-- cq_axi2mfb_tb.vhd: Cocotb top of PCIE_CQ_AXI2MFB, packing its sideband outputs into the CQ MFB meta like PCIE_ADAPTER
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.pcie_axi_cpm5_pack.all;

-- The converter is combinational; CLK only paces the testbench agents.
entity CQ_AXI2MFB_TB is
    generic (
        MFB_REGIONS      : natural := 4;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        AXI_CQUSER_WIDTH : natural := AXI_CQ1024_USER_W;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        STRADDLING       : boolean := true
    );
    port (
        CLK            : in  std_logic;

        CQ_AXI_DATA    : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CQ_AXI_USER    : in  std_logic_vector(AXI_CQUSER_WIDTH-1 downto 0);
        CQ_AXI_LAST    : in  std_logic;
        CQ_AXI_KEEP    : in  std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CQ_AXI_VALID   : in  std_logic;
        CQ_AXI_READY   : out std_logic;

        CQ_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CQ_MFB_META    : out std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        CQ_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CQ_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CQ_MFB_SRC_RDY : out std_logic;
        CQ_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of CQ_AXI2MFB_TB is

    signal cq_tph_present  : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal cq_tph_type     : std_logic_vector(MFB_REGIONS*PCIE_META_TPH_TYPE_W-1 downto 0);
    signal cq_tph_st_tag   : std_logic_vector(MFB_REGIONS*PCIE_META_TPH_ST_TAG_W-1 downto 0);
    signal cq_fbe          : std_logic_vector(MFB_REGIONS*PCIE_META_FBE_W-1 downto 0);
    signal cq_lbe          : std_logic_vector(MFB_REGIONS*PCIE_META_LBE_W-1 downto 0);
    signal cq_be           : std_logic_vector(MFB_REGIONS*PCIE_META_BE_W-1 downto 0);
    signal cq_mfb_meta_arr : slv_array_t(MFB_REGIONS-1 downto 0)(PCIE_CQ_META_WIDTH-1 downto 0);

begin

    dut_i : entity work.PCIE_CQ_AXI2MFB
    generic map (
        MFB_REGIONS      => MFB_REGIONS,
        MFB_REGION_SIZE  => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE   => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH   => MFB_ITEM_WIDTH,
        AXI_CQUSER_WIDTH => AXI_CQUSER_WIDTH,
        AXI_DATA_WIDTH   => AXI_DATA_WIDTH,
        STRADDLING       => STRADDLING,
        DEVICE           => "VERSAL"
    )
    port map (
        CQ_AXI_DATA    => CQ_AXI_DATA,
        CQ_AXI_USER    => CQ_AXI_USER,
        CQ_AXI_LAST    => CQ_AXI_LAST,
        CQ_AXI_KEEP    => CQ_AXI_KEEP,
        CQ_AXI_VALID   => CQ_AXI_VALID,
        CQ_AXI_READY   => CQ_AXI_READY,

        CQ_MFB_DATA    => CQ_MFB_DATA,
        CQ_MFB_SOF     => CQ_MFB_SOF,
        CQ_MFB_EOF     => CQ_MFB_EOF,
        CQ_MFB_SOF_POS => CQ_MFB_SOF_POS,
        CQ_MFB_EOF_POS => CQ_MFB_EOF_POS,
        CQ_MFB_SRC_RDY => CQ_MFB_SRC_RDY,
        CQ_MFB_DST_RDY => CQ_MFB_DST_RDY,

        CQ_TPH_PRESENT => cq_tph_present,
        CQ_TPH_TYPE    => cq_tph_type,
        CQ_TPH_ST_TAG  => cq_tph_st_tag,
        CQ_FBE         => cq_fbe,
        CQ_LBE         => cq_lbe,
        CQ_BE          => cq_be
    );

    -- Same packing as the xilinx_g branch of PCIE_ADAPTER
    cq_mfb_meta_g : for i in 0 to MFB_REGIONS-1 generate
        cq_mfb_meta_arr(i)(PCIE_CQ_META_HEADER)        <= (others => '0');
        cq_mfb_meta_arr(i)(PCIE_CQ_META_PREFIX)        <= (others => '0');
        cq_mfb_meta_arr(i)(PCIE_CQ_META_BAR)           <= (others => '0');
        cq_mfb_meta_arr(i)(PCIE_CQ_META_FBE)           <= cq_fbe((i+1)*PCIE_META_FBE_W-1 downto i*PCIE_META_FBE_W);
        cq_mfb_meta_arr(i)(PCIE_CQ_META_LBE)           <= cq_lbe((i+1)*PCIE_META_LBE_W-1 downto i*PCIE_META_LBE_W);
        cq_mfb_meta_arr(i)(PCIE_CQ_META_BE)            <= cq_be((i+1)*PCIE_META_BE_W-1 downto i*PCIE_META_BE_W);
        cq_mfb_meta_arr(i)(PCIE_CQ_META_TPH_PRESENT_O) <= cq_tph_present(i);
        cq_mfb_meta_arr(i)(PCIE_CQ_META_TPH_TYPE)      <= cq_tph_type((i+1)*PCIE_META_TPH_TYPE_W-1 downto i*PCIE_META_TPH_TYPE_W);
        cq_mfb_meta_arr(i)(PCIE_CQ_META_TPH_ST_TAG)    <= cq_tph_st_tag((i+1)*PCIE_META_TPH_ST_TAG_W-1 downto i*PCIE_META_TPH_ST_TAG_W);
    end generate;

    CQ_MFB_META <= slv_array_ser(cq_mfb_meta_arr);

end architecture;
