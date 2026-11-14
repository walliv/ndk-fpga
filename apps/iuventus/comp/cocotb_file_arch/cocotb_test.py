# cocotb_test.py: system bench of the file shell, USER_CORE(FILE) against the DMA, drives and HBM
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Stage A: random jobs as the C++ Job issues them, on a random logical volume striped over 1, 2 or 4
drives; the drives' contents, counters and status words are checked against file_shell_model.
Every job that fails is followed by a clean one after CLEAR."""

import os
import tempfile

import cocotb

import file_shell_model as fm
import fs_ctx as fc
from dma_iuventus_mq_model import CODE_FAIL, CODE_OOR, OP_READ
from fs_bench import FileShellBench, JobRun, file_sizes, make_job, random_geometry
import fs_exfat
from fs_out_writer_model import output_breakers, plan_writes
from fs_in_planner_model import plan as plan_reads
from fs_tb_util import seeded

SCALE = float(os.environ.get("FS_SCALE", "1.0"))


async def bench_for(dut, salt, **kw):
    rng = seeded(salt)
    tb = FileShellBench(dut, rng, **kw)
    await tb.start()
    return tb


def job(tb, **kw):
    kw.setdefault("fill_max", int(80_000 * SCALE))
    return make_job(tb.rng, tb.vol, **kw)


# Failing jobs and the clean job after each are kept small: the test's point is the error path.
SMALL = {"fill_max": int(40_000 * SCALE), "files": (1, 4)}


async def clean(tb, **kw):
    j = await tb.run(job(tb, **kw))
    tb.check_clean(j)
    return j


def n_reads(tb, j):
    return sum(sum(c.values()) for c in tb.expect_inputs(j))


def chunk_owner(j, qid, lba, num):
    for s, sj in enumerate(j.streams):
        for c in plan_reads(sj.in_entries, j.ld, j.lc, s).chunks:
            if (c.qid, c.lba, c.nlba) == (qid, lba, num):
                return s
    raise AssertionError(f"read drive {qid} LBA {lba:#x} x{num + 1} belongs to no stream")


def job_with_reads(tb, **kw):
    while True:
        j = job(tb, **kw)
        if n_reads(tb, j) >= 2:
            return j


# =================================================================================================
@cocotb.test()
async def test_clean_jobs(dut):
    """Back-to-back random jobs: 1-8 streams, several files each, multi-extent and size-0 files,
    partial last LBAs, output reservations of any fit."""
    tb = await bench_for(dut, 0x101)
    for _ in range(max(1, int(3 * SCALE))):
        await clean(tb)


@cocotb.test()
async def test_need_space(dut):
    """Every output reservation is too small: the job pauses on NEED_SPACE until the driver
    appends extents and raises OUT_TAIL."""
    tb = await bench_for(dut, 0x202)
    for _ in range(max(1, int(3 * SCALE))):
        j = await clean(tb, tight_out=True)
        assert j.extensions > 0, "no NEED_SPACE was served"


@cocotb.test()
async def test_read_errors(dut):
    """Read 01 and 10 fail the read's own stream, 11 every stream; then a clean job after CLEAR."""
    tb = await bench_for(dut, 0x303)
    for kind in tb.rng.sample(["fail", "oor", "lost"], 3):
        j = job_with_reads(tb, **SMALL)
        k = tb.rng.randrange(n_reads(tb, j))
        if kind == "oor":
            tb.dma.oor_accepts = {len(tb.dma.accepted) + k}
        else:
            tb.dma.plan.faults = {tb.dma._rd_seq + k: kind}
        await tb.run(j)
        tb.dma.oor_accepts = set()
        tb.dma.plan.faults = {}
        st = tb.dma.status_log[tb.st0:]
        if kind == "fail":
            (qid, lba, num, cid), = [(q, l, n, c) for op, code, q, l, n, c in st if op == OP_READ and code == CODE_FAIL]
            must = {chunk_owner(j, qid, lba, num): fm.info_nvme(1, 1, qid, cid)}
        elif kind == "oor":
            (qid, lba, num), = [(q, l, n) for op, code, q, l, n, c in st if op == OP_READ and code == CODE_OOR]
            must = {chunk_owner(j, qid, lba, num): fm.info_nvme(2, 1, 0, 0)}
        else:
            (f,), = [[f for f in tb.dma.frames if f.lost]]
            must = {s: fm.info_nvme(3, 1, f.qid, f.cid) for s in range(len(j.streams))}
            f.lost = False
        tb.check_error(j, must)
        await clean(tb, **SMALL)


