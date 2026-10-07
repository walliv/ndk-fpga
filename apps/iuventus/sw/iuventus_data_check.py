#!/usr/bin/env python3
# iuventus_data_check.py: fill drives with an FPGA address pattern, then check reads at line rate
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
#
# Needs USR_DATA_CHECK=1 firmware and fzc holding the drives (CONTROL bit 0 set).
# Pattern: 64-bit LE word w of sector s on queue q is q<<60 | s<<12 | w.
import argparse
import sys
import time

import nfb

from iuventus_rw_test import (
    EVCR_WINDOW_CYCLES, IuventusTest, _evcr_rate, _throughput_point_start, _throughput_point_stop,
    acquire_device_lock, assert_fzc_running,
)

SECT = 512
FILL_LBAS = 256           # one 128 KiB write frame
SPAN_MARGIN = 256         # a read starting at the top of the span reaches this far past it

# iuventus_test_ctrl data-check registers (byte offsets)
R_DC_CTRL = 0x88          # [0] pattern writes, [1] check enable, [2] clear (pulse, never used
                          # here: a campaign must not reset an active design); [31:24] = 0xDC
R_DC_SPAN = 0x8C          # span mask in LBAs applied to generated start addresses; 0 = none
R_DC_SEL = 0x90           # counter select; the write latches the snapshot read at 0x94/0x98
R_DC_CNT_LO = 0x94
R_DC_CNT_HI = 0x98
R_DC_STATUS = 0x9C
R_DC_FM_ID = 0xA0         # [7:0] cid, [19:16] qid, [20] endpoint, [31] valid
R_DC_FM_LBA_L = 0xA4
R_DC_FM_LBA_H = 0xA8
R_DC_FM_BEAT = 0xAC       # [11:0] beat within the frame, [18:16] word within the beat
R_DC_FM_EXP_L = 0xB0
R_DC_FM_EXP_H = 0xB4
R_DC_FM_GOT_L = 0xB8
R_DC_FM_GOT_H = 0xBC
R_TST_ITERATIONS = 0x1C
R_SEQ_ADDR_SEL = 0x70
R_SEQ_ADDR_LO = 0x74
R_SEQ_ADDR_HI = 0x78
R_RD_HOLD_PERIOD = 0x80
R_RD_HOLD_LEN = 0x84

CTRL_PAT_WR = 1 << 0
CTRL_CHECK = 1 << 1
CTRL_CLEAR = 1 << 2

GLOBAL_CNTS = ["rd_ok", "wr_ok", "rd_fail", "wr_fail", "oor", "lost_rpt", "orphan_lost", "rd_cid"]
EP_CNTS = ["frames", "beats", "mm_beats", "mm_frames", "len_err", "id_err", "lost_frames",
           "lost_mm_beats"]
# Per queue at Q_CNT_BASE + 3*q, at the DMA accept, in every mode: reads accepted, reads starting
# where the queue's previous read did, and reads starting where any of its last 8 reads did.
Q_CNT_BASE = 32
Q_CNTS = ["accepted", "dup_prev", "dup_last8"]
# Rate the fill time estimate assumes: four drives writing 128 KiB frames in parallel.
FILL_GBPS = 3.0
STICKY_FLAGS = ["exp_overflow", "report_cam_full", "mismatch_cam_full", "framing_err", "unexpected_frame"]
LIVE_FLAGS = ["no_expectation", "no_mismatch_pending", "no_report_pending", "in_frame"]


def pattern_word(qid: int, sector: int, word: int) -> int:
    """The 64-bit word the checker expects at word `word` (0..63) of `sector` on queue `qid`."""
    return ((qid & 0xF) << 60) | ((sector & ((1 << 48) - 1)) << 12) | (word & 0xFFF)


