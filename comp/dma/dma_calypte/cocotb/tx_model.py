# tx_model.py: model of TX_DMA_CALYPTE, ported from tx/uvm/tbench/env/dma_model.sv
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque

from cocotbext.ofm.utils.math import log2ceil

from pcie_tlp import DmaHeader, cq_decode, encode_fbe, encode_lbe


class TxDmaModel:
    """Pairs each PCIE_CQ_MFB write with its drop flag and replays it into a per-channel memory; a
    DMA header that is not dropped yields the expected USR_TX packet and META."""

    def __init__(self, device, channels, ptr_width, report, expect_cb):
        self.device = device
        self.channels = channels
        self.dpw = ptr_width
        self.mask = (1 << ptr_width) - 1
        self.chan_w = log2ceil(channels)
        self.report = report
        self.expect_cb = expect_cb
        self.memory = [bytearray(1 << ptr_width) for _ in range(channels)]
        self.tlps = deque()
        self.drops = deque()
        self.pcie_tlps = [0] * channels
        self.sent_pkts = [0] * channels
        self.sent_bytes = [0] * channels
        self.disc_pkts = [0] * channels
        self.disc_bytes = [0] * channels

    def used(self):
        return bool(self.tlps) or bool(self.drops)

    def add_tlp(self, data, meta):
        self.tlps.append((bytes(data), meta))
        self._run()

    def add_drop(self, drop):
        self.drops.append(drop)
        self._run()

    def _run(self):
        while self.tlps and self.drops:
            data, meta = self.tlps.popleft()
            self._process(data, meta, self.drops.popleft())

    def _process(self, data, meta, drop):
        pcie_addr, dword_cnt, fbe_ext, lbe_ext, payload = cq_decode(data, meta, self.device)
        addr = pcie_addr & self.mask & ~3
        ch = (pcie_addr >> (self.dpw + 1)) & ((1 << self.chan_w) - 1)
        hdr_flag = (pcie_addr >> (self.dpw + 1 + self.chan_w)) & 1
        self.pcie_tlps[ch] += 1
        if len(payload) < dword_cnt:
            self.report(f"TX model: CQ write of {dword_cnt} DWs carries only {len(payload)} DWs")
            return
        mem = self.memory[ch]
        if not hdr_flag:
            fbe = encode_fbe(fbe_ext)
            lbe = encode_lbe(lbe_ext)
            if dword_cnt <= 1:
                for it in range(fbe, lbe):
                    mem[addr + it] = (payload[0] >> (8 * it)) & 0xFF
            else:
                act = addr
                for it in range(fbe, 4):
                    mem[act + it] = (payload[0] >> (8 * it)) & 0xFF
                act = (act + 4) & self.mask
                for it in range(1, dword_cnt - 1):
                    mem[act:act + 4] = payload[it].to_bytes(4, "little")
                    act = (act + 4) & self.mask
                for it in range(lbe):
                    mem[act + it] = (payload[dword_cnt - 1] >> (8 * it)) & 0xFF
            return
        dma_hdr = DmaHeader.deserialize(payload[0] | (payload[1] << 32))
        size = dma_hdr.frame_len
        frame_ptr = dma_hdr.frame_ptr & self.mask
        p2p = dma_hdr.p2p
        hdr_meta = dma_hdr.meta
        if p2p:
            frame_ptr = (frame_ptr << 7) & self.mask
        if drop:
            self.disc_pkts[ch] += 1
            self.disc_bytes[ch] += size
            return
        out = bytes(mem[(frame_ptr + i) & self.mask] for i in range(size))
        out_meta = (size << (self.chan_w + 24)) | (ch << 24) | hdr_meta
        self.sent_pkts[ch] += 1
        self.sent_bytes[ch] += size
        self.expect_cb(out, out_meta, f"TX ch{ch} {size} B packet from frame pointer {frame_ptr:#x}")
