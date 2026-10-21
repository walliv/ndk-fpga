# dma_iuventus_mq_model.py: multi-queue, two-endpoint DMA Iuventus stand-in for USER_CORE benches
# that check read data: per-queue tag pools, out-of-order completions, per-endpoint drains.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""DMA_IUVENTUS where it decides whether read data can be attributed (op_ctrl.vhd): one read
admitted at a time, per-queue FIFO tag pools freed at the CQE, out-of-order completions, in-order
per-endpoint drains, DATA_LOST after the frame."""

import random
from collections import deque
from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly

from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

from endpoint_view import EndpointView
from iuventus_data_check import pattern_word

SECT = 512
BEAT = 64
SQE_LBA_PTR_W = 64
CQ_ENTRY_CMD_ID_W = 16
OP_READ, OP_WRITE = 1, 0
CODE_OK, CODE_FAIL, CODE_OOR, CODE_LOST = 0, 1, 2, 3
# An LBA no write has reached reads back as this, so it can never pass for the pattern.
UNWRITTEN = bytes([0xEE]) * SECT


def pattern_sector(qid: int, sector: int) -> bytes:
    """The 512 B a pattern-mode write puts at `sector` of queue `qid` (little-endian words)."""
    return b"".join(pattern_word(qid, sector, w).to_bytes(8, "little") for w in range(SECT // 8))


def _as_int(value):
    try:
        return int(value)
    except ValueError:
        return 0


@dataclass
class ReadCmd:
    qid: int
    lba: int
    num: int
    ep: int
    npages: int
    accept_cycle: int
    cid: int = -1
    due: int = 0
    code: int = CODE_OK
    inject: str = ""
    seq: int = -1


@dataclass
class Frame:
    """One delivered read frame, as the reference model sees it."""
    ep: int
    qid: int
    cid: int
    lba: int
    num: int
    data: bytes
    lost: bool
    inject: str = ""
    sent_cycle: int = 0


@dataclass
class InjectPlan:
    """Read ordinal (in completion order) -> fault: corrupt | stale | swap | lost | fail."""
    faults: dict = field(default_factory=dict)


class MultiQueueDmaModel:

    def __init__(self, dut, clk, num_queues: int, endpoints: int, rng: random.Random,
                 queue_depth: int = 8, pages_per_ep: int = 96, rd_lat=(20, 400), wr_lat=(10, 120),
                 cid_delay=(3, 7), rdy_prob: float = 0.8, wr_rdy_prob: float = 0.85,
                 drain_gaps=True):
        self._dut = dut
        self._clk = clk
        self.nq = num_queues
        self.neps = endpoints
        self.qid_w = max(1, (num_queues - 1).bit_length())
        self.rng = rng
        self.queue_depth = queue_depth
        self.rd_lat = rd_lat
        self.wr_lat = wr_lat
        self.cid_delay = cid_delay
        self.rdy_prob = rdy_prob
        self.wr_rdy_prob = wr_rdy_prob
        self.lost_delay = (2, 40)
        self.plan = InjectPlan()

        self.cycle = 0
        self.storage = {}
        # (cid, first cycle it may be reissued): the DMA's tag FIFO plus the dispatcher's latency.
        self.free_tags = [deque((c, 0) for c in range(queue_depth)) for _ in range(num_queues)]
        self.outstanding = [0] * num_queues
        self.pages_free = [pages_per_ep] * endpoints
        self._npages_all = [63] * num_queues
        self._npages_h = [dut.NVME_RD_REQ_NPAGES_ALL[q] for q in range(num_queues)]
        self._issuing = None
        self._completions = []
        self._cqe_staged = None
        self._lost = [deque() for _ in range(endpoints)]
        self._rd_seq = 0
        # Last value written per signal: most cycles change nothing, and each write costs.
        self._driven = {}

        # Reference-model record of everything that crossed the interface.
        self.accepted = []
        self.cqes = []
        self.frames = []
        self.wr_frames = []
        self.lost_posted = 0
        # Cycles some queue had a request waiting but its endpoint's pages could not admit it.
        self.page_bound_cycles = 0

        dut.NVME_RD_REQ_RDY.value = 0
        dut.NVME_RD_REQ_CID.value = 0
        dut.NVME_RD_REQ_CID_VLD.value = 0
        for sig in ("TYPE", "QID", "CID", "CODE", "VLD"):
            getattr(dut, "NVME_OP_STAT_" + sig).value = 0
        dut.NVME_WR_MFB_DST_RDY.value = 0

        geom = {"regions": 1, "region_size": 1, "block_size": BEAT, "item_width": 8}
        rd_params = dict(geom, meta_width=self.qid_w + CQ_ENTRY_CMD_ID_W)
        wr_params = dict(geom, meta_width=SQE_LBA_PTR_W + self.qid_w)
        self._drivers = [MFBDriver(EndpointView(dut, ep), "NVME_RD_MFB", clk, mfb_params=rd_params,
                                   vld_gen=self._gap_gen() if drain_gaps else None)
                         for ep in range(endpoints)]
        self._wr_mon = MFBMonitor(dut, "NVME_WR_MFB", clk, mfb_params=wr_params,
                                  trans_type=MfbTransactionWithMeta)
        self._wr_mon.add_callback(self._on_wr_frame)
        cocotb.start_soon(self._main_loop())

    # -------------------------------------------------------------------------------------------
    def _gap_gen(self):
        while True:
            yield (self.rng.randint(1, 48), self.rng.choice((0, 0, 0, 1, 1, 2, 5)))

    def _drive(self, sig, val):
        if self._driven.get(sig) != val:
            self._driven[sig] = val
            getattr(self._dut, sig).value = val

    def queue_ep(self, qid: int) -> int:
        return qid // (self.nq // self.neps)

    def seed_pattern(self, qid: int, first: int, count: int) -> None:
        for s in range(first, first + count):
            self.storage[(qid, s)] = pattern_sector(qid, s)

    # Sectors below this read back as the pattern unless written: a filled region without storing it.
    pattern_lbas = 0
    # Index into `accepted` of the first read the DUT's repeat history still remembers (a CLEAR).
    hist_reset_idx = 0

    def _sector(self, qid: int, s: int) -> bytes:
        data = self.storage.get((qid, s))
        if data is None:
            return pattern_sector(qid, s) if s < self.pattern_lbas else UNWRITTEN
        return data

    def read_data(self, qid: int, lba: int, sectors: int) -> bytes:
        return b"".join(self._sector(qid, lba + i) for i in range(sectors))

    def idle(self) -> bool:
        return (self._issuing is None and not self._completions and self._cqe_staged is None
                and not any(self._lost) and all(not d._sendQ and not d._sending for d in self._drivers))

    # -------------------------------------------------------------------------------------------
    def _on_wr_frame(self, trans):
        meta = int(trans.meta)
        qid = (meta >> SQE_LBA_PTR_W) & ((1 << self.qid_w) - 1)
        lba = meta & ((1 << SQE_LBA_PTR_W) - 1)
        data = bytes(trans.data)
        for i in range(len(data) // SECT):
            self.storage[(qid, lba + i)] = data[SECT * i:SECT * (i + 1)]
        self.wr_frames.append((qid, lba, len(data)))
        cmd = ReadCmd(qid=qid, lba=lba, num=len(data) // SECT - 1, ep=self.queue_ep(qid), npages=0,
                      accept_cycle=self.cycle, cid=0)
        cmd.due = self.cycle + self.rng.randint(*self.wr_lat)
        self._completions.append((cmd.due, OP_WRITE, cmd))

    def _frame_sent(self, cmd, data):
        self.pages_free[cmd.ep] += cmd.npages
        lost = cmd.inject == "lost"
        self.frames.append(Frame(ep=cmd.ep, qid=cmd.qid, cid=cmd.cid, lba=cmd.lba, num=cmd.num,
                                 data=data, lost=lost, inject=cmd.inject, sent_cycle=self.cycle))
        if lost:
            q = self._lost[cmd.ep]
            due = self.cycle + self.rng.randint(*self.lost_delay)
            if q:
                due = max(due, q[-1][0])
            q.append((due, cmd.qid, cmd.cid))

    def _frame_data(self, cmd):
        sectors = cmd.num + 1
        data = bytearray(self.read_data(cmd.qid, cmd.lba, sectors))
        if cmd.inject in ("corrupt", "lost"):
            beat = self.rng.randrange(sectors * SECT // BEAT)
            byte = beat * BEAT + self.rng.randrange(BEAT)
            data[byte] ^= 1 << self.rng.randrange(8)
            cmd.inject_beat = beat
        elif cmd.inject == "stale":
            # A page still holding an earlier read: same drive, another block.
            # Whole 4 KiB units inside the region, never a multiple of it, so never the same block.
            other = (cmd.lba + 8 * self.rng.randint(1, self.stale_span // 8 - 1)) % self.stale_span
            data = bytearray(self.read_data(cmd.qid, other, sectors))
        elif cmd.inject == "swap":
            other_q = (cmd.qid + self.rng.randint(1, self.nq - 1)) % self.nq
            data = bytearray(self.read_data(other_q, cmd.lba, sectors))
        return bytes(data)

    stale_span = 1 << 12

    def _post_cqe(self, cmd, op):
        self._drive("NVME_OP_STAT_TYPE", op)
        self._drive("NVME_OP_STAT_QID", cmd.qid)
        self._drive("NVME_OP_STAT_CID", cmd.cid)
        self._drive("NVME_OP_STAT_CODE", cmd.code)
        self._drive("NVME_OP_STAT_VLD", 1)
        self.cqes.append((op, cmd.code, cmd.qid, cmd.cid))
        if op != OP_READ:
            return
        if cmd.code == CODE_OK:
            data = self._frame_data(cmd)
            self._drivers[cmd.ep].append(
                MfbTransactionWithMeta(data=data, meta=(cmd.cid << self.qid_w) | cmd.qid),
                callback=lambda _t, c=cmd, d=data: self._frame_sent(c, d))
        else:
            self.pages_free[cmd.ep] += cmd.npages

    def _select_cqe(self):
        """Pick the next due completion; a read gives its tag back now, a cycle before its status."""
        due = [c for c in self._completions if c[0] <= self.cycle]
        if not due:
            return None
        pick = min(due, key=lambda c: c[0])
        self._completions.remove(pick)
        _, op, cmd = pick
        if op == OP_READ:
            self.outstanding[cmd.qid] -= 1
            self.free_tags[cmd.qid].append((cmd.cid, self.cycle + 2))
            cmd.seq = self._rd_seq
            self._rd_seq += 1
            fault = self.plan.faults.get(cmd.seq, "")
            if fault == "fail":
                cmd.code = CODE_FAIL
            else:
                cmd.inject = fault
        return (op, cmd)

    async def _main_loop(self):
        dut = self._dut
        while True:
            await RisingEdge(self._clk)
            self.cycle += 1
            if str(dut.DMA_RST.value) == "1":
                continue

            # OP_STAT: the staged completion, else the oldest due DATA_LOST report.
            vld_before = self._driven.get("NVME_OP_STAT_VLD")
            self._driven["NVME_OP_STAT_VLD"] = 0
            if self._cqe_staged is not None:
                op, cmd = self._cqe_staged
                self._post_cqe(cmd, op)
            else:
                for q in self._lost:
                    if q and q[0][0] <= self.cycle:
                        _, qid, cid = q.popleft()
                        self._drive("NVME_OP_STAT_TYPE", OP_READ)
                        self._drive("NVME_OP_STAT_QID", qid)
                        self._drive("NVME_OP_STAT_CID", cid)
                        self._drive("NVME_OP_STAT_CODE", CODE_LOST)
                        self._drive("NVME_OP_STAT_VLD", 1)
                        self.lost_posted += 1
                        break
            if self._driven["NVME_OP_STAT_VLD"] == 0 and vld_before != 0:
                dut.NVME_OP_STAT_VLD.value = 0
            self._cqe_staged = self._select_cqe()

            # CID of the accepted read, once its delay passed and its queue's head tag is free.
            cid_vld = 0
            cmd = self._issuing
            if cmd is not None and self.cycle >= cmd.due:
                tags = self.free_tags[cmd.qid]
                if tags and tags[0][1] <= self.cycle:
                    cmd.cid = tags.popleft()[0]
                    self._drive("NVME_RD_REQ_CID", cmd.cid)
                    cid_vld = 1
                    cmd.due = self.cycle + self.rng.randint(*self.rd_lat)
                    self._completions.append((cmd.due, OP_READ, cmd))
                    self._issuing = None

            # Admission: one read at a time, a few beyond the tag pool so a read can wait for a tag.
            rdy = 0
            if self._issuing is None:
                page_bound = False
                for q in range(self.nq):
                    ep = self.queue_ep(q)
                    pages_ok = self.pages_free[ep] >= self._npages_all[q]
                    page_bound |= self._npages_all[q] != 63 and not pages_ok
                    if (self.outstanding[q] < self.queue_depth + 1 and pages_ok
                            and self.rng.random() < self.rdy_prob):
                        rdy |= 1 << q
                self.page_bound_cycles += page_bound
            self._drive("NVME_RD_REQ_CID_VLD", cid_vld)
            self._drive("NVME_RD_REQ_RDY", rdy)
            self._drive("NVME_WR_MFB_DST_RDY", int(self.rng.random() < self.wr_rdy_prob))

            await ReadOnly()
            self._npages_all = [_as_int(h.value) for h in self._npages_h]
            vld = _as_int(dut.NVME_RD_REQ_VLD.value)
            if vld & rdy:
                qid = _as_int(dut.NVME_RD_REQ_QID.value)
                assert vld == (1 << qid), f"NVME_RD_REQ_VLD={vld:b} does not match QID={qid}"
                num = _as_int(dut.NVME_RD_REQ_LBA_NUM.value)
                cmd = ReadCmd(qid=qid, lba=_as_int(dut.NVME_RD_REQ_LBA_PTR.value), num=num,
                              ep=self.queue_ep(qid), npages=(num + 8) // 8, accept_cycle=self.cycle)
                cmd.due = self.cycle + self.rng.randint(*self.cid_delay)
                self.outstanding[qid] += 1
                self.pages_free[cmd.ep] -= cmd.npages
                self._issuing = cmd
                self.accepted.append(cmd)
