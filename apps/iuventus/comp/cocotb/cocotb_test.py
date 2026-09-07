# cocotb_test.py: Stage-1 smoke test for a component-level USER_CORE (TEST architecture) cocotb
# testbench, served as a real nfb device via cocotbext.nfb.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import functools
import inspect
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ReadOnly

# Reuses apps/iuventus/sw/iuventus_rw_test.py's MI register map (IuventusTestRegMap,
# rd_req_*/tst_*/gen.* properties) as a library import instead of re-deriving the pokes.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sw"))
from iuventus_rw_test import (  # noqa: E402
    IuventusTest, run_read_dispatch, run_write_dispatch, _throughput_point_start, _throughput_point_stop,
)

# cocotb 2.0 dropped cocotb.external/function from its top-level exports (renamed
# _bridge.bridge/resume); cocotbext.nfb still imports those names. resume() can't await a
# bare generator (TypeError), which silently killed the MI read servicer.
import cocotb._bridge as _cocotb_bridge  # noqa: E402


def _generator_compat_resume(func):
    if not inspect.isgeneratorfunction(func):
        return _cocotb_bridge.resume(func)

    @functools.wraps(func)
    async def _driven(*args, **kwargs):
        gen = func(*args, **kwargs)
        sent = None
        while True:
            try:
                yielded = gen.send(sent)
            except StopIteration as stop:
                return stop.value
            sent = await yielded

    return _cocotb_bridge.resume(_driven)


if not hasattr(cocotb, "external"):
    cocotb.external = _cocotb_bridge.bridge
    cocotb.function = _generator_compat_resume

import cocotbext.nfb  # noqa: E402 (must follow the compat shim above)
from cocotbext.ofm.mi.drivers import MIRequestDriver  # noqa: E402

from dma_iuventus_model import SimplifiedDmaModel  # noqa: E402
from user_core_model import ReadReqModel, WriteFrameModel, ExpectedReadReq, ExpectedWrFrame  # noqa: E402
from scoreboard import Scoreboard  # noqa: E402

# Shortcut, matching apps/minimal/tests/cocotb/cocotb_test.py's own convention.
e = cocotb.external

# NUM_QUEUES must match the -g NUM_QUEUES=... elaboration generic (Makefile's `test` target)
# -- read once at import so the reference model predicts the matching QID round-robin pattern.
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

        # Stage 2 actively drives/monitors NVME_* (drives NVME_RD_REQ_RDY/NVME_RD_MFB/
        # NVME_OP_STAT, monitors NVME_WR_MFB) instead of Stage 1's constant tie-offs; it ties
        # its own initial values.
        self.dma_model = SimplifiedDmaModel(self._dut, self._dut.DMA_CLK)

        self._dut.PCIE_LINK_UP.value = 1
        self._dut.FPGA_ID.value = 0
        self._dut.FPGA_ID_VLD.value = 0

        # USER_CORE's own MI slave port: MI_ASYNC bridges it (master side, MI_CLK/MI_RST) to
        # the DMA_CLK domain the CSR logic runs on (see mi_async_i), so this driver only ever
        # needs MI_CLK.
        self.mi = [MIRequestDriver(self._dut, "MI", self._dut.MI_CLK)]

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


