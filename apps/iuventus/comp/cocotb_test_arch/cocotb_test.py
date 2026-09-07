# cocotb_test.py: Stage-1 smoke test for a component-level USER_CORE (TEST architecture) cocotb
# testbench, served as a real nfb device via cocotbext.nfb.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import functools
import inspect
import math
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ReadOnly, ClockCycles

# iuventus_rw_test.py already implements the exact MI register map real hardware testing uses,
# so it is imported as a library here -- its `if __name__ == "__main__"` CLI never runs -- rather
# than re-deriving the same register pokes a second time.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sw"))
# SimplifiedDmaModel and the scoreboard are shared with the GROUPBY architecture's bench, so they
# live one level up rather than being forked per architecture.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cocotb_common"))
from iuventus_rw_test import (  # noqa: E402
    IuventusTest, run_read_dispatch, run_write_dispatch, _throughput_point_start, _throughput_point_stop,
)

import nfb_compat  # noqa: F401 (patches cocotb before cocotbext.nfb is imported)

import cocotbext.nfb  # noqa: E402 (must follow the compat shim above)
from cocotbext.ofm.mi.drivers import MIRequestDriver  # noqa: E402
from cocotbext.ofm.mfb.properties import attach_mfb_properties  # noqa: E402

from dma_iuventus_model import QID_W, SimplifiedDmaModel  # noqa: E402
from user_core_model import ReadReqModel, WriteFrameModel, ExpectedReadReq, ExpectedWrFrame  # noqa: E402
from scoreboard import Scoreboard  # noqa: E402

# OP_STAT_CODE encoding on the DMA interface: 00 SUCCESS, 01 FAILURE, 10 LBA out of range.
OP_STAT_CODE_SUCCESS = 0

# Shortcut, matching apps/minimal/tests/cocotb/cocotb_test.py's own convention.
e = cocotb.external

# EVCR interval used by every cross-check below. Small vs. the ~2^28-cycle production default so
# an interval completes inside a short directed burst, and named so the TOTAL_CYCLES readback can
# be compared against the value actually programmed.
EVCR_INTERVAL_CYCLES = 200

# NUM_QUEUES must match the -g NUM_QUEUES=... the design was elaborated with; the Makefile passes
# it both ways. Read once at import time so the reference model predicts the QID round-robin
# pattern of whichever build is running.
NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))


class IuventusUserCoreNfbDevice(cocotbext.nfb.NfbDevice):
    """Minimal cocotbext.nfb.NfbDevice for a standalone USER_CORE (TEST architecture) DUT.

    USER_CORE has no PCIe/DMA/eth of its own (all of that lives in DMA_IUVENTUS / the NDK core),
    so this is far simpler than cocotbext.ndk_core.NFBDevice: three clocks, one MI slave, and no
    QueueManager plumbing beyond what the base class's init() already builds for free -- our
    DevTree (see gen_devtree.tcl) has no "netcope,dma_ctrl_ndp_*" nodes, so
    QueueManager(self).rx/tx simply come out as empty lists, which is exactly what we want for an
    MI-only test. _init_pcie() is left at the base class's no-op default.
    """

    async def _init_clks(self):
        await cocotb.start(Clock(self._dut.USR_CLK, 5, 'ns').start())
        await cocotb.start(Clock(self._dut.DMA_CLK, 4, 'ns').start())
        await cocotb.start(Clock(self._dut.MI_CLK, 10, 'ns').start())

        # Stage 2: NVME_* interfaces are now driven/monitored by the simplified DMA Iuventus
        # environment (drives NVME_RD_REQ_RDY/NVME_RD_MFB/NVME_OP_STAT, monitors NVME_WR_MFB),
        # which ties its own initial port values itself.
        self.dma_model = SimplifiedDmaModel(self._dut, self._dut.DMA_CLK)

        self._dut.PCIE_LINK_UP.value = 1
        self._dut.FPGA_ID.value = 0
        self._dut.FPGA_ID_VLD.value = 0

        # USER_CORE's MI slave port -- MI_ASYNC bridges it (MI_CLK/MI_RST side) to the DMA_CLK
        # domain MI_SPLITTER_PLUS_GEN and the CSR logic run on (mi_async_i), so this driver only
        # needs to know about MI_CLK.
        self.mi = [MIRequestDriver(self._dut, "MI", self._dut.MI_CLK)]

        # Conformance watchdog on NVME_RD_MFB and NVME_WR_MFB, both of which run on DMA_CLK. It
        # only samples, so it sits behind the SimplifiedDmaModel that drives and monitors them.
        self.mfb_props = attach_mfb_properties(self._dut, self._dut.DMA_CLK, reset=self._dut.DMA_RST)


    async def _reset(self):
        self._dut.USR_RST.value = 1
        self._dut.DMA_RST.value = 1
        self._dut.MI_RST.value = 1

        await Timer(100, units='ns')

        self._dut.USR_RST.value = 0
        self._dut.DMA_RST.value = 0
        self._dut.MI_RST.value = 0

        await Timer(100, units='ns')


async def _check_mi_access(dev):
    """Stage 1 smoke checks: USER_CORE served as a real nfb device.

    - nfb.comp_open("ziti,iuventus_test_ctrl") + read32(0x7C) == 0xCAFEBABE proves the *whole*
      path is reachable through the real nfb/DevTree/servicer machinery (not just a raw
      MIRequestDriver poke): comp_open's DevTree node lookup -> MIRequestDriver -> MI_ASYNC ->
      MI_SPLITTER_PLUS_GEN -> read_from_regs_p's `when others => X"CAFEBABE"` sentinel (see
      user_core_test_arch.vhd), which is deliberately what any *unmapped* register address (here
      0x7C) returns.
    - A write+readback of EVCR_INTERVAL_CYCLES (0x24, a real RW register, already used by
      apps/iuventus/sw/iuventus_rw_test.py on real hardware) proves the write path too.
    """
    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")

    sentinel = await e(c.read32)(0x7C)
    assert sentinel == 0xCAFEBABE, f"expected 0xCAFEBABE from unmapped reg 0x7C, got {sentinel:#010x}"

    await e(c.write32)(0x24, 0x12345678)
    readback = await e(c.read32)(0x24)
    assert readback == 0x12345678, f"EVCR_INTERVAL_CYCLES readback mismatch: wrote 0x12345678, got {readback:#010x}"


# Async helpers bridging IuventusTest property access into cocotb: each property does a blocking
# nfb C-extension call that must run inside a bridge thread, so `test.tst_mode = "rd"` from the
# main coroutine fails; methods are fine wrapped in `e(...)`.
async def aget(obj, name):
    return await e(lambda: getattr(obj, name))()


async def aset(obj, name, value):
    await e(lambda: setattr(obj, name, value))()


async def _wait_until(predicate, dut, max_cycles):
    """Awaits RisingEdge(dut.DMA_CLK) until predicate() is true or max_cycles elapse."""
    for _ in range(max_cycles):
        await RisingEdge(dut.DMA_CLK)
        if predicate():
            return True
    return False


async def _wait_until_reg(obj, name, dut, expected, poll_period_cycles=10, max_polls=200):
    """Like _wait_until, but for a register-backed property (e.g. IuventusTest.gen.generating)
    that can only be read through the bridge (aget), not synchronously -- polls every
    `poll_period_cycles` DMA_CLK cycles, up to `max_polls` times, re-reading the register each
    time (unlike a plain _wait_until(lambda: not stale_snapshot, ...), which would just check a
    value captured once before the loop started)."""
    for _ in range(max_polls):
        value = await aget(obj, name)
        if value == expected:
            return True
        for _ in range(poll_period_cycles):
            await RisingEdge(dut.DMA_CLK)
    return False


async def _case_one_read_request(dut, dev, test):
    """(a) ONE manual read dispatch (disp_rd_req) -> exactly one NVME_RD_REQ, matching the
    reference model bit-exactly (LBA_PTR, LBA_NUM, QID)."""
    await e(test.set_queue_range)(1)

    sb = Scoreboard("rd_req[one-shot]")
    model = ReadReqModel(num_queues=NUM_QUEUES)

    def on_accept(lba_ptr, lba_num, qid):
        sb.check(ExpectedReadReq(lba_ptr=lba_ptr, lba_num=lba_num, qid=qid))

    dev.dma_model.rd_req_accept_cb = on_accept

    lba_ptr = 0x1000
    lba_num = 3  # 4 sectors (0-based)
    sb.expect(model.next_manual_request(lba_ptr, lba_num))

    await e(test.disp_rd_req)(lba_ptr, lba_num)

    ok = await _wait_until(lambda: sb.checked >= 1, dut, max_cycles=500)
    assert ok, "timed out waiting for the single manual read request to be accepted"
    sb.assert_empty()

    dev.dma_model.rd_req_accept_cb = None


