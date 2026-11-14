# cocotb_test.py: does FS_CTRL run a job to DONE or ERR, drain safely and attribute every error?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""A Python plane emulator drives the datapath activity, the progress flags and the byte counts the
way the planes do (nothing starts once a job is finished or draining, writes get one status each);
the tests and the soak drive the commands and error sources. Reference: fs_ctrl_model, compared on
every output of every cycle; the drain, quiet-window and error rules are also asserted without it."""

import os
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotbext.ofm.utils.signals import signal_int

import fs_ctx as fc
from fs_ctrl_model import (CtrlIn, CtrlOut, FsCtrlModel, S_DONE, S_DRAIN, S_ERR, S_IDLE, S_RUN, STATE_NAMES)
from fs_tb_util import seeded, settle, start_clock
from scoreboard import Scoreboard

# Must match the elaborated generics; the fallbacks are the RTL defaults.
STREAMS = int(os.environ.get("STREAMS", 8))
NUM_QUEUES = int(os.environ.get("NUM_QUEUES", 4))
EPS = int(os.environ.get("PCIE_ENDPOINTS", 1))
QUIET = int(os.environ.get("DONE_QUIET", 1024))
ALL = (1 << STREAMS) - 1
EPS_ALL = (1 << EPS) - 1
MAX_LD = min(fc.MAX_LOG2_DRIVES, NUM_QUEUES.bit_length() - 1)
MAX_FLIGHT = 60
# Priority of the sources that name one stream, highest first.
PRIORITY = ("plan", "writer", "arg", "rerr", "werr", "hbm", "abort")
PULSES = ("reset", "start", "abort", "clear", "plan_err", "writer_err", "arg_err", "rerr_vld", "werr_vld", "hbm_err")


def geom_valid(drives, chunk):
    """The stripe geometry the job controller accepts: a chunk of 2..2**8 LBAs, drives a queue serves."""
    return 1 <= chunk <= fc.MAX_LOG2_CHUNK and drives <= MAX_LD


def bits(mask):
    return [s for s in range(STREAMS) if mask >> s & 1]


class Pins:
    """Writes the model's input record to the DUT, touching only what changed."""

    def __init__(self, dut):
        self.dut = dut
        self.cache = {}

    def put(self, key, handle, value):
        if self.cache.get(key) != value:
            handle.value = value
            self.cache[key] = value

    def drive(self, i):
        d = self.dut
        scalars = {
            "RESET": i.reset, "CTRL_START": i.start, "CTRL_ABORT": i.abort, "CTRL_CLEAR": i.clear,
            "STREAM_MASK": i.mask & ALL, "STRIPE_LOG2_DRIVES": i.drives & 15, "STRIPE_LOG2_CHUNK": i.chunk & 15,
            "IN_DONE": i.in_done & ALL, "OUT_DONE": i.out_done & ALL, "NEED_SPACE": i.need_space & ALL,
            "PLAN_ERR": i.plan_err & ALL, "WRITER_ERR": i.writer_err & ALL, "ARG_ERR": i.arg_err & ALL,
            "RERR_VLD": i.rerr_vld, "RERR_MASK": i.rerr_mask & ALL, "RERR_INFO": i.rerr_info,
            "WERR_VLD": i.werr_vld, "WERR_MASK": i.werr_mask & ALL, "WERR_INFO": i.werr_info,
            "HBM_ERR": i.hbm_err, "RD_IDLE": i.rd_idle, "RD_DATA_IDLE": i.rd_data_idle & EPS_ALL,
            "RD_EOF": i.rd_eof & EPS_ALL, "WR_BUSY": i.wr_busy & ALL, "WR_OUTSTANDING": i.wr_outstanding & ALL,
            "WR_FRAME": i.wr_frame, "WR_STATUS": i.wr_status,
        }
        for name, value in scalars.items():
            self.put(name, getattr(d, name), value)
        for s in range(STREAMS):
            self.put(("PLAN_ERR_INFO", s), d.PLAN_ERR_INFO[s], i.plan_info[s])
            self.put(("WRITER_ERR_INFO", s), d.WRITER_ERR_INFO[s], i.writer_info[s])
        for e in range(EPS):
            self.put(("BYTES_VLD", e), d.BYTES_VLD[e], i.bytes_vld[e] & ALL)
            self.put(("BYTES_N", e), d.BYTES_N[e], i.bytes_n[e])


