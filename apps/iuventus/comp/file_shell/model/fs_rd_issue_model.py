# fs_rd_issue_model.py: reference model of FS_RD_ISSUE with FS_RD_DATA behind it
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""What the read plane must deliver, from what the DMA did. A read is named by its unique request
(queue, LBA, count), never by the DUT's CID pairing: 01 fails its stream, 10 the rejected
request's stream, 11 every stream."""

from collections import Counter, defaultdict
from dataclasses import dataclass, field

from fs_ctx import CODE_FAIL, CODE_LOST, CODE_OOR, ERR_SRC_NVME, err_info
from fs_rd_data_model import frame_beats


@dataclass
class Expected:
    # stream -> cofs -> KinBeat
    beats: dict = field(default_factory=lambda: defaultdict(dict))
    cdone: Counter = field(default_factory=Counter)
    bytes: Counter = field(default_factory=Counter)
    errors: Counter = field(default_factory=Counter)


def expect(chunks: dict, frames, statuses, lost, streams: int) -> Expected:
    """`chunks`: (qid, lba, nlba) -> Ctx; `frames`: (qid, lba, nlba, data) per delivered frame;
    `statuses`: (code, request key or None, qid, cid) per read status; `lost`: (qid, cid) per
    DATA_LOST report."""
    exp = Expected()
    all_mask = (1 << streams) - 1
    for qid, lba, nlba, data in frames:
        ctx = chunks[(qid, lba, nlba)]
        for b in frame_beats(ctx, data):
            assert b.cofs not in exp.beats[b.stream], f"two chunks of stream {b.stream} cover COFS {b.cofs:#x}"
            exp.beats[b.stream][b.cofs] = b
            exp.bytes[b.stream] += b.nbytes
        exp.cdone[(ctx.stream, ctx.fslot)] += 1
    for code, key, qid, cid in statuses:
        if code == CODE_FAIL:
            exp.errors[(1 << chunks[key].stream, err_info(ERR_SRC_NVME, code, 1, qid, cid))] += 1
        elif code == CODE_OOR:
            exp.errors[(1 << chunks[key].stream, err_info(ERR_SRC_NVME, code, 1, 0, 0))] += 1
    for qid, cid in lost:
        exp.errors[(all_mask, err_info(ERR_SRC_NVME, CODE_LOST, 1, qid, cid))] += 1
    return exp
