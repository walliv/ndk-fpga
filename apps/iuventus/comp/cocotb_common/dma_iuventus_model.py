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
OP_STAT_CODE_OOR = 2   # LBA Out of Range ("10"): completed without moving data

# QID_W matches user_core_test_arch.vhd's maximum(1, log2(NUM_QUEUES)) (ceil-log2 per math_pack;
# log2(1)=0). Sizes NVME_WR_MFB_META: SQE_LBA_PTR_W(64) + QID_W bits per region (see
# nvme_wr_mfb_meta_g).
_NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))
# Every queue offered ready at once (see the per-queue handshake note in __init__).
ALL_QUEUES_RDY = (1 << _NUM_QUEUES) - 1


def _as_int(value):
    """int() of a signal value, treating any X/U bit as 0.

    A per-queue vector reads as X for the first cycles out of reset, and a bare int() raises there,
    which would kill the driving loop rather than simply skipping the cycle."""
    try:
        return int(value)
    except ValueError:
        return 0
QID_W = max(1, (_NUM_QUEUES - 1).bit_length())
SQE_LBA_PTR_W = 64
# nvme_meta_pack.CQ_ENTRY_CMD_ID_W -- the NVMe Command Identifier width.
CQ_ENTRY_CMD_ID_W = 16

# USER_CORE's MFB geometry given explicitly, not via get_mfb_params(): it assumes EOF_POS encodes
# BLOCK_SIZE, but here it encodes log2(REGION_SIZE*BLOCK_SIZE). meta_width must also be explicit --
# omitted, it silently defaults to 0.
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
    accept new requests or write data.
    USER_CORE's request/frame generators must hold VLD/SRC_RDY steady and resume (not drop,
    duplicate, or wedge) once ready is reasserted; that's exactly what the backpressure directed
    case in cocotb_test.py checks via the reference-model scoreboard. Disabled by default
    (`enable_backpressure()` not called). `disable_backpressure()` turns it back off, e.g.
    between directed cases sharing one long-lived model instance.
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
        # Optional write/read-back DATA INTEGRITY store, byte-address LBA -> 512-byte sector.
        # Enabled, a READ returns bytes a prior WRITE stored there so the integrity checker's
        # read-back compare runs end-to-end; disabled, READ returns the fixed pattern.
        self.data_integrity = False
        self._storage = {}  # key -> bytes(512); key is LBA_PTR, or (qid, LBA_PTR) below
        # Off by default: the store is one shared LBA_PTR -> sector map. Set True to isolate it per
        # queue (key becomes (qid, LBA_PTR)), matching hardware where each queue talks to its own
        # drive; cocotb_test_arch never sets this.
        self.per_queue_storage = False
        # How much LBA_PTR advances per sector. The integrity checker strides it by 512, as a byte
        # address; the GROUP BY engine strides it by 1, as the block index the NVMe command
        # expects. Both are self-consistent, so the DUT has to say which it means.
        self.lba_sector_stride = 512
        # Optional OOR modelling: when set, any read/write whose (lba_ptr + sectors) exceeds this
        # SECTOR count completes with OP_STAT_CODE_OOR and no data transfer, mirroring the DMA's
        # LBA-Out-of-Range completion. None = never OOR (default).
        self.lba_space_size = None

        # VLD/RDY are per-queue vectors now, the deleted NVME_RD_REQ_QUEUE_RDY's SQ_HAS_SPACE
        # meaning having folded into RDY. This single-outstanding model does not track per-queue SQ
        # occupancy, so it offers every queue ready and gates on its own _rd_busy.
        dut.NVME_RD_REQ_RDY.value = ALL_QUEUES_RDY
        dut.NVME_OP_STAT_TYPE.value = 0
        dut.NVME_OP_STAT_QID.value = 0
        dut.NVME_OP_STAT_CID.value = 0
        dut.NVME_OP_STAT_CODE.value = 0
        dut.NVME_OP_STAT_VLD.value = 0
        dut.NVME_RD_REQ_CID.value = 0
        dut.NVME_RD_REQ_CID_VLD.value = 0
        # Tags handed out to accepted reads. The real DMA draws them from a per-queue pool; this
        # model only has to be self-consistent: the CID it reports on RD_MFB_META and OP_STAT must
        # be the one it published for that request.
        self._next_cid = 0
        self._rd_task = None
        self._inflight_cid = 0
        self._inflight_qid = 0
        self._idle_rd_mfb()
        dut.NVME_WR_MFB_DST_RDY.value = 1

        self._rd_mfb_driver = MFBDriver(dut, "NVME_RD_MFB", clk, mfb_params=_RD_MFB_PARAMS, vld_gen=None)
        self._wr_mfb_monitor = MFBMonitor(dut, "NVME_WR_MFB", clk, mfb_params=_WR_MFB_PARAMS, trans_type=MfbTransactionWithMeta)
        self._wr_mfb_monitor.add_callback(self._on_wr_frame)

        cocotb.start_soon(self._rst_loop())
        cocotb.start_soon(self._rd_req_loop())
        cocotb.start_soon(self._op_stat_loop())
        cocotb.start_soon(self._wr_dst_rdy_loop())
        cocotb.start_soon(self._backpressure_loop())

    def _idle_rd_mfb(self) -> None:
        """Park RD_MFB with nothing offered, the state the driver expects between frames."""
        self._dut.NVME_RD_MFB_DATA.value = 0
        self._dut.NVME_RD_MFB_SOF.value = 0
        self._dut.NVME_RD_MFB_EOF.value = 0
        self._dut.NVME_RD_MFB_SOF_POS.value = 0
        self._dut.NVME_RD_MFB_EOF_POS.value = 0
        self._dut.NVME_RD_MFB_SRC_RDY.value = 0

    def reset(self) -> None:
        """Clears this model's own in-flight/pending state. Call after pulsing a fresh DMA_RST
        mid-simulation (e.g. between directed sub-scenarios sharing one cocotb test) so a stray
        in-flight request/completion from a previous scenario can't leak into the next one."""
        # Cancel the in-flight read service, do not merely forget it: it parks inside send(), so
        # leaving it alive lets it resume once the next scenario started its own, and two
        # coroutines then drive RD_MFB in one timestep, costing a frame its SOF.
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

    def _storage_key(self, qid: int, lba: int):
        return (qid, lba) if self.per_queue_storage else lba

    def seed_sector(self, lba: int, data: bytes, qid: int = None) -> None:
        """Stages one 512 B sector where a later read will find it -- the public alternative to a
        test reaching into `_storage` directly. `qid` selects the drive in per_queue_storage mode
        and must be omitted otherwise."""
        assert len(data) == 512, f"a sector is 512 B, got {len(data)}"
        assert self.per_queue_storage or qid is None, \
            "qid is only meaningful with per_queue_storage enabled"
        self._storage[self._storage_key(qid if qid is not None else 0, lba)] = bytes(data)

    async def _rst_loop(self):
        """Self-reset on DMA_RST, as the engine this stands in for does. A test that pulses the
        reset without calling reset() would otherwise leave a read still driving across it, and
        that frame's EOF lands after the pulse with its SOF on the far side."""
        prev = "0"
        while True:
            await RisingEdge(self._clk)
            now = str(self._dut.DMA_RST.value)
            if now == "1" and prev != "1":
                self.reset()
            prev = now

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
            accepting = (not self._rd_busy) and (not self._bp_active)
            self._dut.NVME_RD_REQ_RDY.value = ALL_QUEUES_RDY if accepting else 0

            await ReadOnly()
            vld_vec = _as_int(self._dut.NVME_RD_REQ_VLD.value)
            rdy_vec = _as_int(self._dut.NVME_RD_REQ_RDY.value)
            qid = _as_int(self._dut.NVME_RD_REQ_QID.value)

            if vld_vec:
                # The entity promises at most one VLD bit, on bit QID. Checked rather than assumed:
                # a second bit, or a bit off QID, would route the request to the wrong queue's SQ
                # while still looking like a clean handshake here.
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
            meta=(self._inflight_qid << CQ_ENTRY_CMD_ID_W) | self._inflight_cid,
        ))

        # Wait for THIS completion's OP_STAT_VLD to dispatch, not just queue, before re-arming RDY:
        # the address generator steps off that pulse (lfsr_rand_addr_gen_i ENABLE), so re-driving
        # RDY the same edge accepts the next request early, on a stale address.
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
            self._dut.NVME_OP_STAT_QID.value = self._inflight_qid
            self._dut.NVME_OP_STAT_CID.value = self._inflight_cid
            self._dut.NVME_OP_STAT_CODE.value = op_code
            self._dut.NVME_OP_STAT_VLD.value = 1

            await RisingEdge(self._clk)
            self._dut.NVME_OP_STAT_VLD.value = 0

            if done is not None:
                done.set()
