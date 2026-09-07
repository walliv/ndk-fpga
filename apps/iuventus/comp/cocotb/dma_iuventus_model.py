# dma_iuventus_model.py: simplified DMA Iuventus environment for the USER_CORE cocotb testbench.
# Drives the NVME_* interfaces USER_CORE expects a real DMA_IUVENTUS/SSD backend to service --
# just enough to close the request -> completion loop, NOT a full behavioral model of
# comp/dma/dma_iuventus itself.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.triggers import Event, RisingEdge, ReadOnly

from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

# NVME_OP_STAT_TYPE: "0 for write, 1 for read" (see user_core_ent.vhd's port comment).
OP_STAT_TYPE_WRITE = 0
OP_STAT_TYPE_READ = 1
OP_STAT_CODE_SUCCESS = 0
OP_STAT_CODE_OOR = 2   # LBA Out of Range (op_ctrl.vhd's "10"): completed internally, no data transfer

# QID_W, matching user_core_test_arch.vhd's `maximum(1, log2(NUM_QUEUES))` (ceil-log2, log2(1)=0
# by math_pack convention). Needed for NVME_WR_MFB_META's width (SQE_LBA_PTR_W(64) + QID_W).
_NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))
QID_W = max(1, (_NUM_QUEUES - 1).bit_length())
SQE_LBA_PTR_W = 64

# MFB geometry passed explicitly: get_mfb_params() infers a wrong block_size/item_width=1
# from EOF_POS here, tripping MFBDriver's assert. meta_width must be given too, or
# trans.meta stays unpopulated.
_MFB_PARAMS = {
    "regions": 1,
    "region_size": 8,
    "block_size": 8,
    "item_width": 8,
    "meta_width": SQE_LBA_PTR_W + QID_W,
}