async def _case_command_identity(dut, dev, test):
    """The DMA publishes which command a completion and a returned frame belong to
    (NVME_RD_REQ_CID/_CID_VLD, RD_MFB_META, OP_STAT_QID/CID). USER_CORE latches all three and
    exposes them at 0x60/0x64/0x68, so software can attribute a state to a command.

    Checked against the identity the DMA model actually published, not against a constant: a
    register wired to the wrong field, or never written, would otherwise still read plausibly.
    """
    await e(test.set_queue_range)(1)
    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")

    # Latch the identity AT ACCEPT, not after: the model assigns it before invoking this callback,
    # and reading it later would pick up whatever a subsequent request had advanced it to.
    seen = {}

    def on_accept(lba_ptr_got, lba_num_got, qid_got):
        seen.setdefault("cid", dev.dma_model._inflight_cid)
        seen.setdefault("qid", dev.dma_model._inflight_qid)

    dev.dma_model.rd_req_accept_cb = on_accept

    lba_ptr = 0x2000
    lba_num = 1  # 2 sectors
    await e(test.disp_rd_req)(lba_ptr, lba_num)

    # Two separate waits. "_rd_busy is False" is ALSO true before the request is ever accepted, so
    # waiting only on that races straight past and reads registers still holding the previous
    # case's identity.
    ok = await _wait_until(lambda: "cid" in seen, dut, max_cycles=2000)
    assert ok, "the manual read was never accepted -- nothing to attribute"
    ok = await _wait_until(lambda: not dev.dma_model._rd_busy, dut, max_cycles=5000)
    assert ok, "timed out waiting for the read to complete -- no identity would be captured"
    await ClockCycles(dut.DMA_CLK, 10)

    want_cid = seen["cid"]
    want_qid = seen["qid"]

    op_stat_id = await e(c.read32)(0x60)
    rd_req_id = await e(c.read32)(0x64)
    rd_mfb_id = await e(c.read32)(0x68)

    for name, got in (("OP_STAT", op_stat_id), ("RD_REQ", rd_req_id), ("RD_MFB", rd_mfb_id)):
        assert got & (1 << 31), (
            f"{name} identity register {got:#010x} has its captured-since-reset bit clear -- the "
            f"identity was never latched"
        )

    assert (op_stat_id & 0xFFFF) == want_cid, (
        f"OP_STAT CID {op_stat_id & 0xFFFF} != published {want_cid}")
    assert ((op_stat_id >> 16) & ((1 << QID_W) - 1)) == want_qid, (
        f"OP_STAT QID {(op_stat_id >> 16) & ((1 << QID_W) - 1)} != published {want_qid}")
    assert (rd_req_id & 0xFFFF) == want_cid, (
        f"RD_REQ CID {rd_req_id & 0xFFFF} != published {want_cid}")
    assert (rd_mfb_id & 0xFFFF) == want_cid, (
        f"RD_MFB CID {rd_mfb_id & 0xFFFF} != published {want_cid}")
    assert ((rd_mfb_id >> 16) & ((1 << QID_W) - 1)) == want_qid, (
        f"RD_MFB QID {(rd_mfb_id >> 16) & ((1 << QID_W) - 1)} != published {want_qid}")

    cocotb.log.info(
        f"command identity: CID={want_cid} QID={want_qid} readable at 0x60/0x64/0x68"
    )
    dev.dma_model.rd_req_accept_cb = None


async def _case_one_write_frame(dut, dev, test):
    """(b) ONE write frame (disp_wr_req, one sector) -> the FIRST NVME_WR_MFB frame matches the
    reference model's data pattern + META (LBA_PTR | QID) bit-exactly.

    Note: `burst_size` (MFB_GENERATOR_MI32's CTRL_CHAN_INC[31:16]) governs the write-side channel
    round-robin group size, NOT how many frames get generated in total -- once enabled (with
    `bursting`/burst_mode_en=1, the IuventusTest default), the generator free-runs continuously
    until explicitly disabled again (exactly like apps/iuventus/sw/iuventus_rw_test.py's own
    disp_wr_req/enabled=False sequencing on real hardware). So this case detaches the callback
    (and only THEN disables the generator) right after the first frame is confirmed, rather than
    relying on the generator to auto-stop after one frame.
    """
    await e(test.set_queue_range)(1)

    sb = Scoreboard("wr_frame[one-shot]")
    model = WriteFrameModel(num_queues=NUM_QUEUES)

    def on_frame(trans):
        lba_ptr = trans.meta & ((1 << 64) - 1)
        qid = trans.meta >> 64
        sb.check(ExpectedWrFrame(data=bytes(trans.data), lba_ptr=lba_ptr, qid=qid))
        if sb.checked >= 1:
            dev.dma_model.wr_frame_accept_cb = None

    dev.dma_model.wr_frame_accept_cb = on_frame

    lba_ptr = 0x3000
    lba_num = 0  # 1 sector = 512 bytes = 8 region-beats
    sb.expect(model.next_frame(lba_ptr, (lba_num + 1) * 512))

    await e(test.disp_wr_req)(lba_ptr, lba_num, 1)

    ok = await _wait_until(lambda: sb.checked >= 1, dut, max_cycles=1000)
    assert ok, "timed out waiting for the single write frame to be accepted"
    sb.assert_empty()

    await aset(test.gen, "enabled", False)


