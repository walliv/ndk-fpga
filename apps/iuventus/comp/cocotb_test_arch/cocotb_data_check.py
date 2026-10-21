# cocotb_data_check.py: USER_CORE (TEST) elaborated with DATA_CHECK, both endpoints and four queues:
# pattern fill, line-rate read checking, and fault injection against a multi-queue DMA model
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Stimulus is the DUT's own generator, set up by iuventus_data_check.py as on the card. The model
stands in for the DMA and drives; its record of delivered frames predicts every checker counter."""

import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ReadOnly

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sw"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cocotb_common"))
import iuventus_rw_test  # noqa: E402
import iuventus_data_check  # noqa: E402
from iuventus_rw_test import IuventusTest  # noqa: E402
from iuventus_data_check import DataCheck, run_fill, run_read_point, pattern_word, SPAN_MARGIN  # noqa: E402
from user_core_model import RandDrawModel, _LFSR64_SEED, LFSR_LEAP, lfsr64_leap  # noqa: E402

import nfb_compat  # noqa: E402,F401 (patches cocotb before cocotbext.nfb is imported)
import cocotbext.nfb  # noqa: E402
from cocotbext.ofm.mi.drivers import MIRequestDriver  # noqa: E402
from cocotbext.ofm.mfb.properties import attach_mfb_properties  # noqa: E402

from dma_iuventus_mq_model import MultiQueueDmaModel, pattern_sector, SECT, BEAT, OP_READ, OP_WRITE  # noqa: E402
from endpoint_view import EndpointView  # noqa: E402

e = cocotb.external

# The Makefile's test-data-check target passes each as both a -g generic and an env var; the
# fallbacks are USER_CORE's own defaults, which this bench refuses to run with.
NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))
PCIE_ENDPOINTS = int(os.environ.get("PCIE_ENDPOINTS", "1"))
assert os.environ.get("DATA_CHECK", "0") == "1", "elaborate with DATA_CHECK=true (make test-data-check)"
assert NUM_QUEUES >= 2 and PCIE_ENDPOINTS == 2, "the bench checks several queues over both endpoints"

# Checked LBAs per queue: the fill test writes FILL_SPAN plus SPAN_MARGIN (the least a 128 KiB point
# allows); others read the unstored pattern over a span where draws rarely coincide.
FILL_SPAN = 512
SPAN = 1 << 30
# Draws are 64 LFSR steps apart, so any repeat is an error here. Independence needs this many
# consecutive draws, and their high bits' correlation must stay under the bound (~4 sigma).
INDEP_MIN_DRAWS = 200
INDEP_MAX_CORR = 0.28
BEATS_PER_SECT = SECT // BEAT

# This DevTree has no DMA Iuventus node, so the card-side "fzc is running" guard cannot pass; it
# checks the card's setup, not the core.
iuventus_rw_test.assert_fzc_running = lambda _test: None
iuventus_data_check.assert_fzc_running = lambda _test: None


class DcNfbDevice(cocotbext.nfb.NfbDevice):
    """USER_CORE as a standalone nfb device, with MultiQueueDmaModel on its DMA-side ports."""

    model_kw = {}

    async def _init_clks(self):
        await cocotb.start(Clock(self._dut.USR_CLK, 5, 'ns').start())
        await cocotb.start(Clock(self._dut.DMA_CLK, 4, 'ns').start())
        await cocotb.start(Clock(self._dut.MI_CLK, 10, 'ns').start())
        # Seeded from cocotb's own seed, so a failing seed reproduces.
        self.rng = random.Random(random.getrandbits(32))
        self.model = MultiQueueDmaModel(self._dut, self._dut.DMA_CLK, NUM_QUEUES, PCIE_ENDPOINTS,
                                        self.rng, **self.model_kw)
        self._dut.PCIE_LINK_UP.value = 1
        self._dut.FPGA_ID.value = 0
        self._dut.FPGA_ID_VLD.value = 0
        self.mi = [MIRequestDriver(self._dut, "MI", self._dut.MI_CLK)]
        # Conformance on the DUT's own output only: the read streams are the model's MFBDriver, and
        # each checked bus costs Python work every cycle.
        self.mfb_props = attach_mfb_properties(self._dut, self._dut.DMA_CLK, reset=self._dut.DMA_RST,
                                               include=("NVME_WR_MFB",))

    async def _reset(self):
        self._dut.USR_RST.value = 1
        self._dut.DMA_RST.value = 1
        self._dut.MI_RST.value = 1
        await Timer(100, unit="ns")
        self._dut.USR_RST.value = 0
        self._dut.DMA_RST.value = 0
        self._dut.MI_RST.value = 0
        await Timer(100, unit="ns")


async def setup(dut, **model_kw):
    """A fresh device per test: cocotb ends every task a test started, clocks and model included."""
    dev = DcNfbDevice(dut)
    dev.model_kw = model_kw
    await dev.init()
    test = await e(lambda: IuventusTest(dev=dev.nfb, index=0))()
    dc = DataCheck(test, endpoints=PCIE_ENDPOINTS, queues=NUM_QUEUES)
    assert await e(dc.present)(), "no data checker at 0x88 -- elaborated without DATA_CHECK?"
    return dev, test, dc


def seed_fill(dma):
    """What run_fill leaves on the drives, as the model's implicit pattern region."""
    dma.pattern_lbas = SPAN + SPAN_MARGIN
    dma.stale_span = SPAN


