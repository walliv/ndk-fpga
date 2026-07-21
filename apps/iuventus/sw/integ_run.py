#!/usr/bin/env python3
# integ_run.py: driver for the FPGA-resident IUVENTUS_INTEGRITY_CHECKER self-test
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
#
# Drive the FPGA-resident IUVENTUS_INTEGRITY_CHECKER (Iuventus TEST user core): write an
# address-derived pattern to a range of SSD LBAs and read it back, comparing in fabric. The pattern
# embeds the LBA in every 64-bit word, so a mismatch flags both bit corruption and a wrong-block
# return. Requires the SSD/DMA plumbing already initialised and the design ENABLEd (e.g. by fzc
# holding the SSD). Reads err_cnt / first mismatch back over MI.
import sys
import time
import nfb

DEV = "0"
# iuventus_test_ctrl register map (byte offsets)
R_INTEG_CTRL   = 0x30   # w: bit0=start(pulse) bit1=en(level) ; r: bit1=en
R_INTEG_BASE_L = 0x34   # byte address of first sector (= sector*512), low 32
R_INTEG_BASE_H = 0x38   # high 32
R_INTEG_COUNT  = 0x3C   # number of sectors to test
R_STATUS       = 0x40   # bit0=busy bit1=done
R_ERR_CNT      = 0x44
R_ERR_LBA_L    = 0x48
R_ERR_LBA_H    = 0x4C
R_ERR_EXP      = 0x50
R_ERR_GOT      = 0x54


def run(base_sector, count, tag, timeout=20.0):
    d = nfb.open(DEV)
    dma = d.comp_open("ziti,dma_iuventus", 0)
    c = d.comp_open("ziti,iuventus_test_ctrl", 0)
    # wait for the design to be ENABLEd (fzc holding the SSD)
    t0 = time.time()
    while (dma.read16(0x00) & 1) == 0:
        if time.time() - t0 > 15:
            print(f"[{tag}] TIMEOUT waiting for design ENABLE")
            return None
        time.sleep(0.1)
    # FSM re-arm: integ_start is a 1-cycle pulse. After a completed sweep the checker sits in
    # S_DONE and needs one start pulse to return to S_IDLE before a new sweep can be launched.
    if c.read32(R_STATUS) & 0x2:                     # done set -> in S_DONE
        c.write32(R_INTEG_CTRL, 0x1)                 # pulse start (en=0): S_DONE -> S_IDLE
        c.write32(R_INTEG_CTRL, 0x0)
    # program the sweep (base is a BYTE address = sector*512)
    base_byte = base_sector * 512
    c.write32(R_INTEG_CTRL, 0)                       # ensure en=0, no stale start
    c.write32(R_INTEG_BASE_L, base_byte & 0xFFFFFFFF)
    c.write32(R_INTEG_BASE_H, (base_byte >> 32) & 0xFFFFFFFF)
    c.write32(R_INTEG_COUNT, count)
    # start + enable (bit0 pulse, bit1 level)
    c.write32(R_INTEG_CTRL, 0x3)
    # poll for done
    t0 = time.time()
    st = 0
    while True:
        st = c.read32(R_STATUS)
        if st & 0x2:      # done
            break
        if time.time() - t0 > timeout:
            print(f"[{tag}] TIMEOUT: base_sector={base_sector} count={count} status=0x{st:08x} "
                  f"(busy={st & 1})")
            c.write32(R_INTEG_CTRL, 0)   # disable so datapath returns to normal
            return False
        time.sleep(0.02)
    err = c.read32(R_ERR_CNT)
    elba = c.read32(R_ERR_LBA_L) | (c.read32(R_ERR_LBA_H) << 32)
    exp = c.read32(R_ERR_EXP)
    got = c.read32(R_ERR_GOT)
    # leave the FSM in a clean state (en cleared; re-arm handled at next call's entry)
    c.write32(R_INTEG_CTRL, 0)
    dt = time.time() - t0
    ok = (err == 0)
    if ok:
        msg = "PASS"
    else:
        msg = (f"FAIL err_cnt={err} first_lba(byte)=0x{elba:x} sector={elba // 512} "
               f"exp=0x{exp:08x} got=0x{got:08x}")
    print(f"[{tag}] base_sector={base_sector} count={count}: {msg}  ({dt * 1000:.0f} ms)")
    return ok


if __name__ == "__main__":
    tag = sys.argv[1] if len(sys.argv) > 1 else "test"
    # sweeps: (base_sector, count) -- start tiny, then widen
    sweeps = [(4096, 1), (4096, 8), (100000, 32), (500000, 64)]
    results = []
    for bs, cnt in sweeps:
        results.append(run(bs, cnt, tag))
        time.sleep(0.3)
    allok = all(r is True for r in results)
    print(f"[{tag}] ==> {'ALL SWEEPS PASS (data intact)' if allok else 'FAILURE/TIMEOUT detected'}")
    sys.exit(0 if allok else 1)
