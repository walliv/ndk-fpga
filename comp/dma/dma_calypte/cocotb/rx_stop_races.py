# rx_stop_races.py: directed RX stop tests driven by the ndp tools' software model
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Three RX stop scenarios: the stale stop comparison, a stale SDP that fills the stopping channel's own ring
while one of its packets is in progress, and ndptool's exit with every queue stopping at once under traffic."""

import os
import random
from collections import Counter

import cocotb
from cocotb.triggers import ClockCycles, Timer

from cocotbext.ofm.utils.signals import signal_binstr, signal_int

from checkers import BenchError
from cocotb_test import _now
from rx_full_buffer import RxHolBench
from rx_start_stop import S_PACKET_PROCESS, STOP_WAIT_FOR_POINTERS, RxStartStopBench

STALE_HIT = "stop slot open while the stop comparator still shows the pointers before their last write"


class RxStaleStopBench(RxStartStopBench):
    """Stops of a just started channel (SDP/SHP = HDP/HHP) against one packet of it swept cycle by cycle, so that its
    pointer write lands after the dispatch read, inside the comparator latency, on the channel's slot."""

    def __init__(self, dut):
        super().__init__(dut, "SOF")
        self.stale_cycles = 0

    def stale_probe(self):
        """Mid-cycle, where the DSP comparator outputs have settled: the stop FSM waits for the pointers, the slot is
        open and the comparator says equal, yet its inputs (the current register values) differ."""
        sw = self.swm
        cmps = (sw.dsp_comp_hdp_i, sw.dsp_comp_hhp_i)

        def cycle_probe():
            if (int(sw.stop_fsm_pst.value) == STOP_WAIT_FOR_POINTERS and signal_binstr(sw.stop_chan_ok) == "1"
                    and signal_binstr(sw.stop_ptr_ok) == "1"
                    and any(signal_int(c.INPUT_1) != signal_int(c.INPUT_2) for c in cmps)):
                self.hits[STALE_HIT] += 1
        self.on_cycle(cycle_probe, falling=True)

    # A packet decided after the stop take is dropped, and its first allocation follows its decision by about 4 cycles,
    # so the comparator latency can meet the channel's next slot only while slots are this close.
    REACHABLE_CHANNELS = 8

    def required_hits(self, kind):
        if self.rx_ch <= self.REACHABLE_CHANNELS:
            return [STALE_HIT]
        if kind == "stop" and not self.hits[STALE_HIT]:
            self.log.warning(f"stale comparator race not required with {self.rx_ch} channels: the slot after a stop take "
                             f"comes {self.rx_ch} cycles later, beyond a packet's first allocation (hits "
                             f"{self.hits[STALE_HIT]})")
        return []

    async def sweep(self):
        """Alternates the smallest packet with one lasting about a round-robin period, whose late block requests can
        reach the comparator latency on the slot that comes CHANNELS cycles after the stop take."""
        self.stale_probe()
        span = 2 * self.rx_ch + 16
        wb = self.word_bytes
        passes = int(os.environ.get("CALYPTE_STALE_PASSES", "8"))
        for npass in range(1, passes + 1):
            ch = self.rng.randrange(self.rx_ch)
            size = 60 if npass % 2 else min(4096, max(60, self.rng.randint((self.rx_ch - 1) * wb, (self.rx_ch + 2) * wb)))
            for off in range(-8, span + 1):
                await self.iteration("stop", ch, off, size)
            self.passes["stop"] = npass
            self.spans.append(("stop", ch, size, 0, span))
            if self.hits[STALE_HIT]:
                break