async def _case_small_read_burst(dut, dev, test, lba_num):
    """(c) a small (minimum-sized, 1000-iteration) read throughput burst -> stream order/QID/count
    match, at whatever NUM_QUEUES the design was elaborated with (collapses to q0 at NUM_QUEUES=1,
    full round-robin at NUM_QUEUES=4). Also probes the EVCR/EVENT_COUNTER event count, and
    explicitly cross-checks the seq-address step size: user_core_test_arch.vhd's seq_addr_cntr_p
    advances the ACCEPTED request's own queue by lba_num+1 LBAs, so the step is only visible
    within one queue's substream -- see user_core_model.py's ReadReqModel.next_burst_request()
    docstring. Called twice by the top-level test, once with lba_num=0 (the smallest step, 1) and
    once with lba_num=3 (checks a >1 step).

    History note (both since resolved as ONE testbench bug, not RTL bugs): an earlier version of
    dma_iuventus_model.py's _rd_req_loop drove NVME_RD_REQ_RDY reactively out of the
    ReadOnly/NextTimeStep phase instead of as a synchronous level decided fresh at each RisingEdge.
    That produced RDY transitions the DUT's own DMA_CLK-registered processes never actually
    registered as clean, edge-aligned handshakes, even though this test's own ReadOnly-synced
    monitor sampled VLD&RDY=1 at two distinct cycles. Two symptoms were consequently (and
    incorrectly) reported as "confirmed RTL bugs": rd_qid_cntr never advancing at NUM_QUEUES>1,
    and EVENT_COUNTER's eve_cnt_reg never incrementing (EVENT_VLD = NVME_RD_REQ_VLD and
    NVME_RD_REQ_RDY is correctly 0 at the DUT's own clock edge if the DUT never really registered
    the accept). See dma_iuventus_model.py's _rd_req_loop docstring for the fix. Neither
    user_core_test_arch.vhd's rd_qid_rr_p nor comp/base/misc/event_counter/event_counter.vhd was
    ever at fault; both are exercised elsewhere too (event_counter has its own passing
    testbench.vhd) and were correct all along. QID/address advancement across NUM_QUEUES is
    already positively confirmed by the reference-model scoreboard below (it would fail the
    instant a real DUT qid/lba_ptr diverged from the model's prediction); an EVCR event-count
    cross-check against this test's own accepted-request tally is kept below to positively confirm
    TOTAL_EVENTS now increments correctly too.
    """
    n_queues = NUM_QUEUES
    await e(test.set_queue_range)(n_queues)

    sb = Scoreboard(f"rd_req[burst,lba_num={lba_num}]")
    model = ReadReqModel(num_queues=n_queues)
    model.configure_range(0, n_queues - 1, 1)  # rd_burst=1: advance queue every request

    lba_ptr = 0x2000
    iterations = 1000  # IuventusTest.tst_iterations enforces >= 1000

    # Small vs. the ~2^28-cycle production default, so an interval genuinely completes early in
    # this burst -- lets the check below cross-check TOTAL_EVENTS against this test's own tally.
    await aset(test, "evcr_interval_cycles", EVCR_INTERVAL_CYCLES)

    accepted_since_reached = 0
    # First few accepted addresses PER QUEUE, for the explicit step-size assertion below. The
    # counter is per queue, so two consecutive accepts of a round-robin stream come from different
    # queues and their difference is not the step.
    seen_addrs = {q: [] for q in range(n_queues)}

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        nonlocal accepted_since_reached
        # Compute the expectation lazily at accept time: next_burst_request() reads the model's
        # CURRENT per-queue seq_addr/QID and applies the advance this accept causes; precomputing
        # would freeze every entry at the initial value.
        sb.expect(model.next_burst_request())
        sb.check(ExpectedReadReq(lba_ptr=got_lba_ptr, lba_num=got_lba_num, qid=got_qid))
        model.on_completion()
        accepted_since_reached += 1
        q = got_qid if got_qid < n_queues else 0
        if len(seen_addrs[q]) < 5:
            seen_addrs[q].append(got_lba_ptr)

    dev.dma_model.rd_req_accept_cb = on_accept

    model.start_burst(lba_ptr, lba_num, addressing="seq", contig=False)

    await aset(test, "rd_req_lba_ptr", lba_ptr)
    await aset(test, "rd_req_lba_num", lba_num)
    await aset(test, "tst_addressing", "seq")
    await aset(test, "tst_mode", "rd")
    await aset(test, "contig_test", False)
    await aset(test, "tst_iterations", iterations)  # fires tst_trigg -- must be written LAST

    # EVCR cross-check: confirm MI-visible TOTAL_EVENTS matches this test's own completion tally
    # for the first interval, read back before the next interval completes. Tallied from the
    # architecture side of the pipeline, which leads the pins by its depth.
    internal = dut.iops_cntr_i
    prev_int_reached = False
    first_interval_events = None
    completions_since_reached = 0
    for _ in range(1000):
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        # TOTAL_EVENTS latches the count through the PREVIOUS cycle, so a completion coincident
        # with int_reached belongs to the next interval: close the interval before counting it.
        reached = bool(internal.int_reached.value)
        pulse = (bool(dut.core_op_stat_vld.value)
                 and int(dut.core_op_stat_code.value) == OP_STAT_CODE_SUCCESS)
        if reached and not prev_int_reached:
            first_interval_events = completions_since_reached
            completions_since_reached = 0
            break
        prev_int_reached = reached
        if pulse:
            completions_since_reached += 1

    assert first_interval_events is not None, (
        f"no EVCR interval (evcr_interval_cycles={EVCR_INTERVAL_CYCLES}) completed within 1000 "
        "DMA_CLK cycles of the burst starting -- can't cross-check TOTAL_EVENTS"
    )
    assert first_interval_events > 0, "no completion was observed during the first EVCR interval"

    got_events = await aget(test, "evcr_total_events")
    got_cycles = await aget(test, "evcr_total_cycles")
    assert got_events == first_interval_events, (
        f"EVCR TOTAL_EVENTS ({got_events}) does not match this test's own tally of successful "
        f"completions during the first completed interval ({first_interval_events})"
    )
    assert got_cycles == EVCR_INTERVAL_CYCLES, (
        f"EVCR TOTAL_CYCLES read back {got_cycles}, expected the programmed interval "
        f"{EVCR_INTERVAL_CYCLES} -- event_counter.vhd latches TOTAL_CYCLES from int_pr_cnt_reg at "
        f"the very cycle it equals int_cyc_reg, so the two cannot legitimately differ"
    )
    cocotb.log.info(
        f"EVCR first interval: TOTAL_EVENTS={got_events} (tally {first_interval_events}), "
        f"TOTAL_CYCLES={got_cycles}"
    )

    ok = await _wait_until(lambda: sb.checked >= iterations, dut, max_cycles=iterations * 50)
    assert ok, f"timed out: only {sb.checked}/{iterations} burst read requests were accepted (short stream)"
    sb.assert_empty()

    # Explicit step-size check atop the scoreboard's bit-exact match: WITHIN one queue the address
    # stream must advance by exactly lba_num+1 every step -- direct evidence of "lba_num=0 -> +1,
    # contiguous per queue", not an indirect scoreboard pass.
    steps_checked = 0
    for q, addrs in seen_addrs.items():
        for prev_addr, next_addr in zip(addrs, addrs[1:]):
            step = next_addr - prev_addr
            assert step == lba_num + 1, (
                f"queue {q}: seq address step was {step}, expected lba_num+1={lba_num + 1} "
                f"(addresses observed: {addrs!r})"
            )
            steps_checked += 1
    assert steps_checked > 0, (
        f"no queue saw two accepted requests, so the address step was never checked "
        f"(addresses observed: {seen_addrs!r})"
    )

    model.stop_burst()
    dev.dma_model.rd_req_accept_cb = None


# --- Stage 3: drive iuventus_rw_test.py's REAL CLI-path functions ---
# That script is the only user-facing entry point, so exercising the exact functions main()'s
# -r/-w/-t handlers call is the primary surface here, on top of Stage 2's property pokes.

async def _case_cli_read_dispatch_sizes(dut, dev, test):
    """Stage 3.1: '-r LBA_PTR LBA_NUM' (run_read_dispatch) at both size extremes -- lba_num=0 (1
    LBA, the smallest legal request) and lba_num=255 (256 LBAs, the largest value that fits the
    8-bit NVME_RD_REQ_LBA_NUM field, per IuventusTest.disp_rd_req's own `assert lba_num < 256`)."""
    await e(test.set_queue_range)(1)

    model = ReadReqModel(num_queues=NUM_QUEUES)

    for lba_ptr, lba_num in ((0x4000, 0), (0x5000, 255)):
        sb = Scoreboard(f"cli_rd_dispatch[lba_num={lba_num}]")

        def on_accept(got_lba_ptr, got_lba_num, got_qid, sb=sb):
            sb.check(ExpectedReadReq(lba_ptr=got_lba_ptr, lba_num=got_lba_num, qid=got_qid))

        dev.dma_model.rd_req_accept_cb = on_accept

        sb.expect(model.next_manual_request(lba_ptr, lba_num))
        await e(run_read_dispatch)(test, lba_ptr, lba_num)

        ok = await _wait_until(lambda sb=sb: sb.checked >= 1, dut, max_cycles=2000)
        assert ok, f"timed out waiting for the run_read_dispatch(lba_num={lba_num}) request to be accepted"
        sb.assert_empty()

    dev.dma_model.rd_req_accept_cb = None


async def _case_cli_write_dispatch(dut, dev, test):
    """Stage 3.2: '-w LBA_PTR LBA_NUM' (run_write_dispatch), one sector -- exercises the exact
    function main()'s '-w' handler calls (a thin wrapper around disp_wr_req, already validated in
    Stage 2's _case_one_write_frame, but driven here through the split-out function itself)."""
    await e(test.set_queue_range)(1)

    sb = Scoreboard("cli_wr_dispatch")
    model = WriteFrameModel(num_queues=NUM_QUEUES)

    def on_frame(trans):
        lba_ptr = trans.meta & ((1 << 64) - 1)
        qid = trans.meta >> 64
        sb.check(ExpectedWrFrame(data=bytes(trans.data), lba_ptr=lba_ptr, qid=qid))
        if sb.checked >= 1:
            dev.dma_model.wr_frame_accept_cb = None

    dev.dma_model.wr_frame_accept_cb = on_frame

    lba_ptr = 0x6000
    lba_num = 0
    sb.expect(model.next_frame(lba_ptr, (lba_num + 1) * 512))

    await e(run_write_dispatch)(test, lba_ptr, lba_num)

    ok = await _wait_until(lambda: sb.checked >= 1, dut, max_cycles=1000)
    assert ok, "timed out waiting for the run_write_dispatch write frame to be accepted"
    sb.assert_empty()

    await aset(test.gen, "enabled", False)


