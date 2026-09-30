#!/usr/bin/env python3
# hbm_arb_probe.py: measure how an HBM pseudo-channel splits its bus between reads and writes
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Which read/write arbitration does the HBM controller apply to one port?

A byte-fair controller splits a saturated mix evenly whatever the burst lengths. A burst-fair one
gives each direction bus time in proportion to its burst length (16-beat reads against 4-beat
writes: 80/20). A read-greedy one serves every pending read first, so writes get only what a
rate-limited read offer leaves. The asymmetric and rate-limited points below tell these apart.
The mean run length of back-to-back R/W beats shows the grant granularity.

Both streams walk the same addresses unless separated: a stream that catches up with the other then
waits behind it on same-address ordering and locks to its rate, which reads as arbitration but is
not. --w-base puts the writes above --mask, on rows the reads never touch (needs W_BASE, 0x20).

Rates come from the tester's HBM-clock counters; the host sleep only sets how long traffic runs.
"""

import argparse
import json
import statistics
import sys

import nfb
from ofm.comp.base.misc.hbm_throughput_tester import HbmThroughputTester, PORT_GBPS


def gap_for(beats, gbps):
    """Address-issue gap that offers `gbps` with `beats`-beat bursts (period = gap + 1 cycles)."""
    return max(0, round(beats * PORT_GBPS / gbps) - 1)


# (label, read beats or 0, write beats or 0, read offer GB/s or None, write offer GB/s or None)
POINTS = [
    ("R16 only", 16, 0, None, None),
    ("R4 only", 4, 0, None, None),
    ("R2 only", 2, 0, None, None),
    ("R1 only", 1, 0, None, None),
    ("W16 only", 0, 16, None, None),
    ("W4 only", 0, 4, None, None),
    ("W2 only", 0, 2, None, None),
    ("W1 only", 0, 1, None, None),
    ("R16+W16 sat", 16, 16, None, None),
    ("R4+W4 sat", 4, 4, None, None),
    ("R2+W2 sat", 2, 2, None, None),
    ("R1+W1 sat", 1, 1, None, None),
    ("R16+W4 sat", 16, 4, None, None),
    ("R4+W16 sat", 4, 16, None, None),
    ("R16+W1 sat", 16, 1, None, None),
    ("R16@8+W4 sat", 16, 4, 8.0, None),
    ("R16@4+W4 sat", 16, 4, 4.0, None),
    ("R16 sat+W4@3.6", 16, 4, None, 3.6),
    ("R16 sat+W4@5.85", 16, 4, None, 5.85),
    ("R16@8+W4@5.85", 16, 4, 8.0, 5.85),
    ("R16@4+W4@3.6", 16, 4, 4.0, 3.6),
    ("R16@8+W1 sat", 16, 1, 8.0, None),
    # The four-PC WRBUFF regime: the substripe cuts both directions into 4-beat bursts per PC.
    ("R4 sat+W4@3.6", 4, 4, None, 3.6),
    ("R4 sat+W4@5.85", 4, 4, None, 5.85),
    ("R4@4+W4 sat", 4, 4, 4.0, None),
    ("R4@8+W4 sat", 4, 4, 8.0, None),
    ("R4@4+W4@3.6", 4, 4, 4.0, 3.6),
]


def run_point(t, reps, seconds, port, rb, wb, r_off, w_off):
    kw = dict(seconds=seconds, read=rb > 0, write=wb > 0, port_mask=1 << port,
              burst_len=max(rb, 1) - 1, w_burst_len=max(wb, 1) - 1,
              ar_gap=gap_for(rb, r_off) if (rb and r_off) else 0,
              aw_gap=gap_for(wb, w_off) if (wb and w_off) else 0)
    runs = [t.run(**kw)[0] for _ in range(reps)]
    med = lambda f: statistics.median(f(r) for r in runs)
    return dict(read_gbps=med(lambda r: r.read_gbps), write_gbps=med(lambda r: r.write_gbps),
                total_gbps=med(lambda r: r.total_gbps), r_run=med(lambda r: r.r_run_beats),
                w_run=med(lambda r: r.w_run_beats), ar_gap=kw["ar_gap"], aw_gap=kw["aw_gap"],
                spread_total=max(r.total_gbps for r in runs) - min(r.total_gbps for r in runs),
                raw=[r.__dict__ for r in runs])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-d", "--device", default="0", help="nfb device (index or path)")
    ap.add_argument("-p", "--port", type=int, default=0, help="tester port")
    ap.add_argument("-s", "--seconds", type=float, default=0.5, help="traffic time per point")
    ap.add_argument("-r", "--reps", type=int, default=5, help="repetitions per point")
    ap.add_argument("-o", "--output", help="write results to this JSON file")
    ap.add_argument("--mask", type=lambda x: int(x, 0), default=0x0FFFFFFF,
                    help="address span both streams walk (default 256 MiB)")
    ap.add_argument("--w-base", type=lambda x: int(x, 0), default=0x10000000,
                    help="ORed onto write addresses; 0 = shared addresses (default 256 MiB)")
    args = ap.parse_args()

    dev = nfb.open(args.device)
    t = HbmThroughputTester(dev=dev)
    t.addr_mask = args.mask
    t.w_base = args.w_base
    assert t.w_base == args.w_base, "this tester image has no W_BASE register"
    res = {}
    print("%-18s %7s %7s %7s  %6s %6s  %5s %5s" % ("point", "R GB/s", "W GB/s", "sum", "R run",
                                                    "W run", "argap", "awgap"))
    for label, rb, wb, r_off, w_off in POINTS:
        r = run_point(t, args.reps, args.seconds, args.port, rb, wb, r_off, w_off)
        res[label] = r
        print("%-18s %7.2f %7.2f %7.2f  %6.1f %6.1f  %5d %5d" % (
            label, r["read_gbps"], r["write_gbps"], r["total_gbps"], r["r_run"], r["w_run"],
            r["ar_gap"], r["aw_gap"]))
    t.stop()
    err = t.resp_err
    print("\nsticky AXI error mask: 0x%x" % err)
    if args.output:
        json.dump(res, open(args.output, "w"), indent=2)
        print("wrote %s" % args.output)
    return 1 if err else 0


if __name__ == "__main__":
    sys.exit(main())
