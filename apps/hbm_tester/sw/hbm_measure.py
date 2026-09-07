#!/usr/bin/env python3
# hbm_measure.py: measure what an HBM pseudo-channel delivers on silicon
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Answers four questions the simulation model cannot.

1. What does ONE port sustain, read-only and write-only? The models assume 14.4 GB/s minus a
   refresh share; these are the numbers that confirm or refute it. Writes are asked separately
   because a DRAM channel need not be symmetric.
2. Do TWO ports scale? Their pseudo-channels are independent, so they should.
3. What does mixed read+write cost on ONE port? The stack has a single electrical interface, so
   every direction change pays a bus turnaround. A model that gives reads and writes separate
   budgets cannot show this, and it is the likeliest explanation for a data path that reaches
   less than the sum of its parts.
4. How does burst length change it? Shorter bursts amortise the per-burst overhead over fewer
   beats.

Rates come from counters the tester keeps in the HBM clock domain. The host sleep only decides how
long traffic runs.
"""

import argparse
import json
import statistics
import sys

import nfb
from ofm.comp.base.misc.hbm_throughput_tester import HbmThroughputTester, PORT_GBPS


def fmt(results):
    return "  ".join("p%d %5.2f GB/s (%4.1f%%)" % (r.port, r.total_gbps, 100 * r.utilisation)
                     for r in results)


def median_run(t, reps, **kw):
    """Median over repetitions, per port. One pass can catch a refresh burst; several cannot."""
    runs = [t.run(**kw) for _ in range(reps)]
    out = []
    for i in range(len(runs[0])):
        ref = runs[0][i]
        ref.r_beats = int(statistics.median(r[i].r_beats for r in runs))
        ref.w_beats = int(statistics.median(r[i].w_beats for r in runs))
        ref.cycles = int(statistics.median(r[i].cycles for r in runs))
        out.append(ref)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-d", "--device", default="0", help="nfb device index")
    ap.add_argument("-s", "--seconds", type=float, default=0.5, help="traffic time per point")
    ap.add_argument("-r", "--reps", type=int, default=5, help="repetitions per point")
    ap.add_argument("-o", "--output", help="write results to this JSON file")
    args = ap.parse_args()

    dev = nfb.open(args.device)
    t = HbmThroughputTester(dev=dev)
    results = {}

    print("HBM port wire rate: %.1f GB/s (256 b @ 450 MHz)\n" % PORT_GBPS)

    print("1. single port, read only")
    for p in range(t.ports):
        res = median_run(t, args.reps, seconds=args.seconds, read=True, write=False,
                         port_mask=1 << p)
        results["read_p%d" % p] = [r.__dict__ for r in res]
        print("   port %d: %s" % (p, fmt(res)))

    print("\n1b. single port, write only")
    for p in range(t.ports):
        res = median_run(t, args.reps, seconds=args.seconds, read=False, write=True,
                         port_mask=1 << p)
        results["write_p%d" % p] = [r.__dict__ for r in res]
        print("   port %d: %s" % (p, fmt(res)))

    print("\n2. both ports, read only")
    res = median_run(t, args.reps, seconds=args.seconds, read=True, write=False)
    results["read_both"] = [r.__dict__ for r in res]
    total = sum(r.total_gbps for r in res)
    print("   %s   aggregate %.2f GB/s" % (fmt(res), total))

    print("\n2b. both ports, write only")
    res = median_run(t, args.reps, seconds=args.seconds, read=False, write=True)
    results["write_both"] = [r.__dict__ for r in res]
    print("   %s   aggregate %.2f GB/s" % (fmt(res), sum(r.total_gbps for r in res)))

    print("\n3. single port, read+write together  <- the bus-turnaround cost")
    for p in range(t.ports):
        res = median_run(t, args.reps, seconds=args.seconds, read=True, write=True,
                         port_mask=1 << p)
        results["rw_p%d" % p] = [r.__dict__ for r in res]
        r = res[0]
        print("   port %d: read %5.2f + write %5.2f = %5.2f GB/s (%4.1f%% of wire)"
              % (p, r.read_gbps, r.write_gbps, r.total_gbps, 100 * r.utilisation))

    print("\n3b. BOTH ports, read+write together  <- the data path's actual operating condition")
    res = median_run(t, args.reps, seconds=args.seconds, read=True, write=True)
    results["rw_both"] = [r.__dict__ for r in res]
    agg = sum(r.total_gbps for r in res)
    for r in res:
        print("   port %d: read %5.2f + write %5.2f = %5.2f GB/s (%4.1f%% of wire)"
              % (r.port, r.read_gbps, r.write_gbps, r.total_gbps, 100 * r.utilisation))
    print("   aggregate %.2f GB/s of traffic -> supports %.2f GB/s of data flow"
          % (agg, agg / 2))

    print("\n4. burst-length sweep, single port read only")
    results["burst"] = {}
    for alen in (15, 7, 3, 1):
        res = median_run(t, args.reps, seconds=args.seconds, read=True, write=False, port_mask=1,
                         burst_len=alen)
        results["burst"][alen] = [r.__dict__ for r in res]
        print("   %2d beats/burst: %s" % (alen + 1, fmt(res)))

    t.stop()
    err = t.resp_err
    print("\nsticky AXI error mask: 0x%x %s" % (err, "" if err == 0 else "  <- non-OKAY response!"))
    if args.output:
        json.dump(results, open(args.output, "w"), indent=2)
        print("wrote %s" % args.output)
    return 1 if err else 0


if __name__ == "__main__":
    sys.exit(main())
