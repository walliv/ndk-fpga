# cocotb_test.py: Functional verification other testbench for H2C DMA Hyperion using cocotb
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque
from dataclasses import dataclass
import random
import cocotb
import logging
from logging.handlers import RotatingFileHandler
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly
from cocotb.logging import SimLogFormatter

import cocotb_bus.monitors
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mi.drivers import MIRequestDriver
from cocotbext.ofm.dma.hyperion import H2CHyperionMIRegMap, CtrlRegBits

from cocotbext.ofm.mfb.fast_drivers import MFBDriver
from cocotbext.ofm.mfb.properties import attach_mfb_properties
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.mfb.utils import random_tuple_iterator
from cocotbext.ofm.pcie import CQMfbMeta, CQHeader, pcie_byte_count, PcieReqType

import cocotbext.axi
from cocotbext.axi import AxiWriteBus, MemoryRegion
from cocotbext.axi.axi_channels import AxiAWSink

# AXI3 carries a 4b AWLEN (max 16 beats) where cocotbext-axi defaults to the AXI4 8b. The sink checks the
# width when AxiSlaveWrite constructs it, so the patch only has to precede the Testbench.
HBM_LEN_WIDTH = 4
AxiAWSink._signal_widths = {**AxiAWSink._signal_widths, "awlen": HBM_LEN_WIDTH}

root_logger = logging.getLogger()
file_handler = RotatingFileHandler("rotating.log", maxBytes=(5 * 1024 * 1024), backupCount=2)
file_handler.setFormatter(SimLogFormatter(strip_ansi=True))
root_logger.addHandler(file_handler)


@dataclass(slots=True)
class MfbTrWithBe(MfbTransactionWithMeta):
    be: int = 0


class MonitorStatistics(cocotb_bus.monitors.MonitorStatistics):
    def __init__(self):
        super().__init__()
        self.received_bytes = 0


class AxiSlaveWrite(cocotbext.axi.AxiSlaveWrite, cocotb_bus.monitors.Monitor):
    def __init__(self, bus: AxiWriteBus, clk, rst=None, target=None, reset_active_level : bool = True, **kwargs):
        cocotbext.axi.AxiSlaveWrite.__init__(self, bus, clk, rst, target, reset_active_level, **kwargs)
        # Explicitly initialize the Monitor base class to ensure _callbacks and other members are set up.
        # This is necessary because cocotbext.axi.AxiSlaveWrite might not call super().__init__().
        cocotb_bus.monitors.Monitor.__init__(self)
        self.stats = MonitorStatistics()
        self.name = "AxiSlaveWriteMonitor"

    # Leave it empty since we need only AxiSlaveWrite.
    # Must be async because Monitor.__init__ schedules it.
    async def _monitor_recv(self):
        pass

    async def _write(self, address, data):
        # Write to the target memory
        await self.target.write(address, data)
        self.log.debug(f"Received AXI Write to address 0x{address:08X} of length {len(data)} bytes.")
        # assert address & 31 == 0, f"Unaligned AXI write to address 0x{address:08X}"

        self.stats.received_transactions += 1
        self.stats.received_bytes += len(data)
        # Run callbacks on the receved transaction
        for callback in self._callbacks:
            callback((address, data))


