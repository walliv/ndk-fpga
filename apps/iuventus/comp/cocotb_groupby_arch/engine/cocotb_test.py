# cocotb_test.py: does the GROUP BY engine aggregate an SSD read stream exactly?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
import os
import random
from collections import defaultdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer

from cocotbext.ofm.mfb.properties import attach_mfb_properties

# Must match the engine's own geometry; the Makefile shrinks SLOTS so a full sweep fits in a test.
LANES = 4
SLOTS = int(os.environ.get("SLOTS", 128))
RD_LBA_NUM = int(os.environ.get("RD_LBA_NUM", 1))
GROUPS = LANES * SLOTS
SECT_BEATS = 8
RECS_BEAT = 4
RECS_SECT = SECT_BEATS * RECS_BEAT
SUM_MASK = (1 << 64) - 1
NUM_QUEUES = 4
# WR_MFB_META layout: CTL_OUT_QID in the high bits, the LBA pointer in the low LBA_PTR_W bits --
# matches IUVENTUS_GROUPBY_ENGINE's WR_MFB_META <= CTL_OUT_QID & wb_lba.
LBA_PTR_W = 64
QID_W = max(1, (NUM_QUEUES - 1).bit_length())

(S_IDLE, S_FILL, S_FILL_WAIT, S_CLEAR, S_RUN, S_DRAIN, S_WB, S_DONE,
 S_ERR) = range(9)


def seeded(salt):
    """A generator seeded off cocotb's own seed, so every run drives different traffic.

    A pinned seed here would make the suite deterministic and blind: the same gaps, the same
    ready pattern, the same key stream on every run. COCOTB_RANDOM_SEED still reproduces a run.
    """
    return random.Random(random.randrange(1 << 32) ^ salt)


async def tick(dut):
    """Advance one cycle and settle 1 ns past the edge.

    Every stimulus write in this bench happens here, so a driven ready line always belongs to the
    cycle that just started. Sampling at the ReadOnly that follows pairs it with the registered
    signals of that same cycle; the properties use sample_delay to land in the same place.
    """
    await RisingEdge(dut.CLK)
    await Timer(1, unit="ns")


def pack_beat(records):
    """Four {key, value} records into one 64 B beat, record 0 in the low bits."""
    word = 0
    for i, (key, value) in enumerate(records):
        word |= ((value & SUM_MASK) << 64 | (key & SUM_MASK)) << (128 * i)
    return word


def model(records):
    """Reference: exact per-key sum for in-range keys, plus the out-of-range tally."""
    sums = defaultdict(int)
    oor = 0
    for key, value in records:
        if key >= GROUPS:
            oor += 1
        else:
            sums[key] = (sums[key] + value) & SUM_MASK
    return sums, oor


def combined(queues):
    """Flattens a {qid: records} mapping into the record stream the table actually aggregates.

    Aggregation is commutative, so cross-queue order does not matter, only the total per key.
    """
    return [rec for recs in queues.values() for rec in recs]


