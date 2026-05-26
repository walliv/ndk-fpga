# cocotb_test.py: NVME CC Packet dispatcher testbench
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import random
import cocotb
import logging

from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotb_bus.drivers import BitDriver
from cocotb_bus.monitors import BusMonitor
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta, MfbTransaction

from cocotbext.ofm.pcie import CCHeader, CQHeader, CQMfbMeta

from cocotbext.ofm.utils.throughput_probe import ThroughputProbe, ThroughputProbeMfbInterface
from cocotbext.ofm.utils import SerializableHeader
from cocotbext.ofm.ver.generators import random_integers, random_packets

# TODO:
#   3. Process the CQ Entries by the model

class CQEntry(SerializableHeader):
    items = list(zip(
        ['cmd_specific',
         'rsv1',
         'sq_hdbl', 'sq_id',
         'cmd_id', 'phase_tag', 'stat_code', 'stat_code_type', 'rsv2', 'more', 'do_not_retry'],
        [32, 32, 16, 16, 16, 1, 8, 3, 2, 1, 1],
    ))

class DblUpdMonitor(BusMonitor):
    _signals = ["sqhdbl", "cqhdbl", "last_cq_entry", "vld"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.upd_processed = 0
        self.cqhdbl = 0

    async def _monitor_recv(self):
        re = RisingEdge(self.clock)

        while True:
            await re
            if self.bus.vld.value == 1:
                cq_entry_deser = CQEntry.deserialize(int(self.bus.last_cq_entry.value))
                self._recv((int(self.bus.sqhdbl.value), int(self.bus.cqhdbl.value), str(cq_entry_deser)))
                self.upd_processed += 1
                self.cqhdbl = int(self.bus.cqhdbl.value)

class Testbench:

    def __init__(self, dut, cq_byte_size=2**17, debug=False):

        self.m_dut = dut
        self.m_cq_mfb_driver = MFBDriver(dut, "PCIE_CQ_MFB", dut.CLK)
        self.m_cc_mfb_monitor = MFBMonitor(dut, "PCIE_CC_MFB", dut.CLK, trans_type = MfbTransactionWithMeta)
        self.m_stat_upd_mon = DblUpdMonitor(dut, "STAT_UPD", dut.CLK)
        self.m_backpressure = BitDriver(dut.PCIE_CC_MFB_DST_RDY, dut.CLK)

        # self.m_throughput_probe = ThroughputProbe(ThroughputProbeMfbInterface(self.m_cc_mfb_monitor), throughput_units="bytes")
        # self.m_throughput_probe.add_log_interval(0, None)
        # self.m_throughput_probe.set_log_period(10)

        self.m_cc_exp_out = []
        self.m_stat_upd_exp_out = []

        self.m_scoreboard = Scoreboard(dut)
        self.m_scoreboard.add_interface(self.m_cc_mfb_monitor, self.m_cc_exp_out, strict_type=True)
        self.m_scoreboard.add_interface(self.m_stat_upd_mon, self.m_stat_upd_exp_out, strict_type=True)

        # ======================================================
        # Internal signals driver by the model
        # ======================================================

        self.cq_hdbl_int = 0
        self.cq_entry_len = len(CQEntry()) // 8
        self.cq_byte_size = cq_byte_size
        self.cq_size = cq_byte_size // self.cq_entry_len
        self.compl_queue = bytearray(cq_byte_size)
        self.data_buff = bytearray(cq_byte_size)
        self._log = logging.getLogger("cocotb")

        self.m_model_received_rd = 0
        self.m_model_received_bytes_rd = 0
        self.m_model_received_wr = 0
        self.m_model_received_bytes_wr = 0
        self.m_model_cqes_processed = 0

        self.m_dut_received_rd = 0
        self.m_dut_received_bytes_rd = 0
        self.m_dut_received_wr = 0
        self.m_dut_received_bytes_wr = 0
        self.m_dut_processed_rd = 0
        self.m_dut_processed_bytes_rd = 0

        self.m_cq_mfb_driver.log.setLevel(logging.WARNING)
        self.m_cc_mfb_monitor.log.setLevel(logging.WARNING)
        self.m_stat_upd_mon.log.setLevel(logging.WARNING)
        self.m_scoreboard.log.setLevel(logging.INFO)

    def _write_buffer_model(self, buff, buff_size, addr, data):
        end_pos = addr + len(data)

        if (end_pos <= buff_size):
            buff[addr:end_pos] = data
        else:
            buff[addr:buff_size] = data[:buff_size - addr]
            buff[0:end_pos % buff_size] = data[buff_size - addr:]

    def _read_buffer_model(self, buff, buff_size, addr, byte_count):
        # ---------------------------------------------------
        # Read data from the specific buffer
        # ---------------------------------------------------
        # 1. Read amount of data based on the address since the reads have to be DWord aligned
        # 2. Round the read slice's length to whole DWords
        total_read_length = (( addr % 4 + byte_count + 3) // 4) * 4
        # Start reading address has to be Dword aligned
        start_pos = addr - addr % 4
        end_pos = start_pos + total_read_length
        read_data = []

        if (end_pos <= buff_size):
            read_data = buff[start_pos:end_pos]
        else:
            read_data = buff[start_pos:buff_size] + buff[0:end_pos % buff_size]

        assert len(read_data) == total_read_length

        self._log.debug(f"Reading slice on 0x{addr:x} (0x{start_pos:x}-0x{end_pos:x}) of size {byte_count} bytes (Total {total_read_length} bytes, {len(read_data)=})")

        # ---------------------------------------------------
        # Segment the data by 128-byte segments
        # ---------------------------------------------------
        segment_size = 128
        rem_bytes = byte_count
        read_data_segmented = []
        firstword = True

        for offset in range(0, total_read_length, segment_size):
            segment = read_data[offset:offset + segment_size]
            # Only the first completion within split completion set has the address
            # set. The rest is 0
            cc_offs = addr if firstword else 0
            segment_tuple = (cc_offs, rem_bytes, segment)
            read_data_segmented.append(segment_tuple)

            # The first Completion can contain a smaller amount of valid data than segment_size
            # which is based on the padding caused by the unaligned access.
            if (firstword):
                rem_bytes = rem_bytes - (segment_size - addr % 4)
                firstword = False
            else:
                # For the rest of the completions, all of the bytes within segment_size are valid.
                rem_bytes = rem_bytes - segment_size

        return read_data_segmented

    def _rw_model(self, write, addr, data, byte_count=0, cq_hdr=None, bar=0):

        # Process write or read if there is any
        if write:
            if bar == 2:
                self._write_buffer_model(self.compl_queue, self.cq_byte_size, addr, data)
            elif bar == 4:
                self._write_buffer_model(self.data_buff, self.cq_byte_size, addr, data)

            self.m_model_received_wr += 1
            self.m_model_received_bytes_wr += len(data)

        else:
            read_data = None

            if bar == 2:
                read_data = self._read_buffer_model(self.compl_queue, self.cq_byte_size, addr, byte_count)
            elif bar == 4:
                read_data = self._read_buffer_model(self.data_buff, self.cq_byte_size, addr, byte_count)

            for offs, rem_bytes, data_int in read_data:
                cc_header = CCHeader()

                cc_header.lower_address = offs & 0x7F
                cc_header.at = cq_hdr.at
                cc_header.byte_count = rem_bytes
                # No need for rounding since the output segment size is always rounded to whole
                # DWords
                cc_header.dword_count = len(data_int) // 4
                cc_header.rid = cq_hdr.req_id
                cc_header.tag = cq_hdr.tag
                cc_header.tc = cq_hdr.tc
                cc_header.attr = cq_hdr.attr
                cc_header.cid = 0x0001
                cc_header.ecrc = 1

                self._log.debug(f"Model response to read with CC hdr:\n{str(cc_header)}")

                mfb_tr = MfbTransactionWithMeta(
                    data=cc_header.serialize().to_bytes(len(CCHeader()) // 8, 'little') + data_int,
                    meta=0
                )
                self.m_cc_exp_out.append(mfb_tr)

            self.m_model_received_rd += 1
            self.m_model_received_bytes_rd += byte_count

    async def cqe_process_model(self):
        re = RisingEdge(self.m_dut.CLK)
        current_phase_tag = 1
        self._log.debug(f"Model for CQ Entries processing has started...")

        while True:
            await re

            cq_entry = int.from_bytes(self.compl_queue[self.cq_hdbl_int*self.cq_entry_len:self.cq_hdbl_int*self.cq_entry_len + self.cq_entry_len], 'little')
            cq_entry_deser = CQEntry.deserialize(cq_entry)

            if (cq_entry_deser.phase_tag == current_phase_tag):
                self._log.debug(f"Captured a CQ Entry:\n{str(cq_entry_deser)}")
                self.cq_hdbl_int = (self.cq_hdbl_int + 1) % self.cq_size
                self.m_stat_upd_exp_out.append((cq_entry_deser.sq_hdbl % self.cq_size, self.cq_hdbl_int, str(cq_entry_deser)))
                self.m_model_cqes_processed += 1

                if (self.cq_hdbl_int == 0):
                    current_phase_tag = (~current_phase_tag) & 0x1
                    self._log.debug(f"Inverting phase tag, new value {current_phase_tag}")

    async def create_write_req(self, addr, data, bar=4, func=0):
        assert len(data) > 0

        self._rw_model(True, addr, data, bar=bar)

        max_segments = len(data)
        self._log.info(f"Received write of {max_segments} bytes to address 0x{addr:x}, bar {bar}")

        # if max_segments == 1:
        segments_with_offsets = [(0, data)]
        # else:
        #     alpha = 0.5
        #     beta = 5.0

        #     no_seg_float = random.betavariate(alpha, beta) * max_segments
        #     num_segments = round(no_seg_float)

        #     split_indices = sorted(random.sample(range(1, len(data)), num_segments - 1))
        #     split_indices = [0] + split_indices + [len(data)]
        #     # Generate (offset, segment) tuples
        #     segments_with_offsets = [(split_indices[i], data[split_indices[i]:split_indices[i+1]]) for i in range(len(split_indices) - 1)]
        #     cocotb.log.info(f"{num_segments=}, {len(data)=}")

        #     random.shuffle(segments_with_offsets)

        for offs, data in segments_with_offsets:
            cq_header = CQHeader()
            mfb_meta = CQMfbMeta()
            byte_count = len(data)

            offs = addr + offs

            mfb_meta.firstBe = [0xF, 0xE, 0xC, 0x8][offs % 4]
            mfb_meta.lastBe = [0xF, 0x1, 0x3, 0x7][(offs + byte_count) % 4]

            dwords = (offs % 4 + byte_count + 3) // 4
            if dwords <= 1:
                mfb_meta.firstBe &= mfb_meta.lastBe
                mfb_meta.lastBe = 0

            cq_header.bar_apper = 26
            cq_header.tgt_func = func
            cq_header.bar_id = bar
            cq_header.addr = offs >> 2
            cq_header.dword_count = dwords & 2047
            cq_header.req_type = 0x1

            mfb_tr = MfbTransactionWithMeta(
                # The writes require additional padding if they are unaligned to DWords
                data=cq_header.serialize().to_bytes(len(CQHeader()) // 8, 'little') + (b'\x00' * (offs % 4)) + data,
                meta = mfb_meta.serialize()
            )

            self._log.debug(f"Create MWr transaction:\nPadding: {offs % 4}\nCQ header:\n{str(cq_header)}\nMFB Meta:\n{str(mfb_meta)}\n{str(mfb_tr)}")

            self.m_cq_mfb_driver.append(mfb_tr)

        return len(segments_with_offsets)

    async def create_read_req(self, addr, byte_count, bar=2, func=0):
        cq_header = CQHeader()
        mfb_meta = CQMfbMeta()

        mfb_meta.firstBe = [0xF, 0xE, 0xC, 0x8][addr % 4]
        mfb_meta.lastBe = [0xF, 0x1, 0x3, 0x7][(addr + byte_count) % 4]

        dwords = (addr % 4 + byte_count + 3) // 4
        if dwords <= 1:
            mfb_meta.firstBe &= mfb_meta.lastBe
            mfb_meta.lastBe = 0

        self._log.info(f"Received read of {byte_count=} ({dwords=}, {(dwords + 31) // 32} transactions), from address 0x{addr:x}, {bar=}, {func=}")

        cq_header.tag = random.randint(0,256)
        cq_header.bar_apper = 26
        cq_header.tgt_func = func
        cq_header.bar_id = bar
        cq_header.addr = addr >> 2
        cq_header.dword_count = dwords & 2047
        cq_header.req_type = 0x0

        self._log.debug(f"Create MRd: \n {str(cq_header)}")

        self._rw_model(False, addr, [], byte_count, cq_header, bar=bar)
        byte_hdr = cq_header.serialize().to_bytes(len(CQHeader()) // 8, 'little')
        mfb_tr = MfbTransactionWithMeta(
            data=cq_header.serialize().to_bytes(len(CQHeader()) // 8, 'little'),
            meta = mfb_meta.serialize()
        )
        self.m_cq_mfb_driver.append(mfb_tr)

    async def reset_general(self):
        self.cq_hdbl_int = 0
        # self.compl_queue[:] = b'\x00' * len(self.compl_queue)
        # self.data_buff[:] = b'\x00' * len(self.data_buff)

        self.m_dut.DBL_MASK.value = self.cq_size -1

        self.m_model_received_rd = 0
        self.m_model_received_bytes_rd = 0
        self.m_model_received_wr = 0
        self.m_model_received_bytes_wr = 0

        self.m_dut.RESET.value = 1
        await ClockCycles(self.m_dut.CLK, 10)
        self.m_dut.RESET.value = 0
        await RisingEdge(self.m_dut.CLK)

    async def counter_sample(self):
        while True:
            await RisingEdge(self.m_dut.CLK)

            assert int(self.m_dut.RD_RECEIVED_INCR.value) == 0 or int(self.m_dut.RD_RECEIVED_INCR.value) == 1  or int(self.m_dut.RD_RECEIVED_INCR.value) == 2
            assert int(self.m_dut.WR_RECEIVED_INCR.value) == 0 or int(self.m_dut.WR_RECEIVED_INCR.value) == 1  or int(self.m_dut.WR_RECEIVED_INCR.value) == 2
            assert int(self.m_dut.RD_PROCESSED_INCR.value) == 0 or int(self.m_dut.RD_PROCESSED_INCR.value) == 1

            if (self.m_dut.RD_RECEIVED_INCR.value != 0b00):
                self.m_dut_received_rd += int(self.m_dut.RD_RECEIVED_INCR.value)
                self.m_dut_received_bytes_rd += int(self.m_dut.RD_RECEIVED_BYTES.value)

            if (self.m_dut.WR_RECEIVED_INCR.value != 0b00):
                self.m_dut_received_wr += int(self.m_dut.WR_RECEIVED_INCR.value)
                self.m_dut_received_bytes_wr += int(self.m_dut.WR_RECEIVED_BYTES.value)

            if (self.m_dut.RD_PROCESSED_INCR.value == 1):
                self.m_dut_processed_rd += 1
                self.m_dut_processed_bytes_rd += int(self.m_dut.RD_PROCESSED_BYTES.value)

    def _dump_buffer(self, filename : str, buff : bytearray):
        with open(filename, 'w') as f:
            for i in range(0, len(buff), 16):
                chunk = buff[i:i+16]
                address = f'{i:08x}'
                # Format each byte as two-digit hex, pad with zero if needed
                hex_bytes = ' '.join(f'{byte:02x}' for byte in chunk)
                f.write(f"{address} {hex_bytes}\n")

    def dump_buffers(self):
        self._dump_buffer("data_buff.txt", self.data_buff)
        self._dump_buffer("compl_queue.txt", self.compl_queue)


async def prepare(dut, cq_byte_size=2**17):
    CLK_PERIOD = 4

    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD, unit='ns').start())

    tb = Testbench(dut, cq_byte_size=cq_byte_size, debug=False)

    def random_tuple_iterator(min1, max1, min2, max2):
        while True:
            yield (random.randint(min1, max1), random.randint(min2, max2))

    tb.m_backpressure.start(random_tuple_iterator(1,20,1,20))
    cocotb.start_soon(tb.counter_sample())
    cocotb.start_soon(tb.cqe_process_model())

    await tb.reset_general()

    return tb

@cocotb.test()
async def run_random_write_test(dut, req_count: int = 1000):

    tb = await prepare(dut)

    trans_count_total = 0
    # tb._log.setLevel(logging.WARNING)

    for _ in range(req_count):
        addr = random.randint(0, tb.cq_byte_size-1)

        data_length = random.randint(1, 4096)
        data = bytearray(random.getrandbits(8) for _ in range(data_length))
        trans_count_total += await tb.create_write_req(addr, data, bar=4, func=1)

    last_num = 0

    while (tb.m_dut_received_wr < trans_count_total or tb.m_cq_mfb_driver.frame_cnt < trans_count_total):

        cocotb.log.info(f"Number of transactions processed: {tb.m_dut_received_wr}/{trans_count_total}")

        if (tb.m_dut_received_wr // 1000 > last_num):
            last_num = tb.m_dut_received_wr // 1000

        await ClockCycles(dut.CLK, 100)

    cocotb.log.info(f"Writes       DUT : {tb.m_dut_received_wr}, MODEL: {tb.m_model_received_wr}")
    cocotb.log.info(f"Writes bytes DUT : {tb.m_dut_received_bytes_wr}, MODEL: {tb.m_model_received_bytes_wr}")

    assert tb.m_dut_received_wr == tb.m_model_received_wr
    assert tb.m_dut_received_bytes_wr == tb.m_model_received_bytes_wr
    assert tb.m_dut_received_rd == tb.m_model_received_rd
    assert tb.m_dut_received_bytes_rd == tb.m_model_received_bytes_rd
    assert tb.m_dut_processed_rd == tb.m_model_received_rd
    assert tb.m_dut_processed_bytes_rd == tb.m_model_received_bytes_rd

    raise tb.m_scoreboard.result

@cocotb.test()
async def run_random_read_test(dut, req_count: int = 1000):

    tb = await prepare(dut)

    trans_count_total = 0
    # tb._log.setLevel(logging.WARNING)

    # Fill out the data buffer with random data
    tst_writes = (len(tb.data_buff)) // 4096
    for idx in range(tst_writes):
        addr = idx * 4096
        bar_id = 4

        data_length = 4096
        data = bytearray(random.getrandbits(8) for _ in range(data_length))
        trans_count_total += await tb.create_write_req(addr, data, bar_id, func=1)

    last_num = 0

    # Write some random data to buffers
    while (tb.m_dut_received_wr < trans_count_total or tb.m_cq_mfb_driver.frame_cnt < trans_count_total):
        cocotb.log.info(f"Number of transactions written: {tb.m_dut_received_wr}/{trans_count_total}")

        if (tb.m_dut_received_wr // 1000 > last_num):
            last_num = tb.m_dut_received_wr // 1000

        await ClockCycles(dut.CLK, 100)

    tb.dump_buffers()

    last_num = 0
    trans_count_total = 0

    for _ in range(req_count):
        addr = random.randint(0, tb.cq_byte_size-1)
        data_length = random.randint(1, 4096)
        bar_id = random.choice([2,4])
        # addr = 0x103e5
        # data_length = 128
        # bar_id = 1
        trans_count_total += (data_length + 127) // 128

        await tb.create_read_req(addr, data_length, bar_id, func=1)

    while (
            tb.m_dut_received_rd < tb.m_model_received_rd
            or tb.m_dut_processed_rd < tb.m_model_received_rd
            or tb.m_cc_mfb_monitor.frame_cnt < trans_count_total
    ):

        cocotb.log.info(f"Number of transactions dispatched: {tb.m_cc_mfb_monitor.frame_cnt}/{trans_count_total}")
        cocotb.log.info(f"Reads           DUT : {tb.m_dut_received_rd},  MODEL: {tb.m_model_received_rd}")
        cocotb.log.info(f"Processed reads DUT : {tb.m_dut_processed_rd}, MODEL: {tb.m_model_received_rd}")

        if (tb.m_cc_mfb_monitor.frame_cnt // 1000 > last_num):
            last_num = tb.m_cc_mfb_monitor.frame_cnt // 1000

        await ClockCycles(dut.CLK, 100)

    cocotb.log.info(f"Reads                 DUT : {tb.m_dut_received_rd}, MODEL: {tb.m_model_received_rd}")
    cocotb.log.info(f"Reads bytes           DUT : {tb.m_dut_received_bytes_rd}, MODEL: {tb.m_model_received_bytes_rd}")
    cocotb.log.info(f"Processed reads       DUT : {tb.m_dut_processed_rd}, MODEL: {tb.m_model_received_rd}")
    cocotb.log.info(f"Processed reads bytes DUT : {tb.m_dut_processed_bytes_rd}, MODEL: {tb.m_model_received_bytes_rd}")

    assert tb.m_dut_received_wr == tb.m_model_received_wr
    assert tb.m_dut_received_bytes_wr == tb.m_model_received_bytes_wr
    assert tb.m_dut_received_rd == tb.m_model_received_rd
    assert tb.m_dut_received_bytes_rd == tb.m_model_received_bytes_rd
    assert tb.m_dut_processed_rd == tb.m_model_received_rd
    assert tb.m_dut_processed_bytes_rd == tb.m_model_received_bytes_rd

    raise tb.m_scoreboard.result

@cocotb.test()
async def run_cqe_process_test(dut, req_total: int = 8000):

    tb = await prepare(dut, cq_byte_size=2**12)
    # tb._log.setLevel(logging.DEBUG)

    trans_count_total = 0
    current_phase_tag = 0b1
    cq_tdbl = 0
    req_count = 0
    addr = 0

    while req_count < req_total:
        if ((cq_tdbl + 1) % tb.cq_size) != tb.m_stat_upd_mon.cqhdbl:
            cqe = CQEntry()
            cqe.sq_id = random.randint(1, 2**16)
            cqe.sq_hdbl = random.randint(0, tb.cq_size)
            cqe.cmd_id = random.randint(0, 2**16)
            cqe.phase_tag = current_phase_tag
            cqe.stat_code = random.randint(1, 2**8)
            cqe.stat_code_type = random.randint(1, 2**3)
            cqe.more = random.choice([0b1, 0b0])
            cqe.do_not_retry = random.choice([0b1, 0b0])

            data = cqe.serialize().to_bytes(len(CQEntry()) // 8, 'little')
            trans_count_total += await tb.create_write_req(addr, data, bar=2, func=1)

            if (cqe.phase_tag == current_phase_tag):
                addr = (addr + tb.cq_entry_len) % tb.cq_byte_size
                cq_tdbl = (cq_tdbl + 1) % tb.cq_size

                if (cq_tdbl == 0):
                    current_phase_tag = ~current_phase_tag

            req_count += 1

        await RisingEdge(dut.CLK)

    last_num = 0

    while (
            tb.m_dut_received_wr < trans_count_total
            or tb.m_cq_mfb_driver.frame_cnt < trans_count_total
            or tb.m_stat_upd_mon.upd_processed < tb.m_model_cqes_processed
    ):

        cocotb.log.info(f"Number of transactions processed: {tb.m_stat_upd_mon.upd_processed}/{req_total}")

        if (tb.m_stat_upd_mon.upd_processed // 1000 > last_num):
            last_num = tb.m_stat_upd_mon.upd_processed // 1000

        await ClockCycles(dut.CLK, 100)

    cocotb.log.info(f"Writes         DUT : {tb.m_dut_received_wr}, MODEL: {tb.m_model_received_wr}")
    cocotb.log.info(f"Writes bytes   DUT : {tb.m_dut_received_bytes_wr}, MODEL: {tb.m_model_received_bytes_wr}")
    cocotb.log.info(f"CQEs processed DUT : {tb.m_stat_upd_mon.upd_processed}, MODEL: {tb.m_model_cqes_processed}")

    assert tb.m_dut_received_wr == tb.m_model_received_wr
    assert tb.m_dut_received_bytes_wr == tb.m_model_received_bytes_wr
    assert tb.m_dut_received_rd == tb.m_model_received_rd
    assert tb.m_dut_received_bytes_rd == tb.m_model_received_bytes_rd
    assert tb.m_dut_processed_rd == tb.m_model_received_rd
    assert tb.m_dut_processed_bytes_rd == tb.m_model_received_bytes_rd
    assert tb.m_stat_upd_mon.upd_processed == tb.m_model_cqes_processed

    raise tb.m_scoreboard.result
