# cocotb_test.py: USER_CORE elaborated with the GROUPBY architecture, driven as a real nfb device
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
import os
import random
from collections import defaultdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ReadOnly

from cocotbext.ofm.mi.drivers import MIRequestDriver
from cocotbext.ofm.mfb.properties import attach_mfb_properties

import nfb_compat
from dma_iuventus_model import SimplifiedDmaModel
from endpoint_view import EndpointView, attach_endpoint_mfb_properties

cocotbext_nfb = nfb_compat.load_cocotbext_nfb()

e = cocotb.external

NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "4"))

# The architecture's table geometry, fixed in user_core_groupby_arch.vhd rather than exposed as a
# generic: the engine's own bench is where the geometry is swept.
LANES = 4
SLOTS = 4096
GROUPS = LANES * SLOTS

SECT_BEATS = 8
RECS_BEAT = 4
RECS_SECT = SECT_BEATS * RECS_BEAT
MASK64 = (1 << 64) - 1

# Register file of the GROUPBY architecture, byte offsets into its device-tree node.
R_CTRL, R_IN_LBA_L, R_IN_LBA_H, R_IN_COUNT = 0x00, 0x04, 0x08, 0x0C
CTRL_START, CTRL_FILL, CTRL_ABORT = 1 << 0, 1 << 1, 1 << 2
R_OUT_LBA_L, R_OUT_LBA_H, R_OUT_QID, R_QID_MASK = 0x10, 0x14, 0x18, 0x1C
R_STATUS, R_REC_CNT_L, R_REC_CNT_H, R_OOR_CNT = 0x20, 0x24, 0x28, 0x2C
R_RESULT_SECT, R_NUM_GROUPS = 0x30, 0x34
R_LBA_NUM, R_ISSUED_CNT, R_COMPL_CNT = 0x38, 0x3C, 0x40
R_EVCR_INTERVAL, R_EVCR_TOTAL_EVENTS, R_EVCR_TOTAL_CYCLES = 0x60, 0x64, 0x68
# Per-queue block, base 0x80, stride 0x10, q = 0..NUM_QUEUES-1.
R_PQ_BASE, R_PQ_STRIDE = 0x80, 0x10
R_PQ_SECT_LEFT, R_PQ_ISSUED, R_PQ_OK, R_PQ_FAILED = 0x0, 0x4, 0x8, 0xC
# Below the per-queue block (0x80+) and past the last decode arm in user_core_groupby_arch.vhd
# (0x68), so reg_sel falls to "others" with pq_hit='0' and reads 0xCAFEBABE.
R_UNMAPPED = 0x6C

STATUS_BUSY, STATUS_DONE, STATUS_ERR = 1 << 0, 1 << 1, 1 << 2
# STATUS carries the engine's state in bits 7:4; the values are state_t'pos.
S_RUN, S_DONE, S_ERR = 4, 7, 8


class GroupByNfbDevice(cocotbext_nfb.NfbDevice):
    """USER_CORE (GROUPBY) as a standalone nfb device with one MI slave and no DMA; its DevTree
    has no netcope,dma_ctrl_ndp_* nodes, so the base class's QueueManager stays empty."""

    async def _init_clks(self):
        await cocotb.start(Clock(self._dut.USR_CLK, 5, 'ns').start())
        await cocotb.start(Clock(self._dut.DMA_CLK, 4, 'ns').start())
        await cocotb.start(Clock(self._dut.MI_CLK, 10, 'ns').start())

        self.dma_model = SimplifiedDmaModel(self._dut, self._dut.DMA_CLK)
        self.dma_model.data_integrity = True
        # Each queue sweeps its own drive, so the model must isolate storage per queue too;
        # otherwise every queue would read back the same (qid 0) sectors.
        self.dma_model.per_queue_storage = True
        # The engine strides LBA_PTR by one per sector, not by 512.
        self.dma_model.lba_sector_stride = 1

        self._dut.PCIE_LINK_UP.value = 1
        self._dut.FPGA_ID.value = 0
        self._dut.FPGA_ID_VLD.value = 0

        self.mi = [MIRequestDriver(self._dut, "MI", self._dut.MI_CLK)]
        # NVME_RD_MFB and PIPE_RD_MFB are per-endpoint arrays discovery cannot index: NVME_RD_MFB
        # gets one checker per endpoint, PIPE_RD_MFB is checked anyway after the merge at ENG_RD_MFB.
        self.mfb_props = attach_mfb_properties(self._dut, self._dut.DMA_CLK,
                                               reset=self._dut.DMA_RST,
                                               exclude=("NVME_RD_MFB", "PIPE_RD_MFB"))
        self.mfb_props.update(attach_endpoint_mfb_properties(self._dut, self._dut.DMA_CLK,
                                                             reset=self._dut.DMA_RST))

    async def _reset(self):
        self._dut.USR_RST.value = 1
        self._dut.DMA_RST.value = 1
        self._dut.MI_RST.value = 1
        await Timer(100, units='ns')
        self._dut.USR_RST.value = 0
        self._dut.DMA_RST.value = 0
        self._dut.MI_RST.value = 0
        await Timer(100, units='ns')


