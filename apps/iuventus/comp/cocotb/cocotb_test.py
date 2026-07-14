# cocotb_test.py: Stage-1 smoke test for a component-level USER_CORE (TEST architecture) cocotb
# testbench, served as a real nfb device via cocotbext.nfb.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import functools
import inspect

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

# cocotb 2.0 compatibility: cocotb 1.x's sync<->async bridge helpers `cocotb.external`
# (blocking function -> awaitable) and `cocotb.function` (coroutine -> blocking, callable from a
# bridged thread) were renamed to `cocotb._bridge.bridge` / `cocotb._bridge.resume` and are no
# longer re-exported at the top level. cocotbext.nfb (and apps/minimal) still reference the old
# names, so restore them here BEFORE importing cocotbext.nfb.
#
# Renaming alone is not enough for `cocotb.function`, though: cocotb 2.0's `resume` requires its
# wrapped callable to be a native `async def` coroutine function (it does `await func(...)`
# internally), but cocotbext.nfb.ext.python.Servicer.read/write (and NdpQueue's start/stop/
# burst_get/burst_put) are still written in the cocotb-1.x style -- plain *generator* functions
# using `yield <awaitable>` that the old `cocotb.function` used to drive step-by-step itself.
# `await <bare generator object>` raises `TypeError: object generator can't be used in 'await'
# expression', which is exactly what made the MI read servicer callback silently fail (visible as
# an "Exception ignored in: 'shim.nfb_pynfb_bus_read'" background traceback, and libnfb.pyx's
# `assert ret == count` failing because the Python side never returned any data). Reimplement the
# old generator-driving behavior as a small adapter and apply it only to generator functions,
# passing everything else (real coroutine functions) straight through to the real `resume`.
import cocotb._bridge as _cocotb_bridge


def _generator_compat_resume(func):
    if not inspect.isgeneratorfunction(func):
        return _cocotb_bridge.resume(func)

    @functools.wraps(func)
    async def _driven(*args, **kwargs):
        gen = func(*args, **kwargs)
        sent = None
        while True:
            try:
                yielded = gen.send(sent)
            except StopIteration as stop:
                return stop.value
            sent = await yielded

    return _cocotb_bridge.resume(_driven)


if not hasattr(cocotb, "external"):
    cocotb.external = _cocotb_bridge.bridge
    cocotb.function = _generator_compat_resume

import cocotbext.nfb  # noqa: E402 (must follow the compat shim above)
from cocotbext.ofm.mi.drivers import MIRequestDriver  # noqa: E402

# Shortcut, matching apps/minimal/tests/cocotb/cocotb_test.py's own convention.
e = cocotb.external


class IuventusUserCoreNfbDevice(cocotbext.nfb.NfbDevice):
    """Minimal cocotbext.nfb.NfbDevice for a standalone USER_CORE (TEST architecture) DUT.

    USER_CORE has no PCIe/DMA/eth of its own (all of that lives in DMA_IUVENTUS / the NDK core),
    so this is far simpler than cocotbext.ndk_core.NFBDevice: three clocks, one MI slave, and no
    QueueManager plumbing beyond what the base class's init() already builds for free -- our
    DevTree (see gen_devtree.tcl) has no "netcope,dma_ctrl_ndp_*" nodes, so
    QueueManager(self).rx/tx simply come out as empty lists, which is exactly what we want for an
    MI-only test. _init_pcie() is left at the base class's no-op default.
    """

    async def _init_clks(self):
        await cocotb.start(Clock(self._dut.USR_CLK, 5, 'ns').start())
        await cocotb.start(Clock(self._dut.DMA_CLK, 4, 'ns').start())
        await cocotb.start(Clock(self._dut.MI_CLK, 10, 'ns').start())

        # Tie the NVME/misc interfaces to benign, quiescent constants (Stage 1 is MI-only; the
        # full DMA/SSD model is Stage 2). Reads are always accepted (RDY=1) but never produce
        # data (SRC_RDY=0), writes are always accepted (DST_RDY=1), and no operation ever
        # "completes" (OP_STAT_VLD=0), so the throughput/latency FSMs stay idle.
        self._dut.NVME_RD_REQ_RDY.value = 1
        self._dut.NVME_OP_STAT_TYPE.value = 0
        self._dut.NVME_OP_STAT_CODE.value = 0
        self._dut.NVME_OP_STAT_VLD.value = 0
        self._dut.NVME_RD_MFB_DATA.value = 0
        self._dut.NVME_RD_MFB_SOF.value = 0
        self._dut.NVME_RD_MFB_EOF.value = 0
        self._dut.NVME_RD_MFB_SOF_POS.value = 0
        self._dut.NVME_RD_MFB_EOF_POS.value = 0
        self._dut.NVME_RD_MFB_SRC_RDY.value = 0
        self._dut.NVME_WR_MFB_DST_RDY.value = 1
        self._dut.PCIE_LINK_UP.value = 1
        self._dut.FPGA_ID.value = 0
        self._dut.FPGA_ID_VLD.value = 0

        # USER_CORE's own MI slave port -- MI_ASYNC bridges this (master side, MI_CLK/MI_RST)
        # across to the DMA_CLK domain that MI_SPLITTER_PLUS_GEN and the CSR logic actually run
        # on (see user_core_test_arch.vhd's mi_async_i), so this driver only ever needs to know
        # about MI_CLK.
        self.mi = [MIRequestDriver(self._dut, "MI", self._dut.MI_CLK)]

    async def _reset(self):
        self._dut.USR_RST.value = 1
        self._dut.DMA_RST.value = 1
        self._dut.MI_RST.value = 1

        await Timer(100, units='ns')

        self._dut.USR_RST.value = 0
        self._dut.DMA_RST.value = 0
        self._dut.MI_RST.value = 0

        await Timer(100, units='ns')


@cocotb.test(timeout_time=50, timeout_unit='us')
async def test_comp_open_and_reg_access(dut):
    """Stage 1 smoke test: USER_CORE served as a real nfb device.

    - nfb.comp_open("ziti,iuventus_test_ctrl") + read32(0x7C) == 0xCAFEBABE proves the *whole*
      path is reachable through the real nfb/DevTree/servicer machinery (not just a raw
      MIRequestDriver poke): comp_open's DevTree node lookup -> MIRequestDriver -> MI_ASYNC ->
      MI_SPLITTER_PLUS_GEN -> read_from_regs_p's `when others => X"CAFEBABE"` sentinel (see
      user_core_test_arch.vhd), which is deliberately what any *unmapped* register address (here
      0x7C) returns.
    - A write+readback of EVCR_INTERVAL_CYCLES (0x24, a real RW register, already used by
      apps/iuventus/sw/iuventus_rw_test.py on real hardware) proves the write path too.
    """
    dev = IuventusUserCoreNfbDevice(dut)
    await dev.init()

    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")

    sentinel = await e(c.read32)(0x7C)
    assert sentinel == 0xCAFEBABE, f"expected 0xCAFEBABE from unmapped reg 0x7C, got {sentinel:#010x}"

    await e(c.write32)(0x24, 0x12345678)
    readback = await e(c.read32)(0x24)
    assert readback == 0x12345678, f"EVCR_INTERVAL_CYCLES readback mismatch: wrote 0x12345678, got {readback:#010x}"