async def _case_cli_throughput_point(dut, dev, test, n_queues, addressing="seq", size=3, settle_cycles=3000):
    """Stage 3.3: drive ONE real '-t' throughput measurement point (read mode) through
    iuventus_rw_test.py's OWN exported _throughput_point_start/_throughput_point_stop -- the exact
    functions run_throughput()/run_throughput_point() call for every sweep point -- rather than
    re-poking the same registers a second time.

    The measurement itself can't be driven through a single bridged call to the full
    run_throughput_point()/run_throughput() (which use a real time.sleep()-based settle by
    default): a plain time.sleep() inside a bridged thread blocks real wall-clock time while the
    simulator's own clocks are frozen (nothing else is scheduled to advance them in the meantime),
    so no simulated read activity would occur during a multi-second wall-clock "settle". Instead,
    the settle here is an explicit DMA_CLK cycle wait driven by THIS async test. _throughput_point_
    stop is still called via the real function, with sleep_fn replaced by a no-op: its own
    gen.generating/rd_req_vld polls are genuine MI-bus reads that need real simulated cycles to
    complete regardless of sleep_fn, so a no-op sleep_fn between polls doesn't skip any needed
    synchronization -- it just polls as fast as the MI bus allows instead of once per 100 ms of
    wall-clock time.

    Checks the full round-robin read-request stream (order/QID/size) via the reference-model
    scoreboard, and cross-checks IuventusTest.iops()/EVCR_TOTAL_EVENTS against this test's own
    accepted-request tally for the second interval boundary observed after the settle loop starts
    (the exact same cross-check as _case_small_read_burst's) -- the FIRST boundary is skipped
    because it can catch a stale/partial interval that was already mostly elapsed while
    _throughput_point_start's several MI register writes were still in flight (each MI transaction
    costs multiple DMA_CLK cycles, comparable to a short interval), before any read had actually
    been serviced yet.

    NOTE on _throughput_point_stop: the scoreboard callback is deliberately detached BEFORE calling
    it. A genuine RTL race was found and reported separately (not fixed here, per instructions):
    NVME_RD_REQ_LBA_PTR's address mux (user_core_test_arch.vhd, ~L580) is purely combinational on
    (tst_finished, contig_test), independent of whether a request is currently VLD (in flight, not
    yet RDY-accepted). If contig_test is cleared (by _throughput_point_stop, to end the test) while
    a request is already VLD=1 awaiting RDY, the address that backend sees at the ACCEPT instant can
    "tear" from the continuing seq/rand test address to the (here, zero/stale) manual-dispatch
    register -- confirmed via a cycle-accurate signal dump (contig_test 1->0 with NEITHER tst_trigg
    NOR data_logger_rst asserted, exactly coinciding with one accepted request's LBA_PTR reading 0
    instead of the expected continuing address). This is a stop-transition-only tail effect (one
    request, at most), not a steady-state generation error, so it's excluded from THIS scoreboard's
    scope rather than causing a nondeterministic gate failure.
    """
    await e(test.set_queue_range)(n_queues)
    await aset(test, "evcr_interval_cycles", EVCR_INTERVAL_CYCLES)

    sb = Scoreboard(f"cli_throughput[rd,{addressing},size={size}]")
    model = ReadReqModel(num_queues=n_queues)
    model.configure_range(0, n_queues - 1, 1)

    accepted_since_reached = 0

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        nonlocal accepted_since_reached
        sb.expect(model.next_burst_request())
        sb.check(ExpectedReadReq(lba_ptr=got_lba_ptr, lba_num=got_lba_num, qid=got_qid))
        model.on_completion()
        accepted_since_reached += 1

    dev.dma_model.rd_req_accept_cb = on_accept

    # _throughput_point_start's read-mode branch sets rd_req_lba_num + contig_test=True but leaves
    # rd_req_lba_ptr untouched -- matching run_throughput()'s behavior of continuing from whatever
    # LBA_PTR is already configured (0 after reset).
    lba_ptr = await aget(test, "rd_req_lba_ptr")
    model.start_burst(lba_ptr, size, addressing=addressing, contig=True)

    await e(_throughput_point_start)(test, "rd", addressing, size)

    internal = dut.iops_cntr_i
    prev_int_reached = False
    intervals_seen = 0
    clean_interval_events = None
    completions_since_reached = 0
    cycles_run = 0
    # Stop at the second interval boundary (so evcr_total_events reads back before a THIRD
    # interval completes), then keep running the remaining settle_cycles budget purely to
    # accumulate more scoreboard-checked traffic.
    for _ in range(settle_cycles):
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        cycles_run += 1
        # Tally successful-completion pulses (an accept-based tally would be off by what's in
        # flight at the boundary): TOTAL_EVENTS latches through the PREVIOUS cycle, so a completion
        # coincident with int_reached belongs to the next interval -- close it first.
        reached = bool(internal.int_reached.value)
        pulse = (bool(dut.core_op_stat_vld.value)
                 and int(dut.core_op_stat_code.value) == OP_STAT_CODE_SUCCESS)
        if reached and not prev_int_reached:
            intervals_seen += 1
            # Take the first FULLY-OBSERVED interval containing a completion; interval 1 is
            # skipped since the point started mid-interval. A large transfer can span several
            # intervals, so scanning to a non-empty one avoids comparing 0 == 0.
            if intervals_seen >= 2 and completions_since_reached > 0:
                clean_interval_events = completions_since_reached
                completions_since_reached = 0
                break
            completions_since_reached = 0
        prev_int_reached = reached
        if pulse:
            completions_since_reached += 1

    assert clean_interval_events is not None, (
        f"no fully-observed EVCR interval containing a completion within {settle_cycles} DMA_CLK "
        "cycles of the throughput point starting -- can't cross-check TOTAL_EVENTS/iops()"
    )
    assert clean_interval_events > 0, "no completion was observed during the second (clean) EVCR interval"

    got_events = await aget(test, "evcr_total_events")
    assert got_events == clean_interval_events, (
        f"EVCR TOTAL_EVENTS ({got_events}) does not match this test's own tally of successful "
        f"completions during the second (clean) completed interval ({clean_interval_events})"
    )
    got_cycles = await aget(test, "evcr_total_cycles")
    assert got_cycles == EVCR_INTERVAL_CYCLES, (
        f"EVCR TOTAL_CYCLES read back {got_cycles}, expected the programmed interval "
        f"{EVCR_INTERVAL_CYCLES}"
    )
    iops = await e(test.iops)()
    # iops() is TOTAL_EVENTS / (TOTAL_CYCLES * clk_period), so reproduce it from the same two
    # registers: a bare "> 0" would pass even if it were reading the wrong register pair.
    clk_period = await e(lambda: test.clk_period)()
    expect_iops = got_events / (got_cycles * clk_period)
    assert math.isclose(iops, expect_iops, rel_tol=1e-9), (
        f"IuventusTest.iops() returned {iops}, but TOTAL_EVENTS={got_events} / (TOTAL_CYCLES="
        f"{got_cycles} * clk_period={clk_period}) is {expect_iops}"
    )
    cocotb.log.info(
        f"EVCR clean interval: TOTAL_EVENTS={got_events} (tally {clean_interval_events}), "
        f"TOTAL_CYCLES={got_cycles}, iops={iops:.0f}"
    )

    # Keep the read stream running for the rest of the settle budget, purely so the scoreboard
    # accumulates a meaningful amount of round-robin traffic (order/QID/size) beyond the two short
    # intervals used for the EVCR cross-check above.
    for _ in range(max(settle_cycles - cycles_run, 0)):
        await RisingEdge(dut.DMA_CLK)

    assert sb.checked > 0, "no read traffic observed during the throughput point's settle window"
    sb.assert_empty()

    # Detach the scoreboard before stopping: the stop transition can retire one already-in-flight
    # request against a torn address, a separately-reported RTL race, not part of what this
    # scoreboard validates.
    dev.dma_model.rd_req_accept_cb = None

    await e(_throughput_point_stop)(test, "rd", sleep_fn=lambda seconds: None)


async def _case_throughput_multi_point(dut, dev, test, n_queues, n_points=6):
    """Consecutive '-t' sweep points.

    _case_cli_throughput_point drives exactly ONE point, so it cannot see the sequencing a real
    sweep performs: start -> settle -> stop -> start the NEXT point. A stall in that sequence (the
    read page pool not recovering between points at N=4, rd_free stuck at 0) is nearly unreadable
    on the card, where stale processes and device contention obscure it, so it is caught here.

    _throughput_point_stop only clears contig_test for reads; it does not wait for in-flight
    operations to retire. This asserts the pool nonetheless recovers between points, which is the
    property a sweep depends on and the one that failed on the card."""
    lba_ptr = await aget(test, "rd_req_lba_ptr")
    sizes = [0, 1, 3, 7, 15, 31][:n_points]
    for idx, size in enumerate(sizes):
        await e(_throughput_point_start)(test, "rd", "rand", size)
        for _ in range(1500):
            await RisingEdge(dut.DMA_CLK)
        await e(_throughput_point_stop)(test, "rd", sleep_fn=lambda _s: None)

        # Let the point retire before the next one starts. Sampling ends with an explicit clock
        # edge so the phase is writable again -- a bridged MI write from the ReadOnly phase raises.
        recovered = False
        for _ in range(20000):
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            quiet = int(dut.NVME_RD_REQ_VLD.value) == 0
            await RisingEdge(dut.DMA_CLK)
            if quiet:
                recovered = True
                break
        assert recovered, (
            f"point {idx} (size={size}) left read requests asserted after "
            f"_throughput_point_stop -- the next sweep point would start on top of it"
        )