class PlaneEmu:
    """The datapath as FS_CTRL sees it. Activity (read and write sources, write frames, read-frame
    ends) comes in random bursts while a job runs; once every enabled stream is done, or the job
    drains, nothing new starts, which is what the idle sampling of the FSM relies on."""

    DEFAULTS = dict(work=(150, 900), p_rearm=0.06, p_busy=0.7, p_eof=0.004, p_frame=0.08, p_bytes=0.3,
                    never_done=False, hold=(), drain_eofs=None, tail_eofs=None, flicker=0.0, eof_noise=0.0,
                    bytes_always=False)

    def __init__(self, rng):
        self.rng = rng
        self.nsrc = 1 + EPS + STREAMS
        self.knobs = dict(self.DEFAULTS)
        self.reset()

    def configure(self, **kw):
        for k, v in kw.items():
            assert k in self.DEFAULTS, k
            self.knobs[k] = v

    def randomize(self):
        r = self.rng
        self.configure(work=r.choice(((60, 200), (150, 900), (600, 1500))), p_rearm=r.choice((0.02, 0.06, 0.2)),
                       p_busy=r.choice((0.3, 0.7, 1.0)), p_eof=r.choice((0.0, 0.004, 0.02)),
                       p_frame=r.choice((0.03, 0.1, 0.3)), p_bytes=r.choice((0.1, 0.3, 0.8)))

    def reset(self):
        self.win = [0] * self.nsrc
        self.busy_prev = [0] * self.nsrc
        self.flight = []
        self.flags_in = self.flags_out = 0
        self.due = {"in": [0] * STREAMS, "out": [0] * STREAMS}
        self.finished = False
        self.work_left = 0
        self.last_rise = -100
        self.busy_any_prev = False
        self.prev_state = S_IDLE
        self.script = []
        self.ns = 0

    def _eof_script(self, c, spec):
        """Absolute cycles of read-frame ends; ('restart', k) spaces k of them just inside the quiet window."""
        r = self.rng
        if spec is None:
            return sorted(c + r.randint(0, 80) for _ in range(r.choice((0, 0, 1, 2, 3))))
        out, t = [], c + r.randint(3, 30)
        for _ in range(spec[1]):
            out.append(t)
            t += max(1, QUIET - r.randint(3, 30))
        return out

    def _new_job(self, c):
        r, k = self.rng, self.knobs
        j = r.randint(*k["work"])
        self.work_left = j
        for kind in ("in", "out"):
            self.due[kind] = [c + (r.randint(0, 5) if r.random() < 0.3 else r.randint(0, j)) for _ in range(STREAMS)]
        self.flags_in = self.flags_out = 0
        self.finished = False
        self.last_rise = -100
        self.script = []

    def _enter_drain(self, c):
        r = self.rng
        self.script = self._eof_script(c, self.knobs["drain_eofs"])
        self.win = [r.randint(1, 100) if self.busy_prev[x] else 0 for x in range(self.nsrc)]

    def _update_flags(self, c, mask_r):
        k = self.knobs
        if k["never_done"]:
            return
        for kind in ("in", "out"):
            for s in range(STREAMS):
                flags = self.flags_in if kind == "in" else self.flags_out
                if flags >> s & 1 or c < self.due[kind][s] or (kind, s) in k["hold"]:
                    continue
                new_in = self.flags_in | (1 << s if kind == "in" else 0)
                new_out = self.flags_out | (1 << s if kind == "out" else 0)
                completes = mask_r & ~(new_in & new_out) == 0 and mask_r & ~(self.flags_in & self.flags_out) != 0
                if completes and c - self.last_rise < 5:
                    continue
                self.flags_in, self.flags_out = new_in, new_out

    def prepare(self, tb, inp):
        m, c, r, k = tb.model, tb.cyc, self.rng, self.knobs
        st = m.state
        if m.plane_clear_r:
            self.flags_in = self.flags_out = 0
            self.finished = False
        if st == S_RUN and self.prev_state != S_RUN:
            self._new_job(c)
        if st == S_DRAIN and self.prev_state != S_DRAIN:
            self._enter_drain(c)
        self.prev_state = st

        active = st in (S_RUN, S_DRAIN)
        if not active:
            assert not any(self.win) and not self.flight, f"cycle {c}: the datapath still active in {STATE_NAMES[st]}"
        was_finished = self.finished
        if st == S_RUN:
            self._update_flags(c, m.mask_r)
            self.finished = m.mask_r & ~(self.flags_in & self.flags_out) == 0
            self.work_left = max(0, self.work_left - 1)
            if self.finished and not was_finished:
                self.script = self._eof_script(c, k["tail_eofs"]) if k["tail_eofs"] is not None else []
        rise_ok = st == S_RUN and not self.finished and self.work_left > 0
        solid = st == S_DRAIN or self.finished

        busy = [0] * self.nsrc
        for x in range(self.nsrc):
            if rise_ok and self.win[x] == 0 and r.random() < k["p_rearm"]:
                self.win[x] = r.randint(1, 60)
            if self.win[x] > 0:
                if solid and not self.busy_prev[x]:
                    self.win[x] = 0
                    continue
                busy[x] = 1 if solid else int(r.random() < k["p_busy"])
                self.win[x] -= 1
        self.busy_prev = busy

        flight_before = len(self.flight)
        outstanding = sum(1 << s for s in {f[1] for f in self.flight})
        due_now = [f for f in self.flight if f[0] <= c]
        status = 0
        if due_now:
            self.flight.remove(min(due_now, key=lambda f: f[0]))
            status = 1
        frame = 0
        cand = [s for s in range(STREAMS) if busy[1 + EPS + s]]
        if rise_ok and cand and len(self.flight) < MAX_FLIGHT and r.random() < k["p_frame"]:
            self.flight.append([c + r.randint(1, 150), r.choice(cand)])
            frame = 1
        busy_any = any(busy) or flight_before > 0
        if (busy_any and not self.busy_any_prev) or frame:
            self.last_rise = c
        self.busy_any_prev = busy_any

        inp.rd_idle = 0 if busy[0] else 1
        inp.rd_data_idle = sum((0 if busy[1 + e] else 1) << e for e in range(EPS))
        inp.wr_busy = sum(busy[1 + EPS + s] << s for s in range(STREAMS))
        inp.wr_outstanding = outstanding
        inp.wr_frame, inp.wr_status = frame, status

        eof = 0
        if st == S_RUN and not self.finished and r.random() < k["p_eof"]:
            eof = r.randint(1, EPS_ALL)
        while self.script and self.script[0] <= c:
            self.script.pop(0)
            eof |= r.randint(1, EPS_ALL)
        if not active and r.random() < k["eof_noise"]:
            eof |= r.randint(1, EPS_ALL)
        inp.rd_eof = eof

        for e in range(EPS):
            if (active or k["bytes_always"]) and r.random() < k["p_bytes"]:
                inp.bytes_vld[e], inp.bytes_n[e] = r.getrandbits(STREAMS), r.randint(1, 64)
            else:
                inp.bytes_vld[e], inp.bytes_n[e] = 0, r.getrandbits(7)

        if r.random() < 0.1:
            self.ns ^= 1 << r.randrange(STREAMS)
        inp.need_space = self.ns
        if st == S_RUN or not k["flicker"]:
            inp.in_done, inp.out_done = self.flags_in, self.flags_out
        else:
            inp.in_done, inp.out_done = r.getrandbits(STREAMS), r.getrandbits(STREAMS)