class DataCheck:
    """The data-check register block of iuventus_test_ctrl, on the IuventusTest's own handle."""

    def __init__(self, test: IuventusTest, endpoints: int = 2, queues: int = 4):
        self.test = test
        self.comp = test._comp
        self.endpoints = endpoints
        self.queues = queues

    def present(self) -> bool:
        return (self.comp.read32(R_DC_CTRL) >> 24) == 0xDC

    def control(self, pat_wr: bool, check: bool, clear: bool = False) -> None:
        self.comp.write32(R_DC_CTRL, (CTRL_PAT_WR if pat_wr else 0) | (CTRL_CHECK if check else 0)
                          | (CTRL_CLEAR if clear else 0))

    @property
    def span_mask(self) -> int:
        return self.comp.read32(R_DC_SPAN)

    @span_mask.setter
    def span_mask(self, val: int) -> None:
        self.comp.write32(R_DC_SPAN, val & 0xFFFFFFFF)

    def counter(self, idx: int) -> int:
        self.comp.write32(R_DC_SEL, idx)
        return self.comp.read32(R_DC_CNT_LO) | ((self.comp.read32(R_DC_CNT_HI) & 0xFFFF) << 32)

    def counters(self) -> dict:
        out = {name: self.counter(i) for i, name in enumerate(GLOBAL_CNTS)}
        out["ep"] = [{name: self.counter(len(GLOBAL_CNTS) + len(EP_CNTS)*ep + i)
                      for i, name in enumerate(EP_CNTS)} for ep in range(self.endpoints)]
        out["queue"] = [{name: self.counter(Q_CNT_BASE + len(Q_CNTS)*q + i)
                         for i, name in enumerate(Q_CNTS)} for q in range(self.queues)]
        return out

    def status(self) -> dict:
        val = self.comp.read32(R_DC_STATUS)
        out = {"raw": val, "cid_beyond_table": bool(val >> 10 & 1),
               "cid_without_accept": bool(val >> 11 & 1), "mismatch_latched": bool(val >> 31 & 1)}
        out["ep"] = [dict({n: bool(val >> (2*i + ep) & 1) for i, n in enumerate(STICKY_FLAGS)},
                          **{n: bool(val >> (16 + 2*j + ep) & 1) for j, n in enumerate(LIVE_FLAGS)})
                     for ep in range(self.endpoints)]
        return out

    def first_mismatch(self):
        ident = self.comp.read32(R_DC_FM_ID)
        if not ident >> 31:
            return None
        beat = self.comp.read32(R_DC_FM_BEAT)
        return {
            "cid": ident & 0xFF, "qid": (ident >> 16) & 0xF, "ep": (ident >> 20) & 1,
            "lba": self.comp.read32(R_DC_FM_LBA_L) | ((self.comp.read32(R_DC_FM_LBA_H) & 0xFFFF) << 32),
            "beat": beat & 0xFFF, "word": (beat >> 16) & 0x7,
            "exp": self.comp.read32(R_DC_FM_EXP_L) | (self.comp.read32(R_DC_FM_EXP_H) << 32),
            "got": self.comp.read32(R_DC_FM_GOT_L) | (self.comp.read32(R_DC_FM_GOT_H) << 32),
        }

    def seq_addr(self, qid: int) -> int:
        self.comp.write32(R_SEQ_ADDR_SEL, qid)
        return self.comp.read32(R_SEQ_ADDR_LO) | ((self.comp.read32(R_SEQ_ADDR_HI) & 0x1) << 32)

    def set_rd_hold(self, period: int, length: int) -> None:
        self.comp.write32(R_RD_HOLD_LEN, length)
        self.comp.write32(R_RD_HOLD_PERIOD, period)


def counters_diff(after, before):
    """after - before, field by field: what one point did. Counters are never cleared here, since a
    campaign must not reset any part of an active design, so every figure is a difference."""
    if isinstance(after, dict):
        return {k: counters_diff(v, before[k]) for k, v in after.items()}
    if isinstance(after, list):
        return [counters_diff(a, b) for a, b in zip(after, before)]
    return after - before


def _sticky(st: dict) -> list:
    out = [n for n in ("cid_beyond_table", "cid_without_accept") if st[n]]
    return out + [f"ep{ep}.{n}" for ep, e in enumerate(st["ep"]) for n in STICKY_FLAGS if e[n]]


def _idle(st: dict) -> bool:
    return all(e["no_expectation"] and e["no_mismatch_pending"] and e["no_report_pending"]
               and not e["in_frame"] for e in st["ep"])


def _wait(cond, sleep_fn, timeout_polls, poll_s):
    for _ in range(timeout_polls):
        if cond():
            return True
        sleep_fn(poll_s)
    return cond()


def fill_bytes(queues: int, span: int) -> int:
    return queues * (span + SPAN_MARGIN) * SECT


