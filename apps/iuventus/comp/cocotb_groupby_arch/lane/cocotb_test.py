# lane_tb.py: does the aggregation lane's read-modify-write bypass actually accumulate?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
import random
from collections import defaultdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

SLOTS = 4096
SUM_MASK = (1 << 64) - 1


async def prepare(dut):
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    dut.IN_VLD.value = 0
    dut.IN_SLOT.value = 0
    dut.IN_VALUE.value = 0
    dut.CLEAR_EN.value = 0
    dut.CLEAR_ADDR.value = 0
    dut.SWEEP_EN.value = 0
    dut.SWEEP_ADDR.value = 0
    dut.RST.value = 1
    await ClockCycles(dut.CLK, 8)
    dut.RST.value = 0
    await RisingEdge(dut.CLK)
    # The table holds whatever the memory powered up with, so a run must clear it first.
    for a in range(SLOTS):
        dut.CLEAR_EN.value = 1
        dut.CLEAR_ADDR.value = a
        await RisingEdge(dut.CLK)
    dut.CLEAR_EN.value = 0
    await RisingEdge(dut.CLK)


async def feed(dut, records, gaps=False):
    """Drive (slot, value) pairs, optionally with idle cycles between them."""
    rnd = random.Random(7)
    for slot, value in records:
        dut.IN_SLOT.value = slot
        dut.IN_VALUE.value = value
        dut.IN_VLD.value = 1
        await RisingEdge(dut.CLK)
        if gaps and rnd.random() < 0.4:
            dut.IN_VLD.value = 0
            await ClockCycles(dut.CLK, rnd.randint(1, 3))
    dut.IN_VLD.value = 0
    # Let the two pipeline stages retire.
    await ClockCycles(dut.CLK, 6)
    await ReadOnly()
    assert str(dut.DRAINED.value) == "1", "lane still busy after the pipeline should have drained"


async def check(dut, expect):
    """Sweep every touched slot and compare sum and count against the model."""
    await RisingEdge(dut.CLK)
    for slot, (exp_sum, exp_cnt) in sorted(expect.items()):
        dut.SWEEP_ADDR.value = slot
        dut.SWEEP_EN.value = 1
        await RisingEdge(dut.CLK)
        dut.SWEEP_EN.value = 0
        await ReadOnly()
        got_sum = int(dut.SWEEP_SUM.value)
        got_cnt = int(dut.SWEEP_CNT.value)
        assert got_sum == exp_sum, f"slot {slot}: sum {got_sum} != {exp_sum}"
        assert got_cnt == exp_cnt, f"slot {slot}: count {got_cnt} != {exp_cnt}"
        await RisingEdge(dut.CLK)


def model(records):
    acc = defaultdict(lambda: [0, 0])
    for slot, value in records:
        acc[slot][0] = (acc[slot][0] + value) & SUM_MASK
        acc[slot][1] += 1
    return {k: (v[0], v[1]) for k, v in acc.items()}


@cocotb.test()
async def test_cleared_table_reads_zero(dut):
    """A clear must leave every slot at zero, or a run accumulates onto stale data."""
    await prepare(dut)
    await check(dut, {s: (0, 0) for s in (0, 1, 17, 4095)})


@cocotb.test()
async def test_distinct_slots(dut):
    """The easy case: no two consecutive records share a slot, so the bypass never fires."""
    await prepare(dut)
    recs = [(i, i * 3 + 1) for i in range(64)]
    await feed(dut, recs)
    await check(dut, model(recs))


@cocotb.test()
async def test_back_to_back_same_slot(dut):
    """The case the bypass exists for: every record hits one slot on consecutive cycles.

    Without forwarding, each read returns the value from before its predecessor's write and all
    but the last increment is lost -- the sum would come out as the final value alone.
    """
    await prepare(dut)
    recs = [(123, 1) for _ in range(32)]
    await feed(dut, recs)
    await check(dut, {123: (32, 32)})


@cocotb.test()
async def test_alternating_two_slots(dut):
    """Two slots interleaved, so the bypass must match on address rather than merely on age."""
    await prepare(dut)
    recs = [(5 if i % 2 == 0 else 6, i + 1) for i in range(40)]
    await feed(dut, recs)
    await check(dut, model(recs))


@cocotb.test()
async def test_random_with_gaps(dut):
    """Random slots and idle cycles: the general case, against a Python model."""
    await prepare(dut)
    rnd = random.Random(cocotb.RANDOM_SEED & 0xFFFF)
    recs = [(rnd.randrange(SLOTS), rnd.randrange(1 << 32)) for _ in range(600)]
    await feed(dut, recs, gaps=True)
    await check(dut, model(recs))


@cocotb.test()
async def test_hot_slot_under_random(dut):
    """One slot taking most of the traffic, the shape key skew produces."""
    await prepare(dut)
    rnd = random.Random(99)
    recs = [(7 if rnd.random() < 0.8 else rnd.randrange(SLOTS), rnd.randrange(1000))
            for _ in range(500)]
    await feed(dut, recs)
    await check(dut, model(recs))