# Engine-side requests scored per queue: bounded below REQ_FIFO_ITEMS(16, IF_PIPE_REQ_ITEMS) so
# no queue's credits saturate mid-window (breaking round-robin scoring), and above the DMA round
# trip so the window scores more than just the LFSR seed.
ENGINE_SCORED_REQS_PER_QUEUE = 12


async def _case_rd_burst_and_rand(dut, dev, test):
    """Stage 3.4: two directed corner cases for the read burst path, folded into one (both need
    NUM_QUEUES>1 to be meaningful and are skipped otherwise):
      - rd_burst > 1: RD_BURST=2 means the QID round-robin advances every 2 accepted requests
        instead of every 1 (user_core_test_arch.vhd's rd_qid_rr_p / RoundRobinQid.next_qid()).
      - random addressing: LBA_PTR follows the LFSR (lfsr_rand_addr_gen_i / lfsr21_step) instead
        of the sequential counter.

    Scored at the ENGINE boundary (rd_req_accepted_s / nvme_rd_req_qid_s / core_rd_req_lba_ptr),
    unlike every other case here, because NEITHER property survives user_core_if_pipe.vhd. Its
    read-request path is a per-queue FIFO whose ENG_RD_REQ_RDY is credit-gated (:356), not gated
    on the DMA's ready: the engine issues one request per DMA_CLK cycle into those FIFOs, and the
    DMA drains them through mv_pick_p's own rotation over the non-empty queues. Both consequences
    are measured, not assumed. The pin-side QID sequence is that rotation (0,1,2,3,...) and
    carries no trace of RD_BURST; and the LFSR, which steps on core_op_stat_vld, is still on its
    seed for the engine's first ~32 addresses, because one DMA round trip costs ~22 cycles more
    than the engine needs to fill the FIFOs. A pin-side scoreboard could only assert things
    neither register controls.

    The two model hooks are driven by the events they name: the sequential counter advances on the
    accept and the LFSR on the completion, exactly where user_core_test_arch.vhd puts them.
    """
    if NUM_QUEUES <= 1:
        return

    n_queues = NUM_QUEUES
    await e(test.set_queue_range)(n_queues)
    await aset(test, "rd_burst", 2)

    sb = Scoreboard("rd_req[burst=2,rand]")
    model = ReadReqModel(num_queues=n_queues)
    model.configure_range(0, n_queues - 1, 2)  # rd_burst=2: advance queue every 2 requests

    lba_ptr = 0x7000
    lba_num = 1
    iterations = 1000
    scored_reqs = ENGINE_SCORED_REQS_PER_QUEUE * n_queues

    def _lvl(sig):
        """int() of a signal, treating an X/U bit as 0 -- these read X for the first cycles out
        of reset, where a bare int() would raise and kill the monitor."""
        try:
            return int(sig.value)
        except ValueError:
            return 0

    lfsr_stepped = False
    scored_after_step = 0

    async def _engine_monitor():
        # An accept and a completion can land in the same cycle. The accepted request carries the
        # address the LFSR held BEFORE that cycle's step (both registers take this cycle's
        # inputs), so the accept is scored first and the completion applied after.
        nonlocal lfsr_stepped, scored_after_step
        while sb.checked < scored_reqs:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            if _lvl(dut.rd_req_accepted_s) == 1:
                sb.expect(model.next_burst_request())
                sb.check(ExpectedReadReq(
                    lba_ptr=_lvl(dut.core_rd_req_lba_ptr),
                    lba_num=_lvl(dut.core_rd_req_lba_num),
                    qid=_lvl(dut.nvme_rd_req_qid_s),
                ))
                if lfsr_stepped:
                    scored_after_step += 1
            if _lvl(dut.core_op_stat_vld) == 1:
                model.on_completion()
                lfsr_stepped = True

    # Pin-side tally only. The pipe's arbiter decides the order there, so nothing about that order
    # is asserted -- only that the requests the engine issued do reach the DMA.
    pin_accepts = 0

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        nonlocal pin_accepts
        pin_accepts += 1

    dev.dma_model.rd_req_accept_cb = on_accept

    model.start_burst(lba_ptr, lba_num, addressing="rand", contig=False)
    # Started before tst_trigg: rd_req_vld_reg_p only raises the generator's VLD once the test is
    # running (or contig_test is set), so no accept can be missed ahead of the monitor.
    cocotb.start_soon(_engine_monitor())

    await aset(test, "rd_req_lba_ptr", lba_ptr)
    await aset(test, "rd_req_lba_num", lba_num)
    await aset(test, "tst_addressing", "rand")
    await aset(test, "tst_mode", "rd")
    await aset(test, "contig_test", False)
    await aset(test, "tst_iterations", iterations)  # fires tst_trigg -- must be written LAST

    ok = await _wait_until(lambda: sb.checked >= scored_reqs, dut, max_cycles=scored_reqs * 200)
    assert ok, (
        f"timed out: only {sb.checked}/{scored_reqs} rd_burst=2/rand requests were scored at the "
        f"engine boundary"
    )
    sb.assert_empty()

    # Anti-vacuity guard: some scored request must carry a STEPPED LFSR value, not the seed. The
    # engine issues one request/cycle while the first completion is a round trip away, so closing
    # before it would pass unchanged with on_completion deleted.
    assert scored_after_step > 0, (
        f"every one of the {scored_reqs} scored addresses predated the first completion, so they "
        f"were all the LFSR seed and the lfsr21_step/on_completion path went unchecked"
    )

    # The engine can run a whole credit pool ahead of the DMA, so a window that closes inside that
    # pool has not yet shown anything reached the pins. This is what the pin side can still prove.
    ok = await _wait_until(lambda: pin_accepts >= 2 * n_queues, dut, max_cycles=20000)
    assert ok, (
        f"only {pin_accepts} of the engine's {sb.checked} accepted requests reached the DMA -- "
        f"the request pipe is not draining"
    )

    model.stop_burst()
    dev.dma_model.rd_req_accept_cb = None
    await aset(test, "rd_burst", 1)  # restore the default for subsequent cases


async def _case_write_enable_disable_midstream(dut, dev, test):
    """Stage 3.5: enable the write generator, let a handful of frames pass, DISABLE it mid-stream
    (before it would have stopped on its own), confirm generation actually halts (gen.generating
    goes False and no further frames arrive), then re-enable it and confirm it resumes cleanly
    with no corrupted/truncated frame at the boundary (the reference-model scoreboard would catch
    a corrupted frame; a stuck DST_RDY/SRC_RDY handshake would show up as the resume timing out)."""
    await e(test.set_queue_range)(1)

    sb = Scoreboard("wr_frame[enable_disable_midstream]")
    model = WriteFrameModel(num_queues=NUM_QUEUES)
    lba_ptr = 0x8000
    lba_num = 0

    def on_frame(trans):
        # Lazy expectation, like _case_small_read_burst's on_accept: the generator is free-running,
        # so the frame COUNT accepted before a disable takes effect isn't known in advance;
        # next_frame() per arrival avoids committing to a count it could outrun.
        got_lba_ptr = trans.meta & ((1 << 64) - 1)
        got_qid = trans.meta >> 64
        sb.expect(model.next_frame(lba_ptr, (lba_num + 1) * 512))
        sb.check(ExpectedWrFrame(data=bytes(trans.data), lba_ptr=got_lba_ptr, qid=got_qid))

    dev.dma_model.wr_frame_accept_cb = on_frame

    await e(run_write_dispatch)(test, lba_ptr, lba_num, 1)

    ok = await _wait_until(lambda: sb.checked >= 3, dut, max_cycles=3000)
    assert ok, f"timed out: only {sb.checked}/3 frames accepted before mid-stream disable"

    await aset(test.gen, "enabled", False)
    ok = await _wait_until_reg(test.gen, "generating", dut, expected=False)
    assert ok, "write generator still reports 'generating' after being disabled mid-stream"

    checked_before_resume = sb.checked

    await aset(test.gen, "enabled", True)

    ok = await _wait_until(lambda: sb.checked >= checked_before_resume + 3, dut, max_cycles=3000)
    assert ok, "write generator did not resume producing correctly-matching frames after re-enable"

    await aset(test.gen, "enabled", False)
    dev.dma_model.wr_frame_accept_cb = None