class Storage:
    """Backs the read path: (qid, sector index) -> list of RECS_SECT records.

    Keyed per queue, one store per drive, so a run that reads the wrong queue's range is
    detectable instead of silently returning another queue's data.
    """

    def __init__(self):
        self.sectors = {}

    def fill(self, qid, base_lba, records):
        assert len(records) % RECS_SECT == 0, "records must fill whole sectors"
        for s in range(len(records) // RECS_SECT):
            self.sectors[(qid, base_lba + s)] = records[s * RECS_SECT:(s + 1) * RECS_SECT]

    def sector(self, qid, lba):
        return self.sectors.get((qid, lba), [(GROUPS + 1, 0)] * RECS_SECT)


class ReadResponder:
    """Stands in for DMA Iuventus on the read side.

    Accepts requests from any queue, then streams each one's sectors back as an MFB frame and
    posts a completion carrying that request's own QID. Frames never interleave, matching the
    DMA's one-frame-per-request contract, but requests may be outstanding on several queues at
    once: accepted requests queue up in `pending` well ahead of `serve()` actually streaming them.
    """

    def __init__(self, dut, storage, rd_latency=(4, 30), gap_rate=0.25, seed=0):
        self.dut = dut
        self.storage = storage
        self.rd_latency = rd_latency
        self.gap_rate = gap_rate
        self.rnd = seeded(seed)
        self.pending = []
        # Every accepted (qid, lba, num), append-only and never popped, for tests that check the
        # address sequence a queue's cursor issued rather than just the aggregated result.
        self.accept_log = []
        # QID of each accepted request not yet completed, oldest first -- lets a test observe more
        # than one queue's request outstanding at once.
        self.inflight_qids = []
        self.err_after = None
        # qid -> completion code: the next request accepted from that queue fails immediately,
        # without streaming any data, so a test can control exactly which queue fails and when.
        self.fail_qids = {}
        # When True, every write-back completion is posted as a failure instead of a success.
        self.wr_fail = False
        # When True, queued write completions are held back rather than posted, parking a fill run
        # in S_FILL_WAIT indefinitely.
        self.hold_wr_stats = False
        # Beats of a read frame still undelivered when its completion is posted. Hardware works
        # this way: the completion says the data reached the DMA's buffer, not that the engine has
        # seen it, so a run that trusts the completion alone leaves its tail behind.
        self.stat_early_beats = 0
        self.issued = 0
        self.completed = 0
        self.beats_sent = 0
        self.busy = False
        self.wr_stats = []

    async def watch(self):
        """Request sampler. Never drives, so it may run beside the frame driver."""
        dut = self.dut
        while True:
            await tick(dut)
            await ReadOnly()
            if dut.RD_REQ_VLD.value == 1:
                qid = int(dut.RD_REQ_QID.value)
                lba = int(dut.RD_REQ_LBA_PTR.value)
                num = int(dut.RD_REQ_LBA_NUM.value) + 1
                self.pending.append((qid, lba, num))
                self.accept_log.append((qid, lba, num))
                self.inflight_qids.append(qid)
                self.issued += 1

    async def serve(self):
        dut = self.dut
        dut.RD_MFB_SRC_RDY.value = 0
        dut.RD_MFB_SOF.value = 0
        dut.RD_MFB_EOF.value = 0
        dut.RD_MFB_SOF_POS.value = 0
        dut.RD_MFB_EOF_POS.value = 0x3F
        dut.RD_MFB_DATA.value = 0
        dut.OP_STAT_VLD.value = 0
        dut.OP_STAT_TYPE.value = 0
        dut.OP_STAT_CODE.value = 0
        dut.OP_STAT_QID.value = 0

        while True:
            if self.wr_stats and not self.hold_wr_stats:
                code = self.wr_stats.pop(0)
                await self._post_stat(code=code, stat_type=0)
                continue

            if not self.pending:
                await tick(dut)
                continue

            self.busy = True
            qid, lba, num = self.pending.pop(0)
            if qid in self.fail_qids:
                # Fails without ever touching RD_MFB, so a test can control precisely which
                # queue fails, with no dependency on rd_latency's random draw.
                code = self.fail_qids.pop(qid)
                await self._post_stat(code=code, qid=qid)
                self.inflight_qids.remove(qid)
                self.busy = False
                continue

            for _ in range(self.rnd.randint(*self.rd_latency)):
                await tick(dut)

            if self.err_after is not None and self.completed >= self.err_after:
                # A failed read never delivers a frame: post the status and move on, exactly
                # as the DMA does on a non-success completion code.
                await self._post_stat(code=self.rnd.randint(1, 3), qid=qid)
                self.inflight_qids.remove(qid)
                self.busy = False
                continue

            early_at = None
            if self.stat_early_beats:
                early_at = max(0, num * SECT_BEATS - self.stat_early_beats)
            sent = 0
            for s in range(num):
                for b in range(SECT_BEATS):
                    if early_at is not None and sent == early_at:
                        await self._post_stat(code=0, qid=qid)
                    recs = self.storage.sector(qid, lba + s)[b * RECS_BEAT:(b + 1) * RECS_BEAT]
                    await self._beat(pack_beat(recs), sof=(b == 0), eof=(b == SECT_BEATS - 1))
                    sent += 1
            if early_at is None:
                await self._post_stat(code=0, qid=qid)
            self.inflight_qids.remove(qid)
            self.completed += 1
            self.busy = False

    async def quiesce(self):
        """Wait for the outstanding reads of an aborted or failed run to run dry.

        S_ERR keeps accepting read data, so each frame still in flight drains on its own and its
        completion follows. Re-arming before that would let a stale completion land inside the next
        run and count against its issue tally, which is why software reconciles the two tallies
        first rather than resetting the DMA.
        """
        for _ in range(20000):
            if not self.pending and not self.busy:
                return
            await tick(self.dut)
        raise AssertionError(f"read side never drained: pending={self.pending} busy={self.busy}")

    async def _beat(self, word, sof, eof):
        dut = self.dut
        while self.rnd.random() < self.gap_rate:
            dut.RD_MFB_SRC_RDY.value = 0
            await tick(dut)

        dut.RD_MFB_DATA.value = word
        dut.RD_MFB_SOF.value = 1 if sof else 0
        dut.RD_MFB_EOF.value = 1 if eof else 0
        dut.RD_MFB_SRC_RDY.value = 1
        while True:
            await ReadOnly()
            accepted = dut.RD_MFB_DST_RDY.value == 1
            await tick(dut)
            if accepted:
                break
        dut.RD_MFB_SRC_RDY.value = 0
        self.beats_sent += 1

    async def _post_stat(self, code, stat_type=1, qid=0):
        dut = self.dut
        dut.OP_STAT_VLD.value = 1
        dut.OP_STAT_TYPE.value = stat_type
        dut.OP_STAT_CODE.value = code
        dut.OP_STAT_QID.value = qid
        await tick(dut)
        dut.OP_STAT_VLD.value = 0
        dut.OP_STAT_CODE.value = 0


class WriteSink:
    """Collects the result frames and checks their framing as they arrive."""

    def __init__(self, dut, responder, storage, ready_rate=0.7, seed=0):
        self.dut = dut
        self.responder = responder
        self.storage = storage
        self.ready_rate = ready_rate
        self.rnd = seeded(seed + 1)
        self.records = []
        self.frames = []
        self._cur = []
        self._cur_meta = None
        self.errors = []

    async def run(self):
        dut = self.dut
        while True:
            ready = self.rnd.random() < self.ready_rate
            dut.WR_MFB_DST_RDY.value = 1 if ready else 0
            await ReadOnly()
            if ready and dut.WR_MFB_SRC_RDY.value == 1:
                self._accept(int(dut.WR_MFB_DATA.value), int(dut.WR_MFB_SOF.value),
                             int(dut.WR_MFB_EOF.value), int(dut.WR_MFB_META.value))
            await tick(dut)

    def _accept(self, data, sof, eof, meta):
        if sof:
            if self._cur:
                self.errors.append("SOF arrived while a frame was still open")
            self._cur = []
            self._cur_meta = meta
        elif not self._cur:
            self.errors.append("beat outside a frame (no SOF seen)")
        for i in range(RECS_BEAT):
            rec = (data >> (128 * i)) & ((1 << 128) - 1)
            self._cur.append((rec & SUM_MASK, rec >> 64))
        if eof:
            if len(self._cur) != RECS_SECT:
                self.errors.append(f"frame of {len(self._cur)} records, expected {RECS_SECT}")
            self.frames.append((self._cur_meta, self._cur))
            self.records.extend(self._cur)
            # Each drive is its own store: a sector written here is what a later read of the same
            # (queue, LBA) returns, which is what makes the self-test fill readable back.
            qid = (self._cur_meta >> LBA_PTR_W) & ((1 << QID_W) - 1)
            lba = self._cur_meta & ((1 << LBA_PTR_W) - 1)
            self.storage.sectors[(qid, lba)] = list(self._cur)
            self._cur = []
            # Every written frame is a command the DMA completes, and the fill phase waits for
            # those completions before it reads its own data back; forcing a failure here exercises
            # S_WB's abort path instead of the normal one.
            self.responder.wr_stats.append(1 if self.responder.wr_fail else 0)


async def prepare(dut, seed=0, gap_rate=0.25, ready_rate=0.7, rd_latency=(4, 30)):
    # Clock and stimulus are started per test: cocotb cancels a test's tasks when it ends, so one
    # started in an earlier test would already be dead here.
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    storage = Storage()
    rd = ReadResponder(dut, storage, rd_latency=rd_latency, gap_rate=gap_rate, seed=seed)
    wr = WriteSink(dut, rd, storage, ready_rate=ready_rate, seed=seed)

    dut.CTL_START.value = 0
    dut.CTL_FILL.value = 0
    dut.CTL_ABORT.value = 0
    dut.CTL_IN_LBA.value = 0
    dut.CTL_IN_COUNT.value = 0
    dut.CTL_OUT_LBA.value = 0
    dut.CTL_OUT_QID.value = 0
    dut.CTL_QID_MASK.value = (1 << NUM_QUEUES) - 1
    dut.RD_REQ_RDY.value = (1 << NUM_QUEUES) - 1
    dut.WR_MFB_DST_RDY.value = 0
    dut.RST.value = 1
    await ClockCycles(dut.CLK, 8)
    dut.RST.value = 0
    await tick(dut)

    # Both DMA-facing buses are checked for framing and handshake conformance. sample_delay clears
    # the 1 ns post-edge ready writes above, which would otherwise pair a post-edge ready with a
    # pre-edge valid and invent faults.
    props = attach_mfb_properties(
        dut, dut.CLK, reset=dut.RST, sample_delay=(2, "ns"), max_errors=4)
    assert set(props) == {"RD_MFB", "WR_MFB"}, f"unexpected MFB interfaces: {sorted(props)}"

    cocotb.start_soon(rd.watch())
    cocotb.start_soon(rd.serve())
    cocotb.start_soon(wr.run())
    return storage, rd, wr, props


async def run_engine(dut, storage, wr, queues, in_lba=0, out_lba=0x1000, timeout=400000,
                     fill=False, sectors=None):
    """Stage every queue's own records, start a run, and wait for it to reach DONE or ERR.

    `queues` maps qid -> records; every mapped queue must supply the same sector count, since
    CTL_IN_COUNT is the one register every enabled queue sweeps on its own drive. `sectors`
    overrides the derived count, which a fill run (no queues to seed) requires.
    """
    if not fill and queues:
        sector_counts = {len(recs) // RECS_SECT for recs in queues.values()}
        assert len(sector_counts) == 1, "every queue in one run must supply the same sector count"
        if sectors is None:
            sectors = next(iter(sector_counts))
    for qid, records in queues.items():
        storage.fill(qid, in_lba, records)

    dut.CTL_IN_LBA.value = in_lba
    dut.CTL_IN_COUNT.value = sectors
    dut.CTL_OUT_LBA.value = out_lba
    await tick(dut)
    dut.CTL_START.value = 1
    dut.CTL_FILL.value = 1 if fill else 0
    await tick(dut)
    dut.CTL_START.value = 0

    for _ in range(timeout):
        await tick(dut)
        await ReadOnly()
        state = int(dut.STS_STATE.value)
        if state in (S_DONE, S_ERR):
            # Sampled here because the caller cannot re-enter ReadOnly, and stepping out of it
            # first would let a later START change what it reads.
            sts = Status(state=state, busy=int(dut.STS_BUSY.value), done=int(dut.STS_DONE.value),
                         err=int(dut.STS_ERR.value), rec_cnt=int(dut.STS_REC_CNT.value),
                         oor_cnt=int(dut.STS_OOR_CNT.value),
                         result_sect=int(dut.STS_RESULT_SECT.value),
                         wr_issued=int(dut.STS_WR_ISSUED.value),
                         wr_compl=int(dut.STS_WR_COMPL.value),
                         err_code=int(dut.STS_ERR_CODE.value),
                         err_type=int(dut.STS_ERR_TYPE.value),
                         err_qid=int(dut.STS_ERR_QID.value),
                         err_vld=int(dut.STS_ERR_VLD.value))
            await tick(dut)
            return sts
    raise AssertionError(
        f"engine never finished: state={int(dut.STS_STATE.value)} "
        f"rec_cnt={int(dut.STS_REC_CNT.value)} wb_records={len(wr.records)}")


class Status:
    """Snapshot of the status registers at the moment the run finished."""

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def __repr__(self):
        return f"Status({self.__dict__})"


def check_result(wr, sums, dut):
    """The sweep emits every group in key order; only non-zero ones carry a sum."""
    assert not wr.errors, f"write-side framing errors: {wr.errors}"
    assert len(wr.records) == GROUPS, f"swept {len(wr.records)} groups, expected {GROUPS}"

    bad = []
    for idx, (key, value) in enumerate(wr.records):
        if key != idx:
            bad.append(f"slot {idx}: key {key}")
        elif value != sums.get(idx, 0):
            bad.append(f"key {idx}: sum {value}, expected {sums.get(idx, 0)}")
        if len(bad) >= 8:
            break
    assert not bad, "result mismatch: " + "; ".join(bad)

    frames = len(wr.frames)
    assert frames == GROUPS // RECS_SECT, f"{frames} result frames, expected {GROUPS // RECS_SECT}"
    lbas = [meta & ((1 << 64) - 1) for meta, _ in wr.frames]
    assert lbas == list(range(lbas[0], lbas[0] + frames)), "result LBAs are not consecutive"


@cocotb.test()
async def test_single_group(dut):
    """Every record on one key per queue: the RMW bypass has to accumulate back-to-back same-slot
    hits, and each queue's own key must land in its own slot rather than leak into another's."""
    storage, rd, wr, _ = await prepare(dut, seed=1)
    queues = {q: [(7 + q, 3)] * (RECS_SECT * 2) for q in range(NUM_QUEUES)}
    sums, _ = model(combined(queues))
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)
    for q in range(NUM_QUEUES):
        assert sums[7 + q] == 3 * RECS_SECT * 2
    dut._log.info(f"keys 7..{7 + NUM_QUEUES - 1} each accumulated to {3 * RECS_SECT * 2}")


@cocotb.test()
async def test_all_distinct(dut):
    """One record per group per queue; each queue's value is offset so a cross-queue read (e.g. a
    queue that reads another's sectors) is detectable rather than masked by identical data."""
    storage, rd, wr, _ = await prepare(dut, seed=2)
    queues = {q: [(k, k + 1 + q) for k in range(GROUPS)] for q in range(NUM_QUEUES)}
    sums, _ = model(combined(queues))
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)


