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
from cocotb.triggers import RisingEdge, ClockCycles, FallingEdge
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta, MfbTransaction
from cocotb_bus.drivers import BitDriver, ValidatedBusDriver
from cocotb_bus.scoreboard import Scoreboard
from cocotbext.ofm.pcie.PcieHeaders import RQHeader, RQMfbMeta

class SQDblUpdDriver(ValidatedBusDriver):
    _signals = ["data", "vld"]

    def __init__(self, entity, name, clock, vld_gen, **kwargs):
        super().__init__(entity, name, clock, valid_generator=vld_gen, **kwargs)

        self.bus.data.value = 0
        self.bus.vld.value = 0
        self.frame_cnt = 0

    async def _driver_send(self, value, sync=True):
        """Send a transmission over the bus.

        Args:
            value: data to drive onto the bus.
        """
        self.log.debug("Sending a SQDBL update: %r", value)

        # Avoid spurious object creation by recycling
        clkedge = RisingEdge(self.clock)

        # Drive some defaults since we don't know what state we're in
        self.bus.vld.value = 0

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

        self.bus.data.value = value
        self.bus.vld.value = 1

        await clkedge

        self.bus.data.value = 0
        self.bus.vld.value = 0

        self.log.debug("Successfully sent the SQTDBL update: %r", value)
        self.frame_cnt += 1

    def reset(self):
        self.bus.data.value = 0
        self.bus.vld.value = 0

class Testbench():
    def __init__(self, dut, vld_gen, debug=False):

        self.m_dut = dut
        self.m_mfb_monitor = MFBMonitor(dut, "PCIE_RQ_MFB", dut.CLK, trans_type=MfbTransactionWithMeta)
        self.m_backpressure = BitDriver(dut.PCIE_RQ_MFB_DST_RDY, dut.CLK)
        self.m_dbl_driver = SQDblUpdDriver(dut, "DBL", dut.CLK, vld_gen)

        # Create a scoreboard on the response_stream_out bus
        self.m_expected_output = []
        self.m_scoreboard = Scoreboard(dut)
        self.m_scoreboard.add_interface(self.m_mfb_monitor, self.m_expected_output, strict_type=True)

        self.m_model_dbl_value = 0
        self.m_model_upds_sent = 0
        self.m_dut_reg_upds = 0
        self.m_dut_rpt_upds = 0

        if debug:
            self.m_mfb_monitor.log.setLevel(logging.DEBUG)
            self.m_scoreboard.log.setLevel(logging.DEBUG)
            self.m_dbl_driver.log.setLevel(logging.DEBUG)

    async def model(self, dbl_baddr):
        while True:
            await FallingEdge(self.m_dut.CLK)

            if bool(self.m_dut.PCIE_RQ_MFB_DST_RDY.value) and bool(self.m_dut.PCIE_RQ_MFB_SRC_RDY.value):
                dbl_hdr = RQHeader()
                dbl_hdr.addr = dbl_baddr >> 2
                dbl_hdr.dword_count = 1
                dbl_hdr.req_type = 1
                dbl_hdr.req_id = 1
                dbl_hdr.attr = 0b001
                dbl_hdr.force_ecrc = 1
                mfb_meta = RQMfbMeta()
                mfb_meta.firstBe = 0x3
                mfb_meta.lastBe = 0x0

                tran = self.m_model_dbl_value.to_bytes(4, 'little')
                pcie_hdr = dbl_hdr.serialize().to_bytes(16, 'little')

                pcie_trans = MfbTransactionWithMeta(data=pcie_hdr+tran, meta=mfb_meta.serialize())
                self.m_expected_output.append(pcie_trans)

                self.m_model_upds_sent += 1

    async def model_ptr_upd(self):
        while True:
            await RisingEdge(self.m_dut.CLK)

            if bool(self.m_dut.DBL_VLD.value):
                self.m_model_dbl_value = int(self.m_dut.DBL_DATA.value)

    async def dut_cntrs(self):
        while True:
            await RisingEdge(self.m_dut.CLK)

            if bool(self.m_dut.REG_UPD_DISPATCHED.value):
                self.m_dut_reg_upds += 1

            if bool(self.m_dut.RPT_UPD_DISPATCHED.value):
                self.m_dut_rpt_upds += 1

    async def reset_general(self):
        self.m_model_dbl_value = 0
        self.m_model_upds_sent = 0
        self.m_dut_reg_upds = 0
        self.m_dut_rpt_upds = 0
        self.m_dbl_driver.reset()

        self.m_dut.RST.value = 1
        await ClockCycles(self.m_dut.CLK, 10)
        self.m_dut.RST.value = 0
        await RisingEdge(self.m_dut.CLK)

async def test_base(dut, transaction_count: int = 1000):
    def random_tuple_iterator(min1, max1, min2, max2):
        while True:
            yield (randint(min1, max1), randint(min2, max2))

    CLK_PERIOD = 4

    tb = Testbench(dut, random_tuple_iterator(1,2,0,100), debug=False)
    cocotb.log.info("Created testbench")

    c = Clock(dut.CLK, CLK_PERIOD, unit='ns')
    c.start()

    dbl_baddr = randint(0, 2**64)
    dut.DBL_BASE_ADDR.value = dbl_baddr

    tb.m_backpressure.start(random_tuple_iterator(1,20,0,20))
    await tb.reset_general()
    cocotb.log.info("Reset done")
    cocotb.log.info("Backpressure activated")

    cocotb.start_soon(tb.model(dbl_baddr))
    cocotb.start_soon(tb.model_ptr_upd())
    cocotb.start_soon(tb.dut_cntrs())
    cocotb.log.info("Model activated")

    dbl_val = 0

    for _ in range(transaction_count):
        await RisingEdge(dut.CLK)

        if choice([True, False]):
            dbl_val += 1

        if choice([True, False]):
            tb.m_dbl_driver.append(dbl_val)

    cocotb.log.info(f"All transactions dispatched {tb.m_model_upds_sent=}")

    # last_num = 0
    while len(tb.m_dbl_driver._sendQ) != 0 or tb.m_model_upds_sent != tb.m_dut_reg_upds + tb.m_dut_rpt_upds:
        await RisingEdge(dut.CLK)
        # cocotb.log.info(f"{len(tb.m_dbl_driver._sendQ)=}")
        # cocotb.log.info(f"{tb.m_mfb_monitor.frame_cnt=}/{tb.m_model_upds_sent=}")
        # cocotb.log.info(f"{dbl_val=:x}/{int(dut.cqhdbl_reg.value)=:x}")

    assert tb.m_mfb_monitor.frame_cnt == tb.m_model_upds_sent
    assert tb.m_model_dbl_value == int(dut.cqhdbl_reg.value)
    assert len(tb.m_dbl_driver._sendQ) == 0
    assert tb.m_model_upds_sent == tb.m_dut_reg_upds + tb.m_dut_rpt_upds

    await ClockCycles(dut.CLK, 300)

    cocotb.log.info("SIMULATION FINISHED!")
    raise tb.m_scoreboard.result

@cocotb.test()
async def tst_regular(dut, transaction_count: int = 1000):
    dut.REPEAT_UPDATE_EN.value = 0
    await test_base(dut, transaction_count)

@cocotb.test()
async def tst_repeated(dut, transaction_count: int = 1000):
    dut.REPEAT_UPDATE_EN.value = 1
    await test_base(dut, transaction_count)
