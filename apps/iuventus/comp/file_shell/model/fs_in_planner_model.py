# fs_in_planner_model.py: reference model of FS_IN_PLANNER, one stream's input list to read chunks
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Cuts each extent at stripe chunk boundaries and at the end of its file's bytes. A malformed list,
or one whose extents cover fewer bytes than a file's SIZE, stops at that entry."""

from collections import Counter
from dataclasses import dataclass, field

from fs_ctx import (ENT_EXTENT, ENT_FILE, FOFS_W, FSLOTS, MASK64, SECT, Ctx, decode_entry,
                    lbas_needed, stripe_drive, stripe_drive_lba)


@dataclass(frozen=True)
class Chunk:
    qid: int
    lba: int
    nlba: int
    ctx: Ctx
    # Ordinal of the chunk's file in the list.
    file: int


@dataclass
class Plan:
    chunks: list = field(default_factory=list)
    # Chunk count of every opened file, in list order (a still-open file has its count so far).
    file_chunks: list = field(default_factory=list)
    # 1-based index of the entry that stopped the list, None if none.
    error: int | None = None
    # The LAST entry was reached without an error.
    done: bool = False

    @property
    def files(self) -> int:
        return len(self.file_chunks)

    @property
    def requests(self) -> Counter:
        """The reads the DMA must see: (drive, drive LBA, NLBA) -> count."""
        return Counter((c.qid, c.lba, c.nlba) for c in self.chunks)


def plan(entries, log2_drives: int, log2_chunk: int, stream: int) -> Plan:
    out = Plan()
    cs = 1 << log2_chunk
    open_file = None

    for idx, ent in enumerate(entries, 1):
        e = decode_entry(ent)
        if (e["rsvd"] or e["type"] not in (ENT_EXTENT, ENT_FILE)
                or (e["type"] == ENT_EXTENT and (open_file is None or e["count"] == 0 or e["lba_hi"]))
                or (e["type"] == ENT_FILE and e["size"] >> FOFS_W)):
            out.error = idx
            return out

        if e["type"] == ENT_FILE:
            if open_file is not None and open_file["fr_lbas"]:
                out.error = idx
                return out
            cofs_base = 0 if open_file is None else open_file["cofs_base"] + open_file["size"]
            size = e["size"]
            open_file = {"ord": out.files, "slot": out.files % FSLOTS, "index": e["index"], "size": size,
                         "fr_lbas": lbas_needed(size), "pad": (SECT - size % SECT) % SECT, "fofs": 0,
                         "cofs_base": cofs_base}
            out.file_chunks.append(0)
            if e["last"]:
                if open_file["fr_lbas"]:
                    out.error = idx
                    return out
                out.done = True
                return out
            continue

        f = open_file
        if f["fr_lbas"] == 0:
            if e["last"]:
                out.done = True
                return out
            continue
        lba, rem = e["lba"], e["count"]
        bnd = cs - (lba % cs)
        while True:
            m1 = min(rem, bnd)
            n = min(m1, f["fr_lbas"])
            n_last = f["fr_lbas"] <= m1
            n_ext_end = rem <= m1 and rem <= f["fr_lbas"]
            vbytes = n * SECT - (f["pad"] if n_last else 0)
            ctx = Ctx(stream=stream, fslot=f["slot"], fidx=f["index"], fofs=f["fofs"],
                      cofs=(f["cofs_base"] + f["fofs"]) & MASK64, vbytes=vbytes)
            out.chunks.append(Chunk(qid=stripe_drive(lba, log2_drives, log2_chunk),
                                    lba=stripe_drive_lba(lba, log2_drives, log2_chunk), nlba=n - 1, ctx=ctx,
                                    file=f["ord"]))
            out.file_chunks[f["ord"]] += 1
            lba += n
            rem -= n
            f["fr_lbas"] -= n
            f["fofs"] += n * SECT
            bnd = cs if n == bnd else bnd - n
            if n_last:
                if e["last"]:
                    out.done = True
                    return out
                break
            if n_ext_end:
                if e["last"]:
                    out.error = idx
                    return out
                break
    return out


def retired_files(plan_: Plan, done_per_file: list, closed: int) -> int:
    """Files retired in order: every file before the first one still owed chunks or still open."""
    n = 0
    while n < closed and done_per_file[n] == plan_.file_chunks[n]:
        n += 1
    return n