async def _case_backpressure_no_wedge(dut, dev, test):
    """Stage 3.6 (the headline Stage-3 check): run a read burst with the DMA model's backpressure
    enabled (NVME_RD_REQ_RDY and NVME_WR_MFB_DST_RDY both intermittently held low, 3 cycles out of
    every 10 -- see dma_iuventus_model.py's enable_backpressure()), and confirm:
      - the reference-model scoreboard still matches bit-exactly (no dropped or duplicated
        requests despite the intermittent stalls);
      - the burst still completes within a bounded (if larger) cycle budget -- i.e. the read
        generator does NOT wedge/hang permanently once backpressure clears. This is the direct
        component-level sim analog of a real backend going temporarily unresponsive: here it is
        USER_CORE's OWN generator being checked for correct recovery, not DMA_IUVENTUS's/the
        SSD's doorbell logic (out of scope for this component-level harness).
    """
    n_queues = NUM_QUEUES
    await e(test.set_queue_range)(n_queues)

    sb = Scoreboard("rd_req[backpressure]")
    model = ReadReqModel(num_queues=n_queues)
    model.configure_range(0, n_queues - 1, 1)

    lba_ptr = 0x9000
    lba_num = 1
    iterations = 1000

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        sb.expect(model.next_burst_request())
        sb.check(ExpectedReadReq(lba_ptr=got_lba_ptr, lba_num=got_lba_num, qid=got_qid))
        model.on_completion()

    dev.dma_model.rd_req_accept_cb = on_accept
    dev.dma_model.enable_backpressure(bp_period=10, bp_low_cycles=3)

    model.start_burst(lba_ptr, lba_num, addressing="seq", contig=False)

    await aset(test, "rd_req_lba_ptr", lba_ptr)
    await aset(test, "rd_req_lba_num", lba_num)
    await aset(test, "tst_addressing", "seq")
    await aset(test, "tst_mode", "rd")
    await aset(test, "contig_test", False)
    await aset(test, "tst_iterations", iterations)  # fires tst_trigg -- must be written LAST

    # Larger cycle budget than the no-backpressure burst case's (iterations*50): backpressure
    # holds RDY/DST_RDY low ~30% of the time, so completion legitimately takes longer -- this is
    # a bound on "eventually completes", not a claim about exact throughput.
    ok = await _wait_until(lambda: sb.checked >= iterations, dut, max_cycles=iterations * 150)
    assert ok, (
        f"read generator appears WEDGED under backpressure: only {sb.checked}/{iterations} "
        "requests were accepted within a generously extended cycle budget"
    )
    sb.assert_empty()

    model.stop_burst()
    dev.dma_model.rd_req_accept_cb = None
    dev.dma_model.disable_backpressure()


async def _case_mi_async_reset_asymmetry(dut, dev, test):
    """(NEW) MI_ASYNC's own cross-clock reset FSM (comp/mi_tools/async/mi_async.vhd's reset_state:
    NO_RESET/MASTER_RESET/SLAVE_RESET/COMP_RESET) only ever visits NO_RESET<->COMP_RESET anywhere
    else in this suite, because IuventusUserCoreNfbDevice._reset() always asserts/deasserts MI_RST
    (master side, MI_CLK domain) and DMA_RST (slave side, DMA_CLK domain, synchronized into MI_CLK
    via mi_async_i's own ASYNC_RESET instance) in lockstep. MASTER_RESET/SLAVE_RESET instead
    require exactly ONE side to be in reset while the other stays clear -- a real (if less common)
    bring-up scenario the RTL is defensively designed for (e.g. one clock domain resetting
    independently of the other, such as a partial/warm reset or a not-yet-locked clock). Directly
    toggles MI_RST/DMA_RST out of lockstep via cocotb signal writes and confirms both states are
    actually visited with a white-box peek of mi_async_i.p_state (reset_state's 0-based literal
    index per cocotb's own VHDL-enum convention: NO_RESET=0, MASTER_RESET=1, SLAVE_RESET=2,
    COMP_RESET=3), then restores a normal synchronized reset and proves the MI path still works
    (the same read32(0x7C)==0xCAFEBABE smoke check _check_mi_access uses) before handing back to
    the rest of the suite."""
    NO_RESET, MASTER_RESET, SLAVE_RESET = 0, 1, 2

    # The architecture runs off the interface pipeline's delayed reset copy, so the DMA-side reset
    # reaches MI_ASYNC a few DMA_CLK cycles after DMA_RST moves, on top of the FSM's own
    # cross-domain handshake. Settle long enough that neither is being raced.
    SETTLE = 20

    async def _settle(cycles):
        for _ in range(cycles):
            await RisingEdge(dut.MI_CLK)

    dut.MI_RST.value = 0
    dut.DMA_RST.value = 0
    await _settle(SETTLE)
    assert int(dut.mi_async_i.p_state.value) == NO_RESET, "did not start in NO_RESET"

    # MI_RST alone: RESET_M='1' while reset_s_sync(0) stays '0' -> MASTER_RESET.
    dut.MI_RST.value = 1
    await _settle(SETTLE)
    got = int(dut.mi_async_i.p_state.value)
    assert got == MASTER_RESET, (
        f"expected MASTER_RESET ({MASTER_RESET}) with MI_RST alone asserted, got {got}"
    )
    dut.MI_RST.value = 0
    await _settle(SETTLE)
    assert int(dut.mi_async_i.p_state.value) == NO_RESET, (
        "did not return to NO_RESET after MI_RST alone was cleared"
    )

    # DMA_RST alone: reset_s_sync(0)='1' (synced from RESET_S=DMA_RST) while RESET_M stays '0'
    # -> SLAVE_RESET.
    dut.DMA_RST.value = 1
    await _settle(SETTLE)
    got = int(dut.mi_async_i.p_state.value)
    assert got == SLAVE_RESET, (
        f"expected SLAVE_RESET ({SLAVE_RESET}) with DMA_RST alone asserted, got {got}"
    )
    dut.DMA_RST.value = 0
    await _settle(SETTLE)
    assert int(dut.mi_async_i.p_state.value) == NO_RESET, (
        "did not return to NO_RESET after DMA_RST alone was cleared"
    )

    # Restore a normal, fully synchronized reset (matches _reset()'s own lockstep sequencing)
    # before handing back to the rest of the suite, and prove the MI path still works afterwards.
    dut.MI_RST.value = 1
    dut.DMA_RST.value = 1
    await _settle(10)
    dut.MI_RST.value = 0
    dut.DMA_RST.value = 0
    await _settle(10)

    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")
    sentinel = await e(c.read32)(0x7C)
    assert sentinel == 0xCAFEBABE, (
        f"MI path did not recover after the reset-asymmetry sequence: expected 0xCAFEBABE from "
        f"unmapped reg 0x7C, got {sentinel:#010x}"
    )


async def _case_data_logger_mi_smoke(dut, dev, test):
    """(NEW) MI_SPLITTER_PLUS_GEN's port2 (base 0x200, "Data Logger for latency meter" -- see
    user_core_test_arch.vhd's MI_SPLIT_BASES) is otherwise never addressed by any test in this
    suite: its OUTPUT_PIPES_G(2) pipeline register (comp/base/misc/pipe/pipe_arch.vhd's own
    fsm_states) never transfers even a FIRST item (stuck at S_0 the whole run), unlike ports 0/1
    which do get exercised elsewhere. One raw MI read at the Data Logger's own CTRL register
    (offset 0 within its window -- a plain read-only status word, see comp/debug/data_logger.vhd's
    MI_CTRL_ADDR/mi_ctrl_p, no side effects on a read) is enough to route a transaction through
    that pipe and confirm the whole splitter path -- not just ports 0/1 -- is wired up correctly.
    Uses the raw MIRequestDriver directly (dev.mi[0], the same transport dev.nfb's own DevTree-based
    comp_open()/read32() ultimately calls into -- see IuventusUserCoreNfbDevice's own port comment)
    rather than nfb.comp_open(), since this DevTree has no "netcope,latency_meter" node wired up for
    this component-level harness."""
    got = await dev.mi[0].read32(0x200)
    dut._log.info(f"Data Logger CTRL reg (0x200) read back: {got:#010x}")


