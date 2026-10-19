-- rq_mfb2axi_tb.vhd: Cocotb top of PCIE_RQ_MFB2AXI
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.pcie_meta_pack.all;
use work.pcie_axi_cpm5_pack.all;

-- TX_COND puts PCIE_CPM5_TX_COND in front of the converter, as PCIE_ADAPTER does; without it the
-- converter is combinational and CLK/RESET only pace the testbench agents.
entity RQ_MFB2AXI_TB is
    generic (
        MFB_REGIONS      : natural := 4;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        AXI_RQUSER_WIDTH : natural := AXI_RQ1024_USER_W;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        STRADDLING       : boolean := true;
        TX_COND          : boolean := false
    );
    port (
        CLK            : in  std_logic;
        RESET          : in  std_logic;

        RQ_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RQ_MFB_META    : in  std_logic_vector(MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
        RQ_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        RQ_MFB_EOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        RQ_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        RQ_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        RQ_MFB_SRC_RDY : in  std_logic;
        RQ_MFB_DST_RDY : out std_logic;

        RQ_AXI_DATA    : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        RQ_AXI_USER    : out std_logic_vector(AXI_RQUSER_WIDTH-1 downto 0);
        RQ_AXI_LAST    : out std_logic;
        RQ_AXI_KEEP    : out std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        RQ_AXI_VALID   : out std_logic;
        RQ_AXI_READY   : in  std_logic
    );
end entity;

architecture FULL of RQ_MFB2AXI_TB is

    signal conv_data    : std_logic_vector(RQ_MFB_DATA'range);
    signal conv_meta    : std_logic_vector(MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
    signal conv_sof     : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal conv_eof     : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal conv_sof_pos : std_logic_vector(RQ_MFB_SOF_POS'range);
    signal conv_eof_pos : std_logic_vector(RQ_MFB_EOF_POS'range);
    signal conv_src_rdy : std_logic;
    signal conv_dst_rdy : std_logic;

begin

    tx_cond_g : if TX_COND generate
        tx_cond_i : entity work.PCIE_CPM5_TX_COND
        generic map (
            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
            MFB_META_WIDTH  => PCIE_RQ_META_WIDTH,
            MAX_TLP_BYTES   => 1024+16,
            DEVICE          => "VERSAL"
        )
        port map (
            CLK            => CLK,
            RESET          => RESET,

            RX_MFB_DATA    => RQ_MFB_DATA,
            RX_MFB_META    => RQ_MFB_META,
            RX_MFB_SOF     => RQ_MFB_SOF,
            RX_MFB_EOF     => RQ_MFB_EOF,
            RX_MFB_SOF_POS => RQ_MFB_SOF_POS,
            RX_MFB_EOF_POS => RQ_MFB_EOF_POS,
            RX_MFB_SRC_RDY => RQ_MFB_SRC_RDY,
            RX_MFB_DST_RDY => RQ_MFB_DST_RDY,

            TX_MFB_DATA    => conv_data,
            TX_MFB_META    => conv_meta,
            TX_MFB_SOF     => conv_sof,
            TX_MFB_EOF     => conv_eof,
            TX_MFB_SOF_POS => conv_sof_pos,
            TX_MFB_EOF_POS => conv_eof_pos,
            TX_MFB_SRC_RDY => conv_src_rdy,
            TX_MFB_DST_RDY => conv_dst_rdy
        );
    else generate
        conv_data       <= RQ_MFB_DATA;
        conv_meta       <= RQ_MFB_META;
        conv_sof        <= RQ_MFB_SOF;
        conv_eof        <= RQ_MFB_EOF;
        conv_sof_pos    <= RQ_MFB_SOF_POS;
        conv_eof_pos    <= RQ_MFB_EOF_POS;
        conv_src_rdy    <= RQ_MFB_SRC_RDY;
        RQ_MFB_DST_RDY  <= conv_dst_rdy;
    end generate;

    dut_i : entity work.PCIE_RQ_MFB2AXI
    generic map (
        MFB_REGIONS      => MFB_REGIONS,
        MFB_REGION_SIZE  => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE   => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH   => MFB_ITEM_WIDTH,
        AXI_RQUSER_WIDTH => AXI_RQUSER_WIDTH,
        AXI_DATA_WIDTH   => AXI_DATA_WIDTH,
        STRADDLING       => STRADDLING
    )
    port map (
        RQ_MFB_DATA    => conv_data,
        RQ_MFB_META    => conv_meta,
        RQ_MFB_SOF     => conv_sof,
        RQ_MFB_EOF     => conv_eof,
        RQ_MFB_SOF_POS => conv_sof_pos,
        RQ_MFB_EOF_POS => conv_eof_pos,
        RQ_MFB_SRC_RDY => conv_src_rdy,
        RQ_MFB_DST_RDY => conv_dst_rdy,

        RQ_AXI_DATA    => RQ_AXI_DATA,
        RQ_AXI_USER    => RQ_AXI_USER,
        RQ_AXI_LAST    => RQ_AXI_LAST,
        RQ_AXI_KEEP    => RQ_AXI_KEEP,
        RQ_AXI_VALID   => RQ_AXI_VALID,
        RQ_AXI_READY   => RQ_AXI_READY
    );

end architecture;
