# cocotb_test.py: reference-model bench for a standalone USER_CORE (TEST architecture), served
# as a real nfb device via cocotbext.nfb.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import functools
import inspect
import math
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ReadOnly, ClockCycles

# Imported as a library (its `__main__` CLI never runs): iuventus_rw_test.py already implements the
# MI register map used on real hardware.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sw"))
# SimplifiedDmaModel and the scoreboard are shared with the GROUPBY architecture's bench.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cocotb_common"))
import iuventus_rw_test  # noqa: E402
from iuventus_rw_test import (  # noqa: E402
    IuventusTest, run_read_dispatch, run_write_dispatch, _throughput_point_start, _throughput_point_stop,
)

# This DevTree has no DMA Iuventus node, so the card-side "fzc is running" guard cannot pass; it
# checks the card's setup, not the core.
iuventus_rw_test.assert_fzc_running = lambda _test: None

import nfb_compat  # noqa: F401 (patches cocotb before cocotbext.nfb is imported)

import cocotbext.nfb  # noqa: E402 (must follow the compat shim above)
from cocotbext.ofm.mi.drivers import MIRequestDriver  # noqa: E402
from cocotbext.ofm.mfb.properties import attach_mfb_properties  # noqa: E402

from endpoint_view import attach_endpoint_mfb_properties  # noqa: E402

from dma_iuventus_model import QID_W, SQE_LBA_PTR_W, SimplifiedDmaModel  # noqa: E402
from user_core_model import ReadReqModel, WriteFrameModel, ExpectedReadReq, ExpectedWrFrame  # noqa: E402
from user_core_model import (  # noqa: E402
    ADDR_CNTR_WIDTH, LBA_ALIGN, MAX_REQ_LBAS, TST_LBA_COUNT, SeqAddrModel, RandDrawModel,
)
from scoreboard import Scoreboard  # noqa: E402

# OP_STAT_CODE encoding on the DMA interface: 00 SUCCESS, 01 FAILURE, 10 LBA out of range.
OP_STAT_CODE_SUCCESS = 0

# Shortcut, matching apps/minimal/tests/cocotb/cocotb_test.py's own convention.
e = cocotb.external

# EVCR interval used by every cross-check below; small vs. the ~2^28-cycle production default so an
# interval completes inside a short directed burst.
EVCR_INTERVAL_CYCLES = 200

# NUM_QUEUES must match the -g NUM_QUEUES=... the design was elaborated with (the Makefile passes it
# both ways); the reference model predicts the QID round-robin from it.
NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))


class IuventusUserCoreNfbDevice(cocotbext.nfb.NfbDevice):
    """cocotbext.nfb device for a standalone USER_CORE: three clocks and one MI slave. The DevTree
    has no DMA controller nodes, so the base class's QueueManager comes out empty and _init_pcie()
    stays a no-op.
    """

    async def _init_clks(self):
        await cocotb.start(Clock(self._dut.USR_CLK, 5, 'ns').start())
        await cocotb.start(Clock(self._dut.DMA_CLK, 4, 'ns').start())
        await cocotb.start(Clock(self._dut.MI_CLK, 10, 'ns').start())

        # The simplified DMA Iuventus environment drives NVME_RD_REQ_RDY/NVME_RD_MFB/NVME_OP_STAT
        # and monitors NVME_WR_MFB; it ties its own initial port values.
        self.dma_model = SimplifiedDmaModel(self._dut, self._dut.DMA_CLK)

        self._dut.PCIE_LINK_UP.value = 1
        self._dut.FPGA_ID.value = 0
        self._dut.FPGA_ID_VLD.value = 0

        # USER_CORE's MI slave port; MI_ASYNC (mi_async_i) bridges it to the DMA_CLK domain, so this
        # driver only needs MI_CLK.
        self.mi = [MIRequestDriver(self._dut, "MI", self._dut.MI_CLK)]

        # Conformance watchdog (sampling only) on the DMA_CLK MFBs: NVME_WR_MFB, and NVME_RD_MFB once
        # per endpoint. Discovery cannot index the per-endpoint arrays, so it skips them.
        self.mfb_props = attach_mfb_properties(self._dut, self._dut.DMA_CLK, reset=self._dut.DMA_RST,
                                               exclude=("CORE_RD_MFB", "NVME_RD_MFB"))
        self.mfb_props.update(attach_endpoint_mfb_properties(self._dut, self._dut.DMA_CLK,
                                                             reset=self._dut.DMA_RST))


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
    """Unmapped 0x7C must return read_from_regs_p's 0xCAFEBABE sentinel through comp_open's DevTree
    lookup, MI_ASYNC and the splitter, proving the read path end to end; a write+readback of
    EVCR_INTERVAL_CYCLES (0x24) proves the write path.
    """
    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")

    sentinel = await e(c.read32)(0x7C)
    assert sentinel == 0xCAFEBABE, f"expected 0xCAFEBABE from unmapped reg 0x7C, got {sentinel:#010x}"

    await e(c.write32)(0x24, 0x12345678)
    readback = await e(c.read32)(0x24)
    assert readback == 0x12345678, f"EVCR_INTERVAL_CYCLES readback mismatch: wrote 0x12345678, got {readback:#010x}"


