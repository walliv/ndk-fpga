# cocotb_test.py: MFB and MVB driver behaviour against a sink that drops DST_RDY at random
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Each driver sends whole words split by scripted idle words while the sink drops DST_RDY at random. Words
must arrive once, in order and held while waiting, and each gap must last exactly its idle words."""

import itertools
import random
from dataclasses import asdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Event, ReadOnly, RisingEdge
from cocotb.types import LogicArray
from cocotb.utils import get_sim_time

from cocotbext.ofm.base.generators import IdleGenerator, OnOffIdleGenerator
from cocotbext.ofm.base.transaction import IdleTransactionFactory
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.protocol import MfbParams
from cocotbext.ofm.mfb.transaction import MfbTransaction, MfbWord
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


async def sample_bus(dut, cycles):
    """One (SRC_RDY, DATA, SOF, EOF) entry per clock, from the timestep it is started in."""
    while True:
        await ReadOnly()
        cycles.append(tuple(int(getattr(dut, f"RX_MFB_{s}").value) for s in ("SRC_RDY", "DATA", "SOF", "EOF")))
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_hold_on_idle_test(dut):
    """With hold_on_idle, the idle words inside and between frames keep the last word on the bus and drop SRC_RDY
    only."""
    await start(dut)
    geo = mfb_geometry(dut)
    blocks = geo.regions * geo.region_size
    word_bytes = geo.word_width // 8
    rng = random.Random(random.getrandbits(64))
    cocotb.start_soon(apply_backpressure(dut.RX_MFB_DST_RDY, dut.CLK, BackpressureConfig(1, 1, 1 - DST_RDY_HIGH), rng))
    pattern = ((blocks, rng.randint(0, GAP_MAX) * blocks) for _ in itertools.count())
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=OnOffIdleGenerator(pattern),
                    hold_on_idle=True)
    for _ in range(WORDS // 4):
        drv.append(MfbTransaction(data=rng.randbytes(rng.randint(1, 4) * word_bytes)))
    cycles = []
    cocotb.start_soon(sample_bus(dut, cycles))
    while drv.pending:
        await ClockCycles(dut.CLK, 100)

    last, idles, errors = None, 0, []
    for n, (src_rdy, *word) in enumerate(cycles):
        if src_rdy:
            last = word
        elif last is not None:
            idles += 1
            if word != last:
                errors.append(n)
    assert idles > 0, "no idle word between the first and the last word"
    assert not errors, f"{len(errors)} idle word(s) changed the bus, first in cycle {errors[0]}"


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


async def collect_words(dut, words):
    """Every accepted MFB word as (DATA, BE), from the word on the bus in the timestep it is started in."""
    while True:
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            words.append((int(dut.RX_MFB_DATA.value), int(dut.RX_MFB_BE.value)))
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_byte_enable_test(dut):
    """BE follows the frame's be, given as an int or a LogicArray, enables every payload byte without it and no byte
    outside a frame."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    words = []
    cocotb.start_soon(collect_words(dut, words))

    cases = []
    for be_form in (int, LogicArray, None):
        data = rng.randbytes(2 * word_bytes)
        be = rng.getrandbits(2 * word_bytes)
        trans = MfbTransaction(data=data)
        if be_form is not None:
            trans.be = be if be_form is int else LogicArray.from_unsigned(be, 2 * word_bytes)
        else:
            be = (1 << (2 * word_bytes)) - 1
        cases.append((trans, 2, int.from_bytes(data, "little"), be))
    short = rng.randbytes(12)
    cases.append((MfbTransaction(data=short), 1, int.from_bytes(short, "little"), (1 << 12) - 1))
    for trans, _, _, _ in cases:
        await drv.send(trans)
    await ClockCycles(dut.CLK, 4)

    expected = []
    for _, n_words, data, be_value in cases:
        for w in range(n_words):
            expected.append(((data >> (w * word_bytes * 8)) & ((1 << (word_bytes * 8)) - 1),
                             (be_value >> (w * word_bytes)) & ((1 << word_bytes) - 1)))
    assert words == expected, f"{len(words)} words sent, expected {len(expected)}; first difference at " \
        f"{next((k for k, (a, b) in enumerate(zip(words, expected)) if a != b), min(len(words), len(expected)))}"
    await ReadOnly()
    assert int(dut.RX_MFB_BE.value) == 0, "BE left set on the parked bus"