class Inject:
    """One cycle of error sources and the info every stream should end up with."""

    def __init__(self, plan=0, writer=0, arg=0, rerr=0, werr=0, hbm=0, abort=0, rng=None, rerr_info=None,
                 werr_info=None):
        self.plan, self.writer, self.arg, self.rerr, self.werr = plan, writer, arg, rerr, werr
        self.hbm, self.abort = hbm, abort
        rnd = rng.getrandbits if rng else (lambda n: 0)
        self.plan_info = [rnd(32) for _ in range(STREAMS)]
        self.writer_info = [rnd(32) for _ in range(STREAMS)]
        self.rerr_info = rnd(32) if rerr_info is None else rerr_info
        self.werr_info = rnd(32) if werr_info is None else werr_info

    def apply(self, inp):
        inp.plan_err, inp.writer_err, inp.arg_err = self.plan, self.writer, self.arg
        inp.plan_info, inp.writer_info = list(self.plan_info), list(self.writer_info)
        inp.rerr_vld, inp.rerr_mask, inp.rerr_info = int(bool(self.rerr)), self.rerr, self.rerr_info
        inp.werr_vld, inp.werr_mask, inp.werr_info = int(bool(self.werr)), self.werr, self.werr_info
        inp.hbm_err, inp.abort = self.hbm, self.abort

    def winner(self, s):
        """(source, info) that names stream s and wins, None when nothing names it."""
        rerr_info = self.rerr_info
        table = {
            "plan": (self.plan >> s & 1, self.plan_info[s]),
            "writer": (self.writer >> s & 1, self.writer_info[s]),
            "arg": (self.arg >> s & 1, fc.err_info(fc.ERR_SRC_FORMAT, 0, 0, 0, 0)),
            "rerr": (self.rerr >> s & 1, rerr_info),
            "werr": (self.werr >> s & 1, self.werr_info),
            "hbm": (self.hbm, fc.err_info(fc.ERR_SRC_HBM, 0, 0, 0, 0)),
            "abort": (self.abort, fc.err_info(fc.ERR_SRC_ABORT, 0, 0, 0, 0)),
        }
        for name in PRIORITY:
            if table[name][0]:
                return name, table[name][1]
        return None

    def fails_job(self, mask):
        """The job fails when a source names an enabled stream, or HBM_ERR or ABORT comes while running."""
        return bool(self.hbm or self.abort or any(self.winner(s) for s in bits(mask)))


class Chaos:
    """Random commands, errors and configuration changes for the soak, in episodes of one profile."""

    def __init__(self, rng):
        self.rng = rng
        self.left = 0
        self.p = {}

    def new_episode(self):
        r = self.rng
        self.left = r.randint(2000, 6000)
        self.p = dict(start=r.choice((0.002, 0.02, 0.2)), abort=r.choice((0.0, 0.0002, 0.001)),
                      clear_busy=r.choice((0.0, 0.0003, 0.002)), clear_idle=r.choice((0.003, 0.02, 0.1)),
                      err=r.choice((0.0, 0.0005, 0.004)), hbm=r.choice((0.0, 0.0002, 0.001)),
                      cfg=r.choice((0.0, 0.001, 0.02)), junk=r.choice((0.0, 0.5)))

    def prepare(self, tb, inp):
        r, p = self.rng, self.p
        if self.left <= 0:
            self.new_episode()
            p = self.p
            tb.emu.randomize()
            tb.emu.configure(drain_eofs=r.choice((None, None, ("restart", 2))), flicker=r.choice((0.0, 1.0)),
                             eof_noise=r.choice((0.0, 0.02)), bytes_always=r.random() < 0.3,
                             tail_eofs=r.choice((None, None, ("restart", 1))))
        self.left -= 1
        st = tb.model.state
        inp.start = int(r.random() < p["start"])
        abort = int(r.random() < p["abort"])
        pc = p["clear_busy"] if st in (S_RUN, S_DRAIN) else p["clear_idle"]
        inp.clear = int(r.random() < pc)
        if r.random() < p["cfg"]:
            inp.mask = r.choice((0, ALL, 1 << r.randrange(STREAMS), r.getrandbits(STREAMS)))
            valid = r.random() < 0.8
            inp.drives = r.randint(0, MAX_LD) if valid else r.getrandbits(4)
            inp.chunk = r.randint(1, fc.MAX_LOG2_CHUNK) if valid else r.getrandbits(4)
        e = Inject(rng=r, rerr_info=(r.getrandbits(32) & ~3) | r.choice((0, 1, 2, 2, 3)))
        if r.random() < p["err"]:
            for name in ("plan", "writer", "arg", "rerr", "werr"):
                if r.random() < 0.3:
                    setattr(e, name, r.getrandbits(STREAMS) if r.random() < 0.5 else 1 << r.randrange(STREAMS))
            e.hbm = int(r.random() < 0.1)
        e.hbm = e.hbm or int(r.random() < p["hbm"])
        e.apply(inp)
        inp.abort = abort
        if not (e.rerr or e.werr) and p["junk"]:
            inp.rerr_mask, inp.werr_mask = r.getrandbits(STREAMS), r.getrandbits(STREAMS)


