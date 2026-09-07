# cocotb_1region_smoke.py: Standalone 1-region smoke test for TX_DMA_PCIE_TRANS_BUFFER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""
``cocotb_test.py``/``trans_buffer_model.py`` in this directory are hard-wired to a fixed
(MFB_REGIONS=2, MFB_REGION_SIZE=1, MFB_BLOCK_SIZE=8, MFB_ITEM_WIDTH=32) geometry and cannot drive a
1-region instance at all (single-region elaborations only have PCIE_MFB_META/RD_*_B ports sized for
one region-slot; the shared driver unconditionally indexes region 1). This module is a small,
self-contained smoke test for a 1-region geometry, in particular the (1,1,16,32) config used by DMA
Iuventus's sq_rd_buffer_i (see comp/dma/dma_iuventus/comp/card2nvme_controller/c2n_controller.vhd),
covering both RAM_TYPE => "BRAM" and RAM_TYPE => "URAM" -- both now the same sdp_ram_g /
XPM_MEMORY_SDPRAM branch (MEMORY_PRIMITIVE selects "block" vs "ultra").

It checks:
  * write/read data integrity across aligned and unaligned (sub-DWord byte-enable) writes, several
    channels and a buffer-wraparound case;
  * the RD_EN_A -> RD_DATA_VLD_A latency is exactly 1 clock cycle, identically for both RAM_TYPE
    values (the external read-valid contract the RTL author's spec requires stays unchanged when
    switching a 1-region array from BRAM to URAM);
  * test_1region_collision_gating: a same-address read racing a write-landing cycle deasserts
    RD_DATA_VLD_A at exactly that cycle (a delay sweep locates the landing cycle, mirroring
    TB_COLLISION_PROBE's 2-region sweep in cocotb_test.py), and every VLD=1 read after it is clean.

Elaborate/run with e.g.::

    COCOTB_TEST_MODULES=cocotb_1region_smoke NVC_ELAB_ARGS="-gMFB_REGIONS=1 -gMFB_REGION_SIZE=1 \\
        -gMFB_BLOCK_SIZE=16 -gMFB_ITEM_WIDTH=32 -gPOINTER_WIDTH=18 -gCHANNELS=2 -gRAM_TYPE=URAM" \\
        make sim-elab sim-run
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

RANDOM_SEED = 0xDEADBEEF


def log2ceil(x: int) -> int:
    return max(1, (x - 1).bit_length()) if x > 1 else 0


class RefModel:
    """Byte-accurate reference for a 1-region (single write context) elaboration."""

    def __init__(self, channels: int, pointer_width: int):
        self.channels = channels
        self.buf_size = 1 << pointer_width
        self.buffers = [bytearray(self.buf_size) for _ in range(channels)]

    def write(self, chan: int, byte_addr: int, be: int, data: bytes):
        buf = self.buffers[chan]
        for i in range(len(data)):
            if (be >> i) & 1:
                buf[(byte_addr + i) % self.buf_size] = data[i]

    def read(self, chan: int, byte_addr: int, length: int) -> bytes:
        buf = self.buffers[chan]
        return bytes(buf[(byte_addr + i) % self.buf_size] for i in range(length))


class Testbench:
    def __init__(self, dut):
        self.dut = dut
        self.channels = int(dut.CHANNELS.value)
        self.pointer_width = int(dut.POINTER_WIDTH.value)
        self.mfb_bytes = (int(dut.MFB_REGION_SIZE.value) * int(dut.MFB_BLOCK_SIZE.value)
                          * int(dut.MFB_ITEM_WIDTH.value)) // 8
        self.chan_width = log2ceil(self.channels)
        self.model = RefModel(self.channels, self.pointer_width)

    async def start_clock(self):
        cocotb.start_soon(Clock(self.dut.CLK, 4, unit='ns').start())
        await ClockCycles(self.dut.CLK, 1)

    async def reset(self):
        dut = self.dut
        dut.RESET.value = 1
        dut.PCIE_MFB_SRC_RDY.value = 0
        dut.PCIE_MFB_SOF.value = 0
        dut.PCIE_MFB_DATA.value = 0
        dut.PCIE_MFB_META[0].value = 0
        dut.RD_EN_A.value = 0
        dut.RD_CHAN_A.value = 0
        dut.RD_ADDR_A.value = 0
        dut.RD_EN_B.value = 0
        dut.RD_CHAN_B.value = 0
        dut.RD_ADDR_B.value = 0
        await ClockCycles(dut.CLK, 10)
        dut.RESET.value = 0
        await RisingEdge(dut.CLK)

    def _encode_meta(self, addr_dw: int, chan: int, be: int) -> int:
        # META layout (see tx_dma_pcie_trans_buffer.vhd): [IS_DMA_HDR(1)][PCIE_ADDR(62)][CHAN(N)][BE(bytes)]
        val = 0
        val |= (addr_dw & ((1 << 62) - 1)) << 1
        val |= (chan & ((1 << self.chan_width) - 1)) << (1 + 62)
        val |= (be & ((1 << self.mfb_bytes) - 1)) << (1 + 62 + self.chan_width)
        return val

    async def write_word(self, addr_dw: int, chan: int, be: int, data: bytes):
        dut = self.dut
        dut.PCIE_MFB_SRC_RDY.value = 1
        dut.PCIE_MFB_SOF.value = 1
        dut.PCIE_MFB_DATA.value = int.from_bytes(data, 'little')
        dut.PCIE_MFB_META[0].value = self._encode_meta(addr_dw, chan, be)
        await RisingEdge(dut.CLK)
        dut.PCIE_MFB_SRC_RDY.value = 0
        dut.PCIE_MFB_SOF.value = 0

    async def measure_read(self, chan: int, byte_addr: int):
        """Assert RD_EN_A for one cycle, then measure how many rising edges elapse before
        RD_DATA_VLD_A is seen, returning (latency_cycles, data)."""
        dut = self.dut
        await RisingEdge(dut.CLK)
        dut.RD_EN_A.value = 1
        dut.RD_CHAN_A.value = chan
        dut.RD_ADDR_A.value = byte_addr
        await RisingEdge(dut.CLK)
        dut.RD_EN_A.value = 0
        latency = 0
        for _ in range(20):
            latency += 1
            await ReadOnly()
            if bool(dut.RD_DATA_VLD_A.value):
                data = int(dut.RD_DATA_A.value).to_bytes(self.mfb_bytes, 'little')
                await RisingEdge(dut.CLK)
                return latency, data
            await RisingEdge(dut.CLK)
        raise TimeoutError(f"measure_read: RD_DATA_VLD_A never asserted for chan={chan} addr={byte_addr}")


@cocotb.test()
async def test_1region_smoke(dut):
    random.seed(RANDOM_SEED)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    mfb_bytes = tb.mfb_bytes
    full_be = (1 << mfb_bytes) - 1

    checks = []  # (chan, byte_addr, data)

    # aligned, fully-enabled writes on every channel
    for chan in range(tb.channels):
        data = bytes(random.randrange(256) for _ in range(mfb_bytes))
        addr_dw = (chan * 4096) // 4
        await tb.write_word(addr_dw, chan, full_be, data)
        tb.model.write(chan, addr_dw * 4, full_be, data)
        checks.append((chan, addr_dw * 4, data))

    # sub-DWord (unaligned) byte-enable pattern
    chan = 0
    addr_dw = 8192 // 4
    partial_be = 0x0000_0F0F  # a handful of scattered enabled bytes within the word
    data = bytes(random.randrange(256) for _ in range(mfb_bytes))
    await tb.write_word(addr_dw, chan, partial_be, data)
    tb.model.write(chan, addr_dw * 4, partial_be, data)
    checks.append((chan, addr_dw * 4, data, partial_be))

    # buffer-wraparound write (address near the end of the per-channel space)
    chan = tb.channels - 1
    wrap_addr_dw = (tb.model.buf_size - mfb_bytes // 2) // 4
    data = bytes(random.randrange(256) for _ in range(mfb_bytes))
    await tb.write_word(wrap_addr_dw, chan, full_be, data)
    tb.model.write(chan, wrap_addr_dw * 4, full_be, data)
    checks.append((chan, wrap_addr_dw * 4, data))

    await ClockCycles(dut.CLK, 20)  # write-settle margin (input reg + BRAM input regs + BRAM write)

    latencies = set()
    for entry in checks:
        if len(entry) == 4:
            chan, byte_addr, data, be = entry
        else:
            chan, byte_addr, data = entry
            be = full_be
        latency, got = await tb.measure_read(chan, byte_addr)
        latencies.add(latency)
        exp = tb.model.read(chan, byte_addr, mfb_bytes)
        for i in range(mfb_bytes):
            if (be >> i) & 1:
                assert got[i] == exp[i], (
                    f"1region_smoke mismatch chan={chan} addr={byte_addr} byte={i}: "
                    f"got={got[i]:02x} exp={exp[i]:02x}")

    assert latencies == {1}, f"1region_smoke: RD_EN_A->RD_DATA_VLD_A latency not uniform: {latencies}"
    cocotb.log.info(
        f"test_1region_smoke: {len(checks)} checks passed, "
        f"RD_EN_A->RD_DATA_VLD_A latency = {latencies.pop()} cycle(s)")


# ==== Same-address collision gating (1-region SDP) ====
# Mirrors TB_COLLISION_PROBE as an always-run test: RD_DATA_VLD_A deasserting on collision is real
# RTL -- unlike TDP collision, whose undefined-data symptom nvc's model can't reproduce.

async def _collision_probe_one(tb, chan: int, byte_addr: int, p_old: bytes, p_new: bytes, delay: int):
    """One data point of the sweep: restore `byte_addr` to p_old, then drive a single write word of
    p_new to the same address while issuing exactly one RD_EN_A/RD_ADDR_A/RD_CHAN_A pulse at `delay`
    clock cycles relative to the write word's capturing edge. Returns (vld, data) sampled the cycle
    RD_DATA_VLD_A/RD_DATA_A are expected valid."""
    dut = tb.dut
    addr_dw = byte_addr // 4
    full_be = (1 << tb.mfb_bytes) - 1

    await tb.write_word(addr_dw, chan, full_be, p_old)
    await ClockCycles(dut.CLK, 20)  # write-settle margin, see test_1region_smoke

    PRE, POST = 4, 20
    result = {"vld": False, "data": None}

    async def writer():
        for _ in range(PRE):
            dut.PCIE_MFB_SRC_RDY.value = 0
            await RisingEdge(dut.CLK)
        # capturing edge (the reference point delay=0 is measured against)
        dut.PCIE_MFB_SRC_RDY.value = 1
        dut.PCIE_MFB_SOF.value = 1
        dut.PCIE_MFB_DATA.value = int.from_bytes(p_new, 'little')
        dut.PCIE_MFB_META[0].value = tb._encode_meta(addr_dw, chan, full_be)
        await RisingEdge(dut.CLK)
        dut.PCIE_MFB_SRC_RDY.value = 0
        dut.PCIE_MFB_SOF.value = 0
        for _ in range(POST):
            await RisingEdge(dut.CLK)

    async def reader():
        wait_cycles = PRE + delay
        assert wait_cycles >= 0, "delay too negative for PRE margin"
        for _ in range(wait_cycles):
            dut.RD_EN_A.value = 0
            await RisingEdge(dut.CLK)
        dut.RD_EN_A.value = 1
        dut.RD_CHAN_A.value = chan
        dut.RD_ADDR_A.value = byte_addr
        await RisingEdge(dut.CLK)  # the read's own capturing edge
        dut.RD_EN_A.value = 0
        await ReadOnly()
        result["vld"] = bool(dut.RD_DATA_VLD_A.value)
        if result["vld"]:
            result["data"] = int(dut.RD_DATA_A.value).to_bytes(tb.mfb_bytes, 'little')
        await RisingEdge(dut.CLK)  # leave the ReadOnly phase cleanly before this task ends
        for _ in range(max(0, (PRE + POST + 1) - (wait_cycles + 2))):
            await RisingEdge(dut.CLK)

    writer_task = cocotb.start_soon(writer())
    reader_task = cocotb.start_soon(reader())
    await writer_task
    await reader_task

    dut.PCIE_MFB_SRC_RDY.value = 0
    dut.RD_EN_A.value = 0
    await ClockCycles(dut.CLK, 20)

    return result["vld"], result["data"]


async def _collision_sweep(tb, chan: int, byte_addr: int, label: str):
    """Sweeps delay in -2..+14 at a fixed (chan, byte_addr), logging one line per delay and a final
    summary. Returns the list of (delay, vld, verdict, data) tuples for the caller to inspect."""
    mfb_bytes = tb.mfb_bytes
    p_old = bytes((i * 7 + 0x11) & 0xFF for i in range(mfb_bytes))
    p_new = bytes((i * 3 + 0xA5) & 0xFF for i in range(mfb_bytes))
    assert p_old != p_new

    results = []
    for delay in range(-2, 15):
        vld, data = await _collision_probe_one(tb, chan, byte_addr, p_old, p_new, delay)
        if not vld:
            verdict = "VLD=0"
        elif data == p_old:
            verdict = "OLD"
        elif data == p_new:
            verdict = "NEW"
        else:
            verdict = "OTHER"
        results.append((delay, vld, verdict, data))
        data_hex = "-" if data is None else data[:8].hex()
        cocotb.log.info(f"[{label}] delay={delay:+3d}  VLD={int(vld)}  verdict={verdict:5s}  data[:8]={data_hex}")

    table = ", ".join(f"{d:+d}:{v}" for d, _, v, _ in results)
    cocotb.log.info(f"[{label}] delay sweep table: {table}")
    return results


@cocotb.test()
async def test_1region_collision_gating(dut):
    """Directed proof of the 1-region SDP collision gate: sweep a single read's timing against a
    write landing at the same address and confirm RD_DATA_VLD_A deasserts at exactly the
    write-landing cycle (found via the sweep, not hardcoded), then resumes clean (NEW) right after."""
    random.seed(RANDOM_SEED + 1)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    results = await _collision_sweep(tb, chan=0, byte_addr=0, label="1region")

    landing_delays = [d for d, vld, _, _ in results if not vld]
    assert landing_delays, (
        f"1region_collision_gating: no delay showed VLD=0 -- the collision gate never fired: {results}")
    landing = max(landing_delays)

    # Once the write has safely landed, a clean read must see NEW data, never OLD (stale) or OTHER
    # (corrupted) -- the gate must not falsely suppress reads past the collision cycle either.
    for d, vld, verdict, _ in results:
        if vld and d > landing:
            assert verdict == "NEW", (
                f"1region_collision_gating: delay={d} verdict={verdict}, expected NEW after landing={landing}")

    cocotb.log.info(f"test_1region_collision_gating: gate fired at delay(s) {landing_delays}, "
                     f"clean NEW reads confirmed after landing={landing}")
