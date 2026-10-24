# dma_iuventus_model.py: simplified DMA Iuventus stand-in for the USER_CORE cocotb testbench.
# Services the NVME_* interfaces just enough to close the request -> completion loop; not a
# behavioral model of comp/dma/dma_iuventus.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.triggers import Event, RisingEdge, ReadOnly

from cocotbext.ofm.mfb.fast_drivers import MFBDriver
from cocotbext.ofm.mfb.fast_monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

from endpoint_view import EndpointView

# NVME_OP_STAT_TYPE: "0 for write, 1 for read" (see user_core_ent.vhd's port comment).
OP_STAT_TYPE_WRITE = 0
OP_STAT_TYPE_READ = 1
OP_STAT_CODE_SUCCESS = 0
OP_STAT_CODE_OOR = 2   # LBA Out of Range ("10"): completed without moving data

_NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))
# Every queue offered ready at once (see the per-queue handshake note in __init__).
ALL_QUEUES_RDY = (1 << _NUM_QUEUES) - 1


def _as_int(value):
    """int() of a signal value, treating any X/U bit as 0: a per-queue vector reads X for the first
    cycles out of reset, and a bare int() raising there would kill the driving loop."""
    try:
        return int(value)
    except ValueError:
        return 0
# QID_W matches user_core_test_arch.vhd's maximum(1, log2(NUM_QUEUES)) (ceil-log2 per math_pack).
# NVME_WR_MFB_META is SQE_LBA_PTR_W(64) + QID_W bits per region (see nvme_wr_mfb_meta_g).
QID_W = max(1, (_NUM_QUEUES - 1).bit_length())
SQE_LBA_PTR_W = 64
# nvme_meta_pack.CQ_ENTRY_CMD_ID_W -- the NVMe Command Identifier width.
CQ_ENTRY_CMD_ID_W = 16

# Explicit MFB geometry, not get_mfb_params(): that assumes EOF_POS encodes BLOCK_SIZE, but here it
# encodes log2(REGION_SIZE*BLOCK_SIZE). meta_width must be given too; it defaults to 0.
_WR_MFB_PARAMS = {
    "regions": 1,
    "region_size": 8,
    "block_size": 8,
    "item_width": 8,
    "meta_width": SQE_LBA_PTR_W + QID_W,
}

# RD_MFB_META carries the identity of the command whose data the frame holds (QID above CID), a
# different field from WR_MFB_META's LBA+QID, so the two buses need separate params.
_RD_MFB_PARAMS = dict(_WR_MFB_PARAMS, meta_width=QID_W + CQ_ENTRY_CMD_ID_W)