def run_fill(test: IuventusTest, dc: DataCheck, queues: int, span: int, sleep_fn=time.sleep,
             poll_s: float = 0.05, timeout_polls: int = 20000) -> dict:
    """Pattern over LBAs [0, span + SPAN_MARGIN) of queues 0..queues-1 in 128 KiB frames. Burst size
    stays 1: it is also the generator's frames per channel, so this is per-frame round robin. Each
    queue's sequential counter proves its coverage."""
    assert_fzc_running(test)
    assert span > 0 and span % FILL_LBAS == 0, "span must be a positive multiple of 256 LBAs"
    frames_per_q = span // FILL_LBAS + SPAN_MARGIN // FILL_LBAS
    target = frames_per_q * queues

    test.contig_test = False
    test.gen.enabled = False
    dc.span_mask = 0
    dc.control(pat_wr=True, check=False)
    before = dc.counters()
    test.set_queue_range(queues)
    # Write mode keeps the read generator off; zero iterations only load the sequential counters.
    test.tst_mode = "wr"
    test.tst_addressing = "seq"
    test.rd_req_lba_ptr = 0
    dc.comp.write32(R_TST_ITERATIONS, 0)
    test.gen.frame_length = FILL_LBAS * SECT
    test.gen.channel_increment = 1
    test.gen.bursting = False
    test.gen.burst_size = 1
    test.contig_test = True

    t0 = time.monotonic()
    wr0 = dc.counter(1)
    fc0 = test.gen.frame_count
    test.gen.enabled = True
    done = _wait(lambda: dc.counter(1) - wr0 >= target, sleep_fn, timeout_polls, poll_s)
    test.gen.enabled = False
    # Every frame the generator counted still reaches a drive; its completion closes the fill.
    issued = test.gen.frame_count - fc0
    settled = _wait(lambda: dc.counter(1) - wr0 >= issued, sleep_fn, timeout_polls, poll_s)
    written = dc.counter(1) - wr0
    test.contig_test = False
    dc.control(pat_wr=False, check=False)
    elapsed = time.monotonic() - t0

    ends = [dc.seq_addr(q) for q in range(queues)]
    short = [q for q, end in enumerate(ends) if end < span + SPAN_MARGIN]
    cnt = counters_diff(dc.counters(), before)
    return {"ok": done and settled and not short and cnt["wr_fail"] == 0 and cnt["oor"] == 0,
            "frames": written, "issued": issued, "target": target, "queue_end_lba": ends,
            "short_queues": short, "wr_fail": cnt["wr_fail"], "oor": cnt["oor"],
            "elapsed_s": elapsed}


def _drained(dc: DataCheck, before: dict) -> bool:
    """Since `before`: every accepted read (CID returned) completed, every successful frame checked,
    every mismatch judged. A still-pending report matches no frame: an orphan (lossy frame, correct
    data), awaited until its window closes."""
    def since(idx, key):
        return dc.counter(idx) - before[key]
    if since(7, "rd_cid") != since(0, "rd_ok") + since(2, "rd_fail"):
        return False
    if not _idle(dc.status()):
        return False
    frames = sum(dc.counter(len(GLOBAL_CNTS) + len(EP_CNTS)*ep) - before["ep"][ep]["frames"]
                 for ep in range(dc.endpoints))
    return frames == since(0, "rd_ok")