class Bench:
    def __init__(self, dut, salt):
        self.dut = dut
        self.rng = seeded(salt)
        self.log = dut._log
        self.model = FsCtrlModel(STREAMS, NUM_QUEUES, EPS, QUIET)
        self.emu = PlaneEmu(self.rng)
        self.chaos = None
        self.pins = Pins(dut)
        self.sb = Scoreboard("fs_ctrl")
        self.inp = CtrlIn(bytes_vld=[0] * EPS, bytes_n=[0] * EPS)
        self.cyc = 0
        self.got = None
        self.known = False
        self.cov = {}
        self.busy_hist = deque(maxlen=8)
        self.reset_cycles = deque(maxlen=QUIET + 8)
        self.run_cycle = None
        self.bytes_tally = [0] * STREAMS
        self.pulses = {"start": [], "abort": [], "clear": []}
        self.handles = {"ss": [dut.STREAM_STATUS[s] for s in range(STREAMS)],
                        "ei": [dut.ERR_INFO[s] for s in range(STREAMS)],
                        "ib": [dut.IN_BYTES[s] for s in range(STREAMS)]}

    @classmethod
    async def create(cls, dut, salt):
        tb = cls(dut, salt)
        start_clock(dut)
        tb.inp.drives, tb.inp.chunk = 1, 4
        await settle(dut)
        for _ in range(6):
            tb.inp.reset = 1
            await tb.tick()
        return tb

    def count(self, key, n=1):
        self.cov[key] = self.cov.get(key, 0) + n

    # ---------------------------------------------------------------------------------- sampling
    def sample(self):
        d, h = self.dut, self.handles
        return CtrlOut(
            plane_clear=signal_int(d.PLANE_CLEAR), plane_start=signal_int(d.PLANE_START),
            plane_abort=signal_int(d.PLANE_ABORT), enable=signal_int(d.ENABLE), sink=signal_int(d.SINK),
            busy=signal_int(d.STATUS_BUSY), done=signal_int(d.STATUS_DONE), err=signal_int(d.STATUS_ERR),
            state=signal_int(d.STATUS_STATE), stream_status=tuple(signal_int(x) for x in h["ss"]),
            err_info=tuple(signal_int(x) for x in h["ei"]), in_bytes=tuple(signal_int(x) for x in h["ib"]))

    def diag(self, exp, got):
        diffs = [f"{f}: got {g}, expected {x}" for f, g, x in zip(CtrlOut._fields, got, exp) if g != x]
        return (f"cycle {self.cyc} (model {STATE_NAMES[self.model.state]}): " + "; ".join(diffs))

    def check_invariants(self, got, busy, inp):
        """Rules that must hold whatever the reference model says."""
        prev, v = self.got, self.cyc
        if inp.rd_eof & EPS_ALL:
            self.reset_cycles.append(v)
        self.busy_hist.append(busy)
        if got.plane_start:
            self.pulses["start"].append((v, got.plane_start))
        if got.plane_abort:
            self.pulses["abort"].append((v, 1))
        if got.plane_clear:
            self.pulses["clear"].append((v, 1))
            self.bytes_tally = [0] * STREAMS
        for s in range(STREAMS):
            self.bytes_tally[s] += sum(inp.bytes_n[e] for e in range(EPS) if inp.bytes_vld[e] >> s & 1)
        if prev is None or prev.state == got.state:
            return
        a, b = prev.state, got.state
        legal = {S_IDLE: (S_RUN, S_ERR), S_RUN: (S_DRAIN, S_DONE), S_DRAIN: (S_IDLE, S_ERR), S_DONE: (S_IDLE,),
                 S_ERR: (S_IDLE,)}
        assert b in legal[a], f"cycle {v}: illegal transition {STATE_NAMES[a]} -> {STATE_NAMES[b]}"
        self.count(f"{STATE_NAMES[a]}->{STATE_NAMES[b]}")
        if a == S_IDLE:
            self.reset_cycles.append(v - 1)
            self.run_cycle = v
        if (a, b) in ((S_RUN, S_DONE), (S_DRAIN, S_IDLE), (S_DRAIN, S_ERR)):
            quiet_hit = [r for r in self.reset_cycles if v - 1 - QUIET <= r <= v - 2]
            assert not quiet_hit, f"cycle {v}: left {STATE_NAMES[a]} within {QUIET} cycles of a frame end/start {quiet_hit}"
            hist = list(self.busy_hist)
            if len(hist) >= 6:
                assert not any(hist[-6:-3]), f"cycle {v}: left {STATE_NAMES[a]} with the datapath busy three samples back"

    # -------------------------------------------------------------------------------------- clock
    async def tick(self):
        inp = self.inp
        self.emu.prepare(self, inp)
        if self.chaos is not None:
            self.chaos.prepare(self, inp)
        self.pins.drive(inp)
        busy = int((not inp.rd_idle) or (inp.rd_data_idle & EPS_ALL) != EPS_ALL or (inp.wr_busy & ALL)
                   or self.model.wr_flight != 0)
        await RisingEdge(self.dut.CLK)
        if inp.reset:
            self.emu.reset()
        got = self.sample() if self.known else None
        exp = self.model.step(inp)
        if got is not None:
            self.sb.expect(exp)
            try:
                self.sb.check(got)
            except AssertionError:
                raise AssertionError(self.diag(exp, got)) from None
            self.check_invariants(got, busy, inp)
            self.got = got
        if inp.reset:
            self.known = True
            self.got = None
            self.reset_cycles.clear()
            self.busy_hist.clear()
        self.cyc += 1
        await Timer(1, unit="ns")
        for f in PULSES:
            setattr(inp, f, 0)

    async def ticks(self, n):
        for _ in range(n):
            await self.tick()

    @property
    def state(self):
        """The state of the cycle the next tick drives."""
        return self.model.state

    async def until(self, pred, limit=20000, what="condition"):
        for _ in range(limit):
            if pred():
                return
            await self.tick()
        raise AssertionError(f"cycle {self.cyc}: {what} not reached in {limit} cycles, model {STATE_NAMES[self.state]}")

    def mark(self):
        for v in self.pulses.values():
            v.clear()

    # ------------------------------------------------------------------------------------ flows
    def cfg(self, mask, drives=None, chunk=None):
        self.inp.mask = mask
        self.inp.drives = self.rng.randint(0, MAX_LD) if drives is None else drives
        self.inp.chunk = self.rng.randint(1, fc.MAX_LOG2_CHUNK) if chunk is None else chunk

    async def start_job(self, mask, drives=None, chunk=None, until_run=True):
        """START from IDLE; returns with the model in RUN (or ERR for a bad geometry)."""
        assert self.state == S_IDLE, STATE_NAMES[self.state]
        self.cfg(mask, drives, chunk)
        self.inp.start = 1
        await self.tick()
        if until_run:
            await self.until(lambda: self.state in (S_RUN, S_ERR), 100, "RUN or ERR")

    async def clear_job(self):
        """CLEAR from any state; returns once the planes were cleared."""
        self.inp.clear = 1
        await self.tick()
        await self.until(lambda: self.state == S_IDLE, 6000, "IDLE after CLEAR")
        await self.ticks(6)

    async def stays(self, state, n, what=""):
        """The state holds for n cycles and the planes get no START."""
        for _ in range(n):
            await self.tick()
            assert self.state == state, f"cycle {self.cyc}: {what} left {STATE_NAMES[state]} for {STATE_NAMES[self.state]}"
            assert self.got.plane_start == 0, f"cycle {self.cyc}: {what} started the planes"

    def finish(self):
        self.log.info("%d cycles checked, %d scoreboard items, coverage %s", self.cyc, self.sb.checked, self.cov)