class RxStaleSdpBench(RxHolBench):
    """Channel c (16-block data ring) with its allocation pointer near the ring end stops while a long packet of it
    enters: the stop loop's stale SDP = 0, or an unflushed userspace SDP, holds c's own next block request."""

    HIT = "c's own request held on its ring while a packet of c is in progress and its stop runs"

    def __init__(self, dut):
        super().__init__(dut, "EOF")
        self.iterations = int(os.environ.get("CALYPTE_STALE_SDP_ITER", "8"))
        self.stopping = None
        self.results = []

    def held_probe(self):
        h = self.hdrm

        def cycle_probe():
            c = self.stopping
            if c is None:
                return
            if (self.held["data"] == c and int(h.pkt_process_pst.value) == S_PACKET_PROCESS
                    and signal_int(h.pkt_chan_reg) == c):
                self.hol_hits[f"{self.HIT} ({self.queues[c].mode})"] += 1
                self.stopping = None
        self.on_cycle(cycle_probe, falling=True)

    async def iteration(self, n):
        self.iter_violations = []
        c = self.rng.randrange(self.rx_ch)
        q = self.queues[c]
        q.mode = ("kernel", "userspace")[n % 2]
        await self.start_channel(c, data_mask=15, hdr_mask=255)
        q.start_consumer()
        k = self.rng.randint(9, 13)
        before = q.stats["consumed"]
        for _ in range(k):
            self.send(c, self.rng.randint(60, 128))
        await self.quiesce(f"iteration {n}: {k} packets of ch{c}")
        while q.stats["consumed"] < before + k:
            await Timer(200, "ns")
        await q.stop_consumer()
        blocks = self.rng.randint(16 - k, 15)
        size = blocks * 128 - self.rng.randint(0, 60)
        # The packet must be decided before the stop is taken and must ask for the block at the ring end only after
        # the stale SDP write, which is the loop's first MI write; its blocks arrive every 128 B of bus words.
        per_block = -(-128 // self.word_bytes)
        off = self.rng.randint(-(15 - k) * per_block + 2, 4)
        self.stopping = c

        async def traffic():
            if off > 0:
                await ClockCycles(self.clk, off)
            self.send(c, size)
            for _ in range(self.rng.randint(1, 3)):
                await ClockCycles(self.clk, self.rng.randint(0, 40))
                self.send(c, self.rng.randint(60, 512))

        if off < 0:
            cocotb.start_soon(traffic())
            await ClockCycles(self.clk, -off)
        else:
            cocotb.start_soon(traffic())
        lat, it = await q.stop(self.bound_ns, _now)
        held = self.stopping is None
        self.stopping = None
        rec = {"n": n, "ch": c, "mode": q.mode, "k": k, "blocks": blocks, "offset": off, "held": held, "stop_ns": lat,
               "iterations": it}
        self.results.append(rec)
        if lat is None:
            msg = (f"iteration {n}: stop of ch{c} ({q.mode}, {k} blocks consumed, {blocks}-block packet at offset "
                   f"{off}) not complete {self.bound_ns} ns after the request; {self.fsm_dump()}")
            self.log.error(msg)
            raise BenchError(msg)
        self.running[c] = False
        await self.quiesce(f"iteration {n}: ch{c} stopped")
        await self.check_pointers("stop", c)
        self.log.info(f"iteration {n}: ch{c} {q.mode}, {k} blocks consumed, {blocks}-block packet at offset {off}: "
                      f"{'own request held during the stop, ' if held else ''}stopped after {lat} ns in {it} "
                      f"iteration(s), contract {len(self.iter_violations) or 'ok'}")
        for v in self.iter_violations:
            self.failures.append(f"iteration {n} (ch{c}): {v}")

    async def run(self):
        await self.bring_up()
        self.probe()
        self.hol_probe()
        self.held_probe()
        await ClockCycles(self.clk, 50)
        n = 0
        while n < self.iterations or (not self.hol_hits[f"{self.HIT} (kernel)"] and n < 4 * self.iterations):
            await self.iteration(n)
            n += 1
        await self.finish(lambda: (f"stale SDP stops {self.results} | hits {dict(self.hol_hits)} | failures "
                                   f"{len(self.failures)} | RQ TLPs compared {self.rx_cmp.compared} | {self.rx_ptr_stats()}"),
                          early=lambda: self.failures,
                          late=lambda: ([] if self.hol_hits[f"{self.HIT} (kernel)"]
                                        else [f"hit counter '{self.HIT} (kernel)' never hit in {n} iterations"]))


class RxNdptoolBench(RxHolBench):
    """ndptool with one thread per queue: every RX channel runs with its consumer (kernel or userspace mode) under
    random traffic; at exit every consumer stops and every queue then stops at once, the traffic going on."""

    def __init__(self, dut):
        super().__init__(dut, "EOF")
        self.rounds = int(os.environ.get("CALYPTE_NDPTOOL_ROUNDS", "3"))
        # Queues ndptool opens per round (a random subset), for the wall time of the larger configurations.
        self.queues_per_round = min(self.rx_ch, int(os.environ.get("CALYPTE_NDPTOOL_QUEUES", "16")))
        # The stop FSM serves one channel at a time and each stop needs the driver's next loop iteration, whose
        # 101 STATUS reads share the MI bus with every other stopping queue: a stop may take this long per queue.
        self.us_per_queue = float(os.environ.get("CALYPTE_NDPTOOL_US_PER_QUEUE", "20"))
        self.traffic_on = False
        self.stop_recs = []
        self.held_in_stop = Counter()
        self.stopping = set()

    def held_probe(self):
        """Counts stops during which the stopping channel's own head request was held on its ring (expected with
        the driver's stale SDP write; the stop waits for its next iteration)."""
        seen = set()

        def cycle_probe():
            nonlocal seen
            for kind in ("data", "hdr"):
                c = self.held[kind]
                if c is not None and c in self.stopping and (c, kind) not in seen and self.held_for[kind] >= 4:
                    seen.add((c, kind))
                    self.held_in_stop[kind] += 1
            seen &= {(c, k) for c in self.stopping for k in ("data", "hdr")}
        self.on_cycle(cycle_probe, falling=True)

    async def configure(self, ch):
        await super().configure(ch)
        r, rng = self.rx_regs[ch], self.rng
        # Small rings fill often; a userspace consumer needs more than 32 headers to flush at all.
        low = 6 if self.queues[ch].mode == "userspace" else 4
        await r.write("data_mask", (1 << rng.randint(max(low, 5), 10)) - 1)
        await r.write("hdr_mask", (1 << rng.randint(low, 9)) - 1)

    async def traffic(self):
        rng = random.Random(self.rng.getrandbits(64))
        while self.traffic_on:
            # Traffic for every channel: the ones ndptool did not open drop it.
            ch = rng.randrange(self.rx_ch)
            self.send(ch, rng.randint(60, rng.choice((128, 512, 1500))))
            gap = rng.choice((0, 0, 1, 4, 20, 100))
            await ClockCycles(self.clk, gap + 1)
            while self.usr_rx_drv.frame_cnt + 4 < self.appended and self.traffic_on:
                await ClockCycles(self.clk, 4)

    async def queue_exit(self, ch, rnd, bound_ns):
        q = self.queues[ch]
        delay = self.rng.randint(0, 2000)
        if delay:
            await Timer(delay, "ns")
        await q.stop_consumer()
        self.stopping.add(ch)
        lat, it = await q.stop(bound_ns, _now)
        self.stopping.discard(ch)
        self.stop_recs.append({"round": rnd, "ch": ch, "mode": q.mode, "ns": lat, "iterations": it})
        if lat is not None:
            self.running[ch] = False
        return lat

    async def round(self, rnd):
        self.iter_violations = []
        chans = sorted(self.rng.sample(range(self.rx_ch), self.queues_per_round))
        for ch in chans:
            await self.start_channel(ch)
            self.queues[ch].start_consumer()
        self.traffic_on = True
        gen = cocotb.start_soon(self.traffic())
        await Timer(self.rng.randint(5, 30), "us")
        bound = max(self.bound_ns, int(len(chans) * self.us_per_queue * 1000))
        self.log.info(f"round {rnd}: queues {chans} stop at once, bound {bound} ns per stop")
        exits = [cocotb.start_soon(self.queue_exit(ch, rnd, bound)) for ch in chans]
        lats = []
        for t in exits:
            lats.append(await t)
        await Timer(2, "us")
        self.traffic_on = False
        await gen
        hung = [ch for ch, lat in zip(chans, lats) if lat is None]
        if hung:
            msg = f"round {rnd}: stop of {['ch%d' % ch for ch in hung]} not complete {self.bound_ns} ns after the request; {self.fsm_dump()}"
            self.log.error(msg)
            raise BenchError(msg)
        await self.quiesce(f"round {rnd}: all queues stopped")
        for ch in chans:
            await self.check_pointers("stop", ch)
        recs = [r for r in self.stop_recs if r["round"] == rnd]
        self.log.info(f"round {rnd}: {len(recs)} concurrent stops, ns max {max(r['ns'] for r in recs)}, ns median "
                      f"{sorted(r['ns'] for r in recs)[len(recs) // 2]}, iterations "
                      f"{dict(Counter(r['iterations'] for r in recs))}, contract {len(self.iter_violations) or 'ok'}")
        self.failures += [f"round {rnd}: {v}" for v in self.iter_violations]

    async def run(self):
        await self.bring_up()
        self.probe()
        self.hol_probe()
        self.held_probe()
        await ClockCycles(self.clk, 50)
        for rnd in range(self.rounds):
            await self.round(rnd)
        await self.finish(lambda: (
            f"ndptool exit: {len(self.stop_recs)} stops "
            f"in {self.rounds} rounds, iterations {dict(Counter(r['iterations'] for r in self.stop_recs))}, "
            f"stop ns max {max(r['ns'] for r in self.stop_recs)}, own request held during its stop "
            f"{dict(self.held_in_stop)} | RX packets in {self.appended}, model processed "
            f"{self.rx_model.processed} | failures {len(self.failures)} | RQ TLPs compared "
            f"{self.rx_cmp.compared} | {self.rx_ptr_stats()}"), early=lambda: self.failures)
