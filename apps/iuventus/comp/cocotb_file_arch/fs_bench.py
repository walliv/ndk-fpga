# fs_bench.py: environment of the file shell system bench: DMA and drives, HBM, MI job driver
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""USER_CORE(FILE) between the shared multi-queue DMA model (one storage array per drive),
cocotbext-axi's AxiRam on the HBM port and MIRequestDriver on MI. The job driver issues exactly the
MI sequence of the C++ Job (submit, then wait serving NEED_SPACE)."""

from collections import Counter
from dataclasses import dataclass, field

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotbext.axi import AxiBus
from cocotbext.ofm.mi.drivers import MIRequestDriver

from dma_iuventus_mq_model import CODE_FAIL, CODE_LOST, CODE_OK, CODE_OOR
import file_shell_model as fm
import fs_ctx as fc
from fs_axi_util import PoisonRam, pause_channels, quiet, use_axi3_len
from fs_dma_model import FsDma
from fs_in_planner_model import plan as plan_reads
from fs_out_writer_model import plan_writes
from fs_tb_util import as_int, start_wall_cap

use_axi3_len()

NUM_QUEUES = 4
EPS = 2
HBM_SIZE = 1 << 24
DMA_NS, MI_NS, USR_NS = 4, 10, 5
MAX_WAIT_CYCLES = 3_000_000


class WrArbQueueTracker:
    """Per queue, the streams FS_WR_ARB granted a write on since the queue last held no write, from
    its grant and engine-side status ports: the most a write error on that queue may name."""

    def __init__(self, dut, clk):
        self.shell = dut.file_shell_i
        self.clk = clk
        self.snaps = []
        self._reset()
        cocotb.start_soon(self._run())

    def _reset(self):
        self.count = [0] * NUM_QUEUES
        self.touched = [0] * NUM_QUEUES
        self.pending = None

    async def _run(self):
        sh = self.shell
        while True:
            await RisingEdge(self.clk)
            if as_int(sh.eng_rst) or as_int(sh.plane_clear):
                self._reset()
                continue
            if self.pending is not None:
                code, q = self.pending
                if code in (CODE_FAIL, CODE_LOST):
                    self.snaps.append((q, code, self.touched[q]))
                if self.count[q]:
                    self.count[q] -= 1
                    if not self.count[q]:
                        self.touched[q] = 0
                self.pending = None
            gnt = as_int(sh.wreq_rdy)
            for s in range(fc.MAX_STREAMS):
                if gnt >> s & 1:
                    q = as_int(sh.wreq_qid[s])
                    self.count[q] += 1
                    self.touched[q] |= 1 << s
            if as_int(sh.eng_op_stat_vld) and not as_int(sh.eng_op_stat_type):
                code = as_int(sh.eng_op_stat_code)
                if code != CODE_OOR:
                    self.pending = (code, as_int(sh.eng_op_stat_qid))


# =================================================================================================
# Logical volume: RAID0 of 1, 2 or 4 drives drawn per job, a bump allocator with random gaps
# =================================================================================================
class Volume:
    def __init__(self, rng, ld=fc.STRIPE_RST_DRIVES, lc=fc.STRIPE_RST_CHUNK):
        self.rng = rng
        self.ld = ld
        self.lc = lc
        self.cur = rng.randrange(0, 4096)

    def alloc(self, nlbas, max_runs=1):
        """Disjoint runs covering `nlbas` LBAs at random, unaligned positions."""
        runs = []
        left = nlbas
        nruns = min(left, self.rng.randint(1, max_runs))
        for k in range(nruns):
            cnt = left if k == nruns - 1 else self.rng.randint(1, left - (nruns - 1 - k))
            self.cur += self.rng.choice((0, 1, 7, 100, 255, 256, 1000))
            runs.append((self.cur, cnt))
            self.cur += cnt
            left -= cnt
        return runs

    def drive_lba(self, lba):
        return fc.stripe_map(lba, self.ld, self.lc)


def file_sizes(rng):
    return rng.choice((0, 1, 63, 64, 65, 511, 512, 513, 4096, rng.randint(1, 2000),
                       rng.randint(1, 40_000), rng.randint(40_000, 300_000)))


def random_stream(rng, vol: Volume, nfiles, fill_max, tight_out=False):
    files = []
    for _ in range(nfiles):
        size = file_sizes(rng)
        nl = fc.lbas_needed(size)
        exts = vol.alloc(nl + rng.choice((0, 0, 0, 1, 3)), max_runs=4) if nl else []
        files.append(fm.InFile(data=rng.randbytes(size), extents=exts))
    fill = 64 * rng.randint(0, fill_max // 64)
    if tight_out:
        fill = max(fill, fc.SECT)  # one LBA would fit in the first reservation and never raise NEED_SPACE
    need = fc.lbas_needed(fill + 32)
    if tight_out or rng.random() < 0.3:
        first = rng.randint(1, max(1, need - 1)) if need > 1 else 1
        out = vol.alloc(first, max_runs=2)
        more = need - first + rng.choice((0, 0, 1, 9))
        ext = vol.alloc(max(1, more), max_runs=3)
    else:
        out = vol.alloc(need + rng.choice((0, 0, 1, 17, 300)), max_runs=3)
        ext = vol.alloc(rng.randint(1, 40), max_runs=1)
    sj = fm.StreamJob(files=files, out_extents=out, extend_extents=ext, fill_bytes=fill,
                      seed=rng.randrange(1 << 32))
    sj.build_entries()
    return sj


# =================================================================================================
# The bench
# =================================================================================================
@dataclass
class JobRun:
    streams: list
    ld: int = fc.STRIPE_RST_DRIVES
    lc: int = fc.STRIPE_RST_CHUNK
    # Raw kernel arguments per stream, overriding the stream's FILL_BYTES/SEED (bad arguments).
    args: dict = field(default_factory=dict)
    out_entries: list = field(default_factory=list)
    abort_after: int = None
    # (stream, index, entry): an output ring entry published in place of the planned one.
    bad_out: tuple = None
    # The drives already hold the inputs (an image striped onto them).
    preloaded: bool = False
    status: int = 0
    regs: list = field(default_factory=list)
    extensions: int = 0


class FileShellBench:

    def __init__(self, dut, rng, dma_kw=None, hbm_pause=0.2):
        self.dut = dut
        self.rng = rng
        self.log = dut._log
        self.vol = Volume(rng)
        self.poison = set()
        dma_kw = dict(dma_kw or {})
        dma_kw.setdefault("queue_depth", rng.choice((8, 16, 64)))
        dma_kw.setdefault("rdy_prob", rng.choice((0.3, 0.7, 0.95)))
        dma_kw.setdefault("wr_rdy_prob", rng.choice((0.3, 0.7, 0.95)))
        dma_kw.setdefault("rd_lat", (10, rng.choice((100, 400, 1500))))
        dma_kw.setdefault("wr_lat", (10, rng.choice((60, 300))))
        self.dma_kw = dma_kw
        self.hbm_pause = hbm_pause

    async def start(self):
        dut = self.dut
        cocotb.start_soon(Clock(dut.DMA_CLK, DMA_NS, unit="ns").start())
        cocotb.start_soon(Clock(dut.MI_CLK, MI_NS, unit="ns").start())
        cocotb.start_soon(Clock(dut.USR_CLK, USR_NS, unit="ns").start())
        start_wall_cap(dut.DMA_CLK)
        dut.DMA_RST.value = 1
        dut.MI_RST.value = 1
        dut.USR_RST.value = 1
        dut.HBM_RESET.value = 1
        dut.HBM_READY.value = 0
        dut.PCIE_LINK_UP.value = 1
        dut.FPGA_ID.value = 0
        dut.FPGA_ID_VLD.value = 0
        self.dma = FsDma(dut, dut.DMA_CLK, NUM_QUEUES, EPS, self.rng, **self.dma_kw)
        self.ram = PoisonRam(AxiBus.from_prefix(dut, "HBM_AXI"), dut.DMA_CLK, dut.HBM_RESET, HBM_SIZE, self.poison,
                             poison_reads=False)
        quiet(self.ram)
        pause_channels(self.ram, self.rng, self.hbm_pause)
        self.mi = MIRequestDriver(dut, "MI", dut.MI_CLK)
        self.wr_arb = WrArbQueueTracker(dut, dut.DMA_CLK)
        await ClockCycles(dut.DMA_CLK, 30)
        dut.DMA_RST.value = 0
        dut.MI_RST.value = 0
        dut.USR_RST.value = 0
        dut.HBM_RESET.value = 0
        await ClockCycles(dut.DMA_CLK, 40)
        dut.HBM_READY.value = 1
        await ClockCycles(dut.DMA_CLK, 10)

    # MI ------------------------------------------------------------------------------------------
    async def rd(self, addr):
        return await self.mi.read32(addr)

    async def wr(self, addr, val):
        await self.mi.write32(addr, val & 0xFFFFFFFF)

    def cycle(self):
        return self.dma.cycle

    # Drives --------------------------------------------------------------------------------------
    def seed_inputs(self, job: JobRun):
        for sj in job.streams:
            for inf in sj.files:
                pos = 0
                for lba, cnt in inf.extents:
                    for i in range(cnt):
                        chunk = inf.data[pos:pos + fc.SECT]
                        pos += fc.SECT
                        sect = chunk + self.rng.randbytes(fc.SECT - len(chunk))
                        q, dl = fc.stripe_map(lba + i, self.vol.ld, self.vol.lc)
                        self.dma.storage[(q, dl)] = sect

    # The C++ Job ---------------------------------------------------------------------------------
    async def push_ring(self, s, ring_base, cap, tail, take, head_reg, tail_reg):
        """Writes the entries `take()` hands out (None once none is left) into the free slots of a ring,
        then its new TAIL; returns the TAIL."""
        head = await self.rd(fm.sreg(s, head_reg))
        used = (tail - head) & fc.MASK32
        free = cap - used if used < cap else 0
        before = tail
        while free > 0 and (ent := take()) is not None:
            for w, word in enumerate(fc.entry_words(ent)):
                await self.wr(ring_base + (tail % cap) * fc.ENTRY_BYTES + 4 * w, word)
            tail += 1
            free -= 1
        if tail != before:
            await self.wr(fm.sreg(s, tail_reg), tail)
        return tail

    async def submit(self, job: JobRun):
        assert await self.rd(fc.REG_VERSION) == 1
        assert await self.rd(fc.REG_KERNEL_ID) == 1
        depths = await self.rd(fc.REG_RING_DEPTHS)
        self.in_cap = 1 << (depths & 0xFF)
        self.out_cap = 1 << ((depths >> 8) & 0xFF)
        self.in_tail = [0] * len(job.streams)
        self.out_tail = [0] * len(job.streams)
        self.out_pending = [[fc.extent_entry(lba, cnt) for lba, cnt in sj.out_extents] for sj in job.streams]
        if job.bad_out is not None:
            s, k, ent = job.bad_out
            self.out_pending[s][k] = ent
        self.ext_pending = [list(sj.extend_extents) for sj in job.streams]
        job.out_entries = [[] for _ in job.streams]
        await self.wr(fc.REG_CTRL, fc.CTRL_CLEAR)
        mask = 0
        for s, sj in enumerate(job.streams):
            await self.push_inputs(job, s)
            await self.push_outputs(job, s)
            args = job.args.get(s, [sj.fill_bytes & 0xFFFFFFFF, sj.fill_bytes >> 32, sj.seed])
            for w, a in enumerate(args):
                await self.wr(fc.ARGS_BASE + s * fc.ARGS_STRIDE + 4 * w, a)
            mask |= 1 << s
        await self.wr(fc.REG_STRIPE, job.ld | (job.lc << 8))
        await self.wr(fc.REG_STREAM_MASK, mask)
        self.start_cycle = self.cycle()
        await self.wr(fc.REG_CTRL, fc.CTRL_START)

    async def push_inputs(self, job, s):
        sj = job.streams[s]
        if self.in_tail[s] >= len(sj.in_entries):
            return
        entries = iter(sj.in_entries[self.in_tail[s]:])
        self.in_tail[s] = await self.push_ring(s, fc.IN_RING_BASE + s * fc.IN_RING_STRIDE, self.in_cap,
                                               self.in_tail[s], lambda: next(entries, None), fc.S_IN_HEAD,
                                               fc.S_IN_TAIL)

    async def push_outputs(self, job, s):
        pend = self.out_pending[s]
        if not pend:
            return

        def take():
            if not pend:
                return None
            ent = pend.pop(0)
            job.out_entries[s].append(ent)
            return ent

        self.out_tail[s] = await self.push_ring(s, fc.OUT_RING_BASE + s * fc.OUT_RING_STRIDE, self.out_cap,
                                                self.out_tail[s], take, fc.S_OUT_HEAD, fc.S_OUT_TAIL)

    async def wait(self, job: JobRun, poll=300):
        """The C++ Job::wait(): returns once DONE or ERR, and once the shell is idle again."""
        n = len(job.streams)
        aborted = False
        next_log = self.start_cycle + 50_000
        while True:
            if self.cycle() >= next_log:
                next_log += 50_000
                self.log.info(f"job running, {self.cycle() - self.start_cycle} cycles, STATUS "
                              f"{await self.rd(fc.REG_STATUS):#x}")
            if self.cycle() - self.start_cycle > MAX_WAIT_CYCLES:
                raise AssertionError(f"job did not finish in {MAX_WAIT_CYCLES} cycles, STATUS "
                                     f"{await self.rd(fc.REG_STATUS):#x}")
            if job.abort_after is not None and not aborted and self.cycle() - self.start_cycle >= job.abort_after:
                await self.wr(fc.REG_CTRL, fc.CTRL_ABORT)
                aborted = True
                self.abort_cycle = self.cycle()
            status = await self.rd(fc.REG_STATUS)
            if status & (fc.ST_DONE | fc.ST_ERR):
                job.status = status
                break
            assert status & fc.ST_BUSY, f"the shell went idle without DONE or ERR, STATUS {status:#x}"
            for s in range(n):
                await self.push_inputs(job, s)
                if (status & fc.ST_NEED_SPACE and not self.out_pending[s]
                        and await self.rd(fm.sreg(s, fc.S_STATUS)) & fc.SS_NEED_SPACE
                        and await self.rd(fm.sreg(s, fc.S_OUT_HEAD)) == self.out_tail[s]):
                    assert self.ext_pending[s], f"stream {s}: NEED_SPACE with no extension left"
                    lba, cnt = self.ext_pending[s].pop(0)
                    self.out_pending[s].append(fc.extent_entry(lba, cnt))
                    job.extensions += 1
                await self.push_outputs(job, s)
            await ClockCycles(self.dut.DMA_CLK, self.rng.randint(1, poll))
        job.regs = []
        for s in range(n):
            r = {}
            for name, off in (("status", fc.S_STATUS), ("err_info", fc.S_ERR_INFO), ("in_files", fc.S_IN_FILES),
                              ("in_head", fc.S_IN_HEAD), ("out_head", fc.S_OUT_HEAD)):
                r[name] = await self.rd(fm.sreg(s, off))
            r["out_bytes"] = await self.rd(fm.sreg(s, fc.S_OUT_BYTES_LO))
            r["out_bytes"] |= await self.rd(fm.sreg(s, fc.S_OUT_BYTES_HI)) << 32
            r["in_bytes"] = await self.rd(fm.sreg(s, fc.S_IN_BYTES_LO))
            r["in_bytes"] |= await self.rd(fm.sreg(s, fc.S_IN_BYTES_HI)) << 32
            job.regs.append(r)
        return job

    async def run(self, job: JobRun):
        if not job.preloaded:
            self.seed_inputs(job)
        self.acc0 = len(self.dma.accepted)
        self.wr0 = len(self.dma.wr_log)
        self.st0 = len(self.dma.status_log)
        self.wf0 = len(self.dma.wr_fault_outstanding)
        self.ws0 = len(self.wr_arb.snaps)
        await self.submit(job)
        await self.wait(job)
        # DMA quiet before the next job, so every completion of this one is in the logs.
        for _ in range(2000):
            if self.dma.idle():
                break
            await ClockCycles(self.dut.DMA_CLK, 50)
        assert self.dma.idle(), "DMA model still busy after the job"
        return job

    # Checks --------------------------------------------------------------------------------------
    def expect_inputs(self, job):
        """Read chunks per stream; the output side is known only once the job published its rings."""
        return [plan_reads(sj.in_entries, job.ld, job.lc, s).requests for s, sj in enumerate(job.streams)]

    def expect(self, job):
        return [fm.expect_stream(sj, s, job.ld, job.lc, job.out_entries[s]) for s, sj in enumerate(job.streams)]

    def check_clean(self, job):
        exps = self.expect(job)
        mask = (1 << len(job.streams)) - 1
        assert job.status == fc.ST_DONE | (fm.STATE_DONE << 8), f"STATUS {job.status:#x}, expected DONE"
        for s, (e, r) in enumerate(zip(exps, job.regs)):
            assert r["status"] == fc.SS_IN_DONE | fc.SS_OUT_DONE, f"stream {s}: STREAM_STATUS {r['status']:#x}"
            assert r["err_info"] == 0, f"stream {s}: ERR_INFO {r['err_info']:#x}"
            assert r["in_files"] == e.in_files, f"stream {s}: IN_FILES {r['in_files']} != {e.in_files}"
            assert r["in_bytes"] == e.in_bytes, f"stream {s}: IN_BYTES {r['in_bytes']} != {e.in_bytes}"
            assert r["out_bytes"] == len(e.out), f"stream {s}: OUT_BYTES {r['out_bytes']} != {len(e.out)}"
            assert r["in_head"] == e.in_head, f"stream {s}: IN_HEAD {r['in_head']} != {e.in_head}"
            assert r["out_head"] == e.out_head, f"stream {s}: OUT_HEAD {r['out_head']} != {e.out_head}"
        reads = Counter((c.qid, c.lba, c.num) for c in self.dma.accepted[self.acc0:])
        want = Counter()
        for e in exps:
            want += e.chunks
        assert reads == want, f"the DMA saw {sum(reads.values())} reads, the planners cut {sum(want.values())}"
        self.check_writes(exps, job, clean=True)
        self.log.info(f"job OK: {1 << job.ld} drives, {1 << job.lc}-LBA chunks, {len(job.streams)} streams (mask {mask:#x}), "
                      f"{sum(len(sj.files) for sj in job.streams)} files, "
                      f"{sum(e.in_bytes for e in exps)} B in, {sum(len(e.out) for e in exps)} B out, "
                      f"{sum(reads.values())} reads, {len(self.dma.wr_log) - self.wr0} writes, "
                      f"{job.extensions} extensions, {self.cycle() - self.start_cycle} cycles")

    def check_writes(self, exps, job, clean):
        """Every write frame is one the writers plan, in full; on a clean job all of them landed."""
        planned = {}
        for s, e in enumerate(exps):
            for w in e.writes:
                planned[(w.qid, w.lba)] = (s, w)
        seen = set()
        for qid, lba, nbytes, code in self.dma.wr_log[self.wr0:]:
            assert (qid, lba) in planned, f"write to drive {qid} LBA {lba:#x} the job never planned"
            s, w = planned[(qid, lba)]
            assert nbytes == (w.nlba0 + 1) * fc.SECT, f"write to drive {qid} LBA {lba:#x}: {nbytes} B"
            assert (qid, lba) not in seen, f"write to drive {qid} LBA {lba:#x} issued twice"
            seen.add((qid, lba))
            if code == CODE_OK:
                for i in range(w.nlba0 + 1):
                    assert self.dma.storage.get((qid, lba + i)) == fc.sector(w.data, i), \
                        f"stream {s}: drive {qid} LBA {lba + i:#x} holds the wrong bytes"
        if clean:
            assert seen == set(planned), f"{len(set(planned) - seen)} planned writes never reached the DMA"

    def writes_of(self, job):
        """(qid, lba) -> stream of this job's write frames."""
        own = {}
        for s, e in enumerate(self.expect_partial(job)):
            for w in e:
                own[(w.qid, w.lba)] = s
        return own

    def expect_partial(self, job):
        """Planned writes per stream, tolerating output rings the job never finished filling."""
        out = []
        for s, sj in enumerate(job.streams):
            writes, _, _ = plan_writes(sj.output(), job.out_entries[s], self.vol.ld, self.vol.lc)
            out.append(writes)
        return out

    def check_error(self, job, expect_info, may=None):
        """`expect_info`: stream -> the ERR_INFO it must fail with; `may`: stream -> the ERR_INFO it
        fails with if it fails at all. Every other stream must not fail."""
        assert job.status == fc.ST_ERR | (fm.STATE_ERR << 8), f"STATUS {job.status:#x}, expected ERR"
        may = may or {}
        for s, r in enumerate(job.regs):
            exp = expect_info.get(s)
            if exp is None and s in may and r["status"] & fc.SS_ERR:
                exp = may[s]
            if exp is None:
                assert not r["status"] & fc.SS_ERR and r["err_info"] == 0, \
                    f"stream {s}: STREAM_STATUS {r['status']:#x} ERR_INFO {r['err_info']:#x}, expected no error"
            else:
                ok = r["err_info"] in exp if isinstance(exp, (set, frozenset)) else r["err_info"] == exp
                assert r["status"] & fc.SS_ERR and ok, \
                    f"stream {s}: STREAM_STATUS {r['status']:#x} ERR_INFO {r['err_info']:#x}, expected {exp}"
        # Whatever was written before the error is a planned write, whole.
        own = self.writes_of(job)
        for qid, lba, nbytes, code in self.dma.wr_log[self.wr0:]:
            assert (qid, lba) in own, f"write to drive {qid} LBA {lba:#x} the job never planned"
        self.log.info(f"job ERR as expected: {{{', '.join(f'{s}: {job.regs[s]['err_info']:#x}' for s in expect_info)}}}, "
                      f"{len(self.dma.wr_log) - self.wr0} writes, {self.cycle() - self.start_cycle} cycles")


def random_geometry(rng):
    """(log2 drives, log2 chunk) for a job: 1/2/4 drives, chunks of 8 to 256 LBAs; the planner bench covers smaller chunks,
    which here cut a job into hundreds of reads and push a test past its wall cap."""
    return rng.randint(0, min(fc.MAX_LOG2_DRIVES, NUM_QUEUES.bit_length() - 1)), rng.randint(3, fc.MAX_LOG2_CHUNK)


def make_job(rng, vol, nstreams=None, files=(1, 6), fill_max=200_000, tight_out=False):
    n = nstreams or rng.randint(1, fc.MAX_STREAMS)
    streams = [random_stream(rng, vol, rng.randint(*files), fill_max, tight_out) for _ in range(n)]
    vol.ld, vol.lc = random_geometry(rng)
    return JobRun(streams=streams, ld=vol.ld, lc=vol.lc)