@cocotb.test()
async def test_write_errors(dut):
    """Write 01/11 on drive d fail every stream with a write outstanding on d (the failed write's own
    included) and may fail only streams that wrote to d since FS_WR_ARB's queue d last drained;
    10 may fail every stream with a write outstanding anywhere."""
    tb = await bench_for(dut, 0x404)
    for code in tb.rng.sample([1, 2, 3], 3):
        while True:
            j = job(tb, **SMALL)
            nw = sum(len(plan_writes(sj.output(), [fc.extent_entry(*e) for e in sj.out_extents + sj.extend_extents],
                                     j.ld, j.lc)[0]) for sj in j.streams)
            if nw >= 2:
                break
        tb.dma.wr_faults = {tb.dma.wr_seq + tb.rng.randrange(min(nw, 6)): code}
        await tb.run(j)
        tb.dma.wr_faults = {}
        (qid, lba, code_seen), = [(q, l, c) for q, l, n, c in tb.dma.wr_log[tb.wr0:] if c]
        assert code_seen == code
        own = tb.writes_of(j)
        if code == 2:
            info = fm.info_nvme(2, 0, 0, 0)
            must = set()
            may = {s for s in own.values()}
        else:
            (cid,), = [[c for op, cd, q, l, n, c in tb.dma.status_log[tb.st0:] if op == 0 and cd == code]]
            info = fm.info_nvme(code, 0, qid, cid)
            (outst,), = [tb.dma.wr_fault_outstanding[tb.wf0:]]
            must = {own[w] for w in outst}
            (snap_q, snap_code, touched), = tb.wr_arb.snaps[tb.ws0:]
            assert (snap_q, snap_code) == (qid, code), f"FS_WR_ARB saw write error {snap_code} on queue {snap_q}"
            may = {s for s in range(len(j.streams)) if touched >> s & 1}
            assert must <= may, f"streams {must - may} had writes outstanding on drive {qid} but never wrote to it"
        failed = {s for s, r in enumerate(j.regs) if r["status"] & fc.SS_ERR}
        assert failed, "a failed write failed no stream"
        tb.log.info(f"write error {code} on drive {qid}: must fail {sorted(must)}, may {sorted(may)}, "
                    f"failed {sorted(failed)}")
        tb.check_error(j, {s: info for s in must}, may={s: info for s in may})
        await clean(tb, **SMALL)


@cocotb.test()
async def test_abort(dut):
    """ABORT mid-job fails every enabled stream with source ABORT; nothing in flight is cut."""
    tb = await bench_for(dut, 0x505)
    for _ in range(max(1, int(3 * SCALE))):
        j = job(tb, **SMALL)
        j.abort_after = tb.rng.randint(0, 5_000)
        await tb.run(j)
        if j.status & fc.ST_DONE:
            tb.log.info("job finished before ABORT")
            tb.check_clean(j)
        else:
            tb.check_error(j, {s: fm.INFO_ABORT for s in range(len(j.streams))})
        await clean(tb, **SMALL)


