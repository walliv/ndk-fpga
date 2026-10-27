# rx_full_buffer.py: directed RX channel stops while another channel's buffer is full
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""The address managers serve requests in order and hold the head request while its buffer is full, so a full channel
X holds every channel's requests. Stops of another channel c behind it must keep the stop contract."""

import os
import re
from collections import Counter, deque

import cocotb
from cocotb.triggers import ClockCycles

from cocotbext.ofm.utils.signals import signal_binstr, signal_int

from checkers import BenchError
from cocotb_test import _now
from rx_start_stop import CHAN_FSM, PKT_FSM, S_PACKET_PROCESS, STOP_FSM, RxStartStopBench, fsm_state

# A 64-entry ring is full after 63 one-block packets (the address manager keeps one slot free); a userspace
# consumer flushes its pointers only after 32 packets, so a smaller ring would never be freed by it.
FULL_MASK = 63
ROOMY_MASK = 255
FILL_PACKETS = FULL_MASK
KINDS = ("data", "hdr")
INS_FSM = ("IDLE", "TRANSACTION_SEND", "DMA_HDR_SEND", "PKT_DROP")
HELD_CYCLES = 4


class RxHolBench(RxStartStopBench):
    """Shadows the header manager's address request FIFOs and finds a head request held on a full buffer."""

    def __init__(self, dut, anchor="EOF"):
        super().__init__(dut, anchor)
        self.shadow = {k: deque() for k in KINDS}
        self.held = {k: None for k in KINDS}
        self.held_for = {k: 0 for k in KINDS}
        self.hol_hits = Counter()
        self.watch = None
        self.scenario = None

    # ------------------------------------------------------------------------------------------
    # Grey-box probes
    # ------------------------------------------------------------------------------------------
    def _mgr(self, kind):
        return self.hdrm.data_pcie_addr_mgr_i if kind == "data" else self.hdrm.dma_hdr_pcie_addr_mgr_i

    def hol_probe(self):
        """Shadows the two address request FIFOs of the header manager (written by its packet FSM, read when the
        address manager serves the head) and finds the head request held because its channel's buffer is full."""
        h = self.hdrm
        takes = self.request_takes()
        fifo = {"data": (h.data_addr_next_wr, h.data_pcie_addr_vld), "hdr": (h.dma_hdr_addr_next_wr,
                                                                             h.dma_hdr_pcie_addr_vld)}

        def cycle_probe():
            for kind in KINDS:
                wr, rd = fifo[kind]
                if signal_binstr(rd) == "1":
                    self.shadow[kind].popleft()
                if signal_binstr(wr) == "1":
                    self.shadow[kind].append(signal_int(h.input_channel))
                m = self._mgr(kind)
                held = (signal_binstr(m.channel_act_vld_reg) == "1" and signal_binstr(m.packet_vld) != "1"
                        and signal_binstr(m.START_REQ_VLD) != "1")
                ch = signal_int(m.channel_act_reg) if held else None
                self.held_for[kind] = self.held_for[kind] + 1 if held and ch == self.held[kind] else int(held)
                self.held[kind] = ch
                if held and self.shadow[kind] and self.shadow[kind][0] != ch:
                    raise BenchError(f"bench: the {kind} request FIFO shadow heads with ch{self.shadow[kind][0]}, the "
                                     f"address manager holds ch{ch}")
            w = self.watch
            if w is None:
                return
            x, c, kind = w["x"], w["c"], w["kind"]
            if self.held[kind] == x and self.held_for[kind] >= HELD_CYCLES and not w["held"]:
                w["held"] = True
                self.hol_hits[f"{kind} request of X held on its full buffer"] += 1
            if w["held"] and not w["queued"] and c in list(self.shadow[kind])[1:]:
                w["queued"] = True
                self.hol_hits[f"c queued behind X's held {kind} request"] += 1
            stop, _ = takes()
            if stop == c and w["held"] and self.held[kind] == x and w["c_take"] is None:
                w["c_take"] = _now()
                if self.scenario == "idle":
                    if all(c not in q for q in self.shadow.values()):
                        self.hol_hits["stop of an idle c taken while X's request is held"] += 1
                elif c in list(self.shadow[kind])[1:]:
                    self.hol_hits["stop of c taken while its request is queued behind X's"] += 1
                pst = fsm_state(h.pkt_process_pst)
                w["c_eof_passed"] = not (pst == S_PACKET_PROCESS and signal_int(h.pkt_chan_reg) == c)
            if stop == x and w["x_take"] is None:
                w["x_take"] = _now()
            if signal_binstr(h.STOP_REQ_DONE) == "1" and signal_int(self.swm.stop_fsm_channel_reg) == c and w["c_done"] is None:
                w["c_done"] = _now()
        self.on_cycle(cycle_probe, falling=True)

    def fsm_dump(self):
        """Where the stop path sits: SW manager stop FSM, header manager channel and packet FSMs, address
        managers, header insertor and the shadowed request FIFOs."""
        sw, h, ins = self.swm, self.hdrm, self.rx_dma_i.rx_dma_hdr_insertor_i
        parts = [f"SW stop FSM {STOP_FSM[fsm_state(sw.stop_fsm_pst)]} on ch{signal_int(sw.stop_fsm_channel_reg)}",
                 f"header manager channel FSM {CHAN_FSM[fsm_state(h.chan_state_change_pst)]}, packet FSM "
                 f"{PKT_FSM[fsm_state(h.pkt_process_pst)]} on ch{signal_int(h.pkt_chan_reg)}, input FIFO "
                 f"{'empty' if signal_binstr(h.input_fifo_empty) == '1' else f'head ch{signal_int(h.input_channel)}'}"]
        if h._get("stop_req_q_vld") is not None:
            q_stop, q_start = signal_binstr(h.stop_req_q_vld) == "1", signal_binstr(h.start_req_q_vld) == "1"
            parts.append(f"queued stop {'ch' + str(signal_int(h.stop_req_q_chan)) if q_stop else '-'}, "
                         f"queued start {'ch' + str(signal_int(h.start_req_q_chan)) if q_start else '-'}")
        for kind in KINDS:
            parts.append(f"{kind} address manager holds {'-' if self.held[kind] is None else f'ch{self.held[kind]}'}, "
                         f"request FIFO {list(self.shadow[kind])}")
        parts.append(f"header insertor {INS_FSM[fsm_state(ins.tprocess_pst)]}")
        return "; ".join(parts)


