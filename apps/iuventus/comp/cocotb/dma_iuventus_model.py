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

# QID_W, matching user_core_test_arch.vhd's `maximum(1, log2(NUM_QUEUES))` (ceil-log2, log2(1)=0
# by this codebase's math_pack convention). Needed for NVME_WR_MFB_META's width (SQE_LBA_PTR_W(64)
# + QID_W bits per region -- see user_core_test_arch.vhd's nvme_wr_mfb_meta_g).
_NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))
QID_W = max(1, (_NUM_QUEUES - 1).bit_length())
SQE_LBA_PTR_W = 64

# USER_CORE's default MFB geometry (DMA_MFB_REGIONS/REGION_SIZE/BLOCK_SIZE/ITEM_WIDTH generics,
# unchanged by this harness). Passed explicitly to MFBDriver/MFBMonitor rather than relying on
# their auto-inference (get_mfb_params(), cocotbext/ofm/mfb/utils.py): that helper assumes
# EOF_POS's width alone encodes BLOCK_SIZE (2**eof_pos_bits), but this entity's EOF_POS instead
# encodes log2(REGION_SIZE*BLOCK_SIZE) (see user_core_ent.vhd's NVME_*_MFB_EOF_POS port width) --
# auto-inference silently derives a wrong, too-large "block_size" (64 instead of 8) and then an
# _item_width of 1, which fails MFBDriver's `assert item_width % 8 == 0`. meta_width must also be
# given explicitly: without a "meta_width" key, get_mfb_params() silently defaults it to 0, so the
# monitor never populates trans.meta at all (it just stays at MfbTransactionWithMeta's own
# dataclass default, 0) -- surfacing only as a wrong-looking LBA_PTR/QID, not an error.
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
    """

    def __init__(self, dut, clk, rd_latency_cycles: int = 2, wr_latency_cycles: int = 2):
        self._dut = dut
        self._clk = clk
        self.rd_latency_cycles = rd_latency_cycles
        self.wr_latency_cycles = wr_latency_cycles

        self.rd_req_accept_cb = None   # (lba_ptr, lba_num, qid) -> None
        self.wr_frame_accept_cb = None  # (MfbTransactionWithMeta) -> None

        self._rd_busy = False
        self._op_stat_pending = []  # list of (type, code, done_event_or_None) awaiting dispatch, FIFO

        dut.NVME_RD_REQ_RDY.value = 1
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

    def reset(self) -> None:
        """Clears this model's own in-flight/pending state. Call after pulsing a fresh DMA_RST
        mid-simulation (e.g. between directed sub-scenarios sharing one cocotb test) so a stray
        in-flight request/completion from a previous scenario can't leak into the next one."""
        self._rd_busy = False
        self._op_stat_pending.clear()
        self._dut.NVME_RD_REQ_RDY.value = 1
        self._dut.NVME_OP_STAT_VLD.value = 0

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
            self._dut.NVME_RD_REQ_RDY.value = int(not self._rd_busy)

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

            cocotb.start_soon(self._service_read(lba_num))

    async def _service_read(self, lba_num: int):
        for _ in range(self.rd_latency_cycles):
            await RisingEdge(self._clk)

        total_bytes = (lba_num + 1) * 512
        pattern = bytes([i & 0xFF for i in range(total_bytes)])
        await self._rd_mfb_driver.send(pattern)

        # Wait for THIS completion's own OP_STAT_VLD pulse to actually be dispatched (not just
        # queued) before re-arming RDY. The RTL's seq_addr_cntr/QID round-robin advance
        # synchronously off NVME_OP_STAT_VLD; if RDY were re-driven high on the very same edge
        # (e.g. by clearing `_rd_busy` right after enqueuing, with `_op_stat_loop` also polling
        # that same queue on the very next RisingEdge), the NEXT request could get accepted on
        # that exact same edge -- one cycle before the address/QID counters' own registered
        # increment has settled, so the next request would observe the STALE pre-increment
        # value. The extra RisingEdge below (past OP_STAT_VLD's deassertion) gives that increment
        # a full cycle to settle before RDY is allowed to go high again.
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
        cocotb.start_soon(self._service_write())

    async def _service_write(self):
        for _ in range(self.wr_latency_cycles):
            await RisingEdge(self._clk)
        # No `_rd_busy`-style single-outstanding gate exists on the write side (DST_RDY is held
        # high throughout), so there is no analogous "next accept races the completion" hazard --
        # a completion event is not needed here.
        self._op_stat_pending.append((OP_STAT_TYPE_WRITE, OP_STAT_CODE_SUCCESS, None))

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