async def error_job(tb, mask, inj, delay=None):
    """START, inject at a random point of RUN, follow to the end and check every stream's outcome."""
    await tb.start_job(mask)
    assert tb.state == S_RUN
    await tb.ticks(tb.rng.randint(1, 40) if delay is None else delay)
    tb.mark()
    inj.apply(tb.inp)
    await tb.tick()
    fail = inj.fails_job(mask)
    if fail:
        await tb.until(lambda: tb.state == S_ERR, 6000, "ERR")
    else:
        await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
    await tb.ticks(3)
    g = tb.got
    assert (g.state, g.err, g.done) == ((S_ERR, 1, 0) if fail else (S_DONE, 0, 1)), f"ended in state {g.state}"
    if fail:
        assert len(tb.pulses["abort"]) == 1, f"{len(tb.pulses['abort'])} PLANE_ABORT pulses"
        tb.count("err_job")
    for s in range(STREAMS):
        w = inj.winner(s) if mask >> s & 1 else None
        want_info = w[1] if w else 0
        want_bit = fc.SS_ERR if w else 0
        assert g.err_info[s] == want_info, f"stream {s}: ERR_INFO {g.err_info[s]:#x}, expected {want_info:#x} ({w})"
        assert g.stream_status[s] & fc.SS_ERR == want_bit, f"stream {s}: error bit {g.stream_status[s]:#x} ({w})"
        if w:
            tb.count(f"win_{w[0]}")
    return g


# ===================================================================================== tests
@cocotb.test()
async def run_jobs(dut):
    """Jobs to DONE with random activity and masks: one START pulse, DONE only after the quiet window,
    IN_BYTES equal to the bytes fed, and CLEAR returning everything to zero."""
    tb = await Bench.create(dut, 0x101)
    rng = tb.rng
    masks = [ALL, 1, 1 << (STREAMS - 1), 5 & ALL or 1] + [rng.randint(1, ALL) for _ in range(6)]
    for mask in masks:
        tb.emu.randomize()
        tb.mark()
        await tb.start_job(mask)
        assert tb.state == S_RUN
        await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
        run_len = tb.cyc - tb.run_cycle
        assert run_len >= QUIET, f"DONE {run_len} cycles after START, the quiet window is {QUIET}"
        await tb.ticks(6)
        g = tb.got
        assert (g.state, g.done, g.busy, g.err, g.sink, g.enable) == (S_DONE, 1, 0, 0, 0, 0), f"outputs {g}"
        assert not any(g.err_info) and not any(x & fc.SS_ERR for x in g.stream_status)
        for s in bits(mask):
            assert g.stream_status[s] & 3 == 3, f"stream {s} DONE without in/out done: {g.stream_status[s]:#x}"
        assert g.in_bytes == tuple(tb.bytes_tally), f"IN_BYTES {g.in_bytes}, fed {tb.bytes_tally}"
        assert [m for _, m in tb.pulses["start"]] == [mask] and not tb.pulses["abort"], tb.pulses
        await tb.clear_job()
        g = tb.got
        assert (g.state, g.done, g.busy, g.err) == (S_IDLE, 0, 0, 0) and not any(g.in_bytes)
        assert len(tb.pulses["clear"]) == 1
        tb.count("jobs")
    tb.finish()


@cocotb.test()
async def run_start_ignored(dut):
    """START is latched only in IDLE: while busy, draining, done or failed it is dropped for good,
    and a START that has not executed when CLEAR comes is dropped too."""
    tb = await Bench.create(dut, 0x202)
    rng = tb.rng
    for _ in range(2):
        # A burst of STARTs around one job: one job, one PLANE_START.
        tb.emu.randomize()
        tb.mark()
        await tb.start_job(rng.randint(1, ALL))
        for _ in range(8):
            tb.inp.start = int(rng.random() < 0.5)
            await tb.tick()
            assert tb.state == S_RUN
        await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
        assert len(tb.pulses["start"]) == 1
        for _ in range(5):
            tb.inp.start = 1
            await tb.tick()
        await tb.stays(S_DONE, 5, "START in DONE")
        tb.inp.start = 1
        await tb.clear_job()
        await tb.stays(S_IDLE, 80, "START carried over a CLEAR")
        tb.count("start_burst")

    # An error drain ends in ERR whatever STARTs arrive meanwhile; ERR then drops them as well.
    tb.emu.randomize()
    tb.mark()
    await tb.start_job(ALL)
    await tb.ticks(rng.randint(2, 30))
    tb.inp.abort = 1
    await tb.tick()
    await tb.until(lambda: tb.state == S_DRAIN, 20, "DRAIN")
    while tb.state == S_DRAIN:
        tb.inp.start = int(rng.random() < 0.3)
        await tb.tick()
        tb.count("start_in_drain")
        assert tb.state in (S_DRAIN, S_ERR)
    await tb.ticks(4)
    assert tb.got.state == S_ERR
    assert len(tb.pulses["start"]) == 1, "START in DRAIN or ERR reached the planes"
    for _ in range(5):
        tb.inp.start = 1
        await tb.tick()
    await tb.stays(S_ERR, 6, "START in ERR")
    await tb.clear_job()
    await tb.stays(S_IDLE, 80, "a START during the drain")

    # A START inside the drain a CLEAR started must not start the next job once IDLE returns.
    tb.emu.randomize()
    tb.mark()
    await tb.start_job(rng.randint(1, ALL))
    await tb.ticks(rng.randint(2, 30))
    tb.inp.clear = 1
    await tb.tick()
    await tb.until(lambda: tb.state == S_DRAIN, 3, "DRAIN")
    while tb.state == S_DRAIN:
        tb.inp.start = int(rng.random() < 0.5)
        await tb.tick()
    await tb.ticks(4)
    assert tb.got.state == S_IDLE and len(tb.pulses["start"]) == 1
    await tb.stays(S_IDLE, 100, "a START in the CLEAR drain")

    # Latched in the first IDLE cycles, before the three quiet samples let it execute: a CLEAR up to
    # one cycle later wins; two cycles later the START has already begun the job.
    for gap in (0, 1, 2):
        tb.emu.randomize()
        await tb.start_job(rng.randint(1, ALL))
        await tb.ticks(rng.randint(1, 20))
        tb.inp.clear = 1
        await tb.tick()
        await tb.until(lambda: tb.state == S_IDLE, 6000, "IDLE")
        tb.mark()
        tb.cfg(rng.randint(1, ALL))
        tb.inp.start = 1
        await tb.tick()
        await tb.ticks(gap)
        tb.inp.clear = 1
        await tb.tick()
        if gap < 2:
            await tb.stays(S_IDLE, 40, f"START {gap} cycles before CLEAR")
            assert not tb.pulses["start"]
            tb.count("start_dropped_by_clear")
        else:
            await tb.until(lambda: tb.state == S_RUN, 20, "RUN")
            await tb.clear_job()
            tb.count("start_won_race")
    # And a START coinciding with the CLEAR that executes.
    for _ in range(4):
        tb.inp.clear = 1
        tb.inp.start = 1
        await tb.tick()
        await tb.stays(S_IDLE, 20, "START with CLEAR")
    tb.finish()


