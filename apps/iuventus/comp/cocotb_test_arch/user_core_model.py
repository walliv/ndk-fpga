# user_core_model.py: behavioral reference model of USER_CORE's TEST architecture read/write
# request generation (apps/iuventus/comp/user_core_test_arch.vhd), predicting the DUT's expected
# NVME_RD_REQ / NVME_WR_MFB output streams from scratch (not by re-running the RTL) so a scoreboard
# can compare DUT vs model.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from dataclasses import dataclass

# DMA_MFB_REGIONS(1) * DMA_MFB_REGION_SIZE(8) * DMA_MFB_BLOCK_SIZE(8) * DMA_MFB_ITEM_WIDTH(8) / 8
# -- USER_CORE's default MFB geometry (unchanged by this harness's Modules.tcl/Makefile).
REGION_BEAT_BYTES = 64
SECT_SIZE = 512

# user_core_test_arch.vhd's lfsr_r: LFSR_SIMPLE_RANDOM_GEN's DATA_WIDTH=64 step (XNOR taps
# 64,63,61,60, 1-based bit positions, order irrelevant), seeded with LFSR_SEED, MSB first.
_LFSR64_TAPS = (60, 61, 63, 64)
_LFSR64_SEED = int("0000110101100111000010000110101100001101011001110000100001101011", 2)
_LFSR64_MASK = (1 << 64) - 1


def lfsr64_step(reg: int) -> int:
    """One step of lfsr_step_f (Fibonacci LFSR, width 64)."""
    v = 1
    for tap in _LFSR64_TAPS:
        bit = (reg >> (tap - 1)) & 1
        v = 1 if v == bit else 0  # XNOR
    return ((reg << 1) | v) & _LFSR64_MASK


# LFSR steps between two draws (user_core_test_arch.vhd's LFSR_LEAP): consecutive draws share no
# state bit.
LFSR_LEAP = 64


def _leap_tables():
    """The affine map of one leap (LFSR_LEAPS(1)) as its constant and, per state byte, the XOR of
    that byte's bit columns for each of its 256 values."""
    def stepped(reg):
        for _ in range(LFSR_LEAP):
            reg = lfsr64_step(reg)
        return reg
    const = stepped(0)
    cols = [stepped(1 << i) ^ const for i in range(64)]
    tables = []
    for b in range(8):
        t = [0] * 256
        for v in range(1, 256):
            low = v & -v
            t[v] = t[v ^ low] ^ cols[8*b + low.bit_length() - 1]
        tables.append(t)
    return const, tables


_LEAP_CONST, _LEAP_TABLES = _leap_tables()


def lfsr64_leap(reg: int, draws: int = 1) -> int:
    """`draws` leaps of LFSR_LEAP steps, each through the leap's map as the RTL applies it."""
    t0, t1, t2, t3, t4, t5, t6, t7 = _LEAP_TABLES
    for _ in range(draws):
        reg = (_LEAP_CONST ^ t0[reg & 0xFF] ^ t1[reg >> 8 & 0xFF] ^ t2[reg >> 16 & 0xFF] ^ t3[reg >> 24 & 0xFF]
               ^ t4[reg >> 32 & 0xFF] ^ t5[reg >> 40 & 0xFF] ^ t6[reg >> 48 & 0xFF] ^ t7[reg >> 56])
    return reg


# As user_core_test_arch.vhd asserts of its leap map: it must agree with stepping the LFSR.
_reg = _LFSR64_SEED
for _ in range(LFSR_LEAP):
    _reg = lfsr64_step(_reg)
assert lfsr64_leap(_LFSR64_SEED) == _reg, "the LFSR leap map disagrees with stepping the LFSR"
del _reg


class RandDrawModel:
    """The RTL's random stream: slot 0 serves an accepted read, slot r+1 write region r, slot k
    being the state k leaps on; the state then moves past the highest slot taken, so no two accepts
    share a draw. `adv` is the leaps the last cycle moved it by."""

    def __init__(self, regions: int = 1, state: int = None):
        self.regions = regions
        self.state = _LFSR64_SEED if state is None else state
        self.adv = 0

    def reset(self) -> None:
        self.state = _LFSR64_SEED

    def slot(self, k: int) -> int:
        return rand_lba(lfsr64_leap(self.state, k))

    def cycle(self, read: bool, writes=(), active: bool = True):
        """Draws this cycle's accepts take -- the read's, then one per write region -- and the step
        after them. Addresses of requests not accepted are None."""
        rd = self.slot(0) if read else None
        wr = [self.slot(r + 1) if w else None for r, w in enumerate(writes)]
        adv = 1 if read else 0
        for r, w in enumerate(writes):
            if w:
                adv = r + 2
        self.adv = adv if active else 0
        if self.adv:
            self.state = lfsr64_leap(self.state, self.adv)
        return rd, wr


