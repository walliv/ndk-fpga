#!/usr/bin/env python3
# health_gate.py: run-validity gate for DMA Iuventus measurement campaigns
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Checks the error channels a throughput number can't be trusted without: unsucc_cpls and
sqes_dispatched==succ_cpls stay clean even while a queue is silently wedged, so DESIGN_ERR and
the per-queue completion balance are what actually catch it.
"""
import os
import sys
import time

# Prefer the checkout this script lives in over any system-wide ofm: a stale installed package is
# how a campaign silently ran against the wrong register map.
_OFM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "python", "ofm")
if os.path.isdir(_OFM):
    sys.path.insert(0, os.path.normpath(_OFM))
from ofm.comp.dma.iuventus.iuventus_reg_access import DMAIuventusRegAccess

DESIGN_ERR_ADDR = 0x13C
WRBUFF_DROP_ADDR = 0x0EC
TOTAL_CYCLES_ADDR = 0x158
# Bit 16 of DESIGN_ERR is the stop-timeout flag; bits below it are the sticky per-queue wedge
# flags. Both clear only on a design RST -- no CONTROL bit resets them, bit 5 having been retired.
DESIGN_ERR_STOP_TIMEOUT = 16
# A queue delivering less than this share of the busiest queue's completions is treated as wedged
# or starved rather than merely unlucky.
QUEUE_BALANCE_MIN = 0.25


def snapshot(ra, num_queues):
    ra.sample_cntrs()
    snap = {
        "succ": ra.succ_cpls,
        "unsucc": ra.unsucc_cpls,
        "err_mask": ra.err_mask,
        "design_err": ra._comp.read32(DESIGN_ERR_ADDR),
        "drops": ra._comp.read64(WRBUFF_DROP_ADDR),
        "cycles": ra._comp.read64(TOTAL_CYCLES_ADDR),
    }
    for q in range(num_queues):
        try:
            snap["q%d" % q] = ra.pq_succ_cpls(q)
        except Exception:
            snap["q%d" % q] = None
    return snap


def decode_design_err(val, num_queues):
    if val == 0:
        return []
    reasons = []
    if val & (1 << DESIGN_ERR_STOP_TIMEOUT):
        reasons.append("STOP_TIMEOUT (a stop that did not complete)")
    wedged = [q for q in range(min(num_queues, DESIGN_ERR_STOP_TIMEOUT)) if val & (1 << q)]
    if wedged:
        reasons.append("queue wedge flags: %s" % ", ".join(str(q) for q in wedged))
    return reasons


def check(before, after, num_queues):
    """Problems that make the enclosed measurement invalid, as a list of strings."""
    problems, warnings = [], []
    for reason in decode_design_err(before["design_err"], num_queues):
        warnings.append("pre-existing DESIGN_ERR 0x%08x: %s (needs an FPGA reload to clear)"
                        % (before["design_err"], reason))
    if before["drops"]:
        warnings.append("pre-existing wrbuff drop count %d (clear with CONTROL bit 3)"
                        % before["drops"])
    if after["cycles"] <= before["cycles"]:
        problems.append("TOTAL_CYCLES did not advance: the handle is not reading live counters")
    if after["unsucc"] != before["unsucc"]:
        problems.append("unsucc_cpls climbed by %d" % (after["unsucc"] - before["unsucc"]))
    if after["err_mask"]:
        problems.append("err_mask = 0x%016x" % after["err_mask"])
    # Sticky and clearable only by a design RST, so a bit already set before the window says
    # nothing about this run. Only a bit that APPEARS inside it invalidates the measurement.
    for reason in decode_design_err(after["design_err"] & ~before["design_err"], num_queues):
        problems.append("DESIGN_ERR rose to 0x%08x in-window: %s" % (after["design_err"], reason))
    if after["drops"] != before["drops"]:
        problems.append("wrbuff dropped %d read frames in-window: data was silently lost"
                        % (after["drops"] - before["drops"]))
    deltas = {}
    for q in range(num_queues):
        if before.get("q%d" % q) is None:
            continue
        deltas[q] = after["q%d" % q] - before["q%d" % q]
    if deltas:
        busiest = max(deltas.values())
        if busiest > 0:
            for q, d in sorted(deltas.items()):
                if d < QUEUE_BALANCE_MIN * busiest:
                    problems.append("queue %d completed %d vs busiest %d: wedged or starved"
                                    % (q, d, busiest))
    return problems, warnings, deltas


def main(argv):
    num_queues = int(argv[1]) if len(argv) > 1 else 1
    window = float(argv[2]) if len(argv) > 2 else 5.0
    ra = DMAIuventusRegAccess(dev="0")
    before = snapshot(ra, num_queues)
    time.sleep(window)
    after = snapshot(ra, num_queues)
    problems, warnings, deltas = check(before, after, num_queues)
    print("completions +%d over %.1f s, per-queue %s"
          % (after["succ"] - before["succ"], window,
             ", ".join("q%d=+%d" % (q, d) for q, d in sorted(deltas.items())) or "n/a"))
    print("design_err=0x%08x drops=%d (delta %d) err_mask=0x%x unsucc=%d"
          % (after["design_err"], after["drops"], after["drops"] - before["drops"],
             after["err_mask"], after["unsucc"]))
    for w in warnings:
        print("  ! %s" % w)
    if problems:
        print("HEALTH FAIL")
        for p in problems:
            print("  - %s" % p)
        return 1
    print("HEALTH OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