@cocotb.test()
async def run_clear(dut):
    """CLEAR in every state: mid-job it drains first (abort pulse, SINK), the quiet window restarts on
    every frame end, errors are discarded, the planes are cleared once and everything reads zero."""
    tb = await Bench.create(dut, 0x303)
    rng = tb.rng
    for k in range(6):
        tb.emu.randomize()
        tb.emu.configure(drain_eofs=("restart", 3) if k < 3 else None)
        tb.mark()
        mask = rng.randint(1, ALL)
        await tb.start_job(mask)
        await tb.ticks(rng.randint(1, 120))
        tb.inp.clear = 1
        await tb.tick()
        await tb.until(lambda: tb.state == S_DRAIN, 3, "DRAIN")
        t0 = tb.cyc
        sunk = 0
        while tb.state == S_DRAIN:
            await tb.tick()
            g = tb.got
            if g.state == S_DRAIN:
                assert (g.sink, g.enable, g.busy, g.done, g.err) == (1, 0, 1, 0, 0), f"outputs {g}"
                sunk += 1
        await tb.until(lambda: tb.state == S_IDLE, 6000, "IDLE")
        await tb.ticks(6)
        g = tb.got
        assert g.state == S_IDLE and not any(g.err_info) and not any(g.in_bytes)
        assert len(tb.pulses["abort"]) == 1 and len(tb.pulses["clear"]) == 1 and len(tb.pulses["start"]) == 1
        if k < 3:
            assert tb.cyc - t0 > QUIET, f"the drain ended {tb.cyc - t0} cycles after CLEAR despite frame ends"
            tb.count("quiet_restart")
        tb.count("clear_mid_job")
    # CLEAR during an error drain discards the error: IDLE, not ERR.
    for _ in range(2):
        tb.emu.randomize()
        tb.emu.configure(drain_eofs=None)
        await tb.start_job(ALL)
        await tb.ticks(rng.randint(2, 30))
        tb.inp.hbm_err = 1
        await tb.tick()
        assert tb.state == S_DRAIN
        await tb.ticks(rng.randint(0, 5))
        tb.inp.clear = 1
        await tb.tick()
        await tb.until(lambda: tb.state == S_IDLE, 6000, "IDLE")
        await tb.ticks(6)
        assert not any(tb.got.err_info) and not any(x & fc.SS_ERR for x in tb.got.stream_status)
        tb.count("clear_in_err_drain")
    # CLEAR in DONE, in ERR (geometry), in IDLE and twice in a row.
    tb.emu.randomize()
    await tb.start_job(rng.randint(1, ALL))
    await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
    await tb.clear_job()
    await tb.start_job(ALL, drives=0, chunk=0)
    assert tb.state == S_ERR
    await tb.ticks(5)
    assert tb.got.state == S_ERR and tb.got.sink == 1
    await tb.clear_job()
    for _ in range(3):
        tb.inp.clear = 1
        await tb.tick()
        await tb.stays(S_IDLE, rng.randint(0, 6), "CLEAR in IDLE")
    tb.inp.clear = 1
    await tb.tick()
    tb.inp.clear = 1
    await tb.tick()
    await tb.stays(S_IDLE, 10, "double CLEAR")
    tb.finish()


