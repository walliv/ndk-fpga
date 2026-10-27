# checkers.py: scoreboards and bus properties of the DMA_CALYPTE bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque

from cocotbext.ofm.utils.signals import binstr_bit, binstr_resolved, signal_binstr, signal_handshake, signal_int
from cocotbext.ofm.ver.scoreboard import ReportError

from pcie_tlp import is_intel, rq_hdr_address

# Every failure of the bench, a reported error or a failed end check, raises this.
BenchError = ReportError


class MvbProperty:
    """Port of comp/uvm/mvb/mvb_property.sv for one-item interfaces whose VLD is constant 1:
    SRC_RDY defined, $rose(SRC_RDY) |-> (SRC_RDY until DST_RDY), no X on DATA while SRC_RDY."""

    def __init__(self, label, src, dst, data, report):
        self.label = label
        self.src = src
        self.dst = dst
        self.data = data
        self.report = report
        self.prev_src = False
        self.pending = False
        self.started = False

    def cycle(self, in_reset, now):
        if in_reset or not self.started:
            self.started = not in_reset
            self.prev_src = False
            self.pending = False
            return
        sv = signal_binstr(self.src)
        if sv not in ("0", "1"):
            self.report(f"{self.label}: SRC_RDY undefined ({sv}) at {now} ns")
            return
        src = sv == "1"
        dst = self.dst is None or signal_binstr(self.dst) == "1"
        if self.pending or (src and not self.prev_src):
            if dst:
                self.pending = False
            elif not src:
                self.report(f"{self.label}: SRC_RDY dropped before DST_RDY at {now} ns")
                self.pending = False
            else:
                self.pending = True
        self.prev_src = src
        if src:
            for name, handle in self.data:
                val = signal_binstr(handle)
                if not binstr_resolved(val):
                    self.report(f"{self.label}: {name} undefined while SRC_RDY ({val}) at {now} ns")


class RxStopInvariant:
    """At every RX stop ack the channel's R_HDP/R_HHP equal its R_SDP/R_SHP (read at the stop comparators'
    inputs) and stay unwritten until its next start request. Also times the last pointer write to the dispatch."""

    NEAR_CYCLES = 16

    def __init__(self, swm, channels, report):
        self.swm = swm
        self.report = report
        self.cmps = (("HDP", "SDP", swm.dsp_comp_hdp_i), ("HHP", "SHP", swm.dsp_comp_hhp_i))
        self.writes = (("HDP", swm.HDP_WR_EN, swm.HDP_WR_CHAN), ("HHP", swm.HHP_WR_EN, swm.HHP_WR_CHAN))
        self.stopped = [None] * channels
        self.last_write = [None] * channels
        self.stop_req = None
        self.dispatch = None
        self.acked = 0
        self.near = 0
        self.margins = []
        # Called with (channel, time in ns) at every acknowledged stop.
        self.ack_hooks = []

    def cycle(self, cycle, now):
        sw = self.swm
        for what, en, chan in self.writes:
            if signal_binstr(en) == "1":
                c = signal_int(chan)
                if self.stopped[c] is not None:
                    self.report(f"RX ch{c}: {what} written at {now} ns, {cycle - self.stopped[c]} cycle(s) after "
                                f"its stop was acknowledged and before its next start request")
                self.last_write[c] = cycle
        if signal_binstr(sw.STOP_REQ_VLD) == "1":
            self.stop_req = cycle
            self.dispatch = None
        if self.dispatch is None and signal_handshake(sw.PTR_UPD_DISP_EN, sw.PTR_UPD_DISP_ACK):
            self.dispatch = cycle
        if signal_binstr(sw.stop_acked) == "1":
            c = signal_int(sw.stop_fsm_channel_reg)
            self.acked += 1
            for hw, swp, cmp in self.cmps:
                hw_val, sw_val = signal_int(cmp.INPUT_1), signal_int(cmp.INPUT_2)
                if hw_val != sw_val:
                    self.report(f"RX ch{c}: stop acknowledged at {now} ns with R_{hw} {hw_val} != R_{swp} {sw_val}")
            last = self.last_write[c]
            if last is not None and cycle - last <= self.NEAR_CYCLES:
                self.near += 1
            if last is not None and self.stop_req is not None and last >= self.stop_req and self.dispatch is not None:
                self.margins.append(self.dispatch - last)
            self.stopped[c] = cycle
            for hook in self.ack_hooks:
                hook(c, now)
        if signal_binstr(sw.START_REQ_VLD) == "1":
            self.stopped[signal_int(sw.START_REQ_CHAN)] = None

    def stats(self):
        # A write lands at the end of its cycle: a dispatch read in that cycle or earlier sends stale pointers.
        margin = min(self.margins) if self.margins else None
        stale = sum(1 for m in self.margins if m <= 0)
        return (f"RX stops acked {self.acked}, within {self.NEAR_CYCLES} cycles of a pointer write {self.near}, "
                f"last pointer write to dispatch read min {margin} cycles over {len(self.margins)} stops, "
                f"{stale} dispatch(es) read before the last write")


