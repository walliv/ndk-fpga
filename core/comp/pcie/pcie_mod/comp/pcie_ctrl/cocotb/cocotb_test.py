# cocotb_test.py: Routing of CQ requests in PCIE_CTRL between the MI32 bus and the DMA-BAR port
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""CQ requests of the Xilinx format enter PCIE_CTRL. Only BAR0 of function 0 may reach the MI32 bus,
every other BAR or function must come out of the DMA-BAR port unchanged. The model routes each request.
"""

import random
from dataclasses import dataclass, field

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb_bus.drivers import BitDriver
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.protocol import MfbProtocol
from cocotbext.ofm.mfb.transaction import MfbTransaction, MfbTransactionWithMeta
from cocotbext.ofm.pcie.PcieHeaders import CQHeader, CQMfbMeta
from cocotbext.ofm.ver.backpressure import BackpressureConfig, BackpressureGenerator

CLK_PERIOD_NS = 4
BAR_APERTURE = 26
MEM_RD = 0
MEM_WR = 1
BAR_BASE = [0x01000000, 0x02000000, 0x03000000, 0x04000000, 0x05000000, 0x06000000]

# PCIE_CQ_META layout of one region (pcie_meta_pack.vhd); the three TPH fields follow LBE as one random value
META_FBE_O = CQMfbMeta.offsets()["firstBe"]
META_LBE_O = CQMfbMeta.offsets()["lastBe"]
META_TPH_O = CQMfbMeta.offsets()["tph_present"]


@dataclass
class CqRequest:
    req_type: int
    bar: int
    func: int
    addr: int
    payload: list = field(default_factory=list)
    dwords: int = 1
    tag: int = 0
    meta_tph: int = 0

    @property
    def to_mi(self):
        return self.bar == 0 and self.func == 0

    def frame(self):
        hdr = CQHeader()
        hdr.addr = self.addr >> 2
        hdr.dword_count = self.dwords
        hdr.req_type = self.req_type
        hdr.tag = self.tag
        hdr.req_id = 0x1234
        hdr.tgt_func = self.func
        hdr.bar_id = self.bar
        hdr.bar_apper = BAR_APERTURE
        data = hdr.serialize().to_bytes(16, "little")
        for dw in self.payload:
            data += dw.to_bytes(4, "little")
        return data

    def meta(self):
        lbe = 0xF if self.dwords > 1 else 0
        return (0xF << META_FBE_O) | (lbe << META_LBE_O) | (self.meta_tph << META_TPH_O)


class RoutingModel:
    """Reference of PCIE_CTRL: where each CQ request goes and what the MI32 bus and the DMA-BAR port see."""

    def __init__(self):
        self.mi = []
        self.dma = []
        self.dma_total = 0
        self.cc_frames = 0

    def push(self, rq):
        if not rq.to_mi:
            self.dma.append(MfbTransactionWithMeta(data=rq.frame(), meta=rq.meta()))
            self.dma_total += 1
            return
        base = BAR_BASE[rq.bar] + (rq.addr & (2 ** BAR_APERTURE - 1))
        for i in range(rq.dwords):
            if rq.req_type == MEM_WR:
                self.mi.append(("wr", base + 4 * i, rq.payload[i], 0xF))
            else:
                self.mi.append(("rd", base + 4 * i, 0, 0xF))
        if rq.req_type == MEM_RD:
            self.cc_frames += 1


class MiMonitor:
    """Records the MI32 requests the DUT master side has issued and the slave has accepted."""

    def __init__(self, dut):
        self.dut = dut
        self.items = []
        cocotb.start_soon(self._run())

    async def _run(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            if d.RESET.value == 1 or d.MI_ARDY.value != 1:
                continue
            if d.MI_WR.value == 1:
                self.items.append(("wr", int(d.MI_ADDR.value), int(d.MI_DWR.value), int(d.MI_BE.value)))
            if d.MI_RD.value == 1:
                self.items.append(("rd", int(d.MI_ADDR.value), 0, int(d.MI_BE.value)))


class Testbench:

    def __init__(self, dut):
        self.dut = dut
        self.model = RoutingModel()
        self.cq_drv = MFBDriver(dut, "CQ_MFB", dut.CLK, protocol=MfbProtocol, generics_prefix="MFB", no_default_rate_limiter=True)
        self.dma_mon = MFBMonitor(dut, "DCQ_MFB", dut.CLK, trans_type=MfbTransactionWithMeta)
        self.cc_mon = MFBMonitor(dut, "CC_MFB", dut.CLK, trans_type=MfbTransaction)
        self.mi_mon = MiMonitor(dut)
        self.dma_ready = BitDriver(dut.DCQ_MFB_DST_RDY, dut.CLK)
        self.cc_ready = BitDriver(dut.CC_MFB_DST_RDY, dut.CLK)
        self.mi_ready = BitDriver(dut.MI_ARDY, dut.CLK)
        self.sb = Scoreboard(dut)
        self.sb.add_interface(self.dma_mon, self.model.dma)

    async def start(self, p_low):
        cocotb.start_soon(Clock(self.dut.CLK, CLK_PERIOD_NS, unit="ns").start())
        self.dut.RESET.value = 1
        self.dut.CQ_MFB_META.value = 0
        self.dut.DCQ_MFB_DST_RDY.value = 0
        self.dut.CC_MFB_DST_RDY.value = 0
        self.dut.MI_ARDY.value = 0
        await ClockCycles(self.dut.CLK, 10)
        self.dut.RESET.value = 0
        await ClockCycles(self.dut.CLK, 2)
        cfg = BackpressureConfig(1, 5, p_low)
        for rdy in (self.dma_ready, self.cc_ready, self.mi_ready):
            rdy.start(BackpressureGenerator(cfg))

    def send(self, rq):
        self.model.push(rq)
        self.cq_drv.append(MfbTransactionWithMeta(data=rq.frame(), meta=rq.meta()))

    async def finish(self, budget=200000):
        for _ in range(budget):
            await RisingEdge(self.dut.CLK)
            if (len(self.mi_mon.items) >= len(self.model.mi)
                    and self.dma_mon.frame_cnt >= self.model.dma_total
                    and self.cc_mon.frame_cnt >= self.model.cc_frames):
                break
        await ClockCycles(self.dut.CLK, 50)
        assert self.dma_mon.frame_cnt == self.model.dma_total, \
            f"DMA-BAR port got {self.dma_mon.frame_cnt} frames, {self.model.dma_total} expected"
        assert self.cc_mon.frame_cnt == self.model.cc_frames, \
            f"CC got {self.cc_mon.frame_cnt} completions, {self.model.cc_frames} expected"
        assert self.mi_mon.items == self.model.mi, \
            f"MI32 requests differ: {len(self.mi_mon.items)} seen, {len(self.model.mi)} expected\n" \
            f"seen     {self.mi_mon.items[:8]}\nexpected {self.model.mi[:8]}"
        raise self.sb.result


def make_request(rng, req_type, bar, func, max_dw=4):
    dwords = rng.randint(1, max_dw)
    addr = rng.randrange(0, 2 ** BAR_APERTURE, 4)
    payload = [rng.getrandbits(32) for _ in range(dwords)] if req_type == MEM_WR else []
    return CqRequest(req_type, bar, func, addr, payload, dwords, tag=rng.getrandbits(8), meta_tph=rng.getrandbits(11))


async def run(dut, requests, p_low):
    tb = Testbench(dut)
    await tb.start(p_low)
    for rq in requests:
        tb.send(rq)
    await tb.finish()


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def route_matrix(dut):
    """Every BAR of functions 0, 1, 2 and 255 with a read and a write: only BAR0 of function 0 reaches MI32."""
    rng = random.Random(cocotb.RANDOM_SEED)
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}")
    requests = [make_request(rng, t, bar, func)
                for func in (0, 1, 2, 255) for bar in range(6) for t in (MEM_WR, MEM_RD)]
    rng.shuffle(requests)
    await run(dut, requests, p_low=0.3)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def route_random(dut):
    """Random mix with a third of the traffic on BAR0 of function 0, random sizes and random backpressure."""
    rng = random.Random(cocotb.RANDOM_SEED)
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}")
    requests = []
    for _ in range(600):
        if rng.random() < 0.35:
            bar, func = 0, 0
        else:
            bar, func = rng.randrange(6), rng.choice((0, 0, 1, 3, 7, 64, 128, 255))
        requests.append(make_request(rng, rng.choice((MEM_WR, MEM_RD)), bar, func, max_dw=rng.choice((1, 4, 8))))
    await run(dut, requests, p_low=rng.choice((0.0, 0.3, 0.6)))