# IuventusTest properties do blocking nfb C-extension calls that must run in a bridge thread, so
# `test.tst_mode = "rd"` from the main coroutine fails; these helpers wrap them in `e(...)`.
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
    """_wait_until for a register-backed property only the bridge (aget) can read: re-reads it every
    `poll_period_cycles` DMA_CLK cycles, up to `max_polls` times."""
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
    """USER_CORE latches the command identity the DMA publishes on RD_REQ_CID, RD_MFB_META and
    OP_STAT at 0x60/0x64/0x68; compared with what the model published, as a miswired or
    never-written register could still read plausibly.
    """
    await e(test.set_queue_range)(1)
    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")

    # Latch the identity at accept: the model assigns it before invoking this callback and a later
    # read would see what a subsequent request advanced it to.
    seen = {}

    def on_accept(lba_ptr_got, lba_num_got, qid_got):
        seen.setdefault("cid", dev.dma_model._inflight_cid)
        seen.setdefault("qid", dev.dma_model._inflight_qid)

    dev.dma_model.rd_req_accept_cb = on_accept

    lba_ptr = 0x2000
    lba_num = 1  # 2 sectors
    await e(test.disp_rd_req)(lba_ptr, lba_num)

    # Two waits: "_rd_busy is False" is also true before the request is accepted, so waiting only on
    # it reads registers still holding the previous case's identity.
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
    """One disp_wr_req frame of one sector: the first NVME_WR_MFB frame matches the model's data and
    META bit-exactly. burst_size only groups channels and the generator free-runs once enabled, so
    the callback detaches after the first frame.
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
    """A 1000-iteration sequential burst over every queue: the scoreboard checks order, QID and LBA,
    TOTAL_EVENTS matches the first EVCR interval's completions, and each queue's address steps by
    lba_num+1.
    """
    n_queues = NUM_QUEUES
    await e(test.set_queue_range)(n_queues)

    sb = Scoreboard(f"rd_req[burst,lba_num={lba_num}]")
    model = ReadReqModel(num_queues=n_queues)
    model.configure_range(0, n_queues - 1, 1)  # rd_burst=1: advance queue every request

    lba_ptr = 0x2000
    iterations = 1000  # IuventusTest.tst_iterations enforces >= 1000

    # Small vs. the ~2^28-cycle production default, so an interval completes early in this burst and
    # TOTAL_EVENTS can be checked against this test's own tally.
    await aset(test, "evcr_interval_cycles", EVCR_INTERVAL_CYCLES)

    accepted_since_reached = 0
    # First few accepted addresses per queue, for the step-size assertion below; the counter is per
    # queue, so consecutive accepts of a round-robin stream come from different queues.
    seen_addrs = {q: [] for q in range(n_queues)}

    def on_accept(got_lba_ptr, got_lba_num, got_qid):
        nonlocal accepted_since_reached
        # Expectation is computed at accept time: next_burst_request() reads the model's current
        # per-queue seq_addr/QID and applies this accept's advance, so precomputing would freeze
        # every entry.
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

    # Cross-check TOTAL_EVENTS against the first interval's completion tally, read back before the
    # next interval completes; tallied architecture-side, which leads the pins by the pipeline
    # depth.
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

    # Step-size check beyond the scoreboard's bit-exact match: within one queue the address stream
    # must advance by lba_num+1 every step.
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


async def _case_cli_read_dispatch_sizes(dut, dev, test):
    """run_read_dispatch ('-r') at both size extremes: lba_num=0 (1 LBA) and lba_num=255, the
    largest the 8-bit NVME_RD_REQ_LBA_NUM holds."""
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
    """run_write_dispatch ('-w'), one sector: the function the CLI's '-w' handler calls produces a
    frame matching the model."""
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
    """One '-t' read point through _throughput_point_start/_stop: the scoreboard checks the
    round-robin stream, TOTAL_EVENTS/iops() a fully observed interval. Settling waits DMA_CLK
    cycles, as time.sleep() in a bridged thread freezes the simulation.
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

    # _throughput_point_start's read-mode branch leaves rd_req_lba_ptr untouched, so the burst
    # continues from the configured LBA_PTR (0 after reset), as run_throughput() does.
    lba_ptr = await aget(test, "rd_req_lba_ptr")
    model.start_burst(lba_ptr, size, addressing=addressing, contig=True)

    await e(_throughput_point_start)(test, "rd", addressing, size)

    internal = dut.iops_cntr_i
    prev_int_reached = False
    intervals_seen = 0
    clean_interval_events = None
    completions_since_reached = 0
    cycles_run = 0
    # Stop at the second interval boundary so evcr_total_events reads back before a third interval
    # completes; the rest of the settle budget runs afterwards.
    for _ in range(settle_cycles):
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        cycles_run += 1
        # Tally completions, not accepts (skewed by in-flight requests). TOTAL_EVENTS latches
        # through the previous cycle, so a completion coincident with int_reached belongs to the
        # next interval.
        reached = bool(internal.int_reached.value)
        pulse = (bool(dut.core_op_stat_vld.value)
                 and int(dut.core_op_stat_code.value) == OP_STAT_CODE_SUCCESS)
        if reached and not prev_int_reached:
            intervals_seen += 1
            # Take the first fully observed interval with a completion: interval 1 starts mid-point,
            # and a large transfer can span several empty intervals (0 == 0 would pass trivially).
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

    # Run out the settle budget so the scoreboard accumulates round-robin traffic (order/QID/size)
    # beyond the two short intervals of the EVCR cross-check.
    for _ in range(max(settle_cycles - cycles_run, 0)):
        await RisingEdge(dut.DMA_CLK)

    assert sb.checked > 0, "no read traffic observed during the throughput point's settle window"
    sb.assert_empty()

    # Detach the scoreboard before stopping: the stop transition can retire one in-flight request
    # against a torn address (a separate RTL race this scoreboard does not validate).
    dev.dma_model.rd_req_accept_cb = None

    await e(_throughput_point_stop)(test, "rd", sleep_fn=lambda seconds: None)