def rand_lba(reg: int) -> int:
    """rand_draw: a slot state's low ADDR_CNTR_WIDTH bits in whole drive units, folded once by
    RAND_LBA_SPAN so no request runs past the namespace."""
    units = (reg & ((1 << ADDR_CNTR_WIDTH) - 1)) // LBA_ALIGN
    span_units = RAND_LBA_SPAN // LBA_ALIGN
    if units >= span_units:
        units -= span_units
    return units * LBA_ALIGN


def gen_wr_mfb_data(pkt_cnt: int, word_cnt: int, sof: bool, eof: bool) -> bytes:
    """Reproduces user_core_test_arch.vhd's gen_wr_mfb_data function exactly: one region-beat
    (REGION_BEAT_BYTES bytes) of deterministic data, tagged with the packet/word counters and
    SOF/EOF flags that were live when that beat was accepted."""
    flag_byte = (pkt_cnt >> 8) & 0xFF
    if sof:
        flag_byte |= 0x80
    if eof:
        flag_byte |= 0x40

    out = bytearray(REGION_BEAT_BYTES)
    for byte_idx in range(REGION_BEAT_BYTES):
        tile_idx = byte_idx // 8
        pos = byte_idx % 8
        if pos == 0:
            out[byte_idx] = 0x4E  # 'N'
        elif pos == 1:
            out[byte_idx] = 0x56  # 'V'
        elif pos == 2:
            out[byte_idx] = 0x4D  # 'M'
        elif pos == 3:
            out[byte_idx] = 0x45  # 'E'
        elif pos == 4:
            out[byte_idx] = ((word_cnt & 0xFF) + tile_idx) & 0xFF
        elif pos == 5:
            out[byte_idx] = (((word_cnt >> 8) & 0xFF) + tile_idx) & 0xFF
        elif pos == 6:
            out[byte_idx] = ((pkt_cnt & 0xFF) + tile_idx) & 0xFF
        else:
            out[byte_idx] = (flag_byte + tile_idx) & 0xFF
    return bytes(out)


class RoundRobinQid:
    """Shared round-robin QID predictor for both the read-request path (rd_qid_cntr/rd_burst_cntr,
    user_core_test_arch.vhd's rd_qid_rr_p) and the write-side channel round-robin (MFB_GENERATOR_MI32's
    chan_cnt/burst_cnt, comp/mfb_tools/debug/generator/mfb_generator.vhd's chan_cnt_g), which share the
    same "advance every `burst` accepted items, wrap ch_max -> ch_min" shape. Both RTL counters reset
    to 0 on their own domain's reset regardless of ch_min -- reproduced here as the `qid` constructor
    default rather than defaulting to ch_min.
    """

    def __init__(self, ch_min: int = 0, ch_max: int = 0, burst: int = 1, num_queues: int = 1):
        self.ch_min = ch_min
        self.ch_max = ch_max
        self.burst = max(burst, 1)
        self.num_queues = num_queues
        self.qid = 0
        self.burst_cnt = 0

    def next_qid(self) -> int:
        """Return the QID for the NEXT accepted item, then advance state as the RTL would upon
        that item's acceptance. NUM_QUEUES=1 always forces QID 0 (matches gen_rd_req_qid /
        gen_nvme_wr_qid_mskd's explicit force-to-zero, independent of the round-robin state)."""
        if self.num_queues == 1:
            return 0

        current = self.qid
        if self.burst_cnt + 1 >= self.burst:
            self.burst_cnt = 0
            if self.qid >= self.ch_max:
                self.qid = self.ch_min
            else:
                self.qid += 1
        else:
            self.burst_cnt += 1
        return current


@dataclass
class ExpectedReadReq:
    lba_ptr: int
    lba_num: int
    qid: int


@dataclass
class ExpectedWrFrame:
    data: bytes
    lba_ptr: int
    qid: int


