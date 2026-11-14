# cocotb_test.py: does the read plane pair every DMA frame with the chunk it reads?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""FS_RD_ISSUE and FS_RD_DATA behind the real USER_CORE_IF_PIPE against the multi-queue DMA model:
random accept RDY, late CIDs, tags reused before their frames drain, out-of-order completions,
failed, lost and rejected reads."""

import os
from collections import Counter, defaultdict

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

from dma_iuventus_mq_model import CODE_FAIL, CODE_LOST, CODE_OK, CODE_OOR, OP_READ
from fs_ctx import BEAT, FSLOTS, SECT, Ctx
from fs_dma_model import FsDma
from fs_rd_data_model import valid_bytes
from fs_rd_issue_model import expect
from fs_tb_util import as_int, onehot_index, rand_mask, release_reset, seeded, start_clock

STREAMS = 4
NUM_QUEUES = 4
EPS = 2
QID_W = 2
XCTX_ITEMS = int(os.environ.get("XCTX_ITEMS", "512"))
# Every frame finishes within this many cycles of the traffic stopping, or the plane is stuck.
DRAIN_TIMEOUT = 200_000


class ReadPlaneBench:

    def __init__(self, dut, rng, kin_rdy_prob, dma_kw, oor_accepts=()):
        self.dut = dut
        self.rng = rng
        self.kin_rdy_prob = kin_rdy_prob
        self.dma = FsDma(dut, dut.CLK, NUM_QUEUES, EPS, rng, oor_accepts=oor_accepts, **dma_kw)
        # Every sector reads as its (queue, sector) pattern, so a frame paired with the wrong
        # request shows up as data that does not belong at the offsets it was delivered with.
        self.dma.pattern_lbas = 1 << 47
        self.chunks = {}
        self.queues = [[] for _ in range(STREAMS)]
        self.cur = [None] * STREAMS
        self.gap = [0] * STREAMS
        self.issued = 0
        self.beats = defaultdict(dict)
        self.dup_beats = []
        self.cdone = Counter()
        self.bytes = Counter()
        self.errors = Counter()
        self.sink = 0
        self.sink_cycle = None
        self.beats_after_sink = 0
        self.cycle = 0
        self._next_lba = [0] * NUM_QUEUES
        self._cofs = [0] * STREAMS

    def add_chunks(self, per_stream, big_prob=0.05):
        """Random chunks with unique requests per queue and disjoint COFS ranges per stream."""
        for s in range(STREAMS):
            for _ in range(per_stream):
                qid = self.rng.randrange(NUM_QUEUES)
                nlba = 255 if self.rng.random() < big_prob else self.rng.choice((0, 0, 1, 2, 3, 7, 15, 31))
                lba = self._next_lba[qid] + self.rng.randrange(0, 4)
                self._next_lba[qid] = lba + nlba + 1
                vbytes = (nlba + 1) * SECT - self.rng.choice((0, 0, 0, 1, 63, 64, 65, 511))
                ctx = Ctx(stream=s, fslot=self.rng.randrange(FSLOTS), fidx=self.rng.randrange(1 << 32),
                          fofs=self.rng.randrange(1 << 30) * SECT, cofs=self._cofs[s], vbytes=vbytes)
                self._cofs[s] += (nlba + 1) * SECT + SECT * self.rng.randrange(3)
                key = (qid, lba, nlba)
                assert key not in self.chunks
                self.chunks[key] = ctx
                self.queues[s].append(key)

    def pending(self):
        return any(self.queues) or any(c is not None for c in self.cur)

    async def run(self):
        dut = self.dut
        vec_vld = 0
        while True:
            await RisingEdge(dut.CLK)
            await Timer(1, unit="ns")
            self.cycle += 1
            for s in range(STREAMS):
                if self.cur[s] is None and self.queues[s]:
                    if self.gap[s] > 0:
                        self.gap[s] -= 1
                    else:
                        key = self.queues[s].pop(0)
                        self.cur[s] = key
                        ctx = self.chunks[key]
                        dut.CREQ_QID[s].value = key[0]
                        dut.CREQ_LBA[s].value = key[1]
                        dut.CREQ_NLBA[s].value = key[2]
                        dut.CREQ_CTX[s].value = ctx.pack()
            new_vld = sum(1 << s for s in range(STREAMS) if self.cur[s] is not None)
            if new_vld != vec_vld:
                dut.CREQ_VLD.value = new_vld
                vec_vld = new_vld
            for e in range(EPS):
                rdy = rand_mask(self.rng, self.kin_rdy_prob)
                dut.KIN_RDY[e].value = rdy
            dut.SINK.value = self.sink

            await ReadOnly()
            if vec_vld:
                rdy = as_int(dut.CREQ_RDY)
                assert rdy & ~vec_vld == 0, f"CREQ_RDY={rdy:b} without CREQ_VLD={vec_vld:b}"
                assert rdy & (rdy - 1) == 0, f"CREQ_RDY={rdy:b} grants more than one stream"
                for s in range(STREAMS):
                    if rdy >> s & 1:
                        self.cur[s] = None
                        self.issued += 1
                        self.gap[s] = self.rng.choice((0, 0, 0, 1, 3, 10))
            for e in range(EPS):
                kv = as_int(dut.KIN_VLD[e])
                if kv:
                    s = onehot_index(kv, f"KIN_VLD[{e}]")
                    if kv & as_int(dut.KIN_RDY[e]):
                        self._take_beat(e, s)
                cv = as_int(dut.CDONE_VLD[e])
                if cv:
                    self.cdone[(onehot_index(cv, f"CDONE_VLD[{e}]"), as_int(dut.CDONE_FSLOT[e]))] += 1
                bv = as_int(dut.BYTES_VLD[e])
                if bv:
                    self.bytes[onehot_index(bv, f"BYTES_VLD[{e}]")] += as_int(dut.BYTES_N[e])
            if as_int(dut.RERR_VLD):
                self.errors[(as_int(dut.RERR_MASK), as_int(dut.RERR_INFO))] += 1

    def _take_beat(self, e, s):
        dut = self.dut
        n = as_int(dut.KIN_BYTES[e])
        cofs = as_int(dut.KIN_COFS[e])
        data = int(dut.KIN_DATA[e].value).to_bytes(BEAT, "little")
        rec = (data[:n], n, as_int(dut.KIN_FIDX[e]), as_int(dut.KIN_FOFS[e]))
        if self.sink_cycle is not None:
            self.beats_after_sink += 1
        if cofs in self.beats[s]:
            self.dup_beats.append((s, cofs))
        self.beats[s][cofs] = rec

    def idle(self):
        dut = self.dut
        return (not self.pending() and self.dma.idle() and as_int(dut.RD_IDLE) == 1
                and as_int(dut.DATA_IDLE) == (1 << EPS) - 1)

    async def wait_idle(self):
        for _ in range(DRAIN_TIMEOUT // 100):
            await ClockCycles(self.dut.CLK, 100)
            if self.idle():
                await ClockCycles(self.dut.CLK, 20)
                if self.idle():
                    return
        raise AssertionError(f"read plane not idle: issued {self.issued}/{len(self.chunks)}, "
                             f"dma idle {self.dma.idle()}, RD_IDLE {as_int(self.dut.RD_IDLE)}, "
                             f"DATA_IDLE {as_int(self.dut.DATA_IDLE):b}")

    def expected(self):
        frames = [(f.qid, f.lba, f.num, f.data) for f in self.dma.frames]
        statuses = [(code, (qid, lba, num), qid, cid) for op, code, qid, lba, num, cid in self.dma.status_log
                    if op == OP_READ and code in (CODE_FAIL, CODE_OOR)]
        lost = [(f.qid, f.cid) for f in self.dma.frames if f.lost]
        return expect(self.chunks, frames, statuses, lost, STREAMS)

    def check(self, sink=False):
        dma = self.dma
        exp = self.expected()
        log = self.dut._log
        assert not self.dup_beats, f"beats delivered twice: {self.dup_beats[:4]}"
        assert self.issued == len(self.chunks), f"issued {self.issued} of {len(self.chunks)} chunks"
        assert len(dma.accepted) == len(self.chunks), f"DMA accepted {len(dma.accepted)} of {len(self.chunks)}"
        reqs = Counter((c.qid, c.lba, c.num) for c in dma.accepted)
        assert reqs == Counter(self.chunks.keys()), "the DMA saw requests that differ from the chunks"
        bad = 0
        for s in range(STREAMS):
            for cofs, (data, n, fidx, fofs) in self.beats[s].items():
                b = exp.beats[s].get(cofs)
                if b is None or (valid_bytes(b), b.nbytes, b.fidx, b.fofs) != (data, n, fidx, fofs):
                    bad += 1
                    if bad <= 4:
                        log.error(f"stream {s} COFS {cofs:#x}: got n={n} fidx={fidx:#x} fofs={fofs:#x}, "
                                  f"expected {None if b is None else (b.nbytes, hex(b.fidx), hex(b.fofs))}")
        assert bad == 0, f"{bad} delivered beats do not match their chunk"
        if not sink:
            for s in range(STREAMS):
                missing = set(exp.beats[s]) - set(self.beats[s])
                assert not missing, f"stream {s}: {len(missing)} beats never delivered"
            assert self.cdone == exp.cdone, "chunk completions differ from the delivered frames"
            assert self.bytes == exp.bytes, f"IN_BYTES increments {dict(self.bytes)} != {dict(exp.bytes)}"
        else:
            assert self.beats_after_sink == 0, f"{self.beats_after_sink} beats delivered while SINK"
        assert self.errors == exp.errors, f"read errors {dict(self.errors)} != expected {dict(exp.errors)}"
        n_lost = sum(1 for f in dma.frames if f.lost)
        log.info(f"chunks {len(self.chunks)}, frames {len(dma.frames)} ({n_lost} lost), "
                 f"statuses {len(dma.status_log)}, errors {sum(self.errors.values())}, "
                 f"beats {sum(len(v) for v in self.beats.values())}, cycles {self.cycle}, "
                 f"page-bound cycles {dma.page_bound_cycles}")


async def start(dut, salt, kin_rdy_prob=None, oor_accepts=(), **dma_kw):
    rng = seeded(salt)
    start_clock(dut)
    dut.DMA_RST.value = 1
    dut.CREQ_VLD.value = 0
    dut.SINK.value = 0
    for e in range(EPS):
        dut.KIN_RDY[e].value = 0
    dma_kw.setdefault("queue_depth", 8)
    bench = ReadPlaneBench(dut, rng, kin_rdy_prob or [1.0] * STREAMS, dma_kw, oor_accepts)
    # The engine end leaves reset STAGES cycles after the DMA end.
    await release_reset(dut, 20, 20, sigs=("DMA_RST",))
    cocotb.start_soon(bench.run())
    return bench


@cocotb.test()
async def test_random_traffic(dut):
    """Four streams over four queues and two endpoints, tags reused before their frames drain."""
    bench = await start(dut, 0x11, kin_rdy_prob=[1.0, 0.8, 0.5, 0.95], rd_lat=(10, 300), cid_delay=(3, 9))
    bench.add_chunks(per_stream=60)
    await bench.wait_idle()
    bench.check()


@cocotb.test()
async def test_slow_kernels_fill_the_window(dut):
    """Kernels stall long enough that every endpoint's issue window closes and reopens."""
    bench = await start(dut, 0x22, kin_rdy_prob=[0.15, 0.3, 0.2, 0.25], rd_lat=(5, 60), queue_depth=16,
                        pages_per_ep=400)
    bench.add_chunks(per_stream=40, big_prob=0.0)
    await bench.wait_idle()
    bench.check()


