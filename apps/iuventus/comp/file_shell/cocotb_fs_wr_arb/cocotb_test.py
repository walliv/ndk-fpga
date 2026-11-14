# cocotb_test.py: does FS_WR_ARB merge the writers' frames intact and attribute every completion?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import attach_mfb_properties, final_check_all
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.utils.signals import signal_int

from fs_ctx import BEAT, SECT
from fs_tb_util import release_reset, seeded, start_clock
from fs_wr_arb_model import FsWrArbModel
from scoreboard import Scoreboard

# Must match the elaborated generics; the fallbacks are the RTL defaults.
STREAMS = int(os.environ.get("STREAMS", 8))
CPL_ITEMS = int(os.environ.get("CPL_FIFO_ITEMS", 72))
NUM_QUEUES = 4
QID_W = 2
MFB_PARAMS = dict(regions=1, region_size=8, block_size=8, item_width=8, meta_width=QID_W + 64)


class Frame:
    def __init__(self, stream, idx, qid, lba, nlba0, nbytes, rng):
        self.stream = stream
        self.idx = idx
        self.qid = qid
        self.lba = lba
        self.nlba0 = nlba0
        self.nbytes = nbytes
        nbeats = (nlba0 + 1) * 8
        self.beats = [(stream << 504) | (idx << 488) | (b << 472) | rng.getrandbits(472) for b in range(nbeats)]

    def expected(self):
        data = b"".join(b.to_bytes(BEAT, "little") for b in self.beats)
        return (self.stream, self.idx, (self.qid << 64) | self.lba, data)


def random_frames(rng, stream, count, qids=None, small=False):
    frames = []
    for i in range(count):
        r = rng.random()
        if small or r < 0.7:
            nlba0 = rng.randint(0, 3)
        elif r < 0.95:
            nlba0 = rng.randint(4, 31)
        else:
            nlba0 = rng.randint(32, 255)
        nbytes = rng.randint(nlba0 * SECT + 1, (nlba0 + 1) * SECT)
        qid = rng.choice(qids) if qids else rng.randrange(NUM_QUEUES)
        frames.append(Frame(stream, i, qid, rng.randrange(1 << 48), nlba0, nbytes, rng))
    return frames


class WriterEmu:
    """One FS_OUT_WRITER as the arbiter sees it: a held request, then a frame that never pauses
    once its first beat went out. Like the real writer it may offer its first beat before the grant."""

    def __init__(self, dut, s, frames, rng, idle=(0, 30)):
        self.dut = dut
        self.s = s
        self.frames = list(frames)
        self.rng = rng
        self.idle = idle
        self.state = "idle"
        self.wait = rng.randint(*idle)
        self.cur = None
        self.beat = 0
        self.vld = 0
        self.req_vld = 0
        self.req_since = None

    def done(self):
        return self.state == "idle" and not self.frames and self.cur is None

    def sample(self, wreq_rdy, wdat_rdy, cyc):
        """Handshakes of the cycle that just ended; returns the granted frame, if any."""
        granted = None
        if self.req_vld and wreq_rdy:
            granted = self.cur
            self.state = "granted"
            self.req_vld = 0
            self.req_since = None
            self.wait = self.rng.choice([0, 0, 0, 1, 2])
        elif wreq_rdy:
            raise AssertionError(f"cycle {cyc}: WREQ_RDY({self.s}) without a request")
        if wdat_rdy:
            assert self.state == "stream" or self.state == "granted", \
                f"cycle {cyc}: WDAT_RDY({self.s}) while the stream holds no grant"
            if self.vld:
                self.beat += 1
                if self.beat == len(self.cur.beats):
                    self.state = "idle"
                    self.cur = None
                    self.vld = 0
                    self.wait = self.rng.randint(*self.idle)
                else:
                    self.state = "stream"
        return granted

    def drive(self, cyc):
        dut = self.dut
        s = self.s
        if self.state == "idle" and self.cur is None:
            if self.frames:
                if self.wait > 0:
                    self.wait -= 1
                else:
                    self.cur = self.frames.pop(0)
                    self.beat = 0
                    self.state = "req"
                    self.req_vld = 1
                    self.req_since = cyc + 1
                    dut.WREQ_QID[s].value = self.cur.qid
                    dut.WREQ_LBA[s].value = self.cur.lba
                    dut.WREQ_NLBA[s].value = self.cur.nlba0
                    dut.WREQ_NBYTES[s].value = self.cur.nbytes
        vld = 0
        if self.state == "req" and self.rng.random() < 0.5:
            vld = 1
        elif self.state == "granted":
            if self.wait > 0:
                self.wait -= 1
            else:
                vld = 1
        elif self.state == "stream":
            vld = 1
        if vld and self.cur is not None:
            dut.WDAT_DATA[s].value = self.cur.beats[self.beat]
        self.vld = vld


