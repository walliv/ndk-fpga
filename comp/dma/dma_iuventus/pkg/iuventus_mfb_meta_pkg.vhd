-- iuventus_mfb_meta_pkg.vhd: package containing the structure of metadata signal inside the controller
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.pcie_meta_pack.all;

package iuventus_mfb_meta_pkg is
    generic (
        MFB_REGION_SIZE : positive;
        MFB_BLOCK_SIZE  : positive;
        MFB_ITEM_WIDTH  : positive;
        CHANNELS        : positive := 2;
        BUFF_PTR_WIDTH  : positive := 17);

    -- =============================================================================================
    -- Base set of metadata subsignals comming from the metadata extractor or inside it 
    -- =============================================================================================
    constant META_PCIE_ADDR_W    : natural := 64;
    constant META_BAR_ID_W       : natural := 3;
    constant META_FBE_W          : natural := 4;
    constant META_LBE_W          : natural := 4;
    constant META_BE_W           : natural := (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8;
    constant META_CHAN_IDX_W     : natural := log2(CHANNELS);
    constant META_BYTE_CNT_W     : natural := 13;

    constant META_PCIE_ADDR_O    : natural := 0;
    constant META_BAR_ID_O       : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    constant META_FBE_O          : natural := META_BAR_ID_O + META_BAR_ID_W;
    constant META_LBE_O          : natural := META_FBE_O + META_FBE_W;
    constant META_BE_O           : natural := META_BAR_ID_O + META_BAR_ID_W;

    subtype META_PCIE_ADDR is natural range META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O;
    subtype META_BAR_ID is natural range META_BAR_ID_O + META_BAR_ID_W -1 downto META_BAR_ID_O;
    subtype META_FBE is natural range META_FBE_O + META_FBE_W -1 downto META_FBE_O;
    subtype META_LBE is natural range META_LBE_O + META_LBE_W -1 downto META_LBE_O;
    subtype META_BE is natural range META_BE_O + META_BE_W -1 downto META_BE_O;

    constant MFB_META_WIDTH_INT         : natural := META_LBE_O + META_LBE_W;
    constant MFB_META_REDUCED_WIDTH_INT : natural := META_BE_O + META_BE_W;

    -- =============================================================================================
    -- Another set of signals for the header FIFO (builds on the base set)
    -- =============================================================================================
    constant META_HDR_FIFO_HDR_RAW_O : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    constant META_HDR_FIFO_BYTE_CNT_O : natural := META_HDR_FIFO_HDR_RAW_O + PCIE_META_REQ_HDR_W;
    subtype META_HDR_FIFO_HDR_RAW is natural range META_HDR_FIFO_HDR_RAW_O + PCIE_META_REQ_HDR_W -1 downto META_HDR_FIFO_HDR_RAW_O;
    subtype META_HDR_FIFO_BYTE_CNT is natural range META_HDR_FIFO_BYTE_CNT_O + META_BYTE_CNT_W -1 downto META_HDR_FIFO_BYTE_CNT_O;
    constant HDR_FIFO_DATA_W : natural := META_HDR_FIFO_BYTE_CNT_O + META_BYTE_CNT_W;

    -- ============================================================================================
    -- Metadata signal in C2N controller
    -- ============================================================================================
    constant C2N_META_BUFF_PTR_W : natural := BUFF_PTR_WIDTH - 2;

    constant C2N_META_BUFF_PTR_O : natural := 2;
    constant C2N_META_CHAN_IDX_O : natural := C2N_META_BUFF_PTR_O + C2N_META_BUFF_PTR_W;
    constant C2N_META_BE_O       : natural := C2N_META_CHAN_IDX_O + META_CHAN_IDX_W;

    subtype C2N_META_BUFF_PTR is natural range C2N_META_BUFF_PTR_O + C2N_META_BUFF_PTR_W -1 downto C2N_META_BUFF_PTR_O;
    subtype C2N_META_CHAN_IDX is natural range C2N_META_CHAN_IDX_O + META_CHAN_IDX_W -1 downto C2N_META_CHAN_IDX_O;
    subtype C2N_META_BE is natural range C2N_META_BE_O + META_BE_W -1 downto C2N_META_BE_O;
end package;

package body iuventus_mfb_meta_pkg is
end package body;
