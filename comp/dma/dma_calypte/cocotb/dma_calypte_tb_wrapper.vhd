-- dma_calypte_tb_wrapper.vhd: test-only wrapper merging the user MFB metadata of DMA_CALYPTE
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

-- Cocotb toplevel in place of DMA_CALYPTE: the user MFB metadata fields form one META port each, so the MFB driver and monitor bind by prefix.
entity DMA_CALYPTE_TB_WRAPPER is
    generic (
        DEVICE : string := "ULTRASCALE";

        USR_MFB_REGIONS     : natural := 1;
        USR_MFB_REGION_SIZE : natural := 4;
        USR_MFB_BLOCK_SIZE  : natural := 8;
        USR_MFB_ITEM_WIDTH  : natural := 8;
        HDR_META_WIDTH      : natural := 24;

        PCIE_RQ_MFB_REGIONS     : natural := 1;
        PCIE_RQ_MFB_REGION_SIZE : natural := 1;
        PCIE_RQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_RQ_MFB_ITEM_WIDTH  : natural := 32;

        PCIE_CQ_MFB_REGIONS     : natural := 1;
        PCIE_CQ_MFB_REGION_SIZE : natural := 1;
        PCIE_CQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_CQ_MFB_ITEM_WIDTH  : natural := 32;

        RX_CHANNELS         : natural := 2;
        RX_PTR_WIDTH        : natural := 16;
        USR_RX_PKT_SIZE_MAX : natural := 2**12;
        TRBUF_REG_EN        : boolean := false;
        PERF_CNTR_EN        : boolean := false;

        TX_CHANNELS         : natural := 2;
        TX_PTR_WIDTH        : natural := 13;
        USR_TX_PKT_SIZE_MAX : natural := 2**12;

        DSP_CNT_WIDTH      : natural := 64;
        RX_GEN_EN          : boolean := true;
        TX_GEN_EN          : boolean := true;
        ST_SP_DBG_SIGNAL_W : natural := 4;
        MI_WIDTH           : natural := 32
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- CHAN & HDR_META
        USR_RX_MFB_META    : in  std_logic_vector(log2(RX_CHANNELS) + HDR_META_WIDTH -1 downto 0);
        USR_RX_MFB_DATA    : in  std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        USR_RX_MFB_SOF     : in  std_logic_vector(USR_MFB_REGIONS -1 downto 0);
        USR_RX_MFB_EOF     : in  std_logic_vector(USR_MFB_REGIONS -1 downto 0);
        USR_RX_MFB_SOF_POS : in  std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0);
        USR_RX_MFB_EOF_POS : in  std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)) -1 downto 0);
        USR_RX_MFB_SRC_RDY : in  std_logic;
        USR_RX_MFB_DST_RDY : out std_logic;

        -- PKT_SIZE & CHAN & HDR_META
        USR_TX_MFB_META    : out std_logic_vector(log2(USR_TX_PKT_SIZE_MAX + 1) + log2(TX_CHANNELS) + HDR_META_WIDTH -1 downto 0);
        USR_TX_MFB_DATA    : out std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        USR_TX_MFB_SOF     : out std_logic_vector(USR_MFB_REGIONS -1 downto 0);
        USR_TX_MFB_EOF     : out std_logic_vector(USR_MFB_REGIONS -1 downto 0);
        USR_TX_MFB_SOF_POS : out std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0);
        USR_TX_MFB_EOF_POS : out std_logic_vector(USR_MFB_REGIONS*max(1, log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)) -1 downto 0);
        USR_TX_MFB_SRC_RDY : out std_logic;
        USR_TX_MFB_DST_RDY : in  std_logic;

        ST_SP_DBG_CHAN : out std_logic_vector(log2(TX_CHANNELS) -1 downto 0);
        ST_SP_DBG_META : out std_logic_vector(ST_SP_DBG_SIGNAL_W -1 downto 0);

        PCIE_RQ_MFB_DATA    : out std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_RQ_MFB_META    : out std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH -1 downto 0);
        PCIE_RQ_MFB_SOF     : out std_logic_vector(PCIE_RQ_MFB_REGIONS -1 downto 0);
        PCIE_RQ_MFB_EOF     : out std_logic_vector(PCIE_RQ_MFB_REGIONS -1 downto 0);
        PCIE_RQ_MFB_SOF_POS : out std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE)) -1 downto 0);
        PCIE_RQ_MFB_EOF_POS : out std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_RQ_MFB_SRC_RDY : out std_logic;
        PCIE_RQ_MFB_DST_RDY : in  std_logic;

        PCIE_CQ_MFB_DATA    : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CQ_MFB_META    : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
        PCIE_CQ_MFB_SOF     : in  std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_EOF     : in  std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_SOF_POS : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_EOF_POS : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_SRC_RDY : in  std_logic;
        PCIE_CQ_MFB_DST_RDY : out std_logic;

        MI_ADDR : in  std_logic_vector (MI_WIDTH -1 downto 0);
        MI_DWR  : in  std_logic_vector (MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector (MI_WIDTH/8-1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_DRD  : out std_logic_vector (MI_WIDTH -1 downto 0);
        MI_ARDY : out std_logic;
        MI_DRDY : out std_logic
    );
end entity;

architecture FULL of DMA_CALYPTE_TB_WRAPPER is

    signal usr_tx_mfb_meta_pkt_size : std_logic_vector(log2(USR_TX_PKT_SIZE_MAX + 1) -1 downto 0);
    signal usr_tx_mfb_meta_chan     : std_logic_vector(log2(TX_CHANNELS) -1 downto 0);
    signal usr_tx_mfb_meta_hdr_meta : std_logic_vector(HDR_META_WIDTH -1 downto 0);

begin

    USR_TX_MFB_META <= usr_tx_mfb_meta_pkt_size & usr_tx_mfb_meta_chan & usr_tx_mfb_meta_hdr_meta;

    dma_calypte_i : entity work.DMA_CALYPTE
    generic map (
        DEVICE => DEVICE,

        USR_MFB_REGIONS     => USR_MFB_REGIONS,
        USR_MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
        USR_MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
        USR_MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,
        HDR_META_WIDTH      => HDR_META_WIDTH,

        PCIE_RQ_MFB_REGIONS     => PCIE_RQ_MFB_REGIONS,
        PCIE_RQ_MFB_REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
        PCIE_RQ_MFB_BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
        PCIE_RQ_MFB_ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

        PCIE_CQ_MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
        PCIE_CQ_MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
        PCIE_CQ_MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
        PCIE_CQ_MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH,

        RX_CHANNELS         => RX_CHANNELS,
        RX_PTR_WIDTH        => RX_PTR_WIDTH,
        USR_RX_PKT_SIZE_MAX => USR_RX_PKT_SIZE_MAX,
        TRBUF_REG_EN        => TRBUF_REG_EN,
        PERF_CNTR_EN        => PERF_CNTR_EN,

        TX_CHANNELS         => TX_CHANNELS,
        TX_PTR_WIDTH        => TX_PTR_WIDTH,
        USR_TX_PKT_SIZE_MAX => USR_TX_PKT_SIZE_MAX,

        DSP_CNT_WIDTH      => DSP_CNT_WIDTH,
        RX_GEN_EN          => RX_GEN_EN,
        TX_GEN_EN          => TX_GEN_EN,
        ST_SP_DBG_SIGNAL_W => ST_SP_DBG_SIGNAL_W,
        MI_WIDTH           => MI_WIDTH
    )
    port map (
        CLK   => CLK,
        RESET => RESET,

        USR_RX_MFB_META_CHAN     => USR_RX_MFB_META(log2(RX_CHANNELS) + HDR_META_WIDTH -1 downto HDR_META_WIDTH),
        USR_RX_MFB_META_HDR_META => USR_RX_MFB_META(HDR_META_WIDTH -1 downto 0),

        USR_RX_MFB_DATA    => USR_RX_MFB_DATA,
        USR_RX_MFB_SOF     => USR_RX_MFB_SOF,
        USR_RX_MFB_EOF     => USR_RX_MFB_EOF,
        USR_RX_MFB_SOF_POS => USR_RX_MFB_SOF_POS,
        USR_RX_MFB_EOF_POS => USR_RX_MFB_EOF_POS,
        USR_RX_MFB_SRC_RDY => USR_RX_MFB_SRC_RDY,
        USR_RX_MFB_DST_RDY => USR_RX_MFB_DST_RDY,

        USR_TX_MFB_META_PKT_SIZE => usr_tx_mfb_meta_pkt_size,
        USR_TX_MFB_META_CHAN     => usr_tx_mfb_meta_chan,
        USR_TX_MFB_META_HDR_META => usr_tx_mfb_meta_hdr_meta,

        USR_TX_MFB_DATA    => USR_TX_MFB_DATA,
        USR_TX_MFB_SOF     => USR_TX_MFB_SOF,
        USR_TX_MFB_EOF     => USR_TX_MFB_EOF,
        USR_TX_MFB_SOF_POS => USR_TX_MFB_SOF_POS,
        USR_TX_MFB_EOF_POS => USR_TX_MFB_EOF_POS,
        USR_TX_MFB_SRC_RDY => USR_TX_MFB_SRC_RDY,
        USR_TX_MFB_DST_RDY => USR_TX_MFB_DST_RDY,

        ST_SP_DBG_CHAN => ST_SP_DBG_CHAN,
        ST_SP_DBG_META => ST_SP_DBG_META,

        PCIE_RQ_MFB_DATA    => PCIE_RQ_MFB_DATA,
        PCIE_RQ_MFB_META    => PCIE_RQ_MFB_META,
        PCIE_RQ_MFB_SOF     => PCIE_RQ_MFB_SOF,
        PCIE_RQ_MFB_EOF     => PCIE_RQ_MFB_EOF,
        PCIE_RQ_MFB_SOF_POS => PCIE_RQ_MFB_SOF_POS,
        PCIE_RQ_MFB_EOF_POS => PCIE_RQ_MFB_EOF_POS,
        PCIE_RQ_MFB_SRC_RDY => PCIE_RQ_MFB_SRC_RDY,
        PCIE_RQ_MFB_DST_RDY => PCIE_RQ_MFB_DST_RDY,

        PCIE_CQ_MFB_DATA    => PCIE_CQ_MFB_DATA,
        PCIE_CQ_MFB_META    => PCIE_CQ_MFB_META,
        PCIE_CQ_MFB_SOF     => PCIE_CQ_MFB_SOF,
        PCIE_CQ_MFB_EOF     => PCIE_CQ_MFB_EOF,
        PCIE_CQ_MFB_SOF_POS => PCIE_CQ_MFB_SOF_POS,
        PCIE_CQ_MFB_EOF_POS => PCIE_CQ_MFB_EOF_POS,
        PCIE_CQ_MFB_SRC_RDY => PCIE_CQ_MFB_SRC_RDY,
        PCIE_CQ_MFB_DST_RDY => PCIE_CQ_MFB_DST_RDY,

        MI_ADDR => MI_ADDR,
        MI_DWR  => MI_DWR,
        MI_BE   => MI_BE,
        MI_RD   => MI_RD,
        MI_WR   => MI_WR,
        MI_DRD  => MI_DRD,
        MI_ARDY => MI_ARDY,
        MI_DRDY => MI_DRDY
    );

end architecture;
