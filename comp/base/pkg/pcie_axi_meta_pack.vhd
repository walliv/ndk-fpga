-- pcie_axi_meta_pack.vhd: Package containing fields of TUSER signals for AXI-Stream interfaces
-- of the PCIe IP core
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

package pcie_axi_meta_pack is
    -- =============================================================================================
    -- 256-bit AXI-Stream CQ Meta fields
    -- =============================================================================================
    constant AXI_CQ256_FBE_W         : natural := 4;
    constant AXI_CQ256_LBE_W         : natural := 4;
    constant AXI_CQ256_BE_W          : natural := 32;
    constant AXI_CQ256_SOP_W         : natural := 1;
    constant AXI_CQ256_DISCON_W      : natural := 1;
    constant AXI_CQ256_TPH_PRESENT_W : natural := 1;
    constant AXI_CQ256_TPH_TYPE_W    : natural := 2;
    constant AXI_CQ256_TPH_ST_TAG_W  : natural := 8;
    constant AXI_CQ256_PARITY_W      : natural := 32;
    constant AXI_CQ256_RSV_W         : natural := 3;

    constant AXI_CQ256_FBE_O         : natural := 0;
    constant AXI_CQ256_LBE_O         : natural := AXI_CQ256_FBE_O + AXI_CQ256_FBE_W;
    constant AXI_CQ256_BE_O          : natural := AXI_CQ256_LBE_O + AXI_CQ256_LBE_W;
    constant AXI_CQ256_SOP_O         : natural := AXI_CQ256_BE_O + AXI_CQ256_BE_W;
    constant AXI_CQ256_DISCON_O      : natural := AXI_CQ256_SOP_O + AXI_CQ256_SOP_W;
    constant AXI_CQ256_TPH_PRESENT_O : natural := AXI_CQ256_DISCON_O + AXI_CQ256_DISCON_W;
    constant AXI_CQ256_TPH_TYPE_O    : natural := AXI_CQ256_TPH_PRESENT_O + AXI_CQ256_TPH_PRESENT_W;
    constant AXI_CQ256_TPH_ST_TAG_O  : natural := AXI_CQ256_TPH_TYPE_O + AXI_CQ256_TPH_TYPE_W;
    constant AXI_CQ256_PARITY_O      : natural := AXI_CQ256_TPH_ST_TAG_O + AXI_CQ256_TPH_ST_TAG_W;
    constant AXI_CQ256_RSV_O         : natural := AXI_CQ256_PARITY_O + AXI_CQ256_PARITY_W;

    subtype AXI_CQ256_FBE is natural range AXI_CQ256_FBE_O + AXI_CQ256_FBE_W -1 downto AXI_CQ256_FBE_O;
    subtype AXI_CQ256_LBE is natural range AXI_CQ256_LBE_O + AXI_CQ256_LBE_W -1 downto AXI_CQ256_LBE_O;
    subtype AXI_CQ256_BE is natural range AXI_CQ256_BE_O + AXI_CQ256_BE_W -1 downto AXI_CQ256_BE_O;
    subtype AXI_CQ256_SOP is natural range AXI_CQ256_SOP_O + AXI_CQ256_SOP_W -1 downto AXI_CQ256_SOP_O;
    subtype AXI_CQ256_DISCON is natural range AXI_CQ256_DISCON_O + AXI_CQ256_DISCON_W -1 downto AXI_CQ256_DISCON_O;
    subtype AXI_CQ256_TPH_PRESENT is natural range AXI_CQ256_TPH_PRESENT_O + AXI_CQ256_TPH_PRESENT_W -1 downto AXI_CQ256_TPH_PRESENT_O;
    subtype AXI_CQ256_TPH_TYPE is natural range AXI_CQ256_TPH_TYPE_O + AXI_CQ256_TPH_TYPE_W -1 downto AXI_CQ256_TPH_TYPE_O;
    subtype AXI_CQ256_TPH_ST_TAG is natural range AXI_CQ256_TPH_ST_TAG_O + AXI_CQ256_TPH_ST_TAG_W -1 downto AXI_CQ256_TPH_ST_TAG_O;
    subtype AXI_CQ256_PARITY is natural range AXI_CQ256_PARITY_O + AXI_CQ256_PARITY_W -1 downto AXI_CQ256_PARITY_O;
    subtype AXI_CQ256_RSV is natural range AXI_CQ256_RSV_O + AXI_CQ256_RSV_W -1 downto AXI_CQ256_RSV_O;

    constant AXI_CQ256_USER_W : natural := AXI_CQ256_RSV_O + AXI_CQ256_RSV_W;

    -- =============================================================================================
    -- 256-bit AXI-Stream CC Meta fields
    -- =============================================================================================
    constant AXI_CC256_DISCON_W : natural := 32;
    constant AXI_CC256_PARITY_W : natural := 32;

    constant AXI_CC256_DISCON_O : natural := 0;
    constant AXI_CC256_PARITY_O : natural := AXI_CC256_DISCON_O + AXI_CC256_DISCON_W;

    subtype AXI_CC256_DISCON is natural range AXI_CC256_DISCON_O + AXI_CC256_DISCON_W -1 downto AXI_CC256_DISCON_O;
    subtype AXI_CC256_PARITY is natural range AXI_CC256_PARITY_O + AXI_CC256_PARITY_W -1 downto AXI_CC256_PARITY_O;

    constant AXI_CC256_USER_W : natural := AXI_CC256_PARITY_O + AXI_CC256_PARITY_W;

    -- =============================================================================================
    -- 256-bit AXI-Stream RQ Meta fields
    -- =============================================================================================
    constant AXI_RQ256_FBE_W           : natural := 4;
    constant AXI_RQ256_LBE_W           : natural := 4;
    constant AXI_RQ256_ADDR_OFFS_W     : natural := 3;
    constant AXI_RQ256_DISCON_W        : natural := 1;
    constant AXI_RQ256_TPH_PRESENT_W   : natural := 1;
    constant AXI_RQ256_TPH_TYPE_W      : natural := 2;
    constant AXI_RQ256_TPH_INDIR_TAG_W : natural := 1;
    constant AXI_RQ256_TPH_ST_TAG_W    : natural := 8;
    constant AXI_RQ256_SEQ_NUM_L_W     : natural := 4;
    constant AXI_RQ256_PARITY_W        : natural := 32;
    constant AXI_RQ256_SEQ_NUM_H_W     : natural := 2;

    constant AXI_RQ256_FBE_O           : natural := 0;
    constant AXI_RQ256_LBE_O           : natural := AXI_RQ256_FBE_O + AXI_RQ256_FBE_W;
    constant AXI_RQ256_ADDR_OFFS_O     : natural := AXI_RQ256_LBE_O + AXI_RQ256_LBE_W;
    constant AXI_RQ256_DISCON_O        : natural := AXI_RQ256_ADDR_OFFS_O + AXI_RQ256_ADDR_OFFS_W;
    constant AXI_RQ256_TPH_PRESENT_O   : natural := AXI_RQ256_DISCON_O + AXI_RQ256_DISCON_W;
    constant AXI_RQ256_TPH_TYPE_O      : natural := AXI_RQ256_TPH_PRESENT_O + AXI_RQ256_TPH_PRESENT_W;
    constant AXI_RQ256_TPH_INDIR_TAG_O : natural := AXI_RQ256_TPH_TYPE_O + AXI_RQ256_TPH_TYPE_W;
    constant AXI_RQ256_TPH_ST_TAG_O    : natural := AXI_RQ256_TPH_INDIR_TAG_O + AXI_RQ256_TPH_INDIR_TAG_W;
    constant AXI_RQ256_SEQ_NUM_L_O     : natural := AXI_RQ256_TPH_ST_TAG_O + AXI_RQ256_TPH_ST_TAG_W;
    constant AXI_RQ256_PARITY_O        : natural := AXI_RQ256_SEQ_NUM_L_O + AXI_RQ256_SEQ_NUM_L_W;
    constant AXI_RQ256_SEQ_NUM_H_O     : natural := AXI_RQ256_PARITY_O + AXI_RQ256_PARITY_W;

    subtype AXI_RQ256_FBE is natural range AXI_RQ256_FBE_O + AXI_RQ256_FBE_W -1 downto AXI_RQ256_FBE_O;
    subtype AXI_RQ256_LBE is natural range AXI_RQ256_LBE_O + AXI_RQ256_LBE_W -1 downto AXI_RQ256_LBE_O;
    subtype AXI_RQ256_ADDR_OFFS is natural range AXI_RQ256_ADDR_OFFS_O + AXI_RQ256_ADDR_OFFS_W -1 downto AXI_RQ256_ADDR_OFFS_O;
    subtype AXI_RQ256_DISCON is natural range AXI_RQ256_DISCON_O + AXI_RQ256_DISCON_W -1 downto AXI_RQ256_DISCON_O;
    subtype AXI_RQ256_TPH_PRESENT is natural range AXI_RQ256_TPH_PRESENT_O + AXI_RQ256_TPH_PRESENT_W -1 downto AXI_RQ256_TPH_PRESENT_O;
    subtype AXI_RQ256_TPH_TYPE is natural range AXI_RQ256_TPH_TYPE_O + AXI_RQ256_TPH_TYPE_W -1 downto AXI_RQ256_TPH_TYPE_O;
    subtype AXI_RQ256_TPH_INDIR_TAG is natural range AXI_RQ256_TPH_INDIR_TAG_O + AXI_RQ256_TPH_INDIR_TAG_W -1 downto AXI_RQ256_TPH_INDIR_TAG_O;
    subtype AXI_RQ256_TPH_ST_TAG is natural range AXI_RQ256_TPH_ST_TAG_O + AXI_RQ256_TPH_ST_TAG_W -1 downto AXI_RQ256_TPH_ST_TAG_O;
    subtype AXI_RQ256_SEQ_NUM_L is natural range AXI_RQ256_SEQ_NUM_L_O + AXI_RQ256_SEQ_NUM_L_W -1 downto AXI_RQ256_SEQ_NUM_L_O;
    subtype AXI_RQ256_PARITY is natural range AXI_RQ256_PARITY_O + AXI_RQ256_PARITY_W -1 downto AXI_RQ256_PARITY_O;
    subtype AXI_RQ256_SEQ_NUM_H is natural range AXI_RQ256_SEQ_NUM_H_O + AXI_RQ256_SEQ_NUM_H_W -1 downto AXI_RQ256_SEQ_NUM_H_O;

    constant AXI_RQ256_USER_W : natural := AXI_RQ256_SEQ_NUM_H_O + AXI_RQ256_SEQ_NUM_H_W;

    -- =============================================================================================
    -- 256-bit AXI-Stream RC Meta fields
    -- =============================================================================================
    constant AXI_RC256_BE_W     : natural := 32;
    constant AXI_RC256_SOP_W    : natural := 2;
    constant AXI_RC256_EOP_0_W  : natural := 4;
    constant AXI_RC256_EOP_1_W  : natural := 4;
    constant AXI_RC256_DISCON_W : natural := 1;
    constant AXI_RC256_PARITY_W : natural := 32;

    constant AXI_RC256_BE_O     : natural := 0;
    constant AXI_RC256_SOP_O    : natural := AXI_RC256_BE_O + AXI_RC256_BE_W;
    constant AXI_RC256_EOP_0_O  : natural := AXI_RC256_SOP_O + AXI_RC256_SOP_W;
    constant AXI_RC256_EOP_1_O  : natural := AXI_RC256_EOP_0_O + AXI_RC256_EOP_0_W;
    constant AXI_RC256_DISCON_O : natural := AXI_RC256_EOP_1_O + AXI_RC256_EOP_1_W;
    constant AXI_RC256_PARITY_O : natural := AXI_RC256_DISCON_O + AXI_RC256_DISCON_W;

    subtype AXI_RC256_BE is natural range AXI_RC256_BE_O + AXI_RC256_BE_W -1 downto AXI_RC256_BE_O;
    subtype AXI_RC256_SOP is natural range AXI_RC256_SOP_O + AXI_RC256_SOP_W -1 downto AXI_RC256_SOP_O;
    subtype AXI_RC256_EOP_0 is natural range AXI_RC256_EOP_0_O + AXI_RC256_EOP_0_W -1 downto AXI_RC256_EOP_0_O;
    subtype AXI_RC256_EOP_1 is natural range AXI_RC256_EOP_1_O + AXI_RC256_EOP_1_W -1 downto AXI_RC256_EOP_1_O;
    subtype AXI_RC256_DISCON is natural range AXI_RC256_DISCON_O + AXI_RC256_DISCON_W -1 downto AXI_RC256_DISCON_O;
    subtype AXI_RC256_PARITY is natural range AXI_RC256_PARITY_O + AXI_RC256_PARITY_W -1 downto AXI_RC256_PARITY_O;

    constant AXI_RC256_USER_W : natural := AXI_RC256_PARITY_O + AXI_RC256_PARITY_W;

    -- =============================================================================================
    -- 512-bit AXI-Stream CQ Meta fields
    -- =============================================================================================
    constant AXI_CQ512_FBE_W         : natural := 8;
    constant AXI_CQ512_LBE_W         : natural := 8;
    constant AXI_CQ512_BE_W          : natural := 64;
    constant AXI_CQ512_SOP_W         : natural := 2;
    constant AXI_CQ512_SOP_POS_0_W   : natural := 2;
    constant AXI_CQ512_SOP_POS_1_W   : natural := 2;
    constant AXI_CQ512_EOP_W         : natural := 2;
    constant AXI_CQ512_EOP_POS_0_W   : natural := 4;
    constant AXI_CQ512_EOP_POS_1_W   : natural := 4;
    constant AXI_CQ512_DISCON_W      : natural := 1;
    constant AXI_CQ512_TPH_PRESENT_W : natural := 2;
    constant AXI_CQ512_TPH_TYPE_W    : natural := 4;
    constant AXI_CQ512_TPH_ST_TAG_W  : natural := 8;
    constant AXI_CQ512_PARITY_W      : natural := 64;

    constant AXI_CQ512_FBE_O         : natural := 0;
    constant AXI_CQ512_LBE_O         : natural := AXI_CQ512_FBE_O + AXI_CQ512_FBE_W;
    constant AXI_CQ512_BE_O          : natural := AXI_CQ512_LBE_O + AXI_CQ512_LBE_W;
    constant AXI_CQ512_SOP_O         : natural := AXI_CQ512_BE_O + AXI_CQ512_BE_W;
    constant AXI_CQ512_SOP_POS_0_O   : natural := AXI_CQ512_SOP_O + AXI_CQ512_SOP_W;
    constant AXI_CQ512_SOP_POS_1_O   : natural := AXI_CQ512_SOP_POS_0_O + AXI_CQ512_SOP_POS_0_W;
    constant AXI_CQ512_EOP_O         : natural := AXI_CQ512_SOP_POS_1_O + AXI_CQ512_SOP_POS_1_W;
    constant AXI_CQ512_EOP_POS_0_O   : natural := AXI_CQ512_EOP_O + AXI_CQ512_EOP_W;
    constant AXI_CQ512_EOP_POS_1_O   : natural := AXI_CQ512_EOP_POS_0_O + AXI_CQ512_EOP_POS_0_W;
    constant AXI_CQ512_DISCON_O      : natural := AXI_CQ512_EOP_POS_1_O + AXI_CQ512_EOP_POS_1_W;
    constant AXI_CQ512_TPH_PRESENT_O : natural := AXI_CQ512_DISCON_O + AXI_CQ512_DISCON_W;
    constant AXI_CQ512_TPH_TYPE_O    : natural := AXI_CQ512_TPH_PRESENT_O + AXI_CQ512_TPH_PRESENT_W;
    constant AXI_CQ512_TPH_ST_TAG_O  : natural := AXI_CQ512_TPH_TYPE_O + AXI_CQ512_TPH_TYPE_W;
    constant AXI_CQ512_PARITY_O      : natural := AXI_CQ512_TPH_ST_TAG_O + AXI_CQ512_TPH_ST_TAG_W;

    subtype AXI_CQ512_FBE is natural range AXI_CQ512_FBE_O + AXI_CQ512_FBE_W -1 downto AXI_CQ512_FBE_O;
    subtype AXI_CQ512_LBE is natural range AXI_CQ512_LBE_O + AXI_CQ512_LBE_W -1 downto AXI_CQ512_LBE_O;
    subtype AXI_CQ512_BE is natural range AXI_CQ512_BE_O + AXI_CQ512_BE_W -1 downto AXI_CQ512_BE_O;
    subtype AXI_CQ512_SOP is natural range AXI_CQ512_SOP_O + AXI_CQ512_SOP_W -1 downto AXI_CQ512_SOP_O;
    subtype AXI_CQ512_SOP_POS_0 is natural range AXI_CQ512_SOP_POS_0_O + AXI_CQ512_SOP_POS_0_W -1 downto AXI_CQ512_SOP_POS_0_O;
    subtype AXI_CQ512_SOP_POS_1 is natural range AXI_CQ512_SOP_POS_1_O + AXI_CQ512_SOP_POS_1_W -1 downto AXI_CQ512_SOP_POS_1_O;
    subtype AXI_CQ512_EOP is natural range AXI_CQ512_EOP_O + AXI_CQ512_EOP_W -1 downto AXI_CQ512_EOP_O;
    subtype AXI_CQ512_EOP_POS_0 is natural range AXI_CQ512_EOP_POS_0_O + AXI_CQ512_EOP_POS_0_W -1 downto AXI_CQ512_EOP_POS_0_O;
    subtype AXI_CQ512_EOP_POS_1 is natural range AXI_CQ512_EOP_POS_1_O + AXI_CQ512_EOP_POS_1_W -1 downto AXI_CQ512_EOP_POS_1_O;
    subtype AXI_CQ512_DISCON is natural range AXI_CQ512_DISCON_O + AXI_CQ512_DISCON_W -1 downto AXI_CQ512_DISCON_O;
    subtype AXI_CQ512_TPH_PRESENT is natural range AXI_CQ512_TPH_PRESENT_O + AXI_CQ512_TPH_PRESENT_W -1 downto AXI_CQ512_TPH_PRESENT_O;
    subtype AXI_CQ512_TPH_TYPE is natural range AXI_CQ512_TPH_TYPE_O + AXI_CQ512_TPH_TYPE_W -1 downto AXI_CQ512_TPH_TYPE_O;
    subtype AXI_CQ512_TPH_ST_TAG is natural range AXI_CQ512_TPH_ST_TAG_O + AXI_CQ512_TPH_ST_TAG_W -1 downto AXI_CQ512_TPH_ST_TAG_O;
    subtype AXI_CQ512_PARITY is natural range AXI_CQ512_PARITY_O + AXI_CQ512_PARITY_W -1 downto AXI_CQ512_PARITY_O;

    constant AXI_CQ512_USER_W : natural := AXI_CQ512_PARITY_O + AXI_CQ512_PARITY_W;

    -- =============================================================================================
    -- 512-bit AXI-Stream CC Meta fields
    -- =============================================================================================
    constant AXI_CC512_SOP_W       : natural := 2;
    constant AXI_CC512_SOP_POS_0_W : natural := 2;
    constant AXI_CC512_SOP_POS_1_W : natural := 2;
    constant AXI_CC512_EOP_W       : natural := 2;
    constant AXI_CC512_EOP_POS_0_W : natural := 4;
    constant AXI_CC512_EOP_POS_1_W : natural := 4;
    constant AXI_CC512_DISCON_W    : natural := 1;
    constant AXI_CC512_PARITY_W    : natural := 64;

    constant AXI_CC512_SOP_O       : natural := 0;
    constant AXI_CC512_SOP_POS_0_O : natural := AXI_CC512_SOP_O + AXI_CC512_SOP_W;
    constant AXI_CC512_SOP_POS_1_O : natural := AXI_CC512_SOP_POS_0_O + AXI_CC512_SOP_POS_0_W;
    constant AXI_CC512_EOP_O       : natural := AXI_CC512_SOP_POS_1_O + AXI_CC512_SOP_POS_1_W;
    constant AXI_CC512_EOP_POS_0_O : natural := AXI_CC512_EOP_O + AXI_CC512_EOP_W;
    constant AXI_CC512_EOP_POS_1_O : natural := AXI_CC512_EOP_POS_0_O + AXI_CC512_EOP_POS_0_W;
    constant AXI_CC512_DISCON_O    : natural := AXI_CC512_EOP_POS_1_O + AXI_CC512_EOP_POS_1_W;
    constant AXI_CC512_PARITY_O    : natural := AXI_CC512_DISCON_O + AXI_CC512_DISCON_W;

    subtype AXI_CC512_SOP is natural range AXI_CC512_SOP_O + AXI_CC512_SOP_W -1 downto AXI_CC512_SOP_O;
    subtype AXI_CC512_SOP_POS_0 is natural range AXI_CC512_SOP_POS_0_O + AXI_CC512_SOP_POS_0_W -1 downto AXI_CC512_SOP_POS_0_O;
    subtype AXI_CC512_SOP_POS_1 is natural range AXI_CC512_SOP_POS_1_O + AXI_CC512_SOP_POS_1_W -1 downto AXI_CC512_SOP_POS_1_O;
    subtype AXI_CC512_EOP is natural range AXI_CC512_EOP_O + AXI_CC512_EOP_W -1 downto AXI_CC512_EOP_O;
    subtype AXI_CC512_EOP_POS_0 is natural range AXI_CC512_EOP_POS_0_O + AXI_CC512_EOP_POS_0_W -1 downto AXI_CC512_EOP_POS_0_O;
    subtype AXI_CC512_EOP_POS_1 is natural range AXI_CC512_EOP_POS_1_O + AXI_CC512_EOP_POS_1_W -1 downto AXI_CC512_EOP_POS_1_O;
    subtype AXI_CC512_DISCON is natural range AXI_CC512_DISCON_O + AXI_CC512_DISCON_W -1 downto AXI_CC512_DISCON_O;
    subtype AXI_CC512_PARITY is natural range AXI_CC512_PARITY_O + AXI_CC512_PARITY_W -1 downto AXI_CC512_PARITY_O;

    constant AXI_CC512_USER_W : natural := AXI_CC512_PARITY_O + AXI_CC512_PARITY_W;

    -- =============================================================================================
    -- 512-bit AXI-Stream RQ Meta fields
    -- =============================================================================================
    constant AXI_RQ512_FBE_W           : natural := 8;
    constant AXI_RQ512_LBE_W           : natural := 8;
    constant AXI_RQ512_ADDR_OFFS_W     : natural := 4;
    constant AXI_RQ512_SOP_W           : natural := 2;
    constant AXI_RQ512_SOP_POS_0_W     : natural := 2;
    constant AXI_RQ512_SOP_POS_1_W     : natural := 2;
    constant AXI_RQ512_EOP_W           : natural := 2;
    constant AXI_RQ512_EOP_POS_0_W     : natural := 4;
    constant AXI_RQ512_EOP_POS_1_W     : natural := 4;
    constant AXI_RQ512_DISCON_W        : natural := 1;
    constant AXI_RQ512_TPH_PRESENT_W   : natural := 2;
    constant AXI_RQ512_TPH_TYPE_W      : natural := 4;
    constant AXI_RQ512_TPH_INDIR_TAG_W : natural := 2;
    constant AXI_RQ512_TPH_ST_TAG_W    : natural := 16;
    constant AXI_RQ512_SEQ_NUM_0_W     : natural := 6;
    constant AXI_RQ512_SEQ_NUM_1_W     : natural := 6;
    constant AXI_RQ512_PARITY_W        : natural := 64;

    constant AXI_RQ512_FBE_O           : natural := 0;
    constant AXI_RQ512_LBE_O           : natural := AXI_RQ512_FBE_O + AXI_RQ512_FBE_W;
    constant AXI_RQ512_ADDR_OFFS_O     : natural := AXI_RQ512_LBE_O + AXI_RQ512_LBE_W;
    constant AXI_RQ512_SOP_O           : natural := AXI_RQ512_ADDR_OFFS_O + AXI_RQ512_ADDR_OFFS_W;
    constant AXI_RQ512_SOP_POS_0_O     : natural := AXI_RQ512_SOP_O + AXI_RQ512_SOP_W;
    constant AXI_RQ512_SOP_POS_1_O     : natural := AXI_RQ512_SOP_POS_0_O + AXI_RQ512_SOP_POS_0_W;
    constant AXI_RQ512_EOP_O           : natural := AXI_RQ512_SOP_POS_1_O + AXI_RQ512_SOP_POS_1_W;
    constant AXI_RQ512_EOP_POS_0_O     : natural := AXI_RQ512_EOP_O + AXI_RQ512_EOP_W;
    constant AXI_RQ512_EOP_POS_1_O     : natural := AXI_RQ512_EOP_POS_0_O + AXI_RQ512_EOP_POS_0_W;
    constant AXI_RQ512_DISCON_O        : natural := AXI_RQ512_EOP_POS_1_O + AXI_RQ512_EOP_POS_1_W;
    constant AXI_RQ512_TPH_PRESENT_O   : natural := AXI_RQ512_DISCON_O + AXI_RQ512_DISCON_W;
    constant AXI_RQ512_TPH_TYPE_O      : natural := AXI_RQ512_TPH_PRESENT_O + AXI_RQ512_TPH_PRESENT_W;
    constant AXI_RQ512_TPH_INDIR_TAG_O : natural := AXI_RQ512_TPH_TYPE_O + AXI_RQ512_TPH_TYPE_W;
    constant AXI_RQ512_TPH_ST_TAG_O    : natural := AXI_RQ512_TPH_INDIR_TAG_O + AXI_RQ512_TPH_INDIR_TAG_W;
    constant AXI_RQ512_SEQ_NUM_0_O     : natural := AXI_RQ512_TPH_ST_TAG_O + AXI_RQ512_TPH_ST_TAG_W;
    constant AXI_RQ512_SEQ_NUM_1_O     : natural := AXI_RQ512_SEQ_NUM_0_O + AXI_RQ512_SEQ_NUM_0_W;
    constant AXI_RQ512_PARITY_O        : natural := AXI_RQ512_SEQ_NUM_1_O + AXI_RQ512_SEQ_NUM_1_W;

    subtype AXI_RQ512_FBE is natural range AXI_RQ512_FBE_O + AXI_RQ512_FBE_W -1 downto AXI_RQ512_FBE_O;
    subtype AXI_RQ512_LBE is natural range AXI_RQ512_LBE_O + AXI_RQ512_LBE_W -1 downto AXI_RQ512_LBE_O;
    subtype AXI_RQ512_ADDR_OFFS is natural range AXI_RQ512_ADDR_OFFS_O + AXI_RQ512_ADDR_OFFS_W -1 downto AXI_RQ512_ADDR_OFFS_O;
    subtype AXI_RQ512_SOP is natural range AXI_RQ512_SOP_O + AXI_RQ512_SOP_W -1 downto AXI_RQ512_SOP_O;
    subtype AXI_RQ512_SOP_POS_0 is natural range AXI_RQ512_SOP_POS_0_O + AXI_RQ512_SOP_POS_0_W -1 downto AXI_RQ512_SOP_POS_0_O;
    subtype AXI_RQ512_SOP_POS_1 is natural range AXI_RQ512_SOP_POS_1_O + AXI_RQ512_SOP_POS_1_W -1 downto AXI_RQ512_SOP_POS_1_O;
    subtype AXI_RQ512_EOP is natural range AXI_RQ512_EOP_O + AXI_RQ512_EOP_W -1 downto AXI_RQ512_EOP_O;
    subtype AXI_RQ512_EOP_POS_0 is natural range AXI_RQ512_EOP_POS_0_O + AXI_RQ512_EOP_POS_0_W -1 downto AXI_RQ512_EOP_POS_0_O;
    subtype AXI_RQ512_EOP_POS_1 is natural range AXI_RQ512_EOP_POS_1_O + AXI_RQ512_EOP_POS_1_W -1 downto AXI_RQ512_EOP_POS_1_O;
    subtype AXI_RQ512_DISCON is natural range AXI_RQ512_DISCON_O + AXI_RQ512_DISCON_W -1 downto AXI_RQ512_DISCON_O;
    subtype AXI_RQ512_TPH_PRESENT is natural range AXI_RQ512_TPH_PRESENT_O + AXI_RQ512_TPH_PRESENT_W -1 downto AXI_RQ512_TPH_PRESENT_O;
    subtype AXI_RQ512_TPH_TYPE is natural range AXI_RQ512_TPH_TYPE_O + AXI_RQ512_TPH_TYPE_W -1 downto AXI_RQ512_TPH_TYPE_O;
    subtype AXI_RQ512_TPH_INDIR_TAG is natural range AXI_RQ512_TPH_INDIR_TAG_O + AXI_RQ512_TPH_INDIR_TAG_W -1 downto AXI_RQ512_TPH_INDIR_TAG_O;
    subtype AXI_RQ512_TPH_ST_TAG is natural range AXI_RQ512_TPH_ST_TAG_O + AXI_RQ512_TPH_ST_TAG_W -1 downto AXI_RQ512_TPH_ST_TAG_O;
    subtype AXI_RQ512_SEQ_NUM_0 is natural range AXI_RQ512_SEQ_NUM_0_O + AXI_RQ512_SEQ_NUM_0_W -1 downto AXI_RQ512_SEQ_NUM_0_O;
    subtype AXI_RQ512_SEQ_NUM_1 is natural range AXI_RQ512_SEQ_NUM_1_O + AXI_RQ512_SEQ_NUM_1_W -1 downto AXI_RQ512_SEQ_NUM_1_O;
    subtype AXI_RQ512_PARITY is natural range AXI_RQ512_PARITY_O + AXI_RQ512_PARITY_W -1 downto AXI_RQ512_PARITY_O;

    constant AXI_RQ512_USER_W : natural := AXI_RQ512_PARITY_O + AXI_RQ512_PARITY_W;

    -- =============================================================================================
    -- 512-bit AXI-Stream RC Meta fields
    -- =============================================================================================
    constant AXI_RC512_BE_W        : natural := 64;
    constant AXI_RC512_SOP_W       : natural := 4;
    constant AXI_RC512_SOP_PTR_0_W : natural := 2;
    constant AXI_RC512_SOP_PTR_1_W : natural := 2;
    constant AXI_RC512_SOP_PTR_2_W : natural := 2;
    constant AXI_RC512_SOP_PTR_3_W : natural := 2;
    constant AXI_RC512_EOP_W       : natural := 4;
    constant AXI_RC512_EOP_PTR_0_W : natural := 4;
    constant AXI_RC512_EOP_PTR_1_W : natural := 4;
    constant AXI_RC512_EOP_PTR_2_W : natural := 4;
    constant AXI_RC512_EOP_PTR_3_W : natural := 4;
    constant AXI_RC512_DISCON_W    : natural := 1;
    constant AXI_RC512_PARITY_W    : natural := 64;

    constant AXI_RC512_BE_O        : natural := 0;
    constant AXI_RC512_SOP_O       : natural := AXI_RC512_BE_O + AXI_RC512_BE_W;
    constant AXI_RC512_SOP_PTR_0_O : natural := AXI_RC512_SOP_O + AXI_RC512_SOP_W;
    constant AXI_RC512_SOP_PTR_1_O : natural := AXI_RC512_SOP_PTR_0_O + AXI_RC512_SOP_PTR_0_W;
    constant AXI_RC512_SOP_PTR_2_O : natural := AXI_RC512_SOP_PTR_1_O + AXI_RC512_SOP_PTR_1_W;
    constant AXI_RC512_SOP_PTR_3_O : natural := AXI_RC512_SOP_PTR_2_O + AXI_RC512_SOP_PTR_2_W;
    constant AXI_RC512_EOP_O       : natural := AXI_RC512_SOP_PTR_3_O + AXI_RC512_SOP_PTR_3_W;
    constant AXI_RC512_EOP_PTR_0_O : natural := AXI_RC512_EOP_O + AXI_RC512_EOP_W;
    constant AXI_RC512_EOP_PTR_1_O : natural := AXI_RC512_EOP_PTR_0_O + AXI_RC512_EOP_PTR_0_W;
    constant AXI_RC512_EOP_PTR_2_O : natural := AXI_RC512_EOP_PTR_1_O + AXI_RC512_EOP_PTR_1_W;
    constant AXI_RC512_EOP_PTR_3_O : natural := AXI_RC512_EOP_PTR_2_O + AXI_RC512_EOP_PTR_2_W;
    constant AXI_RC512_DISCON_O    : natural := AXI_RC512_EOP_PTR_3_O + AXI_RC512_EOP_PTR_3_W;
    constant AXI_RC512_PARITY_O    : natural := AXI_RC512_DISCON_O + AXI_RC512_DISCON_W;

    subtype AXI_RC512_BE is natural range AXI_RC512_BE_O + AXI_RC512_BE_W -1 downto AXI_RC512_BE_O;
    subtype AXI_RC512_SOP is natural range AXI_RC512_SOP_O + AXI_RC512_SOP_W -1 downto AXI_RC512_SOP_O;
    subtype AXI_RC512_SOP_PTR_0 is natural range AXI_RC512_SOP_PTR_0_O + AXI_RC512_SOP_PTR_0_W -1 downto AXI_RC512_SOP_PTR_0_O;
    subtype AXI_RC512_SOP_PTR_1 is natural range AXI_RC512_SOP_PTR_1_O + AXI_RC512_SOP_PTR_1_W -1 downto AXI_RC512_SOP_PTR_1_O;
    subtype AXI_RC512_SOP_PTR_2 is natural range AXI_RC512_SOP_PTR_2_O + AXI_RC512_SOP_PTR_2_W -1 downto AXI_RC512_SOP_PTR_2_O;
    subtype AXI_RC512_SOP_PTR_3 is natural range AXI_RC512_SOP_PTR_3_O + AXI_RC512_SOP_PTR_3_W -1 downto AXI_RC512_SOP_PTR_3_O;
    subtype AXI_RC512_EOP is natural range AXI_RC512_EOP_O + AXI_RC512_EOP_W -1 downto AXI_RC512_EOP_O;
    subtype AXI_RC512_EOP_PTR_0 is natural range AXI_RC512_EOP_PTR_0_O + AXI_RC512_EOP_PTR_0_W -1 downto AXI_RC512_EOP_PTR_0_O;
    subtype AXI_RC512_EOP_PTR_1 is natural range AXI_RC512_EOP_PTR_1_O + AXI_RC512_EOP_PTR_1_W -1 downto AXI_RC512_EOP_PTR_1_O;
    subtype AXI_RC512_EOP_PTR_2 is natural range AXI_RC512_EOP_PTR_2_O + AXI_RC512_EOP_PTR_2_W -1 downto AXI_RC512_EOP_PTR_2_O;
    subtype AXI_RC512_EOP_PTR_3 is natural range AXI_RC512_EOP_PTR_3_O + AXI_RC512_EOP_PTR_3_W -1 downto AXI_RC512_EOP_PTR_3_O;
    subtype AXI_RC512_DISCON is natural range AXI_RC512_DISCON_O + AXI_RC512_DISCON_W -1 downto AXI_RC512_DISCON_O;
    subtype AXI_RC512_PARITY is natural range AXI_RC512_PARITY_O + AXI_RC512_PARITY_W -1 downto AXI_RC512_PARITY_O;

    constant AXI_RC512_USER_W : natural := AXI_RC512_PARITY_O + AXI_RC512_PARITY_W;
end package;

package body pcie_axi_meta_pack is
end package body;
