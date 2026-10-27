# ptr_upd_model.py: model of DMA_PTR_UPDATER for both directions
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""RX side: rx/uvm/tbench/env/ptr_upd_model.sv. TX side: tx/uvm/tbench/env/ptr_upd_model.sv,
with the threshold the DMA_CALYPTE top level passes (USR_TX_PKT_SIZE_MAX/2)."""

from pcie_tlp import ptr_upd_expect


class PtrUpdModel:
    def __init__(self, rx_ptr_width, tx_channels, tx_ptr_width, tx_threshold, tx_regs, expect_cb):
        self.rx_pw = rx_ptr_width
        self.tx_pw = tx_ptr_width
        self.tx_mask = (1 << tx_ptr_width) - 1
        self.threshold = tx_threshold
        self.tx_regs = tx_regs
        self.expect_cb = expect_cb
        self.tx_hdp = [0] * tx_channels
        self.tx_hhp = [0] * tx_channels
        self.counts = {"rx_stop": 0, "tx_start": 0, "tx_rt": 0, "tx_rt_sent": 0, "tx_stop": 0}

    def rx_stop(self, buff_ba, p2p, hdp, hhp):
        self.counts["rx_stop"] += 1
        if p2p:
            # {hdp_int, 7'b0} into a POINTER_WIDTH-wide variable (dma_ptr_updater.vhd:181 likewise)
            hdp = (hdp << 7) & ((1 << self.rx_pw) - 1)
        tlp = ptr_upd_expect(buff_ba, hdp, hhp, p2p)
        tlp.info = "RX stop update"
        self.expect_cb(tlp)

    def tx_cycle(self, start_ch, rt, stop):
        """One clock cycle of TX requests in the UVM model's order: start, runtime update, stop."""
        if start_ch is not None:
            self.counts["tx_start"] += 1
            self.tx_hdp[start_ch] = 0
            self.tx_hhp[start_ch] = 0
        if rt is not None:
            ch, hdp, hhp = rt
            self.counts["tx_rt"] += 1
            if ((hdp - self.tx_hdp[ch]) & self.tx_mask) >= self.threshold:
                self.counts["tx_rt_sent"] += 1
                self.tx_hdp[ch] = hdp
                self.tx_hhp[ch] = hhp
                regs = self.tx_regs[ch]
                p2p = regs.get("exper") & 1
                if p2p:
                    hdp >>= 7
                tlp = ptr_upd_expect(regs.get("update_base"), hdp, hhp, p2p)
                tlp.info = f"TX ch{ch} runtime update"
                self.expect_cb(tlp)
        if stop is not None:
            buff_ba, p2p, hdp, hhp = stop
            self.counts["tx_stop"] += 1
            if p2p:
                hdp >>= 7
            tlp = ptr_upd_expect(buff_ba, hdp, hhp, p2p)
            tlp.info = "TX stop update"
            self.expect_cb(tlp)
