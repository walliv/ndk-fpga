# fs_out_writer_model.py: reference model of FS_OUT_WRITER, the writes one stream's output becomes
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from dataclasses import dataclass

from fs_ctx import (ENT_EXTENT, LAST, MASK32, MAX_LOG2_CHUNK, MAX_LOG2_DRIVES, SECT, TYPE_LO, WORD2_LO, decode_entry,
                    lba_hi_bit, lbas_needed, rsvd_bit, stripe_drive, stripe_drive_lba)


@dataclass(frozen=True)
class Write:
    qid: int
    lba: int
    nlba0: int
    nbytes: int
    data: bytes

    def __repr__(self):
        return (f"Write(qid={self.qid}, lba={self.lba:#x}, nlba0={self.nlba0}, nbytes={self.nbytes}, "
                f"data[{len(self.data)}]={self.data[:8].hex()}..)")


def entry_ok(ent):
    e = decode_entry(ent)
    return e["type"] == ENT_EXTENT and e["last"] == 0 and e["rsvd"] == 0 and e["lba_hi"] == 0 and e["count"] != 0


def output_breakers(rng):
    """Ways to make an output extent entry malformed: TYPE FILE, LAST, a reserved bit, COUNT 0, an LBA bit
    above bit 47."""
    return [lambda e: e | (1 << TYPE_LO),
            lambda e: e | LAST,
            lambda e: e | rsvd_bit(rng),
            lambda e: e & ~(MASK32 << WORD2_LO),
            lambda e: e | lba_hi_bit(rng)]


def plan_writes(out, entries, log2_drives, log2_chunk):
    """(writes in issue order, entries popped, malformed) for output `out` into ring `entries`; an
    entry is popped only while output remains unwritten, and a malformed one ends the plan."""
    log2_drives = min(log2_drives, MAX_LOG2_DRIVES)
    log2_chunk = min(log2_chunk, MAX_LOG2_CHUNK)
    chunk = 1 << log2_chunk
    writes = []
    pos = 0
    popped = 0
    for ent in entries:
        if pos >= len(out):
            break
        popped += 1
        if not entry_ok(ent):
            return writes, popped, True
        e = decode_entry(ent)
        cur, rem = e["lba"], e["count"]
        while rem > 0 and pos < len(out):
            n = min(rem, chunk - cur % chunk)
            nbytes = min(n * SECT, len(out) - pos)
            nlba = lbas_needed(nbytes)
            data = out[pos:pos + nbytes] + bytes(nlba * SECT - nbytes)
            writes.append(Write(stripe_drive(cur, log2_drives, log2_chunk),
                                stripe_drive_lba(cur, log2_drives, log2_chunk), nlba - 1, nbytes, data))
            pos += nbytes
            cur += n
            rem -= n
    return writes, popped, False
