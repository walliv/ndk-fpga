# file_shell_model.py: reference model of the whole file shell, composed from the plane models
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""What one job must leave behind: the reads the planners cut, the kernel's output, the writes the
writers make of it (and so every byte on the drives), the counters and the status words. Errors
follow the host model's rules (ERR_INFO = first error naming the stream)."""

from collections import Counter
from dataclasses import dataclass, field

from fs_ctx import (CODE_OOR, ERR_SRC_ABORT, ERR_SRC_FORMAT, ERR_SRC_HBM, ERR_SRC_NVME, LAST, STREAM_BASE, STREAM_STRIDE,
                    err_info, extent_entry, file_entry, sector)
from fs_in_planner_model import plan as plan_reads
from fs_kernel_digest_fill_model import file_digest, pattern_bytes, record_bytes
from fs_out_writer_model import plan_writes

# FS_CTRL's job states, as STATUS reports them.
STATE_IDLE, STATE_RUN, STATE_DRAIN, STATE_DONE, STATE_ERR = range(5)

# ERR_INFO words the RTL and the host model agree on.
INFO_START = err_info(ERR_SRC_FORMAT, 0, 0, 0, 0)
INFO_ABORT = err_info(ERR_SRC_ABORT, 0, 0, 0, 0)
INFO_HBM = err_info(ERR_SRC_HBM, 0, 0, 0, 0)


def sreg(s, off):
    return STREAM_BASE + s * STREAM_STRIDE + off


def info_input_format(idx):
    return err_info(ERR_SRC_FORMAT, 0, 1, 0, idx)


def info_output_format(idx):
    return err_info(ERR_SRC_FORMAT, 0, 0, 0, idx)


def info_nvme(code, is_read, drive, cid):
    if code == CODE_OOR:
        return err_info(ERR_SRC_NVME, code, is_read, 0, 0)
    return err_info(ERR_SRC_NVME, code, is_read, drive, cid)


@dataclass
class InFile:
    data: bytes
    # (logical LBA, count) runs covering at least ceil(size/512) LBAs.
    extents: list


@dataclass
class StreamJob:
    files: list
    # Output extents the host has reserved before START, and those it adds on NEED_SPACE.
    out_extents: list
    extend_extents: list
    fill_bytes: int
    seed: int
    # Input ring entries: built from the files unless a test breaks one.
    in_entries: list = field(default_factory=list)

    def build_entries(self):
        ents = []
        for f, inf in enumerate(self.files):
            ents.append(file_entry(len(inf.data), f))
            for lba, cnt in inf.extents:
                ents.append(extent_entry(lba, cnt))
        ents[-1] |= LAST
        self.in_entries = ents
        return ents

    def output(self):
        dig = file_digest([(f, inf.data) for f, inf in enumerate(self.files)])
        return pattern_bytes(self.fill_bytes, self.seed) + record_bytes(*dig)


@dataclass
class StreamExpect:
    chunks: Counter
    in_bytes: int
    in_files: int
    out: bytes
    # (qid, drive LBA) -> 512 B sector the job must leave on the drive.
    sectors: dict
    writes: list
    out_head: int
    in_head: int


def expect_stream(sj: StreamJob, stream, log2_drives, log2_chunk, out_entries):
    """The clean outcome of one stream; `out_entries` is every output entry the host published."""
    pl = plan_reads(sj.in_entries, log2_drives, log2_chunk, stream)
    assert pl.done and pl.error is None, f"stream {stream}: the input list is not well formed"
    out = sj.output()
    writes, popped, bad = plan_writes(out, out_entries, log2_drives, log2_chunk)
    assert not bad and sum(w.nbytes for w in writes) == len(out), f"stream {stream}: output does not fit"
    sectors = {}
    for w in writes:
        for i in range(w.nlba0 + 1):
            sectors[(w.qid, w.lba + i)] = sector(w.data, i)
    return StreamExpect(chunks=pl.requests,
                        in_bytes=sum(len(f.data) for f in sj.files), in_files=len(sj.files), out=out,
                        sectors=sectors, writes=writes, out_head=popped, in_head=len(sj.in_entries))
