# cocotb_test.py: MFB and MVB driver behaviour against a sink that drops DST_RDY at random
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Each driver sends whole words split by scripted idle words while the sink drops DST_RDY at random. Words
must arrive once, in order and held while waiting, and each gap must last exactly its idle words. The fast MFB driver
is also checked for byte enables."""

import itertools
import random
from dataclasses import asdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
from cocotb.types import LogicArray

from cocotbext.ofm.base.generators import IdleGenerator
from cocotbext.ofm.base.transaction import IdleTransactionFactory
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.fast_drivers import MFBDriver as FastMFBDriver
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
async def run_fast_mfb_idle_words_test(dut):
    """One-word frames; the valid generator ends each frame with its scripted number of whole idle words."""
    await start(dut)
    geo = mfb_geometry(dut)
    blocks = geo.regions * geo.region_size
    rng = random.Random(random.getrandbits(64))
    gaps = [rng.randint(0, GAP_MAX) for _ in range(WORDS)]
    vld_gen = itertools.chain(((blocks, g * blocks) for g in gaps), itertools.repeat((blocks, 0)))
    drv = FastMFBDriver(dut, "RX_MFB", dut.CLK, mfb_params=asdict(geo), vld_gen=vld_gen)
    frames = [rng.randbytes(geo.word_width // 8) for _ in range(WORDS)]
    for f in frames:
        drv.append(f)
    await run(dut, "RX_MFB", [int.from_bytes(f, "little") for f in frames], gaps)


@cocotb.test()
async def run_mfb_idle_words_test(dut):
    """One-word frames; the idle generator puts the scripted idle transactions before each frame."""
    await start(dut)
    geo = mfb_geometry(dut)
    rng = random.Random(random.getrandbits(64))
    gaps = [rng.randint(0, GAP_MAX) for _ in range(WORDS)]
    drv = MFBDriver(dut, "RX_MFB", dut.CLK, generics_prefix="MFB", no_default_rate_limiter=True,
                    idle_factory=IdleTransactionFactory(1, 1))
    drv.set_idle_generator(ScriptedIdles(gaps))
    frames = [rng.randbytes(geo.word_width // 8) for _ in range(WORDS)]
    for f in frames:
        drv.append(MfbTransaction(data=f))
    await run(dut, "RX_MFB", [int.from_bytes(f, "little") for f in frames], gaps[1:] + [0])


async def collect_words(dut, words):
    """Every accepted MFB word as (DATA, BE)."""
    while True:
        await RisingEdge(dut.CLK)
        await ReadOnly()
        if int(dut.RX_MFB_SRC_RDY.value) and int(dut.RX_MFB_DST_RDY.value):
            words.append((int(dut.RX_MFB_DATA.value), int(dut.RX_MFB_BE.value)))


@cocotb.test()
async def run_fast_mfb_byte_enable_test(dut):
    """BE follows an explicit value, defaults to all payload bytes enabled, and accepts LogicArray payloads."""
    await start(dut)
    geo = mfb_geometry(dut)
    word_bytes = geo.word_width // 8
    dut.RX_MFB_DST_RDY.value = 1
    rng = random.Random(random.getrandbits(64))
    drv = FastMFBDriver(dut, "RX_MFB", dut.CLK, mfb_params=asdict(geo), vld_gen=None)
    words = []
    cocotb.start_soon(collect_words(dut, words))

    explicit = rng.randbytes(2 * word_bytes)
    be = rng.getrandbits(2 * word_bytes)
    unset = rng.randbytes(2 * word_bytes)
    short = rng.randbytes(12)
    explicit_trans = MfbTransaction(data=explicit)
    explicit_trans.be = be
    cases = [
        (explicit_trans, 2, int.from_bytes(explicit, "little"), be),
        (MfbTransaction(data=unset), 2, int.from_bytes(unset, "little"), (1 << (2 * word_bytes)) - 1),
        (MfbTransaction(data=LogicArray.from_bytes(short, byteorder="little")), 1, int.from_bytes(short, "little"),
         (1 << 12) - 1),
    ]
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
