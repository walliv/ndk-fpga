# cocotb_test.py: NVME CC Packet dispatcher testbench
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from random import randint
from copy import copy, deepcopy

import cocotb

from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb_bus.drivers import BitDriver

from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotb_bus.scoreboard import Scoreboard
from cocotbext.ofm.mfb.transaction import MfbTrClassicWithMeta, MfbTrClassic
from cocotbext.ofm.mvb.drivers import MVBDriver
from cocotbext.ofm.mvb.transaction import MvbTrClassic
from cocotbext.ofm.pcie.Axi4SRequester import RequestHeader
from cocotbext.ofm.utils.throughput_probe import ThroughputProbe, ThroughputProbeMfbInterface
from cocotbext.ofm.ver.generators import random_integers, random_packets

class Testbench:

    _RX_MFB_CONF = {
        "regions" : 1,
        "region_size" : 1,
        "block_size" : 64,
        "item_width" : 8
    }

    def __init__(self, dut, debug=False):

        self.m_dut = dut
        self.m_mfb_driver = MFBDriver(dut, "RX_MFB", dut.CLK, mfb_params=self._RX_MFB_CONF)
        self.m_mvb_driver = MVBDriver(dut, "PCIE_HDR", dut.CLK)
        self.m_mfb_monitor = MFBMonitor(dut, "TX_MFB", dut.CLK)
        self.m_backpressure = BitDriver(dut.TX_MFB_DST_RDY, dut.CLK)

        self.m_throughput_probe = ThroughputProbe(ThroughputProbeMfbInterface(self.m_mfb_monitor), throughput_units="bits")
        self.m_throughput_probe.add_log_interval(0, None)
        self.m_throughput_probe.set_log_period(10)

        # Create a scoreboard on the response_stream_out bus
        self.m_expected_output = []
        self.m_scoreboard = Scoreboard(dut)
        self.m_scoreboard.add_interface(self.m_mfb_monitor, self.m_expected_output, strict_type=True)

        self.m_pkts_sent = 0
        self.m_trans_sent = 0

        if debug:
            self.m_mfb_driver.log.setLevel(cocotb.logging.DEBUG)
            self.m_mvb_driver.log.setLevel(cocotb.logging.DEBUG)
            self.m_mfb_monitor.log.setLevel(cocotb.logging.DEBUG)
            self.m_scoreboard.log.setLevel(cocotb.logging.DEBUG)

    def model(self, mfb_tr, hdrs):
        """Model the DUT based on the input transaction"""

        for segment_start in range(0, len(mfb_tr.data), 128):
            segment_end = min(128, len(mfb_tr.data) - segment_start)
            pkt_segment = mfb_tr.data[segment_start:segment_start+segment_end]
            if (len(pkt_segment) % 4) != 0:
                # Extend lenghth of a packet segment to the nearest multiple of 4j
                padding_length = (4 - (len(pkt_segment)%4)) % 4
                pkt_segment = pkt_segment + (b'\x00' * padding_length)

            current_hdr = hdrs.pop(0).to_bytes(12, 'little')
            # cocotb.log.info(f"{len(mfb_tr.data)=}\n{segment_start=}\n{segment_end=}\n{current_hdr.hex()=}\n{pkt_segment.hex()=}\n{len(pkt_segment)=}")
            assert segment_end > 0

            pcie_trans = MfbTrClassicWithMeta(data=current_hdr + pkt_segment)
            self.m_expected_output.append(pcie_trans)
            self.m_trans_sent += 1

        self.m_pkts_sent += 1

    async def reset_general(self):
        self.m_dut.RST.value = 1
        await ClockCycles(self.m_dut.CLK, 2)
        self.m_dut.RST.value = 0
        await RisingEdge(self.m_dut.CLK)

@cocotb.test()
async def run_test(dut, pkt_count: int = 1000, frame_size_min: int = 1, frame_size_max: int = 4096):
    CLK_PERIOD = 4

    # The Intel checks only MFB_DATA but not MFB_META
    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD, units='ns').start())
    tb = Testbench(dut, debug=False)
    # tb.log.set_level(cocotb.logging.INFO)

    await tb.reset_general()

    def random_tuple_iterator(min1, max1, min2, max2):
        while True:
            yield (randint(min1, max1), randint(min2, max2))

    tb.m_backpressure.start(random_tuple_iterator(1,20,1,20))
    # dut.TX_MFB_DST_RDY = 1

    mvb_data_width = tb.m_mvb_driver.item_widths["data"]
    pcie_hdrs = []
    # The overall amount of PCIe transactions since large packets need to be segmented
    trans_total_amount = 0

    for pkt_data in random_packets(frame_size_min, frame_size_max, pkt_count):
        num_pcie_hdrs = (len(pkt_data) + 127) // 128
        trans_total_amount += num_pcie_hdrs;

        for _ in range(num_pcie_hdrs):
            current_hdr = randint(0, 2**mvb_data_width-1)
            pcie_hdrs.append(current_hdr)
            mvb_tr = MvbTrClassic()
            mvb_tr.data = current_hdr;
            tb.m_mvb_driver.append(mvb_tr)

        mfb_tr = MfbTrClassic(data=pkt_data)
        tb.m_mfb_driver.append(mfb_tr)
        tb.model(mfb_tr, pcie_hdrs)

    last_num = 0
    while (tb.m_mfb_monitor.frame_cnt < trans_total_amount):
        if (tb.m_mfb_monitor.frame_cnt // 1000 > last_num):
            last_num = tb.m_mfb_monitor.frame_cnt // 1000
            cocotb.log.info("Number of transactions processed: %d/%d" % (tb.m_mfb_monitor.frame_cnt, trans_total_amount))

        await ClockCycles(dut.CLK, 100)

    cocotb.log.info(f"RX: {tb.m_mfb_driver.frame_cnt}/{pkt_count}")
    cocotb.log.info(f"TX: {tb.m_mfb_monitor.frame_cnt}/{trans_total_amount}")
    cocotb.log.info(f"SC: Transactions: {tb.m_trans_sent}/{trans_total_amount}, packets: {tb.m_pkts_sent}/{pkt_count}")
    tb.m_throughput_probe.log_max_throughput()
    tb.m_throughput_probe.log_average_throughput()
    cocotb.log.info("SIMULATION FINISHED!")
    raise tb.m_scoreboard.result
