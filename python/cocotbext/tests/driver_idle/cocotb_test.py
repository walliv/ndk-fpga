# cocotb_test.py: MFB and MVB driver behaviour against a sink that drops DST_RDY at random
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Each driver sends whole words split by scripted idle words while the sink drops DST_RDY at random. Words
must arrive once, in order and held while waiting, and each gap must last exactly its idle words."""

import itertools
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Event, ReadOnly, RisingEdge

from cocotbext.ofm.base.generators import IdleGenerator, OnOffIdleGenerator
from cocotbext.ofm.base.transaction import IdleTransactionFactory
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.protocol import MfbParams
from cocotbext.ofm.mfb.transaction import MfbTransaction
from cocotbext.ofm.mvb.drivers import MVBDriver
from cocotbext.ofm.mvb.transaction import MvbTrClassic
from cocotbext.ofm.ver.backpressure import BackpressureConfig, apply_backpressure

CLK_NS = 4
WORDS = 400
GAP_MAX = 4
DST_RDY_HIGH = 0.4
# Cycles per word with every gap at GAP_MAX and DST_RDY high only in every tenth cycle.
CYCLES_PER_WORD_MAX = GAP_MAX + 10


class ScriptedIdles(IdleGenerator):
    """Idle items before each transaction, taken from a list, then none."""

    def __init__(self, counts):
        super().__init__()
        self._counts = iter(counts)

    def get(self, transaction, *args, **kwargs):
        return next(self._counts, 0)


async def sample(dut, prefix, cycles):
    """One (SRC_RDY, DST_RDY, DATA) entry per clock, read where the drivers read DST_RDY."""
    src, dst, data = (getattr(dut, f"{prefix}_{s}") for s in ("SRC_RDY", "DST_RDY", "DATA"))
    # The first cycle starts with the first writes of the drivers and the sink, so it is read before the first edge.
    await ReadOnly()
    while True:
        cycles.append((int(src.value), int(dst.value), int(data.value)))
        await RisingEdge(dut.CLK)
        await ReadOnly()


def check(cycles, words, gaps_after):
    """`words` must be accepted in order, each held until DST_RDY; after the k-th accepted word exactly
    gaps_after[k] cycles with SRC_RDY low may pass before the next word is offered."""
    errors, accepted = [], []
    offered, idle = None, None
    for n, (src, dst, data) in enumerate(cycles):
        if src:
            if offered is not None and data != offered:
                errors.append(f"cycle {n}: the offered word changed before DST_RDY")
            if offered is None and idle is not None and idle != gaps_after[len(accepted) - 1]:
                errors.append(f"after word {len(accepted) - 1}: {idle} idle cycle(s) instead of the "
                              f"{gaps_after[len(accepted) - 1]} scripted")
            offered = data
            if dst:
                accepted.append(data)
                offered, idle = None, 0
        else:
            if offered is not None:
                errors.append(f"cycle {n}: SRC_RDY fell before the offered word was accepted")
                offered = None
            if idle is not None:
                idle += 1
    if accepted != words:
        errors.append(f"{len(accepted)} of {len(words)} words accepted, first mismatch at "
                      f"{next((k for k, (a, w) in enumerate(zip(accepted, words)) if a != w), len(accepted))}")
    return errors


async def run(dut, prefix, words, gaps_after):
    cycles = []
    rng = random.Random(random.getrandbits(64))
    cocotb.start_soon(apply_backpressure(getattr(dut, f"{prefix}_DST_RDY"), dut.CLK,
                                         BackpressureConfig(1, 1, 1 - DST_RDY_HIGH), rng))
    cocotb.start_soon(sample(dut, prefix, cycles))
    limit = len(words) * CYCLES_PER_WORD_MAX
    while sum(1 for s, d, _ in cycles if s and d) < len(words) and len(cycles) < limit:
        await ClockCycles(dut.CLK, 100)
    errors = check(cycles, words, gaps_after)
    # The hit counter: idle words offered while DST_RDY was low, the case the drivers must not wait in.
    hits = sum(1 for s, d, _ in cycles if not s and not d)
    dut._log.info(f"{prefix}: {len(words)} words in {len(cycles)} cycles, {hits} idle cycles with DST_RDY low, "
                  f"{len(errors)} error(s)")
    for e in errors[:10]:
        dut._log.error(f"{prefix}: {e}")
    assert hits > 0, "no idle word met DST_RDY low"
    assert not errors, f"{prefix}: {len(errors)} error(s), first: {errors[0]}"


def mfb_geometry(dut):
    return MfbParams(*(int(getattr(dut, f"MFB_{g}").value) for g in ("REGIONS", "REGION_SIZE", "BLOCK_SIZE", "ITEM_WIDTH")))


async def start(dut):
    cocotb.start_soon(Clock(dut.CLK, CLK_NS, "ns").start())
    dut.RX_MFB_DST_RDY.value = 0
    dut.RX_MFB_BE.value = 0
    dut.RX_MVB_DST_RDY.value = 0
    # The MVB driver writes its data signals only with its first word, so they start defined here, one clock
    # ahead: a write of the bench in the timestep of the driver's first word would replace that word.
    dut.RX_MVB_DATA.value = 0
    await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_idle_words_test(dut):
    """One-word frames; the idle generator puts the scripted idle transactions before each frame."""
    await start(dut)
    geo = mfb_geometry(dut)
    rng = random.Random(random.getrandbits(64))
    gaps = [rng.randint(0, GAP_MAX) for _ in range(WORDS)]
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_factory=IdleTransactionFactory(1, 1),
                    idle_generator=ScriptedIdles(gaps))
    frames = [rng.randbytes(geo.word_width // 8) for _ in range(WORDS)]
    for f in frames:
        drv.append(MfbTransaction(data=f))
    await run(dut, "RX_MFB", [int.from_bytes(f, "little") for f in frames], gaps[1:] + [0])


@cocotb.test()
async def run_mfb_frame_gap_words_test(dut):
    """Frames of one to four words; the on-off generator ends each word with its scripted number of whole idle words,
    inside a frame as between frames."""
    await start(dut)
    geo = mfb_geometry(dut)
    blocks = geo.regions * geo.region_size
    word_bytes = geo.word_width // 8
    rng = random.Random(random.getrandbits(64))
    gaps = [rng.randint(0, GAP_MAX) for _ in range(WORDS)]
    pattern = itertools.chain(((blocks, g * blocks) for g in gaps), itertools.repeat((blocks, 0)))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=OnOffIdleGenerator(pattern))
    data = rng.randbytes(WORDS * word_bytes)
    sent = 0
    while sent < WORDS:
        n = min(rng.randint(1, 4), WORDS - sent)
        drv.append(MfbTransaction(data=data[sent * word_bytes:(sent + n) * word_bytes]))
        sent += n
    words = [int.from_bytes(data[k * word_bytes:(k + 1) * word_bytes], "little") for k in range(WORDS)]
    await run(dut, "RX_MFB", words, gaps)


async def collect_sof_blocks(dut, geo, blocks):
    """The block of every SOF, counted from the first word on; with DST_RDY high every clock is a word. Started in
    the timestep of the first word, it reads that word before the first edge."""
    width = len(dut.RX_MFB_SOF_POS) // geo.regions
    word = None
    await ReadOnly()
    while True:
        if word is not None or int(dut.RX_MFB_SRC_RDY.value):
            word = 0 if word is None else word + 1
            sof, sof_pos = int(dut.RX_MFB_SOF.value), str(dut.RX_MFB_SOF_POS.value)
            for r in range(geo.regions):
                if int(dut.RX_MFB_SRC_RDY.value) and sof >> r & 1:
                    field = sof_pos[len(sof_pos) - (r + 1) * width:len(sof_pos) - r * width]
                    blocks.append((word * geo.regions + r) * geo.region_size + int(field, 2))
        await RisingEdge(dut.CLK)
        await ReadOnly()


@cocotb.test()
async def run_mfb_frame_gap_blocks_test(dut):
    """Frames of one region; the on-off generator leaves its scripted number of blocks, up to more than a word,
    empty between them."""
    await start(dut)
    geo = mfb_geometry(dut)
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    frames = 200
    gaps = [rng.randint(0, 3) * geo.region_size for _ in range(frames)]
    pattern = itertools.chain(((geo.region_size, g) for g in gaps), itertools.repeat((geo.region_size, 0)))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=OnOffIdleGenerator(pattern))
    blocks = []
    for _ in range(frames):
        drv.append(MfbTransaction(data=rng.randbytes(geo.region_size * geo.block_size * geo.item_width // 8)))
    cocotb.start_soon(collect_sof_blocks(dut, geo, blocks))
    await ClockCycles(dut.CLK, frames * 3)

    expected = [0]
    for g in gaps[:frames - 1]:
        expected.append(expected[-1] + geo.region_size + g)
    assert blocks == expected, f"{len(blocks)} SOFs, first misplaced: " \
        f"{next(((k, b, e) for k, (b, e) in enumerate(zip(blocks, expected)) if b != e), None)}"


@cocotb.test()
async def run_mvb_idle_words_test(dut):
    """Words of MVB_ITEMS items; the idle generator puts the scripted idle words before each word's first item."""
    await start(dut)
    items, width = int(dut.MVB_ITEMS.value), int(dut.MVB_ITEM_WIDTH.value)
    rng = random.Random(random.getrandbits(64))
    gaps = [rng.randint(0, GAP_MAX) for _ in range(WORDS)]
    drv = MVBDriver(dut, "RX_MVB", dut.CLK, generics_prefix="MVB", no_default_rate_limiter=True,
                    idle_factory=IdleTransactionFactory(1, 1))
    drv.set_idle_generator(ScriptedIdles([g if k == 0 else 0 for g in gaps for k in range(items)]))
    values = [[rng.getrandbits(width) for _ in range(items)] for _ in range(WORDS)]
    for word in values:
        for v in word:
            drv.append(MvbTrClassic(data=v))
    words = [sum(v << (k * width) for k, v in enumerate(word)) for word in values]
    await run(dut, "RX_MVB", words, gaps[1:] + [0])