@cocotb.test()
async def test_failed_lost_and_rejected_reads(dut):
    """01 fails the read's own stream and sends no frame, 10 fails the rejected request's stream,
    11 follows a delivered frame and fails every stream."""
    rng = seeded(0x33)
    oor = set(rng.sample(range(10, 150), 6))
    bench = await start(dut, 0x44, kin_rdy_prob=[0.9, 1.0, 0.7, 1.0], oor_accepts=oor, rd_lat=(10, 200))
    for i in rng.sample(range(5, 150), 12):
        bench.dma.plan.faults[i] = rng.choice(("fail", "fail", "lost"))
    bench.add_chunks(per_stream=45)
    await bench.wait_idle()
    bench.check()
    codes = Counter(code for op, code, *_ in bench.dma.status_log if op == OP_READ)
    assert codes[CODE_FAIL] and codes[CODE_OOR] and any(f.lost for f in bench.dma.frames), \
        f"a fault class was never reached: {dict(codes)}"


@cocotb.test()
async def test_sink_discards(dut):
    """Once SINK is set nothing reaches a kernel, yet every frame is drained and the plane idles."""
    bench = await start(dut, 0x55, kin_rdy_prob=[0.6, 1.0, 0.8, 0.4], rd_lat=(10, 200))
    bench.add_chunks(per_stream=40)
    await ClockCycles(dut.CLK, bench.rng.randrange(800, 2500))
    await RisingEdge(dut.CLK)
    bench.sink = 1
    # SINK reaches the DUT one cycle later; a beat in that cycle may still be delivered.
    await ClockCycles(dut.CLK, 2)
    bench.sink_cycle = bench.cycle
    await bench.wait_idle()
    bench.check(sink=True)
    assert CODE_OK in (code for _, code, *_ in bench.dma.status_log)
    assert CODE_LOST not in (code for _, code, *_ in bench.dma.status_log)