class ArbBench:
    def __init__(self, dut, salt):
        self.dut = dut
        self.rng = seeded(salt)
        self.log = dut._log
        self.model = FsWrArbModel(STREAMS, NUM_QUEUES)
        self.frames_sb = Scoreboard("mfb_frames")
        self.mfb_frames = []
        self.sent = [[] for _ in range(NUM_QUEUES)]
        self.werr_exp = []
        self.werr_got = 0
        self.owner_checks = 0
        self.early_done_cases = 0
        self.full_skips = 0
        self.max_qlen = 0
        self.cyc = 0
        self.props = None

    async def init(self):
        dut = self.dut
        start_clock(dut)
        dut.CLEAR.value = 0
        dut.WREQ_VLD.value = 0
        dut.WDAT_VLD.value = 0
        for s in range(STREAMS):
            dut.WREQ_QID[s].value = 0
            dut.WREQ_LBA[s].value = 0
            dut.WREQ_NLBA[s].value = 0
            dut.WREQ_NBYTES[s].value = 0
            dut.WDAT_DATA[s].value = 0
        dut.WR_MFB_DST_RDY.value = 0
        dut.OP_STAT_VLD.value = 0
        dut.OP_STAT_TYPE.value = 0
        dut.OP_STAT_CODE.value = 0
        dut.OP_STAT_QID.value = 0
        dut.OP_STAT_CID.value = 0
        dut.RESET.value = 1
        self.mon = MFBMonitor(dut, "WR_MFB", dut.CLK, mfb_params=MFB_PARAMS, trans_type=MfbTransactionWithMeta)
        self.mon.add_callback(self._on_frame)
        await ClockCycles(dut.CLK, 5)
        self.props = attach_mfb_properties(dut, dut.CLK, reset=dut.RESET, no_gap_in_frame=True,
                                           sample_delay=(2, "ns"))
        await release_reset(dut, 0, 2)

    def _on_frame(self, trans):
        # The stream and frame index sit in the top bits of every beat.
        head = int.from_bytes(trans.data[:BEAT], "little")
        stream, idx = head >> 504, (head >> 488) & 0xFFFF
        got = (stream, idx, trans.meta, bytes(trans.data))
        self.frames_sb.check(got)
        self.sent[trans.meta >> 64].append((self.cyc, stream, idx))

    async def run(self, writers, cpl_rate=0.2, err_rates=(0.0, 0.0, 0.0), read_noise=0.0, hold=None,
                  sof_stall=(0.15, 400), fairness=True, max_cycles=300000, newest_first=False, code_fn=None):
        """Runs until every writer is done and every frame completed. `hold` = (cycle, length) holds
        back completions for a window, so the completion FIFOs fill. `newest_first` completes a queue's
        latest frame first; `code_fn(queue, owner, frames left on the queue)` picks each status code."""
        dut = self.dut
        rng = self.rng
        model = self.model
        emus = writers
        dst_rdy = 0
        stall = 0
        in_frame = False
        sof_seen = False
        op = None
        op_owner = None
        waiting = {}
        outs_hist = {}
        real_hist = {}
        real_cnt = [0] * STREAMS
        head_cnt = [0] * STREAMS
        head_hist = {}
        bytes_hist = {}
        start = self.cyc

        for _ in range(max_cycles):
            await RisingEdge(dut.CLK)
            cyc = self.cyc
            self.cyc += 1
            wreq_rdy = signal_int(dut.WREQ_RDY)
            wdat_rdy = signal_int(dut.WDAT_RDY)
            src_rdy = int(dut.WR_MFB_SRC_RDY.value)
            sof = int(dut.WR_MFB_SOF.value)
            eof = int(dut.WR_MFB_EOF.value)
            werr_vld = int(dut.WERR_VLD.value)

            # -------- grants first, then this cycle's status: the RTL's attribution order
            granted_now = []
            for e in emus:
                fr = e.sample((wreq_rdy >> e.s) & 1, (wdat_rdy >> e.s) & 1, cyc)
                if fr is not None:
                    granted_now.append(e.s)
                    model.grant(e.s, fr.qid, fr.nbytes)
                    assert model.queue_len(fr.qid) <= CPL_ITEMS, f"cycle {cyc}: grant into a full queue {fr.qid}"
                    self.max_qlen = max(self.max_qlen, model.queue_len(fr.qid))
                    self.frames_sb.expect(fr.expected())
                    real_cnt[e.s] += 1
                    head_cnt[e.s] += 1
            assert len(granted_now) <= 1, f"cycle {cyc}: more than one grant {granted_now}"
            if fairness and granted_now:
                g = granted_now[0]
                for s, seen in waiting.items():
                    if s == g:
                        continue
                    assert g not in seen, f"cycle {cyc}: stream {g} granted twice while stream {s} waited"
                    seen.add(g)
                waiting.pop(g, None)
            for e in emus:
                if e.req_vld and e.s not in waiting:
                    if model.queue_len(e.cur.qid) < CPL_ITEMS - 4:
                        waiting[e.s] = set()
                elif not e.req_vld:
                    waiting.pop(e.s, None)
                if e.req_vld and model.queue_len(e.cur.qid) >= CPL_ITEMS:
                    self.full_skips += 1
                    waiting.pop(e.s, None)

            # What the RTL shows a cycle later: this cycle's grants, the statuses before it.
            outs_hist[cyc] = model.outstanding_mask()
            real_hist[cyc] = sum(1 << s for s in range(STREAMS) if real_cnt[s] > 0)
            head_hist[cyc] = sum(1 << s for s in range(STREAMS) if head_cnt[s] > 0)

            if op is not None:
                werr = model.op_stat(*op)
                if op_owner is not None and op[0] == 0:
                    real_cnt[op_owner] -= 1
                if model.popped is not None:
                    head_cnt[model.popped] -= 1
                if werr is not None:
                    assert op_owner is None or (werr.mask >> op_owner) & 1, \
                        f"cycle {cyc}: the model's mask {werr.mask:#x} misses the failed write's stream {op_owner}"
                    self.werr_exp.append((cyc + 2, werr, op_owner))
            bytes_hist[cyc] = list(model.out_bytes)
            for h in (outs_hist, real_hist, head_hist, bytes_hist):
                h.pop(cyc - 6, None)

            if werr_vld:
                assert self.werr_exp, f"cycle {cyc}: WERR with none expected"
                when, exp, owner = self.werr_exp.pop(0)
                got_mask = int(dut.WERR_MASK.value)
                got_info = int(dut.WERR_INFO.value)
                if owner is not None:
                    assert (got_mask >> owner) & 1, \
                        f"cycle {cyc}: WERR_MASK {got_mask:#x} misses stream {owner}, whose write failed"
                    self.owner_checks += 1
                assert when == cyc and got_mask == exp.mask and got_info == exp.info, \
                    (f"cycle {cyc}: WERR mask {got_mask:#x} info {got_info:#x}, expected cycle {when} "
                     f"mask {exp.mask:#x} info {exp.info:#x}")
                self.werr_got += 1
            elif self.werr_exp:
                assert self.werr_exp[0][0] > cyc, f"cycle {cyc}: expected WERR missing {self.werr_exp[0]}"

            # Outstanding flags: a grant shows a cycle later, a status's pop two cycles later. No stream
            # with a write still in flight may read as done, whichever write the completion belonged to.
            if cyc - 1 in outs_hist:
                got = signal_int(dut.WR_OUTSTANDING)
                assert got == outs_hist[cyc - 1], \
                    f"cycle {cyc}: WR_OUTSTANDING {got:#x}, expected {outs_hist[cyc - 1]:#x}"
                assert real_hist[cyc - 1] & ~got == 0, \
                    f"cycle {cyc}: WR_OUTSTANDING {got:#x} reads done a stream with a write in flight " \
                    f"({real_hist[cyc - 1]:#x})"
                # Cycles where counting per queue head alone would have flagged a stream done early.
                if real_hist[cyc - 1] & ~head_hist[cyc - 1]:
                    self.early_done_cases += 1
            if cyc % 8 == 0 and cyc - 3 in bytes_hist:
                for s in range(STREAMS):
                    got = int(dut.OUT_BYTES[s].value)
                    assert got == bytes_hist[cyc - 3][s], f"cycle {cyc}: OUT_BYTES({s}) {got}, " \
                                                          f"expected {bytes_hist[cyc - 3][s]}"

            # -------- MFB beat bookkeeping for the DMA-side ready
            if src_rdy and dst_rdy:
                in_frame = not eof
                sof_seen = False

            # -------- end condition
            busy = any(not e.done() for e in emus) or in_frame or any(self.sent) or op is not None
            if not busy and not self.werr_exp and not self.frames_sb._expected:
                break

            # -------- drive the next cycle
            await Timer(1, unit="ns")
            for e in emus:
                e.drive(cyc + 1)
            vld_vec = 0
            req_vec = 0
            for e in emus:
                vld_vec |= e.vld << e.s
                req_vec |= e.req_vld << e.s
            dut.WDAT_VLD.value = vld_vec
            dut.WREQ_VLD.value = req_vec

            # DST_RDY stays low at an offered SOF while the DMA waits for its grant, then toggles.
            if src_rdy and sof and not in_frame and not sof_seen:
                sof_seen = True
                stall = rng.randint(1, sof_stall[1]) if rng.random() < sof_stall[0] else rng.randint(0, 3)
            if not in_frame and not sof_seen:
                dst_rdy = 0
            elif stall > 0:
                stall -= 1
                dst_rdy = 0
            elif not in_frame:
                dst_rdy = 1
            elif rng.random() < 0.02:
                stall = rng.randint(1, 30)
                dst_rdy = 0
            else:
                dst_rdy = int(rng.random() < 0.85)
            dut.WR_MFB_DST_RDY.value = dst_rdy

            op = None
            op_owner = None
            held = hold is not None and hold[0] <= cyc - start < hold[0] + hold[1]
            if not held and rng.random() < cpl_rate:
                ready = [q for q in range(NUM_QUEUES) if any(c + 3 <= cyc for c, _, _ in self.sent[q])]
                if ready:
                    q = rng.choice(ready)
                    cands = [i for i, (c, _, _) in enumerate(self.sent[q]) if c + 3 <= cyc]
                    _, owner, _ = self.sent[q].pop(cands[-1] if newest_first else rng.choice(cands))
                    r = rng.random()
                    code = 0
                    if code_fn is not None:
                        code = code_fn(q, owner, len(self.sent[q]))
                    elif r < err_rates[0]:
                        code = 0b01
                    elif r < err_rates[0] + err_rates[1]:
                        code = 0b10
                    elif r < sum(err_rates):
                        code = 0b11
                    qid = rng.randrange(NUM_QUEUES) if code == 0b10 else q
                    op = (0, code, qid, rng.randrange(64))
                    op_owner = owner
            if op is None and rng.random() < read_noise:
                op = (1, rng.randrange(4), rng.randrange(NUM_QUEUES), rng.randrange(1 << 16))
            if op is not None:
                dut.OP_STAT_TYPE.value = op[0]
                dut.OP_STAT_CODE.value = op[1]
                dut.OP_STAT_QID.value = op[2]
                dut.OP_STAT_CID.value = op[3]
                dut.OP_STAT_VLD.value = 1
            else:
                dut.OP_STAT_VLD.value = 0
        else:
            raise AssertionError(f"traffic did not drain in {max_cycles} cycles")

        await Timer(1, unit="ns")
        dut.OP_STAT_VLD.value = 0
        dut.WR_MFB_DST_RDY.value = 0
        await ClockCycles(dut.CLK, 6)
        self.frames_sb.assert_empty()
        assert not self.werr_exp, f"expected WERR never raised: {self.werr_exp}"
        self.check_totals()

    def check_totals(self):
        dut = self.dut
        for s in range(STREAMS):
            got = int(dut.OUT_BYTES[s].value)
            assert got == self.model.out_bytes[s], f"OUT_BYTES({s}) {got}, expected {self.model.out_bytes[s]}"
        got = signal_int(dut.WR_OUTSTANDING)
        exp = self.model.outstanding_mask()
        assert got == exp, f"WR_OUTSTANDING {got:#x}, expected {exp:#x}"

    def finish(self):
        final_check_all(self.props)


