# cocotb_test.py: does FS_RING_FETCH deliver every published ring entry once, in order?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""A Python stand-in for FS_HBM_PORT's client side (random FREQ_RDY, in-order bursts after a random
latency, gaps between beats) over a memory the host model fills; ENT_RDY toggled at random."""

import os
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Timer, ClockCycles
from cocotb.utils import get_sim_time

from fs_ctx import AXI_BEAT, ENTRY_BYTES
from fs_ring_fetch_model import RingFetchModel
from fs_tb_util import CLK_NS, release_reset, seeded, settle, start_clock

LOG2_DEPTH = int(os.environ.get("LOG2_DEPTH", 9))
RING_BASE = int(os.environ.get("RING_BASE", 0x3000))
FIFO_ENTRIES = int(os.environ.get("FIFO_ENTRIES", 64))


class Env:
    def __init__(self, dut, salt):
        self.dut = dut
        self.rng = seeded(salt)
        self.model = RingFetchModel(LOG2_DEPTH, RING_BASE)
        self.mem = {}
        self.inflight = deque()
        self.next_lo = 0       # accepted bursts: [beats data list]
        self.errors = []
        self.freq_rdy_prob = 0.5
        self.ent_rdy_prob = 0.5
        self.beat_gap_prob = 0.2
        self.lat = (2, 40)
        self.cov = {"bursts": 0, "page_end": 0, "full16": 0, "odd_start": 0, "pops": 0,
                    "dropped_in_flight": 0, "ent_stall": 0, "short_bursts": 0}
        start_clock(dut)
        dut.RESET.value = 1
        dut.CLEAR.value = 0
        dut.ENABLE.value = 0
        dut.TAIL.value = 0
        dut.FREQ_RDY.value = 0
        dut.FRSP_VLD.value = 0
        dut.FRSP_DATA.value = 0
        dut.FRSP_LAST.value = 0
        dut.ENT_RDY.value = 0

    async def reset(self):
        await release_reset(self.dut, 8, 2)
        cocotb.start_soon(self._req_side())
        cocotb.start_soon(self._rsp_side())
        cocotb.start_soon(self._consumer())

    # Host side -----------------------------------------------------------------------------------
    def entry_bytes(self, i):
        return self.mem.get(RING_BASE + (i % self.model.depth) * ENTRY_BYTES, bytes(ENTRY_BYTES))

    def publish(self, n):
        """Writes up to n entries the ring has room for, then raises TAIL."""
        room = self.model.depth - (self.model.tail - self.model.popped)
        n = min(n, room)
        for _ in range(n):
            content = self.rng.randbytes(ENTRY_BYTES)
            self.mem[self.model.publish(content)] = content
        self.dut.TAIL.value = self.model.tail
        return n

    def read_mem(self, addr):
        return b"".join(self.mem.get(addr + k * ENTRY_BYTES, bytes(ENTRY_BYTES)) for k in range(AXI_BEAT // ENTRY_BYTES))

    # FS_HBM_PORT stand-in ------------------------------------------------------------------------
    async def _req_side(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            if int(d.FREQ_VLD.value) and int(d.FREQ_RDY.value):
                addr = int(d.FREQ_ADDR.value)
                beats = int(d.FREQ_BEATS.value)
                tail = int(d.TAIL.value)
                # A burst accepted in the CLEAR cycle was computed for the old ring; it is discarded.
                errs = [] if int(d.CLEAR.value) else self.model.check_burst(addr, beats, tail)
                self.errors += errs
                first = None if int(d.CLEAR.value) else self.model.last_first
                if first is not None and first < self.next_lo:
                    self.cov["odd_start"] += 1
                if first is not None:
                    self.next_lo = first + 2 * beats
                self.cov["bursts"] += 1
                if (addr + beats * AXI_BEAT) % 4096 == 0:
                    self.cov["page_end"] += 1
                if beats == 16:
                    self.cov["full16"] += 1
                if beats < 4:
                    self.cov["short_bursts"] += 1
                data = [self.read_mem(addr + k * AXI_BEAT) for k in range(beats)]
                due = self.now + self.rng.randrange(*self.lat)
                self.inflight.append((due, data))
            await Timer(1, unit="ns")
            d.FREQ_RDY.value = int(self.rng.random() < self.freq_rdy_prob)

    @property
    def now(self):
        return int(get_sim_time("ns")) // CLK_NS

    async def _rsp_side(self):
        d = self.dut
        cur = None
        while True:
            await settle(d)
            d.FRSP_VLD.value = 0
            d.FRSP_LAST.value = 0
            if cur is None and self.inflight and self.inflight[0][0] <= self.now:
                cur = list(self.inflight.popleft()[1])
            if cur is not None and self.rng.random() >= self.beat_gap_prob:
                d.FRSP_DATA.value = int.from_bytes(cur.pop(0), "little")
                d.FRSP_VLD.value = 1
                d.FRSP_LAST.value = int(not cur)
                if not cur:
                    cur = None
            elif self.rng.random() < 0.5:
                d.FRSP_DATA.value = self.rng.getrandbits(256)

    # Consumer ------------------------------------------------------------------------------------
    async def _consumer(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            if int(d.RESET.value) or int(d.CLEAR.value):
                pass
            elif int(d.ENT_VLD.value) and int(d.ENT_RDY.value):
                if self.model.popped >= self.model.tail:
                    self.errors.append(f"entry popped beyond TAIL {self.model.tail}")
                else:
                    want, head = self.model.pop()
                    got = int(d.ENT_DATA.value).to_bytes(ENTRY_BYTES, "little")
                    if got != want:
                        self.errors.append(f"entry {head - 1}: got {got.hex()}, expected {want.hex()}")
                    self.cov["pops"] += 1
            elif int(d.ENT_VLD.value):
                self.cov["ent_stall"] += 1
            if not int(d.RESET.value) and not int(d.CLEAR.value):
                if int(d.HEAD.value) != (self.model.popped if not
                                         (int(d.ENT_VLD.value) and int(d.ENT_RDY.value)) else self.model.popped - 1):
                    self.errors.append(f"HEAD {int(d.HEAD.value)} != popped {self.model.popped}")
            await Timer(1, unit="ns")
            d.ENT_RDY.value = int(self.rng.random() < self.ent_rdy_prob)

    def check(self):
        assert not self.errors, "\n".join(self.errors[:20])

    async def drain(self, timeout=40000):
        for _ in range(timeout):
            if self.model.popped == self.model.tail:
                break
            await RisingEdge(self.dut.CLK)
        await ClockCycles(self.dut.CLK, 60)
        assert self.model.popped == self.model.tail, f"popped {self.model.popped} of {self.model.tail}"
        assert int(self.dut.ENT_VLD.value) == 0, "ENT_VLD with nothing left below TAIL"
        assert int(self.dut.HEAD.value) == self.model.tail
        self.check()

    async def clear(self):
        """CLEAR as FS_REGS gives it: tails zeroed in the same cycle."""
        await settle(self.dut)
        self.cov["dropped_in_flight"] += len(self.inflight)
        self.dut.CLEAR.value = 1
        self.dut.TAIL.value = 0
        self.model.clear()
        self.next_lo = 0
        await settle(self.dut)
        self.dut.CLEAR.value = 0


@cocotb.test()
async def test_stream_random(dut):
    """Random publishing (odd tails, bursts of entries), ring wraps, random back-pressure."""
    env = Env(dut, 1)
    await env.reset()
    dut.ENABLE.value = 1
    total = env.model.depth * 3 + env.rng.randrange(env.model.depth)
    sent = 0
    while sent < total:
        env.freq_rdy_prob = env.rng.choice([0.2, 0.6, 1.0])
        env.ent_rdy_prob = env.rng.choice([0.1, 0.5, 1.0])
        sent += env.publish(env.rng.choice([1, 1, 2, 3, env.rng.randrange(1, 80)]))
        await ClockCycles(dut.CLK, env.rng.randrange(0, 60))
        env.check()
    await env.drain()
    dut._log.info(f"coverage: {env.cov}")
    assert env.cov["page_end"] > 0 and env.cov["full16"] > 0 and env.cov["odd_start"] > 0
    assert env.model.popped > env.model.depth


@cocotb.test()
async def test_enable_gating(dut):
    """Nothing is requested while ENABLE is low; fetching resumes where it stopped."""
    env = Env(dut, 2)
    await env.reset()
    env.ent_rdy_prob = 1.0
    env.publish(40)
    await ClockCycles(dut.CLK, 50)
    assert env.cov["bursts"] == 0, "burst requested while ENABLE is low"
    dut.ENABLE.value = 1
    await env.drain()
    dut.ENABLE.value = 0
    await ClockCycles(dut.CLK, 10)
    env.publish(33)
    await ClockCycles(dut.CLK, 50)
    before = env.cov["bursts"]
    await ClockCycles(dut.CLK, 50)
    assert env.cov["bursts"] == before, "burst requested while ENABLE is low"
    dut.ENABLE.value = 1
    await env.drain()


@cocotb.test()
async def test_clear_with_bursts_in_flight(dut):
    """CLEAR while bursts are in flight: their late beats are dropped, the new ring starts at 0."""
    env = Env(dut, 3)
    await env.reset()
    dut.ENABLE.value = 1
    env.lat = (30, 80)
    for rnd in range(6):
        env.ent_rdy_prob = env.rng.choice([0.0, 0.3, 1.0])
        env.publish(env.rng.randrange(20, 200))
        for _ in range(400):
            await RisingEdge(dut.CLK)
            if env.inflight:
                break
        await ClockCycles(dut.CLK, env.rng.randrange(0, 10))
        await env.clear()
        env.ent_rdy_prob = env.rng.choice([0.3, 1.0])
        env.publish(env.rng.randrange(1, 150))
        await env.drain()
    dut._log.info(f"coverage: {env.cov}")
    assert env.cov["dropped_in_flight"] > 0


@cocotb.test()
async def test_full_fifo_backpressure(dut):
    """A stalled consumer: the FIFO fills to FIFO_ENTRIES and no more is requested."""
    env = Env(dut, 4)
    await env.reset()
    dut.ENABLE.value = 1
    env.ent_rdy_prob = 0.0
    env.freq_rdy_prob = 1.0
    env.publish(env.model.depth)
    await ClockCycles(dut.CLK, 300)
    bursts = env.cov["bursts"]
    await ClockCycles(dut.CLK, 300)
    assert env.cov["bursts"] == bursts, "bursts requested with the FIFO full and no pops"
    assert not env.inflight, "bursts still in flight after 600 cycles"
    assert int(dut.ENT_VLD.value) == 1
    env.check()
    env.ent_rdy_prob = 1.0
    await env.drain()
