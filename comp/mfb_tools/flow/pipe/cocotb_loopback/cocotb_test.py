# cocotb_test.py: does the cocotb MFB driver put conformant frames on the wire?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.mfb.properties import attach_mfb_properties

MFB_PARAMS = {
    "regions":     int(os.environ.get("REGIONS", 1)),
    "region_size": int(os.environ.get("REGION_SIZE", 8)),
    "block_size":  int(os.environ.get("BLOCK_SIZE", 8)),
    "item_width":  int(os.environ.get("ITEM_WIDTH", 8)),
    "meta_width":  8,
}
WORD_BYTES = (MFB_PARAMS["regions"] * MFB_PARAMS["region_size"]
              * MFB_PARAMS["block_size"] * MFB_PARAMS["item_width"]) // 8


class EdgeTally:
    """Counts SOF and EOF actually accepted on a bus, independent of the property checker."""

    def __init__(self, dut, prefix):
        self.dut, self.prefix = dut, prefix
        self.words = self.sof = self.eof = 0
        cocotb.start_soon(self._run())

    def _sig(self, field):
        return getattr(self.dut, f"{self.prefix}_{field}")

    async def _run(self):
        while True:
            await RisingEdge(self.dut.CLK)
            await ReadOnly()
            if str(self._sig("SRC_RDY").value) != "1" or str(self._sig("DST_RDY").value) != "1":
                continue
            self.words += 1
            self.sof += 1 if int(self._sig("SOF").value) else 0
            self.eof += 1 if int(self._sig("EOF").value) else 0


class Testbench:
    def __init__(self, dut):
        self.dut = dut
        self.driver = MFBDriver(dut, "RX", dut.CLK, mfb_params=MFB_PARAMS, vld_gen=None)
        # A wire-through DUT drives RX_DST_RDY straight from TX_DST_RDY, so the sink is this line.
        dut.TX_DST_RDY.value = 1
        self.props = attach_mfb_properties(dut, dut.CLK, reset=dut.RESET, max_errors=0)
        self.rx = EdgeTally(dut, "RX")
        self.tx = EdgeTally(dut, "TX")

    async def reset(self):
        self.dut.RESET.value = 1
        await ClockCycles(self.dut.CLK, 4)
        self.dut.RESET.value = 0
        await RisingEdge(self.dut.CLK)


def frames(count, seed, sizes=None):
    rnd = random.Random(seed)
    out = []
    for _ in range(count):
        n = rnd.choice(sizes) if sizes else rnd.randint(1, 4 * WORD_BYTES)
        out.append(bytes(rnd.randrange(256) for _ in range(n)))
    return out


async def _toggle_dst_rdy(dut, seed=7):
    rnd = random.Random(seed)
    while True:
        dut.TX_DST_RDY.value = 1
        await ClockCycles(dut.CLK, rnd.randint(1, 6))
        dut.TX_DST_RDY.value = 0
        await ClockCycles(dut.CLK, rnd.randint(1, 4))


async def _prepare(dut):
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    tb = Testbench(dut)
    await tb.reset()
    return tb


def _report(tb, name, sent):
    viol = {}
    for key, p in tb.props.items():
        for _, rule, _ in p.errors:
            viol[rule] = viol.get(rule, 0) + 1
    cocotb.log.info(
        f"{name}: frames={sent} RX words={tb.rx.words} sof={tb.rx.sof} eof={tb.rx.eof} "
        f"| TX sof={tb.tx.sof} eof={tb.tx.eof} | violations={viol or 'none'}")
    return viol


async def _drain(dut, tb, sent):
    for _ in range(200):
        await ClockCycles(dut.CLK, 50)
        if tb.rx.eof >= sent:
            break
    await ClockCycles(dut.CLK, 50)


