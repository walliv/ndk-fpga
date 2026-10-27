# cocotb_test.py: verification of DMA_CALYPTE with RX and TX traffic at the same time
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""The UVM `base` and `speed` tests of RX and TX DMA Calypte, run together on the top level, plus a
check of the RQ merger that joins the RX data stream with the pointer-updater stream."""

import json
import os
import random

import cocotb
import cocotbext.ofm.mfb.fast_drivers
import ofm
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

from cocotbext.ofm.mfb.fast_drivers import MFBDriver
from cocotbext.ofm.mfb.fast_monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import MFBProperty, final_check_all
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.utils.math import log2ceil
from cocotbext.ofm.utils.random import named_rngs
from cocotbext.ofm.utils.signals import generic_bool, signal_binstr, signal_handshake, signal_int
from cocotbext.ofm.ver.scoreboard import MergeChecker, OrderedComparer, Report, UnorderedComparer

from checkers import BenchError, MvbProperty, RxStopInvariant, RxUpdateOrderChecker
from pcie_tlp import CQ_META_WIDTH, RQ_META_WIDTH, compare_rq, is_intel, parse_rq, pcie_requirement_errors
from ptr_upd_model import PtrUpdModel
from regs import COUNTERS, CH_STRIDE, RX_BASE, RX_MAP, TX_BASE, ChannelRegs, MiBus, tx_map
from rx_model import RxDmaModel
from rx_seq import RxChannelRun, RxPacketSource
from traffic import MfbIdleGen, drive_dst_rdy
from tx_host_driver import CqSender, TransactionBudget, TxChannelDriver, TxChannelSequence
from tx_model import TxDmaModel

CLK_NS = 4
INT_GENERICS = ("HDR_META_WIDTH", "RX_PTR_WIDTH", "TX_PTR_WIDTH", "USR_RX_PKT_SIZE_MAX", "USR_TX_PKT_SIZE_MAX",
                "USR_MFB_REGION_SIZE", "PCIE_RQ_MFB_REGIONS", "RX_CHANNELS", "TX_CHANNELS")


def _now():
    return int(get_sim_time("ns"))


def bench_generics(dut):
    """The generics the bench follows, read from the toplevel; a string generic comes as bytes."""
    cfg = {name: int(getattr(dut, name).value) for name in INT_GENERICS}
    cfg["TRBUF_REG_EN"] = generic_bool(dut.TRBUF_REG_EN)
    device = dut.DEVICE.value
    cfg["DEVICE"] = (device.decode() if isinstance(device, bytes) else str(device)).strip()
    return cfg


class CalypteBench:
    def __init__(self, dut, speed):
        self.dut = dut
        self.speed = speed
        self.cfg = bench_generics(dut)
        self.log = dut._log
        self.report = Report(self.log, int(os.environ.get("CALYPTE_MAX_ERRORS", "1")))
        self.clk = dut.CLK
        c = self.cfg
        self.device = c["DEVICE"]
        self.intel = is_intel(self.device)
        self.rx_ch, self.tx_ch = c["RX_CHANNELS"], c["TX_CHANNELS"]
        self.regions = c["PCIE_RQ_MFB_REGIONS"]
        self.rx_chw = log2ceil(self.rx_ch)
        self.tx_chw = log2ceil(self.tx_ch)
        self._check_elaboration()
        self.rngs = named_rngs("rst", "rx_pkt", "rx_gap", "cq_gap", "rq_rdy", "tx_rdy", "tx_budget")
        self.cycles = 0
        self.in_reset = True
        # Extra consumers of every PCIE_RQ_MFB frame, called with the frame and its sampling time.
        self.rq_out_hooks = []

    def _check_elaboration(self):
        """The port widths must follow the generics, else every check would use wrong geometry."""
        d, c = self.dut, self.cfg
        exp = {"USR_RX_MFB_META": self.rx_chw + c["HDR_META_WIDTH"],
               "USR_TX_MFB_META": (c["USR_TX_PKT_SIZE_MAX"]).bit_length() + self.tx_chw + c["HDR_META_WIDTH"],
               "USR_RX_MFB_DATA": c["USR_MFB_REGION_SIZE"] * 64,
               "PCIE_RQ_MFB_SOF": self.regions, "PCIE_CQ_MFB_SOF": self.regions}
        for name, width in exp.items():
            got = len(getattr(d, name))
            assert got == width, f"{name} is {got} bits, the generics give {width}"

    # ------------------------------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------------------------------
    def build(self):
        d, c, clk = self.dut, self.cfg, self.clk
        usr_geom = {"regions": 1, "region_size": c["USR_MFB_REGION_SIZE"], "block_size": 8, "item_width": 8}
        pcie_geom = {"regions": self.regions, "region_size": 1, "block_size": 8, "item_width": 32}
        self.usr_rx_params = dict(usr_geom, meta_width=self.rx_chw + 24)
        self.usr_tx_params = dict(usr_geom, meta_width=13 + self.tx_chw + 24)
        self.cq_params = dict(pcie_geom, meta_width=CQ_META_WIDTH)
        self.rq_params = dict(pcie_geom, meta_width=RQ_META_WIDTH)
        top = d.dma_calypte_i
        self.rx_dma_i = top.rx_dma_calypte_g.rx_dma_calypte_i
        self.hdrm = self.rx_dma_i.rx_dma_hdr_manager_i
        self.swm = self.rx_dma_i.rx_dma_sw_manager_i
        self.st_sp_i = top.tx_dma_calypte_g.tx_dma_calypte_i.tx_dma_chan_start_stop_ctrl_i

        # Inputs idle until the agents start.
        d.PCIE_RQ_MFB_DST_RDY.value = 0
        d.USR_TX_MFB_DST_RDY.value = 0
        d.RESET.value = 1

        self.mi = MiBus(d, clk)
        self.rx_regs = [ChannelRegs(self.mi, RX_BASE + ch * CH_STRIDE, RX_MAP) for ch in range(self.rx_ch)]
        tmap = tx_map(c["TX_PTR_WIDTH"])
        self.tx_regs = [ChannelRegs(self.mi, TX_BASE + ch * CH_STRIDE, tmap) for ch in range(self.tx_ch)]

        rx_gap = None if self.speed else MfbIdleGen(self.rngs["rx_gap"], c["USR_MFB_REGION_SIZE"])
        cq_gap = None if self.speed else MfbIdleGen(self.rngs["cq_gap"], self.regions)
        self.usr_rx_drv = MFBDriver(d, "USR_RX_MFB", clk, mfb_params=self.usr_rx_params, vld_gen=rx_gap)
        self.cq_drv = MFBDriver(d, "PCIE_CQ_MFB", clk, mfb_params=self.cq_params, vld_gen=cq_gap)

        # Scoreboards
        self.rx_cmp = OrderedComparer("RX DMA RQ", compare_rq, lambda t: t.describe(), self.report,
                                      dut_may_lead=True)
        self.ptr_cmp = UnorderedComparer("pointer update RQ", compare_rq, lambda t: t.describe(), self.report,
                                         dut_may_lead=False)
        self.tx_data_cmp = OrderedComparer("USR_TX data", self._cmp_bytes, self._desc_bytes, self.report,
                                           dut_may_lead=False)
        self.tx_meta_cmp = OrderedComparer("USR_TX meta", self._cmp_int, lambda m: f"{m[0]:#x} {m[1]}",
                                           self.report, dut_may_lead=False)
        self.merger = MergeChecker(self.report, ("RX DMA", "pointer updater"), "PCIE_RQ merger",
                                   lambda f: f"{len(f[0])} B, META {f[1]:#x}")
        self.rx_stop_inv = RxStopInvariant(self.swm, self.rx_ch, self.report)
        self.rx_upd_order = RxUpdateOrderChecker(self.rx_regs, self.report, self.device, top, self.rx_dma_i, CLK_NS)
        self.rx_stop_inv.ack_hooks.append(lambda ch, now: self.rx_upd_order.stopped(ch, now // CLK_NS))

        # Models
        self.rx_model = RxDmaModel(self.rx_ch, self.rx_regs, self.rx_cmp.add_model)
        self.tx_model = TxDmaModel(self.device, self.tx_ch, c["TX_PTR_WIDTH"], self.report, self._tx_expect)
        self.ptr_model = PtrUpdModel(c["RX_PTR_WIDTH"], self.tx_ch, c["TX_PTR_WIDTH"], c["USR_TX_PKT_SIZE_MAX"] // 2,
                                     self.tx_regs, self.ptr_cmp.add_model)

        # Monitors, sampled by one task per cycle (their own tasks are killed).
        def mon(entity, name, params, cb):
            m = MFBMonitor(entity, name, clk, mfb_params=params, trans_type=MfbTransactionWithMeta, start=False)
            m.add_callback(cb)
            return m

        self.monitors = [
            mon(d, "USR_RX_MFB", self.usr_rx_params, lambda t: self.rx_model.add_packet(t.data, t.meta, _now())),
            mon(d, "PCIE_CQ_MFB", self.cq_params, lambda t: self.tx_model.add_tlp(t.data, t.meta)),
            mon(top, "rx_dma_rq_mfb", self.rq_params, self._on_rx_dma_rq),
            mon(top, "ptr_upd_rq_mfb", self.rq_params, self._on_ptr_upd_rq),
            mon(d, "PCIE_RQ_MFB", self.rq_params, self._on_rq_out),
            mon(d, "USR_TX_MFB", self.usr_tx_params, self._on_usr_tx),
        ]

        # MFB conformance on every MFB interface of the top level and on both merger inputs. The RQ interfaces follow
        # uvm_common/pcie_rq_mfb_property.sv: no gap in a frame and, with REGIONS > 1, a SOF in a region after an EOF in
        # the region before (AMD) or only in region 0 (Intel).
        straddle = (not self.intel) if self.regions > 1 else None
        self.mfb_props = {
            "USR_RX_MFB": MFBProperty(d, "USR_RX_MFB", clk, reset=d.RESET, mfb_params=self.usr_rx_params,
                                      start=False),
            "USR_TX_MFB": MFBProperty(d, "USR_TX_MFB", clk, reset=d.RESET, mfb_params=self.usr_tx_params,
                                      start=False),
            # The CQ stimulus may open a frame in region 1 behind an idle region 0, as the UVM CQ
            # sequences do (endpoint_type NORMAL), so the straddling rule is not imposed on it.
            "PCIE_CQ_MFB": MFBProperty(d, "PCIE_CQ_MFB", clk, reset=d.RESET, mfb_params=self.cq_params,
                                       start=False),
            "PCIE_RQ_MFB": MFBProperty(d, "PCIE_RQ_MFB", clk, reset=d.RESET, mfb_params=self.rq_params,
                                       straddling=straddle, no_gap_in_frame=True, start=False),
            "rx_dma_rq_mfb": MFBProperty(top, "rx_dma_rq_mfb", clk, reset=d.RESET, mfb_params=self.rq_params,
                                         straddling=straddle, no_gap_in_frame=True, start=False),
            "ptr_upd_rq_mfb": MFBProperty(top, "ptr_upd_rq_mfb", clk, reset=d.RESET, mfb_params=self.rq_params,
                                          straddling=straddle, no_gap_in_frame=True, start=False),
        }
        self.mvb_props = [
            MvbProperty("RX stop request", top.rx_stop_req_en, top.rx_stop_req_ack,
                        [("BUFF_BA", top.rx_stop_req_buff_ba), ("P2P_EN", top.rx_stop_req_p2p_en),
                         ("HDP", top.rx_stop_req_hdp), ("HHP", top.rx_stop_req_hhp)], self.report),
            MvbProperty("TX stop request", top.tx_stop_req_en, top.tx_stop_req_ack,
                        [("BUFF_BA", top.tx_stop_req_buff_ba), ("P2P_EN", top.tx_stop_req_p2p_en),
                         ("HDP", top.tx_stop_req_hdp), ("HHP", top.tx_stop_req_hhp)], self.report),
            MvbProperty("TX start request", top.tx_start_req_vld, top.tx_start_req_ack,
                        [("CH", top.tx_start_req_ch)], self.report),
            MvbProperty("TX runtime update", top.tx_pkt_disp_upd_en, None,
                        [("CH", top.tx_pkt_disp_upd_ch), ("HDP", top.tx_pkt_disp_upd_hdp),
                         ("HHP", top.tx_pkt_disp_upd_hhp)], self.report),
        ]

        # Host side of TX
        self.cq_sender = CqSender(self.cq_drv, clk)
        tx_rng = self.rngs["tx_budget"]
        tmin = int(os.environ.get("TX_TRANSACTIONS_MIN", "900"))
        tmax = int(os.environ.get("TX_TRANSACTIONS_MAX", "2100"))
        self.budget = TransactionBudget(tx_rng.randint(tmin, tmax))
        self.tx_drivers, self.tx_seqs = [], []
        for ch in range(self.tx_ch):
            drv = TxChannelDriver(ch, c, self.tx_regs[ch], self.cq_sender, random.Random(tx_rng.getrandbits(64)),
                                  self.report)
            self.tx_drivers.append(drv)
            self.tx_seqs.append(TxChannelSequence(ch, self.tx_regs[ch], drv, self.budget,
                                                  random.Random(tx_rng.getrandbits(64)),
                                                  c["USR_TX_PKT_SIZE_MAX"], self.log))
        rx_rng = self.rngs["rx_pkt"]
        self.rx_source = RxPacketSource(self.usr_rx_drv, clk, self.rx_ch, c["USR_RX_PKT_SIZE_MAX"],
                                        random.Random(rx_rng.getrandbits(64)), self.log)
        self.rx_runs = [RxChannelRun(ch, self.rx_regs[ch], random.Random(rx_rng.getrandbits(64)), self.log)
                        for ch in range(self.rx_ch)]
        self.log.info(f"{self.device}, RX {self.rx_ch} ch, TX {self.tx_ch} ch, "
                      f"{self.regions} PCIe region(s), USR MFB (1,{c['USR_MFB_REGION_SIZE']},8,8), "
                      f"TRBUF_REG_EN {c['TRBUF_REG_EN']}, {'speed' if self.speed else 'base'} test, "
                      f"TX budget {self.budget.transactions} packets, RX until {self.rx_source.sim_time_ps // 10**6} us")

    # ------------------------------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------------------------------
    @staticmethod
    def _cmp_bytes(model, dut):
        if model[0] == dut[0]:
            return []
        if len(model[0]) != len(dut[0]):
            return [f"length model {len(model[0])} dut {len(dut[0])}"]
        diff = [i for i, (a, b) in enumerate(zip(model[0], dut[0])) if a != b]
        runs, start = [], diff[0]
        for prev, cur in zip(diff, diff[1:] + [None]):
            if cur != prev + 1:
                runs.append(f"{start}..{prev}")
                start = cur
        return [f"{len(diff)} byte(s) differ in ranges {', '.join(runs[:8])}{' ...' if len(runs) > 8 else ''}; "
                f"first at {diff[0]}: model {model[0][diff[0]]:#04x} dut {dut[0][diff[0]]:#04x}"]

    @staticmethod
    def _cmp_int(model, dut):
        return [] if model[0] == dut[0] else [f"model {model[0]:#x} dut {dut[0]:#x}"]

    @staticmethod
    def _desc_bytes(item):
        return f"{len(item[0])} B {item[0][:16].hex()}... {item[1]}"

    def _tx_expect(self, data, meta, info):
        self.tx_data_cmp.add_model((data, info))
        self.tx_meta_cmp.add_model((meta, info))

    def _parse_dut_rq(self, t, what):
        tlp, errs = parse_rq(t.data, t.meta, self.device)
        if tlp is None:
            self.report(f"{what}: malformed TLP at {_now()} ns: {'; '.join(errs)}")
            return None
        errs += pcie_requirement_errors(tlp)
        if errs:
            self.report(f"{what}: TLP at {_now()} ns violates the encoding: {'; '.join(errs)}\n  {tlp.describe()}")
        return tlp

    def _on_rx_dma_rq(self, t):
        self.merger.add_in(0, (t.data, t.meta))
        tlp = self._parse_dut_rq(t, "RX DMA RQ")
        if tlp is not None:
            self.rx_cmp.add_dut(tlp, _now())

    def _on_ptr_upd_rq(self, t):
        self.merger.add_in(1, (t.data, t.meta))
        tlp = self._parse_dut_rq(t, "pointer update RQ")
        if tlp is not None:
            self.ptr_cmp.add_dut(tlp, _now())

    def _on_rq_out(self, t):
        now = _now()
        hit = self.merger.add_out((t.data, t.meta), f"{now} ns")
        src = None if hit is None else hit[0]
        tlp, _ = parse_rq(t.data, t.meta, self.device)
        if tlp is not None:
            self.rx_upd_order.rq_frame(src, tlp, now)
        for hook in self.rq_out_hooks:
            hook(t, now)

    def _on_usr_tx(self, t):
        now = _now()
        self.tx_data_cmp.add_dut((t.data, f"DUT at {now} ns"), now)
        self.tx_meta_cmp.add_dut((t.meta, f"DUT at {now} ns"), now)

    # ------------------------------------------------------------------------------------------
    # Per-cycle sampling of monitors, probes and properties
    # ------------------------------------------------------------------------------------------
    def _probes(self):
        rx, st, top = self.rx_dma_i, self.st_sp_i, self.dut.dma_calypte_i
        if signal_handshake(rx.hdrm_dma_hdr_src_rdy, rx.hdrm_dma_hdr_dst_rdy):
            self.rx_model.add_drop(signal_int(rx.hdrm_pkt_drop))
        if signal_handshake(st.PCIE_MFB_SRC_RDY, st.PCIE_MFB_DST_RDY):
            sof = signal_int(st.PCIE_MFB_SOF)
            if sof:
                drop = signal_int(st.pkt_drop_en)
                for r in range(self.regions):
                    if (sof >> r) & 1:
                        self.tx_model.add_drop((drop >> r) & 1)
        if signal_handshake(top.rx_stop_req_en, top.rx_stop_req_ack):
            self.ptr_model.rx_stop(signal_int(top.rx_stop_req_buff_ba), signal_int(top.rx_stop_req_p2p_en),
                                   signal_int(top.rx_stop_req_hdp), signal_int(top.rx_stop_req_hhp))
            self.rx_upd_order.dispatched(signal_int(top.rx_stop_req_buff_ba), signal_int(self.swm.stop_fsm_channel_reg),
                                         signal_int(top.rx_stop_req_p2p_en))
        if signal_binstr(self.swm.START_REQ_VLD) == "1":
            self.rx_upd_order.started(signal_int(self.swm.START_REQ_CHAN))
        # The address managers' outputs: a block or DMA header got its address (the pointer registers may follow
        # later, once its write has left).
        dm, hm = self.hdrm.data_pcie_addr_mgr_i, self.hdrm.dma_hdr_pcie_addr_mgr_i
        for kind, en, chan, data in (("data", dm.POINTER_UPDATE_EN, dm.POINTER_UPDATE_CHAN, dm.POINTER_UPDATE_DATA),
                                     ("hdr", hm.POINTER_UPDATE_EN, hm.POINTER_UPDATE_CHAN, hm.POINTER_UPDATE_DATA)):
            if signal_binstr(en) == "1":
                self.rx_upd_order.served(kind, signal_int(chan), signal_int(data), _now() // CLK_NS)
        self.rx_upd_order.path_cycle(_now() // CLK_NS)
        start = rt = stop = None
        if signal_handshake(top.tx_start_req_vld, top.tx_start_req_ack):
            start = signal_int(top.tx_start_req_ch)
        if signal_binstr(top.tx_pkt_disp_upd_en) == "1":
            rt = (signal_int(top.tx_pkt_disp_upd_ch), signal_int(top.tx_pkt_disp_upd_hdp), signal_int(top.tx_pkt_disp_upd_hhp))
        if signal_handshake(top.tx_stop_req_en, top.tx_stop_req_ack):
            stop = (signal_int(top.tx_stop_req_buff_ba), signal_int(top.tx_stop_req_p2p_en), signal_int(top.tx_stop_req_hdp),
                    signal_int(top.tx_stop_req_hhp))
        if start is not None or rt is not None or stop is not None:
            self.ptr_model.tx_cycle(start, rt, stop)

    async def sampler(self):
        edge = RisingEdge(self.clk)
        props = list(self.mfb_props.values())
        while True:
            await edge
            await ReadOnly()
            self.cycles += 1
            now = _now()
            self.in_reset = signal_binstr(self.dut.RESET) != "0"
            if not self.in_reset:
                for m in self.monitors:
                    m.monitor_cycle()
                self._probes()
            for p in props:
                p.check_cycle()
            for p in self.mvb_props:
                p.cycle(self.in_reset, now)
            self.rx_cmp.tick(now)
            self.ptr_cmp.tick(now)
            self.tx_data_cmp.tick(now)
            self.tx_meta_cmp.tick(now)

    async def mid_sampler(self):
        """Samples the RX SW manager mid-cycle: its stop comparators are DSP48 models whose outputs settle
        100 ps after the edge, so stop_ptr_ok and stop_acked are not yet valid at the edge's ReadOnly."""
        edge = FallingEdge(self.clk)
        while True:
            await edge
            await ReadOnly()
            if signal_binstr(self.dut.RESET) != "0":
                continue
            now = _now()
            self.rx_stop_inv.cycle(now // CLK_NS, now)

    # ------------------------------------------------------------------------------------------
    # Test flow
    # ------------------------------------------------------------------------------------------
    def used(self):
        return (self.rx_source.used() or self.rx_model.used() or self.rx_cmp.used() or self.ptr_cmp.used()
                or self.tx_model.used() or self.tx_data_cmp.used() or self.tx_meta_cmp.used()
                or self.cq_sender.used() or self.merger.used())

    async def progress(self):
        period = int(os.environ.get("CALYPTE_PROGRESS_US", "250"))
        while True:
            await Timer(period, "us")
            self.log.info(f"progress: RX in {self.rx_source.sent} pkts, RQ TLPs compared {self.rx_cmp.compared}, "
                          f"TX budget used {min(self.budget.count, self.budget.transactions)}/"
                          f"{self.budget.transactions}, USR_TX compared {self.tx_data_cmp.compared}, pointer "
                          f"updates compared {self.ptr_cmp.compared}, MI accesses {self.mi.accesses}")

    async def reset(self):
        await RisingEdge(self.clk)
        self.dut.RESET.value = 1
        await ClockCycles(self.clk, self.rngs["rst"].randint(7, 30))
        self.dut.RESET.value = 0

    async def tx_channel(self, ch):
        await Timer(200, "ns")
        await self.tx_seqs[ch].run()
        self.log.info(f"TX ch{ch}: main packet sequence done ({self.tx_seqs[ch].packets} packets, "
                      f"{self.tx_seqs[ch].starts} starts, {self.tx_seqs[ch].stops} stops)")

    async def tx_driver_init(self):
        while self.in_reset:
            await RisingEdge(self.clk)
        for drv in self.tx_drivers:
            await drv.init_after_reset()

    async def rx_regs_start(self):
        await Timer(200, "ns")
        return [cocotb.start_soon(run.run()) for run in self.rx_runs]

    async def read_counters(self, regs):
        out = []
        for r in regs:
            vals = {}
            for name in COUNTERS:
                await r.write_words(name, 1, 1)
                vals[name] = await r.read(name)
            out.append(vals)
        return out

    def counter_table(self, title, model, dut):
        lines = [f"{title} counters (model / DUT)",
                 "  ch | sent pkts         | sent bytes            | discarded pkts    | discarded bytes"]
        bad = []
        for ch, vals in enumerate(dut):
            exp = {"sent_pkts": model.sent_pkts[ch], "sent_bytes": model.sent_bytes[ch],
                   "disc_pkts": model.disc_pkts[ch], "disc_bytes": model.disc_bytes[ch]}
            cells = []
            for name in COUNTERS:
                mark = "" if exp[name] == vals[name] else " !"
                cells.append(f"{exp[name]:>8} / {vals[name]:<8}{mark}")
                if exp[name] != vals[name]:
                    bad.append(f"{title} ch{ch} {name}: model {exp[name]} DUT {vals[name]}")
            lines.append(f"  {ch:2} | " + " | ".join(cells))
        self.log.info("\n".join(lines))
        return bad

    async def bring_up(self):
        """Builds the bench, starts the clock, the sampler and the output DST_RDY drivers, and resets."""
        self.build()
        self.log.info(f"cocotbext.ofm imported from {cocotbext.ofm.mfb.fast_drivers.__file__}")
        self.log.info(f"ofm imported from {ofm.__file__}")
        cocotb.start_soon(Clock(self.clk, CLK_NS, "ns", impl="gpi").start())
        cocotb.start_soon(self.sampler())
        cocotb.start_soon(self.mid_sampler())
        cocotb.start_soon(self.progress())
        cocotb.start_soon(drive_dst_rdy(self.dut.PCIE_RQ_MFB_DST_RDY, self.clk, self.rngs["rq_rdy"], self.speed))
        cocotb.start_soon(drive_dst_rdy(self.dut.USR_TX_MFB_DST_RDY, self.clk, self.rngs["tx_rdy"], self.speed))
        await self.reset()
        await self.clear_counters()

    async def clear_counters(self):
        """The counters are memories that RESET leaves as they are, so a test after another one in the same simulation
        clears them, as a write of 0 to a counter register of a channel does."""
        for regs in self.rx_regs + self.tx_regs:
            await regs.write_words("sent_pkts", 0, 0)

    async def run(self):
        await self.bring_up()
        cocotb.start_soon(self.tx_driver_init())
        await self.rx_regs_start()
        rx_src = cocotb.start_soon(self.rx_source.run())
        tx = [cocotb.start_soon(self.tx_channel(ch)) for ch in range(self.tx_ch)]

        await rx_src
        for t in tx:
            await t
        end_time = _now()
        self.log.info(f"stimulus finished at {end_time} ns")
        await Timer(2, "us")
        while end_time + 200_000 > _now() and self.used():
            await Timer(600, "ns")

        # The RX register sequences run forever in UVM; here they park and their channels are stopped, as the ndp
        # tools end a run, so the counters are read once nothing can enter a channel or move its pointers.
        for run in self.rx_runs:
            run.halt = True
        deadline = _now() + 500_000
        while not all(run.parked for run in self.rx_runs) and _now() < deadline:
            await Timer(1, "us")
        for run in self.rx_runs:
            if run.parked:
                await run.stop_if_running()
        deadline = _now() + 20_000
        while (self.ptr_cmp.used() or self.merger.used()) and _now() < deadline:
            await Timer(100, "ns")
        await Timer(1, "us")

        rx_cnt = await self.read_counters(self.rx_regs)
        tx_cnt = await self.read_counters(self.tx_regs)

        problems = [f"{len(self.report.errors)} error(s) reported during the run, first: {self.report.errors[0]}"
                    ] if self.report.errors else []
        for run in self.rx_runs:
            if not run.parked:
                problems.append(f"RX ch{run.ch} register sequence did not park within 500 us: {run.state} since "
                                f"{run.state_since} ns")
        problems += self.end_checks(rx_cnt, tx_cnt)

        self.log.info(
            f"summary: sim_time={_now()} ns cycles={self.cycles} | RX in {self.rx_source.sent} pkts "
            f"{self.rx_source.sent_bytes} B, model processed {self.rx_model.processed}, RQ TLPs compared "
            f"{self.rx_cmp.compared} | TX budget {self.budget.transactions}, CQ writes {self.cq_sender.sent}, "
            f"USR_TX packets compared {self.tx_data_cmp.compared} | pointer updates compared "
            f"{self.ptr_cmp.compared} {self.ptr_model.counts} | merger frames {self.merger.out_frames} | "
            f"RX starts/stops {sum(r.starts for r in self.rx_runs)}/{sum(r.stops for r in self.rx_runs)}, "
            f"TX starts/stops {sum(s.starts for s in self.tx_seqs)}/{sum(s.stops for s in self.tx_seqs)} | "
            f"MI accesses {self.mi.accesses} | {self.rx_ptr_stats()}")
        if problems:
            for p in problems:
                self.log.error(p)
            raise BenchError(f"{len(problems)} end-of-test check(s) failed, first: {problems[0]}")

    def rx_ptr_stats(self):
        return (f"{self.rx_stop_inv.stats()} | {self.rx_upd_order.stats()} | RQ ordering classes "
                f"{json.dumps(self.rx_upd_order.class_stats())}")

    def end_checks(self, rx_cnt, tx_cnt):
        """Counters, scoreboard and model leftovers, open frames and the MFB rules at the end of a test."""
        problems = self.counter_table("RX", self.rx_model, rx_cnt)
        problems += self.counter_table("TX", self.tx_model, tx_cnt)
        for c in (self.rx_cmp, self.ptr_cmp, self.tx_data_cmp, self.tx_meta_cmp):
            problems += c.leftovers()
        problems += self.merger.leftovers()
        problems += self.rx_upd_order.leftovers()
        if self.rx_model.used():
            problems.append(f"RX model: {len(self.rx_model.packets)} packet(s) and {len(self.rx_model.drops)} "
                            f"drop decision(s) left unpaired")
        if self.tx_model.used():
            problems.append(f"TX model: {len(self.tx_model.tlps)} CQ write(s) and {len(self.tx_model.drops)} "
                            f"drop flag(s) left unpaired")
        try:
            final_check_all(self.mfb_props)
        except AssertionError as exc:
            problems.append(str(exc))
        except Exception as exc:  # MFBProtocolError
            problems.append(str(exc))
        return problems


@cocotb.test()
async def run_dma_calypte_test(dut):
    """UVM `base` of RX and TX together: gapped inputs, random DST_RDY on PCIE_RQ and USR_TX."""
    await CalypteBench(dut, speed=False).run()


@cocotb.test()
async def run_dma_calypte_speed_test(dut):
    """UVM `speed` of RX and TX together: no input gaps, DST_RDY constantly 1 on every output."""
    await CalypteBench(dut, speed=True).run()