async def _case_throughput_multi_point(dut, dev, test, n_queues, n_points=6):
    """Consecutive '-t' points: start, settle, stop, then the next start. _throughput_point_stop
    does not wait for in-flight reads to retire, so this checks the read path goes quiet between
    points, which a sweep depends on."""
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


# Engine-side requests per queue: below REQ_FIFO_ITEMS (16, IF_PIPE_REQ_ITEMS) so credits do not
# saturate mid-window, above the DMA round trip so the window scores more than the LFSR seed.
ENGINE_SCORED_REQS_PER_QUEUE = 12


async def _case_rd_burst_and_rand(dut, dev, test):
    """RD_BURST=2 must step the QID round-robin every 2 accepts and random addressing must take
    LFSR draws; scored at the engine boundary, as user_core_if_pipe's per-queue FIFOs drain in
    their own rotation and erase RD_BURST at the pins."""
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

    scored_lbas = []

    async def _engine_monitor():
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
                scored_lbas.append(_lvl(dut.core_rd_req_lba_ptr))

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

    # Every accept takes its own draw: accepts sharing one would pass the scoreboard if the model
    # shared it too.
    assert len(set(scored_lbas)) == len(scored_lbas), (
        f"accepted random reads repeated an LBA: {len(scored_lbas) - len(set(scored_lbas))} "
        f"repeats in {len(scored_lbas)}")

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