@cocotb.test()
async def run_errors(dut):
    """Every error source on its own and all of them layered: the source that names a stream fails the
    job and, in the fixed priority, fills its ERR_INFO; HBM and ABORT name every enabled stream, the
    others only their own; the first error of a stream stays; errors outside RUN and DRAIN are dropped."""
    tb = await Bench.create(dut, 0x404)
    rng = tb.rng
    n = STREAMS

    def reach(k):
        return sum(1 << s for s in range(min(k + 1, n)))

    # Layered: stream s sees the sources from priority s down, so each wins once.
    for rep in range(2):
        tb.emu.randomize()
        inj = Inject(plan=reach(0), writer=reach(1), arg=reach(2), rerr=reach(3), werr=reach(4), hbm=1, abort=1,
                     rng=rng, rerr_info=fc.err_info(0, fc.CODE_FAIL, 1, 2, 0x55AA))
        await error_job(tb, ALL, inj)
        await tb.clear_job()
    # Each source alone, with information that tells them apart.
    singles = (
        dict(plan=ALL), dict(writer=ALL), dict(arg=ALL), dict(rerr=ALL), dict(werr=ALL), dict(hbm=1), dict(abort=1),
        dict(plan=1 << (n - 1)), dict(writer=1), dict(arg=2 & ALL or 1), dict(rerr=reach(2)), dict(werr=1 << (n // 2)),
    )
    for kw in singles:
        tb.emu.randomize()
        await error_job(tb, ALL, Inject(rng=rng, **kw))
        await tb.clear_job()
    # FS_CTRL passes every read error info through unchanged; FS_RD_ISSUE already zeroes a rejected read's identity.
    for code in (fc.CODE_OOR, fc.CODE_FAIL, fc.CODE_LOST, fc.CODE_OK):
        info = fc.err_info(fc.ERR_SRC_NVME, code, 1, rng.randint(0, 3), rng.getrandbits(16)) | rng.getrandbits(4) << 12
        await error_job(tb, ALL, Inject(rerr=ALL, rng=rng, rerr_info=info))
        await tb.clear_job()
    # Errors that name a disabled stream do not fail the job; HBM and ABORT fail it even with no stream.
    mask = 0b0110 & ALL
    for kw in (dict(plan=1), dict(writer=1 << (n - 1)), dict(arg=1), dict(rerr=1), dict(werr=1 << (n - 1))):
        await error_job(tb, mask, Inject(rng=rng, **kw))
        await tb.clear_job()
    for kw in (dict(hbm=1), dict(abort=1)):
        await error_job(tb, 0, Inject(rng=rng, **kw))
        await tb.clear_job()
    # Random combinations, on random masks.
    for _ in range(8):
        tb.emu.randomize()
        pick = {name: rng.getrandbits(n) if rng.random() < 0.5 else 1 << rng.randrange(n)
                for name in ("plan", "writer", "arg", "rerr", "werr") if rng.random() < 0.5}
        inj = Inject(rng=rng, hbm=int(rng.random() < 0.15), abort=int(rng.random() < 0.15), **pick)
        await error_job(tb, rng.randint(1, ALL), inj)
        await tb.clear_job()
    # The first error of a stream stays; the others still collect theirs while the job drains.
    tb.emu.randomize()
    await tb.start_job(ALL)
    await tb.ticks(5)
    first = Inject(arg=1, rng=rng)
    first.apply(tb.inp)
    await tb.tick()
    assert tb.state == S_DRAIN
    await tb.ticks(rng.randint(0, 3))
    later = Inject(plan=0b11, rng=rng)
    later.apply(tb.inp)
    await tb.tick()
    await tb.ticks(1)
    later2 = Inject(abort=1, writer=1 << (n - 1), rng=rng)
    later2.apply(tb.inp)
    await tb.until(lambda: tb.state == S_ERR, 6000, "ERR")
    await tb.ticks(3)
    g = tb.got
    assert g.err_info[0] == fc.err_info(fc.ERR_SRC_FORMAT, 0, 0, 0, 0), "a later error replaced the first one"
    assert g.err_info[1] == later.plan_info[1], "an error in DRAIN was not recorded"
    assert g.err_info[2] == fc.err_info(fc.ERR_SRC_ABORT, 0, 0, 0, 0)
    await tb.clear_job()
    # Errors in IDLE, DONE and ERR change nothing.
    everything = Inject(plan=ALL, writer=ALL, arg=ALL, rerr=ALL, werr=ALL, hbm=1, abort=1, rng=rng)
    for _ in range(3):
        everything.apply(tb.inp)
        await tb.tick()
    await tb.stays(S_IDLE, 4, "errors in IDLE")
    assert not any(tb.got.err_info)
    tb.emu.randomize()
    await tb.start_job(rng.randint(1, ALL))
    await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
    for _ in range(3):
        everything.apply(tb.inp)
        await tb.tick()
    await tb.stays(S_DONE, 4, "errors in DONE")
    assert not any(tb.got.err_info) and tb.got.err == 0
    await tb.clear_job()
    mask = 0b0011 & ALL
    await error_job(tb, mask, Inject(arg=1, rng=rng))
    held = tb.got.err_info
    for _ in range(3):
        everything.apply(tb.inp)
        await tb.tick()
    await tb.stays(S_ERR, 4, "errors in ERR")
    assert tb.got.err_info == held, "an error in ERR rewrote ERR_INFO"
    tb.finish()


@cocotb.test()
async def run_geometry(dut):
    """Every STRIPE geometry at START: a chunk of 2..256 LBAs on a drive count the queues serve runs,
    anything else ends in ERR at once with the format error on the enabled streams only."""
    tb = await Bench.create(dut, 0x505)
    rng = tb.rng
    combos = [(d, c) for d in range(16) for c in range(16)]
    valid = [x for x in combos if geom_valid(*x)]
    full = {(MAX_LD, 1), (MAX_LD, fc.MAX_LOG2_CHUNK), (0, 1), (0, fc.MAX_LOG2_CHUNK)}
    full |= set(rng.sample(valid, 4))
    for drives, chunk in combos:
        mask = rng.choice((ALL, rng.randint(1, ALL), rng.randint(1, ALL)))
        ok = geom_valid(drives, chunk)
        if ok and (drives, chunk) not in full:
            continue
        tb.emu.randomize()
        tb.mark()
        await tb.start_job(mask, drives=drives, chunk=chunk)
        if ok:
            assert tb.state == S_RUN, f"geometry ({drives},{chunk}) rejected"
            await tb.ticks(rng.randint(1, 10))
            assert tb.got.enable == mask and len(tb.pulses["start"]) == 1
            tb.count("geom_valid")
        else:
            assert tb.state == S_ERR, f"geometry ({drives},{chunk}) accepted"
            await tb.ticks(3)
            g = tb.got
            assert (g.state, g.err, g.busy, g.sink, g.enable) == (S_ERR, 1, 0, 1, 0), f"outputs {g}"
            assert not tb.pulses["start"], "PLANE_START for a bad geometry"
            for s in range(STREAMS):
                on = mask >> s & 1
                assert g.err_info[s] == (fc.err_info(fc.ERR_SRC_FORMAT, 0, 0, 0, 0) if on else 0), \
                    f"stream {s} (enabled {on}): ERR_INFO {g.err_info[s]:#x}"
                assert g.stream_status[s] & fc.SS_ERR == (fc.SS_ERR if on else 0), f"stream {s}"
            tb.count("geom_invalid")
        await tb.clear_job()
    tb.finish()


@cocotb.test()
async def run_masks(dut):
    """Stream mask corners: none enabled (DONE after the quiet window, ABORT and HBM_ERR still fail it),
    all enabled, one at a time, and a DONE that waits for the last in/out flag of an enabled stream."""
    tb = await Bench.create(dut, 0x606)
    rng = tb.rng
    tb.emu.randomize()
    tb.mark()
    await tb.start_job(0)
    await tb.until(lambda: tb.state == S_DONE, 6000, "DONE")
    assert tb.cyc - tb.run_cycle >= QUIET
    await tb.ticks(4)
    assert tb.got.done == 1 and not any(tb.got.err_info) and tb.got.enable == 0
    await tb.clear_job()
    for kw in (dict(abort=1), dict(hbm=1)):
        await error_job(tb, 0, Inject(rng=rng, **kw), delay=rng.randint(1, 20))
        assert tb.got.state == S_ERR and not any(x & fc.SS_ERR for x in tb.got.stream_status)
        await tb.clear_job()
    # One stream at a time; errors for the others are ignored, the flags of the others do not matter.
    for s in range(STREAMS):
        tb.emu.randomize()
        tb.emu.configure(work=(60, 200))
        other = (ALL & ~(1 << s)) or 1
        await error_job(tb, 1 << s, Inject(plan=other, writer=other, arg=other, rng=rng), delay=rng.randint(1, 20))
        assert tb.got.state == S_DONE and tb.got.stream_status[s] & 3 == 3
        await tb.clear_job()
    # DONE waits for the in and the out flag of every enabled stream.
    for kind in ("in", "out"):
        s = rng.randrange(STREAMS)
        tb.emu.randomize()
        tb.emu.configure(work=(60, 200), hold={(kind, s)})
        await tb.start_job(ALL)
        await tb.ticks(3 * QUIET)
        assert tb.state == S_RUN, f"DONE without the {kind} flag of stream {s}"
        tb.emu.configure(hold=())
        await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
        tb.count("done_waited")
        await tb.clear_job()
    tb.emu.randomize()
    await tb.start_job(ALL)
    await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
    await tb.ticks(4)
    assert all(x & 3 == 3 for x in tb.got.stream_status)
    tb.finish()


@cocotb.test()
async def run_quiet_window(dut):
    """Frame ends keep the quiet window open before DONE as well as in a drain: DONE and the end of
    the drain each come a whole window after the last frame end."""
    tb = await Bench.create(dut, 0x707)
    for spec in (("restart", 1), ("restart", 2)):
        tb.emu.randomize()
        tb.emu.configure(work=(60, 200), tail_eofs=spec, p_eof=0.0)
        await tb.start_job(tb.rng.randint(1, ALL))
        t0 = tb.cyc
        await tb.until(lambda: tb.state == S_DONE, 20000, "DONE")
        assert tb.cyc - t0 > QUIET + (spec[1] - 1) * (QUIET - 30), f"DONE after {tb.cyc - t0} cycles despite frame ends"
        tb.count("done_restarted")
        await tb.clear_job()
        tb.emu.configure(tail_eofs=None, drain_eofs=spec)
        await tb.start_job(tb.rng.randint(1, ALL))
        await tb.ticks(tb.rng.randint(1, 20))
        tb.inp.abort = 1
        t0 = tb.cyc
        await tb.tick()
        await tb.until(lambda: tb.state == S_ERR, 20000, "ERR")
        if QUIET >= 100:
            assert tb.cyc - t0 > QUIET + (spec[1] - 1) * (QUIET - 30), f"drain over after {tb.cyc - t0} cycles"
        await tb.clear_job()
        tb.count("drain_restarted")
    tb.finish()


@cocotb.test()
async def run_reset(dut):
    """RESET in every state, with a START or CLEAR pending and writes in flight, returns the controller
    to IDLE with zeroed outputs, and the next job runs clean."""
    tb = await Bench.create(dut, 0x808)
    rng = tb.rng
    for target in (S_IDLE, S_RUN, S_DRAIN, S_DONE, S_ERR, S_RUN, S_DRAIN):
        tb.emu.randomize()
        tb.emu.configure(work=(60, 200))
        mask = rng.randint(1, ALL)
        if target == S_RUN:
            await tb.start_job(mask)
            await tb.ticks(rng.randint(1, 100))
        elif target == S_DRAIN:
            await tb.start_job(mask)
            await tb.ticks(rng.randint(1, 30))
            tb.inp.abort = 1
            await tb.tick()
            await tb.ticks(rng.randint(0, 20))
        elif target == S_DONE:
            await tb.start_job(mask)
            await tb.until(lambda: tb.state == S_DONE, 12000, "DONE")
        elif target == S_ERR:
            await tb.start_job(mask, drives=0, chunk=0)
        tb.inp.reset = 1
        tb.inp.start = int(rng.random() < 0.5)
        tb.inp.clear = int(rng.random() < 0.5)
        await tb.tick()
        await tb.ticks(2)
        g = tb.got
        assert g.state == S_IDLE and not any(g.err_info) and not any(g.in_bytes) and g.busy == 0, f"outputs {g}"
        tb.mark()
        await tb.start_job(rng.randint(1, ALL))
        await tb.until(lambda: tb.state == S_DONE, 12000, "DONE after RESET")
        await tb.clear_job()
        tb.count("reset_in_" + STATE_NAMES[target])
    tb.finish()


@cocotb.test()
async def run_soak(dut):
    """Random commands, errors, mask and stripe changes at any time over many jobs, in episodes of
    different rates; every output of every cycle against the model."""
    tb = await Bench.create(dut, 0x909)
    tb.chaos = Chaos(tb.rng)
    cycles = int(os.environ.get("SOAK_CYCLES", 90000))
    await tb.ticks(cycles)
    for key in ("RUN->DONE", "RUN->DRAIN", "DRAIN->ERR", "DRAIN->IDLE", "IDLE->ERR", "DONE->IDLE", "ERR->IDLE"):
        assert tb.cov.get(key, 0) > 0, f"the soak never made the transition {key}"
    tb.finish()