@cocotb.test()
async def test_worst_case_lane_skew(dut):
    """All four records of every beat target one lane, on every queue at once, so beats retire at
    a quarter rate while queues also contend for the same lane; values are offset per queue so a
    cross-queue read is still detectable."""
    storage, rd, wr, _ = await prepare(dut, seed=3)
    # key % LANES selects the lane; stepping by LANES keeps every record on lane 0.
    queues = {q: [(LANES * (i % SLOTS), 5 + q) for i in range(RECS_SECT * 4)]
              for q in range(NUM_QUEUES)}
    sums, _ = model(combined(queues))
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)
    lanes = {k % LANES for k in sums}
    assert lanes == {0}, f"stimulus leaked off lane 0: {lanes}"


@cocotb.test()
async def test_out_of_range_keys(dut):
    """Keys at and beyond the table are counted, never aggregated, and never stall a beat, summed
    over every queue; values are offset per queue so a cross-queue read is still detectable."""
    storage, rd, wr, _ = await prepare(dut, seed=4)

    def make_records(q):
        records = []
        for i in range(RECS_SECT * 2):
            if i % 3 == 0:
                records.append((GROUPS + i, 111))
            else:
                records.append((i % GROUPS, 2 + q))
        # The boundary itself must be excluded, not included.
        records[0] = (GROUPS, 999)
        return records

    queues = {q: make_records(q) for q in range(NUM_QUEUES)}
    total_records = combined(queues)
    sums, oor = model(total_records)
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)
    assert sts.oor_cnt == oor, f"OOR_CNT {sts.oor_cnt}, expected {oor}"
    assert sts.rec_cnt == len(total_records), f"REC_CNT {sts.rec_cnt}, expected {len(total_records)}"
    assert oor > 0, "stimulus produced no out-of-range records"