async def _case_rand_draw_per_accept(dut, dev, test, cycles=6000):
    """Random reads and write frames together: each accept, even a same-cycle read and write, takes
    its own draw and the stream steps only on accepts; addresses and the LFSR state are scored
    against RandDrawModel at the engine boundary."""
    await e(test.set_queue_range)(NUM_QUEUES)
    model = RandDrawModel(regions=1)
    stats = {"rd": 0, "wr": 0, "both": 0, "cycles_active": 0}
    errors = []
    running = True

    def _lvl(sig):
        try:
            return int(sig.value)
        except ValueError:
            return 0

    async def _monitor():
        while running:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            if _lvl(dut.lfsr_r) != model.state:
                errors.append(f"LFSR state {_lvl(dut.lfsr_r):#x}, model {model.state:#x}")
                return
            active = _lvl(dut.seq_en) == 1
            rand = _lvl(dut.tst_sel_reg) & 1
            rd = _lvl(dut.rd_req_accepted_s) == 1
            wr = (_lvl(dut.gen_nvme_wr_accept) & 1) == 1
            rd_lba, (wr_lba,) = model.cycle(read=rd, writes=(wr,), active=active)
            if not (active and rand):
                continue
            stats["cycles_active"] += 1
            if rd:
                stats["rd"] += 1
                got = _lvl(dut.core_rd_req_lba_ptr)
                if got != rd_lba:
                    errors.append(f"read took {got:#x}, model draw {rd_lba:#x}")
            if wr:
                stats["wr"] += 1
                got = _lvl(dut.gen_wr_meta_full) & ((1 << SQE_LBA_PTR_W) - 1)
                if got != wr_lba:
                    errors.append(f"write frame took {got:#x}, model draw {wr_lba:#x}")
            if rd and wr:
                stats["both"] += 1
                if rd_lba == wr_lba:
                    errors.append(f"a same-cycle read and write frame shared {rd_lba:#x}")

    mon = cocotb.start_soon(_monitor())
    await aset(test, "tst_addressing", "rand")
    await aset(test, "tst_mode", "rd")
    await aset(test, "rd_req_lba_num", 0)
    await aset(test.gen, "bursting", False)
    await aset(test.gen, "burst_size", 1)
    await aset(test, "contig_test", True)
    # One-beat frames give a write accept almost every cycle, so read accepts share it, and flood
    # the model's OP_STAT (two cycles a completion); a three-beat round runs first to supply reads.
    for frame_len in (192, 64):
        await aset(test.gen, "frame_length", frame_len)
        await aset(test.gen, "enabled", True)
        await ClockCycles(dut.DMA_CLK, cycles // 2)
        await aset(test.gen, "enabled", False)
    await aset(test, "contig_test", False)
    await aset(test.gen, "enabled", False)
    await ClockCycles(dut.DMA_CLK, 200)
    running = False
    await mon
    await RisingEdge(dut.DMA_CLK)

    assert not errors, f"{len(errors)} random-draw errors, first: {errors[:3]}"
    cocotb.log.info(f"random draws scored: {stats}")
    assert stats["rd"] >= 20 and stats["wr"] >= 20, f"too little random traffic scored: {stats}"
    assert stats["both"] >= 5, f"too few cycles accepted a read and a write frame together: {stats}"


# The card's sweep order: all random sizes, then sequential; the 1-, 2- and 4-LBA random points
# leave each queue's counter off a drive unit for the next sequential point.
ALIGN_SWEEP_CAMPAIGN = ([("rd", "rand", s) for s in (0, 1, 3, 7, 15, 31, 63, 127, 255)]
                        + [("rd", "seq", 7), ("rd", "seq", 255)])
# A sequential stride that is not a whole unit, direct random-to-sequential transitions, and writes
# starting on a residue the reads left.
ALIGN_SWEEP_MIXED = [("rd", "seq", 2), ("rd", "seq", 7), ("rd", "rand", 0), ("rd", "seq", 7),
                     ("rd", "rand", 1), ("wr", "seq", 7), ("wr", "rand", 7), ("rd", "rand", 0),
                     ("wr", "seq", 15)]
# Counters placed near the namespace end: rounding TST_LBA_COUNT-3 up lands on the end itself and
# folds to 0, and the later sequential points run through the fold.
ALIGN_SWEEP_FOLD = [(TST_LBA_COUNT - 3, [("rd", "seq", 7)]),
                    (TST_LBA_COUNT - 44, [("rd", "rand", 0), ("rd", "seq", 7)]),
                    (TST_LBA_COUNT - 40, [("rd", "seq", 7)])]


async def _case_lba_alignment_sweep(dut, dev, test, n_queues):
    """Test addresses start on a 4 KiB drive unit whenever the request size is whole units, sequential
    streams stay contiguous per queue across points, and random ones leave room for the largest request."""
    await e(test.set_queue_range)(n_queues)
    model = SeqAddrModel(NUM_QUEUES)
    lba_mask = (1 << ADDR_CNTR_WIDTH) - 1
    errors = []
    stats = {"loads": 0, "starts": 0, "points": 0}
    point = {"name": "-", "size": 0, "scored": {}}
    running = True

    def _lvl(sig):
        """int() of a signal, treating an X/U bit as 0 (reset leaves some briefly undefined)."""
        try:
            return int(sig.value)
        except ValueError:
            return 0

    def _seq_idx(qid):
        return qid if qid < NUM_QUEUES else 0

    def _score(kind, q, lba, n_lbas, rand):
        where = f"{kind} q{q} lba={lba:#x} lbas={n_lbas} in point {point['name']}"
        if rand:
            if lba % LBA_ALIGN or lba + MAX_REQ_LBAS > TST_LBA_COUNT:
                errors.append(("random", f"{where}: off a drive unit or too close to the namespace end"))
        else:
            if lba != model.cntr[q]:
                errors.append(("not contiguous", f"{where}: expected {model.cntr[q]:#x}"))
            if n_lbas % LBA_ALIGN == 0 and lba % LBA_ALIGN:
                errors.append(("straddles", f"{where}: straddles a drive unit"))
        point["scored"][q] = point["scored"].get(q, 0) + 1

    async def _monitor():
        prev_contig = 0
        while running:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            # A load has priority over every advance, so this cycle's accepts do not move a counter.
            if _lvl(dut.seq_load):
                model.load(_lvl(dut.nvme_rd_req_lba_ptr_reg) & lba_mask)
                stats["loads"] += 1
                prev_contig = _lvl(dut.contig_test)
                continue
            contig = _lvl(dut.contig_test)
            if contig and not prev_contig:
                model.point_start()
                stats["starts"] += 1
            prev_contig = contig
            if not _lvl(dut.seq_en):
                continue
            rand = _lvl(dut.tst_sel_reg) & 1
            advance = {}
            if _lvl(dut.rd_req_accepted_s):
                q = _seq_idx(_lvl(dut.nvme_rd_req_qid_s))
                n_lbas = _lvl(dut.core_rd_req_lba_num) + 1
                _score("rd", q, _lvl(dut.core_rd_req_lba_ptr), n_lbas, rand)
                advance[q] = advance.get(q, 0) + n_lbas
            if _lvl(dut.gen_nvme_wr_accept) & 1:
                meta = _lvl(dut.gen_wr_meta_full)
                q = _seq_idx(meta >> SQE_LBA_PTR_W)
                n_lbas = point["size"] + 1
                _score("wr", q, meta & ((1 << SQE_LBA_PTR_W) - 1), n_lbas, rand)
                advance[q] = advance.get(q, 0) + n_lbas
            model.step(advance)

    async def _readback_counters():
        c = test._comp
        for q in range(n_queues):
            await e(c.write32)(0x70, q)
            lo = await e(c.read32)(0x74)
            hi = await e(c.read32)(0x78)
            got = ((hi & 1) << 32) | lo
            if got != model.cntr[q]:
                errors.append(("readback", f"after point {point['name']}: queue {q} counter reads "
                                           f"{got:#x} over MI, expected {model.cntr[q]:#x}"))

    async def _run_point(mode, addressing, size):
        point.update(name=f"{mode}:{addressing}:{size}", size=size, scored={})
        await e(_throughput_point_start)(test, mode, addressing, size)
        await ClockCycles(dut.DMA_CLK, random.randint(800, 1600))
        await e(_throughput_point_stop)(test, mode, sleep_fn=lambda _s: None)
        stats["points"] += 1
        # Requests still queued in the interface pipe drain with the point stopped; they carry the
        # manual pointer and move no counter. Quiet must outlast a backpressure window, which hides them.
        quiet_run = 0

        def _drained():
            nonlocal quiet_run
            idle = _lvl(dut.NVME_RD_REQ_VLD) == 0 and not dev.dma_model._rd_busy
            quiet_run = quiet_run + 1 if idle else 0
            return quiet_run >= 32

        assert await _wait_until(_drained, dut, max_cycles=20000), (
            f"point {point['name']} left read requests pending")
        await ClockCycles(dut.DMA_CLK, 20)
        scored = dict(point["scored"])
        need = n_queues if (mode == "rd" and addressing == "seq") else 1
        assert sum(1 for v in scored.values() if v >= 2) >= need, (
            f"point {point['name']} scored too few requests to check a stream: {scored}")
        await _readback_counters()
        cocotb.log.info(f"point {point['name']}: scored per queue {dict(sorted(scored.items()))}, "
                        f"counters {[hex(v) for v in model.cntr]}")

    async def _load(lba):
        # Write mode keeps the read generator off across the trigger, and zero iterations end the
        # counted run the cycle after it starts: only the load remains.
        await aset(test, "tst_mode", "wr")
        await aset(test, "rd_req_lba_ptr", lba)
        loads_before = stats["loads"]
        await e(test._comp.write32)(0x1C, 0)  # IuventusTestRegMap.TST_ITERATIONS
        assert await _wait_until(lambda: stats["loads"] > loads_before, dut, max_cycles=2000), (
            "TST_ITERATIONS did not load the sequential counters")
        await ClockCycles(dut.DMA_CLK, 10)
        point["name"] = f"load {lba:#x}"
        await _readback_counters()

    mon = cocotb.start_soon(_monitor())
    # Out-of-range completions skip the data phase: the one-outstanding model would otherwise drain a
    # credit pool of 128 KiB reads after every stop. Only addresses are under test.
    dev.dma_model.lba_space_size = 0
    bp_period = random.randint(5, 16)
    dev.dma_model.enable_backpressure(bp_period=bp_period, bp_low_cycles=random.randint(1, min(4, bp_period - 2)))
    try:
        for mode, addressing, size in ALIGN_SWEEP_CAMPAIGN + ALIGN_SWEEP_MIXED:
            await _run_point(mode, addressing, size)
        for lba, points in ALIGN_SWEEP_FOLD:
            await _load(lba)
            for mode, addressing, size in points:
                await _run_point(mode, addressing, size)
        await _load(0)
    finally:
        running = False
        await mon
        # The monitor ends in ReadOnly; the next case's reset writes signals, so leave that phase.
        await RisingEdge(dut.DMA_CLK)
        dev.dma_model.lba_space_size = None
        dev.dma_model.disable_backpressure()

    by_kind = {k: sum(1 for kind, _ in errors if kind == k) for k, _ in errors}
    firsts = [f"{k}: " + next(m for kind, m in errors if kind == k) for k in by_kind]
    assert not errors, f"address errors {by_kind}, first of each:\n  " + "\n  ".join(firsts)
    assert stats["starts"] == stats["points"], (
        f"{stats['points']} points ran but contig_test rose {stats['starts']} times")
    assert model.deferred == 0, (
        f"a point start waited {model.deferred} cycles for an idle queue: the generator was already "
        f"issuing when contig_test rose, so its first requests went out before the rounding")
    # The loads at TST_LBA_COUNT-3 and -44 guarantee this even when the random points happen to
    # leave every counter on a unit.
    assert model.rounded > 0, "no point start rounded a counter up, so the alignment went unchecked"
    cocotb.log.info(f"LBA alignment sweep: {stats['points']} points, {model.rounded} counters rounded "
                    f"up at a point start, {stats['loads']} loads")


async def _case_write_enable_disable_midstream(dut, dev, test):
    """Disabling the write generator mid-stream halts it (gen.generating falls) and re-enabling
    resumes with matching frames; the scoreboard catches a frame corrupted at the boundary, and a
    stuck handshake times the resume out."""
    await e(test.set_queue_range)(1)

    sb = Scoreboard("wr_frame[enable_disable_midstream]")
    model = WriteFrameModel(num_queues=NUM_QUEUES)
    lba_ptr = 0x8000
    lba_num = 0

    def on_frame(trans):
        # Expectation per arrival, like _case_small_read_burst's on_accept: the generator free-runs,
        # so the frame count accepted before a disable takes effect is not known in advance.
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
    """A sequential read burst with RDY and DST_RDY held low 3 of every 10 cycles: the scoreboard
    still matches with nothing dropped or duplicated, and the burst completes in a bounded budget,
    so USER_CORE's generator recovers once ready returns.
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

    # Larger budget than the no-backpressure burst's iterations*50: backpressure holds RDY/DST_RDY
    # low ~30% of the time. This bounds "eventually completes", not throughput.
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
    """MI_ASYNC's reset FSM reaches MASTER_RESET and SLAVE_RESET only when one side resets alone,
    which _reset()'s lockstep MI_RST/DMA_RST never does; toggling them apart must visit both, and
    the MI path must work after a normal reset."""
    NO_RESET, MASTER_RESET, SLAVE_RESET = 0, 1, 2

    # The architecture runs off the interface pipeline's delayed reset copy, so DMA_RST reaches
    # MI_ASYNC a few DMA_CLK cycles late, plus the FSM's cross-domain handshake; settle past both.
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
    """One raw read of the Data Logger CTRL register (0x200) must complete through
    MI_SPLITTER_PLUS_GEN's port 2, which no other case addresses; raw MI, as this DevTree has no
    latency-meter node."""
    got = await dev.mi[0].read32(0x200)
    dut._log.info(f"Data Logger CTRL reg (0x200) read back: {got:#010x}")


async def _case_write_gen_burst_mode(dut, dev, test):
    """mfb_generator's burst FSM enters S_BURST_COUNTDOWN only with bursting set and burst_size >
    REGIONS (1); every DMA_RST clears bursting, so this re-asserts it, dispatches burst_size=3 and
    watches burst_fsm_pst, besides scoring the frame."""
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
    """IUVENTUS_INTEGRITY_CHECKER driven by integ_run.py's MI sequence against the model's
    write/read-back store must report err_cnt 0, and a sweep past the namespace must abort to DONE
    with STS_OP_ERR instead of hanging."""
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

        # A sweep past the namespace must abort (STS_OP_ERR, DONE), not hang: the checker writes
        # first, so the write-OOR completion aborts S_WR_WAIT to DONE before a read can wedge
        # S_RD_DATA.
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
    """Latency mode keeps one command in flight at QD64: LATENCY_METER pairs starts to completions
    positionally, and back-to-back issue can starve the page pool so tst_finished never asserts.
    Checks QD1, the gate engaging and tst_finished."""
    # lat_meas_mode LAST: tst_mode/tst_addressing also write TST_SEQ_RAND_SEL (0x20) and would
    # clear bit 4 again.
    await e(lambda: setattr(test, "tst_mode", mode))()
    await e(lambda: setattr(test, "tst_addressing", "seq"))()
    # set_bit() preserves tst_sel_reg; a whole-register write clobbers the read-generator enable.
    # Wait for the gate to reach the DUT: the MI write is slower than the first frames.
    await e(lambda: setattr(test, "lat_meas_mode", True))()
    for _ in range(400):
        await RisingEdge(dut.DMA_CLK)
    assert int(dut.lat_meas_mode.value) == 1, (
        f"lat_meas_mode did not reach the DUT even on a direct write32 "
        f"(tst_sel_reg={int(dut.tst_sel_reg.value)}, contig={int(dut.contig_test.value)})"
    )
    # Bypass the >=1000 guard on IuventusTest.tst_iterations: it exists for statistical confidence
    # on hardware and 1000 QD1 round trips do not fit the sim budget.
    if mode == "wr":
        await e(lambda: setattr(test.gen, "bursting", True))()
        await e(lambda: test.disp_wr_req(0, 3, 8))()
    await e(lambda: test._comp.write32(0x1C, 8))()  # IuventusTestRegMap.TST_ITERATIONS

    async def _lat_monitor():
        """Runs for the whole case, not just the measurement loop, as a violation can follow
        tst_finished."""
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


async def _case_rd_hold_knob(dut, dev, test):
    """The periodic RD MFB hold (0x80 period, 0x84 length, DMA_CLK cycles): endpoint 0's read
    stream must be refused for exactly LEN of every PERIOD cycles, and never once PERIOD is 0."""
    c = dev.nfb.comp_open("ziti,iuventus_test_ctrl")
    period, length, periods = 100, 30, 10
    await e(c.write32)(0x84, length)
    await e(c.write32)(0x80, period)
    assert await e(c.read32)(0x80) == period and await e(c.read32)(0x84) == length, \
        "RD hold registers do not read back"
    rdy = dut.core_rd_mfb_dst_rdy
    # Align to the start of a hold window, then count refused cycles over whole periods.
    assert await _wait_until(lambda: (int(rdy.value) & 1) == 1, dut, max_cycles=4 * period)
    assert await _wait_until(lambda: (int(rdy.value) & 1) == 0, dut, max_cycles=4 * period)
    held = 0
    for _ in range(period * periods):
        held += (int(rdy.value) & 1) == 0
        await RisingEdge(dut.DMA_CLK)
    assert held == length * periods, f"RD hold refused {held} of {period * periods} cycles, expected {length * periods}"
    await e(c.write32)(0x80, 0)
    # The posted write crosses MI_ASYNC; the read-back orders it before the check.
    assert await e(c.read32)(0x80) == 0
    for _ in range(2 * period):
        assert (int(rdy.value) & 1) == 1, "RD MFB still held with the hold period at 0"
        await RisingEdge(dut.DMA_CLK)


@cocotb.test(timeout_time=2000, timeout_unit='us')
async def test_user_core_reference_model(dut):
    """Every case against the reference-model scoreboard through SimplifiedDmaModel: MI smoke,
    directed reads and writes, iuventus_rw_test.py's CLI-path functions and corner cases, in one
    test sharing one device."""
    dev = IuventusUserCoreNfbDevice(dut)
    await dev.init()
    # IuventusTest.__init__ performs blocking nfb calls (the MfbGenerator burst_size/bursting
    # setters), so construction goes through the bridge like every other IuventusTest access.
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

    await dev._reset()
    dev.dma_model.reset()
    await _case_lba_alignment_sweep(dut, dev, test, n_queues=NUM_QUEUES)

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
    await _case_rand_draw_per_accept(dut, dev, test)

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

    await dev._reset()
    dev.dma_model.reset()
    await _case_rd_hold_knob(dut, dev, test)