async def collect_eof_pos(dut, regions, words):
    """Every accepted MFB word as (DATA, the EOF_POS of region 0), from the word on the bus in the timestep it is
    started in."""
    while True:
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            eof_pos = str(dut.RX_MFB_EOF_POS.value)
            words.append((int(dut.RX_MFB_DATA.value), int(eof_pos[-(len(eof_pos) // regions):], 2)))
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_geometry_test(dut):
    """The geometry comes from mfb_params, as MfbParams or a dict, or from the generics, or without either from the
    signal widths. The given mfb_params have 16-bit items, so a frame of four bytes ends in item 1, not 3."""
    await start(dut)
    geo = mfb_geometry(dut)
    wide = MfbParams(geo.regions, geo.region_size, geo.block_size // 2, geo.item_width * 2)
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    forms = {"MfbParams": (dict(mfb_params=wide), 1), "dict": (dict(mfb_params=asdict(wide)), 1),
             "generics": (dict(generics_prefix="MFB"), 3), "widths": ({}, 3)}

    for form, (kwargs, eof_pos) in forms.items():
        drv = MFBDriver(dut, "RX_MFB", dut.CLK, idle_generator=IdleGenerator(), **kwargs)
        words = []
        cocotb.start_soon(collect_eof_pos(dut, geo.regions, words))
        frame = rng.randbytes(4)
        await drv.send(MfbTransaction(data=frame))
        await ClockCycles(dut.CLK, 2)
        assert words == [(int.from_bytes(frame, "little"), eof_pos)], f"geometry from {form}: words {words}"


async def collect_frame_words(dut, words):
    """Every accepted MFB word as (DATA, SOF, EOF), from the word on the bus in the timestep it is started in."""
    while True:
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            words.append((int(dut.RX_MFB_DATA.value), int(dut.RX_MFB_SOF.value), int(dut.RX_MFB_EOF.value)))
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_sof_after_eof_test(dut):
    """A frame starts in the region where the previous one ends when it does not end there as well; one that would
    end there too starts in the next region."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    region_bytes = word_bytes // geo.regions
    block_bytes = geo.block_size * geo.item_width // 8
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    words = []
    cocotb.start_soon(collect_frame_words(dut, words))

    # A ends in block 0 of the second word, B fills the rest of that region and ends in the next one, where C,
    # a block long, cannot follow it.
    a = rng.randbytes(word_bytes + block_bytes)
    b = rng.randbytes(region_bytes)
    c = rng.randbytes(block_bytes)
    for frame in (a, b):
        drv.append(MfbTransaction(data=frame))
    await drv.send(MfbTransaction(data=c))
    await ClockCycles(dut.CLK, 2)

    stream = a + b + bytes(word_bytes - region_bytes - block_bytes) + c
    expected = [(int.from_bytes(stream[0:word_bytes], "little"), 0b01, 0b00),
                (int.from_bytes(stream[word_bytes:2 * word_bytes], "little"), 0b01, 0b11),
                (int.from_bytes(stream[2 * word_bytes:], "little"), 0b01, 0b01)]
    assert words == expected, f"words as (DATA, SOF, EOF): {[(hex(d), s, e) for d, s, e in words]}"


@cocotb.test()
async def run_mfb_transaction_forms_test(dut):
    """A frame is an MfbTransaction with bytes or a LogicArray as data, or plain bytes or a LogicArray; frame_cnt and
    item_cnt count the accepted ones."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    words = []
    cocotb.start_soon(collect_frame_words(dut, words))

    payloads = [rng.randbytes(word_bytes) for _ in range(5)]
    forms = [MfbTransaction(data=payloads[0]), MfbTransaction(data=LogicArray.from_bytes(payloads[1], byteorder="little")),
             payloads[2], bytearray(payloads[3]), LogicArray.from_bytes(payloads[4], byteorder="little")]
    for form in forms:
        await drv.send(form)
    await ClockCycles(dut.CLK, 2)

    assert words == [(int.from_bytes(p, "little"), 1, 1 << (geo.regions - 1)) for p in payloads], \
        f"words as (DATA, SOF, EOF): {[(hex(d), s, e) for d, s, e in words]}"
    assert drv.frame_cnt == len(forms) and drv.item_cnt == len(forms) * word_bytes * 8 // geo.item_width


async def collect_bus_words(dut, words):
    """Every accepted MFB word as the bit strings of its signals, from the word on the bus in the timestep it is started
    in."""
    while True:
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            words.append(tuple(str(getattr(dut, f"RX_MFB_{s}").value) for s in ("DATA", "SOF", "EOF", "SOF_POS", "EOF_POS", "BE")))
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_word_test(dut):
    """MfbWord words go on the bus as given, after the open word of a frame; item_cnt and the default BE follow their
    SOF, EOF and positions."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    region_items = geo.region_size * geo.block_size
    eof_width = len(dut.RX_MFB_EOF_POS) // geo.regions
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    words = []
    cocotb.start_soon(collect_bus_words(dut, words))

    frame = rng.randbytes(3)
    first = MfbWord(data=rng.getrandbits(geo.word_width), sof=0b01, sof_pos=1)
    last = MfbWord(data=rng.getrandbits(geo.word_width), eof=1 << (geo.regions - 1),
                   eof_pos=5 << ((geo.regions - 1) * eof_width), be=0x1234)
    drv.append(MfbTransaction(data=frame))
    drv.append(first)
    await drv.send(last)
    await ClockCycles(dut.CLK, 2)

    def bits(value, width):
        return format(value, f"0{width}b")

    sof_pos_x = "X" * len(dut.RX_MFB_SOF_POS)
    eof_pos_x = "X" * len(dut.RX_MFB_EOF_POS)
    # the first word covers the region of its SOF from block 1 on and every region after it
    first_be = ((1 << word_bytes) - 1) & ~((1 << geo.block_size * geo.item_width // 8) - 1)
    expected = [
        (bits(int.from_bytes(frame, "little"), geo.word_width), bits(1, geo.regions), bits(1, geo.regions),
         sof_pos_x[:-2] + "00", eof_pos_x[:-eof_width] + bits(2, eof_width), bits((1 << 3) - 1, word_bytes)),
        (bits(first.data, geo.word_width), bits(1, geo.regions), bits(0, geo.regions), bits(1, len(sof_pos_x)),
         eof_pos_x, bits(first_be, word_bytes)),
        (bits(last.data, geo.word_width), bits(0, geo.regions), bits(last.eof, geo.regions), sof_pos_x,
         bits(last.eof_pos, len(eof_pos_x)), bits(0x1234, word_bytes)),
    ]
    assert words == expected, f"words as (DATA, SOF, EOF, SOF_POS, EOF_POS, BE): {words}"
    assert drv.frame_cnt == 2
    assert drv.item_cnt == 3 + (geo.regions * region_items - geo.block_size) + (geo.regions - 1) * region_items + 6


@cocotb.test()
async def run_mfb_monitor_read_only_test(dut):
    """A monitor sampling at ReadOnly receives the frames of one sampling at the edge a clock earlier, as the word an
    edge accepts settles after the edge before; started with the driver, it reads the word the first edge takes."""
    await start(dut)
    geo = mfb_geometry(dut)
    rng = random.Random(random.getrandbits(64))
    dut.RX_MFB_DST_RDY.value = 1
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    received = {}
    for read_only in (False, True):
        mon = MFBMonitor(dut, "RX_MFB", dut.CLK, mfb_params=asdict(geo), read_only=read_only)
        received[read_only] = []
        mon.add_callback(lambda tr, got=received[read_only]: got.append((get_sim_time("ns"), tr)))

    frames = [rng.randbytes(rng.randint(1, 3 * geo.word_width // 8)) for _ in range(50)]
    for frame in frames:
        drv.append(MfbTransaction(data=frame))
    await RisingEdge(dut.CLK)
    cocotb.start_soon(apply_backpressure(dut.RX_MFB_DST_RDY, dut.CLK, BackpressureConfig(1, 4, 0.5), rng))
    while drv.pending:
        await ClockCycles(dut.CLK, 10)
    await ClockCycles(dut.CLK, 2)

    assert [tr for _, tr in received[False]] == frames
    assert [tr for _, tr in received[True]] == frames
    assert all(edge - read_only == CLK_NS for (edge, _), (read_only, _) in zip(received[False], received[True]))


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
    """Every accepted MFB word as (DATA, SOF), from the word on the bus in the timestep it is started in."""
    while True:
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            words.append((int(dut.RX_MFB_DATA.value), int(dut.RX_MFB_SOF.value)))
        await RisingEdge(dut.CLK)


@cocotb.test()
async def run_mfb_abort_test(dut):
    """A send cancelled under backpressure leaves the rest of its frame in the driver; after abort() the bus is
    parked and the next frame arrives whole, from its SOF on."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    stalled = cocotb.start_soon(drv.send(MfbTransaction(data=rng.randbytes(4 * word_bytes))))
    drv.append(MfbTransaction(data=rng.randbytes(word_bytes)))
    await ClockCycles(dut.CLK, 4)
    stalled.cancel()
    drv.abort()
    assert drv.pending == 0, f"{drv.pending} frame(s) pending after abort()"
    await ReadOnly()
    assert int(dut.RX_MFB_SRC_RDY.value) == 0, "abort() left SRC_RDY high"

    await RisingEdge(dut.CLK)
    dut.RX_MFB_DST_RDY.value = 1
    words = []
    cocotb.start_soon(collect_sof_words(dut, words))
    frame = rng.randbytes(2 * word_bytes)
    await drv.send(MfbTransaction(data=frame))
    await ClockCycles(dut.CLK, 4)

    expected = [(int.from_bytes(frame[:word_bytes], "little"), 1), (int.from_bytes(frame[word_bytes:], "little"), 0)]
    assert words == expected, f"{len(words)} word(s) after abort(), first as (DATA, SOF): " \
        f"{(hex(words[0][0]), words[0][1]) if words else None}"


@cocotb.test()
async def run_mfb_clear_test(dut):
    """clear() drops the frames the driver has not started; the one on the bus is sent whole."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    rng = random.Random(random.getrandbits(64))
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", idle_generator=IdleGenerator())
    words = []
    cocotb.start_soon(collect_sof_words(dut, words))

    started = rng.randbytes(2 * word_bytes)
    drv.append(MfbTransaction(data=started))
    for _ in range(3):
        drv.append(MfbTransaction(data=rng.randbytes(word_bytes)), event=Event())
    await ClockCycles(dut.CLK, 2)
    assert drv.queued == 3
    drv.clear()
    assert drv.queued == 0 and drv.pending == 1 and not drv._waiters
    dut.RX_MFB_DST_RDY.value = 1
    await ClockCycles(dut.CLK, 6)

    expected = [(int.from_bytes(started[:word_bytes], "little"), 1), (int.from_bytes(started[word_bytes:], "little"), 0)]
    assert words == expected, f"{len(words)} word(s) after clear(), first as (DATA, SOF): " \
        f"{(hex(words[0][0]), words[0][1]) if words else None}"
    assert drv.pending == 0


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
    are set then; pending counts the frames not yet accepted and queued the ones not yet started."""
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
    assert drv.pending == drv.queued == len(events)
    await ClockCycles(dut.CLK, 2)
    assert drv.queued < len(events), "the driver took up no frame"
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