class RxFullBufferBench(RxHolBench):
    """`scenario` "resume" (H-a): c's packet queued behind X's held request, stop c, X's consumer resumes. "stop" (H-b):
    X is stopped as well by the driver's loop instead. "idle" (H-c): c has nothing queued, X stays full. `upd_timeout`
    replaces the random R_UPDATE_TIMEOUT of every channel."""

    def __init__(self, dut, scenario, upd_timeout=None):
        super().__init__(dut, "EOF")
        assert scenario in ("resume", "stop", "idle")
        self.scenario = scenario
        self.upd_timeout = upd_timeout
        self.iterations = int(os.environ.get("CALYPTE_HOL_ITER", "6"))
        self.outcomes = []

    # ------------------------------------------------------------------------------------------
    # Software side
    # ------------------------------------------------------------------------------------------
    async def configure(self, ch):
        await super().configure(ch)
        if self.upd_timeout is not None:
            await self.rx_regs[ch].write("upd_timeout", self.upd_timeout)

    async def stop_bounded(self, ch, res, key):
        lat = await self.wait_done(ch, 0)
        res[key] = lat
        if lat is not None:
            self.running[ch] = False

    def small(self):
        return self.rng.randint(60, 128)

    async def iteration(self, n, kind):
        self.iter_violations = []
        x, c = self.rng.sample(range(self.rx_ch), 2)
        for ch in (x, c):
            if self.running[ch]:
                await self.stop_channel(ch)
        await self.quiesce(f"iteration {n}: idle before the start")
        await self.start_channel(x, data_mask=FULL_MASK if kind == "data" else ROOMY_MASK,
                                 hdr_mask=FULL_MASK if kind == "hdr" else ROOMY_MASK)
        await self.start_channel(c)
        for _ in range(FILL_PACKETS):
            self.send(x, self.small())
        await self.quiesce(f"iteration {n}: ch{x} filled")
        w = {"x": x, "c": c, "kind": kind, "held": False, "queued": False, "c_take": None, "x_take": None,
             "c_eof_passed": None, "c_done": None}
        self.watch = w
        self.send(x, self.small())
        if not await self.wait_for(lambda: w["held"], 64 * self.rx_ch + 500):
            raise BenchError(f"iteration {n}: the {kind} request of ch{x} was never held on its full buffer; "
                             f"{self.fsm_dump()}")
        c_size = None
        if self.scenario != "idle":
            c_size = self.c_size()
            self.send(c, c_size)
            if not await self.wait_for(lambda: w["queued"], 64 * self.rx_ch + 500):
                self.log.warning(f"iteration {n}: the {c_size} B packet of ch{c} was not queued behind the held "
                                 f"{kind} request of ch{x}; {self.fsm_dump()}")
            await ClockCycles(self.clk, self.rng.randint(0, 64))
        res = {}
        stops = [cocotb.start_soon(self.stop_bounded(c, res, "c"))]
        if self.scenario == "stop":
            await self.wait_for(lambda: w["c_take"] is not None, 8 * self.rx_ch + 200)
            stops.append(cocotb.start_soon(self.stop_bounded(x, res, "x")))
        for t in stops:
            await t
        pending = [(ch, key) for ch, key in ((c, "c"), (x, "x")) if key in res and res[key] is None]
        # Behind a full X, c's stop may wait for the resume (H-a); the stop protocol (H-b) and an idle c (H-c) may not.
        hang = [ch for ch, _ in pending] if self.scenario != "resume" else []
        dump = self.fsm_dump() if pending else None
        if hang:
            self.fail(f"iteration {n} ({self.scenario}, {kind}): stop of {', '.join(f'ch{ch}' for ch in hang)} not "
                      f"complete {self.bound_ns} ns after the request; {dump}")
        elif pending:
            self.log.info(f"iteration {n}: stop of ch{c} waits for the resume of ch{x}; {dump}")
        # X's consumer frees its ring: the resume of H-a, an out-of-protocol way out of an H-b or H-c hang.
        done_before = w["c_done"] is not None
        self.queues[x].start_consumer()
        late = {}
        for ch, key in pending:
            late[key] = await self.wait_done(ch, 0)
            if late[key] is None:
                msg = (f"iteration {n} ({self.scenario}, {kind}): stop of ch{ch} not complete {self.bound_ns} ns "
                       f"after ch{x} was consumed; {self.fsm_dump()}")
                if self.scenario == "resume":
                    hang.append(ch)
                    self.failures.append(msg)
                raise BenchError(msg)
            self.running[ch] = False
        await self.queues[x].stop_consumer()
        if self.running[x]:
            await self.stop_channel(x)
        await self.quiesce(f"iteration {n}: after the stops")
        for ch in (c, x):
            first = len(self.iter_violations)
            await self.check_pointers("stop", ch)
            self.iter_violations[first:] = [f"ch{ch}: {v}" for v in self.iter_violations[first:]]
        self.watch = None
        on_c = [v for v in self.iter_violations if re.search(rf"\bch{c}\b", v)]
        out = {"n": n, "scenario": self.scenario, "kind": kind, "x": x, "c": c, "c_size": c_size,
               "c_queued": w["queued"], "c_eof_passed_at_take": w["c_eof_passed"], "c_hdrm_ack_before_x": done_before,
               "c_stop_ns": res.get("c"), "x_stop_ns": res.get("x"), "after_consume_ns": late, "hang": hang,
               "dump": dump, "violations": list(self.iter_violations), "violations_c": on_c}
        self.outcomes.append(out)
        # A violation of X alone comes from its clean-up stop, not from the scenario.
        verdict = "HANG" if hang else ("CONTRACT VIOLATION" if on_c else "pass")
        self.log.info(f"iteration {n} ({self.scenario}, {kind}-full ch{x}, stopped ch{c}"
                      f"{'' if c_size is None else f', {c_size} B packet'}): {verdict}; c queued {w['queued']}, "
                      f"c's EOF past the header manager at the stop take {w['c_eof_passed']}, header manager acked "
                      f"c's stop before X was consumed {done_before}, c stop "
                      f"{res.get('c')} ns, X stop {res.get('x', '-')} ns, after consuming X {late or '-'}, "
                      f"{len(on_c)} violation(s) of c, {len(self.iter_violations) - len(on_c)} of X")
        self.fail_violations(f"iteration {n} ({self.scenario}, {kind}-full ch{x}, stopped ch{c})")

    def c_size(self):
        """Half the packets fit one 128 B segment (one word where the bus is 64 B wide), the rest span up to four."""
        if self.rng.getrandbits(1):
            return self.rng.randint(60, max(60, min(128, self.word_bytes)) if self.word_bytes >= 60 else 128)
        return self.rng.randint(129, 512)

    def required_hol_hits(self):
        req = [f"{kind} request of X held on its full buffer" for kind in KINDS[:min(2, self.iterations)]]
        if self.scenario == "idle":
            req.append("stop of an idle c taken while X's request is held")
        else:
            req.append("stop of c taken while its request is queued behind X's")
        return req

    async def run(self):
        await self.bring_up()
        self.probe()
        self.hol_probe()
        await ClockCycles(self.clk, 50)
        for n in range(self.iterations):
            await self.iteration(n, KINDS[n % 2])
        await self.stop_all(checked=False)

        def summary():
            verdicts = Counter("hang" if o["hang"] else "violation" if o["violations_c"] else "pass" for o in self.outcomes)
            return (f"full-buffer {self.scenario}: {dict(verdicts)} over {len(self.outcomes)} iterations | "
                    f"R_UPDATE_TIMEOUT {'random' if self.upd_timeout is None else self.upd_timeout} | hits "
                    f"{dict(self.hol_hits)} | failures {len(self.failures)} | RQ TLPs compared {self.rx_cmp.compared}, "
                    f"pointer updates compared {self.ptr_cmp.compared} | {self.rx_ptr_stats()}")

        await self.finish(summary, early=lambda: self.failures,
                          late=lambda: [f"hit counter '{k}' never hit in {self.iterations} iterations"
                                        for k in self.required_hol_hits() if not self.hol_hits[k]])
