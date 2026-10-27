# cocotb_test.py: MI32 reads and writes through the CQ and CC interfaces of an AMD PCIe IP
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""The completer model of the cocotbext library sends memory reads and writes of random size and alignment to BAR0 and
rebuilds the completions. The MI32 slave of the DUT is a RAM, and a byte array of the same size is the reference model.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotb_bus.drivers import BitDriver

from cocotbext.ofm.axi4s_pcie.drivers import Axi4sPcieDriverMaster
from cocotbext.ofm.axi4stream.monitors import Axi4StreamV
from cocotbext.ofm.pcie import Axi4SCompleter
from cocotbext.ofm.utils.signals import generic_bool
from cocotbext.ofm.ver.backpressure import BackpressureConfig, BackpressureGenerator

CLK_PERIOD_NS = 4


async def start(dut, p_low):
    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD_NS, unit="ns").start())
    dut.CQ_AXI_LAST.value = 0
    dut.CC_AXI_READY.value = 0
    dut.RESET.value = 1
    await ClockCycles(dut.CLK, 8)
    dut.RESET.value = 0
    await ClockCycles(dut.CLK, 4)

    ready = BitDriver(dut.CC_AXI_READY, dut.CLK)
    ready.start(BackpressureGenerator(BackpressureConfig(1, 5, p_low)))
    cq = Axi4sPcieDriverMaster(dut, "CQ_AXI", dut.CLK)
    ccm = Axi4StreamV(dut, "CC_AXI", dut.CLK, 0, aux_signals=True)
    return Axi4SCompleter(cq, ready, ccm)


async def access(mi, rng, ops, max_bytes, window, p_write):
    """Random accesses to the window (offset, size) of the RAM that no other test uses, the RAM is not reset between tests."""
    offset, size = window
    model = bytearray(size)
    for i in range(ops):
        n = rng.randint(1, max_bytes)
        rel = rng.randrange(0, size - n)
        if rng.random() < p_write:
            data = bytes(rng.getrandbits(8) for _ in range(n))
            model[rel:rel + n] = data
            await mi.write(offset + rel, list(data))
        else:
            got = await mi.read(offset + rel, n)
            expected = bytes(model[rel:rel + n])
            assert got == expected, f"read {i}: {n} bytes at 0x{offset + rel:x} differ\ngot      {got.hex()}\nexpected {expected.hex()}"


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def mi_random_access(dut, ops=600):
    """Reads and writes of 1 to 64 bytes at any alignment, one at a time, with random backpressure on the completions."""
    rng = random.Random(cocotb.RANDOM_SEED)
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}, straddling {generic_bool(dut.AXI_STRADDLING)}")
    mi = await start(dut, 0.3)
    await access(mi, rng, ops, 64, (0, 1024), 0.5)


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def mi_dword_access(dut, ops=800):
    """Aligned single Dword reads and writes, so that completions are as short as they can be."""
    rng = random.Random(cocotb.RANDOM_SEED)
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}")
    mi = await start(dut, 0.2)
    model = bytearray(1024)
    for i in range(ops):
        addr = 1024 + 4 * rng.randrange(256)
        if rng.random() < 0.5:
            val = rng.getrandbits(32)
            model[addr - 1024:addr - 1020] = val.to_bytes(4, "little")
            await mi.write32(addr, val)
        else:
            got = await mi.read32(addr)
            assert got == int.from_bytes(model[addr - 1024:addr - 1020], "little"), f"read {i} at 0x{addr:x}"


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def mi_large_access(dut, ops=60):
    """Reads and writes of up to 256 bytes, which take several beats of the CQ and CC interfaces."""
    rng = random.Random(cocotb.RANDOM_SEED)
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}")
    mi = await start(dut, 0.4)
    await access(mi, rng, ops, 256, (2048, 2048), 0.5)