class ReadReqModel:
    """Predicts USER_CORE's NVME_RD_REQ stream.

    Two distinct dispatch modes exist in the RTL and are modeled separately:
      - manual (one-shot register write to 0x00, IuventusTest.disp_rd_req): LBA_PTR/LBA_NUM come
        straight from the configured registers, bypassing seq/rand addressing entirely, and no
        counter moves (seq_addr_cntr_p's gate is closed while tst_finished='1', contig_test='0').
      - burst (tst_finished='0', or contig_test='1'): LBA_PTR is tst_addr -- the requested queue's
        own seq_addr_cntr entry, or the shared LFSR.
    In both modes the QID round-robin (rd_qid_cntr/rd_burst_cntr) advances on every accepted
    request regardless of dispatch mode.

    Only the read stream is modeled here. A write frame accepted while the same gate is open also
    advances the queue it names (user_core_test_arch.vhd's seq_addr_cntr_p, :1342), so a scenario
    running the write generator during a burst would have to feed that in too; none does, because
    every case starts from a DMA_RST that clears MFB_GENERATOR_MI32's own enable.
    """

    def __init__(self, num_queues: int = 1):
        self.num_queues = num_queues
        self.rr = RoundRobinQid(num_queues=num_queues)
        # One counter per queue, mirroring user_core_test_arch.vhd's seq_addr_cntr array (:278).
        # An accepted request only moves the counter of the queue it names, so a round-robin
        # stream steps each queue once per full rotation rather than once per request.
        self.seq_addr = [0] * num_queues
        self.rand = RandDrawModel()
        self.addressing = "seq"
        self.lba_num = 0
        self.contig = False
        self.test_active = False

    def configure_range(self, ch_min: int, ch_max: int, burst: int) -> None:
        self.rr.ch_min = ch_min
        self.rr.ch_max = ch_max
        self.rr.burst = max(burst, 1)

    def _seq_idx(self, qid: int) -> int:
        """Mirrors user_core_test_arch.vhd's seq_idx_f (:222): QID_W is a rounded-up log2, so at
        NUM_QUEUES 1 or 3 a QID value can name a queue that does not exist; the RTL folds those
        onto queue 0 rather than indexing the array out of range."""
        return qid if qid < self.num_queues else 0

    def dut_reset(self) -> None:
        """DMA_RST: reseeds the LFSR and round-robin QID and re-arms every seq_addr_cntr from
        nvme_rd_req_lba_ptr_reg, which the same reset clears to 0."""
        self.rand = RandDrawModel()
        self.rr.qid = 0
        self.rr.burst_cnt = 0
        self.seq_addr = [0] * self.num_queues
        self.test_active = False

    def next_manual_request(self, lba_ptr: int, lba_num: int) -> ExpectedReadReq:
        qid = self.rr.next_qid()
        return ExpectedReadReq(lba_ptr=lba_ptr, lba_num=lba_num, qid=qid)

    def start_burst(self, lba_ptr: int, lba_num: int, addressing: str, contig: bool) -> None:
        """Mirrors tst_trigg's effect (a write to TST_ITERATIONS): EVERY queue's seq_addr_cntr
        entry is (re)armed to the currently-configured LBA_PTR -- the RTL assigns the whole array
        with `(others => resize(unsigned(nvme_rd_req_lba_ptr_reg), ADDR_CNTR_WIDTH))` (:1318), so
        all queues start the burst on the same address and diverge only as each is used. The LFSR
        is NOT reseeded here (only DMA_RST does that)."""
        assert addressing in ("seq", "rand")
        self.seq_addr = [lba_ptr] * self.num_queues
        self.lba_num = lba_num
        self.addressing = addressing
        self.contig = contig
        self.test_active = True

    def stop_burst(self) -> None:
        self.test_active = False

    def next_burst_request(self) -> ExpectedReadReq:
        """Predicts ONE accepted burst request and applies that accept's own side effect.

        LBA_PTR is the requested queue's own address: tst_addr indexes tst_addr_q by the QID the
        request carries (user_core_test_arch.vhd:1359), so each queue reads its own counter, while
        the random stream stays shared across queues (:1355).

        seq_addr_cntr advances HERE, on acceptance (`rd_req_accepted_s`, :1330), and only for the
        queue named by the request. Waiting for the completion instead would leave the next
        address undefined for a whole round trip, capping a sequential stream at one useful
        command in flight per queue. NVME_RD_REQ_LBA_NUM is a 0-based LBA count (0 => 1 LBA), so
        the step of lba_num+1 keeps each queue's stream contiguous and disjoint. Gated exactly
        like the RTL: (tst_finished = '0') or (contig_test = '1'). The counter runs in rand
        addressing too -- tst_sel_reg(0) only selects which address is read out."""
        qid = self.rr.next_qid()
        idx = self._seq_idx(qid)
        active = self.test_active or self.contig
        draw, _ = self.rand.cycle(read=True, active=active)
        addr = self.seq_addr[idx] if self.addressing == "seq" else draw
        if active:
            self.seq_addr[idx] += (self.lba_num + 1)
        return ExpectedReadReq(lba_ptr=addr, lba_num=self.lba_num, qid=qid)

    def on_completion(self) -> None:
        """No-op: the random stream steps on the accept, in next_burst_request(); kept for
        callers that drive the model per completion."""


