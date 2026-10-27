# rx_model.py: model of RX_DMA_CALYPTE, ported from rx/uvm/tbench/env/dma_model.sv
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque

from pcie_tlp import DmaHeader, mwr_expect

BLOCK_SIZE_BYTES = 128
ADDR_MASK = (1 << 64) - 1


class RxChannelState:
    def __init__(self):
        self.data_ptr = 0
        self.hdr_ptr = 0
        self.vld_bit = 1


class RxDmaModel:
    """Pairs the k-th packet seen on USR_RX_MFB with the k-th header-manager drop decision (the
    UVM probe on hdrm_pkt_drop) and turns accepted packets into the expected RQ writes."""

    def __init__(self, channels, regs, expect_cb):
        self.channels = channels
        self.regs = regs
        self.expect_cb = expect_cb
        self.state = [RxChannelState() for _ in range(channels)]
        self.packets = deque()
        self.drops = deque()
        self.sent_pkts = [0] * channels
        self.sent_bytes = [0] * channels
        self.disc_pkts = [0] * channels
        self.disc_bytes = [0] * channels
        self.processed = 0
        for ch in range(channels):
            regs[ch].control_hooks.append(lambda ch=ch: self._on_start(ch))

    def _on_start(self, ch):
        st = self.state[ch]
        st.data_ptr = 0
        st.hdr_ptr = 0
        st.vld_bit = 1

    def used(self):
        return bool(self.packets) or bool(self.drops)

    def add_packet(self, data, meta, now):
        self.packets.append((bytes(data), meta, now))
        self._run()

    def add_drop(self, drop):
        self.drops.append(drop)
        self._run()

    def _run(self):
        while self.packets and self.drops:
            data, meta, start = self.packets.popleft()
            drop = self.drops.popleft()
            ch = meta >> 24
            hdr_meta = meta & 0xFFFFFF
            self.processed += 1
            if drop:
                self.disc_pkts[ch] += 1
                self.disc_bytes[ch] += len(data)
            else:
                self.sent_pkts[ch] += 1
                self.sent_bytes[ch] += len(data)
                self._packet_send(data, ch, hdr_meta, start)

    def _packet_send(self, data, ch, hdr_meta, start):
        st = self.state[ch]
        regs = self.regs[ch]
        data_base = regs.get("data_base")
        data_mask = regs.get("data_mask")
        start_ptr = st.data_ptr
        parts = (len(data) + BLOCK_SIZE_BYTES - 1) // BLOCK_SIZE_BYTES
        for part in range(parts):
            addr = (data_base + st.data_ptr * BLOCK_SIZE_BYTES) & ADDR_MASK
            st.data_ptr = (st.data_ptr + 1) & data_mask
            tlp = mwr_expect(addr, data[part * BLOCK_SIZE_BYTES:(part + 1) * BLOCK_SIZE_BYTES])
            tlp.info = f"RX ch{ch} data part {part + 1}/{parts} of a {len(data)} B packet (in at {start} ns)"
            self.expect_cb(tlp)

        addr = (regs.get("hdr_base") + st.hdr_ptr * 8) & ADDR_MASK
        st.hdr_ptr = (st.hdr_ptr + 1) & regs.get("hdr_mask")
        p2p = regs.get("exper") & 1
        hdr = DmaHeader()
        hdr.frame_len, hdr.frame_ptr, hdr.vld, hdr.p2p, hdr.meta = len(data), start_ptr, st.vld_bit, p2p, hdr_meta
        tlp = mwr_expect(addr, hdr.serialize().to_bytes(8, "little"))
        tlp.info = f"RX ch{ch} DMA header of a {len(data)} B packet (in at {start} ns)"
        self.expect_cb(tlp)
        if st.hdr_ptr == 0:
            st.vld_bit ^= 1
