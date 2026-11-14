# fs_dma_model.py: the shared multi-queue DMA model plus the faults the file shell benches inject
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Out-of-range read rejections and failing writes, which MultiQueueDmaModel lacks: a chosen accept
gets no CID but a TYPE 1 / CODE 10 status with garbage QID/CID before the DMA admits the next
read, and a chosen write completes with a failing code."""

from dma_iuventus_mq_model import CODE_FAIL, CODE_LOST, CODE_OK, CODE_OOR, OP_READ, OP_WRITE, MultiQueueDmaModel, ReadCmd

from fs_ctx import SECT, sector


class FsDma(MultiQueueDmaModel):
    """`status_log`: (op, code, qid, lba, num, cid) per status; `wr_log`: (qid, lba, bytes, code) per
    write frame; `wr_faults`: write sequence number -> code."""

    def __init__(self, *args, oor_accepts=(), **kwargs):
        self.oor_accepts = set(oor_accepts)
        self.wr_faults = {}
        self.wr_seq = 0
        self.status_log = []
        self.wr_log = []
        # Per failed write (01/11): (qid, lba) of every write outstanding on its drive, its own included.
        self.wr_fault_outstanding = []
        super().__init__(*args, **kwargs)

    # Reads rejected as out of range ---------------------------------------------------------------
    def _select_cqe(self):
        cmd = self._issuing
        if cmd is not None and getattr(cmd, "oor_state", 0) == 2 and self.cycle >= cmd.oor_free:
            self._issuing = None
        if cmd is not None and getattr(cmd, "oor_state", 0) == 0 and cmd.cid < 0:
            if self.accepted and self.accepted[-1] is cmd and len(self.accepted) - 1 in self.oor_accepts:
                cmd.oor_state = 1
                cmd.oor_at = cmd.due
                cmd.due = 1 << 60
        if cmd is not None and getattr(cmd, "oor_state", 0) == 1 and self.cycle >= cmd.oor_at:
            if not any(c[0] <= self.cycle for c in self._completions):
                cmd.oor_state = 2
                cmd.oor_free = self.cycle + 2
                cmd.code = CODE_OOR
                self.outstanding[cmd.qid] -= 1
                return (OP_READ, cmd)
        return super()._select_cqe()

    def _post_cqe(self, cmd, op):
        if cmd.code == CODE_OOR:
            real_qid, real_cid = cmd.qid, cmd.cid
            cmd.qid = self.rng.randrange(self.nq)
            cmd.cid = self.rng.randrange(1 << 16)
            super()._post_cqe(cmd, op)
            self.status_log.append((op, CODE_OOR, real_qid, cmd.lba, cmd.num, 0))
            cmd.qid, cmd.cid = real_qid, real_cid
            return
        super()._post_cqe(cmd, op)
        self.status_log.append((op, cmd.code, cmd.qid, cmd.lba, cmd.num, cmd.cid))
        if op == OP_WRITE and cmd.code in (CODE_FAIL, CODE_LOST):
            self.wr_fault_outstanding.append({(c.qid, c.lba) for _, o, c in self._completions
                                              if o == OP_WRITE and c.qid == cmd.qid} | {(cmd.qid, cmd.lba)})

    # Writes, optionally failing ------------------------------------------------------------------
    def _on_wr_frame(self, trans):
        meta = int(trans.meta)
        qid = (meta >> 64) & ((1 << self.qid_w) - 1)
        lba = meta & ((1 << 64) - 1)
        data = bytes(trans.data)
        n = self.wr_seq
        self.wr_seq += 1
        code = self.wr_faults.get(n, CODE_OK)
        if code == CODE_OK:
            for i in range(len(data) // SECT):
                self.storage[(qid, lba + i)] = sector(data, i)
        self.wr_frames.append((qid, lba, len(data)))
        self.wr_log.append((qid, lba, len(data), code))
        cmd = ReadCmd(qid=qid, lba=lba, num=len(data) // SECT - 1, ep=self.queue_ep(qid), npages=0,
                      accept_cycle=self.cycle, cid=self.rng.randrange(64))
        cmd.code = code
        cmd.due = self.cycle + self.rng.randint(*self.wr_lat)
        self._completions.append((cmd.due, OP_WRITE, cmd))