class RxUpdateOrderChecker:
    """An RX pointer update on PCIE_RQ may only cover blocks and DMA headers of its channel whose RQ writes left
    before it. The header manager's HDP/HHP updates name each served one in order, as its writes must leave."""

    BLOCK_BYTES = {"data": 128, "hdr": 8}
    ADDR_MASK = (1 << 64) - 1
    # Where a served write is on its way to PCIE_RQ (statistics only). The header insertor pops a PCIe header at its
    # TLP's last beat, so before the first beat the header is either the head of the header manager's FIFO or queued.
    STAGES = {"head": "c: header insertor, TLP not started (its header heads the header manager FIFO)",
              "queued": "c: header manager FIFO, behind other headers", "rqout": "b: RX DMA RQ output, not accepted",
              "mrg": "a: merger input 0 or behind"}
    OTHER = "d: other"

    def __init__(self, regs, report, device=None, top=None, rx=None, clk_ns=4):
        self.regs = regs
        self.report = report
        self.pending = {kind: [deque() for _ in regs] for kind in self.BLOCK_BYTES}
        self.dispatches = deque()
        self.writes = 0
        self.updates = 0
        self.updates_behind = 0
        self.device = device
        self.top = top
        self.rx = rx
        self.clk_ns = clk_ns
        # Furthest stage per pending write address, with the cycle it was served.
        self.stage = {}
        self.served_at = {}
        # Per RX update address, the stages of its channel's pending writes when it entered merger input 1.
        self.snapshots = {}
        # Writes classified, waiting to leave PCIE_RQ: address -> [record, ...].
        self.awaiting = {}
        self.violations = []
        self.stop_records = []
        self.stops_clean = 0
        # Per channel, the number of start requests seen: a stop update belongs to the episode it was dispatched in.
        self.epoch = [0] * len(regs)
        self.acked_at = {}
        self.late_updates = 0
        self.late_max = 0

    def started(self, ch):
        self.epoch[ch] += 1

    def served(self, kind, ch, ptr, cycle=None):
        r = self.regs[ch]
        if kind == "data":
            base, mask = r.get("data_base"), r.get("data_mask")
        else:
            base, mask = r.get("hdr_base"), r.get("hdr_mask")
        addr = (base + ((ptr - 1) & mask) * self.BLOCK_BYTES[kind]) & self.ADDR_MASK
        self.pending[kind][ch].append((addr, ptr, self.epoch[ch]))
        self.stage.setdefault(addr, "rx")
        self.served_at[addr] = cycle

    def dispatched(self, buff_ba, ch, p2p):
        self.dispatches.append((buff_ba, ch, p2p, self.epoch[ch]))

    # ------------------------------------------------------------------------------------------
    # Path statistics
    # ------------------------------------------------------------------------------------------
    def _sof_addrs(self, prefix):
        """Header addresses of the frames starting in this cycle's word of an RQ stream of the top level."""
        sof = signal_binstr(getattr(self.top, f"{prefix}_sof"))
        regions = len(sof)
        if "1" not in sof:
            return []
        src = getattr(self.top, f"{prefix}_meta" if is_intel(self.device) else f"{prefix}_data")
        bits = signal_binstr(src)
        width = len(bits) // regions
        out = []
        # Only the header of a region with a SOF is decoded: a region without one may hold undefined bits.
        for r in range(regions):
            if binstr_bit(sof, r):
                hdr = bits[len(bits) - r * width - 128:len(bits) - r * width]
                if not binstr_resolved(hdr):
                    self.report(f"{prefix}: undefined PCIe header bits in region {r} at a SOF: {hdr}")
                    continue
                out.append(rq_hdr_address(int(hdr, 2), self.device))
        return out

    def _where(self, addr, around):
        st = self.stage.get(addr)
        if st is None:
            return self.OTHER
        if st == "mrg":
            return self.STAGES["mrg"]
        presented, heads = around
        if addr in presented:
            return self.STAGES["rqout"]
        return self.STAGES["head" if addr in heads else "queued"]

    def _around(self):
        """First beats waiting at the RX DMA RQ output and the PCIe headers heading the header manager's FIFOs."""
        top, rx = self.top, self.rx
        presented = set()
        if signal_binstr(top.rx_dma_rq_mfb_src_rdy) == "1" and signal_binstr(top.rx_dma_rq_mfb_dst_rdy) != "1":
            presented = set(self._sof_addrs("rx_dma_rq_mfb"))
        heads = {rq_hdr_address(signal_int(hdr), self.device)
                 for hdr, src in ((rx.hdrm_data_pcie_hdr, rx.hdrm_data_pcie_hdr_src_rdy),
                                  (rx.hdrm_dma_pcie_hdr, rx.hdrm_dma_pcie_hdr_src_rdy))
                 if signal_binstr(src) == "1"}
        return presented, heads

    def path_cycle(self, cycle):
        """Marks pending writes whose first beat entered merger input 0 and snapshots, at every RX pointer update
        entering merger input 1, where its channel's pending writes are."""
        top = self.top
        if signal_handshake(top.rx_dma_rq_mfb_src_rdy, top.rx_dma_rq_mfb_dst_rdy):
            for addr in self._sof_addrs("rx_dma_rq_mfb"):
                self.stage[addr] = "mrg"
        if self.dispatches and signal_handshake(top.ptr_upd_rq_mfb_src_rdy, top.ptr_upd_rq_mfb_dst_rdy):
            for addr in self._sof_addrs("ptr_upd_rq_mfb"):
                disp = next((d for d in self.dispatches if d[0] == addr), None)
                if disp is None:
                    continue
                ch = disp[1]
                around = self._around()
                snap = {a: self._where(a, around) for kind in self.BLOCK_BYTES for a, _, _ in self.pending[kind][ch]}
                self.snapshots.setdefault(addr, deque()).append((cycle, snap))

    def stopped(self, ch, cycle):
        """At R_STATUS becoming stopped: where the channel's last served write is, if it has not left yet."""
        heads = [q[-1][0] for q in (self.pending["data"][ch], self.pending["hdr"][ch]) if q]
        self.acked_at[(ch, self.epoch[ch])] = cycle
        if not heads:
            self.stops_clean += 1
            return
        last = max(heads, key=lambda a: self.served_at.get(a) or 0)
        rec = {"kind": "stopped", "ch": ch, "addr": last, "cls": self._where(last, self._around()), "at": cycle,
               "lag": None}
        self.stop_records.append(rec)
        self.awaiting.setdefault(last, []).append(rec)

    def _left(self, addr, cycle):
        self.stage.pop(addr, None)
        self.served_at.pop(addr, None)
        for rec in self.awaiting.pop(addr, []):
            rec["lag"] = cycle - rec["at"]
            self.report.log.info(f"RQ path record: {rec['kind']} RX ch{rec['ch']} write {addr:#x} was in {rec['cls']}, "
                                 f"left {rec['lag']} cycles ({rec['lag'] * self.clk_ns} ns) after the "
                                 f"{'pointer update' if rec['kind'] == 'update' else 'channel reported stopped'}")

    # ------------------------------------------------------------------------------------------
    def rq_frame(self, src, tlp, now):
        addr = tlp.byte_address()
        cycle = now // self.clk_ns
        if src == 0:
            head = next(((kind, ch) for kind, qs in self.pending.items() for ch, q in enumerate(qs)
                         if q and q[0][0] == addr), None)
            if head is None:
                self.report(f"PCIE_RQ: RX DMA write to {addr:#x} at {now} ns is not the next served data block or "
                            f"DMA header of any channel")
                return
            self.pending[head[0]][head[1]].popleft()
            self.writes += 1
            self._left(addr, cycle)
            return
        idx = next((i for i, d in enumerate(self.dispatches) if d[0] == addr), None) if src == 1 else None
        if idx is None:
            return
        _, ch, p2p, ep = self.dispatches[idx]
        del self.dispatches[idx]
        if (ch, ep) in self.acked_at:
            # Dispatched before the stop was acknowledged, still on its way afterwards (statistics only).
            self.late_updates += 1
            self.late_max = max(self.late_max, cycle - self.acked_at[(ch, ep)])
        snaps = self.snapshots.get(addr)
        entered, snap = snaps.popleft() if snaps else (None, {})
        self.updates += 1
        behind = False
        for kind, name, val in (("data", "HDP", tlp.data[0]), ("hdr", "HHP", tlp.data[1])):
            for blk_addr, ptr, blk_ep in self.pending[kind][ch]:
                if blk_ep != ep:
                    continue
                behind = True
                # The pointer updater sends a P2P HDP shifted left by 7 within 16 bits.
                if ((ptr << 7) & 0xFFFF if p2p and kind == "data" else ptr) == val:
                    cls = snap.get(blk_addr, self.OTHER)
                    rec = {"kind": "update", "ch": ch, "addr": blk_addr, "cls": cls, "at": cycle, "entered": entered,
                           "lag": None}
                    self.violations.append(rec)
                    self.awaiting.setdefault(blk_addr, []).append(rec)
                    self.report(f"PCIE_RQ: pointer update of RX ch{ch} at {now} ns carries {name} {val:#x}, which "
                                f"covers the {'data block' if kind == 'data' else 'DMA header'} at {blk_addr:#x} "
                                f"whose RQ write has not left yet (at merger input 1 it was in {cls})")
        self.updates_behind += behind

    def leftovers(self):
        return [f"PCIE_RQ: {len(q)} served {kind} item(s) of RX ch{ch} never written, first at {q[0][0]:#x}"
                for kind, qs in self.pending.items() for ch, q in enumerate(qs) if q]

    def class_stats(self):
        """Per class of the update-time and stop-time records: count, maximum lag and records whose write never left."""
        out = {"stops_all_left": self.stops_clean}
        for what, recs in (("update", self.violations), ("stopped", self.stop_records)):
            tab = {}
            for rec in recs:
                e = tab.setdefault(rec["cls"], {"n": 0, "max_lag_cycles": None, "never_left": 0})
                e["n"] += 1
                if rec["lag"] is None:
                    e["never_left"] += 1
                else:
                    e["max_lag_cycles"] = max(e["max_lag_cycles"] or 0, rec["lag"])
            out[what] = dict(sorted(tab.items()))
        return out

    def stats(self):
        return (f"RX RQ writes ordered {self.writes}, RX pointer updates checked {self.updates} "
                f"({self.updates_behind} left with writes of their channel still pending, {self.late_updates} left "
                f"after their stop was acknowledged, up to {self.late_max} cycles)")