def make_writers(tb, counts=(10, 40), small=False, qids=None, idle=(0, 30)):
    return [WriterEmu(tb.dut, s, random_frames(tb.rng, s, tb.rng.randint(*counts), qids=qids, small=small),
                      tb.rng, idle=idle) for s in range(STREAMS)]


@cocotb.test()
async def run_traffic(dut):
    """All writers at random rates and frame sizes, completions out of order, all successful."""
    tb = ArbBench(dut, 0x101)
    await tb.init()
    await tb.run(make_writers(tb))
    tb.log.info("%d frames merged", tb.frames_sb.checked)
    tb.finish()


@cocotb.test()
async def run_errors(dut):
    """Injected 01/10/11 completions and read statuses mixed in; masks and ERR_INFO per the model."""
    tb = ArbBench(dut, 0x202)
    await tb.init()
    await tb.run(make_writers(tb), err_rates=(0.05, 0.03, 0.03), read_noise=0.1)
    assert tb.werr_got > 0, "no write error was raised"
    tb.log.info("%d frames merged, %d write errors raised", tb.frames_sb.checked, tb.werr_got)
    tb.finish()


@cocotb.test()
async def run_reorder(dut):
    """Writes of several streams on one queue complete newest first and the oldest one fails: its
    stream was popped off the FIFO head by another's success, yet WERR_MASK must name it."""
    tb = ArbBench(dut, 0x505)
    await tb.init()
    rng = tb.rng
    for _ in range(12):
        q = rng.randrange(NUM_QUEUES)
        streams = rng.sample(range(STREAMS), rng.randint(2, min(4, STREAMS)))
        writers = [WriterEmu(dut, s, random_frames(rng, s, 1, qids=[q], small=True) if s in streams else [],
                             rng, idle=(0, 20)) for s in range(STREAMS)]
        fail = rng.choice((0b01, 0b11))
        await tb.run(writers, hold=(0, 1500), cpl_rate=0.5, sof_stall=(0.0, 1), fairness=False,
                     newest_first=True, code_fn=lambda _q, _owner, left: fail if left == 0 else 0)
    assert tb.owner_checks >= 12, f"{tb.owner_checks} reordered failures checked, 12 expected"
    tb.log.info("%d reordered failures named their owner", tb.owner_checks)
    tb.finish()