# Small async helpers bridging synchronous property access into cocotb: each property makes a
# blocking nfb call needing a bridge thread, so a bare `test.tst_mode = "rd"` fails. Methods
# work via `e(...)`; gets/sets need this.
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
    explicitly cross-checks the seq-address step size (user_core_test_arch.vhd's seq_addr_cntr_p
    now advances by lba_num+1 LBAs per completion, fixed from an earlier lba_num-only step that
    left lba_num=0 bursts reading the same address forever -- see user_core_model.py's
    ReadReqModel.on_completion() docstring). Called twice by the top-level test, once with
    lba_num=0 (checks the previously-frozen case now advances by exactly 1) and once with
    lba_num=3 (checks a >1 step).

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
    await aset(test, "evcr_interval_cycles", 200)

    accepted_since_reached = 0
    seen_addrs = []  # first few accepted addresses, for the explicit step-size assertion below

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        nonlocal accepted_since_reached
        # Compute the expectation lazily at accept time, mirroring the RTL's registered
        # counters. Precomputing up front would freeze every entry at the initial values,
        # since only on_completion() advances that state.
        sb.expect(model.next_burst_request())
        sb.check(ExpectedReadReq(lba_ptr=got_lba_ptr, lba_num=got_lba_num, qid=got_qid))
        model.on_completion()
        accepted_since_reached += 1
        if len(seen_addrs) < 5:
            seen_addrs.append(got_lba_ptr)

    dev.dma_model.rd_req_accept_cb = on_accept

    model.start_burst(lba_ptr, lba_num, addressing="seq", contig=False)

    await aset(test, "rd_req_lba_ptr", lba_ptr)
    await aset(test, "rd_req_lba_num", lba_num)
    await aset(test, "tst_addressing", "seq")
    await aset(test, "tst_mode", "rd")
    await aset(test, "contig_test", False)
    await aset(test, "tst_iterations", iterations)  # fires tst_trigg -- must be written LAST

    # EVCR cross-check: wait for the first interval (iops_cntr_i.int_reached), confirm MI
    # TOTAL_EVENTS matches this test's tally of accepted reads since the burst started, read
    # back before the next interval completes.
    internal = dut.iops_cntr_i
    prev_int_reached = False
    first_interval_events = None
    for _ in range(1000):
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        reached = bool(internal.int_reached.value)
        if reached and not prev_int_reached:
            first_interval_events = accepted_since_reached
            accepted_since_reached = 0
            break
        prev_int_reached = reached

    assert first_interval_events is not None, (
        "no EVCR interval (evcr_interval_cycles=200) completed within 1000 DMA_CLK cycles of the "
        "burst starting -- can't cross-check TOTAL_EVENTS"
    )
    assert first_interval_events > 0, "no read request was accepted during the first EVCR interval"

    got_events = await aget(test, "evcr_total_events")
    got_cycles = await aget(test, "evcr_total_cycles")
    assert got_events == first_interval_events, (
        f"EVCR TOTAL_EVENTS ({got_events}) does not match this test's own tally of read requests "
        f"accepted during the first completed interval ({first_interval_events})"
    )
    assert got_cycles > 0, "EVCR TOTAL_CYCLES read back as 0 after a completed interval"

    ok = await _wait_until(lambda: sb.checked >= iterations, dut, max_cycles=iterations * 50)
    assert ok, f"timed out: only {sb.checked}/{iterations} burst read requests were accepted (short stream)"
    sb.assert_empty()

    # Explicit step-size cross-check (beyond the scoreboard's bit-exact match): confirm the DUT's
    # observed address stream advances by exactly lba_num+1 every step, as concrete evidence
    # rather than an indirect pass/fail.
    assert len(seen_addrs) >= 2, "not enough accepted requests observed to check the address step"
    for prev_addr, next_addr in zip(seen_addrs, seen_addrs[1:]):
        step = next_addr - prev_addr
        assert step == lba_num + 1, (
            f"seq address step was {step}, expected lba_num+1={lba_num + 1} "
            f"(addresses observed: {seen_addrs!r})"
        )

    model.stop_burst()
    dev.dma_model.rd_req_accept_cb = None


# Stage 3 drives iuventus_rw_test.py's real CLI functions (run_read_dispatch/
# run_write_dispatch/_throughput_point_start/_stop): the only user-facing entry point, so
# exercising it directly is the primary surface here.
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
    await aset(test, "evcr_interval_cycles", 200)

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
    cycles_run = 0
    # Stop as soon as the second interval boundary is captured, so evcr_total_events is read
    # before a third interval completes, then keep running settle_cycles to accumulate more
    # scoreboard-checked traffic.
    for _ in range(settle_cycles):
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        cycles_run += 1
        reached = bool(internal.int_reached.value)
        if reached and not prev_int_reached:
            intervals_seen += 1
            if intervals_seen == 2:
                clean_interval_events = accepted_since_reached
            accepted_since_reached = 0
            if intervals_seen >= 2:
                break
        prev_int_reached = reached

    assert clean_interval_events is not None, (
        f"fewer than 2 EVCR intervals completed within {settle_cycles} DMA_CLK cycles of the "
        "throughput point starting -- can't cross-check TOTAL_EVENTS/iops() against a clean interval"
    )
    assert clean_interval_events > 0, "no read request was accepted during the second (clean) EVCR interval"

    got_events = await aget(test, "evcr_total_events")
    assert got_events == clean_interval_events, (
        f"EVCR TOTAL_EVENTS ({got_events}) does not match this test's own tally of read requests "
        f"accepted during the second (clean) completed interval ({clean_interval_events})"
    )
    iops = await e(test.iops)()
    assert iops > 0, "IuventusTest.iops() reported 0 during an active throughput point"

    # Keep the read stream running for the rest of the settle budget, purely so the scoreboard
    # accumulates a meaningful amount of round-robin traffic (order/QID/size) beyond the two short
    # intervals used for the EVCR cross-check above.
    for _ in range(max(settle_cycles - cycles_run, 0)):
        await RisingEdge(dut.DMA_CLK)

    assert sb.checked > 0, "no read traffic observed during the throughput point's settle window"
    sb.assert_empty()

    # Detach the scoreboard before stopping: the stop transition can retire one in-flight request
    # against a torn address -- a separately-reported RTL race, not what this scoreboard validates.
    dev.dma_model.rd_req_accept_cb = None

    await e(_throughput_point_stop)(test, "rd", sleep_fn=lambda seconds: None)