async def _case_write_gen_burst_mode(dut, dev, test):
    """(NEW) mfb_generator.vhd's own burst_fsm_pst (BURST_FSM_STATE_T: S_TRIGGER_DETECT=0,
    S_BURST_COUNTDOWN=1) never visits S_BURST_COUNTDOWN anywhere else in this suite. Two things
    must both hold for the FSM to ever leave S_TRIGGER_DETECT (burst_mod_fsm_out_logic's own entry
    condition): CTRL_CHAN_INC's CONFIG[1]/bit9 ("bursting"/burst_mode_en) must be '1' (with it '0'
    the mux `gen_vld <= (others => CTRL_EN) when burst_mode_en = '0' else gen_vld_regions` instead
    selects plain continuous streaming -- see mfb_generator.vhd's own register-map comment), AND
    burst_size > REGIONS (REGIONS=1, DMA_MFB_REGIONS's entity default, unchanged by this suite's
    elaboration -- see user_core_test_arch.vhd's mfb_generator_i instantiation). IuventusTest.
    __init__ sets `self.gen.bursting = True` once, but every dev._reset() between cases (this
    orchestrator's own convention) clears the generator's registers back to their power-on default
    (bursting=False) and NOTHING re-asserts it afterwards -- so every OTHER case in this file that
    calls disp_wr_req (all with burst_size=1) is actually, silently, running in continuous-
    streaming mode (bursting=False), not "burst_size=1, one-shot" mode as their own docstrings
    assumed; that misconception is what a purely burst_size=3 attempt here first ran into (it
    failed: burst_fsm_pst never left S_TRIGGER_DETECT, because bursting read back False). This
    case re-asserts bursting=True explicitly right before dispatching (burst_size=3 > REGIONS),
    and burst_fsm_pst is sampled every DMA_CLK cycle via a white-box peek
    (dut.mfb_generator_i.mfb_generator_i.burst_fsm_pst) to confirm S_BURST_COUNTDOWN is actually
    entered, on top of the existing scoreboard-based frame-content check (mirrors
    _case_one_write_frame's own pattern -- NUM_QUEUES=1 makes the channel-grouping side of
    burst_size unobservable in the predicted QID anyway, see RoundRobinQid.next_qid())."""
    await e(test.set_queue_range)(1)
    await aset(test.gen, "bursting", True)

    seen_countdown = False

    async def _monitor():
        nonlocal seen_countdown
        while True:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            if int(dut.mfb_generator_i.mfb_generator_i.burst_fsm_pst.value) == 1:
                seen_countdown = True

    cocotb.start_soon(_monitor())

    sb = Scoreboard("wr_frame[burst_mode]")
    model = WriteFrameModel(num_queues=NUM_QUEUES)

    def on_frame(trans):
        lba_ptr = trans.meta & ((1 << 64) - 1)
        qid = trans.meta >> 64
        sb.check(ExpectedWrFrame(data=bytes(trans.data), lba_ptr=lba_ptr, qid=qid))
        if sb.checked >= 1:
            dev.dma_model.wr_frame_accept_cb = None

    dev.dma_model.wr_frame_accept_cb = on_frame

    lba_ptr = 0x9000
    lba_num = 0  # 1 sector
    sb.expect(model.next_frame(lba_ptr, (lba_num + 1) * 512))

    await e(test.disp_wr_req)(lba_ptr, lba_num, 3)  # burst_size=3 > REGIONS(1)

    ok = await _wait_until(lambda: sb.checked >= 1, dut, max_cycles=1000)
    assert ok, "timed out waiting for the burst-mode write frame to be accepted"
    sb.assert_empty()

    # A few extra cycles: burst_fsm_pst's own countdown continues region-by-region for a bit past
    # the confirmed frame's own accept.
    for _ in range(20):
        await RisingEdge(dut.DMA_CLK)

    await aset(test.gen, "enabled", False)

    assert seen_countdown, (
        "burst_fsm_pst never visited S_BURST_COUNTDOWN (index 1) with burst_size=3 > REGIONS=1 -- "
        "mfb_generator.vhd's burst_mod_fsm_out_logic entry condition regressed"
    )


async def _case_integrity_checker(dut, dev, test):
    """Drive the IUVENTUS_INTEGRITY_CHECKER end-to-end -- the same MI sequence
    apps/iuventus/sw/integ_run.py uses on real hardware -- against the DMA model's write/read-back
    data-integrity store. Simulating it covers the checker FSM, the integ_en WR/RD-MFB steering
    mux, its address-derived write pattern (ref_beat) and the read-back comparator without a card. With integ_en=1 the checker
    owns NVME_WR_MFB / NVME_RD_REQ / NVME_RD_MFB; the model stores each written sector and returns it
    on the matching read, so a correct checker reports err_cnt == 0."""
    STATES = {0: "IDLE", 1: "WR", 2: "WR_WAIT", 3: "RD_REQ", 4: "RD_DATA", 5: "DONE"}
    dev.dma_model.data_integrity = True
    dev.dma_model._storage.clear()
    try:
        c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")
        base_byte = 8 * 512   # in-range byte-address LBA (sector 8)
        count = 4             # sectors written then read back

        # Re-arm if a previous sweep parked the FSM in DONE (DONE->IDLE needs a pulse before IDLE->WR).
        if (await e(c.read32)(0x40)) & 0x2:
            await e(c.write32)(0x30, 0x1)
            await e(c.write32)(0x30, 0x0)

        await e(c.write32)(0x34, base_byte & 0xffffffff)
        await e(c.write32)(0x38, (base_byte >> 32) & 0xffffffff)
        await e(c.write32)(0x3C, count)
        await e(c.write32)(0x30, 0x2)   # integ_en=1
        await e(c.write32)(0x30, 0x3)   # start pulse (+en)
        await e(c.write32)(0x30, 0x2)   # deassert start (keep en)

        done = False
        for _ in range(400):
            if (await e(c.read32)(0x40)) & 0x2:
                done = True
                break
            for _ in range(20):
                await RisingEdge(dut.DMA_CLK)

        status = await e(c.read32)(0x40)
        state = STATES.get((status >> 4) & 7, (status >> 4) & 7)
        assert done, (f"integrity checker never reached DONE "
                      f"(status=0x{status:08x} state={state} beat={(status >> 8) & 0xff})")
        err = await e(c.read32)(0x44)
        exp = await e(c.read32)(0x50)
        got = await e(c.read32)(0x54)
        assert err == 0, f"integrity check found {err} mismatch(es): first exp=0x{exp:08x} got=0x{got:08x}"

        # OOR ABORT: a sweep past the namespace must ABORT (STS_OP_ERR, DONE), not hang. The
        # checker WRITEs first, so an OOR sweep trips the DMA's write-OOR completion and
        # S_WR_WAIT aborts to DONE, rather than reaching a read that wedges S_RD_DATA.
        dev.dma_model.lba_space_size = 4096   # sectors
        if (await e(c.read32)(0x40)) & 0x2:   # re-arm from the previous DONE
            await e(c.write32)(0x30, 0x1)
            await e(c.write32)(0x30, 0x0)
        oor_base = 8192   # sector 8192 > 4096 -> out of range
        await e(c.write32)(0x34, oor_base & 0xffffffff)
        await e(c.write32)(0x38, (oor_base >> 32) & 0xffffffff)
        await e(c.write32)(0x3C, 4)
        await e(c.write32)(0x30, 0x2)
        await e(c.write32)(0x30, 0x3)
        await e(c.write32)(0x30, 0x2)
        done = False
        for _ in range(200):
            if (await e(c.read32)(0x40)) & 0x2:
                done = True
                break
            for _ in range(20):
                await RisingEdge(dut.DMA_CLK)
        status = await e(c.read32)(0x40)
        state = STATES.get((status >> 4) & 7, (status >> 4) & 7)
        assert done, (f"OOR sweep HUNG (the bug this fix targets): status=0x{status:08x} state={state}")
        assert (status >> 2) & 1 == 1, (f"OOR sweep reached DONE but STS_OP_ERR (bit 2) not set: "
                                        f"status=0x{status:08x}")
    finally:
        dev.dma_model.data_integrity = False
        dev.dma_model.lba_space_size = None



