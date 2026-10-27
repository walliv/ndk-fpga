# cocotb_loopback_test.py: does the fast cocotb MFB driver put conformant frames on the wire and the monitor read them back?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotbext.ofm.mfb.fast_drivers import MFBDriver
from cocotbext.ofm.mfb.fast_monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import attach_mfb_properties, final_check_all
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.mfb.utils import random_tuple_iterator

MFB_PARAMS = {
    "regions":     int(os.environ.get("REGIONS", 1)),
    "region_size": int(os.environ.get("REGION_SIZE", 8)),
    "block_size":  int(os.environ.get("BLOCK_SIZE", 8)),
    "item_width":  int(os.environ.get("ITEM_WIDTH", 8)),
    "meta_width":  8,
}
ITEM_BYTES = MFB_PARAMS["item_width"] // 8
WORD_BYTES = (MFB_PARAMS["regions"] * MFB_PARAMS["region_size"]
              * MFB_PARAMS["block_size"] * MFB_PARAMS["item_width"]) // 8
FRAMES = 200


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
            # A word of several regions can start and end a frame in each of them.
            self.sof += int(self._sig("SOF").value).bit_count()
            self.eof += int(self._sig("EOF").value).bit_count()


class EofMetaTally:
    """META read at every EOF region of the accepted TX words, plus how often a frame ended in the region where the next began."""

    def __init__(self, dut):
        self.dut = dut
        self.metas = []
        self.end_and_start = 0
        self._open = False
        cocotb.start_soon(self._run())

    async def _run(self):
        regions, meta_w = MFB_PARAMS["regions"], MFB_PARAMS["meta_width"]
        while True:
            await RisingEdge(self.dut.CLK)
            await ReadOnly()
            if str(self.dut.TX_SRC_RDY.value) != "1" or str(self.dut.TX_DST_RDY.value) != "1":
                continue
            sof, eof = int(self.dut.TX_SOF.value), int(self.dut.TX_EOF.value)
            meta = int(self.dut.TX_META.value)
            for r in range(regions):
                s, e = (sof >> r) & 1, (eof >> r) & 1
                if e:
                    self.metas.append((meta >> (r * meta_w)) & ((1 << meta_w) - 1))
                if s and e and self._open:
                    self.end_and_start += 1
                if s and not e:
                    self._open = True
                elif e and not s:
                    self._open = False


class Scoreboard:
    """Frames read back on TX against the frames the driver was given, payload and META alike."""

    def __init__(self, dut):
        self.expected = []
        self.received = []
        self.monitor = MFBMonitor(dut, "TX", dut.CLK, mfb_params=MFB_PARAMS, trans_type=MfbTransactionWithMeta)
        self.monitor.add_callback(self.received.append)

    def expect(self, data, meta):
        self.expected.append((data, meta))

    def mismatches(self):
        errors = []
        if len(self.received) != len(self.expected):
            errors.append(f"{len(self.received)} frames received, {len(self.expected)} sent")
        for n, (trans, (data, meta)) in enumerate(zip(self.received, self.expected)):
            if trans.data != data:
                errors.append(f"frame {n}: payload differs ({len(trans.data)} B received, {len(data)} B sent)")
            if trans.meta != meta:
                errors.append(f"frame {n}: META {trans.meta:#x} received, {meta:#x} sent")
        return errors


class Testbench:
    def __init__(self, dut, vld_gen=None):
        self.dut = dut
        self.driver = MFBDriver(dut, "RX", dut.CLK, mfb_params=MFB_PARAMS, vld_gen=vld_gen)
        # A wire-through DUT drives RX_DST_RDY straight from TX_DST_RDY, so the sink is this line.
        dut.TX_DST_RDY.value = 1
        self.props = attach_mfb_properties(dut, dut.CLK, reset=dut.RESET, max_errors=0)
        self.rx = EdgeTally(dut, "RX")
        self.tx = EdgeTally(dut, "TX")
        self.scoreboard = Scoreboard(dut)

    async def reset(self):
        self.dut.RESET.value = 1
        await ClockCycles(self.dut.CLK, 4)
        self.dut.RESET.value = 0
        await RisingEdge(self.dut.CLK)


