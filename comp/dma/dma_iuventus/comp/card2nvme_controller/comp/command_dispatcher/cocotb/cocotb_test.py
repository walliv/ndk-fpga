# cocotb_test.py: NVME dispatcher testbench
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import itertools
from random import choice, randint
from pickle import dumps
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Edge, FallingEdge, ReadOnly
from cocotb.queue import Queue
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta, MfbTransaction
from cocotb_bus.drivers import BitDriver, ValidatedBusDriver
from cocotb_bus.scoreboard import Scoreboard
from cocotbext.ofm.utils.throughput_probe import ThroughputProbe, ThroughputProbeMfbInterface
from cocotbext.ofm.utils.header import SerializableHeader
from cocotbext.ofm.pcie import RQHeader, RQMfbMeta

class SQCmdMfbMeta(SerializableHeader):
    items = list(zip(
        ['pcie_addr', 'chan_idx', 'be'],
        [64, 1, 32],
    ))

class SQCommand():
    # Empty command (and also invalid) initialized completely to 0
    _cmd_dwords = [bytearray(4) for _ in range(16)]

    def __init__(self, opcode, nsid, meta_ptr, prp_entry1, prp_entry2, start_lba, lba_amount, cmd_id):
        assert opcode in [0b0, 0b1]
        assert 0 <= nsid <= 0xFFFFFFFF
        assert 0 <= meta_ptr <= 0xFFFFFFFFFFFFFFFF
        assert 0 <= prp_entry1 <= 0xFFFFFFFFFFFFFFFF
        assert 0 <= prp_entry2 <= 0xFFFFFFFFFFFFFFFF
        assert 0 <= start_lba <= 0xFFFFFFFFFFFFFFFF
        assert 0 <= lba_amount <= 0xFFFF

        opcode = 0x1 if opcode == 0 else 0x2

        dw1 = opcode
        dw1 |= (cmd_id << 16)

        self._cmd_dwords[0] = bytearray(dw1.to_bytes(4, 'little'))
        self._cmd_dwords[1] = bytearray(nsid.to_bytes(4,'little'))
        self._cmd_dwords[4] = bytearray((meta_ptr & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[5] = bytearray(((meta_ptr >> 32) & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[6] = bytearray((prp_entry1 & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[7] = bytearray(((prp_entry1 >> 32) & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[8] = bytearray((prp_entry2 & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[9] = bytearray(((prp_entry2 >> 32) & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[10] = bytearray((start_lba & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[11] = bytearray(((start_lba >> 32) & 0xFFFFFFFF).to_bytes(4,'little'))
        self._cmd_dwords[12] = bytearray(lba_amount.to_bytes(4, 'little'))

        self.cmd_id = cmd_id;

    def serialize(self):
        outp_obj = b''.join(self._cmd_dwords)
        return outp_obj

class CplUpdDriver(ValidatedBusDriver):
    _signals = ["tag", "sqhdbl", "vld"]

    def __init__(self, entity, name, clock, vld_gen, **kwargs):
        super().__init__(entity, name, clock, valid_generator=vld_gen, **kwargs)

        self.bus.tag.value = 0
        self.bus.sqhdbl.value = 0
        self.bus.vld.value = 0

    async def _driver_send(self, value, sync=True):
        """Send a transmission over the bus.

        Args:
            value: data to drive onto the bus.
        """
        self.log.debug("Sending a SQHDBL update: %r", value)

        # Avoid spurious object creation by recycling
        clkedge = RisingEdge(self.clock)

        # Drive some defaults since we don't know what state we're in
        self.bus.vld.value = 0

        if sync:
            await clkedge

        # Insert a gap where valid is low
        if not self.on:
            self.bus.vld.value = 0
            for _ in range(self.off):
                await clkedge

            # Grab the next set of on/off values
            self._next_valids()

        # Consume a valid cycle
        if self.on is not True and self.on:
            self.on -= 1

        self.bus.vld.value = 1

        tag, sqhdbl = value
        self.bus.tag.value = tag
        self.bus.sqhdbl.value = sqhdbl

        await clkedge
        self.bus.vld.value = 0
        self.bus.sqhdbl.value = 0
        self.bus.tag.value = 0

        self.log.debug(f"Successfully sent the SQHDBL and TAG update: {sqhdbl}, {tag}")

    def reset(self):
        self.bus.tag.value = 0x0FF0
        self.bus.sqhdbl.value = 0xF00F
        self.bus.vld.value = 0

class Testbench():
    def __init__(self, dut, vld_gen, dbl_mask, same_clk=True):

        self.m_dut = dut
        self.m_sq_cmd_mfb_monitor = MFBMonitor(dut, "SQ_CMD_MFB", dut.CLK, trans_type = MfbTransactionWithMeta)
        self.m_sq_cmd_mfb_bpsr = BitDriver(dut.SQ_CMD_MFB_DST_RDY, dut.CLK)
        self.m_sqhdbl_driver = CplUpdDriver(dut, "CPL_STAT", dut.CLK, vld_gen)
        self._log = logging.getLogger("cocotb")
        self.tag_queue = Queue()

        self.m_thrp_probe1 = ThroughputProbe(ThroughputProbeMfbInterface(self.m_sq_cmd_mfb_monitor), throughput_units="bytes", time_units="us")
        self.m_thrp_probe1.log = logging.getLogger("cocotb.probe.SQ_CMD_MFB")
        self.m_thrp_probe1.set_log_period(10, "us")

        # Create a scoreboard on the response_stream_out bus
        self.m_exp_out_sq_cmd = []
        self.m_exp_out_sqtdbl_upd = []
        self.m_scoreboard = Scoreboard(dut)
        self.m_scoreboard.add_interface(self.m_sq_cmd_mfb_monitor, self.m_exp_out_sq_cmd, strict_type=True)

        self.m_model_iops_sent = 0
        self.m_dut_iops_sent = 0
        self.m_dbl_mask = dbl_mask
        self.m_sqhdbl_value = 0
        self.m_sqtdbl_value = 0
        self.m_sqtdbl_dut_value = 0
        self.cmd_id = 0

        self.m_sq_cmd_mfb_monitor.log.setLevel(logging.WARNING)
        self.m_sqhdbl_driver.log.setLevel(logging.WARNING)
        self.m_scoreboard.log.setLevel(logging.INFO)

    async def model(self, test_trans : SQCommand, sq_baddr):
        """Model the DUT based on the input transaction"""

        mfb_meta = SQCmdMfbMeta()
        mfb_meta.be = 0xFFFFFFFF
        mfb_meta.pcie_addr = (sq_baddr + (self.m_sqtdbl_value << 6))
        mfb_meta.chan_idx = 0

        tran = test_trans.serialize()
        cocotb.log.debug(f"Generated SQ CMD on address x{mfb_meta.pcie_addr:x}:\n{tran.hex()}")

        cmd_trans = MfbTransactionWithMeta(data=tran, meta=mfb_meta.serialize())
        self.m_exp_out_sq_cmd.append(cmd_trans)

        await self.tag_queue.put(test_trans.cmd_id)
        self.m_sqtdbl_value = (self.m_sqtdbl_value + 1) & self.m_dbl_mask
        self.m_model_iops_sent += 1

    async def update_sqhdbl(self):

        while True:
            await RisingEdge(self.m_dut.CLK)

            if (self.m_dut.TAG_INIT_DONE.value == 0 or self.m_dut.RST.value == 1):
                continue

            # Update when the Head pointer is not equal to the Tail pointer which means that only
            # when the buffer is not empty
            if self.m_dut.sqtdbl_reg.value != self.m_sqhdbl_value:
                self.m_sqhdbl_value = (self.m_sqhdbl_value + 1) & self.m_dbl_mask
                tag = await self.tag_queue.get()
                self.m_sqhdbl_driver.append((tag, self.m_sqhdbl_value))

    async def counter_sample(self):
        while True:
            await RisingEdge(self.m_dut.CLK)

            if (self.m_dut.SQE_DISP_CNTR_INCR.value == 0b1):
                self.m_dut_iops_sent += 1
                self.m_sqtdbl_dut_value = int(self.m_dut.SQTDBL_VAL.value)

    async def reset_general(self):
        self.m_model_iops_sent = 0
        self.m_dut_iops_sent = 0
        self.m_sqtdbl_value = 0
        self.m_sqhdbl_value = 0
        self.m_sqtdbl_dut_value = 0
        self.m_sqhdbl_driver.reset()

        self.m_dut.RST.value = 1
        await ClockCycles(self.m_dut.CLK, 10)
        self.m_dut.RST.value = 0
        await RisingEdge(self.m_dut.CLK)

        # Wait until the TAGs are initialized
        await RisingEdge(self.m_dut.TAG_INIT_DONE)

async def prepare_tb(dut, dbl_mask=0x00FF, tx_dst_rdy_bpsr=True):
    def random_tuple_iterator(min1, max1, min2, max2):
        while True:
            yield (randint(min1, max1), randint(min2, max2))

    CLK_PERIOD = 4

    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD, unit='ns').start())

    tb = Testbench(dut, random_tuple_iterator(1,2,0,100), dbl_mask)

    if tx_dst_rdy_bpsr:
        tb.m_sq_cmd_mfb_bpsr.start(random_tuple_iterator(1,20,0,20))
    else:
        dut.SQ_CMD_MFB_DST_RDY.value = 1

    cocotb.start_soon(tb.counter_sample())
    cocotb.start_soon(tb.update_sqhdbl())

    dut.TRIGG_DISPATCH.value = 0
    dut.SQTDBL_INIT_VAL.value = 0
    dut.DBL_MASK.value = dbl_mask
    dut.NAMESPACE_ID.value = 1
    dut.METADATA_PTR.value = 0

    dut.RD_EN.value = 0
    dut.SQ_BASE_ADDR.value = 0
    dut.PRP_ENTRY_1.value = 0
    dut.PRP_ENTRY_2.value = 0
    dut.START_LBA_PTR.value = 0
    dut.LBA_NUM.value = 0
    dut.LBA_SPACE_SIZE.value = 0

    await tb.reset_general()

    return tb

@cocotb.test()
async def run_single_dispatch_test(dut, transaction_count: int = 5000):

    tb = await prepare_tb(dut)
    # tb._log.setLevel(logging.DEBUG)

    tb.m_thrp_probe1.start_log()

    cmd_id = 0
    for _ in range(transaction_count):

        # choose between read and write
        opcode = choice([0b1, 0b0])
        sq_base_addr = randint(0, (2**64)-1)
        # sq_base_addr = 0xFFFFFFFFCAFEBABE
        # dbl_base_addr = 0xDEADBEADFFFFFFFF
        prp_entry1 = randint(0, (2**64)-1)
        prp_entry2 = randint(0, (2**64)-1)
        lba_space_size = randint(1, (2**64)-1)
        start_lba = randint(0, lba_space_size-1)
        lba_amount = randint(0, (2**16)-1)

        for _ in range(0, 1000):
            await FallingEdge(dut.CLK)
            status = bool(dut.READY_FOR_DISPATCH.value)
            cocotb.log.debug(f"Read status {status}")
            if status: break
        else:
            cocotb.log.error("Not able to capture the positive ready status.")
            assert False

        dut.RD_EN.value = opcode
        dut.SQ_BASE_ADDR.value = sq_base_addr
        dut.PRP_ENTRY_1.value = prp_entry1
        dut.PRP_ENTRY_2.value = prp_entry2
        dut.START_LBA_PTR.value = start_lba
        dut.LBA_NUM.value = lba_amount
        dut.LBA_SPACE_SIZE.value = lba_space_size

        lba_amount_capped = min(lba_amount, (lba_space_size + 1) - start_lba)
        sq_cmd = SQCommand(opcode, 1, 0, prp_entry1, prp_entry2, start_lba, lba_amount_capped, cmd_id)
        await tb.model(sq_cmd, sq_base_addr)

        dut.TRIGG_DISPATCH.value = 1
        await RisingEdge(dut.CLK)
        dut.TRIGG_DISPATCH.value = 0
        await RisingEdge(dut.CLK)

        cmd_id = (cmd_id + 1) % 2048;

    last_num = 0
    while (
            tb.m_dut_iops_sent < tb.m_model_iops_sent
            or tb.m_sq_cmd_mfb_monitor.frame_cnt < transaction_count
    ):
        cocotb.log.info(f"Number of transactions processed: {tb.m_dut_iops_sent}/{tb.m_model_iops_sent}")

        if (tb.m_sq_cmd_mfb_monitor.frame_cnt // 1000 > last_num):
            last_num = tb.m_cq_cmd_mfb_monitor.frame_cnt // 1000

    await ClockCycles(dut.CLK, 100)

    cocotb.log.info(f"IOPs counters: DUT: {tb.m_dut_iops_sent}, MODEL: {tb.m_model_iops_sent}")
    cocotb.log.info(f"MFB transactions: Monitor: {tb.m_sq_cmd_mfb_monitor.frame_cnt}, Testbench: {transaction_count}")
    cocotb.log.info(f"TB Tag Queue status: {tb.tag_queue.qsize()}")

    assert tb.m_dut_iops_sent == tb.m_model_iops_sent
    assert tb.m_sq_cmd_mfb_monitor.frame_cnt == transaction_count
    assert tb.tag_queue.qsize() == 0
    assert tb.m_sqtdbl_value == tb.m_sqtdbl_dut_value

    tb.m_thrp_probe1.stop_log()
    raise tb.m_scoreboard.result

@cocotb.test()
async def run_continuous_dispatch_test(dut, transaction_count: int = 5000):

    tb = await prepare_tb(dut, tx_dst_rdy_bpsr=False)
    # tb._log.setLevel(logging.DEBUG)

    tb.m_thrp_probe1.start_log()
    await RisingEdge(dut.CLK)
    dut.TRIGG_DISPATCH.value = 1

    cmd_id = 0
    for _ in range(transaction_count):

        # choose between read and write
        opcode = choice([0b1, 0b0])
        sq_base_addr = randint(0, (2**64)-1)
        prp_entry1 = randint(0, (2**64)-1)
        prp_entry2 = randint(0, (2**64)-1)
        lba_space_size = randint(1, (2**64)-1)
        start_lba = randint(0, lba_space_size-1)
        lba_amount = randint(0, (2**16)-1)

        dut.RD_EN.value = opcode
        dut.SQ_BASE_ADDR.value = sq_base_addr
        dut.PRP_ENTRY_1.value = prp_entry1
        dut.PRP_ENTRY_2.value = prp_entry2
        dut.START_LBA_PTR.value = start_lba
        dut.LBA_NUM.value = lba_amount
        dut.LBA_SPACE_SIZE.value = lba_space_size

        lba_amount_capped = min(lba_amount, (lba_space_size + 1) - start_lba)
        sq_cmd = SQCommand(opcode, 1, 0, prp_entry1, prp_entry2, start_lba, lba_amount_capped, cmd_id)
        await tb.model(sq_cmd, sq_base_addr)

        for _ in range(0, 1000):
            await RisingEdge(dut.CLK)
            status = bool(dut.READY_FOR_DISPATCH.value)
            cocotb.log.debug(f"Read status {status}")
            if status: break
            # await ClockCycles(dut.CLK, 10)
        else:
            cocotb.log.error("Not able to capture the positive ready status.")
            assert False

        cmd_id = (cmd_id + 1) % 2048;

    await RisingEdge(dut.CLK)
    dut.TRIGG_DISPATCH.value = 0
    await ClockCycles(dut.CLK, 10)
    await RisingEdge(dut.CLK)

    last_num = 0
    while (
            tb.m_dut_iops_sent < tb.m_model_iops_sent
            or tb.m_sq_cmd_mfb_monitor.frame_cnt < transaction_count
    ):
        cocotb.log.info(f"Number of transactions processed: {tb.m_dut_iops_sent}/{tb.m_model_iops_sent}")

        if (tb.m_sq_cmd_mfb_monitor.frame_cnt // 1000 > last_num):
            last_num = tb.m_cq_cmd_mfb_monitor.frame_cnt // 1000

        await ClockCycles(dut.CLK, 100)

    cocotb.log.info(f"IOPs counters: DUT: {tb.m_dut_iops_sent}, MODEL: {tb.m_model_iops_sent}")
    cocotb.log.info(f"MFB transactions: Monitor: {tb.m_sq_cmd_mfb_monitor.frame_cnt}, Testbench: {transaction_count}")
    cocotb.log.info(f"TB Tag Queue status: {tb.tag_queue.qsize()}")

    assert tb.m_dut_iops_sent == tb.m_model_iops_sent
    assert tb.m_sq_cmd_mfb_monitor.frame_cnt == transaction_count
    assert tb.tag_queue.qsize() == 0
    assert tb.m_sqtdbl_value == tb.m_sqtdbl_dut_value

    tb.m_thrp_probe1.stop_log()
    raise tb.m_scoreboard.result