class SimplifiedDmaModel:
    """Drives/monitors USER_CORE's NVME_* interfaces from the DMA_CLK side, standing in for
    DMA_IUVENTUS + the SSD it talks to.

    Read path (NVME_RD_REQ / NVME_RD_MFB / NVME_OP_STAT):
      - Single-outstanding by construction: NVME_RD_REQ_RDY is only asserted when no read is
        currently in flight, and is dropped the instant a request is accepted. This keeps the
        model's (and the RTL's own) address/QID state fully deterministic -- a HW backend with any
        real queue-depth limit already throttles this way; genuinely-concurrent multi-outstanding
        reads are out of scope for this simplified environment.
      - After `rd_latency_cycles` cycles, the model returns (LBA_NUM+1) sectors of a deterministic
        counting pattern on NVME_RD_MFB, then one NVME_OP_STAT (TYPE=READ) completion pulse, then
        re-asserts RDY.

    Write path (NVME_WR_MFB / NVME_OP_STAT):
      - NVME_WR_MFB_DST_RDY is held high (no backpressure) by default.
      - Each complete frame observed on NVME_WR_MFB triggers, after `wr_latency_cycles` cycles, one
        NVME_OP_STAT (TYPE=WRITE) completion pulse.

    Completions are serialized through a single internal queue/coroutine so overlapping read/write
    completions never collide on the same DMA_CLK edge.

    Backpressure (Stage 3): call `enable_backpressure()` to make a background loop
    (`_backpressure_loop`) periodically hold BOTH NVME_RD_REQ_RDY and NVME_WR_MFB_DST_RDY low
    together for `bp_low_cycles` cycles out of every `bp_period` cycles -- the direct
    component-level sim analog of a real backend (SSD/DMA_IUVENTUS) that intermittently can't
    accept new requests or write data (e.g. the HW read-path stall / SSD idle-window wedge).
    USER_CORE's request/frame generators must hold VLD/SRC_RDY steady and resume (not drop,
    duplicate, or wedge) once ready is reasserted; that's exactly what the backpressure directed
    case in cocotb_test.py checks via the reference-model scoreboard. Disabled by default
    (`enable_backpressure()` not called), in which case behavior is identical to before this knob
    existed. `disable_backpressure()` cleanly turns it back off (e.g. between directed cases
    sharing one long-lived model instance).
    """

    def __init__(self, dut, clk, rd_latency_cycles: int = 2, wr_latency_cycles: int = 2):
        self._dut = dut
        self._clk = clk
        self.rd_latency_cycles = rd_latency_cycles
        self.wr_latency_cycles = wr_latency_cycles
        self.bp_period = 10
        self.bp_low_cycles = 3

        self.rd_req_accept_cb = None   # (lba_ptr, lba_num, qid) -> None
        self.wr_frame_accept_cb = None  # (MfbTransactionWithMeta) -> None

        self._rd_busy = False
        self._bp_enabled = False  # backpressure feature armed (toggled by enable/disable_backpressure)
        self._bp_active = False  # backpressure window currently in effect (RDY/DST_RDY held low)
        self._op_stat_pending = []  # list of (type, code, done_event_or_None) awaiting dispatch, FIFO
        # Optional DATA INTEGRITY store (LBA -> 512-byte sector): enabled, READ returns bytes a
        # prior WRITE stored, so IUVENTUS_INTEGRITY_CHECKER's comparison runs end-to-end;
        # disabled, READ returns a fixed pattern.
        self.data_integrity = False
        self._storage = {}  # 512-aligned byte offset -> bytes(512)
        # Optional OOR modelling: when set, any read/write whose (lba_ptr + sectors) exceeds this
        # SECTOR count completes with OP_STAT_CODE_OOR and no data transfer, mirroring the DMA's
        # LBA-Out-of-Range completion. None = never OOR (default).
        self.lba_space_size = None

        dut.NVME_RD_REQ_RDY.value = 1
        # Per-queue "DMA can accept a read" (op_ctrl.vhd's SQ_HAS_SPACE, mirrored via
        # DMA_IUVENTUS -- NVME_RD_REQ_QUEUE_RDY). This single-outstanding model skips per-queue SQ
        # occupancy: every queue stays permanently "ready".
        dut.NVME_RD_REQ_QUEUE_RDY.value = (1 << _NUM_QUEUES) - 1
        dut.NVME_OP_STAT_TYPE.value = 0
        dut.NVME_OP_STAT_CODE.value = 0
        dut.NVME_OP_STAT_VLD.value = 0
        dut.NVME_RD_MFB_DATA.value = 0
        dut.NVME_RD_MFB_SOF.value = 0
        dut.NVME_RD_MFB_EOF.value = 0
        dut.NVME_RD_MFB_SOF_POS.value = 0
        dut.NVME_RD_MFB_EOF_POS.value = 0
        dut.NVME_RD_MFB_SRC_RDY.value = 0
        dut.NVME_WR_MFB_DST_RDY.value = 1

        self._rd_mfb_driver = MFBDriver(dut, "NVME_RD_MFB", clk, mfb_params=_MFB_PARAMS, vld_gen=None)
        self._wr_mfb_monitor = MFBMonitor(dut, "NVME_WR_MFB", clk, mfb_params=_MFB_PARAMS, trans_type=MfbTransactionWithMeta)
        self._wr_mfb_monitor.add_callback(self._on_wr_frame)

        cocotb.start_soon(self._rd_req_loop())
        cocotb.start_soon(self._op_stat_loop())
        cocotb.start_soon(self._wr_dst_rdy_loop())
        cocotb.start_soon(self._backpressure_loop())

    def reset(self) -> None:
        """Clears this model's own in-flight/pending state. Call after pulsing a fresh DMA_RST
        mid-simulation (e.g. between directed sub-scenarios sharing one cocotb test) so a stray
        in-flight request/completion from a previous scenario can't leak into the next one."""
        self._rd_busy = False
        self._bp_active = False
        self._op_stat_pending.clear()
        self._dut.NVME_RD_REQ_RDY.value = 1
        self._dut.NVME_OP_STAT_VLD.value = 0

    def enable_backpressure(self, bp_period: int = 10, bp_low_cycles: int = 3) -> None:
        """Arms periodic backpressure: RDY/DST_RDY will be held low for `bp_low_cycles` cycles out
        of every `bp_period` cycles, starting from the next cycle boundary `_backpressure_loop`
        observes."""
        self.bp_period = bp_period
        self.bp_low_cycles = bp_low_cycles
        self._bp_enabled = True

    def disable_backpressure(self) -> None:
        """Disarms backpressure; RDY/DST_RDY return to their normal (busy-gated / always-high)
        behavior from the next cycle."""
        self._bp_enabled = False

    async def _wr_dst_rdy_loop(self):
        """Drives NVME_WR_MFB_DST_RDY as a synchronous level every cycle (same discipline as
        _rd_req_loop's RDY): high unless a backpressure window is active. With backpressure never
        enabled, `_bp_active` is permanently False, so this reproduces the previous "always high"
        tie-off exactly."""
        while True:
            await RisingEdge(self._clk)
            self._dut.NVME_WR_MFB_DST_RDY.value = int(not self._bp_active)

    async def _backpressure_loop(self):
        """Recomputes `_bp_active` fresh every cycle from a free-running `cycle_in_period` counter
        (reset whenever backpressure is disabled), holding it True for the last `bp_low_cycles` of
        every `bp_period`-cycle window while `_bp_enabled`. RDY/DST_RDY (via _rd_req_loop /
        _wr_dst_rdy_loop, which both AND in `not self._bp_active`) are held low together during
        that window, independent of any in-flight read/write servicing."""
        cycle_in_period = 0
        while True:
            await RisingEdge(self._clk)
            if not self._bp_enabled:
                self._bp_active = False
                cycle_in_period = 0
                continue
            self._bp_active = cycle_in_period >= (self.bp_period - self.bp_low_cycles)
            cycle_in_period = (cycle_in_period + 1) % self.bp_period

    async def _rd_req_loop(self):
        """Drives NVME_RD_REQ_RDY as a synchronous level, decided fresh every DMA_CLK edge from
        `self._rd_busy` -- NOT reactively out of the ReadOnly phase. RDY is written immediately
        after RisingEdge (the Normal/writable phase), so its new value is stable across the WHOLE
        upcoming cycle and is exactly what the DUT's own registered processes (e.g. this core's
        rd_qid_rr_p) see at the NEXT edge. Sampling (of VLD/RDY/the request fields) is kept
        strictly separate, done afterwards in ReadOnly() once all of this edge's deltas have
        settled. This avoids the previous NextTimeStep()-based reactive drive, which -- though it
        never raised an error -- produced RDY transitions that the DUT did not register as clean,
        edge-aligned handshakes (see cocotb_test.py's history for the misdiagnosis this caused)."""
        while True:
            await RisingEdge(self._clk)
            self._dut.NVME_RD_REQ_RDY.value = int((not self._rd_busy) and (not self._bp_active))

            await ReadOnly()
            vld = bool(self._dut.NVME_RD_REQ_VLD.value)
            rdy = bool(self._dut.NVME_RD_REQ_RDY.value)

            if self._rd_busy or not (vld and rdy):
                continue

            lba_ptr = int(self._dut.NVME_RD_REQ_LBA_PTR.value)
            lba_num = int(self._dut.NVME_RD_REQ_LBA_NUM.value)
            qid = int(self._dut.NVME_RD_REQ_QID.value)

            self._rd_busy = True

            if self.rd_req_accept_cb:
                self.rd_req_accept_cb(lba_ptr, lba_num, qid)

            cocotb.start_soon(self._service_read(lba_num, lba_ptr))

    async def _service_read(self, lba_num: int, lba_ptr: int = 0):
        for _ in range(self.rd_latency_cycles):
            await RisingEdge(self._clk)

        if self.lba_space_size is not None and (lba_ptr + lba_num + 1) > self.lba_space_size:
            # LBA Out of Range: op_ctrl completes it internally, never drains WRBUFF (no RD_MFB).
            done = Event()
            self._op_stat_pending.append((OP_STAT_TYPE_READ, OP_STAT_CODE_OOR, done))
            await done.wait()
            await RisingEdge(self._clk)
            self._rd_busy = False
            return

        total_bytes = (lba_num + 1) * 512
        if self.data_integrity:
            # Return exactly what a prior WRITE stored at this LBA (zeros if never written), so the
            # integrity checker's read-back compare against its own write pattern is meaningful.
            out = bytearray()
            for off in range(0, total_bytes, 512):
                out += self._storage.get(lba_ptr + off, bytes(512))
            pattern = bytes(out)
        else:
            pattern = bytes([i & 0xFF for i in range(total_bytes)])
        await self._rd_mfb_driver.send(pattern)

        # Wait one extra RisingEdge past OP_STAT_VLD's fall before re-arming RDY: seq_addr/QID
        # advance synchronously on NVME_OP_STAT_VLD, so re-arming on the same edge could accept the
        # next request before that increment settles.
        done = Event()
        self._op_stat_pending.append((OP_STAT_TYPE_READ, OP_STAT_CODE_SUCCESS, done))
        await done.wait()
        await RisingEdge(self._clk)

        # RDY itself is re-driven by `_rd_req_loop` on the next edge (it recomputes
        # `not self._rd_busy` every cycle) -- clearing the busy flag here is enough.
        self._rd_busy = False

    def _on_wr_frame(self, trans):
        if self.wr_frame_accept_cb:
            self.wr_frame_accept_cb(trans)
        # META = [QID (high QID_W bits) | LBA_PTR (low SQE_LBA_PTR_W bits, a BYTE address)].
        lba = int(trans.meta) & ((1 << SQE_LBA_PTR_W) - 1)
        data = bytes(trans.data)
        sectors = max(1, len(data) // 512)
        oor = self.lba_space_size is not None and (lba + sectors) > self.lba_space_size
        if self.data_integrity and not oor:
            for off in range(0, len(data), 512):
                self._storage[lba + off] = data[off:off + 512].ljust(512, b'\x00')
        cocotb.start_soon(self._service_write(oor))

    async def _service_write(self, oor: bool = False):
        for _ in range(self.wr_latency_cycles):
            await RisingEdge(self._clk)
        # No `_rd_busy`-style single-outstanding gate exists on the write side (DST_RDY is held
        # high throughout), so there is no analogous "next accept races the completion" hazard --
        # a completion event is not needed here.
        code = OP_STAT_CODE_OOR if oor else OP_STAT_CODE_SUCCESS
        self._op_stat_pending.append((OP_STAT_TYPE_WRITE, code, None))

    async def _op_stat_loop(self):
        while True:
            await RisingEdge(self._clk)

            if not self._op_stat_pending:
                self._dut.NVME_OP_STAT_VLD.value = 0
                continue

            op_type, op_code, done = self._op_stat_pending.pop(0)
            self._dut.NVME_OP_STAT_TYPE.value = op_type
            self._dut.NVME_OP_STAT_CODE.value = op_code
            self._dut.NVME_OP_STAT_VLD.value = 1

            await RisingEdge(self._clk)
            self._dut.NVME_OP_STAT_VLD.value = 0

            if done is not None:
                done.set()