def run_read_point(test: IuventusTest, dc: DataCheck, addressing: str, size: int, queues: int,
                   span: int, seconds: float, hold_period: int = 0, hold_len: int = 0,
                   sleep_fn=time.sleep, settle_fn=None, poll_s: float = 0.05,
                   timeout_polls: int = 2000) -> dict:
    """One checked read point, generated starts masked into [0, span). Rates come from the
    campaign's EVENT_COUNTER window; settle_fn(seconds) -> completions/s replaces that wait."""
    assert_fzc_running(test)
    assert span & (span - 1) == 0 and span >= 2*FILL_LBAS, "span must be a power of two"

    test.contig_test = False
    dc.span_mask = span - 1
    # A request accepted while the point stops reads the manual pointer: keep it inside the fill.
    test.rd_req_lba_ptr = 0
    dc.set_rd_hold(hold_period, hold_len)
    dc.control(pat_wr=False, check=True)
    test.set_queue_range(queues)
    test.evcr_interval_cycles = EVCR_WINDOW_CYCLES

    # No reset happens between points, so the checker must start idle and in step; after a sticky
    # flag only CLEAR (forbidden in a campaign) or an FPGA reload restores that.
    before, st0, fm0 = dc.counters(), dc.status(), dc.first_mismatch()
    pre_flags, idle0 = _sticky(st0), _idle(st0)

    _throughput_point_start(test, "rd", addressing, size)
    iops = (settle_fn or (lambda s: _evcr_rate(test, s, sleep_fn)))(seconds)
    _throughput_point_stop(test, "rd", sleep_fn=sleep_fn)
    dc.set_rd_hold(0, 0)

    drained = _wait(lambda: _drained(dc, before), sleep_fn, timeout_polls, poll_s)
    cnt = counters_diff(dc.counters(), before)
    st = dc.status()
    # The latch keeps the first mismatch since the last CLEAR: one latched before this point is not
    # this point's, and this point's own first mismatch can then not be latched.
    fm = dc.first_mismatch() if fm0 is None else None
    new_flags = [f for f in _sticky(st) if f not in pre_flags]
    sectors = size + 1
    beats = sum(ep["beats"] for ep in cnt["ep"])
    frames = sum(ep["frames"] for ep in cnt["ep"])
    errors = sum(ep["mm_beats"] + ep["len_err"] + ep["id_err"] for ep in cnt["ep"])
    completed = cnt["rd_cid"] == cnt["rd_ok"] + cnt["rd_fail"]
    reasons = []
    if not idle0:
        reasons.append("the checker was not idle when the point started")
    if pre_flags:
        reasons.append(f"sticky flags set before the point: {pre_flags} -- frame tracking may be out "
                       f"of step, recoverable only by CLEAR or an FPGA reload")
    if new_flags:
        reasons.append(f"sticky flags raised: {new_flags}")
    if not drained:
        reasons.append("did not drain")
    if not completed:
        reasons.append(f"rd_cid={cnt['rd_cid']} != rd_ok={cnt['rd_ok']} + rd_fail={cnt['rd_fail']}")
    if errors:
        reasons.append(f"{errors} data, length or identity errors")
    if frames != cnt["rd_ok"] or cnt["rd_ok"] == 0:
        reasons.append(f"{frames} frames checked for {cnt['rd_ok']} successful reads")
    return {
        "addressing": addressing, "size": size, "queues": queues, "span": span,
        "hold": (hold_period, hold_len), "drained": drained, "counters": cnt, "status": st,
        "first_mismatch": fm, "first_mismatch_before": fm0, "flags_before": pre_flags,
        "flags_raised": new_flags, "iops": iops, "gbps": iops * sectors * SECT / 1e9,
        "frames": frames, "beats": beats, "bytes_checked": beats * 64,
        "all_checked": frames == cnt["rd_ok"] and beats == cnt["rd_ok"] * sectors * 8,
        "completed": completed, "reasons": reasons, "ok": not reasons,
    }