@cocotb.test()
async def run_early_done(dut):
    """Several streams write one queue and complete newest first, so each completion pops another
    stream's FIFO entry: no stream may read done while its own write is in flight, and an
    out-of-range status in the middle must name the stream that owns it."""
    tb = ArbBench(dut, 0x606)
    await tb.init()
    rng = tb.rng
    rounds = 16
    for rnd in range(rounds):
        q = rng.randrange(NUM_QUEUES)
        streams = rng.sample(range(STREAMS), rng.randint(2, min(4, STREAMS)))
        writers = [WriterEmu(dut, s, random_frames(rng, s, 1, qids=[q], small=True) if s in streams else [],
                             rng, idle=(0, 20)) for s in range(STREAMS)]
        oor_second = rnd % 2 == 1
        second = len(streams) - 2

        def code_fn(_q, _owner, left):
            return 0b10 if oor_second and left == second else 0

        await tb.run(writers, hold=(0, 1500), cpl_rate=0.5, sof_stall=(0.0, 1), fairness=False,
                     newest_first=True, code_fn=code_fn)
        if oor_second:
            # The out-of-range status leaves its FIFO entry behind.
            await Timer(1, unit="ns")
            dut.CLEAR.value = 1
            await RisingEdge(dut.CLK)
            await Timer(1, unit="ns")
            dut.CLEAR.value = 0
            await ClockCycles(dut.CLK, 3)
            tb.model = FsWrArbModel(STREAMS, NUM_QUEUES)
            tb.check_totals()
    assert tb.owner_checks >= rounds // 2, f"{tb.owner_checks} out-of-range statuses checked"
    assert tb.early_done_cases > 0, "no completion ever popped another stream's entry"
    tb.log.info("%d out-of-range owners named, %d cycles a per-head count would read done early",
                tb.owner_checks, tb.early_done_cases)
    tb.finish()


