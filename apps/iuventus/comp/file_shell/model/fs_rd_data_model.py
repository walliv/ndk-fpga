# fs_rd_data_model.py: reference model of FS_RD_DATA, one read frame to kernel beats
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Beat k of a frame covers file bytes FOFS+64k.. with min(64, VBYTES-64k) valid bytes; beats
wholly past VBYTES are not delivered."""

from dataclasses import dataclass

from fs_ctx import BEAT, COFS_W, FOFS_W, SECT, Ctx


@dataclass(frozen=True)
class KinBeat:
    stream: int
    data: bytes
    nbytes: int
    fidx: int
    fofs: int
    cofs: int


def frame_beats(ctx: Ctx, data: bytes) -> list:
    """Kernel beats of one frame, in delivery order."""
    assert len(data) % SECT == 0 and len(data) >= ctx.vbytes > len(data) - SECT, \
        f"frame of {len(data)} B cannot carry VBYTES={ctx.vbytes}"
    beats = []
    for k in range(len(data) // BEAT):
        left = ctx.vbytes - BEAT * k
        if left <= 0:
            break
        beats.append(KinBeat(stream=ctx.stream, data=data[BEAT * k:BEAT * (k + 1)], nbytes=min(BEAT, left),
                             fidx=ctx.fidx, fofs=(ctx.fofs + BEAT * k) & ((1 << FOFS_W) - 1),
                             cofs=(ctx.cofs + BEAT * k) & ((1 << COFS_W) - 1)))
    return beats


def valid_bytes(beat: KinBeat) -> bytes:
    """Only the valid prefix is defined; the rest of a partial beat is whatever the frame held."""
    return beat.data[:beat.nbytes]
