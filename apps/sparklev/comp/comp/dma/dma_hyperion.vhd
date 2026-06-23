-- dma_hyperion.vhd: wrapper for DMA Hyperion module
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

use work.dma_bus_pack.all;
use work.pcie_meta_pack.all;

entity DMA_HYPERION is
    generic(
        DEVICE : string := "STRATIX10";

        DMA_STREAMS : natural := 1;

        DMA_MFB_REGIONS     : natural := 1;
        DMA_MFB_REGION_SIZE : natural := 8;
        DMA_MFB_BLOCK_SIZE  : natural := 8;
        DMA_MFB_ITEM_WIDTH  : natural := 8;

        PCIE_RQ_MFB_REGIONS     : natural := 2;
        PCIE_RQ_MFB_REGION_SIZE : natural := 1;
        PCIE_RQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_RQ_MFB_ITEM_WIDTH  : natural := 32;

        PCIE_RC_MFB_REGIONS     : natural := 2;
        PCIE_RC_MFB_REGION_SIZE : natural := 1;
        PCIE_RC_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_RC_MFB_ITEM_WIDTH  : natural := 32;

        PCIE_CQ_MFB_REGIONS     : natural := 2;
        PCIE_CQ_MFB_REGION_SIZE : natural := 1;
        PCIE_CQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_CQ_MFB_ITEM_WIDTH  : natural := 32;

        PCIE_CC_MFB_REGIONS     : natural := 2;
        PCIE_CC_MFB_REGION_SIZE : natural := 1;
        PCIE_CC_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_CC_MFB_ITEM_WIDTH  : natural := 32;

        HDR_META_WIDTH : natural := 12;
        PKT_SIZE_MAX   : natural := 2**12;

        C2H_CHANNELS  : natural := 8;
        C2H_PTR_WIDTH : natural := 16;

        H2C_CHANNELS  : natural := 8;
        H2C_PTR_WIDTH : natural := 16;

        DSP_CNT_WIDTH : natural := 64;

        C2H_GEN_EN : boolean := TRUE;
        H2C_GEN_EN : boolean := TRUE;

        DMA_DEBUG_ENABLE : boolean := FALSE;

        MI_WIDTH : natural := 32;

        HBM_DATA_W  : natural := 256;
        HBM_ADDR_W  : natural := 34;
        HBM_BURST_W : natural := 2;
        HBM_ID_W    : natural := 6;
        HBM_LEN_W   : natural := 4;
        HBM_SIZE_W  : natural := 3;
        HBM_RESP_W  : natural := 2
    );
    port(
        -- =====================================================================
        --  Clock and Reset
        -- =====================================================================
        -- Clock for MI interface
        MI_CLK   : in std_logic;
        MI_RESET : in std_logic;

        -- Clock and reset for the DMA core
        DMA_CLK   : in std_logic_vector(DMA_STREAMS -1 downto 0);
        DMA_RESET : in std_logic_vector(DMA_STREAMS -1 downto 0);

        -- =========================================================================================
        -- HBM AXI3 interface (single port)
        -- =========================================================================================
        HBM_AXI_AWID    : out std_logic_vector(HBM_ID_W-1 downto 0);
        HBM_AXI_AWADDR  : out std_logic_vector(HBM_ADDR_W-1 downto 0);
        HBM_AXI_AWLEN   : out std_logic_vector(HBM_LEN_W-1 downto 0);
        HBM_AXI_AWSIZE  : out std_logic_vector(HBM_SIZE_W-1 downto 0);
        HBM_AXI_AWBURST : out std_logic_vector(HBM_BURST_W-1 downto 0);
        HBM_AXI_AWVALID : out std_logic;
        HBM_AXI_AWREADY : in  std_logic;

        HBM_AXI_WDATA        : out std_logic_vector(HBM_DATA_W-1 downto 0);
        HBM_AXI_WSTRB        : out std_logic_vector((HBM_DATA_W/8)-1 downto 0);
        HBM_AXI_WDATA_PARITY : out std_logic_vector((HBM_DATA_W/8)-1 downto 0);
        HBM_AXI_WLAST        : out std_logic;
        HBM_AXI_WVALID       : out std_logic;
        HBM_AXI_WREADY       : in  std_logic;

        HBM_AXI_BID    : in  std_logic_vector(HBM_ID_W-1 downto 0);
        HBM_AXI_BRESP  : in  std_logic_vector(HBM_RESP_W-1 downto 0);
        HBM_AXI_BVALID : in  std_logic;
        HBM_AXI_BREADY : out std_logic;

        HBM_AXI_ARID    : out std_logic_vector(HBM_ID_W-1 downto 0);
        HBM_AXI_ARADDR  : out std_logic_vector(HBM_ADDR_W-1 downto 0);
        HBM_AXI_ARLEN   : out std_logic_vector(HBM_LEN_W-1 downto 0);
        HBM_AXI_ARSIZE  : out std_logic_vector(HBM_SIZE_W-1 downto 0);
        HBM_AXI_ARBURST : out std_logic_vector(HBM_BURST_W-1 downto 0);
        HBM_AXI_ARVALID : out std_logic;
        HBM_AXI_ARREADY : in  std_logic;

        HBM_AXI_RID          : in  std_logic_vector(HBM_ID_W-1 downto 0);
        HBM_AXI_RDATA        : in  std_logic_vector(HBM_DATA_W-1 downto 0);
        HBM_AXI_RDATA_PARITY : in  std_logic_vector((HBM_DATA_W/8)-1 downto 0);
        HBM_AXI_RRESP        : in  std_logic_vector(HBM_RESP_W-1 downto 0);
        HBM_AXI_RLAST        : in  std_logic;
        HBM_AXI_RVALID       : in  std_logic;
        HBM_AXI_RREADY       : out std_logic;

        -- =====================================================================
        --  PCIe-side interfaces
        -- =====================================================================
        -- Upstream MFB interface (for sending data to PCIe Endpoints)
        PCIE_RQ_MFB_DATA    : out slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH -1 downto 0) := (others => (others => '0'));
        PCIE_RQ_MFB_META    : out slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH -1 downto 0);
        PCIE_RQ_MFB_SOF     : out slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_RQ_MFB_REGIONS -1 downto 0)                                                                       := (others => (others => '0'));
        PCIE_RQ_MFB_EOF     : out slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_RQ_MFB_REGIONS -1 downto 0)                                                                       := (others => (others => '0'));
        PCIE_RQ_MFB_SOF_POS : out slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE)) -1 downto 0)                                 := (others => (others => '0'));
        PCIE_RQ_MFB_EOF_POS : out slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE)) -1 downto 0)          := (others => (others => '0'));
        PCIE_RQ_MFB_SRC_RDY : out std_logic_vector(DMA_STREAMS -1 downto 0)                                                                                                    := (others => '0');
        PCIE_RQ_MFB_DST_RDY : in  std_logic_vector(DMA_STREAMS -1 downto 0);

        -- CQ MFB interface (receiving data from PCIe endpoint, DMA Calypte only)
        PCIE_CQ_MFB_DATA    : in  slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH -1 downto 0);
        PCIE_CQ_MFB_META    : in  slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
        PCIE_CQ_MFB_SOF     : in  slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_EOF     : in  slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_SOF_POS : in  slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_EOF_POS : in  slv_array_t (DMA_STREAMS -1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_SRC_RDY : in  std_logic_vector(DMA_STREAMS -1 downto 0);
        PCIE_CQ_MFB_DST_RDY : out std_logic_vector(DMA_STREAMS -1 downto 0) := (others => '0');

        -- =============================================================================================
        -- MI control interface
        -- =============================================================================================
        MI_ADDR : in  slv_array_t(DMA_STREAMS -1 downto 0)(32 -1 downto 0);
        MI_DWR  : in  slv_array_t(DMA_STREAMS -1 downto 0)(32 -1 downto 0);
        MI_BE   : in  slv_array_t(DMA_STREAMS -1 downto 0)(32/8 -1 downto 0);
        MI_RD   : in  std_logic_vector(DMA_STREAMS -1 downto 0);
        MI_WR   : in  std_logic_vector(DMA_STREAMS -1 downto 0);
        MI_DRD  : out slv_array_t(DMA_STREAMS -1 downto 0)(32 -1 downto 0);
        MI_ARDY : out std_logic_vector(DMA_STREAMS -1 downto 0);
        MI_DRDY : out std_logic_vector(DMA_STREAMS -1 downto 0)
    );