class HyperionModel:
    def __init__(self, mps: int = 512, axi_width: int = 512):
        self.wr_exp_out = []
        self.recv_trs = 0
        self.recv_trs_bytes = 0
        self.mps = mps  # Max Payload Size in bytes
        self.axi_width = axi_width
        self.byte_lanes = axi_width // 8

        self.log = logging.getLogger("cocotb.%s" % (type(self).__qualname__))

    def reset(self):
        self.wr_exp_out.clear()
        self.recv_trs = 0
        self.recv_trs_bytes = 0

    # Callback for the CQ MFB driver
    def proc_input(self, transaction: MfbTrWithBe):
        hdr = int.from_bytes(transaction.data[:len(CQHeader()) // 8], 'little')
        cq_hdr = CQHeader.deserialize(hdr)
        meta = CQMfbMeta.deserialize(transaction.meta)

        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Processing PCIe CQ Request: {cq_hdr}, Meta: {meta}")

        # Calculate the real length of data payload in bytes based on
        byte_count = pcie_byte_count(cq_hdr.dword_count, meta.firstBe, meta.lastBe)

        if meta.firstBe & 0b0001:
            offset = 0
        elif meta.firstBe & 0b0010:
            offset = 1
        elif meta.firstBe & 0b0100:
            offset = 2
        elif meta.firstBe & 0b1000:
            offset = 3
        else:
            offset = 0

        addr = (cq_hdr.addr << 2) + offset

        assert cq_hdr.req_type == PcieReqType.MWR, "Only Memory Write Requests are supported in HyperionModel."
        assert cq_hdr.req_id == 0, "Only Request ID 0 is supported in HyperionModel."
        assert cq_hdr.tag == 0, "Only Tag 0 is supported in HyperionModel."
        assert cq_hdr.tgt_func == 0, "Only Target Function 0 is supported in HyperionModel."
        assert cq_hdr.bar_id == 2, "Only BAR ID 0 is supported in HyperionModel."
        assert cq_hdr.bar_apper > 4, "BAR Apper must be greater than 4 in HyperionModel."
        assert cq_hdr.tc == 0, "Only Traffic Class 0 is supported in HyperionModel."
        assert cq_hdr.attr == 0, "Only Attr 0 is supported in HyperionModel."

        assert (addr & 0xFFFFF000) == ((addr + byte_count - 1) & 0xFFFFF000), "Writes over 4KB boundary are not supported."
        assert byte_count > 0, "Byte count must be greater than 0."
        assert byte_count <= self.mps, f"Byte count {byte_count} exceeds Max Payload Size {self.mps}."
        assert byte_count+offset in range(cq_hdr.dword_count*4 - 3, cq_hdr.dword_count*4 + 1), "Byte count does not match Dword Count and BE settings."

        data = transaction.data[(len(CQHeader()) // 8) + offset:]
        data = data[:byte_count]
        assert len(data) > 0, "Attempt to write data payload of 0 bytes"

        # Split the PCIe payload into AXI-sized chunks, correctly aligned
        curr_addr = addr
        remaining = data

        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Processing MWR to address 0x{addr:08X} of length {byte_count} bytes.")
        while remaining:
            bytes_to_boundary = self.byte_lanes - (curr_addr % self.byte_lanes)
            chunk_size = min(len(remaining), bytes_to_boundary)

            chunk = remaining[:chunk_size]
            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Generated AXI write to address 0x{curr_addr:08X} of length {len(chunk)} bytes.")
            self.wr_exp_out.append((curr_addr , chunk))

            curr_addr += chunk_size
            remaining = remaining[chunk_size:]
            self.recv_trs += 1
            self.recv_trs_bytes += chunk_size


def random_pause():
    while True:
        yield random.random() > 0.9  # 70% chance of dropping READY


class Testbench:
    def __init__(self, dut, debug=False):
        self.dut = dut
        self.mi_driver = MIRequestDriver(dut, "MI", dut.CLK)
        # A real CQ source legally deasserts SRC_RDY between and inside frames.
        self.cq_mfb_driver = MFBDriver(dut, "PCIE_CQ_MFB", dut.CLK, vld_gen=random_tuple_iterator(2, 8, 0, 4))
        # Conformance watchdog on the CQ input; it only samples, so it rides alongside the driver. nvc also
        # exposes the internal MFB signals of the top level, hence the explicit interface.
        self.mfb_props = attach_mfb_properties(
            dut, dut.CLK, reset=dut.RESET, include=("PCIE_CQ_MFB",),
            mfb_params={"regions": 1, "region_size": 1, "block_size": 8, "item_width": 32},
        )
        self.hbm_wr_slave = AxiSlaveWrite(AxiWriteBus.from_prefix(dut, "HBM_AXI"), dut.CLK, dut.RESET)
        region = MemoryRegion(2**self.hbm_wr_slave.address_width)
        self.hbm_wr_slave.target = region
        self.hbm_wr_slave.aw_channel.set_pause_generator(random_pause())
        self.hbm_wr_slave.w_channel.set_pause_generator(random_pause())
        self.model = HyperionModel(mps=256, axi_width=self.hbm_wr_slave.width)

        self.scoreboard = Scoreboard(dut)
        self.scoreboard.add_interface(self.hbm_wr_slave, self.model.wr_exp_out, strict_type=True)

        self.log = logging.getLogger("cocotb.%s" % (type(self).__qualname__))
        if debug:
            self.log.setLevel(logging.DEBUG)
            self.scoreboard.log.setLevel(logging.INFO)
            self.cq_mfb_driver.log.setLevel(logging.WARNING)
            self.hbm_wr_slave.log.setLevel(logging.DEBUG)
            self.model.log.setLevel(logging.DEBUG)
        else:
            self.scoreboard.log.setLevel(logging.WARNING)
            self.cq_mfb_driver.log.setLevel(logging.WARNING)
            self.hbm_wr_slave.log.setLevel(logging.WARNING)
            self.model.log.setLevel(logging.WARNING)

    async def reset(self):
        self.model.reset()
        self.cq_mfb_driver.clear()
        self.tb_rd_reqs = 0
        self.tb_rd_req_bytes = 0

        self.dut.RESET.value = 1
        await ClockCycles(self.dut.CLK, 100)
        self.dut.RESET.value = 0

    async def w_burst_monitor(self):
        """W-channel watchdog: no accepted W beat has WSTRB = 0, no burst exceeds 16 beats, and beats
        per WLAST match AWLEN+1 in order. An AW may follow its W beats, so both streams are queued
        and paired."""
        aw_lens = deque()
        w_lens = deque()
        beats = 0
        while True:
            await RisingEdge(self.dut.CLK)
            await ReadOnly()
            if bool(self.dut.HBM_AXI_AWVALID.value) and bool(self.dut.HBM_AXI_AWREADY.value):
                aw_lens.append(int(self.dut.HBM_AXI_AWLEN.value))

            if bool(self.dut.HBM_AXI_WVALID.value) and bool(self.dut.HBM_AXI_WREADY.value):
                assert int(self.dut.HBM_AXI_WSTRB.value) != 0, (
                    f"accepted a W beat with WSTRB = 0 (a padding beat) after {beats} beats of the "
                    f"current burst")
                beats += 1
                assert beats <= 16, f"{beats} W beats without a WLAST (AXI3 allows at most 16)"
                if bool(self.dut.HBM_AXI_WLAST.value):
                    w_lens.append(beats - 1)
                    beats = 0

            while aw_lens and w_lens:
                declared = aw_lens.popleft()
                sent = w_lens.popleft()
                assert declared == sent, (
                    f"burst declared AWLEN={declared} but its WLAST arrived after {sent + 1} beats")

    async def axi_aw_4k_boundary_monitor(self):
        """AXI3 write-burst legality watchdog: no accepted AW burst may cross a 4096B boundary
        (AMBA A3.4.1). AWLEN is the native 4b port, so the <=16-beat rule is structural."""
        while True:
            await RisingEdge(self.dut.CLK)
            await ReadOnly()
            if bool(self.dut.HBM_AXI_AWVALID.value) and bool(self.dut.HBM_AXI_AWREADY.value):
                addr = int(self.dut.HBM_AXI_AWADDR.value)
                length = int(self.dut.HBM_AXI_AWLEN.value)
                size = int(self.dut.HBM_AXI_AWSIZE.value)
                burst_bytes = (length + 1) << size
                start_page = addr & ~0xFFF
                end_page = (addr + burst_bytes - 1) & ~0xFFF
                assert start_page == end_page, (
                    f"AW burst crosses a 4KB boundary: addr=0x{addr:09X} awlen={length} "
                    f"awsize={size} (burst_bytes={burst_bytes})")

    async def axi_valid_hold_monitor(self):
        """AW/W handshake watchdog (AMBA A3.2.1): once VALID is asserted it stays asserted, with the
        payload unchanged, until READY takes the transfer."""
        dut = self.dut
        channels = (
            ("AW", dut.HBM_AXI_AWVALID, dut.HBM_AXI_AWREADY,
             (dut.HBM_AXI_AWID, dut.HBM_AXI_AWADDR, dut.HBM_AXI_AWLEN, dut.HBM_AXI_AWSIZE, dut.HBM_AXI_AWBURST)),
            ("W", dut.HBM_AXI_WVALID, dut.HBM_AXI_WREADY,
             (dut.HBM_AXI_WDATA, dut.HBM_AXI_WSTRB, dut.HBM_AXI_WLAST)),
        )
        stalled = {name: None for name, _, _, _ in channels}
        while True:
            await RisingEdge(dut.CLK)
            await ReadOnly()
            for name, valid, ready, payload in channels:
                v = bool(valid.value)
                now = tuple(str(sig.value) for sig in payload)
                held = stalled[name]
                if held is not None:
                    assert v, f"{name}VALID fell without a handshake (AMBA A3.2.1)"
                    assert now == held, f"{name} payload changed while {name}VALID waited for {name}READY"
                stalled[name] = now if v and not bool(ready.value) else None

    async def sample_cntrs(self):
        ctrl_reg = int.from_bytes(await self.mi_driver.read(H2CHyperionMIRegMap.CONTROL, 1))
        ctrl_reg |= (1 << CtrlRegBits.SAMPLE_CNTRS)
        await self.mi_driver.write(H2CHyperionMIRegMap.CONTROL, ctrl_reg.to_bytes(1, 'little'))

    async def check_counters(self, req_count):
        assert self.model.recv_trs == self.hbm_wr_slave.stats.received_transactions, \
            f"Mismatch in number of received write transactions: Model={self.model.recv_trs}, HBM Slave={self.hbm_wr_slave.stats.received_transactions}"
        assert self.model.recv_trs_bytes == self.hbm_wr_slave.stats.received_bytes, \
            f"Mismatch in number of received write bytes: Model={self.model.recv_trs_bytes}, HBM Slave={self.hbm_wr_slave.stats.received_bytes}"

        await self.sample_cntrs()
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_WR_REQS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == req_count, \
            f"PCIE write requests counter mismatch: Model= {req_count}, DUT= {int.from_bytes(cntr, 'little')}"
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_WR_REQ_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.model.recv_trs_bytes, \
            f"PCIE write bytes counter mismatch: Model= {self.model.recv_trs_bytes}, DUT= {int.from_bytes(cntr, 'little')}"
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_RD_REQS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == 0, \
            f"PCIE read requests counter mismatch: Model= 0, DUT= {int.from_bytes(cntr, 'little')}"
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_RD_REQ_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == 0, \
            f"PCIE read bytes counter mismatch: Model= 0, DUT= {int.from_bytes(cntr, 'little')}"
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.HBM_WR_TRS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.model.recv_trs, \
            f"HBM write transactions counter mismatch: Model= {self.model.recv_trs}, DUT= {int.from_bytes(cntr, 'little')}"
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.HBM_WR_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.model.recv_trs_bytes, \
            f"HBM write bytes counter mismatch: Model= {self.model.recv_trs_bytes}, DUT= {int.from_bytes(cntr, 'little')}"

    async def print_stats(self):
        self.log.info(f"Model received transactions:        {self.model.recv_trs}")
        self.log.info(f"Model received transaction bytes:   {self.model.recv_trs_bytes}")

        await self.sample_cntrs()
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_WR_REQS_CNTR_L, 8)
        self.log.info(f"PCIE write requests counter:        {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_WR_REQ_BYTES_CNTR_L, 8)
        self.log.info(f"PCIE write bytes counter:           {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_RD_REQS_CNTR_L, 8)
        self.log.info(f"PCIE read requests counter:         {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_RD_REQ_BYTES_CNTR_L, 8)
        self.log.info(f"PCIE read bytes counter:            {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.HBM_WR_TRS_CNTR_L, 8)
        self.log.info(f"HBM write transactions counter:     {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.HBM_WR_BYTES_CNTR_L, 8)
        self.log.info(f"HBM write bytes counter:            {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.PCIE_MFB_BLOCK_CNTR_L, 8)
        self.log.info(f"PCIE MFB block counter:             {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.HBM_W_BLOCK_CNTR_L, 8)
        self.log.info(f"HBM write block counter:            {int.from_bytes(cntr, 'little')}")
        cntr = await self.mi_driver.read(H2CHyperionMIRegMap.HBM_AW_BLOCK_CNTR_L, 8)
        self.log.info(f"HBM address write block counter:    {int.from_bytes(cntr, 'little')}")

    def create_cq_req(self, addr: int, data_len: int = 64, data: bytes = None) -> None:
        if data is None:
            data = random.randbytes(data_len)

        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Creating CQ Request for address 0x{addr:08X} (shifted {addr >> 2:08X}) with data length {len(data)} bytes.")

        # Calculate Dword count by considering the offset within the first DWord
        payload_offset = addr % 4
        payload_len = payload_offset + len(data)
        dword_count = (payload_len + 3) // 4

        cq_hdr = CQHeader()
        cq_hdr.addr = addr >> 2
        cq_hdr.dword_count = dword_count
        cq_hdr.req_type = PcieReqType.MWR
        cq_hdr.bar_id = 2
        cq_hdr.bar_apper = 34

        meta = CQMfbMeta()
        if dword_count == 1:
            meta.firstBe = ((1 << len(data)) - 1) << (addr % 4)
            meta.lastBe = 0
        else:
            meta.firstBe = [0xF, 0xE, 0xC, 0x8][addr % 4]
            meta.lastBe = [0xF, 0x1, 0x3, 0x7][(addr + len(data)) % 4]

        hdr_bytes = cq_hdr.serialize().to_bytes(len(cq_hdr) // 8, 'little')
        meta = meta.serialize()

        # Pad data to DWord boundary to ensure MFB item alignment
        full_data = hdr_bytes + (b'\x00' * payload_offset) + data + (b'\x00' * (dword_count * 4 - payload_len))

        # Byte enable mask covers:
        # - Header bytes (all zeros, first 16 bits)
        # - Payload data bytes (ones starting after header and offset)
        # - Invalid bytes (zeros)
        be = ((1 << len(data)) - 1) << (16 + payload_offset)

        tr = MfbTrWithBe(data=full_data, meta=meta, be=be)
        self.cq_mfb_driver.append(tr)
        self.model.proc_input(tr)


async def prepare(dut):
    CLK_PERIOD = 4
    cocotb.start_soon(Clock(dut.CLK, CLK_PERIOD, unit='ns').start())

    tb = Testbench(dut=dut, debug=False)
    tb.log.info(f"cocotb.RANDOM_SEED={cocotb.RANDOM_SEED} "
                f"(re-run with COCOTB_RANDOM_SEED=<seed> to reproduce this exact run, including "
                f"PCIE_CQ_MFB gap entropy)")
    await tb.reset()
    cocotb.start_soon(tb.w_burst_monitor())
    cocotb.start_soon(tb.axi_aw_4k_boundary_monitor())
    cocotb.start_soon(tb.axi_valid_hold_monitor())

    return tb


@cocotb.test()
async def run_random_read_test(dut, req_count: int = 10000):

    tb = await prepare(dut)

    axi_transfers = 0
    for _ in range(req_count):
        addr = random.randint(0, 0x3FFFFFFFF)
        max_data_len = min(tb.model.mps, 4096 - (addr % 4096))  # Ensure we don't cross 4KB boundary
        data_len = random.randint(1, max_data_len)
        tb.create_cq_req(addr=addr, data_len=data_len)

        # Calculate the amount of AXI transfers while considering alignment
        remaining = data_len
        curr_addr = addr
        while remaining > 0:
            bytes_to_boundary = tb.hbm_wr_slave.byte_lanes - (curr_addr % tb.hbm_wr_slave.byte_lanes)
            chunk_size = min(remaining, bytes_to_boundary)
            axi_transfers += 1
            curr_addr += chunk_size
            remaining -= chunk_size

    last_num = 0
    while (tb.hbm_wr_slave.stats.received_transactions < axi_transfers):

        if (tb.hbm_wr_slave.stats.received_transactions // 1000 > last_num):
            cocotb.log.info(f"Waiting for all AXI transactions to be received: {tb.hbm_wr_slave.stats.received_transactions}/{axi_transfers}")
            last_num = tb.hbm_wr_slave.stats.received_transactions // 1000

        await ClockCycles(dut.CLK, 100)
    await ClockCycles(dut.CLK, 100)

    await tb.check_counters(req_count)
    await tb.print_stats()

    raise tb.scoreboard.result