@cocotb.test()
async def test_awaited_send_puts_one_sof_per_frame(dut):
    """Await each send() in turn, the shape SimplifiedDmaModel uses."""
    tb = await _prepare(dut)
    payloads = frames(200, seed=1)
    for p in payloads:
        await tb.driver.send(p)
    await _drain(dut, tb, len(payloads))
    viol = _report(tb, "awaited-send", len(payloads))
    assert tb.rx.sof == len(payloads), f"driver put {tb.rx.sof} SOFs on the wire for {len(payloads)} frames"
    assert tb.rx.eof == len(payloads), f"driver put {tb.rx.eof} EOFs on the wire for {len(payloads)} frames"
    assert not viol, f"MFB violations on a wired-through DUT: {viol}"


@cocotb.test()
async def test_word_multiple_frames_awaited(dut):
    """Payloads that fill whole words exactly, the shape a sector-sized read produces."""
    tb = await _prepare(dut)
    payloads = frames(200, seed=3, sizes=[WORD_BYTES, 8 * WORD_BYTES, 16 * WORD_BYTES])
    for p in payloads:
        await tb.driver.send(p)
    await _drain(dut, tb, len(payloads))
    viol = _report(tb, "word-multiple-awaited", len(payloads))
    assert tb.rx.sof == len(payloads), f"driver put {tb.rx.sof} SOFs for {len(payloads)} frames"
    assert tb.rx.eof == len(payloads), f"driver put {tb.rx.eof} EOFs for {len(payloads)} frames"
    assert not viol, f"MFB violations on a wired-through DUT: {viol}"


@cocotb.test()
async def test_word_multiple_frames_with_backpressure(dut):
    """Word-filling payloads while the sink stalls at random, as a real consumer does."""
    tb = await _prepare(dut)
    cocotb.start_soon(_toggle_dst_rdy(dut))
    payloads = frames(200, seed=4, sizes=[WORD_BYTES, 8 * WORD_BYTES, 16 * WORD_BYTES])
    for p in payloads:
        await tb.driver.send(p)
    await _drain(dut, tb, len(payloads))
    viol = _report(tb, "word-multiple-backpressure", len(payloads))
    assert tb.rx.sof == len(payloads), f"driver put {tb.rx.sof} SOFs for {len(payloads)} frames"
    assert tb.rx.eof == len(payloads), f"driver put {tb.rx.eof} EOFs for {len(payloads)} frames"
    assert not viol, f"MFB violations on a wired-through DUT: {viol}"


@cocotb.test()
async def test_meta_transactions_awaited(dut):
    """MfbTransactionWithMeta takes a different unpacking path than raw bytes."""
    tb = await _prepare(dut)
    payloads = frames(200, seed=5, sizes=[WORD_BYTES, 8 * WORD_BYTES, 16 * WORD_BYTES])
    for i, p in enumerate(payloads):
        await tb.driver.send(MfbTransactionWithMeta(data=p, meta=i & 0xFF))
    await _drain(dut, tb, len(payloads))
    viol = _report(tb, "meta-awaited", len(payloads))
    assert tb.rx.sof == len(payloads), f"driver put {tb.rx.sof} SOFs for {len(payloads)} frames"
    assert tb.rx.eof == len(payloads), f"driver put {tb.rx.eof} EOFs for {len(payloads)} frames"
    assert not viol, f"MFB violations on a wired-through DUT: {viol}"


@cocotb.test()
async def test_appended_frames_put_one_sof_per_frame(dut):
    """Queue every frame up front, the shape the engine bench uses."""
    tb = await _prepare(dut)
    payloads = frames(200, seed=2)
    for p in payloads:
        tb.driver.append(p)
    await _drain(dut, tb, len(payloads))
    viol = _report(tb, "appended", len(payloads))
    assert tb.rx.sof == len(payloads), f"driver put {tb.rx.sof} SOFs on the wire for {len(payloads)} frames"
    assert tb.rx.eof == len(payloads), f"driver put {tb.rx.eof} EOFs on the wire for {len(payloads)} frames"
    assert not viol, f"MFB violations on a wired-through DUT: {viol}"