def frame_mismatches(fr):
    """Beat indices whose data differs from the pattern, and the first differing word."""
    exp = b"".join(pattern_sector(fr.qid, fr.lba + i) for i in range(fr.num + 1))
    bad, first = [], None
    for b in range(len(fr.data) // BEAT):
        got_b, exp_b = fr.data[b*BEAT:(b + 1)*BEAT], exp[b*BEAT:(b + 1)*BEAT]
        if got_b != exp_b:
            bad.append(b)
            if first is None:
                w = next(i for i in range(8) if got_b[8*i:8*i + 8] != exp_b[8*i:8*i + 8])
                first = {"ep": fr.ep, "qid": fr.qid, "cid": fr.cid & 0xFF, "lba": fr.lba, "beat": b,
                         "word": w, "exp": int.from_bytes(exp_b[8*w:8*w + 8], "little"),
                         "got": int.from_bytes(got_b[8*w:8*w + 8], "little")}
    return bad, first


class Window:
    """The model's records from one point on, which is what the DUT's counters cover after CLEAR."""

    def __init__(self, dma):
        self.dma = dma
        self.acc0, self.cqe0, self.frm0, self.lost0 = (len(dma.accepted), len(dma.cqes),
                                                       len(dma.frames), dma.lost_posted)

    def expected(self):
        dma = self.dma
        cqes = dma.cqes[self.cqe0:]
        frames = dma.frames[self.frm0:]
        exp = {"rd_ok": sum(1 for op, code, _, _ in cqes if op == OP_READ and code == 0),
               "wr_ok": sum(1 for op, code, _, _ in cqes if op == OP_WRITE and code == 0),
               "rd_fail": sum(1 for op, code, _, _ in cqes if op == OP_READ and code == 1),
               "wr_fail": 0, "oor": 0, "lost_rpt": dma.lost_posted - self.lost0, "orphan_lost": 0,
               "rd_cid": sum(1 for c in dma.accepted[self.acc0:] if c.cid >= 0)}
        eps = [dict(frames=0, beats=0, mm_beats=0, mm_frames=0, len_err=0, id_err=0, lost_frames=0,
                    lost_mm_beats=0) for _ in range(PCIE_ENDPOINTS)]
        first = None
        for fr in sorted(frames, key=lambda f: f.sent_cycle):
            bad, fm = frame_mismatches(fr)
            c = eps[fr.ep]
            c["frames"] += 1
            c["beats"] += (fr.num + 1) * BEATS_PER_SECT
            if fr.lost and bad:
                c["lost_frames"] += 1
                c["lost_mm_beats"] += len(bad)
            elif fr.lost:
                # Correct data in a lossy frame: nothing to attribute, its report resolves as an orphan.
                exp["orphan_lost"] += 1
            elif bad:
                c["mm_frames"] += 1
                c["mm_beats"] += len(bad)
                if first is None:
                    first = fm
        exp["ep"] = eps
        # Start-LBA repeats at the DMA accept, against each queue's own last 8. Only a reset empties
        # them, so the history runs from the device's start; the window counts only its own reads.
        queues = [dict(accepted=0, dup_prev=0, dup_last8=0) for _ in range(NUM_QUEUES)]
        hist = [[] for _ in range(NUM_QUEUES)]
        for i, c in enumerate(dma.accepted[dma.hist_reset_idx:], start=dma.hist_reset_idx):
            lba, h, q = c.lba & ((1 << 48) - 1), hist[c.qid], queues[c.qid]
            if i >= self.acc0:
                q["accepted"] += 1
                q["dup_prev"] += bool(h) and h[0] == lba
                q["dup_last8"] += lba in h
            h.insert(0, lba)
            del h[8:]
        exp["queue"] = queues
        return exp, first, frames


def scoreboard(res, win, expect_first=None):
    """DUT counters and first-mismatch fields against the model's prediction."""
    exp, first, frames = win.expected()
    got = res["counters"]
    errors = []
    for k, v in exp.items():
        if k in ("ep", "queue"):
            for i, block in enumerate(v):
                for name, val in block.items():
                    if got[k][i][name] != val:
                        errors.append(f"{k}{i}.{name}: DUT {got[k][i][name]}, model {val}")
        elif got[k] != v:
            errors.append(f"{k}: DUT {got[k]}, model {v}")
    if expect_first is not None:
        first = expect_first
    if first != res["first_mismatch"]:
        errors.append(f"first mismatch: DUT {res['first_mismatch']}, model {first}")
    st = res["status"]
    if st["cid_beyond_table"] or st["cid_without_accept"] or any(
            ep[n] for ep in st["ep"] for n in iuventus_data_check.STICKY_FLAGS):
        errors.append(f"sticky checker flags raised: {st}")
    assert not errors, "data-check scoreboard:\n  " + "\n  ".join(errors)
    cocotb.log.info(f"scoreboard: {len(frames)} frames, counters {got}")
    return exp


def settle_until(dc, reads, max_polls=20000):
    """settle_fn for run_read_point: run until `reads` reads completed since the point's start, as
    counters are never cleared between points. MI reads advance simulated time, so polling waits."""
    def settle(_seconds):
        base = dc.counter(0)
        for _ in range(max_polls):
            if dc.counter(0) - base >= reads:
                return 0.0
        raise AssertionError(f"read point never reached {reads} completions")
    return settle


def _lvl(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def steps_since_reset(lfsr_state, limit=1 << 18):
    """How many steps from the reset seed the LFSR is in, or None beyond `limit`. The stream only
    moves by whole draws, so only multiples of LFSR_LEAP are tried."""
    reg = _LFSR64_SEED
    for k in range(0, limit, LFSR_LEAP):
        if reg == lfsr_state:
            return k
        reg = lfsr64_leap(reg)
    return None


async def draw_checker(dut, state):
    """Scores each engine-side accept's address and the LFSR state every cycle against
    RandDrawModel, from the DUT's state at start. Records each queue's reads as (LBA, LFSR steps
    since reset of its draw, or None if not drawn)."""
    model = None
    step = None
    while state["running"]:
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        if model is None:
            model = RandDrawModel(regions=1, state=_lvl(dut.lfsr_r))
            step = steps_since_reset(model.state)
        if _lvl(dut.lfsr_r) != model.state:
            state["errors"].append(f"LFSR state {_lvl(dut.lfsr_r):#x}, model {model.state:#x}")
            return
        active = _lvl(dut.seq_en) == 1
        rd = _lvl(dut.rd_req_accepted_s) == 1
        wr = (_lvl(dut.gen_nvme_wr_accept) & 1) == 1
        rd_lba, _ = model.cycle(read=rd, writes=(wr,), active=active)
        drawn = active and rd and _lvl(dut.tst_sel_reg) & 1
        if rd:
            got = _lvl(dut.core_rd_req_lba_ptr)
            state["per_q"].setdefault(_lvl(dut.nvme_rd_req_qid_s), []).append(
                (got, step if drawn and step is not None else None))
            if drawn:
                state["draws"] += 1
                state["drawn"].append((_lvl(dut.nvme_rd_req_qid_s), got))
                exp = rd_lba & _lvl(dut.dc_addr_mask)
                if got != exp:
                    state["errors"].append(f"read took {got:#x}, model draw {exp:#x}")
        if step is not None:
            step += LFSR_LEAP * model.adv


def assert_fresh_lbas(chk, counters, prior):
    """No queue's read starts where its previous one, or one of its last 8, started; `prior` holds
    each queue's earlier reads (newest first), which the DUT's history still remembers. Also checks
    the DUT's repeat counters against these reads."""
    for q in range(NUM_QUEUES):
        hist = [(lba, None) for lba in prior[q][:8]]
        for lba, step in chk["per_q"].get(q, []):
            hits = [h for h in hist if h[0] == lba]
            assert not hits, (f"queue {q} repeated LBA {lba:#x} (draw steps {[h[1] for h in hits]} "
                              f"and {step})")
            hist = [(lba, step)] + hist[:7]
        got = counters["queue"][q]
        assert (got["dup_prev"], got["dup_last8"]) == (0, 0), f"queue {q}: DUT counted repeats {got}"


def assert_independent_draws(chk, span):
    """Draws are 64 LFSR steps apart, so the 1-step shift law (each draw twice the previous plus a
    bit) must not hold between consecutive draws, nor a queue's consecutive reads for shifts up to
    8, and their high bits must not correlate."""
    units = span >> 3
    drawn = chk["drawn"]
    u = [lba >> 3 for _, lba in drawn]
    assert len(u) >= INDEP_MIN_DRAWS, f"only {len(u)} draws: too few to judge independence"
    shift1 = sum((b - 2*a) % units < 2 for a, b in zip(u, u[1:]))
    per_q = {}
    for q, lba in drawn:
        per_q.setdefault(q, []).append(lba >> 3)
    shift_q = sum((b - (a << d)) % units < (1 << d)
                  for seq in per_q.values() for a, b in zip(seq, seq[1:]) for d in range(1, 9))
    top_w = 8
    t = [x >> (units.bit_length() - 1 - top_w) for x in u]
    mean = sum(t) / len(t)
    var = sum((x - mean)**2 for x in t) / len(t)
    corr = sum((a - mean) * (b - mean) for a, b in zip(t, t[1:])) / (len(t) - 1) / var
    # The shift law's own signature: bit j of a draw repeating bit j-1 of the one before.
    lagged = min(sum(((b >> j) & 1) == ((a >> (j - 1)) & 1) for a, b in zip(u, u[1:])) / (len(u) - 1)
                 for j in range(units.bit_length() - top_w, units.bit_length() - 1))
    lagged_max = max(sum(((b >> j) & 1) == ((a >> (j - 1)) & 1) for a, b in zip(u, u[1:])) / (len(u) - 1)
                     for j in range(units.bit_length() - top_w, units.bit_length() - 1))
    stats = {"draws": len(u), "shift1_hits": shift1, "per_queue_shift_hits": shift_q,
             "top8_lag1_corr": round(corr, 3), "lagged_bit_agree": (round(lagged, 3), round(lagged_max, 3))}
    cocotb.log.info(f"draw independence: {stats}")
    assert shift1 == 0 and shift_q == 0, f"draws follow the LFSR shift law: {stats}"
    assert abs(corr) < INDEP_MAX_CORR, f"high bits of consecutive draws correlate: {stats}"
    assert 0.3 < lagged and lagged_max < 0.7, f"a draw repeats the previous one's bits shifted: {stats}"
    return stats


# Independence statistics of every point that had enough draws, for the report.
indep_stats = []


async def checked_point(dut, dev, test, dc, addressing, size, reads, hold=(0, 0), expect_ok=True,
                        span=SPAN):
    win = Window(dev.model)
    chk = {"running": True, "errors": [], "per_q": {}, "draws": 0, "drawn": []}
    mon = cocotb.start_soon(draw_checker(dut, chk))
    res = await e(run_read_point)(test, dc, addressing, size, NUM_QUEUES, span, 0.0,
                                  hold_period=hold[0], hold_len=hold[1], sleep_fn=lambda _s: None,
                                  settle_fn=settle_until(dc, reads), timeout_polls=4000)
    chk["running"] = False
    await mon
    await RisingEdge(dut.DMA_CLK)
    await e(iuventus_data_check.print_point)(res)
    assert res["drained"], "the point never drained: frames still owed to completed reads"
    if expect_ok:
        assert res["ok"] and res["all_checked"], f"checked point failed: {res}"
    # Every queue must have carried traffic, on both endpoints, from more than one block.
    acc = dev.model.accepted[win.acc0:]
    qids = {c.qid for c in acc}
    assert qids == set(range(NUM_QUEUES)), f"point reached queues {sorted(qids)} only"
    lbas = {c.lba for c in acc}
    cocotb.log.info(f"{addressing} point: {len(acc)} reads from {len(lbas)} distinct start LBAs, "
                    f"{chk['draws']} random draws scored")
    assert all(c.lba + c.num < span + SPAN_MARGIN for c in acc), "a read left the filled region"

    # Each queue's reads reach the DMA in the order the engine accepted them, and every random one
    # took the draw the model predicts -- a fresh LFSR state per accept.
    assert not chk["errors"], f"{len(chk['errors'])} random-draw errors, first {chk['errors'][:3]}"
    for q in range(NUM_QUEUES):
        pins = [c.lba for c in acc if c.qid == q]
        assert [lba for lba, _ in chk["per_q"].get(q, [])] == pins, (
            f"queue {q}: engine and DMA read sequences differ")
    if addressing == "rand":
        assert chk["draws"] >= reads, f"only {chk['draws']} random draws scored"
        dups = [(q["dup_prev"], q["dup_last8"]) for q in res["counters"]["queue"]]
        if span >= 1 << 20:
            # Distinct draws coincide after the fold and mask with probability ~2^-27 per pair here.
            since = dev.model.accepted[dev.model.hist_reset_idx:win.acc0]
            prior = [[c.lba for c in reversed(since) if c.qid == q][:8] for q in range(NUM_QUEUES)]
            assert_fresh_lbas(chk, res["counters"], prior)
            cocotb.log.info(f"random repeats {dups}: none")
            if chk["draws"] >= INDEP_MIN_DRAWS:
                indep_stats.append(assert_independent_draws(chk, span))
        else:
            # A 64-unit span: distinct draws coincide by chance (~1/64 per pair); the scoreboard
            # matched these counts to the model, and the draw check shows no draw was reused.
            cocotb.log.info(f"chance repeats of distinct draws in a {span}-LBA span: {dups}")
    return res, win


@cocotb.test(timeout_time=400, timeout_unit="ms")
async def test_fill_then_checked_reads(dut):
    """The FPGA fill writes the pattern over every queue's region, and random and sequential 4 KiB
    and 128 KiB points over all four queues and both endpoints then check clean."""
    dev, test, dc = await setup(dut)
    fill = await e(run_fill)(test, dc, NUM_QUEUES, FILL_SPAN, sleep_fn=lambda _s: None, timeout_polls=200000)
    cocotb.log.info(f"fill: {fill}")
    assert fill["ok"], f"fill failed: {fill}"
    # The fill's own scoreboard: every written frame carried the pattern of the block it went to.
    bad = [(q, s) for q in range(NUM_QUEUES) for s in range(FILL_SPAN + SPAN_MARGIN)
           if dev.model.storage.get((q, s)) != pattern_sector(q, s)]
    assert not bad, f"{len(bad)} filled sectors do not hold the pattern, first {bad[:4]}"
    assert len(dev.model.wr_frames) == fill["frames"]
    dev.model.stale_span = FILL_SPAN

    for addressing, size, reads in (("rand", 7, 160), ("seq", 7, 160), ("rand", 255, 10), ("seq", 255, 10)):
        res, win = await checked_point(dut, dev, test, dc, addressing, size, reads, span=FILL_SPAN)
        scoreboard(res, win)


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def test_rd_hold_knob_checked(dut):
    """The periodic RD MFB hold engaged during a checked run: frames pile up and drain at full rate
    on both endpoints, and every one still checks clean."""
    dev, test, dc = await setup(dut, pages_per_ep=128)
    seed_fill(dev.model)
    held = {"cycles": 0}
    rd0 = EndpointView(dut, 0)

    async def watch():
        while True:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            held["cycles"] += int(rd0.NVME_RD_MFB_DST_RDY.value) == 0
    mon = cocotb.start_soon(watch())
    for addressing, size, reads, hold in (("rand", 7, 240, (400, 300)), ("rand", 0, 300, (1000, 700)),
                                          ("seq", 255, 12, (3000, 2000))):
        res, win = await checked_point(dut, dev, test, dc, addressing, size, reads, hold=hold)
        scoreboard(res, win)
    mon.cancel()
    assert held["cycles"] > 1000, f"the RD hold refused only {held['cycles']} cycles"


async def _fault_point(dut, fault, size=7, reads=120, hold=(0, 0), extra=None):
    dev, test, dc = await setup(dut)
    seed_fill(dev.model)
    k = dev.rng.randrange(20, reads - 20)
    faults = {k: fault}
    faults.update(extra or {})
    dev.model.plan.faults = faults
    res, win = await checked_point(dut, dev, test, dc, "rand", size, reads, hold=hold, expect_ok=False)
    exp = scoreboard(res, win)
    hit = [f for f in dev.model.frames[win.frm0:] if f.inject == fault]
    return res, exp, hit


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def test_pool_bound_random_reads_take_fresh_lbas(dut):
    """A page pool holding two 128 KiB reads per endpoint makes every completion free room for a
    burst of admissions; each must take its own draw, so no queue repeats its previous LBA or any of
    its last 8."""
    dev, test, dc = await setup(dut, pages_per_ep=64, rd_lat=(20, 120))
    seed_fill(dev.model)
    for size, reads in ((255, 24), (127, 32), (7, 240)):
        bound0 = dev.model.page_bound_cycles
        res, win = await checked_point(dut, dev, test, dc, "rand", size, reads)
        scoreboard(res, win)
        bound = dev.model.page_bound_cycles - bound0
        cocotb.log.info(f"{(size + 1) // 2} KiB: {bound} cycles a queued read waited for pages")
        if size >= 127:
            assert bound > 1000, f"the {(size + 1) // 2} KiB point was not bound by the page pool"


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_corrupt_beat_detected(dut):
    """One bit flipped in one beat of one frame: exactly that beat counts, and the first-mismatch
    fields name its queue, tag, LBA, beat, word, and the expected and delivered word."""
    res, exp, hit = await _fault_point(dut, "corrupt")
    assert len(hit) == 1
    c = res["counters"]["ep"][hit[0].ep]
    assert c["mm_beats"] == 1 and c["mm_frames"] == 1, c
    fm = res["first_mismatch"]
    assert fm is not None and fm["lba"] == hit[0].lba and fm["qid"] == hit[0].qid
    assert bin(fm["exp"] ^ fm["got"]).count("1") == 1, "a single flipped bit must show as one"


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_stale_page_detected(dut):
    """One frame carries another read's data (a stale WRBUFF page): every beat of it mismatches."""
    res, exp, hit = await _fault_point(dut, "stale")
    assert len(hit) == 1
    c = res["counters"]["ep"][hit[0].ep]
    assert c["mm_frames"] == 1 and c["mm_beats"] == (hit[0].num + 1) * BEATS_PER_SECT, c
    fm = res["first_mismatch"]
    assert fm["beat"] == 0 and fm["word"] == 0 and fm["exp"] == pattern_word(hit[0].qid, hit[0].lba, 0)


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_queue_swap_detected(dut):
    """One frame carries the same block of another drive: only the queue field differs, and that
    alone flags every beat."""
    res, exp, hit = await _fault_point(dut, "swap")
    assert len(hit) == 1
    c = res["counters"]["ep"][hit[0].ep]
    assert c["mm_frames"] == 1 and c["mm_beats"] == (hit[0].num + 1) * BEATS_PER_SECT, c
    fm = res["first_mismatch"]
    assert (fm["exp"] ^ fm["got"]) >> 60 != 0 and (fm["exp"] ^ fm["got"]) & ((1 << 60) - 1) == 0


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def test_data_lost_is_reported_not_counted(dut):
    """DATA_LOST frames count as lost, never as mismatches, and never reach the first-mismatch latch.
A short RD hold parks frames in the pipe so reports land both before and after them; failed reads
move no data."""
    dev, test, dc = await setup(dut)
    seed_fill(dev.model)
    # A frame closes about 12 cycles after its EOF leaves the DMA; reports trailing by 2..60 cycles,
    # against a short frequent hold that parks whole 512 B frames in the pipe, land on both sides.
    dev.model.lost_delay = (2, 60)
    reads = 400
    ks = dev.rng.sample(range(20, reads - 20), 10)
    dev.model.plan.faults = {k: ("fail" if i < 2 else "lost") for i, k in enumerate(ks)}

    # Which side waited: a pending report (it arrived first) or a pending mismatching frame.
    seen = {"report_first": 0, "frame_first": 0}

    async def watch():
        eps = [dut.data_check_g.dc_ep_g[ep] for ep in range(PCIE_ENDPOINTS)]
        while True:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            for h in eps:
                seen["report_first"] += int(h.lc_vld.value) != 0
                seen["frame_first"] += int(h.mc_vld.value) != 0
    mon = cocotb.start_soon(watch())
    res, win = await checked_point(dut, dev, test, dc, "rand", 0, reads, hold=(48, 30), expect_ok=False)
    mon.cancel()
    cocotb.log.info(f"cycles a report waited for its frame / a frame for its report: {seen}")
    scoreboard(res, win)
    c = res["counters"]
    assert c["lost_rpt"] == 8 and c["rd_fail"] == 2, c
    assert sum(ep["lost_frames"] for ep in c["ep"]) == 8
    assert seen["report_first"] and seen["frame_first"], f"only one arrival order was exercised: {seen}"
    assert sum(ep["mm_beats"] + ep["mm_frames"] for ep in c["ep"]) == 0
    assert res["first_mismatch"] is None
    assert sum(ep["frames"] for ep in c["ep"]) == c["rd_ok"]


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_repeat_counters_without_check(dut):
    """The per-queue start-LBA repeat counters measure the generator as built, so they count with
    CHECK_EN off too, while every per-endpoint data counter stays at zero."""
    dev, test, dc = await setup(dut)
    seed_fill(dev.model)
    win = Window(dev.model)
    chk = {"running": True, "errors": [], "per_q": {}, "draws": 0, "drawn": []}
    mon = cocotb.start_soon(draw_checker(dut, chk))
    await e(lambda: setattr(dc, "span_mask", SPAN - 1))()
    await e(dc.control)(False, False)
    await e(test.set_queue_range)(NUM_QUEUES)
    await e(iuventus_rw_test._throughput_point_start)(test, "rd", "rand", 7)
    await e(settle_until(dc, 150))(0.0)
    await e(iuventus_rw_test._throughput_point_stop)(test, "rd", sleep_fn=lambda _s: None)
    # The MI read comes first: it is what advances simulated time between polls.
    drained = await e(lambda: iuventus_data_check._wait(
        lambda: dc.counter(0) == len(dev.model.accepted) - win.acc0 and dev.model.idle(),
        lambda _s: None, 4000, 0))()
    assert drained, (f"never drained: {len(dev.model.accepted) - win.acc0} accepted, "
                     f"rd_ok={await e(dc.counter)(0)}")
    chk["running"] = False
    await mon
    await RisingEdge(dut.DMA_CLK)
    assert not chk["errors"], f"random-draw errors, first {chk['errors'][:3]}"
    cnt = await e(dc.counters)()
    exp, _, _ = win.expected()
    assert cnt["queue"] == exp["queue"], f"repeat counters: DUT {cnt['queue']}, model {exp['queue']}"
    assert all(v == 0 for ep in cnt["ep"] for v in ep.values()), f"data counters moved: {cnt['ep']}"
    assert_fresh_lbas(chk, cnt, [[] for _ in range(NUM_QUEUES)])
    cocotb.log.info(f"repeat counters with CHECK_EN off: {cnt['queue']}, no repeats")
    assert_independent_draws(chk, SPAN)
    assert sum(q["accepted"] for q in cnt["queue"]) >= 150


def _all_zero(v):
    if isinstance(v, dict):
        return all(_all_zero(x) for x in v.values())
    if isinstance(v, list):
        return all(_all_zero(x) for x in v)
    return v == 0


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def test_clear_restarts_the_checker(dut):
    """Back-to-back points without CLEAR report differences and keep an earlier first mismatch
    latched; CLEAR on an idle core zeroes every counter, flag and the latch, and the next point
    checks clean. The host script never issues CLEAR."""
    dev, test, dc = await setup(dut)
    seed_fill(dev.model)
    dev.model.plan.faults = {dev.rng.randrange(20, 100): "corrupt"}
    res1, win1 = await checked_point(dut, dev, test, dc, "rand", 7, 120, expect_ok=False)
    scoreboard(res1, win1)
    fm1 = res1["first_mismatch"]
    assert fm1 is not None and sum(ep["mm_beats"] for ep in res1["counters"]["ep"]) == 1

    res2, win2 = await checked_point(dut, dev, test, dc, "rand", 7, 120)
    scoreboard(res2, win2)
    assert res2["first_mismatch"] is None and res2["first_mismatch_before"] == fm1, res2
    assert sum(ep["mm_beats"] for ep in res2["counters"]["ep"]) == 0

    await e(dc.control)(False, True, True)
    dev.model.hist_reset_idx = len(dev.model.accepted)
    cnt = await e(dc.counters)()
    st = await e(dc.status)()
    assert _all_zero(cnt), f"CLEAR left counters: {cnt}"
    assert not st["mismatch_latched"] and await e(dc.first_mismatch)() is None
    assert not iuventus_data_check._sticky(st) and iuventus_data_check._idle(st), st

    res3, win3 = await checked_point(dut, dev, test, dc, "rand", 255, 16)
    scoreboard(res3, win3)
    assert res3["first_mismatch_before"] is None and res3["ok"]
    cocotb.log.info(f"draw independence over the run: {indep_stats}")