@cocotb.test()
async def test_random_keys(dut):
    """Random keys over several sectors, one independent stream per queue, checked against the
    Python model."""
    storage, rd, wr, _ = await prepare(dut, seed=5)
    queues = {}
    for q in range(NUM_QUEUES):
        rnd = seeded(0xB16 + q)
        queues[q] = [(rnd.randrange(GROUPS), rnd.randrange(1 << 20)) for _ in range(RECS_SECT * 6)]
    total_records = combined(queues)
    sums, _ = model(total_records)
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)
    collisions = len(total_records) - len(sums)
    assert collisions > 0, "no key repeated, so the accumulate path was never exercised"
    dut._log.info(f"{len(sums)} distinct keys, {collisions} repeats")


@cocotb.test()
async def test_writeback_backpressure(dut):
    """A sink that is ready one cycle in eight must still receive every group exactly once, summed
    over every queue that swept it."""
    storage, rd, wr, _ = await prepare(dut, seed=6, ready_rate=0.125)
    queues = {q: [(k, 1 + q) for k in range(GROUPS)] for q in range(NUM_QUEUES)}
    sums, _ = model(combined(queues))
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)


@cocotb.test()
async def test_read_error_aborts(dut):
    """A non-success completion never drains its frame, so the run must abort, not hang. Restricted
    to one queue so the failing command is unambiguous."""
    storage, rd, wr, _ = await prepare(dut, seed=7)
    dut.CTL_QID_MASK.value = 0b0001
    rd.err_after = 1
    records = [(k % GROUPS, 1) for k in range(RECS_SECT * 8)]
    assert len(records) // RECS_SECT > RD_LBA_NUM + 1, "input fits in one command, so no command can fail after a success"
    sts = await run_engine(dut, storage, wr, {0: records}, timeout=200000)
    assert sts.state == S_ERR, f"ended in {sts}, expected S_ERR"
    assert sts.err == 1 and sts.busy == 0, f"status contradicts S_ERR: {sts}"
    assert not wr.records, "a failed run must not write results back"