end entity;

architecture FULL of DMA_HYPERION is

    -- =============================================================================================
    -- Setup constants
    -- =============================================================================================
    constant OUT_PIPE_EN : boolean := TRUE;

    constant MFB_LOOPBACK_EN    : boolean := TRUE;
    constant LATENCY_METER_EN   : boolean := DMA_DEBUG_ENABLE;
    constant TX_DMA_DBG_CORE_EN : boolean := DMA_DEBUG_ENABLE;

    constant ST_SP_DBG_META_WIDTH : natural := 4;

    --==============================================================================================
    --  MI Async and Splitting
    --==============================================================================================
    constant MI_SPLIT_PORTS : natural := 3;
    constant MI_SPLIT_BASES : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH-1 downto 0) := (
        0 => X"00000000",               -- RX_DMA_CALYPTE
        1 => X"00100000",               -- H2C_DMA_HYPERION
        2 => X"00200000"                -- C2H_HBM_READER
    );
    constant MI_SPLIT_ADDR_MASK : std_logic_vector(MI_WIDTH -1 downto 0) := X"00300000";

    -- MI split for DMA 0 and TSU
    signal mi_dmagen_dwr  : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(32-1 downto 0);
    signal mi_dmagen_addr : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(32-1 downto 0);
    signal mi_dmagen_be   : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(4-1 downto 0);
    signal mi_dmagen_rd   : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);
    signal mi_dmagen_wr   : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);
    signal mi_dmagen_drd  : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(32-1 downto 0);
    signal mi_dmagen_ardy : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);
    signal mi_dmagen_drdy : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);

    -- MI clocked on DMA_CLK after CDC
    signal mi_split_dwr  : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(32-1 downto 0);
    signal mi_split_addr : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(32-1 downto 0);
    signal mi_split_be   : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(4-1 downto 0);
    signal mi_split_rd   : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_wr   : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_drd  : slv_array_2d_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0)(32-1 downto 0);
    signal mi_split_ardy : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_drdy : slv_array_t(DMA_STREAMS -1 downto 0)(MI_SPLIT_PORTS -1 downto 0);


    -- =============================================================================================
    -- Piped PCIE interfaces
    -- =============================================================================================
    signal pcie_rq_mfb_data_piped    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_rq_mfb_meta_piped    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH -1 downto 0);
    signal pcie_rq_mfb_sof_piped     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS -1 downto 0);
    signal pcie_rq_mfb_eof_piped     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS -1 downto 0);
    signal pcie_rq_mfb_sof_pos_piped : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE)) -1 downto 0);
    signal pcie_rq_mfb_eof_pos_piped : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE)) -1 downto 0);
    signal pcie_rq_mfb_src_rdy_piped : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_rq_mfb_dst_rdy_piped : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal pcie_cq_mfb_data_piped    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_cq_mfb_meta_piped    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
    signal pcie_cq_mfb_sof_piped     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS -1 downto 0);
    signal pcie_cq_mfb_eof_piped     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS -1 downto 0);
    signal pcie_cq_mfb_sof_pos_piped : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0);
    signal pcie_cq_mfb_eof_pos_piped : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
    signal pcie_cq_mfb_src_rdy_piped : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_cq_mfb_dst_rdy_piped : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal pcie_cq_mfb_be_piped : slv_array_t(DMA_STREAMS-1 downto 0)((PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH)/8 -1 downto 0);

    -- =============================================================================================
    -- Debugging signals
    -- =============================================================================================
    signal st_sp_dbg_chan  : slv_array_t(DMA_STREAMS -1 downto 0)(log2(H2C_CHANNELS) -1 downto 0);
    signal st_sp_dbg_meta  : slv_array_t(DMA_STREAMS -1 downto 0)(ST_SP_DBG_META_WIDTH -1 downto 0);
    signal force_reset_dbg : std_logic_vector(DMA_STREAMS-1 downto 0);

    -- =============================================================================================
    -- C2H reader to RX DMA interface
    -- =============================================================================================
    signal c2h_reader_meta          : slv_array_t(DMA_STREAMS -1 downto 0)(HDR_META_WIDTH + log2(C2H_CHANNELS) -1 downto 0);
    signal c2h_reader_meta_hdr_meta : slv_array_t(DMA_STREAMS -1 downto 0)(HDR_META_WIDTH -1 downto 0);
    signal c2h_reader_meta_chan     : slv_array_t(DMA_STREAMS -1 downto 0)(log2(C2H_CHANNELS) -1 downto 0);
    signal c2h_reader_data          : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
    signal c2h_reader_sof           : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS -1 downto 0);
    signal c2h_reader_eof           : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS -1 downto 0);
    signal c2h_reader_sof_pos       : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE)) -1 downto 0);
    signal c2h_reader_eof_pos       : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)) -1 downto 0);
    signal c2h_reader_src_rdy       : std_logic_vector(DMA_STREAMS -1 downto 0);
    signal c2h_reader_dst_rdy       : std_logic_vector(DMA_STREAMS -1 downto 0);

    -- =============================================================================================
    -- C2H stop-request signals (RX_DMA_CALYPTE ↔ DMA_PTR_UPDATER)
    -- =============================================================================================
    signal c2h_stop_req_buff_ba : std_logic_vector(64-1 downto 0);
    signal c2h_stop_req_p2p_en  : std_logic;
    signal c2h_stop_req_hdp     : std_logic_vector(C2H_PTR_WIDTH-1 downto 0);
    signal c2h_stop_req_hhp     : std_logic_vector(C2H_PTR_WIDTH-1 downto 0);
    signal c2h_stop_req_en      : std_logic;
    signal c2h_stop_req_ack     : std_logic;

    -- =============================================================================================
    -- C2H DMA RQ MFB (RX_DMA_CALYPTE → MFB_MERGER_SIMPLE)
    -- =============================================================================================
    signal c2h_dma_rq_mfb_data    : std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH-1 downto 0);
    signal c2h_dma_rq_mfb_meta    : std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
    signal c2h_dma_rq_mfb_sof     : std_logic_vector(PCIE_RQ_MFB_REGIONS-1 downto 0);
    signal c2h_dma_rq_mfb_eof     : std_logic_vector(PCIE_RQ_MFB_REGIONS-1 downto 0);
    signal c2h_dma_rq_mfb_sof_pos : std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE))-1 downto 0);
    signal c2h_dma_rq_mfb_eof_pos : std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE))-1 downto 0);
    signal c2h_dma_rq_mfb_src_rdy : std_logic;
    signal c2h_dma_rq_mfb_dst_rdy : std_logic;

    -- =============================================================================================
    -- PTR_UPD RQ MFB (DMA_PTR_UPDATER → MFB_MERGER_SIMPLE)
    -- =============================================================================================
    signal ptr_upd_rq_mfb_data    : std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH-1 downto 0);
    signal ptr_upd_rq_mfb_meta    : std_logic_vector(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
    signal ptr_upd_rq_mfb_sof     : std_logic_vector(PCIE_RQ_MFB_REGIONS-1 downto 0);
    signal ptr_upd_rq_mfb_eof     : std_logic_vector(PCIE_RQ_MFB_REGIONS-1 downto 0);
    signal ptr_upd_rq_mfb_sof_pos : std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE))-1 downto 0);
    signal ptr_upd_rq_mfb_eof_pos : std_logic_vector(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE))-1 downto 0);
    signal ptr_upd_rq_mfb_src_rdy : std_logic;
    signal ptr_upd_rq_mfb_dst_rdy : std_logic;
