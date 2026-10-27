# trans_buffer_model.py: Reference model of TX_DMA_PCIE_TRANS_BUFFER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Byte content of the TX_DMA_PCIE_TRANS_BUFFER channel buffers for the (2,1,8,32) MFB geometry: process_word() once
per accepted write word in drive order; the RTL's write pipeline delay only matters for read timing."""

MFB_REGIONS = 2
MFB_BLOCK_SIZE = 8  # DWs per region
MFB_BYTES = 64      # bytes per MFB word (both regions)
REGION_BYTES = 32   # bytes per region


class TransBufferModel:
    def __init__(self, channels: int, pointer_width: int):
        self.channels = channels
        self.pointer_width = pointer_width
        self.buf_size = 1 << pointer_width
        self.buffers = [bytearray(self.buf_size) for _ in range(channels)]

        # write-context registers (mirror addr_cntr_pst / chan_num_reg in the RTL)
        self.addr_cntr = 0  # in DWORDS, META_PCIE_ADDR_W = 62 bits wide
        self.chan_reg = 0
        self._addr_mask = (1 << 62) - 1

    def write_bytes(self, chan: int, base_dw: int, be: int, data: bytes, region_len: int):
        """Writes up to region_len bytes of `data` from byte base_dw*4 of `chan`, gated by bit i of `be`, wrapping at
        the buffer size."""
        buf = self.buffers[chan]
        base_byte = (base_dw * 4) & self._addr_mask
        for i in range(region_len):
            if (be >> i) & 1:
                buf[(base_byte + i) % self.buf_size] = data[i]

    def process_word(self, sof0: bool, sof1: bool,
                     meta0_addr: int, meta0_chan: int, meta0_be: int,
                     meta1_addr: int, meta1_chan: int, meta1_be: int,
                     data: bytes):
        """Process one accepted (SRC_RDY=1) MFB write word. `data` is 64 bytes, data[0] is the
        byte residing at bits [7:0] of PCIE_MFB_DATA (region 0, DW 0, byte 0)."""
        assert len(data) == MFB_BYTES

        # ---- Step 1: per-region effective write base (see addr_cntr_nst_logic_p / wr_bshifter) ----
        if sof0:
            base_dw0, chan0 = meta0_addr, meta0_chan
        else:
            base_dw0, chan0 = self.addr_cntr, self.chan_reg

        # ---- Step 2: byte-enable mapping / actual writes ----
        if sof1:
            # Region 0: independent write of its own 32 B (may be empty if meta0_be == 0, e.g. a
            # SOF(1)-only "region 0 empty" word).
            self.write_bytes(chan0, base_dw0, meta0_be, data[0:REGION_BYTES], REGION_BYTES)

            # Region 1: independent transaction, addressed relative to its own PCIE_ADDR (not
            # offset by the region size -- the RTL's wr_shift_sel(1) subtracts MFB_BLOCK_SIZE=8
            # DWs from META(1).PCIE_ADDR precisely to cancel that offset).
            base_dw1, chan1 = meta1_addr, meta1_chan
            self.write_bytes(chan1, base_dw1, meta1_be, data[REGION_BYTES:MFB_BYTES], REGION_BYTES)
        else:
            # Whole word is a single transaction addressed by base_dw0/chan0; the byte-enable is
            # the concatenation of META(1).BE (bytes 32..63) and META(0).BE (bytes 0..31).
            be_full = (meta1_be << REGION_BYTES) | meta0_be
            self.write_bytes(chan0, base_dw0, be_full, data, MFB_BYTES)

        # ---- Step 3: addr_cntr / chan_reg update (addr_cntr_nst_logic_p, "last SOF wins") ----
        self.addr_cntr = (self.addr_cntr + MFB_REGIONS * MFB_BLOCK_SIZE) & self._addr_mask
        if sof0:
            self.addr_cntr = (meta0_addr + (MFB_REGIONS - 0) * MFB_BLOCK_SIZE) & self._addr_mask
            self.chan_reg = chan0
        if sof1:
            self.addr_cntr = (meta1_addr + (MFB_REGIONS - 1) * MFB_BLOCK_SIZE) & self._addr_mask
            self.chan_reg = meta1_chan

    def read(self, chan: int, byte_addr: int, length: int = MFB_BYTES) -> bytes:
        buf = self.buffers[chan]
        return bytes(buf[(byte_addr + i) % self.buf_size] for i in range(length))