@cocotb.test()
async def test_restart_after_error(dut):
    """START from S_ERR must re-arm: the table is cleared and the previous tally is dropped."""
    storage, rd, wr, _ = await prepare(dut, seed=8)
    dut.CTL_QID_MASK.value = 0b0001
    rd.err_after = 1
    records = [(k % GROUPS, 1) for k in range(RECS_SECT * 8)]
    sts = await run_engine(dut, storage, wr, {0: records}, timeout=200000)
    assert sts.state == S_ERR, f"ended in {sts}, expected S_ERR"

    rd.err_after = None
    await rd.quiesce()
    records = [(3, 10)] * RECS_SECT
    sums, _ = model(records)
    sts = await run_engine(dut, storage, wr, {0: records}, in_lba=0x800)
    assert sts.state == S_DONE, f"restart ended in {sts}"
    check_result(wr, sums, dut)
    assert sts.rec_cnt == len(records), "REC_CNT carried over from the failed run"


@cocotb.test()
async def test_queue_mask_skips(dut):
    """A masked-off queue must never be issued to, and only the enabled queues' own data may
    appear in the swept result -- CTL_QID_MASK=0b0101 enables queues 0 and 2 only."""
    storage, rd, wr, _ = await prepare(dut, seed=9)
    dut.CTL_QID_MASK.value = 0b0101
    seen = set()

    async def watch_qid():
        while True:
            await tick(dut)
            await ReadOnly()
            if dut.RD_REQ_VLD.value == 1:
                seen.add(int(dut.RD_REQ_QID.value))

    cocotb.start_soon(watch_qid())
    queues = {0: [(k % GROUPS, 4) for k in range(RECS_SECT * 8)],
              2: [(k % GROUPS, 7) for k in range(RECS_SECT * 8)]}
    sums, _ = model(combined(queues))
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)
    assert seen == {0, 2}, f"issued to queues {sorted(seen)}, mask allowed {{0, 2}}"


