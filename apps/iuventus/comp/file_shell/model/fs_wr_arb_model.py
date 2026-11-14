# fs_wr_arb_model.py: reference model of FS_WR_ARB's completion attribution
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque
from dataclasses import dataclass

from fs_ctx import CODE_OK, CODE_OOR, ERR_SRC_NVME, MASK64, err_info


@dataclass(frozen=True)
class WErr:
    mask: int
    info: int


class FsWrArbModel:
    """Per queue a FIFO of (stream, nbytes) in grant order, popped by each write completion, and the
    streams granted on the queue since it last drained. An error on a queue names those streams, an
    out-of-range status and WR_OUTSTANDING every stream of any queue. Feed a cycle's grants before its
    status: the RTL reads the FIFOs a cycle later, with that grant in."""

    def __init__(self, streams, num_queues):
        self.streams = streams
        self.fifo = [deque() for _ in range(num_queues)]
        self.touched = [0] * num_queues
        self.out_bytes = [0] * streams
        # The stream the last status popped, None when it popped nothing.
        self.popped = None

    def grant(self, stream, qid, nbytes):
        self.fifo[qid].append((stream, nbytes))
        self.touched[qid] |= 1 << stream

    def outstanding_mask(self):
        """The streams WR_OUTSTANDING flags: those granted on a queue that has not drained since."""
        mask = 0
        for touched in self.touched:
            mask |= touched
        return mask

    def op_stat(self, op_type, code, qid, cid):
        """Returns the WErr the status raises, or None."""
        self.popped = None
        if op_type != 0:
            return None
        if code == CODE_OOR:
            return WErr(self.outstanding_mask(), err_info(ERR_SRC_NVME, code, 0, 0, 0))
        queue = self.fifo[qid]
        mask = self.touched[qid]
        assert queue, f"write completion on queue {qid} with no write outstanding"
        stream, nbytes = queue.popleft()
        if not queue:
            self.touched[qid] = 0
        self.popped = stream
        if code == CODE_OK:
            self.out_bytes[stream] = (self.out_bytes[stream] + nbytes) & MASK64
            return None
        return WErr(mask, err_info(ERR_SRC_NVME, code, 0, qid, cid))

    def queue_len(self, qid):
        return len(self.fifo[qid])
