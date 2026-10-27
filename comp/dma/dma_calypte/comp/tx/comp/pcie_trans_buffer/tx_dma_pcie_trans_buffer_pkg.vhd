-- tx_dma_pcie_trans_buffer_pkg.vhd: write META layout and memory geometry of the PCIe transaction buffer
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

use work.math_pack.all;

package tx_dma_pcie_trans_buffer_pkg is

    -- The write META of one region holds, from bit 0 up, IS_DMA_HDR, the DWord address PCIE_ADDR, the channel
    -- CHAN_NUM of log2(CHANNELS) bits and one byte enable BE per byte of the region.
    constant TRBUF_META_IS_DMA_HDR_W : natural := 1;
    constant TRBUF_META_PCIE_ADDR_W  : natural := 62;

    constant TRBUF_META_IS_DMA_HDR_O : natural := 0;
    constant TRBUF_META_PCIE_ADDR_O  : natural := TRBUF_META_IS_DMA_HDR_O + TRBUF_META_IS_DMA_HDR_W;
    constant TRBUF_META_CHAN_NUM_O   : natural := TRBUF_META_PCIE_ADDR_O + TRBUF_META_PCIE_ADDR_W;

    subtype TRBUF_META_IS_DMA_HDR is natural range TRBUF_META_IS_DMA_HDR_O + TRBUF_META_IS_DMA_HDR_W -1 downto TRBUF_META_IS_DMA_HDR_O;
    subtype TRBUF_META_PCIE_ADDR  is natural range TRBUF_META_PCIE_ADDR_O + TRBUF_META_PCIE_ADDR_W -1 downto TRBUF_META_PCIE_ADDR_O;

    -- Offset of BE behind the CHAN_NUM field of the given number of channels
    function trbuf_meta_be_o_f (channels : natural) return natural;
    -- Width of the write META of a region of region_width bits
    function trbuf_meta_width_f (channels : natural; region_width : natural) return natural;

    -- Rows of one memory array: 8-bit M20K and RAMB36 blocks of the per-byte buffer, word-wide BRAM and URAM arrays
    -- of the row-banked buffer.
    constant TRBUF_DEPTH_M20K : natural := 2048;
    constant TRBUF_DEPTH_BRAM : natural := 4096;
    constant TRBUF_DEPTH_URAM : natural := 16384;

    -- Rows of mfb_width bits that the 2**pointer_width bytes of one channel take
    function trbuf_buffer_depth_f (pointer_width : natural; mfb_width : natural) return natural;
    -- Channels that share one memory array of depth rows
    function trbuf_chans_per_array_f (channels : natural; buffer_depth : natural; depth : natural) return natural;

end package;

package body tx_dma_pcie_trans_buffer_pkg is

    function trbuf_meta_be_o_f (channels : natural) return natural is
    begin
        return TRBUF_META_CHAN_NUM_O + log2(channels);
    end function;

    function trbuf_meta_width_f (channels : natural; region_width : natural) return natural is
    begin
        return trbuf_meta_be_o_f(channels) + region_width/8;
    end function;

    function trbuf_buffer_depth_f (pointer_width : natural; mfb_width : natural) return natural is
    begin
        return (2**pointer_width)/(mfb_width/8);
    end function;

    function trbuf_chans_per_array_f (channels : natural; buffer_depth : natural; depth : natural) return natural is
    begin
        return minimum(channels, depth/buffer_depth);
    end function;

end package body;