@cocotb.test()
async def test_not_ready_queue_is_skipped(dut):
    """The DMA is single-issue, so a not-ready queue must cost a cycle, never block the sweep.
    Queue 3 is masked off rather than left never-ready: an enabled queue owns its own full range,
    so one that never became ready would never finish its own sweep."""
    storage, rd, wr, _ = await prepare(dut, seed=10)
    dut.CTL_QID_MASK.value = 0b0111
    queues = {q: [(k % GROUPS, 6 + q) for k in range(RECS_SECT * 8)] for q in range(3)}
    sums, _ = model(combined(queues))

    async def flap_ready():
        rnd = seeded(11)
        while True:
            await tick(dut)
            # Queue 3 is masked off; the rest come and go.
            dut.RD_REQ_RDY.value = rnd.randrange(0, 8)

    cocotb.start_soon(flap_ready())
    seen = set()

    async def watch_qid():
        while True:
            await tick(dut)
            await ReadOnly()
            if dut.RD_REQ_VLD.value == 1:
                seen.add(int(dut.RD_REQ_QID.value))

    cocotb.start_soon(watch_qid())
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    check_result(wr, sums, dut)
    assert 3 not in seen, "issued to a masked-off queue"
    assert seen == {0, 1, 2}, f"expected every enabled queue to be used, got {sorted(seen)}"


@cocotb.test()
async def test_self_test_fill(dut):
    """The fill writes its own records on one queue, then aggregates them: group g must hold
    count(g)*(g+1)."""
    storage, rd, wr, _ = await prepare(dut, seed=12)
    dut.CTL_QID_MASK.value = 0b0001

    sectors = 6
    sts = await run_engine(dut, storage, wr, {}, in_lba=0x200, out_lba=0x1000,
                           sectors=sectors, fill=True)
    assert sts.state == S_DONE, f"ended in {sts}"

    # The fill writes before the sweep does, so its frames are the first `sectors` collected.
    fills, results = wr.frames[:sectors], wr.frames[sectors:]
    written = [rec for _, frame in fills for rec in frame]
    assert len(written) == sectors * RECS_SECT, \
        f"fill wrote {len(written)} records, expected {sectors * RECS_SECT}"
    # key = index mod GROUPS, value = key + 1.
    for idx, (key, value) in enumerate(written):
        assert key == idx % GROUPS and value == key + 1, \
            f"fill record {idx} is ({key}, {value})"

    lbas = sorted({meta & ((1 << 64) - 1) for meta, _ in fills})
    assert lbas == list(range(0x200, 0x200 + sectors)), f"fill LBAs {lbas}"

    wr.frames = results
    wr.records = [rec for _, frame in results for rec in frame]
    sums, _ = model(written)
    check_result(wr, sums, dut)
    assert sts.rec_cnt == len(written), f"REC_CNT {sts.rec_cnt}, expected {len(written)}"


@cocotb.test()
async def test_per_queue_cursor_coverage(dut):
    """Every enabled queue must sweep its OWN [CTL_IN_LBA, +CTL_IN_COUNT) range exactly once, with
    no gaps and no repeats, independent of the others -- the whole point of a cursor per queue.
    RD_LBA_NUM=1 (2 sectors/command) means each queue needs several commands to cover it."""
    storage, rd, wr, _ = await prepare(dut, seed=13)
    in_lba, sectors = 0x100, 10
    sts = await run_engine(dut, storage, wr, {}, in_lba=in_lba, sectors=sectors)
    assert sts.state == S_DONE, f"ended in {sts}"

    by_qid = defaultdict(list)
    for qid, lba, num in rd.accept_log:
        by_qid[qid].append((lba, num))
    assert set(by_qid) == set(range(NUM_QUEUES)), \
        f"queues issued: {sorted(by_qid)}, expected all of {sorted(range(NUM_QUEUES))}"

    for qid, reqs in by_qid.items():
        cursor = in_lba
        for lba, num in reqs:
            assert lba == cursor, \
                f"queue {qid}: request at {lba:#x}, expected {cursor:#x} (gap or repeat)"
            cursor += num
        assert cursor == in_lba + sectors, \
            f"queue {qid}: swept up to {cursor:#x}, expected {in_lba + sectors:#x}"