def print_point(res: dict) -> None:
    cnt, st = res["counters"], res["status"]
    print(f"{res['addressing']} {(res['size'] + 1) * SECT // 1024} KiB N={res['queues']} "
          f"span={res['span']} hold={res['hold']}: {res['iops']:.0f} completions/s, "
          f"{res['gbps']:.3f} GB/s")
    unclaimed = cnt["lost_rpt"] - cnt["orphan_lost"] - sum(c["lost_frames"] for c in cnt["ep"])
    print(f"  completions: rd_ok={cnt['rd_ok']} rd_fail={cnt['rd_fail']} oor={cnt['oor']} "
          f"lost_reports={cnt['lost_rpt']} orphan_lost={cnt['orphan_lost']} "
          f"lost_reports_without_mismatch_pending={unclaimed} rd_cid={cnt['rd_cid']}")
    # Repeated start LBAs: each random read takes a fresh draw, so a repeat is a chance collision
    # under the span mask, and may be served from the drive's cache rather than its flash.
    for q, c in enumerate(cnt["queue"]):
        acc = max(c["accepted"], 1)
        print(f"  q{q}: accepted={c['accepted']} same_lba_as_previous={c['dup_prev']} "
              f"({100.0 * c['dup_prev'] / acc:.2f} %) same_lba_as_one_of_last_8={c['dup_last8']} "
              f"({100.0 * c['dup_last8'] / acc:.2f} %)")
    for ep, c in enumerate(cnt["ep"]):
        print(f"  ep{ep}: frames={c['frames']} beats={c['beats']} mismatching_beats={c['mm_beats']} "
              f"mismatching_frames={c['mm_frames']} length_errors={c['len_err']} "
              f"identity_errors={c['id_err']} lost_frames={c['lost_frames']} "
              f"lost_mismatching_beats={c['lost_mm_beats']} flags={st['ep'][ep]}")
    if res["first_mismatch_before"]:
        print(f"  a first mismatch was latched before this point ({res['first_mismatch_before']}); "
              f"this point's own cannot be latched without CLEAR")
    if res["first_mismatch"]:
        fm = res["first_mismatch"]
        print(f"  first mismatch: ep{fm['ep']} qid={fm['qid']} cid={fm['cid']} lba={fm['lba']:#x} "
              f"beat={fm['beat']} word={fm['word']} exp={fm['exp']:#018x} got={fm['got']:#018x}")
    print(f"  {res['bytes_checked']} bytes checked, all frames checked: {res['all_checked']}, "
          f"drained: {res['drained']}, rd_cid = rd_ok + rd_fail: {res['completed']} ==> "
          f"{'PASS' if res['ok'] else 'FAIL: ' + '; '.join(res['reasons'])}")


def parse_args():
    p = argparse.ArgumentParser(description="Fill drives with a pattern from the FPGA and check a "
                                            "read point at line rate (USR_DATA_CHECK firmware)")
    p.add_argument("-d", "--device", default=nfb.libnfb.Nfb.default_dev_path)
    p.add_argument("--queues", type=int, default=4, help="queues/drives 0..N-1 (default 4)")
    # 64 GiB per drive: a 10 s point at ~17 GB/s reads ~42 GB per drive, far beyond its DRAM.
    p.add_argument("--span", type=int, default=1 << 27,
                   help="checked region per drive, LBAs from 0, a power of two up to 2^32 "
                        "(default 2^27 = 64 GiB)")
    p.add_argument("--no-fill", action="store_true", help="the region already holds the pattern")
    p.add_argument("--addressing", choices=("rand", "seq"), default="rand")
    p.add_argument("--size", type=int, default=255, help="0-based LBA count per read (default 255)")
    p.add_argument("--seconds", type=float, default=10.0)
    p.add_argument("--hold-period", type=int, default=0, help="RD MFB hold period, DMA_CLK cycles")
    p.add_argument("--hold-len", type=int, default=0, help="RD MFB hold length, DMA_CLK cycles")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    acquire_device_lock(args.device)
    # One handle for everything: a second nfb.open() reads every counter back as zero.
    dev = nfb.open(args.device)
    test = IuventusTest(dev=dev, index=0)
    dc = DataCheck(test, endpoints=2, queues=args.queues)
    if not dc.present():
        sys.exit("ERROR: no data checker at 0x88 -- build the firmware with USR_DATA_CHECK=1")

    if args.span & (args.span - 1) or not 2 * FILL_LBAS <= args.span <= 1 << 32:
        sys.exit("ERROR: --span must be a power of two between 512 and 2^32 LBAs")
    if not args.no_fill:
        nbytes = fill_bytes(args.queues, args.span)
        print(f"fill: {nbytes / 2**30:.1f} GiB over {args.queues} drives, about "
              f"{nbytes / (FILL_GBPS * 1e9):.0f} s at {FILL_GBPS:.0f} GB/s", flush=True)
        fill = run_fill(test, dc, args.queues, args.span)
        print(f"fill: {fill['frames']}/{fill['target']} frames in {fill['elapsed_s']:.1f} s, queue "
              f"ends {[hex(e) for e in fill['queue_end_lba']]}, wr_fail={fill['wr_fail']} "
              f"oor={fill['oor']} ==> {'OK' if fill['ok'] else 'FAILED'}")
        if not fill["ok"]:
            sys.exit(1)

    res = run_read_point(test, dc, args.addressing, args.size, args.queues, args.span, args.seconds,
                         hold_period=args.hold_period, hold_len=args.hold_len)
    print_point(res)
    sys.exit(0 if res["ok"] else 1)