@cocotb.test()
async def test_format_errors(dut):
    """Bad STRIPE, a kernel's bad arguments, a malformed input or output entry and a failed ring
    write in HBM, each followed by a clean job."""
    tb = await bench_for(dut, 0x606)
    rng = tb.rng
    cases = ["stripe", "args", "input", "output", "hbm"]
    rng.shuffle(cases)
    for case in cases:
        j = job(tb, **SMALL)
        n = len(j.streams)
        if case == "stripe":
            j.ld, j.lc = rng.choice(((2, 0), (2, 9), (3, 8), (2, 15)))
            must = {s: fm.INFO_START for s in range(n)}
        elif case == "args":
            s = rng.randrange(n)
            sj = j.streams[s]
            j.args[s] = [sj.fill_bytes + rng.randint(1, 63), 0, sj.seed]
            must = {s: fm.INFO_START}
        elif case == "input":
            s = rng.randrange(n)
            sj = j.streams[s]
            while True:
                ents = list(sj.in_entries)
                k = rng.randrange(len(ents))
                ents[k] = rng.choice((lambda e: e & ~(fc.MASK32 << fc.WORD2_LO) & ~(3 << fc.TYPE_LO),   # EXTENT, COUNT 0
                                      lambda e: e | (2 << fc.TYPE_LO),
                                      lambda e: e | fc.rsvd_bit(rng),
                                      lambda e: e | fc.lba_hi_bit(rng)))(ents[k])
                pl = plan_reads(ents, j.ld, j.lc, s)
                if pl.error:
                    break
            sj.in_entries = ents
            must = {s: fm.info_input_format(pl.error)}
        elif case == "output":
            s = rng.randrange(n)
            sj = j.streams[s]
            exts = sj.out_extents
            k = rng.randrange(len(exts))
            bad_ent = rng.choice(output_breakers(rng))(fc.extent_entry(*exts[k]))
            j.bad_out = (s, k, bad_ent)
            ents = [fc.extent_entry(*e) for e in exts]
            ents[k] = bad_ent
            _, popped, bad = plan_writes(sj.output(), ents, j.ld, j.lc)
            must = {s: fm.info_output_format(popped)} if bad else None
        else:
            # Entry 0 of stream 0's input ring is written with SLVERR.
            tb.poison.add(fc.IN_RING_BASE - fc.OUT_RING_BASE)
            must = {s: fm.INFO_HBM for s in range(n)}
        await tb.run(j)
        tb.poison.clear()
        if must is None:
            tb.log.info("the malformed output entry was never needed")
            tb.check_clean(j)
        else:
            tb.check_error(j, must)
        await clean(tb, **SMALL)


# =================================================================================================
# Stage B
# =================================================================================================
@cocotb.test(skip=not fs_exfat.available())
async def test_exfat_image(dut):
    """A job on a real exFAT volume: iuv-exfat puts the inputs (into fragmented free space) and
    reserves the outputs; after the job the drives are merged back, the outputs finalized with
    OUT_BYTES, and fsck.exfat and `iuv-exfat get` must agree with DIGEST_FILL."""
    tb = await bench_for(dut, 0x707)
    rng = tb.rng
    ld, lc = random_geometry(rng)
    with tempfile.TemporaryDirectory(dir=os.getcwd()) as d:
        img = fs_exfat.ExfatImage(d, rng)
        img.fragment(rng.randint(4, 24))
        names = []
        for s in range(rng.randint(1, 8)):
            files = []
            for f in range(rng.randint(1, 5)):
                data = rng.randbytes(file_sizes(rng))
                img.put(data, f"/s{s}_f{f}.bin")
                files.append((f"/s{s}_f{f}.bin", data))
            names.append(files)
        streams = []
        for s, files in enumerate(names):
            infiles = []
            for name, data in files:
                size, exts = img.extents(name)
                assert size == len(data), f"{name}: extents reports size {size}, put {len(data)}"
                img.load_extents(tb.dma.storage, exts, ld, lc)
                infiles.append(fm.InFile(data=data, extents=exts))
            sj = fm.StreamJob(files=infiles, out_extents=[], extend_extents=[],
                              fill_bytes=64 * rng.randint(0, int(4000 * SCALE)), seed=rng.randrange(1 << 32))
            sj.build_entries()
            sj.out_extents = img.reserve(f"/out{s}", len(sj.output()))
            streams.append(sj)
        j = JobRun(streams=streams, ld=ld, lc=lc, preloaded=True)
        await tb.run(j)
        tb.check_clean(j)
        for s, sj in enumerate(streams):
            img.merge_extents(tb.dma.storage, sj.out_extents, ld, lc)
            img.finalize(f"/out{s}", j.regs[s]["out_bytes"])
        report = img.fsck()
        for s, sj in enumerate(streams):
            got = img.get(f"/out{s}")
            assert got == sj.output(), f"/out{s}: {len(got)} B read back, {len(sj.output())} B expected"
            for name, data in names[s]:
                assert img.get(name) == data, f"{name} changed"
        n_ext = sum(len(f.extents) for sj in streams for f in sj.files)
        n_out = sum(len(sj.out_extents) for sj in streams)
        tb.log.info(f"exFAT image OK: {len(streams)} outputs finalized, {n_ext} input and {n_out} output "
                    f"extents, fsck: {report.splitlines()[-1].split(': ')[-1] if report else ''}")