async def _case_latency_qd1(dut, dev, test, mode: str = "rd"):
    """Latency mode must keep exactly ONE command in flight while the queue stays QD64.

    LATENCY_METER pairs starts to completions positionally (no tag), so any concurrency pairs a
    completion with the wrong start. Before the fix NVME_RD_REQ_VLD was gated only on SQ room, so a
    latency run issued back-to-back until the page pool emptied; the run could then never retire its
    programmed operation count, the measurement FSM never left S_COUNT_TESTING_PACKETS and
    tst_finished never asserted -- the host hung forever polling it. This drives a real measurement
    run and requires (a) never more than one outstanding, (b) the gate actually engages, and
    (c) tst_finished asserts. Against the pre-fix RTL (b) never happens and (c) times out."""
    # lat_meas_mode LAST: tst_mode/tst_addressing also write TST_SEQ_RAND_SEL (0x20) and would
    # clear bit 4 again.
    await e(lambda: setattr(test, "tst_mode", mode))()
    await e(lambda: setattr(test, "tst_addressing", "seq"))()
    # set_bit() preserves tst_sel_reg -- a whole-register write clobbers the read-generator enable.
    # Arm the gate and WAIT for it to reach the DUT before dispatching: the MI write is slower than
    # the first frames, so a burst would launch ungated.
    await e(lambda: setattr(test, "lat_meas_mode", True))()
    for _ in range(400):
        await RisingEdge(dut.DMA_CLK)
    assert int(dut.lat_meas_mode.value) == 1, (
        f"lat_meas_mode did not reach the DUT even on a direct write32 "
        f"(tst_sel_reg={int(dut.tst_sel_reg.value)}, contig={int(dut.contig_test.value)})"
    )
    # Bypass the >=1000 guard on IuventusTest.tst_iterations: that minimum exists for statistical
    # confidence on hardware, not for this structural check, and 1000 QD1 round trips does not fit
    # the sim budget.
    if mode == "wr":
        await e(lambda: setattr(test.gen, "bursting", True))()
        await e(lambda: test.disp_wr_req(0, 3, 8))()
    await e(lambda: test._comp.write32(0x1C, 8))()  # IuventusTestRegMap.TST_ITERATIONS

    async def _lat_monitor():
        """Runs for the whole case, not just the measurement loop -- the previous version stopped
        at tst_finished and so missed everything after it, which is where the violation was."""
        while True:
            await RisingEdge(dut.DMA_CLK)
            it = int(dut.lat_meas_fifo_items.value)
            if int(dut.lat_start_event_s.value) == 1 or int(dut.core_op_stat_vld.value) == 1 or it > 1:
                dut._log.debug(
                    f"LATMON items={it} outst={int(dut.lat_outstanding_r.value)} "
                    f"start={int(dut.lat_start_event_s.value)} opstat={int(dut.core_op_stat_vld.value)} "
                    f"wr_sof={int(dut.NVME_WR_MFB_SOF.value)} wr_eof={int(dut.NVME_WR_MFB_EOF.value)} "
                    f"wr_src={int(dut.NVME_WR_MFB_SRC_RDY.value)} inframe={int(dut.lat_wr_in_frame_r.value)} "
                    f"wrgate={int(dut.lat_wr_issue_ok.value)} newfr={int(dut.lat_wr_new_frame_s.value)} "
                    f"rdvld={int(dut.NVME_RD_REQ_VLD.value)} mode={int(dut.lat_meas_mode.value)}")
    mon = cocotb.start_soon(_lat_monitor())

    # Read issue is gated by lat_meas_issue_ok, write issue at the frame boundary by
    # lat_wr_issue_ok -- assert on whichever this mode actually drives.
    gate = dut.lat_meas_issue_ok if mode == "rd" else dut.lat_wr_issue_ok
    saw_gated = False
    finished = False
    trace = []
    for _ in range(60000):
        await RisingEdge(dut.DMA_CLK)
        items = int(dut.lat_meas_fifo_items.value)
        # Rolling trace so a violation reports HOW it got there instead of just that it did.
        snap = (
            f"items={items} outst={int(dut.lat_outstanding_r.value)} "
            f"start={int(dut.lat_start_event_s.value)} opstat={int(dut.core_op_stat_vld.value)} "
            f"wr_sof={int(dut.NVME_WR_MFB_SOF.value)} wr_eof={int(dut.NVME_WR_MFB_EOF.value)} "
            f"wr_src={int(dut.NVME_WR_MFB_SRC_RDY.value)} wr_dst={int(dut.NVME_WR_MFB_DST_RDY.value)} "
            f"inframe={int(dut.lat_wr_in_frame_r.value)} wrgate={int(dut.lat_wr_issue_ok.value)} "
            f"rdvld={int(dut.NVME_RD_REQ_VLD.value)} rdrdy={int(dut.NVME_RD_REQ_RDY.value)}"
        )
        trace.append(snap)
        if len(trace) > 14:
            trace.pop(0)
        if items > 1:
            dut._log.error("LAT QD1 VIOLATION, last cycles:\n  " + "\n  ".join(trace))
        assert items <= 1, (
            f"{items} operations outstanding during a latency measurement -- the meter pairs "
            f"positionally, so this reports a wrong latency"
        )
        if int(gate.value) == 0:
            saw_gated = True
        # The write gate must never bite mid-frame -- that would stall a partial frame.
        if mode == "wr" and int(dut.lat_wr_in_frame_r.value) == 1:
            assert int(dut.lat_wr_issue_ok.value) == 1, \
                "write gate withheld SRC_RDY mid-frame"
        if saw_gated and int(dut.tst_finished.value) == 1:
            finished = True
            break

    assert saw_gated, (
        "the QD1 gate never engaged -- the generator was never actually throttled, so this run "
        "did not exercise the fix"
    )
    assert finished, (
        "tst_finished never asserted after the measurement run -- this is the hang: the FSM cannot "
        "leave S_COUNT_TESTING_PACKETS and the host polls forever"
    )

    await e(lambda: setattr(test, "lat_meas_mode", False))()
    # Same propagation budget as arming it: an MI write needs far more than a few DMA_CLK edges
    # to reach the register through the nfb bridge.
    for _ in range(400):
        await RisingEdge(dut.DMA_CLK)
    assert int(dut.lat_meas_mode.value) == 0, "lat_meas_mode did not clear"
    assert int(dut.lat_meas_issue_ok.value) == 1 and int(dut.lat_wr_issue_ok.value) == 1, (
        "a serialisation gate is still engaged with latency mode off -- it would throttle "
        "throughput runs"
    )


@cocotb.test(timeout_time=2000, timeout_unit='us')
async def test_user_core_reference_model(dut):
    """Stage 2+3: reference-model-predicted expected output vs a scoreboard comparing against the
    real DUT, driven through a simplified DMA Iuventus environment (SimplifiedDmaModel). Runs the
    Stage 1 MI smoke checks, Stage 2's directed property-poke cases (one read, one write, and two
    burst runs -- lba_num=0 and lba_num=3, cross-checking the seq-address step size), then Stage
    3's cases driving apps/iuventus/sw/iuventus_rw_test.py's own exported CLI-path functions
    (run_read_dispatch/run_write_dispatch/_throughput_point_start/_throughput_point_stop) plus
    directed corner cases (rd_burst>1, random addressing, write generator enable/disable
    mid-stream, and backpressure/no-wedge) -- all inside ONE cocotb test/one live simulation, since
    USR_CLK/DMA_CLK/MI_CLK are started exactly once per simulation run (cocotb runs every
    @cocotb.test in the same simulation session; a second _init_clks() call from a second test
    would start a second, colliding clock driver on the same signals)."""
    dev = IuventusUserCoreNfbDevice(dut)
    await dev.init()
    # IuventusTest.__init__ (via self.gen = MfbGenerator(...)) already performs blocking nfb
    # calls itself (burst_size/bursting property setters), so construction must go through the
    # bridge too, exactly like every other IuventusTest access below.
    test = await e(lambda: IuventusTest(dev=dev.nfb, index=0))()

    await _check_mi_access(dev)

    await dev._reset()
    dev.dma_model.reset()
    await _case_one_read_request(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_command_identity(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_one_write_frame(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_small_read_burst(dut, dev, test, lba_num=0)

    await dev._reset()
    dev.dma_model.reset()
    await _case_small_read_burst(dut, dev, test, lba_num=3)

    await dev._reset()
    dev.dma_model.reset()
    await _case_latency_qd1(dut, dev, test, mode="rd")

    await dev._reset()
    dev.dma_model.reset()
    await _case_latency_qd1(dut, dev, test, mode="wr")

    # --- Stage 3: real iuventus_rw_test.py CLI-path functions + directed corner cases ---------
    await dev._reset()
    dev.dma_model.reset()
    await _case_cli_read_dispatch_sizes(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_cli_write_dispatch(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_cli_throughput_point(dut, dev, test, n_queues=NUM_QUEUES)

    await dev._reset()
    dev.dma_model.reset()
    await _case_throughput_multi_point(dut, dev, test, n_queues=NUM_QUEUES)

    await dev._reset()
    dev.dma_model.reset()
    await _case_rd_burst_and_rand(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_write_enable_disable_midstream(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_backpressure_no_wedge(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_integrity_checker(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_mi_async_reset_asymmetry(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_data_logger_mi_smoke(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_write_gen_burst_mode(dut, dev, test)
