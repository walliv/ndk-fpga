# cocotb_test.py: does FS_RD_DATA hand every frame's valid bytes to the right kernel lane?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Frames with seeded gaps and their contexts against the model's beats, completions and byte
counts; kernel ready lines toggle, and a stalled kernel must hold the stream, never drop."""

import os
from collections import defaultdict, deque

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

from cocotbext.ofm.base.generators import OnOffIdleGenerator
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

from fs_ctx import BEAT, CTX_W, FSLOTS, SECT, TAG_W, Ctx
from fs_rd_data_model import frame_beats, valid_bytes
from fs_tb_util import as_int, onehot_index, rand_mask, release_reset, seeded, start_clock

STREAMS = int(os.environ.get("STREAMS", "8"))
NUM_QUEUES = 4
QID_W = 2
CID_W = 16


class RdDataBench:

    def __init__(self, dut, rng, kin_rdy_prob, gaps=True, ctx_lead=(1, 30)):
        self.dut = dut
        self.rng = rng
        self.kin_rdy_prob = kin_rdy_prob
        self.ctx_lead = ctx_lead
        params = {"regions": 1, "region_size": 1, "block_size": 64, "item_width": 8,
                  "meta_width": QID_W + CID_W}
        gen = OnOffIdleGenerator(self._gap_gen()) if gaps else None
        kw = {"idle_generator": gen} if gen else {}
        self.drv = MFBDriver(dut, "RX_MFB", dut.CLK, mfb_params=params, **kw)
        self.frames = []
        # Contexts as FS_RD_ISSUE queues them: (cycle from which it is visible, packed word).
        self.xq = deque()
        self.xctx_pops = 0
        self.got = defaultdict(list)
        self.cdone = defaultdict(list)
        self.bytes = defaultdict(int)
        self.sink = 0
        self.sink_seen = False
        self.beats_in_sink = 0
        self.cycle = 0
        self.stall_cycles = 0
        self.dst_low_with_ctx = 0

    def _gap_gen(self):
        while True:
            yield (self.rng.randint(1, 40), self.rng.choice((0, 0, 0, 1, 1, 2, 7)))

    def add_frames(self, n, big_prob=0.05, late=False):
        """Queue frames and their contexts. A late context becomes visible only some cycles after
        the previous frame was taken, so its own frame already waits at SOF."""
        for _ in range(n):
            nlba = 255 if self.rng.random() < big_prob else self.rng.choice((0, 0, 1, 2, 3, 7, 15))
            vbytes = (nlba + 1) * SECT - self.rng.choice((0, 0, 1, 63, 64, 65, 448, 511))
            ctx = Ctx(stream=self.rng.randrange(STREAMS), fslot=self.rng.randrange(FSLOTS),
                      fidx=self.rng.randrange(1 << 32), fofs=self.rng.randrange(1 << 39) * SECT,
                      cofs=self.rng.randrange(1 << 55) * SECT, vbytes=vbytes)
            qid, tag = self.rng.randrange(NUM_QUEUES), self.rng.randrange(1 << TAG_W)
            data = self.rng.randbytes((nlba + 1) * SECT)
            self.frames.append((ctx, qid, tag, data))
            word = (qid << (TAG_W + CTX_W)) | (tag << CTX_W) | ctx.pack()
            entry = [None if late else self.cycle, word]
            self.xq.append(entry)
            if late and len(self.xq) == 1:
                entry[0] = self.cycle + self.rng.randint(*self.ctx_lead)
            self.drv.append(MfbTransactionWithMeta(data=data, meta=(tag << QID_W) | qid),
                            callback=lambda _t: self._frame_taken())

    def _frame_taken(self):
        for entry in self.xq:
            if entry[0] is None:
                entry[0] = self.cycle + self.rng.randint(*self.ctx_lead)
                break

    async def run(self):
        dut = self.dut
        xvld = 0
        while True:
            await RisingEdge(dut.CLK)
            await Timer(1, unit="ns")
            self.cycle += 1
            head_ok = bool(self.xq) and self.xq[0][0] is not None and self.xq[0][0] <= self.cycle
            if head_ok:
                dut.XCTX_DATA.value = self.xq[0][1]
            if int(head_ok) != xvld:
                xvld = int(head_ok)
                dut.XCTX_VLD.value = xvld
            dut.KIN_RDY.value = rand_mask(self.rng, self.kin_rdy_prob)
            dut.SINK.value = self.sink

            await ReadOnly()
            src, dst = as_int(dut.RX_MFB_SRC_RDY), as_int(dut.RX_MFB_DST_RDY)
            if src and not dst:
                self.stall_cycles += 1
            if as_int(dut.XCTX_RD):
                assert xvld, "XCTX_RD without XCTX_VLD"
                self.xq.popleft()
                self.xctx_pops += 1
                # The FIFO shows its next item a cycle after a read.
                if self.xq and self.xq[0][0] is not None:
                    self.xq[0][0] = max(self.xq[0][0], self.cycle + 2)
            kv, kr = as_int(dut.KIN_VLD), as_int(dut.KIN_RDY)
            if kv:
                s = onehot_index(kv, "KIN_VLD")
                assert not self.sink_seen, "a beat was offered to a kernel while SINK"
                if kv & kr:
                    n = as_int(dut.KIN_BYTES)
                    data = int(dut.KIN_DATA.value).to_bytes(BEAT, "little")[:n]
                    self.got[s].append((data, n, as_int(dut.KIN_FIDX), as_int(dut.KIN_FOFS), as_int(dut.KIN_COFS)))
            cv = as_int(dut.CDONE_VLD)
            if cv:
                self.cdone[onehot_index(cv, "CDONE_VLD")].append(as_int(dut.CDONE_FSLOT))
            bv = as_int(dut.BYTES_VLD)
            if bv:
                self.bytes[onehot_index(bv, "BYTES_VLD")] += as_int(dut.BYTES_N)
            self.sink_seen = bool(self.sink)

    async def wait_done(self, timeout=400_000):
        for _ in range(timeout // 50):
            await ClockCycles(self.dut.CLK, 50)
            if not self.drv.pending and as_int(self.dut.IDLE) == 1:
                await ClockCycles(self.dut.CLK, 10)
                return
        raise AssertionError(f"frames left: {self.drv.pending}, IDLE {as_int(self.dut.IDLE)}")

    def expected(self, frames):
        beats, cdone, nbytes = defaultdict(list), defaultdict(list), defaultdict(int)
        for ctx, _, _, data in frames:
            for b in frame_beats(ctx, data):
                beats[b.stream].append((valid_bytes(b), b.nbytes, b.fidx, b.fofs, b.cofs))
                nbytes[b.stream] += b.nbytes
            cdone[ctx.stream].append(ctx.fslot)
        return beats, cdone, nbytes

    def check(self):
        assert self.xctx_pops == len(self.frames), f"{self.xctx_pops} contexts taken for {len(self.frames)} frames"
        beats, cdone, nbytes = self.expected(self.frames)
        for s in range(STREAMS):
            got, exp = self.got[s], beats[s]
            for i, (g, x) in enumerate(zip(got, exp)):
                assert g == x, f"stream {s} beat {i}: got n={g[1]} fofs={g[3]:#x} cofs={g[4]:#x}, " \
                               f"expected n={x[1]} fofs={x[3]:#x} cofs={x[4]:#x} (data equal: {g[0] == x[0]})"
            assert len(got) == len(exp), f"stream {s}: {len(got)} beats, expected {len(exp)}"
            assert self.cdone[s] == cdone[s], f"stream {s}: completions {self.cdone[s]} != {cdone[s]}"
            assert self.bytes[s] == nbytes[s], f"stream {s}: {self.bytes[s]} bytes counted, {nbytes[s]} delivered"
        self.dut._log.info(f"frames {len(self.frames)}, beats {sum(len(v) for v in self.got.values())}, "
                           f"stalled input cycles {self.stall_cycles}, cycles {self.cycle}")


async def start(dut, salt, kin_rdy_prob, **kw):
    start_clock(dut)
    dut.RESET.value = 1
    dut.CLEAR.value = 0
    dut.SINK.value = 0
    dut.XCTX_VLD.value = 0
    dut.XCTX_DATA.value = 0
    dut.KIN_RDY.value = 0
    bench = RdDataBench(dut, seeded(salt), kin_rdy_prob, **kw)
    await release_reset(dut, 10, 5)
    cocotb.start_soon(bench.run())
    return bench


@cocotb.test()
async def test_frames_to_lanes(dut):
    """Random frames, partial last beats, dropped tails, gaps and kernel backpressure."""
    bench = await start(dut, 0x101, [1.0, 0.9, 0.5, 0.2, 1.0, 0.7, 0.05, 0.95][:STREAMS])
    bench.add_frames(300)
    await bench.wait_done()
    bench.check()


@cocotb.test()
async def test_late_context_stalls_only_at_sof(dut):
    """With every kernel ready and the contexts ahead the input never waits; a context that is
    not yet there holds its frame at SOF and nothing is lost."""
    bench = await start(dut, 0x202, [1.0] * STREAMS, gaps=False)
    bench.add_frames(80, big_prob=0.1)
    await bench.wait_done()
    bench.check()
    assert bench.stall_cycles == 0, f"input stalled {bench.stall_cycles} cycles with contexts ahead and kernels ready"

    bench.ctx_lead = (1, 30)
    bench.add_frames(60, late=True)
    await bench.wait_done()
    bench.check()
    assert bench.stall_cycles > 0, "no frame ever waited for a late context"


@cocotb.test()
async def test_sink_mid_stream(dut):
    """Frames keep draining under SINK while no kernel sees a beat, no completion or byte count."""
    bench = await start(dut, 0x303, [0.6] * STREAMS)
    bench.add_frames(120)
    await ClockCycles(dut.CLK, bench.rng.randrange(300, 1500))
    await RisingEdge(dut.CLK)
    delivered = {s: len(v) for s, v in bench.got.items()}
    cdone = {s: len(v) for s, v in bench.cdone.items()}
    bench.sink = 1
    await bench.wait_done()
    assert bench.xctx_pops == len(bench.frames), "a frame under SINK did not take its context"
    # At most the one beat in flight when SINK rose may still land.
    extra = sum(len(v) - delivered.get(s, 0) for s, v in bench.got.items())
    assert extra <= 1, f"{extra} beats delivered after SINK"
    extra_cd = sum(len(v) - cdone.get(s, 0) for s, v in bench.cdone.items())
    assert extra_cd <= 1, f"{extra_cd} completions reported after SINK"
    beats, _, _ = bench.expected(bench.frames)
    for s, got in bench.got.items():
        assert got == beats[s][:len(got)], f"stream {s}: beats before SINK do not match"