async def device(dut):
    """A fresh device per test: cocotb cancels a test's tasks, clocks included, when it ends, so
    a shared device would block the next test's first MI access forever."""
    dev = GroupByNfbDevice(dut)
    await dev.init()
    return dev


def pack_sector(records):
    """RECS_SECT {key, value} records into the 512 B a sector carries, record 0 first."""
    out = bytearray()
    for key, value in records:
        out += (key & MASK64).to_bytes(8, "little") + (value & MASK64).to_bytes(8, "little")
    assert len(out) == 512
    return bytes(out)


def model(records):
    sums = defaultdict(int)
    oor = 0
    for key, value in records:
        if key >= GROUPS:
            oor += 1
        else:
            sums[key] = (sums[key] + value) & MASK64
    return sums, oor


def seed_storage(dma, base_lba, records, qid=None):
    """Stage records where the model's read path will find them, one sector per LBA, on the given
    queue's own drive (per_queue_storage mode)."""
    assert len(records) % RECS_SECT == 0
    for s in range(len(records) // RECS_SECT):
        dma.seed_sector(base_lba + s, pack_sector(records[s * RECS_SECT:(s + 1) * RECS_SECT]), qid=qid)


class ResultCollector:
    """Reassembles the result frames the engine writes back."""

    def __init__(self):
        self.records = []
        self.frames = []

    def on_frame(self, trans):
        data = bytes(trans.data)
        assert len(data) == 512, f"result frame of {len(data)} B, expected 512"
        recs = [(int.from_bytes(data[i:i + 8], "little"),
                 int.from_bytes(data[i + 8:i + 16], "little"))
                for i in range(0, 512, 16)]
        self.frames.append(recs)
        self.records.extend(recs)


async def start_run(comp, in_lba, sectors, out_lba, out_qid=0, qid_mask=None, fill=False):
    await e(comp.write32)(R_IN_LBA_L, in_lba & 0xFFFFFFFF)
    await e(comp.write32)(R_IN_LBA_H, (in_lba >> 32) & 0xFFFFFFFF)
    await e(comp.write32)(R_IN_COUNT, sectors)
    await e(comp.write32)(R_OUT_LBA_L, out_lba & 0xFFFFFFFF)
    await e(comp.write32)(R_OUT_LBA_H, (out_lba >> 32) & 0xFFFFFFFF)
    await e(comp.write32)(R_OUT_QID, out_qid)
    if qid_mask is not None:
        await e(comp.write32)(R_QID_MASK, qid_mask)
    await e(comp.write32)(R_CTRL, CTRL_START | (CTRL_FILL if fill else 0))


async def wait_done(comp, dut, timeout_cycles=600000):
    """Poll STATUS over MI until the run settles, exactly as software would."""
    for _ in range(timeout_cycles // 200):
        status = await e(comp.read32)(R_STATUS)
        if status & (STATUS_DONE | STATUS_ERR):
            return status
        await Timer(200 * 4, units='ns')
    raise AssertionError(f"run never finished, last STATUS={status:#010x}")


@cocotb.test()
async def test_register_map(dut):
    """The device-tree node resolves and every register reads back what was written."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    sentinel = await e(comp.read32)(R_UNMAPPED)
    assert sentinel == 0xCAFEBABE, f"unmapped read gave {sentinel:#010x}"

    groups = await e(comp.read32)(R_NUM_GROUPS)
    assert groups == GROUPS, f"NUM_GROUPS reports {groups}, the bench assumes {GROUPS}"
    sectors = await e(comp.read32)(R_RESULT_SECT)
    assert sectors == GROUPS // RECS_SECT, f"RESULT_SECT reports {sectors}"

    for reg, value in ((R_IN_LBA_L, 0xDEADBEEF), (R_IN_LBA_H, 0x0000CAFE),
                       (R_IN_COUNT, 0x00001234), (R_OUT_LBA_L, 0x11223344),
                       (R_OUT_LBA_H, 0x00005678)):
        await e(comp.write32)(reg, value)
        got = await e(comp.read32)(reg)
        assert got == value, f"reg {reg:#04x} read back {got:#010x}, wrote {value:#010x}"

    # Narrow fields must truncate rather than store bits the engine never sees.
    await e(comp.write32)(R_OUT_QID, 0xFFFFFFFF)
    got = await e(comp.read32)(R_OUT_QID)
    assert got == NUM_QUEUES - 1, f"OUT_QID kept {got:#x}, expected it clipped to {NUM_QUEUES - 1:#x}"
    await e(comp.write32)(R_QID_MASK, 0xFFFFFFFF)
    got = await e(comp.read32)(R_QID_MASK)
    assert got == (1 << NUM_QUEUES) - 1, f"QID_MASK kept {got:#x}"

    status = await e(comp.read32)(R_STATUS)
    assert status & (STATUS_BUSY | STATUS_DONE | STATUS_ERR) == 0, \
        f"idle STATUS reports activity: {status:#010x}"


@cocotb.test()
async def test_aggregate_end_to_end(dut):
    """Aggregate every queue's distinct data through the DMA path and check the table sums to the
    combined total, so a queue reading another's range shows as a mismatch."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    sectors = 8
    per_queue = {}
    for q in range(NUM_QUEUES):
        rnd = random.Random(random.randrange(1 << 32))
        records = [(rnd.randrange(GROUPS), rnd.randrange(1 << 24))
                   for _ in range(sectors * RECS_SECT)]
        # A handful of keys past the table, so OOR_CNT is exercised rather than left at zero.
        for i in range(0, len(records), 37):
            records[i] = (GROUPS + i, 0xABC)
        per_queue[q] = records

    all_records = [rec for recs in per_queue.values() for rec in recs]
    sums, oor = model(all_records)
    assert oor > 0

    in_lba, out_lba = 0x0, 0x4000
    for q, records in per_queue.items():
        seed_storage(dev.dma_model, in_lba, records, qid=q)

    results = ResultCollector()
    dev.dma_model.wr_frame_accept_cb = results.on_frame

    seen_qids = set()
    dev.dma_model.rd_req_accept_cb = lambda lba, num, qid: seen_qids.add(qid)

    await start_run(comp, in_lba, sectors, out_lba)
    status = await wait_done(comp, dut)
    assert status & STATUS_ERR == 0, f"run failed, STATUS={status:#010x}"
    assert status & STATUS_DONE, f"run did not report DONE, STATUS={status:#010x}"

    rec_cnt = await e(comp.read32)(R_REC_CNT_L)
    assert rec_cnt == len(all_records), f"REC_CNT {rec_cnt}, expected {len(all_records)}"
    oor_cnt = await e(comp.read32)(R_OOR_CNT)
    assert oor_cnt == oor, f"OOR_CNT {oor_cnt}, expected {oor}"

    assert len(results.records) == GROUPS, \
        f"wrote back {len(results.records)} groups, expected {GROUPS}"
    bad = []
    for idx, (key, value) in enumerate(results.records):
        if key != idx:
            bad.append(f"slot {idx}: key {key}")
        elif value != sums.get(idx, 0):
            bad.append(f"key {idx}: sum {value}, expected {sums.get(idx, 0)}")
        if len(bad) >= 8:
            break
    assert not bad, "result mismatch: " + "; ".join(bad)

    assert seen_qids == set(range(NUM_QUEUES)), \
        f"issued to queues {sorted(seen_qids)}, expected every one of {sorted(range(NUM_QUEUES))}"
    dut._log.info(f"{len(sums)} distinct keys aggregated over queues {sorted(seen_qids)}")


@cocotb.test()
async def test_restart_clears_the_table(dut):
    """A second run must report only its own records. One queue only: per-queue independence is
    test_aggregate_end_to_end's job."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    results = ResultCollector()
    dev.dma_model.wr_frame_accept_cb = results.on_frame

    first = [(11, 7)] * RECS_SECT
    seed_storage(dev.dma_model, 0x0, first, qid=0)
    await start_run(comp, 0x0, 1, 0x4000, qid_mask=1)
    status = await wait_done(comp, dut)
    assert status & STATUS_DONE, f"first run STATUS={status:#010x}"
    assert results.records[11][1] == 7 * RECS_SECT

    results.records.clear()
    results.frames.clear()
    second = [(11, 1)] * RECS_SECT
    seed_storage(dev.dma_model, 0x800, second, qid=0)
    await start_run(comp, 0x800, 1, 0x4000, qid_mask=1)
    status = await wait_done(comp, dut)
    assert status & STATUS_DONE, f"second run STATUS={status:#010x}"
    assert len(results.records) == GROUPS
    assert results.records[11][1] == 1 * RECS_SECT, \
        f"key 11 totals {results.records[11][1]}, so the first run's sum survived the clear"


@cocotb.test()
async def test_self_test_fill(dut):
    """With no host to stage data, the engine fills one queue's drive and reads it back. Masked to
    that queue: the fill writes only CTL_OUT_QID's drive, so other queues would sweep an empty
    range."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    results = ResultCollector()
    dev.dma_model.wr_frame_accept_cb = results.on_frame

    sectors = 4
    await start_run(comp, 0x0, sectors, 0x4000, qid_mask=1, fill=True)
    status = await wait_done(comp, dut)
    assert status & STATUS_ERR == 0, f"fill run failed, STATUS={status:#010x}"

    rec_cnt = await e(comp.read32)(R_REC_CNT_L)
    assert rec_cnt == sectors * RECS_SECT, f"REC_CNT {rec_cnt}, expected {sectors * RECS_SECT}"
    oor_cnt = await e(comp.read32)(R_OOR_CNT)
    assert oor_cnt == 0, f"the fill pattern never leaves the table, yet OOR_CNT is {oor_cnt}"

    # key = index mod GROUPS, value = key + 1, so group g holds count(g)*(g+1).
    written = [(i % GROUPS, (i % GROUPS) + 1) for i in range(sectors * RECS_SECT)]
    sums, _ = model(written)
    fill_frames = sectors
    table = results.records[fill_frames * RECS_SECT:]
    assert len(table) == GROUPS, f"swept {len(table)} groups, expected {GROUPS}"
    bad = [f"key {i}: {v}, expected {sums.get(i, 0)}"
           for i, (k, v) in enumerate(table) if k != i or v != sums.get(i, 0)]
    assert not bad, "fill self-test mismatch: " + "; ".join(bad[:8])


@cocotb.test()
async def test_eps_periodic_windows(dut):
    """EVENT_COUNTER updates TOTAL_EVENTS/TOTAL_CYCLES only at interval end. A collision-free
    single-queue burst takes one beat per DMA_CLK cycle, so a saturated window must read
    RECS_BEAT * interval: records counted, not beats."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    interval = 200
    await e(comp.write32)(R_EVCR_INTERVAL, interval)

    # key % LANES cycles 0..3 within every beat, so no beat ever stalls on a lane collision.
    sectors = 250
    records = [(k, k + 1) for k in range(sectors * RECS_SECT)]
    seed_storage(dev.dma_model, 0x0, records, qid=0)
    await start_run(comp, 0x0, sectors, 0x4000, qid_mask=1)

    # Ground truth per window from the NVME_RD_MFB wires STS_REC_EVENT uses, independent of MI CDC
    # latency. S_CLEAR (SLOTS cycles) precedes the first read; windows before any beat are
    # discarded.
    windows = []
    records_since = beats_since = 0
    prev_reached = False
    seen_any_beat = False
    internal = dut.eps_cntr_i
    rd0 = EndpointView(dut, 0)
    cycles = 0
    while len(windows) < 5:
        await RisingEdge(dut.DMA_CLK)
        await ReadOnly()
        cycles += 1
        assert cycles < 2_000_000, f"never collected 5 active EVCR windows; got {len(windows)}"
        reached = bool(internal.int_reached.value)
        if reached and not prev_reached:
            # Boundary cycle: event_counter.vhd's eve_cnt_reg_pr resets on int_reached after
            # counting EVENT_VLD, so a same-cycle event is discarded; close the window on its
            # pre-boundary total.
            if seen_any_beat or windows:
                windows.append((records_since, beats_since))
            records_since = beats_since = 0
        elif int(rd0.NVME_RD_MFB_SRC_RDY.value) == 1 and int(rd0.NVME_RD_MFB_DST_RDY.value) == 1:
            records_since += RECS_BEAT
            beats_since += 1
            seen_any_beat = True
        prev_reached = reached

    for rec_tally, beat_tally in windows:
        assert rec_tally == RECS_BEAT * beat_tally, \
            f"window tally {rec_tally} records over {beat_tally} beats disagrees with itself"

    # Read immediately: interval (800 ns) comfortably outlasts the two MI transactions below, so
    # the register pair still holds the window this loop just closed.
    got_events = await e(comp.read32)(R_EVCR_TOTAL_EVENTS)
    got_cycles = await e(comp.read32)(R_EVCR_TOTAL_CYCLES)
    assert got_cycles == interval, f"EVCR_TOTAL_CYCLES {got_cycles}, expected the programmed {interval}"
    assert got_events == windows[-1][0], (
        f"EVCR_TOTAL_EVENTS {got_events} does not match the {windows[-1][0]} records this bench "
        "independently counted on NVME_RD_MFB for the same window"
    )

    peak_events, peak_beats = max(windows, key=lambda w: w[0])
    assert peak_beats > 0, "no window observed any accepted beat"
    assert peak_events == RECS_BEAT * interval, (
        f"best window ingested {peak_events} of a possible {RECS_BEAT * interval} records -- "
        "collision-free single-queue data should saturate the read bus, proving TOTAL_EVENTS "
        "counts records (RECS_BEAT per beat), not beats"
    )

    status = await wait_done(comp, dut)
    assert status & STATUS_DONE, f"run did not finish cleanly, STATUS={status:#010x}"


@cocotb.test()
async def test_rec_cnt_high_word_latches_on_read(dut):
    """Reading REC_CNT_L (0x24) must latch STS_REC_CNT's high half into the REC_CNT_H (0x28)
    shadow, which moves on no other cycle. 2**32 records is out of sim reach, so the latch trigger
    is checked against internal registers."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    assert int(dut.rec_cnt_hi_shadow.value) == 0, "REC_CNT_H shadow is not zero out of reset"

    sectors = 8
    records = [(k % GROUPS, 1) for k in range(sectors * RECS_SECT)]
    seed_storage(dev.dma_model, 0x0, records, qid=0)
    await start_run(comp, 0x0, sectors, 0x4000, qid_mask=1)

    # The shadow must never move except in a cycle where an MI read of reg_sel==9 (REC_CNT_L, word
    # offset 9 = byte 0x24) is in progress; watched every DMA_CLK cycle while records flow.
    stray_updates = 0

    async def watch_shadow():
        nonlocal stray_updates
        prev = int(dut.rec_cnt_hi_shadow.value)
        while True:
            await RisingEdge(dut.DMA_CLK)
            await ReadOnly()
            now = int(dut.rec_cnt_hi_shadow.value)
            is_the_latch_write = False
            if bool(dut.mi_rd_sync.value):
                addr_word = (int(dut.mi_addr_sync.value) >> 2) & 0x3F
                is_the_latch_write = addr_word == 9
            if now != prev and not is_the_latch_write:
                stray_updates += 1
            prev = now

    watcher = cocotb.start_soon(watch_shadow())

    # Poll REC_CNT_L (the latch under test) until it is non-zero: S_CLEAR (SLOTS cycles) precedes
    # any read. Each poll is a real 0x24 read, so watch_shadow() must already be running.
    got_l = 0
    for _ in range(5000):
        got_l = await e(comp.read32)(R_REC_CNT_L)
        if got_l > 0:
            break
        await Timer(200 * 4, units='ns')
    else:
        raise AssertionError("REC_CNT_L never advanced, so this run never exercised the latch")
    live_hi = int(dut.sts_rec_cnt.value) >> 32
    got_h = await e(comp.read32)(R_REC_CNT_H)
    assert got_h == live_hi, (
        f"REC_CNT_H {got_h} does not match the high half live around the 0x24 read that should "
        f"have latched it ({live_hi})"
    )

    status = await wait_done(comp, dut)
    assert status & STATUS_DONE, f"run did not finish, STATUS={status:#010x}"
    watcher.kill()
    assert stray_updates == 0, (
        f"REC_CNT_H shadow moved {stray_updates} time(s) with no 0x24 (REC_CNT_L) read in "
        "progress -- it must be a latch armed by that read, not a live value"
    )


@cocotb.test()
async def test_per_queue_register_block(dut):
    """The per-queue block at 0x80 (stride 0x10) must report each queue's own progress: zero
    sectors left, one command issued (the data fits in one), one OK, none failed."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    sectors = 8
    for q in range(NUM_QUEUES):
        records = [((k + 17 * q) % GROUPS, 1) for k in range(sectors * RECS_SECT)]
        seed_storage(dev.dma_model, 0x0, records, qid=q)

    await start_run(comp, 0x0, sectors, 0x4000)
    status = await wait_done(comp, dut)
    assert status & STATUS_DONE, f"run did not finish, STATUS={status:#010x}"

    for q in range(NUM_QUEUES):
        base = R_PQ_BASE + q * R_PQ_STRIDE
        sect_left = await e(comp.read32)(base + R_PQ_SECT_LEFT)
        issued = await e(comp.read32)(base + R_PQ_ISSUED)
        ok = await e(comp.read32)(base + R_PQ_OK)
        failed = await e(comp.read32)(base + R_PQ_FAILED)
        assert sect_left == 0, f"queue {q}: PQ_SECT_LEFT {sect_left}, expected 0 (run is done)"
        assert issued == 1, f"queue {q}: PQ_ISSUED {issued}, expected 1 (fits in one command)"
        assert ok == 1, f"queue {q}: PQ_OK {ok}, expected 1"
        assert failed == 0, f"queue {q}: PQ_FAILED {failed}, expected 0"


@cocotb.test()
async def test_abort_leaves_the_read_path_usable(dut):
    """Abort mid-run, then require a full correct run. Pipeline-buffered reads land after the
    abort: refusing their data jams the DMA, and dropping them keeps COMPL_CNT from ever reaching
    ISSUED_CNT, software's only quiesce signal."""
    dev = await device(dut)
    comp = dev.nfb.comp_open("ziti,iuventus_groupby")

    # Long enough that reads are still outstanding when the abort lands.
    long_sectors = 64
    rnd = random.Random(0x5EED)
    for q in range(NUM_QUEUES):
        recs = [(rnd.randrange(GROUPS), 1) for _ in range(long_sectors * RECS_SECT)]
        seed_storage(dev.dma_model, 0x0, recs, qid=q)

    await start_run(comp, 0x0, long_sectors, 0x8000)
    for _ in range(400):
        await Timer(200 * 4, units='ns')
        if await e(comp.read32)(R_REC_CNT_L) > 0:
            break
    else:
        raise AssertionError("run consumed no records, so there was nothing to abort")
    status = await e(comp.read32)(R_STATUS)
    assert status & STATUS_BUSY, "the run ended before the abort; raise long_sectors"

    await e(comp.write32)(R_CTRL, CTRL_ABORT)
    for _ in range(50):
        status = await e(comp.read32)(R_STATUS)
        if status & STATUS_ERR:
            break
        await Timer(200 * 4, units='ns')
    assert status & STATUS_ERR, f"abort did not take, STATUS={status:#010x}"
    assert (status >> 4) & 0xF == S_ERR, f"state {(status >> 4) & 0xF} after abort, expected S_ERR"

    # The recovery protocol: outstanding reads must reconcile before a restart.
    for _ in range(500):
        issued = await e(comp.read32)(R_ISSUED_CNT)
        compl = await e(comp.read32)(R_COMPL_CNT)
        if issued == compl:
            break
        await Timer(200 * 4, units='ns')
    assert issued == compl, \
        f"aborted run never quiesced: ISSUED_CNT={issued}, COMPL_CNT={compl}"
    dut._log.info(f"abort quiesced with {issued} reads reconciled")

    # A clean run on fresh data. Stale sectors from the aborted run would inflate both REC_CNT and
    # the sums, and a jammed read path would simply never finish.
    results = ResultCollector()
    dev.dma_model.wr_frame_accept_cb = results.on_frame
    second = {q: [(q * 3 + 5, 2)] * RECS_SECT for q in range(NUM_QUEUES)}
    for q, recs in second.items():
        seed_storage(dev.dma_model, 0x2000, recs, qid=q)
    sums, _ = model([r for recs in second.values() for r in recs])

    await start_run(comp, 0x2000, 1, 0x8000)
    status = await wait_done(comp, dut)
    assert status & STATUS_ERR == 0, f"run after abort failed, STATUS={status:#010x}"
    assert status & STATUS_DONE, f"run after abort did not finish, STATUS={status:#010x}"

    rec_cnt = await e(comp.read32)(R_REC_CNT_L)
    assert rec_cnt == NUM_QUEUES * RECS_SECT, \
        f"REC_CNT {rec_cnt} after abort, expected {NUM_QUEUES * RECS_SECT}"
    bad = [f"key {k}: {results.records[k][1]}, expected {v}"
           for k, v in sums.items() if results.records[k][1] != v]
    assert not bad, "sums after abort: " + "; ".join(bad)