@cocotb.test()
async def test_concurrent_queues_outstanding(dut):
    """Requests from more than one queue must be able to sit outstanding at once -- the point of a
    cursor per queue -- so a long, held-up response must not stop the round robin from accepting
    other queues' requests in the meantime."""
    storage, rd, wr, _ = await prepare(dut, seed=17, rd_latency=(60, 90))
    queues = {q: [(k % GROUPS, 1 + q) for k in range(RECS_SECT * 2)] for q in range(NUM_QUEUES)}

    max_distinct = 0

    async def sample():
        nonlocal max_distinct
        while True:
            await tick(dut)
            await ReadOnly()
            max_distinct = max(max_distinct, len(set(rd.inflight_qids)))

    cocotb.start_soon(sample())
    sts = await run_engine(dut, storage, wr, queues)
    assert sts.state == S_DONE, f"ended in {sts}"
    assert max_distinct >= 2, \
        f"never observed more than {max_distinct} distinct queue(s) with a request outstanding"


@cocotb.test()
async def test_abort_from_run(dut):
    """CTL_ABORT must escape S_RUN, ending the run in S_ERR instead of hanging on a completion
    that will never arrive."""
    storage, rd, wr, _ = await prepare(dut, seed=16, rd_latency=(20, 40))
    dut.CTL_QID_MASK.value = 0b0001
    records = [(k % GROUPS, 1) for k in range(RECS_SECT * 4)]
    storage.fill(0, 0, records)
    dut.CTL_IN_LBA.value = 0
    dut.CTL_IN_COUNT.value = len(records) // RECS_SECT
    dut.CTL_OUT_LBA.value = 0x1000
    await tick(dut)
    dut.CTL_START.value = 1
    await tick(dut)
    dut.CTL_START.value = 0

    for _ in range(100000):
        # No ReadOnly() here: tick()'s own 1 ns settle already gives a correct sample, and the
        # abort write right below must land in the writable phase that follows, not ReadOnly.
        await tick(dut)
        if int(dut.STS_STATE.value) == S_RUN:
            break
    else:
        raise AssertionError("run never reached S_RUN")

    dut.CTL_ABORT.value = 1
    state = None
    for _ in range(200000):
        # No ReadOnly() here either: the deassert below must land in the writable phase.
        await tick(dut)
        state = int(dut.STS_STATE.value)
        if state in (S_DONE, S_ERR):
            break
    else:
        raise AssertionError("run never settled after abort")
    dut.CTL_ABORT.value = 0
    assert state == S_ERR, f"CTL_ABORT during S_RUN ended in state {state}, expected S_ERR"
    assert not wr.records, "an aborted run must not write results back"


@cocotb.test()
async def test_abort_from_fill_wait(dut):
    """CTL_ABORT must also escape S_FILL_WAIT: parked there by holding back the fill's own write
    completions, exactly the case the abort exists for (a completion that will never arrive)."""
    storage, rd, wr, _ = await prepare(dut, seed=15)
    rd.hold_wr_stats = True
    dut.CTL_IN_LBA.value = 0x300
    dut.CTL_IN_COUNT.value = 2
    dut.CTL_OUT_LBA.value = 0x1000
    await tick(dut)
    dut.CTL_START.value = 1
    dut.CTL_FILL.value = 1
    await tick(dut)
    dut.CTL_START.value = 0
    dut.CTL_FILL.value = 0

    for _ in range(100000):
        # No ReadOnly() here: tick()'s own 1 ns settle already gives a correct sample, and the
        # abort write right below must land in the writable phase that follows, not ReadOnly.
        await tick(dut)
        if int(dut.STS_STATE.value) == S_FILL_WAIT:
            break
    else:
        raise AssertionError("run never reached S_FILL_WAIT")

    dut.CTL_ABORT.value = 1
    state = None
    for _ in range(1000):
        # No ReadOnly() here either: the deassert below must land in the writable phase.
        await tick(dut)
        state = int(dut.STS_STATE.value)
        if state in (S_DONE, S_ERR):
            break
    else:
        raise AssertionError("run never settled after abort")
    dut.CTL_ABORT.value = 0
    rd.hold_wr_stats = False
    assert state == S_ERR, f"CTL_ABORT during S_FILL_WAIT ended in state {state}, expected S_ERR"