@cocotb.test()
async def run_fifo_full(dut):
    """Completions held back while small frames pile onto two queues: grants to a queue with a full
    completion FIFO must stop, the other queues keep flowing."""
    tb = ArbBench(dut, 0x303)
    await tb.init()
    writers = make_writers(tb, counts=(25, 40), small=True, qids=[0, 0, 0, 1, 2, 3], idle=(0, 3))
    # Frames go out every ~40 cycles; the hold must outlast more than CPL_ITEMS of them to one queue.
    await tb.run(writers, hold=(0, 12000), cpl_rate=0.5, sof_stall=(0.02, 20), fairness=False)
    assert tb.full_skips > 0, f"no completion FIFO ever filled, the deepest held {tb.max_qlen} of {CPL_ITEMS}"
    tb.log.info("%d frames merged, %d request-cycles held by a full FIFO", tb.frames_sb.checked, tb.full_skips)
    tb.finish()


@cocotb.test()
async def run_clear(dut):
    """CLEAR returns the counters and the stale FIFO entries a code-10 status leaves behind to zero."""
    tb = ArbBench(dut, 0x404)
    await tb.init()
    await tb.run(make_writers(tb, counts=(5, 15)), err_rates=(0.0, 0.1, 0.0))
    await Timer(1, unit="ns")
    dut.CLEAR.value = 1
    await RisingEdge(dut.CLK)
    await Timer(1, unit="ns")
    dut.CLEAR.value = 0
    await ClockCycles(dut.CLK, 3)
    tb.model = FsWrArbModel(STREAMS, NUM_QUEUES)
    tb.check_totals()
    await tb.run(make_writers(tb, counts=(5, 15)))
    tb.finish()
