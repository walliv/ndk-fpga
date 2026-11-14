# cocotb_test.py: does FS_OUT_WRITER turn a kernel's output into exactly the planned disk writes?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotbext.ofm.utils.signals import signal_int

from fs_ctx import BEAT, ERR_SRC_FORMAT, MAX_LOG2_CHUNK, SECT, err_info, extent_entry, lbas_needed
from fs_out_writer_model import Write, output_breakers, plan_writes
from fs_tb_util import release_reset, seeded, start_clock
from scoreboard import Scoreboard

# Must match the elaborated generic; the fallback is the RTL default.
SL = int(os.environ.get("STAGE_LOG2_BEATS", 12))
MAX_LC = min(MAX_LOG2_CHUNK, SL - 3)


def kernel_beats(out, rng):
    """The kernel's beats for output `out`: 64 B each, the last one partial, garbage past its end."""
    if not out:
        return [(rng.getrandbits(512), 0, 1)]
    beats = []
    for pos in range(0, len(out), BEAT):
        chunk = out[pos:pos + BEAT]
        raw = chunk + rng.randbytes(BEAT - len(chunk))
        beats.append((int.from_bytes(raw, "little"), len(chunk), int(pos + BEAT >= len(out))))
    return beats


def random_extents(rng, nlbas, lc, extra=None):
    """Output extents whose capacity covers `nlbas` LBAs, a few spare ones after them."""
    chunk = 1 << lc
    ents = []
    cap = 0
    spare = rng.randint(0, 2) if extra is None else extra
    while cap < nlbas or spare > 0:
        if cap >= nlbas:
            spare -= 1
        kind = rng.random()
        if kind < 0.3:
            count = rng.randint(1, 4)
        elif kind < 0.6:
            count = rng.randint(1, 3 * chunk)
        elif kind < 0.85:
            count = chunk * rng.randint(1, 4)
        else:
            count = rng.randint(1, 1 << 20)
        base = rng.randrange(1 << 40)
        if rng.random() < 0.5:
            base = (base // chunk) * chunk + rng.choice([0, chunk - 1, chunk // 2])
        ents.append(extent_entry(base, count))
        cap += count
    return ents


class Job:
    def __init__(self, out, entries, ld, lc, release="eager", initial=None, kout_rate=1.0, grant_mode="fast",
                 abort_at=None):
        self.out = out
        self.entries = entries
        self.ld = ld
        self.lc = lc
        self.release = release
        self.initial = len(entries) if release == "eager" else (initial or 0)
        self.kout_rate = kout_rate
        self.grant_mode = grant_mode
        self.abort_at = abort_at


class WriterBench:
    def __init__(self, dut, salt):
        self.dut = dut
        self.rng = seeded(salt)
        self.log = dut._log
        self.kout_stalled = 0
        self.need_space_cycles = 0

    async def init(self):
        dut = self.dut
        start_clock(dut)
        for sig in (dut.CLEAR, dut.START, dut.ABORT, dut.ENABLE, dut.KOUT_VLD, dut.KOUT_LAST, dut.ENT_VLD,
                    dut.WREQ_RDY, dut.WDAT_RDY, dut.WR_OUTSTANDING):
            sig.value = 0
        dut.KOUT_DATA.value = 0
        dut.KOUT_BYTES.value = 0
        dut.ENT_DATA.value = 0
        dut.OUT_HEAD.value = 0
        dut.OUT_TAIL.value = 0
        dut.STRIPE_LOG2_DRIVES.value = 0
        dut.STRIPE_LOG2_CHUNK.value = 0
        dut.RESET.value = 1
        await release_reset(dut, 5, 2)

    def grant_delay(self, mode):
        r = self.rng.random()
        if mode == "slow":
            return self.rng.randint(50, 600) if r < 0.5 else self.rng.randint(0, 50)
        if r < 0.7:
            return self.rng.randint(0, 4)
        if r < 0.95:
            return self.rng.randint(5, 60)
        return self.rng.randint(100, 400)

    def sof_stall(self, mode):
        r = self.rng.random()
        if mode == "slow" or r < 0.1:
            return self.rng.randint(20, 400)
        return self.rng.randint(0, 6)

    async def run_job(self, job, max_cycles=None):
        """Drives one job from CLEAR and START to OUT_DONE (or to quiescence after ABORT / ERR).
        Returns a dict of what was observed."""
        dut = self.dut
        rng = self.rng
        writes, popped_exp, malformed = plan_writes(job.out, job.entries, job.ld, job.lc)
        sb = Scoreboard("writes")
        for w in writes:
            sb.expect(w)
        self.log.info("job: %d B, %d entries (%s, %d released), stripe 2**%d x 2**%d LBAs, %d writes%s",
                      len(job.out), len(job.entries), job.release, job.initial, job.ld, job.lc, len(writes),
                      ", malformed entry" if malformed else "")

        await Timer(1, unit="ns")
        dut.STRIPE_LOG2_DRIVES.value = job.ld
        dut.STRIPE_LOG2_CHUNK.value = job.lc
        dut.ENABLE.value = 1
        dut.OUT_HEAD.value = 0
        dut.OUT_TAIL.value = 0
        dut.CLEAR.value = 1
        await RisingEdge(dut.CLK)
        await Timer(1, unit="ns")
        dut.CLEAR.value = 0
        dut.START.value = 1
        await RisingEdge(dut.CLK)
        await Timer(1, unit="ns")
        dut.START.value = 0

        beats = kernel_beats(job.out, rng)
        k_idx = 0
        k_vld = 0
        accepted = 0
        head = 0
        tail = job.initial
        ent_vld = 0
        ent_wait = rng.randint(0, 8)
        popcap = 0
        release_at = None
        ns_armed = True
        snaps = {}

        arb = "idle"
        arb_wait = 0
        wreq_rdy = 0
        wdat_rdy = 0
        req = None
        req_seen = None
        frame_beats = 0
        frame_data = []
        first_taken = False
        stall_left = 0
        outstanding = 0
        cpl_due = []
        out_hist = {}
        received = []

        aborted_at = None
        err_seen = []
        done_seen = False
        quiet = 0

        # A budget that scales with the work: the slow grant mode spends up to ~1000 cycles per write.
        if max_cycles is None:
            max_cycles = 20000 + 1200 * len(writes) + 8 * len(beats)
        last_progress = 0

        for cyc in range(max_cycles):
            await RisingEdge(dut.CLK)
            kout_rdy = dut.KOUT_RDY.value
            ent_rdy = dut.ENT_RDY.value
            wreq_vld = dut.WREQ_VLD.value
            wdat_vld = dut.WDAT_VLD.value
            need = dut.NEED_SPACE.value
            done = dut.OUT_DONE.value
            busy = dut.BUSY.value
            err = dut.ERR.value

            snaps[cyc] = (head, tail, accepted, popcap)
            snaps.pop(cyc - 3, None)

            # -------- handshakes of the cycle that just ended
            if k_vld and kout_rdy:
                accepted += beats[k_idx][1]
                k_idx += 1
                last_progress = cyc
            elif k_vld:
                self.kout_stalled += 1
            if ent_vld and ent_rdy:
                # OUT_HEAD counts extents the writer started writing into, so it pops only for data.
                assert accepted > popcap * SECT, f"cycle {cyc}: output extent popped with no output pending"
                popcap += (job.entries[head] >> 64) & 0xFFFFFFFF
                head += 1
                ent_wait = rng.randint(0, 3)

            if wreq_vld and req_seen is None:
                req_seen = (int(dut.WREQ_QID.value), int(dut.WREQ_LBA.value), int(dut.WREQ_NLBA.value),
                            int(dut.WREQ_NBYTES.value))
                if aborted_at is not None and cyc > aborted_at:
                    raise AssertionError(f"cycle {cyc}: a new write request after ABORT at {aborted_at}")
            elif wreq_vld:
                now = (int(dut.WREQ_QID.value), int(dut.WREQ_LBA.value), int(dut.WREQ_NLBA.value),
                       int(dut.WREQ_NBYTES.value))
                assert now == req_seen, f"cycle {cyc}: write request changed while waiting: {req_seen} -> {now}"

            if wreq_rdy and wreq_vld:
                req = req_seen
                req_seen = None
                arb = "stream"
                frame_beats = 0
                frame_data = []
                first_taken = False
                stall_left = self.sof_stall(job.grant_mode)
                outstanding += 1
            elif wreq_rdy:
                raise AssertionError(f"cycle {cyc}: WREQ_VLD dropped while granted")

            if arb == "stream":
                if wdat_rdy and wdat_vld:
                    frame_data.append(signal_int(dut.WDAT_DATA))
                    frame_beats += 1
                    last_progress = cyc
                    first_taken = True
                elif first_taken and not wdat_vld:
                    raise AssertionError(f"cycle {cyc}: WDAT_VLD paused inside a granted frame")
                if frame_beats == (req[2] + 1) * 8:
                    data = b"".join(d.to_bytes(BEAT, "little") for d in frame_data)
                    got = Write(req[0], req[1], req[2], req[3], data)
                    received.append(got)
                    sb.check(got)
                    arb = "idle"
                    arb_wait = self.grant_delay(job.grant_mode)
                    cpl_due.append(cyc + rng.randint(5, 300))

            due = [c for c in cpl_due if c <= cyc]
            if due:
                cpl_due = [c for c in cpl_due if c > cyc]
                outstanding -= len(due)

            # -------- checks on registered status
            if need:
                self.need_space_cycles += 1
                prev = snaps.get(cyc - 1)
                if prev is not None:
                    p_head, p_tail, p_acc, p_cap = prev
                    assert p_head == p_tail, f"cycle {cyc}: NEED_SPACE while the ring held entries"
                    assert p_acc > p_cap * SECT, f"cycle {cyc}: NEED_SPACE with no output pending"
                assert job.release != "eager" or tail < len(job.entries), "NEED_SPACE with every extent given"
            if done:
                assert out_hist.get(cyc - 1, 1) == 0, f"cycle {cyc}: OUT_DONE while writes were outstanding"
                assert len(received) == len(writes), f"cycle {cyc}: OUT_DONE before every write was issued"
                assert aborted_at is None, "OUT_DONE after ABORT"
                done_seen = True
            if err:
                err_seen.append((cyc, int(dut.ERR_INFO.value)))

            # A stalled grant or SOF wait lasts at most 600 cycles here, so this long without a kernel
            # beat or a write beat is a deadlock, not slowness.
            if cyc - last_progress > 5000 and not (aborted_at is not None or malformed):
                raise AssertionError(f"cycle {cyc}: no progress for 5000 cycles: {len(received)}/{len(writes)} "
                                     f"writes, {accepted}/{len(job.out)} B accepted, head {head}, tail {tail}")

            # -------- end conditions
            if aborted_at is not None or malformed:
                halted = aborted_at is not None or err_seen
                if halted and not busy and arb == "idle" and not wreq_vld and outstanding == 0:
                    quiet += 1
                    if quiet > 64:
                        break
                else:
                    quiet = 0
            elif done_seen:
                break

            # -------- drive the next cycle
            await Timer(1, unit="ns")

            if job.abort_at is not None and aborted_at is None and accepted >= job.abort_at:
                dut.ABORT.value = 1
                aborted_at = cyc + 1
            else:
                dut.ABORT.value = 0

            if not (k_vld and not kout_rdy):
                if k_idx < len(beats) and rng.random() < job.kout_rate:
                    data, nbytes, last = beats[k_idx]
                    dut.KOUT_DATA.value = data
                    dut.KOUT_BYTES.value = nbytes
                    dut.KOUT_LAST.value = last
                    k_vld = 1
                else:
                    k_vld = 0
                dut.KOUT_VLD.value = k_vld

            if job.release != "eager":
                if need and ns_armed and release_at is None:
                    release_at = cyc + rng.randint(0, 150)
                    ns_armed = False
                if not need:
                    ns_armed = True
                if release_at is not None and cyc >= release_at:
                    tail = min(len(job.entries), tail + rng.randint(1, 3))
                    release_at = None
            if head < tail:
                if ent_wait > 0:
                    ent_wait -= 1
                    ent_vld = 0
                else:
                    ent_vld = 1
                    dut.ENT_DATA.value = job.entries[head]
            else:
                ent_vld = 0
                ent_wait = rng.randint(0, 8)
            dut.ENT_VLD.value = ent_vld
            dut.OUT_HEAD.value = head
            dut.OUT_TAIL.value = tail

            wreq_rdy = 0
            if arb == "idle" and wreq_vld:
                if arb_wait > 0:
                    arb_wait -= 1
                else:
                    wreq_rdy = 1
            dut.WREQ_RDY.value = wreq_rdy

            wdat_rdy = 0
            if arb == "stream":
                if stall_left > 0:
                    stall_left -= 1
                elif rng.random() < 0.03:
                    stall_left = rng.randint(1, 40)
                else:
                    wdat_rdy = int(rng.random() < 0.8)
            dut.WDAT_RDY.value = wdat_rdy

            dut.WR_OUTSTANDING.value = int(outstanding > 0)
            out_hist[cyc + 1] = int(outstanding > 0)
            out_hist.pop(cyc - 3, None)
        else:
            raise AssertionError(f"job did not finish in {max_cycles} cycles: {len(received)}/{len(writes)} writes, "
                                 f"{accepted}/{len(job.out)} B accepted, head {head}, tail {tail}")

        await Timer(1, unit="ns")
        dut.ABORT.value = 0
        dut.KOUT_VLD.value = 0
        dut.ENT_VLD.value = 0
        dut.WREQ_RDY.value = 0
        dut.WDAT_RDY.value = 0
        dut.WR_OUTSTANDING.value = 0

        if aborted_at is None and not malformed:
            sb.assert_empty()
            assert head == popped_exp, f"OUT_HEAD {head}, the plan pops {popped_exp} entries"
            assert accepted == len(job.out)
            assert int(dut.NEED_SPACE.value) == 0
        return dict(received=received, writes=writes, err=err_seen, head=head, popped=popped_exp,
                    aborted_at=aborted_at, accepted=accepted)


def random_job(rng, release=None, size=None, kout_rate=None, grant_mode=None, min_lc=0):
    lc = rng.randint(min(min_lc, MAX_LC), MAX_LC)
    ld = rng.randint(0, 2)
    if size is None:
        r = rng.random()
        if r < 0.15:
            size = rng.randint(0, 600)
        elif r < 0.6:
            size = rng.randint(600, 24000)
        else:
            size = rng.randint(24000, 3 * (BEAT << SL))
        if rng.random() < 0.3:
            size -= size % rng.choice([64, 512])
    out = rng.randbytes(size)
    entries = random_extents(rng, lbas_needed(size), lc)
    release = release or rng.choice(["eager", "late", "mixed"])
    initial = 0 if release == "late" else rng.randint(0, len(entries))
    return Job(out, entries, ld, lc, release=release, initial=initial,
               kout_rate=kout_rate if kout_rate is not None else rng.choice([1.0, 0.8, 0.4, 0.1]),
               grant_mode=grant_mode or rng.choice(["fast", "fast", "slow"]))


@cocotb.test()
async def run_random_jobs(dut):
    """Random sizes, stripes, release policies and rates; one job after another, CLEAR between."""
    tb = WriterBench(dut, 0x11)
    await tb.init()
    for _ in range(8):
        await tb.run_job(random_job(tb.rng))
    dut._log.info("NEED_SPACE asserted on %d cycles, kernel stalled on %d", tb.need_space_cycles, tb.kout_stalled)


@cocotb.test()
async def run_need_space(dut):
    """Output extents arrive only after NEED_SPACE, so every extent is served late."""
    tb = WriterBench(dut, 0x22)
    await tb.init()
    for _ in range(6):
        await tb.run_job(random_job(tb.rng, release="late"))
    assert tb.need_space_cycles > 0, "NEED_SPACE never asserted in a late-release test"


@cocotb.test()
async def run_corner_sizes(dut):
    """Output sizes at the beat, LBA, chunk and staging boundaries, including the empty output."""
    tb = WriterBench(dut, 0x33)
    await tb.init()
    rng = tb.rng
    lc = rng.randint(0, MAX_LC)
    chunk_b = SECT << lc
    sizes = [0, 1, 63, 64, 65, 511, 512, 513, chunk_b - 1, chunk_b, chunk_b + 1, (BEAT << SL) - 1,
             BEAT << SL, (BEAT << SL) + 64]
    for size in sizes:
        job = random_job(rng, size=size)
        await tb.run_job(job)


@cocotb.test()
async def run_backpressure(dut):
    """A fast kernel against slow grants and long SOF stalls: the staging buffer must fill."""
    tb = WriterBench(dut, 0x44)
    await tb.init()
    for _ in range(4):
        await tb.run_job(random_job(tb.rng, size=tb.rng.randint(2 * (BEAT << SL), 4 * (BEAT << SL)),
                                    kout_rate=1.0, grant_mode="slow", min_lc=2))
    assert tb.kout_stalled > 0, "the staging buffer never pushed back on the kernel"


@cocotb.test()
async def run_abort(dut):
    """ABORT mid-output: the granted frame completes, no new request follows, the kernel is drained."""
    tb = WriterBench(dut, 0x55)
    await tb.init()
    rng = tb.rng
    for _ in range(4):
        job = random_job(rng, size=rng.randint(4000, 3 * (BEAT << SL)), release="eager")
        job.abort_at = rng.randint(0, len(job.out) // 2)
        res = await tb.run_job(job)
        assert res["received"] == res["writes"][:len(res["received"])], "writes before ABORT differ from the plan"
        assert int(dut.KOUT_RDY.value) == 1, "the kernel is not drained after ABORT"
        assert int(dut.OUT_DONE.value) == 0


@cocotb.test()
async def run_malformed_entry(dut):
    """A malformed output extent raises ERR with ERR_INFO source FORMAT and stops the writer."""
    tb = WriterBench(dut, 0x66)
    await tb.init()
    rng = tb.rng
    for brk in output_breakers(rng):
        job = random_job(rng, size=rng.randint(2000, 2 * (BEAT << SL)), release="eager")
        bad = rng.randrange(len(job.entries))
        job.entries[bad] = brk(job.entries[bad])
        res = await tb.run_job(job)
        assert res["received"] == res["writes"], "writes before the malformed entry differ from the plan"
        if res["popped"] == bad + 1:
            assert len(res["err"]) == 1 and res["err"][0][1] == err_info(ERR_SRC_FORMAT, 0, 0, 0, bad + 1), \
                f"ERR {res['err']}"
        else:
            assert not res["err"], "ERR on an entry the writer never needed"
