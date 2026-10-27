# cocotb_1region_smoke.py: Standalone 1-region smoke test for TX_DMA_PCIE_TRANS_BUFFER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""1-region TX_DMA_PCIE_TRANS_BUFFER, which cocotb_test.py cannot drive: data integrity of aligned, unaligned and
wrapping writes, a one-cycle RD_EN_A -> RD_DATA_VLD_A latency, and the result of a read colliding with a write."""

import random

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from trans_buffer_model import TransBufferModel
from trans_buffer_tb import TransBufferTestbench, WRITE_SETTLE_MARGIN, collision_sweep


class Testbench(TransBufferTestbench):
    """A 1-region elaboration: META[0] only, its BE as wide as the region; every word carries a SOF."""

    def __init__(self, dut):
        region_bytes = (int(dut.MFB_REGION_SIZE.value) * int(dut.MFB_BLOCK_SIZE.value)
                        * int(dut.MFB_ITEM_WIDTH.value)) // 8
        model = TransBufferModel(int(dut.CHANNELS.value), int(dut.POINTER_WIDTH.value))
        super().__init__(dut, model, 1, region_bytes)

    def model_word(self, word):
        addr_dw, chan, be = word['meta'][0]
        self.model.write_bytes(chan, addr_dw, be, word['data'], len(word['data']))

    def release_bus(self):
        super().release_bus()
        self.dut.PCIE_MFB_SOF.value = 0

    def row_word(self, chan: int, addr_byte: int, data: bytes):
        return dict(sof=(True,), meta=((addr_byte // 4, chan, (1 << self.mfb_bytes) - 1),), data=data)

    async def write_word(self, addr_dw: int, chan: int, be: int, data: bytes):
        await self.drive_word(dict(sof=(True,), meta=((addr_dw, chan, be),), data=data))
        self.release_bus()

    async def measure_read(self, chan: int, byte_addr: int):
        """Assert RD_EN_A for one cycle, then measure how many rising edges elapse before
        RD_DATA_VLD_A is seen, returning (latency_cycles, data)."""
        dut = self.dut
        await self.issue_read(chan, byte_addr)
        latency = 0
        for _ in range(20):
            latency += 1
            await self.read_sample_point()
            vld, data = self.sample_read()
            if vld:
                await RisingEdge(dut.CLK)
                return latency, data
            await RisingEdge(dut.CLK)
        raise TimeoutError(f"measure_read: RD_DATA_VLD_A never asserted for chan={chan} addr={byte_addr}")


@cocotb.test()
async def test_1region_smoke(dut):
    tb = await Testbench.setup(dut, 0)

    mfb_bytes = tb.mfb_bytes
    full_be = (1 << mfb_bytes) - 1

    checks = []  # (chan, byte_addr, data)

    # aligned, fully-enabled writes on every channel
    for chan in range(tb.channels):
        data = bytes(random.randrange(256) for _ in range(mfb_bytes))
        addr_dw = ((chan * 4096) % tb.model.buf_size) // 4
        await tb.write_word(addr_dw, chan, full_be, data)
        checks.append((chan, addr_dw * 4, data))

    # sub-DWord (unaligned) byte-enable pattern
    chan = 0
    addr_dw = (tb.model.buf_size // 2 + 64) // 4
    partial_be = 0x0000_0F0F  # a handful of scattered enabled bytes within the word
    data = bytes(random.randrange(256) for _ in range(mfb_bytes))
    await tb.write_word(addr_dw, chan, partial_be, data)
    checks.append((chan, addr_dw * 4, data, partial_be))

    # buffer-wraparound write (address near the end of the per-channel space)
    chan = tb.channels - 1
    wrap_addr_dw = (tb.model.buf_size - mfb_bytes // 2) // 4
    data = bytes(random.randrange(256) for _ in range(mfb_bytes))
    await tb.write_word(wrap_addr_dw, chan, full_be, data)
    checks.append((chan, wrap_addr_dw * 4, data))

    await ClockCycles(dut.CLK, WRITE_SETTLE_MARGIN)

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
# Always run, unlike the 2-region probe of cocotb_test.py: the dropped RD_DATA_VLD_A is RTL behaviour, while the
# undefined data of a TDP collision does not show in simulation.

@cocotb.test()
async def test_1region_collision_gating(dut):
    """Sweeps one read against a write to the same address: the banked buffer must drop RD_DATA_VLD_A in exactly the
    cycle the write lands, the per-byte one returns the old data until then; later reads must return the new data."""
    tb = await Testbench.setup(dut, 1)

    results = await collision_sweep(tb, chan=0, addr_byte=0, label="1region")

    banked = hasattr(dut.tx_dma_pcie_trans_buffer_i.impl_g.trans_buffer_i, "wr_bank_be")
    cocotb.log.info(f"test_1region_collision_gating: {'banked' if banked else 'per-byte'} implementation")
    if not banked:
        verdicts = [v for _, _, v, _ in results]
        assert all(v in ("OLD", "NEW") for v in verdicts) and "NEW" in verdicts, (
            f"1region_collision_gating: per-byte reads must be clean OLD then NEW: {results}")
        first_new = verdicts.index("NEW")
        assert all(v == "NEW" for v in verdicts[first_new:]), f"1region_collision_gating: OLD after NEW: {results}"
        cocotb.log.info(f"test_1region_collision_gating: per-byte reads return the old data until delay "
                        f"{results[first_new][0]}, then the new data")
        return

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