class WriteFrameModel:
    """Predicts USER_CORE's NVME_WR_MFB frame stream (MFB_GENERATOR_MI32's framing/channel +
    user_core_test_arch.vhd's own gen_wr_mfb_data payload function -- see that function's header
    comment for why the generator's own TX_MFB_DATA is irrelevant here (tied to `open`))."""

    def __init__(self, num_queues: int = 1):
        self.num_queues = num_queues
        self.rr = RoundRobinQid(num_queues=num_queues)
        self.pkt_cnt = 0
        self.word_cnt = 0

    def configure_range(self, ch_min: int, ch_max: int, burst_size: int) -> None:
        self.rr.ch_min = ch_min
        self.rr.ch_max = ch_max
        self.rr.burst = max(burst_size, 1)

    def dut_reset(self) -> None:
        self.rr.qid = 0
        self.rr.burst_cnt = 0
        self.pkt_cnt = 0
        self.word_cnt = 0

    def next_frame(self, lba_ptr: int, total_bytes: int) -> ExpectedWrFrame:
        """`lba_ptr` is supplied by the caller, not predicted: every scenario here dispatches
        writes with the test idle (tst_finished='1', contig_test='0'), where gen_wr_meta_lba is
        the nvme_wr_req_lba_ptr_reg the caller just programmed (user_core_test_arch.vhd:863). A
        write issued during a burst instead takes tst_addr_q of the queue its own region names,
        which would have to be predicted from ReadReqModel's per-queue counters."""
        qid = self.rr.next_qid()
        num_beats = (total_bytes + REGION_BEAT_BYTES - 1) // REGION_BEAT_BYTES

        data = bytearray()
        for beat_idx in range(num_beats):
            sof = beat_idx == 0
            eof = beat_idx == num_beats - 1
            data.extend(gen_wr_mfb_data(self.pkt_cnt, self.word_cnt, sof, eof))
            if eof:
                self.word_cnt = 0
            else:
                self.word_cnt += 1

        self.pkt_cnt = (self.pkt_cnt + 1) & 0xFFFF
        return ExpectedWrFrame(data=bytes(data[:total_bytes]), lba_ptr=lba_ptr, qid=qid)


class EvcrModel:
    """Predicts the EVENT_COUNTER's total-event count: one event per accepted read request plus
    one per accepted write frame's SOF beat (see evcr_event_vld's assignment)."""

    def __init__(self):
        self.total_events = 0

    def on_read_accept(self) -> None:
        self.total_events += 1

    def on_write_frame_accept(self) -> None:
        self.total_events += 1


# Namespace size and address-counter width, as user_core_test_arch.vhd declares them
# (TST_LBA_COUNT, ADDR_CNTR_WIDTH).
TST_LBA_COUNT = 488377323 << 4
ADDR_CNTR_WIDTH = 33
# LBAs per 4 KiB drive unit (512 B sectors). A request straddling two units is split and serialised
# by the SSD, so every generated test address starts on one.
LBA_ALIGN = 4096 // SECT_SIZE
# Largest request: NVME_RD_REQ_LBA_NUM is 8 bits, 0-based. Random starts must leave room for it.
MAX_REQ_LBAS = 256
# Where the random stream folds (user_core_test_arch.vhd's RAND_LBA_SPAN).
RAND_LBA_SPAN = TST_LBA_COUNT - MAX_REQ_LBAS


def seq_fold(lba: int) -> int:
    """The counter's fold at the namespace end. An advance wrapping ADDR_CNTR_WIDTH is taken as
    wrapped, exactly as the RTL's candidate select does."""
    if lba >= 1 << ADDR_CNTR_WIDTH:
        return lba - (1 << ADDR_CNTR_WIDTH)
    if lba >= TST_LBA_COUNT:
        return lba - TST_LBA_COUNT
    return lba


def lba_align_up(lba: int) -> int:
    """Next drive-unit boundary at or above lba, folded like any other advance."""
    return seq_fold(-(-lba // LBA_ALIGN) * LBA_ALIGN)


class SeqAddrModel:
    """Specification of seq_addr_cntr: an accept takes a queue's value and advances it by its LBAs, a
    load sets every queue, and a point start rounds each up to a drive unit in its first idle cycle."""

    def __init__(self, num_queues: int):
        self.cntr = [0] * num_queues
        self.pend = [False] * num_queues
        # Cycles a point start waited behind an accept, and point starts that moved a counter.
        self.deferred = 0
        self.rounded = 0

    def load(self, lba: int) -> None:
        self.cntr = [lba] * len(self.cntr)
        self.pend = [False] * len(self.cntr)

    def point_start(self) -> None:
        self.pend = [True] * len(self.cntr)

    def step(self, advance: dict) -> None:
        """One cycle in which the counters run: `advance` maps a queue to the LBAs accepted on it."""
        for q in range(len(self.cntr)):
            if advance.get(q, 0):
                self.cntr[q] = seq_fold(self.cntr[q] + advance[q])
                if self.pend[q]:
                    self.deferred += 1
            elif self.pend[q]:
                if self.cntr[q] % LBA_ALIGN:
                    self.rounded += 1
                self.cntr[q] = lba_align_up(self.cntr[q])
                self.pend[q] = False