async def _case_rd_burst_and_rand(dut, dev, test):
    """Stage 3.4: two directed corner cases for the read burst path, folded into one (both need
    NUM_QUEUES>1 to be meaningful and are skipped otherwise):
      - rd_burst > 1: RD_BURST=2 means the QID round-robin advances every 2 accepted requests
        instead of every 1 (user_core_test_arch.vhd's rd_qid_rr_p / RoundRobinQid.next_qid()).
      - random addressing: LBA_PTR follows the LFSR (lfsr_rand_addr_gen_i / lfsr21_step) instead
        of the sequential counter.
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

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        sb.expect(model.next_burst_request())
        sb.check(ExpectedReadReq(lba_ptr=got_lba_ptr, lba_num=got_lba_num, qid=got_qid))
        model.on_completion()

    dev.dma_model.rd_req_accept_cb = on_accept

    model.start_burst(lba_ptr, lba_num, addressing="rand", contig=False)

    await aset(test, "rd_req_lba_ptr", lba_ptr)
    await aset(test, "rd_req_lba_num", lba_num)
    await aset(test, "tst_addressing", "rand")
    await aset(test, "tst_mode", "rd")
    await aset(test, "contig_test", False)
    await aset(test, "tst_iterations", iterations)  # fires tst_trigg -- must be written LAST

    ok = await _wait_until(lambda: sb.checked >= iterations, dut, max_cycles=iterations * 50)
    assert ok, f"timed out: only {sb.checked}/{iterations} rd_burst=2/rand requests were accepted"
    sb.assert_empty()

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
        # Lazy expectation, like _case_small_read_burst's on_accept: the generator is
        # free-running, so the exact frame COUNT accepted before "disable" takes effect isn't
        # known in advance -- compute next_frame() as each frame arrives.
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
        component-level sim analog of the real hardware's read-path stall (an SSD backend that
        goes idle/unresponsive for a window): here it is USER_CORE's OWN generator being checked
        for correct recovery, not DMA_IUVENTUS's/the SSD's doorbell logic (out of scope for this
        component-level harness).
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


async def _case_integrity_checker(dut, dev, test):
    """(NEW) Drive the IUVENTUS_INTEGRITY_CHECKER end-to-end -- the same MI sequence
    apps/iuventus/sw/integ_run.py uses on real hardware -- against the DMA model's write/read-back
    data-integrity store. This is the FIRST *simulation* of the integrity checker (previously
    HW-only): it exercises the checker FSM, the integ_en WR/RD-MFB steering mux, its address-derived
    write pattern (ref_beat) and the read-back comparator, all in sim. With integ_en=1 the checker
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
        # checker WRITEs first, so an OOR sweep trips op_ctrl's write-OOR completion and
        # S_WR_WAIT aborts to DONE instead of wedging S_RD_DATA.
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
    await _case_one_write_frame(dut, dev, test)

    await dev._reset()
    dev.dma_model.reset()
    await _case_small_read_burst(dut, dev, test, lba_num=0)

    await dev._reset()
    dev.dma_model.reset()
    await _case_small_read_burst(dut, dev, test, lba_num=3)

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