def frames(count, sizes=None):
    """Random payloads drawn from the run's seed (COCOTB_RANDOM_SEED), whole items long."""
    rnd = random.Random(random.getrandbits(64))
    out = []
    for _ in range(count):
        n = rnd.choice(sizes) if sizes else rnd.randint(1, 4 * WORD_BYTES // ITEM_BYTES) * ITEM_BYTES
        out.append(rnd.randbytes(n))
    return out


async def _toggle_dst_rdy(dut):
    rnd = random.Random(random.getrandbits(64))
    while True:
        dut.TX_DST_RDY.value = 1
        await ClockCycles(dut.CLK, rnd.randint(1, 6))
        dut.TX_DST_RDY.value = 0
        await ClockCycles(dut.CLK, rnd.randint(1, 4))


async def _prepare(dut, vld_gen=None):
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    tb = Testbench(dut, vld_gen)
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
        if len(tb.scoreboard.received) >= sent:
            break
    await ClockCycles(dut.CLK, 50)


def _send_all(tb, payloads, await_each):
    """The sends of a test: awaited one by one, or queued up front; every frame gets a distinct META."""
    async def sender():
        for i, p in enumerate(payloads):
            tb.scoreboard.expect(p, i & 0xFF)
            trans = MfbTransactionWithMeta(data=p, meta=i & 0xFF)
            if await_each:
                await tb.driver.send(trans)
            else:
                tb.driver.append(trans)
    return sender()


async def _verify(dut, tb, name, payloads, await_each=True):
    await _send_all(tb, payloads, await_each)
    await _drain(dut, tb, len(payloads))
    viol = _report(tb, name, len(payloads))
    assert tb.rx.sof == len(payloads), f"driver put {tb.rx.sof} SOFs on the wire for {len(payloads)} frames"
    assert tb.rx.eof == len(payloads), f"driver put {tb.rx.eof} EOFs on the wire for {len(payloads)} frames"
    assert not viol, f"MFB violations on a wired-through DUT: {viol}"
    final_check_all(tb.props)
    errors = tb.scoreboard.mismatches()
    assert not errors, f"{len(errors)} scoreboard mismatch(es), first: {errors[0]}"


@cocotb.test()
async def test_awaited_send_puts_one_sof_per_frame(dut):
    """Await each send() in turn, one bus word of a frame after another."""
    tb = await _prepare(dut)
    await _verify(dut, tb, "awaited-send", frames(FRAMES))


@cocotb.test()
async def test_word_multiple_frames_awaited(dut):
    """Payloads that fill whole words exactly."""
    tb = await _prepare(dut)
    await _verify(dut, tb, "word-multiple-awaited", frames(FRAMES, [WORD_BYTES, 8 * WORD_BYTES, 16 * WORD_BYTES]))


@cocotb.test()
async def test_word_multiple_frames_with_backpressure(dut):
    """Word-filling payloads while the sink stalls at random, as a real consumer does."""
    tb = await _prepare(dut)
    cocotb.start_soon(_toggle_dst_rdy(dut))
    await _verify(dut, tb, "word-multiple-backpressure", frames(FRAMES, [WORD_BYTES, 8 * WORD_BYTES, 16 * WORD_BYTES]))


@cocotb.test()
async def test_gaps_inside_frames_with_backpressure(dut):
    """The valid generator leaves SRC_RDY low inside frames while the sink stalls at random."""
    tb = await _prepare(dut, vld_gen=random_tuple_iterator(1, 6, 1, 4))
    cocotb.start_soon(_toggle_dst_rdy(dut))
    await _verify(dut, tb, "gaps-backpressure", frames(FRAMES))


@cocotb.test()
async def test_meta_transactions_awaited(dut):
    """MfbTransactionWithMeta takes a different unpacking path than raw bytes."""
    tb = await _prepare(dut)
    await _verify(dut, tb, "meta-awaited", frames(FRAMES, [WORD_BYTES, 8 * WORD_BYTES, 16 * WORD_BYTES]))


@cocotb.test()
async def test_appended_frames_put_one_sof_per_frame(dut):
    """Queue every frame up front."""
    tb = await _prepare(dut)
    await _verify(dut, tb, "appended", frames(FRAMES), await_each=False)


@cocotb.test()
async def test_eof_meta_with_frame_ending_where_the_next_starts(dut):
    """With META valid at EOF, a frame ending in the region where the next one starts gets the META of that region."""
    tb = await _prepare(dut)
    monitor = MFBMonitor(dut, "TX", dut.CLK, mfb_params=MFB_PARAMS, trans_type=MfbTransactionWithMeta,
                         meta_vld_with="eof")
    received = []
    monitor.add_callback(received.append)
    tally = EofMetaTally(dut)
    cocotb.start_soon(_toggle_dst_rdy(dut))
    payloads = frames(FRAMES)
    await _send_all(tb, payloads, await_each=False)
    await _drain(dut, tb, len(payloads))

    # A region of one block always starts a frame at its first item, so no frame can end where another starts.
    if MFB_PARAMS["region_size"] > 1:
        assert tally.end_and_start > 0, "no frame ended in the region where the next one started"
    assert [t.meta for t in received] == tally.metas
