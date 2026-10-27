-- pcie_adapter_tb.vhd: Cocotb top of PCIE_ADAPTER on the CQ and CC interfaces of an AMD PCIe IP
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.pcie_axi_meta_pack.all;

-- The RC and RQ interfaces are idle.
entity PCIE_ADAPTER_TB is
    generic (
        MFB_REGIONS      : natural := 2;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        AXI_CQUSER_WIDTH : natural := AXI_CQ512_USER_W;
        AXI_CCUSER_WIDTH : natural := AXI_CC512_USER_W;
        AXI_RQUSER_WIDTH : natural := AXI_RQ512_USER_W;
        AXI_RCUSER_WIDTH : natural := AXI_RC512_USER_W;
        AXI_STRADDLING   : boolean := true
    );
    port (
        CLK              : in  std_logic;
        RESET            : in  std_logic;

        CQ_AXI_DATA      : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CQ_AXI_USER      : in  std_logic_vector(AXI_CQUSER_WIDTH-1 downto 0);
        CQ_AXI_LAST      : in  std_logic;
        CQ_AXI_KEEP      : in  std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CQ_AXI_VALID     : in  std_logic;
        CQ_AXI_READY     : out std_logic;

        CQ_MFB_DATA      : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CQ_MFB_META      : out std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        CQ_MFB_SOF       : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_EOF       : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_SOF_POS   : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CQ_MFB_EOF_POS   : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CQ_MFB_SRC_RDY   : out std_logic;
        CQ_MFB_DST_RDY   : in  std_logic;

        CC_MFB_DATA      : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CC_MFB_META      : in  std_logic_vector(MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
        CC_MFB_SOF       : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_EOF       : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_SOF_POS   : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CC_MFB_EOF_POS   : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CC_MFB_SRC_RDY   : in  std_logic;
        CC_MFB_DST_RDY   : out std_logic;

        CC_AXI_DATA      : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CC_AXI_USER      : out std_logic_vector(AXI_CCUSER_WIDTH-1 downto 0);
        CC_AXI_LAST      : out std_logic;
        CC_AXI_KEEP      : out std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CC_AXI_VALID     : out std_logic;
        CC_AXI_READY     : in  std_logic
    );
end entity;

architecture FULL of PCIE_ADAPTER_TB is

    signal rc_mfb_dst_rdy : std_logic;

begin

    dut_i : entity work.PCIE_ADAPTER
    generic map (
        CQ_MFB_REGIONS     => MFB_REGIONS,
        CQ_MFB_REGION_SIZE => MFB_REGION_SIZE,
        CQ_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        CQ_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        RC_MFB_REGIONS     => MFB_REGIONS,
        RC_MFB_REGION_SIZE => MFB_REGION_SIZE,
        RC_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        RC_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        CC_MFB_REGIONS     => MFB_REGIONS,
        CC_MFB_REGION_SIZE => MFB_REGION_SIZE,
        CC_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        CC_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        RQ_MFB_REGIONS     => MFB_REGIONS,
        RQ_MFB_REGION_SIZE => MFB_REGION_SIZE,
        RQ_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        RQ_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        ENDPOINT_TYPE      => "USP",
        DEVICE             => "ULTRASCALE",
        AXI_DATA_WIDTH     => AXI_DATA_WIDTH,
        AXI_CQUSER_WIDTH   => AXI_CQUSER_WIDTH,
        AXI_CCUSER_WIDTH   => AXI_CCUSER_WIDTH,
        AXI_RQUSER_WIDTH   => AXI_RQUSER_WIDTH,
        AXI_RCUSER_WIDTH   => AXI_RCUSER_WIDTH,
        AXI_STRADDLING     => AXI_STRADDLING
    )
    port map (
        PCIE_CLK            => CLK,
        PCIE_RESET          => RESET,

        AVST_DOWN_DATA      => (others => '0'),
        AVST_DOWN_HDR       => (others => '0'),
        AVST_DOWN_PREFIX    => (others => '0'),
        AVST_DOWN_SOP       => (others => '0'),
        AVST_DOWN_EOP       => (others => '0'),
        AVST_DOWN_EMPTY     => (others => '0'),
        AVST_DOWN_BAR_RANGE => (others => '0'),
        AVST_DOWN_VALID     => (others => '0'),
        AVST_DOWN_READY     => open,

        AVST_UP_DATA        => open,
        AVST_UP_HDR         => open,
        AVST_UP_PREFIX      => open,
        AVST_UP_SOP         => open,
        AVST_UP_EOP         => open,
        AVST_UP_ERROR       => open,
        AVST_UP_VALID       => open,
        AVST_UP_READY       => '0',

        CRDT_DOWN_INIT_DONE => '0',
        CRDT_DOWN_UPDATE    => open,
        CRDT_DOWN_CNT_PH    => open,
        CRDT_DOWN_CNT_NPH   => open,
        CRDT_DOWN_CNT_CPLH  => open,
        CRDT_DOWN_CNT_PD    => open,
        CRDT_DOWN_CNT_NPD   => open,
        CRDT_DOWN_CNT_CPLD  => open,

        CRDT_UP_INIT_DONE   => '0',
        CRDT_UP_UPDATE      => (others => '0'),
        CRDT_UP_CNT_PH      => (others => '0'),
        CRDT_UP_CNT_NPH     => (others => '0'),
        CRDT_UP_CNT_CPLH    => (others => '0'),
        CRDT_UP_CNT_PD      => (others => '0'),
        CRDT_UP_CNT_NPD     => (others => '0'),
        CRDT_UP_CNT_CPLD    => (others => '0'),

        CQ_AXI_DATA         => CQ_AXI_DATA,
        CQ_AXI_USER         => CQ_AXI_USER,
        CQ_AXI_LAST         => CQ_AXI_LAST,
        CQ_AXI_KEEP         => CQ_AXI_KEEP,
        CQ_AXI_VALID        => CQ_AXI_VALID,
        CQ_AXI_READY        => CQ_AXI_READY,

        RC_AXI_DATA         => (others => '0'),
        RC_AXI_USER         => (others => '0'),
        RC_AXI_LAST         => '0',
        RC_AXI_KEEP         => (others => '0'),
        RC_AXI_VALID        => '0',
        RC_AXI_READY        => open,

        CC_AXI_DATA         => CC_AXI_DATA,
        CC_AXI_USER         => CC_AXI_USER,
        CC_AXI_LAST         => CC_AXI_LAST,
        CC_AXI_KEEP         => CC_AXI_KEEP,
        CC_AXI_VALID        => CC_AXI_VALID,
        CC_AXI_READY        => CC_AXI_READY,

        RQ_AXI_DATA         => open,
        RQ_AXI_USER         => open,
        RQ_AXI_LAST         => open,
        RQ_AXI_KEEP         => open,
        RQ_AXI_VALID        => open,
        RQ_AXI_READY        => '1',

        RQ_MFB_DATA         => (others => '0'),
        RQ_MFB_META         => (others => '0'),
        RQ_MFB_SOF          => (others => '0'),
        RQ_MFB_EOF          => (others => '0'),
        RQ_MFB_SOF_POS      => (others => '0'),
        RQ_MFB_EOF_POS      => (others => '0'),
        RQ_MFB_SRC_RDY      => '0',
        RQ_MFB_DST_RDY      => open,

        RC_MFB_DATA         => open,
        RC_MFB_META         => open,
        RC_MFB_SOF          => open,
        RC_MFB_EOF          => open,
        RC_MFB_SOF_POS      => open,
        RC_MFB_EOF_POS      => open,
        RC_MFB_SRC_RDY      => open,
        RC_MFB_DST_RDY      => rc_mfb_dst_rdy,

        CQ_MFB_DATA         => CQ_MFB_DATA,
        CQ_MFB_META         => CQ_MFB_META,
        CQ_MFB_SOF          => CQ_MFB_SOF,
        CQ_MFB_EOF          => CQ_MFB_EOF,
        CQ_MFB_SOF_POS      => CQ_MFB_SOF_POS,
        CQ_MFB_EOF_POS      => CQ_MFB_EOF_POS,
        CQ_MFB_SRC_RDY      => CQ_MFB_SRC_RDY,
        CQ_MFB_DST_RDY      => CQ_MFB_DST_RDY,

        CC_MFB_DATA         => CC_MFB_DATA,
        CC_MFB_META         => CC_MFB_META,
        CC_MFB_SOF          => CC_MFB_SOF,
        CC_MFB_EOF          => CC_MFB_EOF,
        CC_MFB_SOF_POS      => CC_MFB_SOF_POS,
        CC_MFB_EOF_POS      => CC_MFB_EOF_POS,
        CC_MFB_SRC_RDY      => CC_MFB_SRC_RDY,
        CC_MFB_DST_RDY      => CC_MFB_DST_RDY
    );

    rc_mfb_dst_rdy <= '1';

end architecture;
