# cocotb_test.py: does FS_IN_PLANNER cut every input list into exactly the model's chunks?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Random lists and stripe geometries under entry gaps, CREQ backpressure and out-of-order
completions on two lanes: the chunk sequence, in-order retirement, the 64-slot window, errors."""

import os

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

from fs_ctx import (ENT_FILE, ERR_SRC_FORMAT, FSLOTS, LAST, SECT, STRIPE_RST_CHUNK, STRIPE_RST_DRIVES, Ctx,
                    decode_entry, err_info, extent_entry, file_entry, lbas_needed)
from fs_in_planner_model import Chunk, plan, retired_files
from fs_tb_util import as_int, release_reset, seeded, start_clock

STREAM_IDX = int(os.environ.get("STREAM_IDX", "5"))
CDONE_LANES = int(os.environ.get("CDONE_LANES", "2"))
NUM_QUEUES = 4


def gen_list(rng, nfiles, lc, size_lbas=6):
    """A valid list: per file a FILE, then extents covering its bytes in random pieces, sometimes
    with LBAs and whole extents past the end of the file."""
    entries = []
    for _ in range(nfiles):
        kind = rng.random()
        if kind < 0.1:
            size = 0
        elif kind < 0.3:
            size = rng.choice((1, 63, 64, 511, 512, 513, 1023, 1024, 4096))
        else:
            size = rng.randrange(1, size_lbas * (1 << lc) * SECT + 1)
        entries.append(file_entry(size, rng.randrange(1 << 32)))
        need = lbas_needed(size)
        pieces = []
        while need > 0:
            n = rng.randint(1, need)
            pieces.append(n)
            need -= n
        if pieces and rng.random() < 0.5:
            pieces[-1] += rng.choice((1, 2, 7, 300, 1 << 20, (1 << 32) - 1 - pieces[-1]))
        if (pieces or size == 0) and rng.random() < 0.2:
            pieces.append(rng.randint(1, 50))
        for n in pieces:
            entries.append(extent_entry(rng.randrange((1 << 48) - n), n))
    if entries:
        entries[-1] |= LAST
    return entries


def file_close_points(entries):
    """1-based index of the entry whose decode closes each file: the next FILE or the LAST."""
    files = [i for i, e in enumerate(entries, 1) if decode_entry(e)["type"] == ENT_FILE]
    return files[1:] + [len(entries)]


class PlannerBench:

    def __init__(self, dut, rng):
        self.dut = dut
        self.rng = rng
        self.ent_q = []
        self.ent_vld = 0
        self.ent_gap = 0
        self.popped = 0
        self.creq_rdy_prob = 0.7
        self.enable_off_prob = 0.0
        self.enable = 1
        self.cd_delay = (1, 60)
        self.chunks = []
        self.pending_cd = []
        self.lane_free = [0] * CDONE_LANES
        self.cd_sent = 0
        self.done_per_file = []
        self.err = []
        self.kernel_end = []
        self.in_done_cycle = None
        self.files_hw = 0
        self.cycle = 0
        self.plan = None
        self.close_pts = []
        self.violations = []

    def load(self, entries, ld, lc):
        self.ent_q = list(entries)
        # An entry a stopped list left on the bus belongs to that list, not to this one.
        self.ent_vld = 0
        self.ent_gap = 0
        self.popped = 0
        self.chunks = []
        self.pending_cd = []
        self.cd_sent = 0
        self.err = []
        self.kernel_end = []
        self.in_done_cycle = None
        self.files_hw = 0
        self.plan = plan(entries, ld, lc, STREAM_IDX)
        self.done_per_file = [0] * max(1, self.plan.files)
        self.close_pts = file_close_points(entries)

    def closed_files(self):
        return sum(1 for p in self.close_pts[:self.plan.files] if self.popped >= p)

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.CLK)
            await Timer(1, unit="ns")
            self.cycle += 1
            if self.enable_off_prob:
                if self.enable and self.rng.random() < self.enable_off_prob:
                    self.enable = 0
                elif not self.enable and self.rng.random() < 0.2:
                    self.enable = 1
                dut.ENABLE.value = self.enable
            if not self.ent_vld and self.ent_q:
                if self.ent_gap:
                    self.ent_gap -= 1
                else:
                    dut.ENT_DATA.value = self.ent_q[0]
                    self.ent_vld = 1
            dut.ENT_VLD.value = self.ent_vld
            dut.CREQ_RDY.value = int(self.rng.random() < self.creq_rdy_prob)
            vld = 0
            due = [c for c in self.pending_cd if c[0] <= self.cycle]
            for lane in range(CDONE_LANES):
                if due and self.lane_free[lane] <= self.cycle:
                    c = due.pop(self.rng.randrange(len(due)))
                    self.pending_cd.remove(c)
                    vld |= 1 << lane
                    dut.CDONE_FSLOT[lane].value = c[1]
                    self.lane_free[lane] = self.cycle + 2
                    self.done_per_file[c[2]] += 1
                    self.cd_sent += 1
            dut.CDONE_VLD.value = vld

            await ReadOnly()
            if self.ent_vld and as_int(dut.ENT_RDY):
                assert self.enable, "an entry was taken while ENABLE was low"
                self.ent_q.pop(0)
                self.popped += 1
                self.ent_vld = 0
                self.ent_gap = self.rng.choice((0, 0, 0, 1, 2, 5))
            if as_int(dut.CREQ_VLD):
                assert self.enable, "a chunk was offered while ENABLE was low"
                if as_int(dut.CREQ_RDY):
                    self._take_chunk()
            files_hw = as_int(dut.IN_FILES)
            assert files_hw >= self.files_hw, "IN_FILES went backwards"
            self.files_hw = files_hw
            if self.plan is not None:
                bound = retired_files(self.plan, self.done_per_file, self.closed_files())
                if files_hw > bound:
                    self.violations.append(f"cycle {self.cycle}: IN_FILES {files_hw} > retirable {bound}")
            if as_int(dut.ERR):
                self.err.append((self.cycle, as_int(dut.ERR_INFO)))
            if as_int(dut.KERNEL_END):
                self.kernel_end.append(self.cycle)
            if as_int(dut.IN_DONE) and self.in_done_cycle is None:
                self.in_done_cycle = self.cycle

    def _take_chunk(self):
        dut = self.dut
        i = len(self.chunks)
        got = Chunk(qid=as_int(dut.CREQ_QID), lba=as_int(dut.CREQ_LBA), nlba=as_int(dut.CREQ_NLBA),
                    ctx=Ctx.unpack(as_int(dut.CREQ_CTX)), file=-1)
        assert i < len(self.plan.chunks), f"chunk {i} beyond the model's {len(self.plan.chunks)}: {got}"
        exp = self.plan.chunks[i]
        assert (got.qid, got.lba, got.nlba, got.ctx) == (exp.qid, exp.lba, exp.nlba, exp.ctx), \
            f"chunk {i}: got {got}, expected {exp}"
        # Slot reuse: file k may open only once file k-64 retired.
        assert self.files_hw >= exp.file - (FSLOTS - 1), \
            f"file {exp.file} issued while only {self.files_hw} files retired"
        self.chunks.append(got)
        self.pending_cd.append((self.cycle + self.rng.randint(*self.cd_delay), exp.ctx.fslot, exp.file))

    async def job(self, entries, ld, lc, timeout=400_000):
        dut = self.dut
        await RisingEdge(dut.CLK)
        await Timer(1, unit="ns")
        dut.CLEAR.value = 1
        await RisingEdge(dut.CLK)
        await Timer(1, unit="ns")
        dut.CLEAR.value = 0
        self.load(entries, ld, lc)
        dut.STRIPE_LOG2_DRIVES.value = ld
        dut.STRIPE_LOG2_CHUNK.value = lc
        dut.START.value = 1
        await RisingEdge(dut.CLK)
        await Timer(1, unit="ns")
        dut.START.value = 0
        for _ in range(timeout // 50):
            await ClockCycles(dut.CLK, 50)
            settled = not self.pending_cd and self.cd_sent == len(self.chunks)
            if self.plan.error is not None and self.err and settled:
                break
            if self.plan.error is None and self.in_done_cycle is not None:
                break
        await ClockCycles(dut.CLK, 20)
        self.check()

    def check(self):
        p = self.plan
        assert not self.violations, self.violations[:3]
        assert len(self.chunks) == len(p.chunks), f"{len(self.chunks)} chunks issued, model {len(p.chunks)}"
        if p.error is not None:
            exp = err_info(ERR_SRC_FORMAT, 0, 1, 0, p.error)
            assert len(self.err) == 1, f"ERR pulsed {len(self.err)} times, expected once at entry {p.error}"
            assert self.err[0][1] == exp, f"ERR_INFO {self.err[0][1]:#x}, expected {exp:#x} (entry {p.error})"
            assert self.in_done_cycle is None and not self.kernel_end, "IN_DONE after an error"
            return
        assert p.done, "the model never reached LAST"
        assert not self.err, f"unexpected ERR {self.err}"
        assert self.in_done_cycle is not None, "IN_DONE never rose"
        assert self.kernel_end == [self.in_done_cycle], f"KERNEL_END {self.kernel_end}, IN_DONE at {self.in_done_cycle}"
        assert self.files_hw == p.files, f"IN_FILES {self.files_hw}, model {p.files}"
        assert self.cd_sent == len(p.chunks), "IN_DONE before every chunk came back"


async def start(dut, salt):
    start_clock(dut)
    dut.RESET.value = 1
    for sig in ("CLEAR", "START", "ENT_VLD", "CREQ_RDY", "CDONE_VLD"):
        getattr(dut, sig).value = 0
    dut.ENABLE.value = 1
    dut.ENT_DATA.value = 0
    dut.STRIPE_LOG2_DRIVES.value = STRIPE_RST_DRIVES
    dut.STRIPE_LOG2_CHUNK.value = STRIPE_RST_CHUNK
    for lane in range(CDONE_LANES):
        dut.CDONE_FSLOT[lane].value = 0
    bench = PlannerBench(dut, seeded(salt))
    await release_reset(dut, 10, 5)
    cocotb.start_soon(bench.run())
    return bench


@cocotb.test()
async def test_random_lists(dut):
    """Jobs over every stripe geometry: drive counts 1/2/4, chunks of 1 to 256 LBAs."""
    bench = await start(dut, 0x401)
    rng = bench.rng
    geoms = [(ld, lc) for ld in range(3) for lc in range(9)] * 3
    rng.shuffle(geoms)
    for ld, lc in geoms:
        entries = gen_list(rng, rng.randint(1, 25), lc)
        bench.creq_rdy_prob = rng.choice((0.3, 0.7, 1.0))
        await bench.job(entries, ld, lc)
        dut._log.info(f"ld={ld} lc={lc}: {len(entries)} entries, {bench.plan.files} files, "
                      f"{len(bench.chunks)} chunks")


@cocotb.test()
async def test_enable_gating(dut):
    """ENABLE dropping at random holds entries and chunks and loses nothing."""
    bench = await start(dut, 0x402)
    bench.enable_off_prob = 0.05
    for _ in range(4):
        lc = bench.rng.choice((2, 8))
        await bench.job(gen_list(bench.rng, 10, lc), 2, lc)
    bench.enable_off_prob = 0.0
    bench.enable = 1
    dut.ENABLE.value = 1


@cocotb.test()
async def test_file_window(dut):
    """More small files than slots, completions slow: a FILE waits for its slot and the files
    still retire in order."""
    bench = await start(dut, 0x403)
    bench.cd_delay = (200, 3000)
    bench.creq_rdy_prob = 1.0
    rng = bench.rng
    entries = []
    for _ in range(200):
        entries.append(file_entry(rng.choice((0, 1, 300, 512, 1000)), rng.randrange(1 << 32)))
        if (entries[-1] & ((1 << 64) - 1)) > 0:
            entries.append(extent_entry(rng.randrange(1 << 40), 2))
    entries[-1] |= LAST
    await bench.job(entries, 1, 3, timeout=2_000_000)


def malformed(rng, kind, lc):
    """A valid prefix, then one bad entry (or a short file) of the given kind."""
    entries = gen_list(rng, rng.randint(0, 3), lc) if kind != "ext_first" else []
    if entries:
        entries[-1] &= ~LAST
    if kind == "ext_first":
        entries.append(extent_entry(5, 3))
        return entries
    entries.append(file_entry(3 * SECT + 5, 77))
    if kind == "count0":
        entries.append(extent_entry(100, 0))
    elif kind == "type":
        entries.append(extent_entry(100, 4, etype=rng.choice((2, 3))))
    elif kind == "rsvd":
        entries.append(extent_entry(100, 4, rsvd=1 << rng.randrange(29)))
    elif kind == "lba_hi":
        entries.append(extent_entry(100, 4, hi=1 << rng.randrange(16)))
    elif kind == "size_hi":
        entries.append(file_entry(1 << rng.randrange(48, 64), 3))
    elif kind == "short_file":
        entries.append(extent_entry(100, 2))
        entries.append(file_entry(10, 4))
    elif kind == "short_last":
        entries.append(extent_entry(100, 3, last=True))
    elif kind == "file_last":
        entries.append(extent_entry(100, 4))
        entries.append(file_entry(1, 9, last=True))
    entries.append(extent_entry(9, 9, last=True))
    return entries


@cocotb.test()
async def test_malformed_lists(dut):
    """Each malformed kind stops the list at its entry with a FORMAT error."""
    bench = await start(dut, 0x404)
    rng = bench.rng
    kinds = ["ext_first", "count0", "type", "rsvd", "lba_hi", "size_hi", "short_file", "short_last",
             "file_last"]
    rng.shuffle(kinds)
    for kind in kinds:
        lc = rng.choice((0, 4, 8))
        entries = malformed(rng, kind, lc)
        await bench.job(entries, rng.randrange(3), lc)
        assert bench.plan.error is not None, f"{kind}: the model accepted the list"
        dut._log.info(f"{kind}: error at entry {bench.plan.error} of {len(entries)}, {len(bench.chunks)} chunks")
