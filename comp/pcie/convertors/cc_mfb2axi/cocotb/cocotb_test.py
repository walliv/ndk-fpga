# cocotb_test.py: PCIE_CC_MFB2AXI on the straddled 1024-bit Versal CPM5 CC interface
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Random completions in as PCIe-flavoured MFB (4,1,8,32), legal CPM5 straddled CC out. A CC TLP
crosses unchanged, which the scoreboard checks; Cpm5StraddleMonitor checks the straddle rules.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cocotbext.ofm.axi4s_pcie.cpm5 import (
    MfbContractCounter,
    CC1024,
    BEAT_DW,
    assert_coverage,
    random_cc_tlp,
    run_mfb_to_cpm5,
    wall_clock_watchdog,
)

CLK_PERIOD_NS = 4
WALL_CLOCK_LIMIT_S = 540


async def setup(dut):
    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(wall_clock_watchdog(dut.CLK, WALL_CLOCK_LIMIT_S, dut._log))
    dut.CC_AXI_READY.value = 0
    dut.RESET.value = 1
    await ClockCycles(dut.CLK, 4)
    dut.RESET.value = 0
    await ClockCycles(dut.CLK, 2)
    # cocotb seeds `random` per test from COCOTB_RANDOM_SEED, so this stays reproducible
    rng = random.Random(random.getrandbits(64))
    n = int(os.environ.get("CPM5_TLPS", "4000"))
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}, {n} TLPs")
    return rng, n


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def cc_random(dut):
    """Completions with 0-1024 Dwords of payload, random bursts and random TREADY."""
    rng, n = await setup(dut)
    tlps = [random_cc_tlp(rng) for _ in range(n)]
    mon = await run_mfb_to_cpm5(dut, dut.CLK, "CC_MFB", "CC_AXI", CC1024, tlps, rng)
    cov = mon.coverage
    dut._log.info(f"coverage: {dict(sorted(cov.items()))}")
    minima = {"sops_4": 5, "sops_3": 5, "sops_2": 20, "eops_4": 5, "eop_sop_same_slot": 50,
              "eop_then_sop_next_slot": 50, "tlp_3plus_beats": 50, "tlp_1dw_payload": 20, "stall_mid_tlp": 50,
              "idle_cycles": 10}
    minima.update({f"sop_slot_{s}": 20 for s in range(4)})
    minima.update({f"eop_dw_{d}": 1 for d in range(BEAT_DW)})
    assert_coverage(cov, minima, dut._log)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def cc_short_tlps(dut):
    """Completions of at most 8 Dwords, so most beats carry three or four TLPs."""
    rng, n = await setup(dut)
    tlps = []
    while len(tlps) < n:
        tlp = random_cc_tlp(rng)
        if tlp.dwords <= 8:
            tlps.append(tlp)
    mon = await run_mfb_to_cpm5(dut, dut.CLK, "CC_MFB", "CC_AXI", CC1024, tlps, rng)
    assert_coverage(mon.coverage, {"sops_4": 100, "eops_4": 100, "eop_sop_same_slot": 1000,
                                   "tlp_1dw_payload": 50}, dut._log)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def cc_region_gaps(dut):
    """One-region TLPs on words with free regions between them, a shape the MFB driver never makes."""
    rng, n = await setup(dut)
    tlps = []
    while len(tlps) < n:
        tlp = random_cc_tlp(rng)
        if tlp.dwords <= 8:
            tlps.append(tlp)
    mon = await run_mfb_to_cpm5(dut, dut.CLK, "CC_MFB", "CC_AXI", CC1024, tlps, rng, stimulus="region_gaps")
    assert_coverage(mon.coverage, {"slot_gap": 500, "eop_then_sop_next_slot": 500, "sops_4": 50,
                                   "idle_cycles": 50}, dut._log)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def cc_gappy(dut):
    """Any legal MFB (gaps inside frames, SOFs in any region) through PCIE_CPM5_TX_COND (TX_COND=true):
    the CPM5 side must still obey every straddle rule. Without the conditioner this test must fail."""
    rng, n = await setup(dut)
    # The CPM5 MPS is 1024 B, which is what PCIE_CPM5_TX_COND buffers for
    tlps = [random_cc_tlp(rng, max_dw=256) for _ in range(n)]
    contract = MfbContractCounter(dut, "CC_MFB", dut.CLK)
    mon = await run_mfb_to_cpm5(dut, dut.CLK, "CC_MFB", "CC_AXI", CC1024, tlps, rng, stimulus="gappy")
    dut._log.info(f"input contract breaks: {dict(contract.counts)}")
    assert_coverage(contract.counts, {"gap_mid_frame": 100, "fresh_sof_not_region0": 100, "multi_sof_words": 100}, dut._log)
    assert_coverage(mon.coverage, {"tlp_3plus_beats": 50, "stall_mid_tlp": 50, "tlp_1dw_payload": 10}, dut._log)
