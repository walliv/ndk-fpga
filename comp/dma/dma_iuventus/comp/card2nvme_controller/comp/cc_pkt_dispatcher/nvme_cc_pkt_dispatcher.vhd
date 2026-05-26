-- nvme_cc_pkt_dispatcher.vhd:
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;

entity NVME_CC_PKT_DISPATCHER is
    generic (
        -- =========================================================================================
        -- RX MFB configuration
        -- =========================================================================================
        RX_REGIONS     : natural := 1;
        RX_REGION_SIZE : natural := 1;
        RX_BLOCK_SIZE  : natural := 64;
        RX_ITEM_WIDTH  : natural := 8;

        -- =========================================================================================
        -- TX MFB configuration
        -- =========================================================================================
        TX_REGIONS     : natural := 2;
        TX_REGION_SIZE : natural := 1;
        TX_BLOCK_SIZE  : natural := 8;
        TX_ITEM_WIDTH  : natural := 32;

        DEVICE : string := "ULTRASCALE"
        );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- MFB input interface
        -- =========================================================================================
        RX_MFB_DATA    : in  std_logic_vector(RX_REGIONS*RX_REGION_SIZE*RX_BLOCK_SIZE*RX_ITEM_WIDTH-1 downto 0);
        RX_MFB_SOF     : in  std_logic_vector(RX_REGIONS -1 downto 0);
        RX_MFB_EOF     : in  std_logic_vector(RX_REGIONS -1 downto 0);
        RX_MFB_SOF_POS : in  std_logic_vector(RX_REGIONS*maximum(1, log2(RX_REGION_SIZE)) -1 downto 0);
        RX_MFB_EOF_POS : in  std_logic_vector(RX_REGIONS*log2(RX_REGION_SIZE*RX_BLOCK_SIZE) -1 downto 0);
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- MFB output interface
        -- =========================================================================================
        TX_MFB_DATA    : out std_logic_vector(TX_REGIONS*TX_REGION_SIZE*TX_BLOCK_SIZE*TX_ITEM_WIDTH-1 downto 0);
        TX_MFB_META    : out std_logic_vector(TX_REGIONS*PCIE_CC_META_WIDTH - 1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(TX_REGIONS-1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(TX_REGIONS-1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(TX_REGIONS*max(1, log2(TX_REGION_SIZE))-1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(TX_REGIONS*max(1, log2(TX_REGION_SIZE*TX_BLOCK_SIZE))-1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Header manager MVB interface
        -- =========================================================================================
        PCIE_HDR_DATA    : in  std_logic_vector(PCIE_META_CPL_HDR_W -1 downto 0);
        PCIE_HDR_SRC_RDY : in  std_logic;
        PCIE_HDR_DST_RDY : out std_logic);
end entity;

architecture FULL of NVME_CC_PKT_DISPATCHER is
    constant BUFF_REGIONS     : positive := 1;
    constant BUFF_REGION_SIZE : positive := 1;
    constant BUFF_BLOCK_SIZE  : positive := 128;
    constant BUFF_ITEM_WIDTH  : positive := 8;

    constant BUFF_MFB_WIDTH : positive := BUFF_REGIONS*BUFF_REGION_SIZE*BUFF_BLOCK_SIZE*BUFF_ITEM_WIDTH;

    signal trbuf_mfb_data : std_logic_vector(BUFF_MFB_WIDTH -1 downto 0);
    signal trbuf_mfb_sof : std_logic;
    signal trbuf_mfb_eof : std_logic;
    signal trbuf_mfb_eof_pos : std_logic_vector(BUFF_REGIONS*log2(BUFF_REGION_SIZE*BUFF_BLOCK_SIZE) -1 downto 0);
    signal trbuf_mfb_src_rdy : std_logic;
    signal trbuf_mfb_dst_rdy : std_logic;

    signal pcie_hdr_dst_rdy_n : std_logic;
    signal hdr_fifo_do : std_logic_vector(PCIE_HDR_DATA'range);
    signal hdr_fifo_rd : std_logic;
    signal hdr_fifo_empty : std_logic;
begin
    cc_trans_buffer_i : entity work.RX_DMA_CALYPTE_TRANS_BUFFER
        generic map (
            BUFFERED_DATA_SIZE => BUFF_MFB_WIDTH/8,
            REG_OUT_EN         => true,
            RX_REGION_SIZE     => RX_REGION_SIZE,
            RX_BLOCK_SIZE      => RX_BLOCK_SIZE,
            RX_ITEM_WIDTH      => RX_ITEM_WIDTH)
        port map (
            CLK            => CLK,
            RST            => RST,

            RX_MFB_DATA    => RX_MFB_DATA,
            RX_MFB_SOF     => RX_MFB_SOF(0),
            RX_MFB_EOF     => RX_MFB_EOF(0),
            RX_MFB_EOF_POS => RX_MFB_EOF_POS,
            RX_MFB_SRC_RDY => RX_MFB_SRC_RDY,
            RX_MFB_DST_RDY => RX_MFB_DST_RDY,

            TX_MFB_DATA    => trbuf_mfb_data,
            TX_MFB_SOF_POS => open,
            TX_MFB_SOF     => trbuf_mfb_sof,
            TX_MFB_EOF     => trbuf_mfb_eof,
            TX_MFB_EOF_POS => trbuf_mfb_eof_pos,
            TX_MFB_SRC_RDY => trbuf_mfb_src_rdy,
            TX_MFB_DST_RDY => trbuf_mfb_dst_rdy);

    PCIE_HDR_DST_RDY <= not pcie_hdr_dst_rdy_n;

    pcie_hdr_fifo_i : entity work.FIFOX
        generic map (
            DATA_WIDTH          => PCIE_META_CPL_HDR_W,
            -- TODO: This size needs to be probably more tuned
            --      This FIFO just needs to fit the headers for the completion of the maximum size
            --      divided by 128B -> MPS / 128
            ITEMS               => 2**8,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 2,
            ALMOST_EMPTY_OFFSET => 2,
            FAKE_FIFO           => false)
        port map (
            CLK    => CLK,
            RESET  => RST,

            DI     => PCIE_HDR_DATA,
            WR     => PCIE_HDR_SRC_RDY,
            FULL   => pcie_hdr_dst_rdy_n,

            AFULL  => open,
            STATUS => open,

            DO     => hdr_fifo_do,
            RD     => hdr_fifo_rd,
            EMPTY  => hdr_fifo_empty,

            AEMPTY => open);

    cc_hdr_insertor_i : entity work.NVME_CC_HDR_INSERTOR
        generic map (
            RX_REGION_SIZE => BUFF_REGION_SIZE,
            RX_BLOCK_SIZE  => BUFF_BLOCK_SIZE,
            RX_ITEM_WIDTH  => BUFF_ITEM_WIDTH,

            TX_REGIONS     => TX_REGIONS,
            TX_REGION_SIZE => TX_REGION_SIZE,
            TX_BLOCK_SIZE  => TX_BLOCK_SIZE,
            TX_ITEM_WIDTH  => TX_ITEM_WIDTH,

            DEVICE         => DEVICE)
        port map (
            CLK              => CLK,
            RST              => RST,

            RX_MFB_DATA      => trbuf_mfb_data,
            RX_MFB_SOF       => trbuf_mfb_sof,
            RX_MFB_EOF       => trbuf_mfb_eof,
            RX_MFB_EOF_POS   => trbuf_mfb_eof_pos,
            RX_MFB_SRC_RDY   => trbuf_mfb_src_rdy,
            RX_MFB_DST_RDY   => trbuf_mfb_dst_rdy,

            TX_MFB_DATA      => TX_MFB_DATA,
            TX_MFB_META      => TX_MFB_META,
            TX_MFB_SOF       => TX_MFB_SOF,
            TX_MFB_EOF       => TX_MFB_EOF,
            TX_MFB_SOF_POS   => TX_MFB_SOF_POS,
            TX_MFB_EOF_POS   => TX_MFB_EOF_POS,
            TX_MFB_SRC_RDY   => TX_MFB_SRC_RDY,
            TX_MFB_DST_RDY   => TX_MFB_DST_RDY,

            PCIE_HDR         => hdr_fifo_do,
            PCIE_HDR_SRC_RDY => not hdr_fifo_empty,
            PCIE_HDR_DST_RDY => hdr_fifo_rd);
end architecture;
