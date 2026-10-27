# rx_start_stop.py: directed RX channel start and stop requests against single packets
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""RX channel stops (starts) written through MI at swept offsets against the EOF or SOF of one
processed (dropped) packet, no other RX traffic. Each must complete and keep the software contract;
a grey-box counter proves the hazard cycle was hit."""

import os
import random
from collections import Counter

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.utils.signals import binstr_bit, signal_binstr, signal_handshake, signal_int

from checkers import BenchError
from cocotb_test import CLK_NS, CalypteBench, _now
from pcie_tlp import parse_rq
from rx_driver import RxQueue
from traffic import ndk_rand_dist, pick

SW_POLL_CYCLES = 20
# States of the header manager's packet_process_fsm_t and chan_state_change_t and of the SW manager's stop_fsm_type by
# position, as fsm_state() reads them.
PKT_FSM = ("S_IDLE", "S_PACKET_PROCESS", "S_PACKET_DISCARD")
CHAN_FSM = ("S_IDLE", "S_WAIT_FOR_PKT_END")
STOP_FSM = ("IDLE", "WAIT_FOR_REQ_ACK", "WAIT_FOR_POINTERS", "WAIT_FOR_PTR_UPDATE_DISPATCH")
S_IDLE, S_PACKET_PROCESS, S_PACKET_DISCARD = map(PKT_FSM.index, ("S_IDLE", "S_PACKET_PROCESS", "S_PACKET_DISCARD"))
CHAN_S_IDLE, CHAN_S_WAIT_FOR_PKT_END = map(CHAN_FSM.index, ("S_IDLE", "S_WAIT_FOR_PKT_END"))
STOP_IDLE, STOP_WAIT_FOR_POINTERS, STOP_DISPATCH = map(STOP_FSM.index, ("IDLE", "WAIT_FOR_POINTERS",
                                                                        "WAIT_FOR_PTR_UPDATE_DISPATCH"))


def fsm_state(handle):
    """Position of an enum signal. cocotb 2.1's EnumObject.value wraps positions above 1 on Questa, whose FLI handle
    reports one element where VHPI reports the 8 or 32 bits of the value, so it is read through the GPI value."""
    return handle._handle.get_signal_val_long()


START_WINDOW_HIT = "pointer write before start_acked"
# The SW manager acks a start when its round-robin counter returns to the channel, CHANNELS-1 cycles after
# the header manager takes it; a packet decided right after the take writes its first HDP 6 cycles later.
START_WINDOW_MIN_CHANNELS = 8


class RxStartStopBench(CalypteBench):
    """The MI write is aligned to the SW manager's round-robin channel counter, so the request reaches
    the header manager a fixed number of cycles after it and the swept offset moves the packet one
    cycle per step."""

    KINDS = ("stop", "start")

    def __init__(self, dut, anchor):
        super().__init__(dut, speed=False)
        assert anchor in ("EOF", "SOF")
        self.anchor = anchor
        self.rng = random.Random(random.getrandbits(64))
        self.bound_ns = int(float(os.environ.get("CALYPTE_REQ_BOUND_US", "60")) * 1000)
        self.word_bytes = self.cfg["USR_MFB_REGION_SIZE"] * 8
        self.running = [False] * self.rx_ch
        self.max_passes = int(os.environ.get("CALYPTE_SWEEP_PASSES_MAX", "32"))
        self.passes = {}
        self.spans = []
        self.hits = Counter()
        self.failures = []
        self.appended = 0
        self.last_take = {}
        # Channels whose start the header manager took and the SW manager has not acknowledged yet.
        self.start_window = set()
        # Cycles at which the header manager saw a packet's EOF or decided its header, this iteration.
        self.events = {"EOF": [], "SOF": []}
        # Per channel, the buffers and update address of its last start and when it reported stopped.
        self.episodes = {}
        self.iter_violations = []
        self.contract = Counter()

    def build(self):
        super().build()
        # Single packets at exact cycle offsets: input gaps would blur the offset being swept.
        self.usr_rx_drv.set_valid_generator(None)
        self.rq_out_hooks.append(self._rq_out)
        self.rx_stop_inv.ack_hooks.append(self._stopped)
        self.queues = [RxQueue(ch, self.rx_regs[ch], self.rng.choice(("kernel", "userspace")),
                               random.Random(self.rng.getrandbits(64)), self.log) for ch in range(self.rx_ch)]
        self.log.info(f"software mode per RX queue: {[q.mode for q in self.queues]}")

    # ------------------------------------------------------------------------------------------
    # Grey-box probes
    # ------------------------------------------------------------------------------------------
    def request_takes(self):
        """Returns a function giving, in a read-only phase, the channel of the stop and of the start the header
        manager takes in this cycle (None if none), for the RTL with and without its request queue."""
        h = self.hdrm
        if h._get("stop_req_q_take") is not None:
            self.log.info("header manager with a request queue: takes read from stop_req_q_take/start_req_q_take")

            def takes():
                return (signal_int(h.stop_req_q_chan) if signal_binstr(h.stop_req_q_take) == "1" else None,
                        signal_int(h.start_req_q_chan) if signal_binstr(h.start_req_q_take) == "1" else None)
            return takes
        self.log.info("header manager without a request queue: a stop is taken on STOP_REQ_VLD in S_IDLE, a start "
                      "on START_REQ_VLD in S_IDLE without a stop; a request outside S_IDLE is lost")

        def takes():
            idle = fsm_state(h.chan_state_change_pst) == CHAN_S_IDLE
            stop = idle and signal_binstr(h.STOP_REQ_VLD) == "1"
            start = idle and not stop and signal_binstr(h.START_REQ_VLD) == "1"
            return (signal_int(h.STOP_REQ_CHANNEL) if stop else None, signal_int(h.START_REQ_CHANNEL) if start else None)
        return takes

    def probe(self):
        h, sw = self.hdrm, self.swm
        takes = self.request_takes()
        reqs = (("stop", 0, S_PACKET_PROCESS, True), ("start", 1, S_PACKET_DISCARD, False))
        dm, hm = h.data_pcie_addr_mgr_i, h.dma_hdr_pcie_addr_mgr_i
        # Allocations by the address managers: none may come after the channel reported stopped.
        ptr_upd = (("HDP", dm.POINTER_UPDATE_EN, dm.POINTER_UPDATE_CHAN), ("HHP", hm.POINTER_UPDATE_EN, hm.POINTER_UPDATE_CHAN))

        def cycle_probe():
            cycle = _now() // CLK_NS
            eof = signal_binstr(h.MFB_EOF) == "1" and signal_handshake(h.MFB_SRC_RDY, h.MFB_DST_RDY)
            if eof:
                self.events["EOF"].append(cycle)
            if signal_binstr(h.input_fifo_empty) == "0" and fsm_state(h.pkt_process_pst) == S_IDLE:
                self.events["SOF"].append(cycle)
            taken = takes()
            for kind, idx, busy, running in reqs:
                c = taken[idx]
                if c is None:
                    continue
                self.last_take[kind] = cycle
                pst = fsm_state(h.pkt_process_pst)
                if kind == "start":
                    self.start_window.add(c)
                if eof and pst == busy and signal_int(h.pkt_chan_reg) == c:
                    self.hits[f"{kind} at EOF"] += 1
                # The packet FSM decides this channel's next packet in this same cycle, from the old status.
                if (pst == S_IDLE and signal_binstr(h.input_fifo_empty) == "0" and signal_int(h.input_channel) == c
                        and binstr_bit(signal_binstr(h.channel_status_reg), c) == running):
                    self.hits[f"{kind} at SOF"] += 1
            for what, en, chan in ptr_upd:
                if signal_binstr(en) == "1":
                    c = signal_int(chan)
                    # A write in the cycle of start_acked lands together with that ack's own register writes.
                    if c in self.start_window:
                        self.hits[START_WINDOW_HIT] += 1
                    ep = self.episodes.get(c)
                    # Mid-cycle, after the stop invariant of the same sample: a write of the stopping cycle itself is
                    # not one after the stop.
                    if ep is not None and ep["stopped_at"] is not None and _now() > ep["stopped_at"]:
                        self.violation(f"{what} of ch{c} advanced {_now() - ep['stopped_at']} ns after the "
                                       f"channel reported stopped")
            if signal_binstr(sw.start_acked) == "1":
                self.start_window.discard(signal_int(sw.start_fsm_channel_reg))
        # Mid-cycle, as the comparator probes: there an output a vendor simulation model updates after the edge has
        # settled, so the hazard classification does not depend on the model's output delay.
        self.on_cycle(cycle_probe, falling=True)

    def _stopped(self, ch, now):
        ep = self.episodes.get(ch)
        if ep is not None and ep["stopped_at"] is None:
            ep["stopped_at"] = now

    def _rq_out(self, t, now):
        tlp, _ = parse_rq(t.data, t.meta, self.device)
        if tlp is None:
            return
        addr = tlp.byte_address()
        for ch, ep in self.episodes.items():
            if addr == ep["upd"]:
                ep["host"] = tuple(tlp.data[:2])
                self.queues[ch].host_write("upd", 0, tlp.data[:2])
                continue
            if ep["hdr"][0] <= addr < ep["hdr"][1]:
                self.queues[ch].host_write("hdr", (addr - ep["hdr"][0]) // 8, tlp.data[:2])
            if ep["stopped_at"] is not None and any(lo <= addr < hi for lo, hi in (ep["data"], ep["hdr"])):
                self.violation(f"RQ write to {addr:#x} in a buffer of ch{ch} {now - ep['stopped_at']} ns after "
                               f"the channel reported stopped")

    def violation(self, msg):
        self.iter_violations.append(msg)

    def fail(self, msg):
        self.log.error(msg)
        self.failures.append(msg)

    def fail_violations(self, prefix):
        for v in self.iter_violations:
            self.fail(f"{prefix}: {v}")

    def rx_ptr_stats(self):
        sw = Counter()
        for q in self.queues:
            sw.update(q.stats)
        return f"{super().rx_ptr_stats()} | software {dict(sw)}"

    # ------------------------------------------------------------------------------------------
    # Software side
    # ------------------------------------------------------------------------------------------
    async def configure(self, ch):
        """Channel registers except control. P2P stays off so the host pointer is the plain HDP."""
        rng, r = self.rng, self.rx_regs[ch]
        used = {ep["data"][0] for ep in self.episodes.values()}
        region = None
        while region is None or region in used:
            hi = 0 if rng.getrandbits(1) else rng.getrandbits(32)
            region = ((hi << 32) | rng.getrandbits(32)) & ~((1 << 24) - 1) & ((1 << 64) - (1 << 24))
        # Disjoint data (<= 4 MiB), header (<= 256 KiB) and update areas, as separate allocations are.
        await r.write("update_base", region + (3 << 22) + 8 * rng.getrandbits(10))
        await r.write("data_base", region)
        await r.write("hdr_base", region + (2 << 22) + 8 * rng.getrandbits(10))
        await r.write_sp(0, 0)
        await r.write("data_mask", (1 << rng.randint(4, 15)) - 1)
        await r.write("hdr_mask", (1 << rng.randint(4, 15)) - 1)
        await r.write("upd_timeout", pick(rng, ndk_rand_dist(5, 1024)))
        await r.write("exper", 0)

    def new_episode(self, ch):
        """Called before the start is written: what the channel may write to until it reports stopped."""
        r = self.rx_regs[ch]
        data, hdr = r.get("data_base"), r.get("hdr_base")
        self.episodes[ch] = {"data": (data, data + (r.get("data_mask") + 1) * 128),
                             "hdr": (hdr, hdr + (r.get("hdr_mask") + 1) * 8),
                             "upd": r.get("update_base"), "stopped_at": None, "host": None}
        self.queues[ch].reset()

    async def wait_status(self, ch, want):
        """Polls R_STATUS until bit 0 is `want`. Returns the latency, None past the bound."""
        r = self.rx_regs[ch]
        t0 = _now()
        while (await r.read("status")) & 1 != want:
            if _now() - t0 > self.bound_ns:
                return None
            await ClockCycles(self.clk, SW_POLL_CYCLES)
        return _now() - t0

    async def wait_done(self, ch, want, control_written=False):
        """A start is polled; a stop is the driver's stop loop (rx_driver.RxQueue.stop)."""
        if want:
            return await self.wait_status(ch, 1)
        lat, it = await self.queues[ch].stop(self.bound_ns, _now, control_written)
        self.last_stop_iterations = it
        return lat

    async def complete(self, ch, want, what, control_written=False):
        lat = await self.wait_done(ch, want, control_written)
        if lat is None:
            self.fail(f"{what}: not complete {self.bound_ns} ns after the request with no further RX traffic")
            # Any later EOF releases a header manager waiting for a packet end, so the sweep goes on.
            self.send(ch, 64)
            lat = await self.wait_done(ch, want)
            if lat is None:
                raise BenchError(f"{what}: still not complete after a further packet")
        self.running[ch] = bool(want)
        return lat

    async def start_channel(self, ch, data_mask=None, hdr_mask=None):
        """Starts `ch` with a fresh configuration, whose random ring masks `data_mask` and `hdr_mask` replace if given."""
        await self.configure(ch)
        r = self.rx_regs[ch]
        if data_mask is not None:
            await r.write("data_mask", data_mask)
        if hdr_mask is not None:
            await r.write("hdr_mask", hdr_mask)
        self.new_episode(ch)
        await r.write("control", 1)
        await self.complete(ch, 1, f"RX ch{ch} start")

    async def stop_channel(self, ch):
        await self.complete(ch, 0, f"RX ch{ch} stop")

    async def stop_all(self, checked=True):
        """Stops the channels still running at the end of a test. `checked` quiesces and checks the pointers after each
        stop; otherwise the RX path is quiesced once after the last."""
        self.iter_violations = []
        for ch in range(self.rx_ch):
            if self.running[ch]:
                await self.stop_channel(ch)
                if checked:
                    await self.quiesce(f"RX ch{ch} stop at the end")
                    await self.check_pointers("stop", ch)
        if not checked:
            await self.quiesce("final stops")
        self.failures += [f"final stops: {v}" for v in self.iter_violations]

    def send(self, ch, size):
        meta = (ch << 24) | self.rng.getrandbits(24)
        self.usr_rx_drv.append(MfbTransactionWithMeta(data=self.rng.randbytes(size), meta=meta))
        self.appended += 1

    async def quiesce(self, what):
        """Waits until the packet left the bench and every expected RQ write and pointer update came."""
        deadline = _now() + 50_000
        while (self.usr_rx_drv.frame_cnt < self.appended or self.rx_model.used() or self.rx_cmp.used()
               or self.ptr_cmp.used() or self.merger.used()):
            if _now() > deadline:
                raise BenchError(f"{what}: RX path not idle 50 us after the packet")
            await Timer(100, "ns")
        await Timer(400, "ns")

    async def check_pointers(self, kind, ch):
        """After a stop the host must hold the final HW pointers; after a start a packet dropped right
        behind it must not have moved them."""
        r = self.rx_regs[ch]
        hw = (await r.read("hdp"), await r.read("hhp"))
        st = self.rx_model.state[ch]
        if hw != (st.data_ptr, st.hdr_ptr):
            self.violation(f"HW pointers HDP/HHP {hw} differ from the model's {(st.data_ptr, st.hdr_ptr)}")
        host = self.episodes[ch]["host"]
        if kind == "stop" and host != hw:
            self.violation(f"the last pointer update written to the host carries HDP/HHP {host}, the hardware "
                           f"ended at {hw}")

    # ------------------------------------------------------------------------------------------
    # Sweep
    # ------------------------------------------------------------------------------------------
    async def _align(self):
        """Returns, sampled mid-cycle as the probes are, the cycle at which the round-robin counter is 0."""
        while True:
            await FallingEdge(self.clk)
            await ReadOnly()
            if signal_int(self.swm.active_chan_regu) == 0:
                return _now() // CLK_NS

    async def _after(self, cycles, fn):
        await ClockCycles(self.clk, cycles)
        await fn()

    async def wait_for(self, cond, cycles):
        """Checks `cond` mid-cycle, as the probes sample, in up to `cycles` cycles; returns past the next rising edge, so
        the caller may write signals. True if `cond` held."""
        edge = RisingEdge(self.clk)
        for _ in range(cycles):
            await FallingEdge(self.clk)
            await ReadOnly()
            if cond():
                await edge
                return True
        await edge
        return False

    async def iteration(self, kind, ch, off, size):
        """One request of `kind` on `ch`, the packet's anchor word `off` cycles after the MI write. Returns
        (take - anchor cycles, MI write to take cycles)."""
        self.iter_violations = []
        if kind == "stop" and not self.running[ch]:
            await self.start_channel(ch)
        if kind == "start":
            if self.running[ch]:
                await self.stop_channel(ch)
            await self.configure(ch)
            self.new_episode(ch)
        words = -(-size // self.word_bytes)
        first = off - (words - 1 if self.anchor == "EOF" else 0)
        # A multiple of the round-robin period keeps the write's latency to the header manager constant.
        lead = -(-max(2, 2 - first) // self.rx_ch) * self.rx_ch
        hits = Counter(self.hits)
        drops = sum(self.rx_model.disc_pkts)
        self.events = {"EOF": [], "SOF": []}
        if kind == "stop":
            # The driver's first stop step, so that the swept CONTROL write keeps its cycle.
            await self.queues[ch].stop_prefix()
        issue = await self._align() + lead
        wr = cocotb.start_soon(self._after(lead, lambda: self.rx_regs[ch].write("control", int(kind == "start"))))

        async def pkt():
            self.send(ch, size)

        pk = cocotb.start_soon(self._after(lead + first, pkt))
        await wr
        await pk
        lat = await self.complete(ch, int(kind == "start"), f"RX ch{ch} {kind} at offset {off} ({size} B)",
                                  control_written=kind == "stop")
        await self.quiesce(f"RX ch{ch} {kind} at offset {off}")
        await self.check_pointers(kind, ch)
        hit = [k for k in self.hits if self.hits[k] > hits[k]]
        anchor = self.events[self.anchor]
        delta = self.last_take[kind] - anchor[0] if anchor else None
        dropped = sum(self.rx_model.disc_pkts) > drops
        self.log.info(f"{kind} ch{ch} offset {off:+4d} size {size:4d}: take - {self.anchor} "
                      f"{'n/a' if delta is None else f'{delta:+d}'} cycles, "
                      f"{'dropped' if dropped else 'passed'}, {'HAZARD CYCLE ' + '/'.join(hit) + ', ' if hit else ''}"
                      f"done after {lat} ns, contract {len(self.iter_violations) or 'ok'}")
        self.contract[(kind, f"{kind} at {self.anchor}" in hit, bool(self.iter_violations))] += 1
        self.fail_violations(f"RX ch{ch} {kind} at offset {off} ({size} B, {'/'.join(hit) or 'no hazard cycle'})")
        return delta, self.last_take[kind] - issue

    def required_hits(self, kind):
        """Hit counters a sweep of `kind` must fire before it ends."""
        req = [f"{kind} at {self.anchor}"]
        if kind == "start" and self.rx_ch >= START_WINDOW_MIN_CHANNELS:
            req.append(START_WINDOW_HIT)
        return req

    def sweep_size(self):
        return self.rng.randint(max(60, self.word_bytes + 1), 1024)

    async def sweep(self):
        """Passes of stops against processed packets, then of starts against dropped ones, until each required
        hit counter fired. A pass keeps one channel and size and spans the request latency around the hazard
        offset."""
        for kind in self.KINDS:
            for npass in range(1, self.max_passes + 1):
                ch, size = self.rng.randrange(self.rx_ch), self.sweep_size()
                delta, latency = await self.iteration(kind, ch, 0, size)
                # take - anchor falls by one per offset step and PCIE_RQ backpressure only delays the anchor,
                # so the largest offset + delta seen is the hazard offset of an undelayed packet.
                centre = delta if delta is not None else 0
                span = latency + 16
                tried = {0}
                for _ in range(2 * span):
                    offs = [off for off in range(centre - span, centre + span + 1) if off not in tried]
                    if not offs:
                        break
                    near = min(abs(off - centre) for off in offs)
                    off = self.rng.choice([o for o in offs if abs(o - centre) == near])
                    tried.add(off)
                    delta, _ = await self.iteration(kind, ch, off, size)
                    if delta is not None and off + delta > centre:
                        centre = off + delta
                self.passes[kind] = npass
                self.spans.append((kind, ch, size, centre, span))
                if all(self.hits[k] for k in self.required_hits(kind)):
                    break

    async def run(self):
        await self.bring_up()
        self.probe()
        await Timer(200, "ns")
        await self.sweep()
        await self.stop_all()

        def missed():
            return [f"{kind} sweep: hazard cycle '{hit}' never hit in {self.passes.get(kind)} sweep passes"
                    for kind in self.KINDS for hit in self.required_hits(kind) if not self.hits[hit]]

        def summary():
            table = ", ".join(f"{k} {'hit' if h else 'no hit'} {'violating' if v else 'ok'}: {n}"
                              for (k, h, v), n in sorted(self.contract.items()))
            return (f"{self.anchor} sweeps (kind, ch, size, centre, span) {self.spans}, passes {self.passes} | hazard "
                    f"cycles {dict(self.hits)} | iterations {table} | failures {len(self.failures)} | RQ TLPs compared "
                    f"{self.rx_cmp.compared}, pointer updates compared {self.ptr_cmp.compared} | MI accesses "
                    f"{self.mi.accesses} | {self.rx_ptr_stats()}")

        await self.finish(summary, early=lambda: self.failures, late=missed)


class RxStartDiscardBench(RxStartStopBench):
    """Starts swept against the header decision of a long packet of the stopped channel. A packet dropped with the
    old status must be counted as discarded once the start completes, so its discard is read at the completion and
    again once the packet left."""

    KINDS = ("start",)

    def __init__(self, dut):
        super().__init__(dut, "SOF")
        self.disc_at_start = None

    def sweep_size(self):
        # The software sees the start complete within about 50 cycles, well before the EOF of a packet this long.
        return self.rng.randint(2048, self.cfg["USR_RX_PKT_SIZE_MAX"])

    async def configure(self, ch):
        await super().configure(ch)
        # A processed packet of up to 4 KiB needs 32 data blocks.
        await self.rx_regs[ch].write("data_mask", (1 << self.rng.randint(6, 15)) - 1)

    async def wait_done(self, ch, want, control_written=False):
        lat = await super().wait_done(ch, want, control_written)
        if want and lat is not None:
            self.disc_at_start = await self.read_counter(self.rx_regs[ch], "disc_pkts")
        return lat

    async def check_pointers(self, kind, ch):
        await super().check_pointers(kind, ch)
        if kind == "start" and self.disc_at_start is not None:
            disc = await self.read_counter(self.rx_regs[ch], "disc_pkts")
            if disc != self.disc_at_start:
                self.violation(f"{disc - self.disc_at_start} packet(s) counted as discarded after the start "
                               f"completed ({self.disc_at_start} discarded packets at its completion)")
            self.disc_at_start = None


class RxStopLivelockBench(RxStartStopBench):
    """Stops of an idle channel held behind another channel's start against its dropped packet, whose EOF, stepped
    by one cycle per stop, moves the first pointer update dispatch over every phase of the channel's slot."""

    CAL_TIMEOUT = 5

    def __init__(self, dut):
        super().__init__(dut, "EOF")
        self.timeout = None
        self.period = None
        self.stops = []
        self.stop_rec = None
        self.lock_hits = 0
        self.phase_runs = Counter()
        self.ok_to_ack = []
        self.unheld = 0

    async def configure(self, ch):
        await super().configure(ch)
        if self.timeout is not None:
            await self.rx_regs[ch].write("upd_timeout", self.timeout)

    def bound_cycles(self):
        return 4 * self.rx_ch * self.period

    def stop_probe(self):
        """Per stop: dispatch entries, their length and phase against the channel's slot, the first cycle the
        pointers matched in a dispatch or wait state, and the ack. Sampled mid-cycle for the DSP comparators."""
        sw = self.swm
        prev = STOP_IDLE

        def cycle_probe():
            nonlocal prev
            cycle = _now() // CLK_NS
            pst = fsm_state(sw.stop_fsm_pst)
            if signal_binstr(sw.STOP_REQ_VLD) == "1":
                self.stop_rec = {"ch": signal_int(sw.STOP_REQ_CHAN), "req": cycle, "disp": [], "disp_len": [], "slot": [],
                                 "ok": None, "ack": None, "hits": 0, "late": False}
                self.stops.append(self.stop_rec)
            rec = self.stop_rec
            if rec is not None and rec["ack"] is None:
                ptr_ok = signal_binstr(sw.stop_ptr_ok) == "1"
                if pst == STOP_DISPATCH:
                    if prev != STOP_DISPATCH:
                        rec["disp"].append(cycle)
                        rec["disp_len"].append(0)
                        rec["slot"].append((signal_int(sw.active_chan_reg) - rec["ch"]) % self.rx_ch)
                    rec["disp_len"][-1] += 1
                    if ptr_ok and signal_binstr(sw.stop_chan_ok) == "1":
                        rec["hits"] += 1
                        self.lock_hits += 1
                if ptr_ok and rec["ok"] is None and pst in (STOP_DISPATCH, STOP_WAIT_FOR_POINTERS):
                    rec["ok"] = cycle
                if signal_binstr(sw.stop_acked) == "1":
                    rec["ack"] = cycle
                elif (self.period is not None and rec["ok"] is not None and not rec["late"]
                      and cycle - rec["ok"] > self.bound_cycles()):
                    rec["late"] = True
                    phases = sorted({s % self.period for s in rec["slot"]})
                    self.report(f"RX ch{rec['ch']}: stop not acknowledged {self.bound_cycles()} cycles after its "
                                f"pointers matched (period {self.period}, slot phases at dispatch {phases}, "
                                f"{rec['hits']} dispatch(es) on the slot)")
            prev = pst
        self.on_cycle(cycle_probe, falling=True)

    async def calibrate(self, ch):
        """A stop whose SDP differs from HDP re-dispatches until it matches. Returns the length of the first
        dispatch and the set of periods between dispatch entries under R_UPDATE_TIMEOUT = CAL_TIMEOUT."""
        await self.start_channel(ch)
        r = self.rx_regs[ch]
        await r.write("upd_timeout", self.CAL_TIMEOUT)
        await r.write("sdp", 1)
        n = len(self.stops)
        await r.write("control", 0)
        deadline = _now() + 20_000
        while len(self.stops) <= n or len(self.stops[n]["disp"]) < 4:
            if _now() > deadline:
                recs = [(r["ch"], len(r["disp"]), r["ok"], r["ack"]) for r in self.stops[n:]]
                raise BenchError(f"RX ch{ch}: fewer than 4 stop pointer update dispatches 20 us after a stop whose SDP "
                                 f"differs from HDP; stops seen (channel, dispatches, pointers ok cycle, ack cycle) {recs}")
            await ClockCycles(self.clk, 8)
        rec = self.stops[n]
        await self.complete(ch, 0, f"RX ch{ch} calibration stop")
        await self.quiesce(f"RX ch{ch} calibration stop")
        await self.check_pointers("stop", ch)
        disp = rec["disp"][:4]
        return rec["disp_len"][0], {b - a for a, b in zip(disp, disp[1:])}

    def choose_period(self, disp_len):
        """Re-dispatches repeat every R_UPDATE_TIMEOUT + 1 + dispatch length cycles. Returns the divisor of CHANNELS
        nearest CALYPTE_LIVELOCK_PERIOD that leaves R_UPDATE_TIMEOUT >= 1, None if there is none."""
        want = int(os.environ.get("CALYPTE_LIVELOCK_PERIOD", "8"))
        cands = [p for p in range(disp_len + 2, self.rx_ch + 1) if self.rx_ch % p == 0]
        return min(cands, key=lambda p: (abs(p - want), p)) if cands else None

    async def lock_iteration(self, b, c, step, size):
        """Stops c while the header manager waits for the EOF of b's dropped packet on b's start; b's packet is
        sent `step` cycles after a round-robin counter of 0."""
        h = self.hdrm
        self.iter_violations = []
        if self.running[b]:
            await self.stop_channel(b)
        if not self.running[c]:
            await self.start_channel(c)
        await self.configure(b)
        self.new_episode(b)
        await self._align()
        await ClockCycles(self.clk, step + 1)
        self.send(b, size)
        limit = 4 * self.rx_ch + size // self.word_bytes
        await self.wait_for(lambda: fsm_state(h.pkt_process_pst) == S_PACKET_DISCARD and signal_int(h.pkt_chan_reg) == b,
                            limit)
        await self.rx_regs[b].write("control", 1)
        held = await self.wait_for(lambda: fsm_state(h.chan_state_change_pst) == CHAN_S_WAIT_FOR_PKT_END, limit)
        n = len(self.stops)
        start = cocotb.start_soon(self.complete(b, 1, f"RX ch{b} start against its dropped packet"))
        lat = await self.complete(c, 0, f"RX ch{c} stop behind the start of ch{b} (step {step})")
        await start
        await self.quiesce(f"RX ch{c} stop behind the start of ch{b}")
        await self.check_pointers("start", b)
        await self.check_pointers("stop", c)
        rec = self.stops[n] if len(self.stops) > n else None
        if rec is None or rec["ch"] != c or rec["ack"] is None:
            raise BenchError(f"RX ch{c}: the stop FSM recorded no acknowledged stop of the channel")
        held = held and self.last_take.get("stop", 0) > rec["req"] + 1
        self.ok_to_ack.append(rec["ack"] - rec["ok"])
        phase = rec["slot"][0]
        self.phase_runs[phase] += 1
        self.unheld += not held
        self.log.info(f"stop ch{c} step {step:3d}: {'held behind' if held else 'NOT held behind'} the start of ch{b}, "
                      f"slot phase at dispatch {phase}/{self.rx_ch} ({phase % self.period} in the period), "
                      f"{len(rec['disp'])} dispatch(es), {rec['hits']} on the slot with the pointers matching, ack "
                      f"{rec['ack'] - rec['ok']} cycles after they matched, done after {lat} ns, contract "
                      f"{len(self.iter_violations) or 'ok'}")
        self.fail_violations(f"RX ch{c} stop at step {step}")

    async def run(self):
        await self.bring_up()
        self.probe()
        self.stop_probe()
        await Timer(200, "ns")
        problems = []
        b, c = self.rng.sample(range(self.rx_ch), 2)
        disp_len, periods = await self.calibrate(c)
        expect = self.CAL_TIMEOUT + 1 + disp_len
        self.log.info(f"calibration on ch{c}: dispatch {disp_len} cycle(s), periods {sorted(periods)} with "
                      f"R_UPDATE_TIMEOUT {self.CAL_TIMEOUT} (T + 1 + dispatch = {expect})")
        if periods != {expect}:
            raise BenchError(f"stop pointer update period {sorted(periods)} is not R_UPDATE_TIMEOUT + 1 + dispatch "
                             f"length = {expect}")
        period = self.choose_period(disp_len)
        size = self.cfg["USR_RX_PKT_SIZE_MAX"]
        if period is None:
            self.log.warning(f"RX stop livelock impossible: no divisor of CHANNELS = {self.rx_ch} is a dispatch period "
                             f"(>= {disp_len + 2} cycles); phase sweep skipped")
        elif size // self.word_bytes < 2 * self.rx_ch + 24:
            self.log.warning(f"RX stop livelock not testable: a {size} B packet lasts {size // self.word_bytes} words, "
                             f"too short to hold a stop behind a start with {self.rx_ch} channels; phase sweep skipped")
            period = None
        if period is not None:
            self.period, self.timeout = period, period - 1 - disp_len
            self.log.info(f"phase sweep: stops of ch{c} held behind starts of ch{b}, R_UPDATE_TIMEOUT {self.timeout}, "
                          f"period {period}, bound {self.bound_cycles()} cycles from matching pointers to the ack")
            max_iter = int(os.environ.get("CALYPTE_LIVELOCK_ITER_MAX", str(4 * self.rx_ch)))
            for it in range(max_iter):
                await self.lock_iteration(b, c, it % self.rx_ch, size)
                if len(self.phase_runs) == self.rx_ch:
                    break
            missing = sorted(set(range(self.rx_ch)) - set(self.phase_runs))
            if missing:
                problems.append(f"slot phase(s) {missing} of the first dispatch never reached in {max_iter} stops")
            if self.rx_ch > self.timeout + 2 and not self.lock_hits:
                problems.append("no stop dispatch fell on the channel's slot with the pointers matching")
        await self.stop_all()
        await self.finish(lambda: (
            f"livelock period {self.period}, "
            f"R_UPDATE_TIMEOUT {self.timeout}, dispatch {disp_len} cycle(s), stops per slot phase "
            f"{dict(sorted(self.phase_runs.items()))} ({self.unheld} not held), dispatches on the slot "
            f"with matching pointers {self.lock_hits}, matching pointers to ack max "
            f"{max(self.ok_to_ack, default=None)} cycles | failures {len(self.failures)} | RQ TLPs compared "
            f"{self.rx_cmp.compared}, pointer updates compared {self.ptr_cmp.compared} | MI accesses "
            f"{self.mi.accesses} | {self.rx_ptr_stats()}"), early=lambda: problems + self.failures)