async def collect_sof_words(dut, words):
    """Every accepted MFB word as (DATA, SOF)."""
    while True:
        await RisingEdge(dut.CLK)
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            words.append((int(dut.RX_MFB_DATA.value), int(dut.RX_MFB_SOF.value)))


async def count_eofs(dut, eofs):
    """The count of accepted EOFs in eofs[0], sampled at ReadOnly before the edge that accepts them."""
    while True:
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            eofs[0] += bin(int(dut.RX_MFB_EOF.value)).count("1")
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_send_test(dut):
    """send() returns once the sink has accepted the frame, whatever DST_RDY does, and the events given to append()
    are set then; pending counts the frames not yet accepted."""
    await start(dut)
    geo = mfb_geometry(dut)
    rng = random.Random(random.getrandbits(64))
    cocotb.start_soon(apply_backpressure(dut.RX_MFB_DST_RDY, dut.CLK, BackpressureConfig(1, 4, 0.5), rng))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB")
    eofs = [0]
    cocotb.start_soon(count_eofs(dut, eofs))

    for k in range(40):
        await drv.send(MfbTransaction(data=rng.randbytes(rng.randint(1, 3 * geo.word_width // 8))))
        assert eofs[0] == k + 1 and drv.frame_cnt == k + 1 and drv.pending == 0, \
            f"send() of frame {k} returned with {eofs[0]} frame(s) accepted, frame_cnt {drv.frame_cnt}"

    events = [Event() for _ in range(20)]
    for ev in events:
        drv.append(MfbTransaction(data=rng.randbytes(rng.randint(1, 100))), event=ev)
    assert drv.pending == len(events)
    for k, ev in enumerate(events):
        await ev.wait()
        assert eofs[0] >= 41 + k, f"the event of frame {k} was set before the sink accepted it"
    assert drv.pending == 0


@cocotb.test()
async def run_mfb_append_while_flushing_test(dut):
    """A frame appended while the driver waits for DST_RDY on the open word of the last frame is sent after it."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB")
    drv.set_idle_generator(IdleGenerator())
    words = []
    cocotb.start_soon(collect_sof_words(dut, words))

    # The first frame ends inside its word, which the driver offers alone once its queue runs empty.
    first, second = rng.randbytes(word_bytes // 4), rng.randbytes(word_bytes // 4)
    drv.append(MfbTransaction(data=first))
    await ClockCycles(dut.CLK, 3)
    drv.append(MfbTransaction(data=second))
    await ClockCycles(dut.CLK, 3)
    dut.RX_MFB_DST_RDY.value = 1
    await ClockCycles(dut.CLK, 10)

    assert [d for d, _ in words] == [int.from_bytes(first, "little"), int.from_bytes(second, "little")]