begin
    assert (PCIE_CQ_MFB_REGIONS = 1)
        report "DMA_HYPERION: PCIE_CQ_MFB_REGIONS must be 1 for H2C_DMA_HYPERION."
        severity FAILURE;

    dma_pcie_endp_g : for i in 0 to DMA_STREAMS-1 generate

        --==========================================================================================
        --  MI Splitting and CDC
        --==========================================================================================
        -- splitting the MI bus for the DMA Calypte and TX Testing core.
        -- The Splitter only makes sense when TX direction is enabled, while at that case, both, the
        -- MFB_LOOPBACK and the TX_DEBUG_CORE can be enabled.
        mi_gen_spl_i : entity work.MI_SPLITTER_PLUS_GEN
            generic map(
                ADDR_WIDTH => MI_WIDTH,
                DATA_WIDTH => MI_WIDTH,
                META_WIDTH => 0,
                PORTS      => MI_SPLIT_PORTS,
                PIPE_OUT   => (others => FALSE),

                ADDR_MASK  => MI_SPLIT_ADDR_MASK,
                ADDR_BASES => MI_SPLIT_PORTS,
                ADDR_BASE  => MI_SPLIT_BASES,

                DEVICE => DEVICE
            )
            port map(
                CLK   => MI_CLK,
                RESET => MI_RESET,

                RX_DWR  => MI_DWR(i),
                RX_MWR  => (others => '0'),
                RX_ADDR => MI_ADDR(i),
                RX_BE   => MI_BE(i),
                RX_RD   => MI_RD(i),
                RX_WR   => MI_WR(i),
                RX_ARDY => MI_ARDY(i),
                RX_DRD  => MI_DRD(i),
                RX_DRDY => MI_DRDY(i),

                TX_DWR  => mi_dmagen_dwr(i),
                TX_MWR  => open,
                TX_ADDR => mi_dmagen_addr(i),
                TX_BE   => mi_dmagen_be(i),
                TX_RD   => mi_dmagen_rd(i),
                TX_WR   => mi_dmagen_wr(i),
                TX_ARDY => mi_dmagen_ardy(i),
                TX_DRD  => mi_dmagen_drd(i),
                TX_DRDY => mi_dmagen_drdy(i));

        -- syncing the MI data to the clock which drives the DMA components
        mi_async_g : for p in 0 to MI_SPLIT_PORTS-1 generate
            mi_async_i : entity work.MI_ASYNC
                generic map(
                    ADDR_WIDTH => MI_WIDTH,
                    DATA_WIDTH => MI_WIDTH,
                    DEVICE     => DEVICE
                )
                port map(
                    CLK_M     => MI_CLK,
                    RESET_M   => MI_RESET,
                    MI_M_ADDR => mi_dmagen_addr(i)(p),
                    MI_M_DWR  => mi_dmagen_dwr(i)(p),
                    MI_M_BE   => mi_dmagen_be(i)(p),
                    MI_M_RD   => mi_dmagen_rd(i)(p),
                    MI_M_WR   => mi_dmagen_wr(i)(p),
                    MI_M_ARDY => mi_dmagen_ardy(i)(p),
                    MI_M_DRDY => mi_dmagen_drdy(i)(p),
                    MI_M_DRD  => mi_dmagen_drd(i)(p),

                    CLK_S     => DMA_CLK(i),
                    RESET_S   => DMA_RESET(i),
                    MI_S_ADDR => mi_split_addr(i)(p),
                    MI_S_DWR  => mi_split_dwr(i)(p),
                    MI_S_BE   => mi_split_be(i)(p),
                    MI_S_RD   => mi_split_rd(i)(p),
                    MI_S_WR   => mi_split_wr(i)(p),
                    MI_S_ARDY => mi_split_ardy(i)(p),
                    MI_S_DRDY => mi_split_drdy(i)(p),
                    MI_S_DRD  => mi_split_drd(i)(p)
                );
        end generate;

        -- =========================================================================================
        -- DMA Hyperion Module
        -- =========================================================================================
        pcie_cq_mfb_be_piped(i) <= pcie_cq_mfb_meta_piped(i)(PCIE_CQ_META_BE);

        h2c_dma_hyperion_i : entity work.H2C_DMA_HYPERION
        generic map (
            DEVICE           => DEVICE,
            MI_WIDTH         => MI_WIDTH,

            HBM_DATA_WIDTH   => HBM_DATA_W,
            HBM_ADDR_WIDTH   => HBM_ADDR_W,
            HBM_BURST_WIDTH  => HBM_BURST_W,
            HBM_ID_WIDTH     => HBM_ID_W,
            HBM_LEN_WIDTH    => HBM_LEN_W,
            HBM_SIZE_WIDTH   => HBM_SIZE_W,
            HBM_RESP_WIDTH   => HBM_RESP_W,

            PCIE_CQ_MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
            PCIE_CQ_MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
            PCIE_CQ_MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
            PCIE_CQ_MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH
        )
        port map (
            CLK   => DMA_CLK(i),
            RESET => DMA_RESET(i),

            PCIE_CQ_MFB_BE      => pcie_cq_mfb_be_piped(i),
            PCIE_CQ_MFB_DATA    => pcie_cq_mfb_data_piped(i),
            PCIE_CQ_MFB_META    => pcie_cq_mfb_meta_piped(i),
            PCIE_CQ_MFB_SOF     => pcie_cq_mfb_sof_piped(i),
            PCIE_CQ_MFB_EOF     => pcie_cq_mfb_eof_piped(i),
            PCIE_CQ_MFB_SOF_POS => pcie_cq_mfb_sof_pos_piped(i),
            PCIE_CQ_MFB_EOF_POS => pcie_cq_mfb_eof_pos_piped(i),
            PCIE_CQ_MFB_SRC_RDY => pcie_cq_mfb_src_rdy_piped(i),
            PCIE_CQ_MFB_DST_RDY => pcie_cq_mfb_dst_rdy_piped(i),

            HBM_AXI_AWID    => HBM_AXI_AWID,
            HBM_AXI_AWADDR  => HBM_AXI_AWADDR,
            HBM_AXI_AWLEN   => HBM_AXI_AWLEN,
            HBM_AXI_AWSIZE  => HBM_AXI_AWSIZE,
            HBM_AXI_AWBURST => HBM_AXI_AWBURST,
            HBM_AXI_AWVALID => HBM_AXI_AWVALID,
            HBM_AXI_AWREADY => HBM_AXI_AWREADY,

            HBM_AXI_WDATA        => HBM_AXI_WDATA,
            HBM_AXI_WSTRB        => HBM_AXI_WSTRB,
            HBM_AXI_WDATA_PARITY => HBM_AXI_WDATA_PARITY,
            HBM_AXI_WLAST        => HBM_AXI_WLAST,
            HBM_AXI_WVALID       => HBM_AXI_WVALID,
            HBM_AXI_WREADY       => HBM_AXI_WREADY,

            HBM_AXI_BID    => HBM_AXI_BID,
            HBM_AXI_BRESP  => HBM_AXI_BRESP,
            HBM_AXI_BVALID => HBM_AXI_BVALID,
            HBM_AXI_BREADY => HBM_AXI_BREADY,

            MI_ADDR => mi_split_addr(i)(1),
            MI_DWR  => mi_split_dwr(i)(1),
            MI_BE   => mi_split_be(i)(1),
            MI_RD   => mi_split_rd(i)(1),
            MI_WR   => mi_split_wr(i)(1),
            MI_DRD  => mi_split_drd(i)(1),
            MI_ARDY => mi_split_ardy(i)(1),
            MI_DRDY => mi_split_drdy(i)(1)
        );

        c2h_hbm_reader_i : entity work.C2H_HBM_READER
        generic map (
            MI_WIDTH            => MI_WIDTH,

            HBM_DATA_WIDTH      => HBM_DATA_W,
            HBM_ADDR_WIDTH      => HBM_ADDR_W,
            HBM_BURST_WIDTH     => HBM_BURST_W,
            HBM_ID_WIDTH        => HBM_ID_W,
            HBM_LEN_WIDTH       => HBM_LEN_W,
            HBM_SIZE_WIDTH      => HBM_SIZE_W,
            HBM_RESP_WIDTH      => HBM_RESP_W,

            MFB_REGIONS         => DMA_MFB_REGIONS,
            MFB_REGION_SIZE     => DMA_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE      => DMA_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH      => DMA_MFB_ITEM_WIDTH,

            HDR_META_WIDTH      => HDR_META_WIDTH,
            CHANNELS            => C2H_CHANNELS,

            DEVICE              => DEVICE
        )
        port map (
            CLK   => DMA_CLK(i),
            RESET => DMA_RESET(i),

            MI_ADDR => mi_split_addr(i)(2),
            MI_DWR  => mi_split_dwr(i)(2),
            MI_BE   => mi_split_be(i)(2),
            MI_RD   => mi_split_rd(i)(2),
            MI_WR   => mi_split_wr(i)(2),
            MI_DRD  => mi_split_drd(i)(2),
            MI_ARDY => mi_split_ardy(i)(2),
            MI_DRDY => mi_split_drdy(i)(2),

            HBM_AXI_ARID    => HBM_AXI_ARID,
            HBM_AXI_ARADDR  => HBM_AXI_ARADDR,
            HBM_AXI_ARLEN   => HBM_AXI_ARLEN,
            HBM_AXI_ARSIZE  => HBM_AXI_ARSIZE,
            HBM_AXI_ARBURST => HBM_AXI_ARBURST,
            HBM_AXI_ARVALID => HBM_AXI_ARVALID,
            HBM_AXI_ARREADY => HBM_AXI_ARREADY,

            HBM_AXI_RID          => HBM_AXI_RID,
            HBM_AXI_RDATA        => HBM_AXI_RDATA,
            HBM_AXI_RDATA_PARITY => HBM_AXI_RDATA_PARITY,
            HBM_AXI_RRESP        => HBM_AXI_RRESP,
            HBM_AXI_RLAST        => HBM_AXI_RLAST,
            HBM_AXI_RVALID       => HBM_AXI_RVALID,
            HBM_AXI_RREADY       => HBM_AXI_RREADY,

            USER_RX_MFB_META          => c2h_reader_meta(i),
            USER_RX_MFB_DATA          => c2h_reader_data(i),
            USER_RX_MFB_SOF           => c2h_reader_sof(i),
            USER_RX_MFB_EOF           => c2h_reader_eof(i),
            USER_RX_MFB_SOF_POS       => c2h_reader_sof_pos(i),
            USER_RX_MFB_EOF_POS       => c2h_reader_eof_pos(i),
            USER_RX_MFB_SRC_RDY       => c2h_reader_src_rdy(i),
            USER_RX_MFB_DST_RDY       => c2h_reader_dst_rdy(i)
        );

        -- Deparse compound USER_RX_MFB_META into separate fields for RX_DMA_CALYPTE
        c2h_reader_meta_chan(i)     <= c2h_reader_meta(i)(log2(C2H_CHANNELS)-1 downto 0);
        c2h_reader_meta_hdr_meta(i) <= c2h_reader_meta(i)(HDR_META_WIDTH+log2(C2H_CHANNELS)-1 downto log2(C2H_CHANNELS));

        rx_dma_calypte_i : entity work.RX_DMA_CALYPTE
        generic map (
            DEVICE   => DEVICE,
            MI_WIDTH => MI_WIDTH,

            USER_RX_MFB_REGIONS     => DMA_MFB_REGIONS,
            USER_RX_MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
            USER_RX_MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
            USER_RX_MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,

            PCIE_UP_MFB_REGIONS     => PCIE_RQ_MFB_REGIONS,
            PCIE_UP_MFB_REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
            PCIE_UP_MFB_BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
            PCIE_UP_MFB_ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

            CHANNELS       => C2H_CHANNELS,
            POINTER_WIDTH  => C2H_PTR_WIDTH,
            SW_ADDR_WIDTH  => 64,
            CNTRS_WIDTH    => 64,
            HDR_META_WIDTH => HDR_META_WIDTH,
            PKT_SIZE_MAX   => PKT_SIZE_MAX,
            TRBUF_REG_EN   => true,
            PERF_CNTR_EN   => false 
        )
        port map (
            CLK   => DMA_CLK(i),
            RESET => DMA_RESET(i),

            MI_ADDR => mi_split_addr(i)(0),
            MI_DWR  => mi_split_dwr(i)(0),
            MI_BE   => mi_split_be(i)(0),
            MI_RD   => mi_split_rd(i)(0),
            MI_WR   => mi_split_wr(i)(0),
            MI_DRD  => mi_split_drd(i)(0),
            MI_ARDY => mi_split_ardy(i)(0),
            MI_DRDY => mi_split_drdy(i)(0),

            PTR_UPD_BUFF_BA  => c2h_stop_req_buff_ba,
            PTR_UPD_P2P_EN   => c2h_stop_req_p2p_en,
            PTR_UPD_HDP      => c2h_stop_req_hdp,
            PTR_UPD_HHP      => c2h_stop_req_hhp,
            PTR_UPD_DISP_EN  => c2h_stop_req_en,
            PTR_UPD_DISP_ACK => c2h_stop_req_ack,

            USER_RX_MFB_META_HDR_META => c2h_reader_meta_hdr_meta(i),
            USER_RX_MFB_META_CHAN     => c2h_reader_meta_chan(i),

            USER_RX_MFB_DATA    => c2h_reader_data(i),
            USER_RX_MFB_SOF     => c2h_reader_sof(i),
            USER_RX_MFB_EOF     => c2h_reader_eof(i),
            USER_RX_MFB_SOF_POS => c2h_reader_sof_pos(i),
            USER_RX_MFB_EOF_POS => c2h_reader_eof_pos(i),
            USER_RX_MFB_SRC_RDY => c2h_reader_src_rdy(i),
            USER_RX_MFB_DST_RDY => c2h_reader_dst_rdy(i),

            PCIE_UP_MFB_DATA    => c2h_dma_rq_mfb_data,
            PCIE_UP_MFB_META    => c2h_dma_rq_mfb_meta,
            PCIE_UP_MFB_SOF     => c2h_dma_rq_mfb_sof,
            PCIE_UP_MFB_EOF     => c2h_dma_rq_mfb_eof,
            PCIE_UP_MFB_SOF_POS => c2h_dma_rq_mfb_sof_pos,
            PCIE_UP_MFB_EOF_POS => c2h_dma_rq_mfb_eof_pos,
            PCIE_UP_MFB_SRC_RDY => c2h_dma_rq_mfb_src_rdy,
            PCIE_UP_MFB_DST_RDY => c2h_dma_rq_mfb_dst_rdy
        );

        dma_ptr_updater_i : entity work.DMA_PTR_UPDATER
        generic map (
            DEVICE            => DEVICE,

            MFB_REGIONS       => PCIE_RQ_MFB_REGIONS,
            MFB_REGION_SIZE   => PCIE_RQ_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE    => PCIE_RQ_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH    => PCIE_RQ_MFB_ITEM_WIDTH,

            RX_CHANNELS       => C2H_CHANNELS,
            RX_PTR_WIDTH      => C2H_PTR_WIDTH,

            TX_CHANNELS       => H2C_CHANNELS,
            TX_DATA_PTR_WIDTH => H2C_PTR_WIDTH,
            TX_HDR_PTR_WIDTH  => H2C_PTR_WIDTH-3,
            TX_UPD_THRESHOLD  => PKT_SIZE_MAX/2
        )
        port map (
            CLK                 => DMA_CLK(i),
            RESET               => DMA_RESET(i),

            RX_STOP_REQ_BUFF_BA => c2h_stop_req_buff_ba,
            RX_STOP_REQ_P2P_EN  => c2h_stop_req_p2p_en,
            RX_STOP_REQ_HDP     => c2h_stop_req_hdp,
            RX_STOP_REQ_HHP     => c2h_stop_req_hhp,
            RX_STOP_REQ_EN      => c2h_stop_req_en,
            RX_STOP_REQ_ACK     => c2h_stop_req_ack,

            TX_RT_UPD_CH        => open,
            TX_RT_UPD_BUFF_BA   => (others => '0'),
            TX_RT_UPD_P2P_EN    => '0',

            TX_PKT_DISP_CH      => (others => '0'),
            TX_PKT_DISP_HDP     => (others => '0'),
            TX_PKT_DISP_HHP     => (others => '0'),
            TX_PKT_DISP_EN      => '0',

            TX_START_REQ_CH     => (others => '0'),
            TX_START_REQ_VLD    => '0',
            TX_START_REQ_ACK    => open,

            TX_STOP_REQ_BUFF_BA => (others => '0'),
            TX_STOP_REQ_P2P_EN  => '0',
            TX_STOP_REQ_HDP     => (others => '0'),
            TX_STOP_REQ_HHP     => (others => '0'),
            TX_STOP_REQ_EN      => '0',
            TX_STOP_REQ_ACK     => open,

            PCIE_RQ_MFB_DATA    => ptr_upd_rq_mfb_data,
            PCIE_RQ_MFB_META    => ptr_upd_rq_mfb_meta,
            PCIE_RQ_MFB_SOF     => ptr_upd_rq_mfb_sof,
            PCIE_RQ_MFB_EOF     => ptr_upd_rq_mfb_eof,
            PCIE_RQ_MFB_SOF_POS => ptr_upd_rq_mfb_sof_pos,
            PCIE_RQ_MFB_EOF_POS => ptr_upd_rq_mfb_eof_pos,
            PCIE_RQ_MFB_SRC_RDY => ptr_upd_rq_mfb_src_rdy,
            PCIE_RQ_MFB_DST_RDY => ptr_upd_rq_mfb_dst_rdy
        );

        pcie_rq_mfb_merger_i : entity work.MFB_MERGER_SIMPLE
        generic map (
            REGIONS     => PCIE_RQ_MFB_REGIONS,
            REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
            BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
            ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

            META_WIDTH  => PCIE_RQ_META_WIDTH,
            MASKING_EN  => false,
            CNT_MAX     => 2**3
        )
        port map (
            CLK             => DMA_CLK(i),
            RST             => DMA_RESET(i),

            RX_MFB0_DATA    => c2h_dma_rq_mfb_data,
            RX_MFB0_META    => c2h_dma_rq_mfb_meta,
            RX_MFB0_SOF     => c2h_dma_rq_mfb_sof,
            RX_MFB0_SOF_POS => c2h_dma_rq_mfb_sof_pos,
            RX_MFB0_EOF     => c2h_dma_rq_mfb_eof,
            RX_MFB0_EOF_POS => c2h_dma_rq_mfb_eof_pos,
            RX_MFB0_SRC_RDY => c2h_dma_rq_mfb_src_rdy,
            RX_MFB0_DST_RDY => c2h_dma_rq_mfb_dst_rdy,

            RX_MFB1_DATA    => ptr_upd_rq_mfb_data,
            RX_MFB1_META    => ptr_upd_rq_mfb_meta,
            RX_MFB1_SOF     => ptr_upd_rq_mfb_sof,
            RX_MFB1_SOF_POS => ptr_upd_rq_mfb_sof_pos,
            RX_MFB1_EOF     => ptr_upd_rq_mfb_eof,
            RX_MFB1_EOF_POS => ptr_upd_rq_mfb_eof_pos,
            RX_MFB1_SRC_RDY => ptr_upd_rq_mfb_src_rdy,
            RX_MFB1_DST_RDY => ptr_upd_rq_mfb_dst_rdy,

            TX_MFB_DATA     => pcie_rq_mfb_data_piped(i),
            TX_MFB_META     => pcie_rq_mfb_meta_piped(i),
            TX_MFB_SOF      => pcie_rq_mfb_sof_piped(i),
            TX_MFB_SOF_POS  => pcie_rq_mfb_sof_pos_piped(i),
            TX_MFB_EOF      => pcie_rq_mfb_eof_piped(i),
            TX_MFB_EOF_POS  => pcie_rq_mfb_eof_pos_piped(i),
            TX_MFB_SRC_RDY  => pcie_rq_mfb_src_rdy_piped(i),
            TX_MFB_DST_RDY  => pcie_rq_mfb_dst_rdy_piped(i)
        );

        pcie_rq_mfb_pipe_i : entity work.MFB_PIPE
            generic map (
                REGIONS     => PCIE_RQ_MFB_REGIONS,
                REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
                BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
                ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

                META_WIDTH  => PCIE_RQ_META_WIDTH,
                FAKE_PIPE   => (not OUT_PIPE_EN) or (not C2H_GEN_EN),
                USE_DST_RDY => TRUE,
                PIPE_TYPE   => "REG",
                DEVICE      => DEVICE)
            port map (
                CLK   => DMA_CLK(i),
                RESET => DMA_RESET(i),

                RX_DATA    => pcie_rq_mfb_data_piped(i),
                RX_META    => pcie_rq_mfb_meta_piped(i),
                RX_SOF_POS => pcie_rq_mfb_sof_pos_piped(i),
                RX_EOF_POS => pcie_rq_mfb_eof_pos_piped(i),
                RX_SOF     => pcie_rq_mfb_sof_piped(i),
                RX_EOF     => pcie_rq_mfb_eof_piped(i),
                RX_SRC_RDY => pcie_rq_mfb_src_rdy_piped(i),
                RX_DST_RDY => pcie_rq_mfb_dst_rdy_piped(i),

                TX_DATA    => PCIE_RQ_MFB_DATA(i),
                TX_META    => PCIE_RQ_MFB_META(i),
                TX_SOF_POS => PCIE_RQ_MFB_SOF_POS(i),
                TX_EOF_POS => PCIE_RQ_MFB_EOF_POS(i),
                TX_SOF     => PCIE_RQ_MFB_SOF(i),
                TX_EOF     => PCIE_RQ_MFB_EOF(i),
                TX_SRC_RDY => PCIE_RQ_MFB_SRC_RDY(i),
                TX_DST_RDY => PCIE_RQ_MFB_DST_RDY(i));

        pcie_cq_mfb_pipe_i : entity work.MFB_PIPE
            generic map (
                REGIONS     => PCIE_CQ_MFB_REGIONS,
                REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
                BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
                ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH,

                META_WIDTH  => PCIE_CQ_META_WIDTH,
                FAKE_PIPE   => (not OUT_PIPE_EN) or (not H2C_GEN_EN),
                USE_DST_RDY => TRUE,
                PIPE_TYPE   => "REG",
                DEVICE      => DEVICE)
            port map (
                CLK   => DMA_CLK(i),
                RESET => DMA_RESET(i),

                RX_DATA    => PCIE_CQ_MFB_DATA(i),
                RX_META    => PCIE_CQ_MFB_META(i),
                RX_SOF_POS => PCIE_CQ_MFB_SOF_POS(i),
                RX_EOF_POS => PCIE_CQ_MFB_EOF_POS(i),
                RX_SOF     => PCIE_CQ_MFB_SOF(i),
                RX_EOF     => PCIE_CQ_MFB_EOF(i),
                RX_SRC_RDY => PCIE_CQ_MFB_SRC_RDY(i),
                RX_DST_RDY => PCIE_CQ_MFB_DST_RDY(i),

                TX_DATA    => pcie_cq_mfb_data_piped(i),
                TX_META    => pcie_cq_mfb_meta_piped(i),
                TX_SOF_POS => pcie_cq_mfb_sof_pos_piped(i),
                TX_EOF_POS => pcie_cq_mfb_eof_pos_piped(i),
                TX_SOF     => pcie_cq_mfb_sof_piped(i),
                TX_EOF     => pcie_cq_mfb_eof_piped(i),
                TX_SRC_RDY => pcie_cq_mfb_src_rdy_piped(i),
                TX_DST_RDY => pcie_cq_mfb_dst_rdy_piped(i));
    end generate;
end architecture;
