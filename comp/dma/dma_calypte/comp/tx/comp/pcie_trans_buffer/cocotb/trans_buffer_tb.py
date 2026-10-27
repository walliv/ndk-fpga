# trans_buffer_tb.py: Shared testbench of the TX_DMA_PCIE_TRANS_BUFFER cocotb benches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Write driving, read sampling and the read-write collision sweep shared by the multi-region (cocotb_test.py) and
the 1-region (cocotb_1region_smoke.py) TX_DMA_PCIE_TRANS_BUFFER benches."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, ReadOnly

# Each test reseeds from the cocotb seed, so COCOTB_RANDOM_SEED varies the stimulus and reproduces a run.
RANDOM_SEED = cocotb.RANDOM_SEED
CLK_PERIOD_NS = 4

# Read data is only guaranteed valid ~6 cycles after the write word that produced it has been
# accepted (1 input register + 2 BRAM input registers + the BRAM write itself). Use a generous
# margin.
WRITE_SETTLE_MARGIN = 20


def log2ceil(x: int) -> int:
    return max(1, (x - 1).bit_length()) if x > 1 else 0


def encode_meta(addr_dw: int, chan: int, be: int, chan_width: int, be_width: int) -> int:
    """PCIE_MFB_META of one region, from the LSB: [IS_DMA_HDR(1)][PCIE_ADDR(62)][CHAN(chan_width)][BE(be_width)]."""
    val = 0  # IS_DMA_HDR = 0
    val |= (addr_dw & ((1 << 62) - 1)) << 1
    val |= (chan & ((1 << chan_width) - 1)) << (1 + 62)
    val |= (be & ((1 << be_width) - 1)) << (1 + 62 + chan_width)
    return val


class TransBufferTestbench:
    """One elaboration of `regions` MFB regions of `region_bytes` each. A write word is a dict of per-region `sof`
    flags, per-region `meta` (addr_dw, chan, be) tuples and `data`; subclasses build the words of their geometry."""

    def __init__(self, dut, model, regions: int, region_bytes: int):
        self.dut = dut
        self.model = model
        self.regions = regions
        self.region_bytes = region_bytes
        self.mfb_bytes = regions * region_bytes
        self.channels = model.channels
        self.chan_width = log2ceil(self.channels)
        self.buf_size = model.buf_size
        # RD_DATA_VLD_A comes READ_LATENCY cycles after RD_EN_A; every sampling point waits the cycles beyond the first.
        self.rd_lat = int(dut.READ_LATENCY.value)

    @classmethod
    async def setup(cls, dut, seed_offset: int):
        """Test prologue: seeds `random` with RANDOM_SEED + seed_offset, starts the clock and resets."""
        random.seed(RANDOM_SEED + seed_offset)
        tb = cls(dut)
        await tb.start_clock()
        await tb.reset()
        return tb

    def start_monitors(self):
        """Hook for observer tasks; started per test, as cocotb ends the tasks of a test with it."""

    async def start_clock(self):
        cocotb.start_soon(Clock(self.dut.CLK, CLK_PERIOD_NS, unit='ns').start())
        self.start_monitors()
        await ClockCycles(self.dut.CLK, 1)

    async def reset(self):
        dut = self.dut
        dut.RESET.value = 1
        dut.PCIE_MFB_SRC_RDY.value = 0
        dut.PCIE_MFB_SOF.value = 0
        dut.PCIE_MFB_DATA.value = 0
        for r in range(self.regions):
            dut.PCIE_MFB_META[r].value = 0
        dut.RD_EN_A.value = 0
        dut.RD_CHAN_A.value = 0
        dut.RD_ADDR_A.value = 0
        dut.RD_EN_B.value = 0
        dut.RD_CHAN_B.value = 0
        dut.RD_ADDR_B.value = 0
        await ClockCycles(dut.CLK, 10)
        dut.RESET.value = 0
        await RisingEdge(dut.CLK)
        # RESET clears the RTL's addr_cntr_pst/chan_num_reg pipeline registers; mirror that in
        # the model (the BRAM content itself is untouched by RESET, on either side).
        self.model.addr_cntr = 0
        self.model.chan_reg = 0

    def model_word(self, word):
        (sof0, sof1), (meta0, meta1) = word['sof'], word['meta']
        self.model.process_word(sof0, sof1, *meta0, *meta1, word['data'])

    def put_word(self, word):
        """Presents `word` with SRC_RDY for the next edge and mirrors it into the model."""
        dut = self.dut
        dut.PCIE_MFB_SRC_RDY.value = 1
        dut.PCIE_MFB_SOF.value = sum(int(sof) << r for r, sof in enumerate(word['sof']))
        dut.PCIE_MFB_DATA.value = int.from_bytes(word['data'], 'little')
        for r, (addr_dw, chan, be) in enumerate(word['meta']):
            dut.PCIE_MFB_META[r].value = encode_meta(addr_dw, chan, be, self.chan_width, self.region_bytes)
        self.model_word(word)

    async def drive_word(self, word):
        self.put_word(word)
        await RisingEdge(self.dut.CLK)

    def release_bus(self):
        self.dut.PCIE_MFB_SRC_RDY.value = 0

    async def drive_idle(self, cycles=1):
        self.dut.PCIE_MFB_SRC_RDY.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.CLK)

    def row_word(self, chan: int, addr_byte: int, data: bytes):
        """The single write word that fills the MFB-word-sized row at `addr_byte` of `chan` with `data`."""
        raise NotImplementedError

    async def write_row(self, chan: int, addr_byte: int, data: bytes):
        await self.drive_word(self.row_word(chan, addr_byte, data))
        self.release_bus()

    async def read_latency_wait(self):
        for _ in range(self.rd_lat - 1):
            await RisingEdge(self.dut.CLK)

    def set_read(self, chan: int, addr: int):
        self.dut.RD_EN_A.value = 1
        self.dut.RD_CHAN_A.value = chan
        self.dut.RD_ADDR_A.value = addr

    async def issue_read(self, chan: int, addr: int):
        """One RD_EN_A pulse from the next edge; returns right after the edge that captures it."""
        await RisingEdge(self.dut.CLK)
        self.set_read(chan, addr)
        await RisingEdge(self.dut.CLK)
        self.dut.RD_EN_A.value = 0

    async def read_sample_point(self):
        """Mid-cycle sampling: vendor memory models (AMD's URAM TDP port B) may update their outputs a few ps after the edge."""
        await FallingEdge(self.dut.CLK)
        await ReadOnly()

    def sample_read(self):
        """(RD_DATA_VLD_A, RD_DATA_A as bytes or None while not valid), to be called in the ReadOnly phase."""
        vld = bool(self.dut.RD_DATA_VLD_A.value)
        return vld, (int(self.dut.RD_DATA_A.value).to_bytes(self.mfb_bytes, 'little') if vld else None)


