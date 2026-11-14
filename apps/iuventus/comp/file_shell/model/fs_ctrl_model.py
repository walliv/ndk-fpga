# fs_ctrl_model.py: reference model of FS_CTRL, the job controller of the file shell
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""One call of `step` is one clock cycle: it returns the outputs that cycle shows and then
advances the registers. The job FSM, the drain rules and the error attribution follow the register
contract of fs_regs.vhd and fs_pkg.vhd; the datapath is reduced to the activity inputs."""

from collections import namedtuple
from dataclasses import dataclass, field

from fs_ctx import (ERR_SRC_ABORT, ERR_SRC_FORMAT, ERR_SRC_HBM, MASK64, MAX_LOG2_CHUNK,
                    MAX_LOG2_DRIVES, MAX_STREAMS, SS_ERR, SS_IN_DONE, SS_NEED_SPACE, SS_OUT_DONE, err_info)

S_IDLE, S_RUN, S_DRAIN, S_DONE, S_ERR = range(5)
STATE_NAMES = ("IDLE", "RUN", "DRAIN", "DONE", "ERR")

# Consecutive quiet samples inside a state before the datapath counts as idle.
SETTLE = 3

INFO_ABORT = err_info(ERR_SRC_ABORT, 0, 0, 0, 0)
INFO_HBM = err_info(ERR_SRC_HBM, 0, 0, 0, 0)
# A bad stripe and a kernel's ARG_ERR name no ring entry.
INFO_ARG = err_info(ERR_SRC_FORMAT, 0, 0, 0, 0)


@dataclass
class CtrlIn:
    """Every input of FS_CTRL during one cycle; vectors are ints, per-stream info lists."""
    reset: int = 0
    start: int = 0
    abort: int = 0
    clear: int = 0
    mask: int = 0
    drives: int = 0
    chunk: int = 0
    in_done: int = 0
    out_done: int = 0
    need_space: int = 0
    plan_err: int = 0
    plan_info: list = field(default_factory=lambda: [0] * MAX_STREAMS)
    writer_err: int = 0
    writer_info: list = field(default_factory=lambda: [0] * MAX_STREAMS)
    arg_err: int = 0
    rerr_vld: int = 0
    rerr_mask: int = 0
    rerr_info: int = 0
    werr_vld: int = 0
    werr_mask: int = 0
    werr_info: int = 0
    hbm_err: int = 0
    rd_idle: int = 1
    rd_data_idle: int = -1
    rd_eof: int = 0
    wr_busy: int = 0
    wr_outstanding: int = 0
    wr_frame: int = 0
    wr_status: int = 0
    bytes_vld: list = field(default_factory=lambda: [0])
    bytes_n: list = field(default_factory=lambda: [0])


CtrlOut = namedtuple("CtrlOut", "plane_clear plane_start plane_abort enable sink busy done err state "
                                "stream_status err_info in_bytes")


class FsCtrlModel:
    def __init__(self, streams=MAX_STREAMS, num_queues=4, endpoints=1, done_quiet=1024):
        self.streams = streams
        self.endpoints = endpoints
        self.done_quiet = done_quiet
        self.all_streams = (1 << streams) - 1
        self.all_eps = (1 << endpoints) - 1
        self.max_log2_drives = min(MAX_LOG2_DRIVES, max(num_queues, 1).bit_length() - 1)
        self.flight_mod = 1 << ((num_queues * 128 - 1).bit_length() + 1)
        self.reset()

    def reset(self):
        self.state = S_IDLE
        self.start_pend = 0
        self.clear_pend = 0
        self.mask_r = 0
        self.dp_idle_r = 0
        self.idle_cnt = 0
        self.quiet_cnt = 0
        self.wr_flight = 0
        self.stream_err = [0] * self.streams
        self.err_info_r = [0] * self.streams
        self.plane_clear_r = 0
        self.plane_start_r = 0
        self.plane_abort_r = 0
        self.inc_r = [0] * self.streams
        self.acc_r = [0] * self.streams

    def geom_ok(self, drives, chunk):
        return 1 <= chunk <= MAX_LOG2_CHUNK and drives <= self.max_log2_drives

    def stream_error(self, i, s):
        """The info the highest-priority source naming stream `s` carries, None without one. Order:
        plane error, writer error, kernel ARG_ERR, read error, write error, HBM error, ABORT."""
        if i.plan_err >> s & 1:
            return i.plan_info[s]
        if i.writer_err >> s & 1:
            return i.writer_info[s]
        if i.arg_err >> s & 1:
            return INFO_ARG
        if i.rerr_vld and i.rerr_mask >> s & 1:
            return i.rerr_info
        if i.werr_vld and i.werr_mask >> s & 1:
            return i.werr_info
        if i.hbm_err:
            return INFO_HBM
        if i.abort:
            return INFO_ABORT
        return None

    def step(self, i):
        st = self.state
        n = self.streams
        geom_ok = self.geom_ok(i.drives, i.chunk)
        dp_idle = (i.rd_idle and i.rd_data_idle & self.all_eps == self.all_eps and i.wr_busy & self.all_streams == 0
                   and self.wr_flight == 0)
        idle_ok = self.idle_cnt == SETTLE
        quiet_ok = self.quiet_cnt == self.done_quiet
        all_done = self.mask_r & ~(i.in_done & i.out_done) == 0
        start_exec = st == S_IDLE and self.start_pend and not self.clear_pend and idle_ok
        clear_exec = bool(self.clear_pend and idle_ok
                          and (st in (S_IDLE, S_DONE, S_ERR) or (st == S_DRAIN and quiet_ok)))
        live = st in (S_RUN, S_DRAIN)

        errs = [self.stream_error(i, s) if live and self.mask_r >> s & 1 else None for s in range(n)]
        err_any = any(e is not None for e in errs) or (live and (i.abort or i.hbm_err))

        if st == S_IDLE:
            nxt = (S_RUN if geom_ok else S_ERR) if start_exec else st
        elif st == S_RUN:
            if err_any or self.clear_pend:
                nxt = S_DRAIN
            elif all_done and idle_ok and quiet_ok:
                nxt = S_DONE
            else:
                nxt = st
        elif st == S_DRAIN:
            if idle_ok and quiet_ok:
                nxt = S_IDLE if self.clear_pend else S_ERR
            else:
                nxt = st
        else:
            nxt = S_IDLE if clear_exec else st

        out = CtrlOut(
            plane_clear=self.plane_clear_r,
            plane_start=self.plane_start_r,
            plane_abort=self.plane_abort_r,
            enable=self.mask_r if st == S_RUN else 0,
            sink=int(st in (S_DRAIN, S_ERR)),
            busy=int(st in (S_RUN, S_DRAIN) or bool(self.start_pend)),
            done=int(st == S_DONE),
            err=int(st == S_ERR),
            state=st,
            stream_status=tuple((SS_IN_DONE if i.in_done >> s & 1 else 0) | (SS_OUT_DONE if i.out_done >> s & 1 else 0)
                                | (SS_NEED_SPACE if i.need_space >> s & 1 else 0)
                                | (SS_ERR if self.stream_err[s] else 0) for s in range(n)),
            err_info=tuple(self.err_info_r),
            in_bytes=tuple(self.acc_r))

        # ------------------------------------------------------------------ registers
        prev_idle_cnt = self.idle_cnt
        new_start_pend, new_clear_pend = self.start_pend, self.clear_pend
        new_mask = self.mask_r
        new_stream_err = list(self.stream_err)
        new_err_info = list(self.err_info_r)
        plane_start = 0

        if i.start and st == S_IDLE:
            new_start_pend = 1
        if i.clear:
            new_clear_pend = 1
        if clear_exec:
            new_start_pend = new_clear_pend = 0
        if start_exec:
            new_start_pend = 0
            new_mask = i.mask
            if geom_ok:
                plane_start = i.mask
            else:
                new_stream_err = [i.mask >> s & 1 for s in range(n)]
                new_err_info = [INFO_ARG if i.mask >> s & 1 else 0 for s in range(n)]
        plane_abort = int(st == S_RUN and nxt == S_DRAIN)

        for s in range(n):
            if errs[s] is not None and not self.stream_err[s]:
                new_stream_err[s] = 1
                new_err_info[s] = errs[s]

        self.idle_cnt = 0 if (nxt != st or not self.dp_idle_r) else min(prev_idle_cnt + 1, SETTLE)
        self.dp_idle_r = int(dp_idle)

        if i.wr_frame and not i.wr_status:
            self.wr_flight = (self.wr_flight + 1) % self.flight_mod
        elif i.wr_status and not i.wr_frame:
            self.wr_flight = (self.wr_flight - 1) % self.flight_mod

        if i.rd_eof & self.all_eps or start_exec:
            self.quiet_cnt = 0
        elif self.quiet_cnt != self.done_quiet:
            self.quiet_cnt += 1

        if clear_exec:
            new_stream_err = [0] * n
            new_err_info = [0] * n

        # The bytes pipeline: the endpoints' increments summed in one stage, accumulated in the next.
        acc = [(self.acc_r[s] + self.inc_r[s]) & MASK64 for s in range(n)]
        inc = [sum(i.bytes_n[e] for e in range(self.endpoints) if i.bytes_vld[e] >> s & 1) for s in range(n)]
        if i.reset or self.plane_clear_r:
            inc, acc = [0] * n, [0] * n
        self.inc_r, self.acc_r = inc, acc

        self.plane_clear_r = int(clear_exec)
        self.plane_start_r = plane_start
        self.plane_abort_r = plane_abort
        self.start_pend, self.clear_pend = new_start_pend, new_clear_pend
        self.mask_r = new_mask
        self.stream_err, self.err_info_r = new_stream_err, new_err_info
        self.state = nxt

        if i.reset:
            self.reset()
        return out
