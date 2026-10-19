# cocotb_test.py: PCIE_CQ_AXI2MFB on the straddled 1024-bit Versal CPM5 CQ interface
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Straddled CPM5 CQ TLPs in, MFB (4,1,8,32) frames with the adapter's CQ meta out. The model maps
each TLP the AXI monitor saw to its frame; scoreboards compare generated/driven and expected/received.
"""

import dataclasses
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.types import LogicArray
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.axi4s_pcie.cpm5 import (
    CQ1024,
    BEAT_DW,
    CPM5_RULES,
    Cpm5StraddleDriver,
    Cpm5StraddleMonitor,
    assert_coverage,
    random_cq_tlp,
    random_ready,
    scoreboard_check,
    wall_clock_watchdog,
)
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import MFBProperty
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

CLK_PERIOD_NS = 4
WALL_CLOCK_LIMIT_S = 540

# PCIE_CQ_META layout (pcie_meta_pack.vhd)
META_FBE_O = 128 + 32 + 3
META_LBE_O = META_FBE_O + 4
META_BE_O = META_LBE_O + 4 + 1 + 2 + 8


def expected_frame(tlp):
    """The MFB frame PCIE_CQ_AXI2MFB + the adapter's meta packing make of one CQ TLP. The SOF
    region holds TLP bytes 0-31, so the meta BE is byte_en of those bytes; CPM5 has no TPH."""
    meta = (tlp.first_be << META_FBE_O) | (tlp.last_be << META_LBE_O) | ((tlp.byte_en & 0xFFFFFFFF) << META_BE_O)
    return MfbTransactionWithMeta(data=tlp.data, meta=meta)


async def run_cq(dut, n_tlps, gen_tlp, p_idle):
    # cocotb seeds `random` per test from COCOTB_RANDOM_SEED, so this stays reproducible
    rng = random.Random(random.getrandbits(64))
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}, {n_tlps} TLPs")
    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(wall_clock_watchdog(dut.CLK, WALL_CLOCK_LIMIT_S, dut._log))

    dut.CQ_MFB_DST_RDY.value = 0
    dut.CQ_AXI_LAST.value = 0
    await ClockCycles(dut.CLK, 4)

    drv = Cpm5StraddleDriver(dut, "CQ_AXI", dut.CLK, CQ1024, rng=random.Random(rng.getrandbits(32)))
    axi_mon = Cpm5StraddleMonitor(dut, "CQ_AXI", dut.CLK, CQ1024)
    mfb_mon = MFBMonitor(dut, "CQ_MFB", dut.CLK, trans_type=MfbTransactionWithMeta)
    mfb_prop = MFBProperty(dut, "CQ_MFB", dut.CLK)
    cocotb.start_soon(random_ready(dut.CLK, dut.CQ_MFB_DST_RDY, random.Random(rng.getrandbits(32))))

    sb = Scoreboard(dut)
    driven = []
    expected = []
    sb.add_interface(axi_mon, driven)
    sb.add_interface(mfb_mon, expected)
    # The model works from what the input monitor saw, the driven-vs-generated scoreboard vouches for the agents.
    axi_mon.add_callback(lambda tlp: expected.append(expected_frame(tlp)))

    for _ in range(n_tlps):
        tlp = gen_tlp(rng)
        idle = rng.randint(1, 6) if rng.random() < p_idle else 0
        driven.append(tlp)
        drv.append(tlp, idle_before=idle)

    budget = n_tlps * 200 + 10000
    for _ in range(budget):
        await RisingEdge(dut.CLK)
        if not driven and not expected and mfb_mon.frame_cnt == n_tlps:
            break
    await ClockCycles(dut.CLK, 8)

    axi_mon.final_check()
    mfb_prop.final_check()
    dut._log.info(f"driven {axi_mon.tlps} TLPs in {axi_mon.beats} beats, received {mfb_mon.frame_cnt} MFB frames")
    assert axi_mon.tlps == n_tlps and mfb_mon.frame_cnt == n_tlps, \
        f"{n_tlps} TLPs generated, {axi_mon.tlps} driven, {mfb_mon.frame_cnt} received"
    scoreboard_check(sb)
    return axi_mon.coverage


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def cq_random(dut):
    """Mixed MemRd/MemWr of 1-1024 Dwords, random gaps and random DST_RDY."""
    n = int(os.environ.get("CPM5_TLPS", "4000"))
    cov = await run_cq(dut, n, random_cq_tlp, p_idle=0.05)
    dut._log.info(f"coverage: {dict(sorted(cov.items()))}")
    minima = {"sops_4": 5, "sops_3": 5, "sops_2": 20, "eop_sop_same_slot": 50, "eop_then_sop_next_slot": 50,
              "slot_gap": 10, "tlp_3plus_beats": 50, "tlp_1dw_payload": 20, "stall_mid_tlp": 50, "idle_cycles": 10}
    minima.update({f"sop_slot_{s}": 20 for s in range(4)})
    minima.update({f"eop_dw_{d}": 1 for d in range(BEAT_DW)})
    assert_coverage(cov, minima, dut._log)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def cq_short_tlps(dut):
    """Descriptor-only and 1-4 Dword TLPs, so most beats carry three or four TLPs."""
    def gen(rng):
        return random_cq_tlp(rng, p_read=1.0) if rng.random() < 0.5 else _short_write(rng)

    def _short_write(rng):
        while True:
            tlp = random_cq_tlp(rng, p_read=0.0)
            if tlp.dwords <= 8:
                return tlp

    n = int(os.environ.get("CPM5_TLPS", "4000"))
    cov = await run_cq(dut, n, gen, p_idle=0.02)
    dut._log.info(f"coverage: {dict(sorted(cov.items()))}")
    assert_coverage(cov, {"sops_4": 100, "eops_4": 100, "eop_sop_same_slot": 1000, "tlp_1dw_payload": 50}, dut._log)


def _user(lay, sops=(), eops=(), sop_bits=None, eop_bits=None, extra=0):
    u = extra
    u |= (sop_bits if sop_bits is not None else (1 << len(sops)) - 1) << lay.sop
    u |= (eop_bits if eop_bits is not None else (1 << len(eops)) - 1) << lay.eop
    for i, s in enumerate(sops):
        u |= s << (lay.sop_ptr + 2 * i)
    for i, e in enumerate(eops):
        u |= e << (lay.eop_ptr + 5 * i)
    return u


def _x(width, value, *ranges):
    """``value`` as a ``width``-bit LogicArray with X in every bit range [lo, hi)."""
    bits = list(format(value, f"0{width}b"))
    for lo, hi in ranges:
        for b in range(lo, hi):
            bits[width - 1 - b] = "X"
    return LogicArray("".join(bits))


def _dw(lo, hi=None):
    """Bit range of TDATA Dwords lo..hi."""
    return (32 * lo, 32 * ((lo if hi is None else hi) + 1))


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def cpm5_monitor_selftest(dut):
    """Directed beats: the CPM5 rule checker must name every rule it is shown breaking and stay silent on X outside TLPs."""
    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD_NS, unit="ns").start())
    lay = dataclasses.replace(CQ1024, zero_fields=((197, 44),))
    dw_w = len(dut.CQ_AXI_DATA)
    uw = len(dut.CQ_AXI_USER)
    dut.CQ_AXI_VALID.value = 0
    dut.CQ_AXI_LAST.value = 0
    dut.CQ_AXI_DATA.value = 0
    dut.CQ_AXI_USER.value = 0
    dut.CQ_MFB_DST_RDY.value = 1
    await ClockCycles(dut.CLK, 2)

    # Each case: (rule, [(valid, dst_rdy, data, user), ...], check open TLP at end)
    cases = [
        ("sop_thermometer", [(1, 1, 0, _user(lay, sops=(0, 2), eops=(3, 19), sop_bits=0b0101))], False),
        ("eop_thermometer", [(1, 1, 0, _user(lay, sops=(0,), eops=(3,), eop_bits=0b0010))], False),
        ("sop_ptr_reserved", [(1, 1, 0, _user(lay, sops=(0, 0), eops=(3, 4)))], False),
        ("sop_order", [(1, 1, 0, _user(lay, sops=(2, 1), eops=(11, 19)))], False),
        ("eop_order", [(1, 1, 0, _user(lay, sops=(0, 1), eops=(12, 3)))], False),
        ("first_sop_not_slot0", [(1, 1, 0, _user(lay, sops=(1,), eops=(11,)))], False),
        ("sop_while_open", [(1, 1, 0, _user(lay, sops=(0,))), (1, 1, 0, _user(lay, sops=(1,), eops=(9, 13)))], False),
        ("eop_without_sop", [(1, 1, 0, _user(lay, eops=(5,)))], False),
        ("tlp_too_short", [(1, 1, 0, _user(lay, sops=(0,), eops=(1,)))], False),
        ("valid_dropped", [(1, 1, 0, _user(lay, sops=(0,))), (0, 1, 0, 0)], False),
        ("hold_changed", [(1, 0, 1, _user(lay, sops=(0,), eops=(3,))), (1, 1, 2, _user(lay, sops=(0,), eops=(3,)))], False),
        ("discontinue", [(1, 1, 0, _user(lay, sops=(0,), eops=(5,), extra=1 << lay.discon))], False),
        ("zero_field", [(1, 1, 0, _user(lay, sops=(0,), eops=(5,), extra=1 << 200))], False),
        ("tlp_open_at_end", [(1, 1, 0, _user(lay, sops=(0,)))], True),
        ("x_in_tlp", [(1, 1, _x(dw_w, 0, _dw(3)), _user(lay, sops=(0,), eops=(5,)))], False),
        ("x_in_tlp", [(1, 1, 0, _user(lay, sops=(0,))), (1, 1, _x(dw_w, 0, _dw(1)), _user(lay, eops=(2,)))], False),
        ("x_in_tlp", [(1, 1, _x(dw_w, 0, _dw(17)), _user(lay, sops=(0, 2), eops=(5, 19)))], False),
        ("x_in_tuser", [(1, 1, 0, _x(uw, _user(lay, sops=(0,), eops=(5,)), (lay.eop_ptr, lay.eop_ptr + 1)))], False),
        ("x_in_tuser", [(1, 1, 0, _x(uw, _user(lay, sops=(0,), eops=(5,)), (lay.sop + 3, lay.sop + 4)))], False),
        ("x_in_tuser", [(1, 1, 0, _x(uw, _user(lay, sops=(0,), eops=(5,)), (lay.byte_en + 20, lay.byte_en + 21)))], False),
        ("x_in_tuser", [(1, 1, 0, _x(uw, _user(lay, sops=(0,), eops=(5,)), (200, 201)))], False),
    ]
    assert {c[0] for c in cases} == set(CPM5_RULES), "every rule needs a directed case"
    # X outside every TLP: past the last EOP, in a slot gap, in idle/stalled beats, in unused TUSER fields; (TLPs, beats)
    legal = [
        (1, [(1, 1, _x(dw_w, 0, _dw(6, 31)),
              _x(uw, _user(lay, sops=(0,), eops=(5,)), (lay.sop_ptr + 2, lay.sop_ptr + 8), (lay.eop_ptr + 5, lay.eop_ptr + 20),
                 (lay.fbe + 4, lay.fbe + 16), (lay.byte_en + 24, lay.byte_en + 128)))]),
        (2, [(1, 1, _x(dw_w, 0, _dw(4, 15), _dw(20, 31)), _user(lay, sops=(0, 2), eops=(3, 19)))]),
        (1, [(0, 1, _x(dw_w, 0, (0, dw_w)), _x(uw, 0, (0, uw))), (1, 1, 0, _user(lay, sops=(0,), eops=(5,)))]),
        (1, [(1, 0, _x(dw_w, 0, _dw(6, 31)), _user(lay, sops=(0,), eops=(5,))),
             (1, 1, _x(dw_w, 0, _dw(6, 31)), _user(lay, sops=(0,), eops=(5,)))]),
    ]
    cases += [(n, beats, False) for n, beats in legal]

    for rule, beats, final in cases:
        mon = Cpm5StraddleMonitor(dut, "CQ_AXI", dut.CLK, lay, max_errors=0, quiet=True)
        for valid, rdy, data, user in beats:
            await RisingEdge(dut.CLK)
            dut.CQ_AXI_VALID.value = valid
            dut.CQ_MFB_DST_RDY.value = rdy
            dut.CQ_AXI_DATA.value = data
            dut.CQ_AXI_USER.value = user
        await RisingEdge(dut.CLK)
        dut.CQ_AXI_VALID.value = 0
        dut.CQ_MFB_DST_RDY.value = 1
        await ClockCycles(dut.CLK, 2)
        if final:
            try:
                mon.final_check()
            except Exception:
                pass
        mon.kill()
        if isinstance(rule, int):
            assert not mon.errors, f"X outside TLPs reported: {mon.errors}"
            assert mon.tlps == rule, f"{mon.tlps} TLPs rebuilt from a legal case with X lanes, expected {rule}"
            dut._log.info(f"X outside TLPs: no violation, {mon.tlps} TLP(s)")
            continue
        hit = [e for e in mon.errors if f": {rule}:" in e]
        assert hit, f"rule {rule} not reported, got {mon.errors}"
        dut._log.info(f"{rule}: reported ({len(mon.errors)} violation(s) in the case)")