async def _collision_probe_one(tb, chan: int, addr_byte: int, p_old: bytes, p_new: bytes, delay: int):
    """Restores the row at `addr_byte` of `chan` to p_old, writes p_new there with one word and issues one read `delay`
    cycles from the write's edge. Writer and reader are separate coroutines. Returns (vld, data)."""
    dut = tb.dut

    # ---- restore the row to a known old pattern and let it fully settle -----------------------
    await tb.write_row(chan, addr_byte, p_old)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)
    w = tb.row_word(chan, addr_byte, p_new)

    # PRE must be >= -min(delay) so the reader's idle-cycle count below never goes negative.
    PRE, POST = 4, 20
    result = {"vld": False, "data": None}

    async def writer():
        for _ in range(PRE):
            dut.PCIE_MFB_SRC_RDY.value = 0
            await RisingEdge(dut.CLK)
        # capturing edge (the reference point delay=0 is measured against)
        tb.put_word(w)
        await RisingEdge(dut.CLK)
        tb.release_bus()
        for _ in range(POST):
            await RisingEdge(dut.CLK)

    async def reader():
        wait_cycles = PRE + delay
        assert wait_cycles >= 0, "delay too negative for PRE margin"
        for _ in range(wait_cycles):
            dut.RD_EN_A.value = 0
            await RisingEdge(dut.CLK)
        tb.set_read(chan, addr_byte)
        await RisingEdge(dut.CLK)  # the read's own capturing edge
        dut.RD_EN_A.value = 0
        await tb.read_latency_wait()
        await tb.read_sample_point()
        result["vld"], result["data"] = tb.sample_read()
        await RisingEdge(dut.CLK)  # leave the ReadOnly phase cleanly before this task ends
        for _ in range(max(0, (PRE + POST + 1) - (wait_cycles + 2))):
            await RisingEdge(dut.CLK)

    writer_task = cocotb.start_soon(writer())
    reader_task = cocotb.start_soon(reader())
    await writer_task
    await reader_task

    dut.PCIE_MFB_SRC_RDY.value = 0
    dut.RD_EN_A.value = 0
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    return result["vld"], result["data"]


async def collision_sweep(tb, chan: int, addr_byte: int, label: str):
    """Sweeps delay in -2..+14 at a fixed (chan, addr_byte), logging one line per delay and a final
    summary. Returns the list of (delay, vld, verdict, data) tuples for the caller to inspect."""
    p_old = bytes((i * 7 + 0x11) & 0xFF for i in range(tb.mfb_bytes))
    p_new = bytes((i * 3 + 0xA5) & 0xFF for i in range(tb.mfb_bytes))
    assert p_old != p_new

    results = []
    for delay in range(-2, 15):
        vld, data = await _collision_probe_one(tb, chan, addr_byte, p_old, p_new, delay)
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

    any_other = any(v == "OTHER" for _, _, v, _ in results)
    any_stale_vld = any(v == "OLD" and vld for _, vld, v, _ in results)
    cocotb.log.info(f"[{label}] VERDICT: any delay with VLD=1 and OTHER (neither old nor new) data: "
                    f"{any_other} -- any delay with VLD=1 and STALE (old) data: {any_stale_vld}")
    return results
