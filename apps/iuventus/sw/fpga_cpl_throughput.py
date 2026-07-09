#!/usr/bin/env python3
# fpga_cpl_throughput.py: completion-based DMA Iuventus P2P throughput measurement
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
#
# Completion-based FPGA-P2P throughput: succ_cpls delta x (LBAs x 512) / time.
# Reflects real NVMe completions (actual SSD reads/writes), unlike the MFB speed meter.
# Requires fzc running on the target SSD (design enabled).
# Usage: fpga_cpl_throughput.py [dev] [secs] [out.json]
import os, sys, time, json, nfb
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iuventus_rw_test import IuventusTest
from ofm.comp.dma.iuventus.iuventus_reg_access import DMAIuventusRegAccess

DEV = sys.argv[1] if len(sys.argv) > 1 else "2"
T   = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

c    = nfb.open(DEV).comp_open("ziti,dma_iuventus", 0)
test = IuventusTest(dev=DEV, index=0)
ra   = DMAIuventusRegAccess(dev=DEV)

t0 = time.time()
while (c.read16(0x00) & 1) == 0:
    if time.time() - t0 > 25:
        print("no enable (is fzc running?)"); sys.exit(2)
print("ENABLED CONTROL=0x%04x; measuring completion-based throughput (T=%.1fs)" % (c.read16(0x00), T), flush=True)

def sample():
    ra.sample_cntrs()
    return ra.succ_cpls, ra.unsucc_cpls

sizes = [0, 1, 3, 7, 15, 31, 63, 127, 255]   # lba_num -> 1..256 LBAs
results = []
for mode in ["rd", "wr"]:
    for addr in ["seq", "rand"]:
        for size in sizes:
            test.contig_test = False
            test.tst_mode = mode
            test.tst_addressing = addr
            if mode == "rd":
                test.rd_req_lba_num = size
            s0, u0 = sample()
            if mode == "wr":
                test.contig_test = True
                test.gen.bursting = False
                test.disp_wr_req(0, size, 64)
            else:
                test.rd_req_lba_num = size
                test.contig_test = True
            time.sleep(T)
            s1, u1 = sample()
            # stop the generator
            if mode == "wr":
                test.gen.enabled = False
                test.gen.bursting = True
                test.contig_test = False
                t1 = time.time()
                while test.gen.generating and time.time() - t1 < 3:
                    time.sleep(0.05)
            else:
                test.contig_test = False
                time.sleep(0.2)
            cpls = s1 - s0
            gbps = cpls * (size + 1) * 512 / (T * 1e9)
            results.append({"mode": mode, "addressing": addr, "lba_num": size,
                            "completions": cpls, "unsucc": u1 - u0, "throughput_gbps": gbps})
            print("%s_%s_%d: %8d cpls  %6.3f GB/s  (unsucc %d)" %
                  (mode, addr, size, cpls, gbps, u1 - u0), flush=True)

out = sys.argv[3] if len(sys.argv) > 3 else "fpga_completion_throughput.json"
json.dump(results, open(out, "w"), indent=2)
print("saved", out, flush=True)