@cocotb.test()
async def test_abort_from_drain(dut):
    """CTL_ABORT must also escape S_DRAIN: caught the instant STS_STATE registers that value,
    since the lane pipeline drains in only a cycle or two."""
    storage, rd, wr, _ = await prepare(dut, seed=14)
    dut.CTL_QID_MASK.value = 0b0001
    records = [(k % GROUPS, 1) for k in range(RECS_SECT * 2)]
    storage.fill(0, 0, records)
    dut.CTL_IN_LBA.value = 0
    dut.CTL_IN_COUNT.value = len(records) // RECS_SECT
    dut.CTL_OUT_LBA.value = 0x1000
    await tick(dut)
    dut.CTL_START.value = 1
    await tick(dut)
    dut.CTL_START.value = 0

    for _ in range(100000):
        # No ReadOnly() here: tick()'s own 1 ns settle already gives a correct sample, and the
        # abort write below must land in that same writable phase, not in ReadOnly.
        await tick(dut)
        if int(dut.STS_STATE.value) == S_DRAIN:
            dut.CTL_ABORT.value = 1
            break
    else:
        raise AssertionError("run never reached S_DRAIN")

    state = None
    for _ in range(1000):
        # No ReadOnly() here either: the deassert below must land in the writable phase.
        await tick(dut)
        state = int(dut.STS_STATE.value)
        if state in (S_DONE, S_ERR):
            break
    else:
        raise AssertionError("run never settled after abort")
    dut.CTL_ABORT.value = 0
    assert state == S_ERR, f"CTL_ABORT during S_DRAIN ended in state {state}, expected S_ERR"


@cocotb.test()
async def test_writeback_failure_aborts(dut):
    """Every result write-back completion failing must end the run in S_ERR, not S_DONE: S_WB now
    tests err_r, and S_DONE additionally requires wr_compl == wr_issued."""
    storage, rd, wr, _ = await prepare(dut, seed=18)
    dut.CTL_QID_MASK.value = 0b0001
    rd.wr_fail = True
    records = [(k % GROUPS, 1) for k in range(RECS_SECT * 2)]
    sts = await run_engine(dut, storage, wr, {0: records}, timeout=200000)
    assert sts.state == S_ERR, f"ended in {sts}, expected S_ERR"
    assert sts.wr_issued > 0, "the write-back never even started, so this never exercised S_WB"


@cocotb.test()
async def test_err_info_latches_first_failure(dut):
    """ERR_INFO latches the code/type/qid of the FIRST failing completion and stays put even when
    a second, different failure follows -- the identity that explains the run is the one that
    ended it. Only queues 0 and 1 are enabled so their fail order is unambiguous."""
    storage, rd, wr, _ = await prepare(dut, seed=19)
    dut.CTL_QID_MASK.value = 0b0011
    rd.fail_qids = {0: 1, 1: 2}
    records = [(k % GROUPS, 1) for k in range(RECS_SECT * 2)]
    sts = await run_engine(dut, storage, wr, {0: records, 1: records}, timeout=200000)
    assert sts.state == S_ERR, f"ended in {sts}, expected S_ERR"
    assert sts.err_vld == 1, "ERR_INFO was never latched"
    assert sts.err_code == 1, f"ERR_INFO code {sts.err_code}, expected queue 0's code (1)"
    assert sts.err_type == 1, f"ERR_INFO type {sts.err_type}, expected READ (1)"
    assert sts.err_qid == 0, f"ERR_INFO qid {sts.err_qid}, expected queue 0 (the first to fail)"


@cocotb.test()
async def test_completion_before_data_keeps_the_tail(dut):
    """A read completion says the data reached the DMA's buffer, not that the engine has seen it.

    The responder posts each completion with beats still to come, as the hardware does. A run that
    treats the completion as proof of arrival ends early and strands its tail, which the next run
    then absorbs -- so this checks both that this run's tally is exact and that the following run's
    is untouched by it.
    """
    storage, rd, wr, _ = await prepare(dut, seed=21)
    dut.CTL_QID_MASK.value = 0b0011
    rd.stat_early_beats = 6

    first = {q: [((k * 7 + q) % GROUPS, q + 1) for k in range(RECS_SECT * 4)] for q in (0, 1)}
    sums, _ = model([r for recs in first.values() for r in recs])
    sts = await run_engine(dut, storage, wr, first)
    assert sts.state == S_DONE, f"run ended in {sts}"
    expect = sum(len(r) for r in first.values())
    assert sts.rec_cnt == expect, \
        f"REC_CNT {sts.rec_cnt}, expected {expect}: the run left its tail behind"
    check_result(wr, sums, dut)

    wr.frames.clear()
    wr.records.clear()
    second = {q: [(5, 3)] * RECS_SECT for q in (0, 1)}
    sums2, _ = model([r for recs in second.values() for r in recs])
    sts = await run_engine(dut, storage, wr, second, in_lba=0x800)
    assert sts.state == S_DONE, f"second run ended in {sts}"
    expect2 = sum(len(r) for r in second.values())
    assert sts.rec_cnt == expect2, \
        f"second REC_CNT {sts.rec_cnt}, expected {expect2}: it absorbed the first run's tail"
    check_result(wr, sums2, dut)