class SimplifiedDmaModel:
    """Stands in for DMA_IUVENTUS and its SSD on USER_CORE's NVME_* interfaces. Reads are
    single-outstanding so address/QID state stays deterministic; one OP_STAT queue serializes read
    and write completions so they never share an edge.
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
        # Optional write/read-back data-integrity store, byte-address LBA -> 512-byte sector:
        # enabled, a READ returns what a prior WRITE stored there; disabled, the fixed pattern.
        self.data_integrity = False
        self._storage = {}  # key -> bytes(512); key is LBA_PTR, or (qid, LBA_PTR) below
        # False: one shared LBA_PTR -> sector map. True isolates it per queue, key (qid, LBA_PTR),
        # as on hardware where each queue talks to its own drive; cocotb_test_arch never sets it.
        self.per_queue_storage = False
        # LBA_PTR advance per sector: the integrity checker strides 512 (byte address), the GROUP BY
        # engine 1 (NVMe block index); both are self-consistent, so the DUT must say which it means.
        self.lba_sector_stride = 512
        # Optional OOR modelling: a read/write whose (lba_ptr + sectors) exceeds this sector count
        # completes with OP_STAT_CODE_OOR and no data, as the DMA does; None = never OOR.
        self.lba_space_size = None

        # VLD/RDY are per-queue vectors with SQ_HAS_SPACE folded into RDY. This single-outstanding
        # model does not track per-queue SQ occupancy: it offers every queue ready, gated on
        # _rd_busy.
        dut.NVME_RD_REQ_RDY.value = ALL_QUEUES_RDY
        dut.NVME_OP_STAT_TYPE.value = 0
        dut.NVME_OP_STAT_QID.value = 0
        dut.NVME_OP_STAT_CID.value = 0
        dut.NVME_OP_STAT_CODE.value = 0
        dut.NVME_OP_STAT_VLD.value = 0
        dut.NVME_RD_REQ_CID.value = 0
        dut.NVME_RD_REQ_CID_VLD.value = 0
        # Tags handed out to accepted reads. The real DMA draws them from a per-queue pool; here the
        # CID on RD_MFB_META and OP_STAT only has to match the one published for that request.
        self._next_cid = 0
        self._rd_task = None
        self._inflight_cid = 0
        self._inflight_qid = 0
        # NVME_RD_MFB is per endpoint; this single-outstanding model serves endpoint 0's stream.
        self._rd = EndpointView(dut, 0)
        self._idle_rd_mfb()
        dut.NVME_WR_MFB_DST_RDY.value = 1

        self._rd_mfb_driver = MFBDriver(self._rd, "NVME_RD_MFB", clk, mfb_params=_RD_MFB_PARAMS, vld_gen=None)
        self._wr_mfb_monitor = MFBMonitor(dut, "NVME_WR_MFB", clk, mfb_params=_WR_MFB_PARAMS, trans_type=MfbTransactionWithMeta)
        self._wr_mfb_monitor.add_callback(self._on_wr_frame)

        cocotb.start_soon(self._rst_loop())
        cocotb.start_soon(self._rd_req_loop())
        cocotb.start_soon(self._op_stat_loop())
        cocotb.start_soon(self._wr_dst_rdy_loop())
        cocotb.start_soon(self._backpressure_loop())

    def _idle_rd_mfb(self) -> None:
        """Park RD_MFB with nothing offered, the state the driver expects between frames."""
        self._rd.NVME_RD_MFB_DATA.value = 0
        self._rd.NVME_RD_MFB_SOF.value = 0
        self._rd.NVME_RD_MFB_EOF.value = 0
        self._rd.NVME_RD_MFB_SOF_POS.value = 0
        self._rd.NVME_RD_MFB_EOF_POS.value = 0
        self._rd.NVME_RD_MFB_SRC_RDY.value = 0

    def reset(self) -> None:
        """Clears in-flight and pending state after a DMA_RST between scenarios sharing one test,
        so a stray request or completion cannot leak into the next scenario."""
        # Cancel the in-flight read service: it parks inside send() and would resume in the next
        # scenario, where two coroutines drive RD_MFB in one timestep and cost a frame its SOF.
        if self._rd_task is not None and not self._rd_task.done():
            self._rd_task.cancel()
        self._rd_task = None
        # Cancelling can land mid-frame, leaving queued words in the driver and a half-written
        # word on the bus. abort() drops both, so the next scenario starts from nothing.
        self._rd_mfb_driver.abort()
        self._idle_rd_mfb()
        self._rd_busy = False
        self._bp_active = False
        self._op_stat_pending.clear()
        self._dut.NVME_RD_REQ_RDY.value = ALL_QUEUES_RDY
        self._dut.NVME_OP_STAT_VLD.value = 0

    def enable_backpressure(self, bp_period: int = 10, bp_low_cycles: int = 3) -> None:
        """Holds RDY/DST_RDY low for `bp_low_cycles` of every `bp_period` cycles. At least two ready
        cycles per period: USER_CORE_IF_PIPE picks its offer from RDY a cycle ahead, so a one-cycle
        window is gone when the offer lands."""
        assert bp_period - bp_low_cycles >= 2, (
            f"backpressure {bp_low_cycles}/{bp_period} leaves a one-cycle ready window, which the "
            f"request pipe can never hit")
        self.bp_period = bp_period
        self.bp_low_cycles = bp_low_cycles
        self._bp_enabled = True

    def disable_backpressure(self) -> None:
        """Disarms backpressure; RDY/DST_RDY return to their normal (busy-gated / always-high)
        behavior from the next cycle."""
        self._bp_enabled = False

    def _storage_key(self, qid: int, lba: int):
        return (qid, lba) if self.per_queue_storage else lba

    def seed_sector(self, lba: int, data: bytes, qid: int = None) -> None:
        """Stages one 512 B sector where a later read finds it; `qid` selects the drive in
        per_queue_storage mode and must be omitted otherwise."""
        assert len(data) == 512, f"a sector is 512 B, got {len(data)}"
        assert self.per_queue_storage or qid is None, \
            "qid is only meaningful with per_queue_storage enabled"
        self._storage[self._storage_key(qid if qid is not None else 0, lba)] = bytes(data)

    async def _rst_loop(self):
        """Self-resets on DMA_RST like the real engine: otherwise a read still driving across the
        pulse lands its EOF after it, with its SOF on the far side."""
        prev = "0"
        while True:
            await RisingEdge(self._clk)
            now = str(self._dut.DMA_RST.value)
            if now == "1" and prev != "1":
                self.reset()
            prev = now

    async def _wr_dst_rdy_loop(self):
        """DST_RDY as a synchronous level every cycle, like _rd_req_loop's RDY: high unless a
        backpressure window is active."""
        while True:
            await RisingEdge(self._clk)
            self._dut.NVME_WR_MFB_DST_RDY.value = int(not self._bp_active)

    async def _backpressure_loop(self):
        """One `_bp_active` window shared by RDY and DST_RDY, so both drop together regardless of
        any read or write in flight."""
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
        """RDY is written right after RisingEdge, so it holds across the whole cycle the DUT samples
        at the next edge; sampling waits for ReadOnly. Driven reactively from ReadOnly, RDY edges
        are not seen by the DUT as clean handshakes."""
        while True:
            await RisingEdge(self._clk)
            accepting = (not self._rd_busy) and (not self._bp_active)
            self._dut.NVME_RD_REQ_RDY.value = ALL_QUEUES_RDY if accepting else 0

            await ReadOnly()
            vld_vec = _as_int(self._dut.NVME_RD_REQ_VLD.value)
            rdy_vec = _as_int(self._dut.NVME_RD_REQ_RDY.value)
            qid = _as_int(self._dut.NVME_RD_REQ_QID.value)

            if vld_vec:
                # The entity promises at most one VLD bit, on bit QID; a second bit or one off QID
                # would route the request to the wrong queue's SQ yet look like a clean handshake.
                assert vld_vec & (vld_vec - 1) == 0, (
                    f"NVME_RD_REQ_VLD has {bin(vld_vec)} set -- at most one queue may offer")
                assert vld_vec == (1 << qid), (
                    f"NVME_RD_REQ_VLD={bin(vld_vec)} does not match NVME_RD_REQ_QID={qid}")

            if self._rd_busy or not (vld_vec & rdy_vec):
                continue

            lba_ptr = _as_int(self._dut.NVME_RD_REQ_LBA_PTR.value)
            lba_num = _as_int(self._dut.NVME_RD_REQ_LBA_NUM.value)

            self._rd_busy = True
            self._inflight_cid = self._next_cid
            self._inflight_qid = qid
            self._next_cid = (self._next_cid + 1) % (1 << CQ_ENTRY_CMD_ID_W)

            if self.rd_req_accept_cb:
                self.rd_req_accept_cb(lba_ptr, lba_num, qid)

            cocotb.start_soon(self._publish_rd_req_cid(self._inflight_cid))
            self._rd_task = cocotb.start_soon(self._service_read(lba_num, lba_ptr))

    async def _publish_rd_req_cid(self, cid: int):
        """One-cycle CID_VLD pulse a cycle after the accept, mirroring the DMA: the tag is drawn a
        few cycles after admission, so it cannot be returned in the accept cycle."""
        await RisingEdge(self._clk)
        self._dut.NVME_RD_REQ_CID.value = cid
        self._dut.NVME_RD_REQ_CID_VLD.value = 1
        await RisingEdge(self._clk)
        self._dut.NVME_RD_REQ_CID_VLD.value = 0

    async def _service_read(self, lba_num: int, lba_ptr: int = 0):
        for _ in range(self.rd_latency_cycles):
            await RisingEdge(self._clk)

        if self.lba_space_size is not None and (lba_ptr + lba_num + 1) > self.lba_space_size:
            # LBA Out of Range: completed without moving data, so no RD_MFB follows.
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
            for i in range(lba_num + 1):
                key = self._storage_key(self._inflight_qid, lba_ptr + i * self.lba_sector_stride)
                out += self._storage.get(key, bytes(512))
            pattern = bytes(out)
        else:
            pattern = bytes([i & 0xFF for i in range(total_bytes)])
        # Same identity the accept published, so a consumer can match returned data to its request.
        await self._rd_mfb_driver.send(MfbTransactionWithMeta(
            data=pattern,
            # DMA_IUVENTUS drives RD_MFB_META as CID & QID (queue in the low bits).
            meta=(self._inflight_cid << QID_W) | self._inflight_qid,
        ))

        # Re-arm RDY only after OP_STAT_VLD dispatches: the address generator steps off that pulse
        # (lfsr_rand_addr_gen_i ENABLE), so RDY on the same edge accepts the next request on a
        # stale address.
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
        # META = [QID (high QID_W bits) | LBA_PTR (low SQE_LBA_PTR_W bits)].
        meta = int(trans.meta)
        qid = (meta >> SQE_LBA_PTR_W) & ((1 << QID_W) - 1)
        lba = meta & ((1 << SQE_LBA_PTR_W) - 1)
        data = bytes(trans.data)
        sectors = max(1, len(data) // 512)
        oor = self.lba_space_size is not None and (lba + sectors) > self.lba_space_size
        if self.data_integrity and not oor:
            for i in range(sectors):
                key = self._storage_key(qid, lba + i * self.lba_sector_stride)
                self._storage[key] = data[512 * i:512 * (i + 1)].ljust(512, b'\x00')
        cocotb.start_soon(self._service_write(oor))

    async def _service_write(self, oor: bool = False):
        for _ in range(self.wr_latency_cycles):
            await RisingEdge(self._clk)
        # No `_rd_busy`-style single-outstanding gate exists on the write side (DST_RDY is held
        # high), so no next accept races the completion and no completion event is needed.
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
            self._dut.NVME_OP_STAT_QID.value = self._inflight_qid
            self._dut.NVME_OP_STAT_CID.value = self._inflight_cid
            self._dut.NVME_OP_STAT_CODE.value = op_code
            self._dut.NVME_OP_STAT_VLD.value = 1

            await RisingEdge(self._clk)
            self._dut.NVME_OP_STAT_VLD.value = 0

            if done is not None:
                done.set()
