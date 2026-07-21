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

# LFSR_SIMPLE_RANDOM_GEN(DATA_WIDTH=21) taps, per lfsr_simple_random_gen.vhd's fce_get_taps table
# for DATA_WIDTH=21: XNOR_TAPS = (0, 0, 21, 19). Evaluated in the RTL's own loop order (i=3 downto
# 0, i.e. tap 19 first, then tap 21); taps are 1-based bit positions (bit index = tap - 1).
_LFSR21_TAPS = (19, 21)
_LFSR21_SEED = int("000011010110011100001", 2)
_LFSR21_MASK = (1 << 21) - 1


def lfsr21_step(reg: int) -> int:
    """One clock step of user_core_test_arch.vhd's lfsr_rand_addr_gen_i (Fibonacci LFSR, width 21)."""
    v = 1
    for tap in _LFSR21_TAPS:
        bit = (reg >> (tap - 1)) & 1
        v = 1 if v == bit else 0  # XNOR
    return ((reg << 1) | v) & _LFSR21_MASK


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
        straight from the configured registers, bypassing seq/rand addressing entirely.
      - burst (an active throughput test, tst_finished='0'): LBA_PTR is tst_addr (seq_addr_cntr or
        the LFSR), which only advances on completion (NVME_OP_STAT_VLD), not on request
        acceptance -- see on_completion().
    In both modes the QID round-robin (rd_qid_cntr/rd_burst_cntr) advances on every accepted
    request regardless of dispatch mode.
    """

    def __init__(self, num_queues: int = 1):
        self.num_queues = num_queues
        self.rr = RoundRobinQid(num_queues=num_queues)
        self.seq_addr = 0
        self.lfsr_reg = _LFSR21_SEED
        self.addressing = "seq"
        self.lba_num = 0
        self.contig = False
        self.test_active = False

    def configure_range(self, ch_min: int, ch_max: int, burst: int) -> None:
        self.rr.ch_min = ch_min
        self.rr.ch_max = ch_max
        self.rr.burst = max(burst, 1)

    def dut_reset(self) -> None:
        """Mirrors DMA_RST/data_logger_rst: reseeds the LFSR and the round-robin QID counter."""
        self.lfsr_reg = _LFSR21_SEED
        self.rr.qid = 0
        self.rr.burst_cnt = 0
        self.test_active = False

    def next_manual_request(self, lba_ptr: int, lba_num: int) -> ExpectedReadReq:
        qid = self.rr.next_qid()
        return ExpectedReadReq(lba_ptr=lba_ptr, lba_num=lba_num, qid=qid)

    def start_burst(self, lba_ptr: int, lba_num: int, addressing: str, contig: bool) -> None:
        """Mirrors tst_trigg's effect (a write to TST_ITERATIONS): seq_addr_cntr is (re)armed to
        the currently-configured LBA_PTR; the LFSR is NOT reseeded here (only DMA_RST does that)."""
        assert addressing in ("seq", "rand")
        self.seq_addr = lba_ptr
        self.lba_num = lba_num
        self.addressing = addressing
        self.contig = contig
        self.test_active = True

    def stop_burst(self) -> None:
        self.test_active = False

    def next_burst_request(self) -> ExpectedReadReq:
        addr = self.seq_addr if self.addressing == "seq" else self.lfsr_reg
        qid = self.rr.next_qid()
        return ExpectedReadReq(lba_ptr=addr, lba_num=self.lba_num, qid=qid)

    def on_completion(self) -> None:
        """Mirrors seq_addr_cntr / the LFSR advancing on NVME_OP_STAT_VLD, gated exactly like the
        RTL: (tst_finished = '0') or (contig_test = '1')."""
        if self.test_active or self.contig:
            if self.addressing == "seq":
                self.seq_addr += (self.lba_num + 1)
            else:
                self.lfsr_reg = lfsr21_step(self.lfsr_reg)


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
