-- core_logic.vhd: Core of the scratchpad application, an HBM window behind PF1 BAR0 of both PCIe endpoints
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.combo_const.all;
use work.combo_user_const.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.mi_addr_space_pack.all;
use work.ab_init_pack.all;

-- Each endpoint's PCIE_BAR2AXI turns MemWr/MemRd on PF1 BAR0 into AXI4 bursts of that endpoint's VNoC NMU. Both NMUs reach the same HBM PC0 window, so both BARs show one memory. MI (EP0 PF0 BAR0) runs on the CIPS PL0 clock.
entity CORE_LOGIC is
    generic (
        DEVICE             : string  := "VERSAL";

        PCIE_GEN           : natural := 5;
        -- Number of PCIe connectors present on board
        PCIE_CONS          : natural := 1;
        -- Number of PCIe lanes per connector
        PCIE_LANES         : natural := 16;
        -- Number of instantiated PCIe endpoints
        PCIE_ENDPOINTS     : natural := 2;
        -- Connected PCIe endpoint type, only CPM5
        PCIE_MOD_ARCH      : string  := "CPM5";
        -- Connected PCIe endpoint mode: 1 = 2x8 lanes
        PCIE_ENDPOINT_MODE : natural := 1
    );
    port (
        -- PCIe interface
        PCIE_SYSCLK_P : in  std_logic_vector(PCIE_CONS*PCIE_ENDPOINTS-1 downto 0);
        PCIE_SYSCLK_N : in  std_logic_vector(PCIE_CONS*PCIE_ENDPOINTS-1 downto 0);
        PCIE_RX_P     : in  std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);
        PCIE_RX_N     : in  std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);
        PCIE_TX_P     : out std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);
        PCIE_TX_N     : out std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);

        -- HBM stack 0 reference clock, 200 MHz
        HBM_REFCLK_P  : in  std_logic;
        HBM_REFCLK_N  : in  std_logic
    );
end entity;

architecture FULL of CORE_LOGIC is

    component v80_hbm_wrapper is
        port (
            HBM_REF_CLK_0_CLK_N : in std_logic_vector(0 to 0);
            HBM_REF_CLK_0_CLK_P : in std_logic_vector(0 to 0)
        );
    end component;

    constant MI_WIDTH    : natural := 32;
    constant RESET_WIDTH : natural := 4;
    constant CNT_WIDTH   : natural := 32;

    -- CPM5 1024-bit straddle: up to 4 TLPs per word on CQ, CC and RQ, up to 8 on RC
    constant PCIE_CQ_MFB_REGIONS     : natural := 4;
    constant PCIE_CQ_MFB_REGION_SIZE : natural := 1;
    constant PCIE_CQ_MFB_BLOCK_SIZE  : natural := 8;
    constant PCIE_CQ_MFB_ITEM_WIDTH  : natural := 32;

    constant PCIE_CC_MFB_REGIONS     : natural := 4;
    constant PCIE_CC_MFB_REGION_SIZE : natural := 1;
    constant PCIE_CC_MFB_BLOCK_SIZE  : natural := 8;
    constant PCIE_CC_MFB_ITEM_WIDTH  : natural := 32;

    constant PCIE_RQ_MFB_REGIONS     : natural := 4;
    constant PCIE_RQ_MFB_REGION_SIZE : natural := 1;
    constant PCIE_RQ_MFB_BLOCK_SIZE  : natural := 8;
    constant PCIE_RQ_MFB_ITEM_WIDTH  : natural := 32;

    constant PCIE_RC_MFB_REGIONS     : natural := 8;
    constant PCIE_RC_MFB_REGION_SIZE : natural := 1;
    constant PCIE_RC_MFB_BLOCK_SIZE  : natural := 4;
    constant PCIE_RC_MFB_ITEM_WIDTH  : natural := 32;

    constant CQ_DATA_W  : natural := PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH;
    constant CQ_SOFP_W  : natural := PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE));
    constant CQ_EOFP_W  : natural := PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE));
    constant CC_DATA_W  : natural := PCIE_CC_MFB_REGIONS*PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE*PCIE_CC_MFB_ITEM_WIDTH;
    constant CC_SOFP_W  : natural := PCIE_CC_MFB_REGIONS*max(1, log2(PCIE_CC_MFB_REGION_SIZE));
    constant CC_EOFP_W  : natural := PCIE_CC_MFB_REGIONS*max(1, log2(PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE));
    constant RQ_DATA_W  : natural := PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH;
    constant RQ_SOFP_W  : natural := PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE));
    constant RQ_EOFP_W  : natural := PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE));

    -- PCIe module function and BAR numbering of the CQ descriptor: PF0 BAR0 goes to the MTC, PF1 BAR0 (target function 1, BAR ID 0) arrives on the DMA CQ port
    constant SPAD_FUNC_ID      : natural := 1;
    constant SPAD_BAR_ID       : natural := 0;
    -- 1 GiB window = HBM stack 0 PC0, the same for both endpoints
    constant SPAD_BAR_APERTURE : natural := 30;
    constant SPAD_AXI_BASE     : std_logic_vector(63 downto 0) := X"0000004000000000";

    constant NMU_DATA_WIDTH : natural := 256;
    constant NMU_ADDR_WIDTH : natural := 64;
    constant NMU_ID_WIDTH   : natural := 4;

    -- PL0 clock and reset of the CIPS, through MISC_PCIE2TOP(0) of the PCIe module
    constant MISC_PCIE2TOP_WIDTH : natural := 2;

    signal misc_pcie2top : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MISC_PCIE2TOP_WIDTH-1 downto 0);
    signal mi_clk        : std_logic;
    signal mi_rst_async  : std_logic;
    signal mi_rst        : std_logic_vector(RESET_WIDTH-1 downto 0);

    signal pcie_clks     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rsts     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_link_up  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    -- Two register stages between the reset synchroniser beside the CPM and the endpoint logic
    signal ep_rst_pipe   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(1 downto 0) := (others => (others => '1'));

    -- MI32 roots, one per endpoint (PF0 BAR0)
    signal mi_dwr  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_addr : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_be   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH/8-1 downto 0);
    signal mi_rd   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_wr   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_drd  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_ardy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_drdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    -- MI interfaces of the components behind endpoint 0 (clocked at mi_clk)
    signal mi_adc_dwr  : slv_array_t(MI_ADC_PORTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_adc_mwr  : slv_array_t(MI_ADC_PORTS-1 downto 0)(2-1 downto 0);
    signal mi_adc_addr : slv_array_t(MI_ADC_PORTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_adc_be   : slv_array_t(MI_ADC_PORTS-1 downto 0)(MI_WIDTH/8-1 downto 0);
    signal mi_adc_rd   : std_logic_vector(MI_ADC_PORTS-1 downto 0);
    signal mi_adc_wr   : std_logic_vector(MI_ADC_PORTS-1 downto 0);
    signal mi_adc_drd  : slv_array_t(MI_ADC_PORTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_adc_ardy : std_logic_vector(MI_ADC_PORTS-1 downto 0);
    signal mi_adc_drdy : std_logic_vector(MI_ADC_PORTS-1 downto 0);

    -- Status block MI after the crossing into each endpoint's clock
    signal mi_st_dwr  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_st_addr : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_st_be   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH/8-1 downto 0);
    signal mi_st_rd   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_st_wr   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_st_drd  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MI_WIDTH-1 downto 0);
    signal mi_st_ardy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_st_drdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal pcie_cq_mfb_data    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CQ_DATA_W-1 downto 0);
    signal pcie_cq_mfb_meta    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
    signal pcie_cq_mfb_sof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(PCIE_CQ_MFB_REGIONS-1 downto 0);
    signal pcie_cq_mfb_eof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(PCIE_CQ_MFB_REGIONS-1 downto 0);
    signal pcie_cq_mfb_sof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CQ_SOFP_W-1 downto 0);
    signal pcie_cq_mfb_eof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CQ_EOFP_W-1 downto 0);
    signal pcie_cq_mfb_src_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cq_mfb_dst_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal pcie_cc_mfb_data    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CC_DATA_W-1 downto 0);
    signal pcie_cc_mfb_meta    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(PCIE_CC_MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
    signal pcie_cc_mfb_sof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(PCIE_CC_MFB_REGIONS-1 downto 0);
    signal pcie_cc_mfb_eof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(PCIE_CC_MFB_REGIONS-1 downto 0);
    signal pcie_cc_mfb_sof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CC_SOFP_W-1 downto 0);
    signal pcie_cc_mfb_eof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CC_EOFP_W-1 downto 0);
    signal pcie_cc_mfb_src_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cc_mfb_dst_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal axi_awid    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_ID_WIDTH-1 downto 0);
    signal axi_awaddr  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_ADDR_WIDTH-1 downto 0);
    signal axi_awlen   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(8-1 downto 0);
    signal axi_awsize  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3-1 downto 0);
    signal axi_awburst : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(2-1 downto 0);
    signal axi_awlock  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_awcache : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(4-1 downto 0);
    signal axi_awprot  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3-1 downto 0);
    signal axi_awqos   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(4-1 downto 0);
    signal axi_awvalid : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_awready : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_wdata   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_DATA_WIDTH-1 downto 0);
    signal axi_wstrb   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_DATA_WIDTH/8-1 downto 0);
    signal axi_wlast   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_wvalid  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_wready  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_bid     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_ID_WIDTH-1 downto 0);
    signal axi_bresp   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(2-1 downto 0);
    signal axi_bvalid  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_bready  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_arid    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_ID_WIDTH-1 downto 0);
    signal axi_araddr  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_ADDR_WIDTH-1 downto 0);
    signal axi_arlen   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(8-1 downto 0);
    signal axi_arsize  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3-1 downto 0);
    signal axi_arburst : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(2-1 downto 0);
    signal axi_arlock  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_arcache : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(4-1 downto 0);
    signal axi_arprot  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3-1 downto 0);
    signal axi_arqos   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(4-1 downto 0);
    signal axi_arvalid : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_arready : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_rid     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_ID_WIDTH-1 downto 0);
    signal axi_rdata   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(NMU_DATA_WIDTH-1 downto 0);
    signal axi_rresp   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(2-1 downto 0);
    signal axi_rlast   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_rvalid  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal axi_rready  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal cnt_wr   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CNT_WIDTH-1 downto 0);
    signal cnt_rd   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CNT_WIDTH-1 downto 0);
    signal cnt_ur   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CNT_WIDTH-1 downto 0);
    signal cnt_drop : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CNT_WIDTH-1 downto 0);
    signal cnt_err  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(CNT_WIDTH-1 downto 0);

begin

    assert (PCIE_MOD_ARCH = "CPM5" and PCIE_ENDPOINTS = MI_ADC_STATUS_EPS and PCIE_ENDPOINT_MODE = 1)
        report "CORE_LOGIC (scratchpad): only the CPM5 PCIe module with two x8 endpoints is supported!"
        severity failure;

    -- =========================================================================
    --  MI CLOCK AND RESET (CIPS PL0)
    -- =========================================================================
    mi_clk       <= misc_pcie2top(0)(0);
    mi_rst_async <= not misc_pcie2top(0)(1);

    mi_reset_i : entity work.ASYNC_RESET
    generic map (
        TWO_REG  => false,
        OUT_REG  => true,
        REPLICAS => RESET_WIDTH
    )
    port map (
        CLK       => mi_clk,
        ASYNC_RST => mi_rst_async,
        OUT_RST   => mi_rst
    );

    -- =========================================================================
    --  PCIe module instance and connections
    -- =========================================================================
    pcie_i : entity work.PCIE
    generic map (
        BAR0_BASE_ADDR    => BAR0_BASE_ADDR,
        BAR1_BASE_ADDR    => BAR1_BASE_ADDR,
        BAR2_BASE_ADDR    => BAR2_BASE_ADDR,
        BAR3_BASE_ADDR    => BAR3_BASE_ADDR,
        BAR4_BASE_ADDR    => BAR4_BASE_ADDR,
        BAR5_BASE_ADDR    => BAR5_BASE_ADDR,
        EXP_ROM_BASE_ADDR => EXP_ROM_BASE_ADDR,

        CQ_MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
        CQ_MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
        CQ_MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
        CQ_MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH,

        RC_MFB_REGIONS     => PCIE_RC_MFB_REGIONS,
        RC_MFB_REGION_SIZE => PCIE_RC_MFB_REGION_SIZE,
        RC_MFB_BLOCK_SIZE  => PCIE_RC_MFB_BLOCK_SIZE,
        RC_MFB_ITEM_WIDTH  => PCIE_RC_MFB_ITEM_WIDTH,

        CC_MFB_REGIONS     => PCIE_CC_MFB_REGIONS,
        CC_MFB_REGION_SIZE => PCIE_CC_MFB_REGION_SIZE,
        CC_MFB_BLOCK_SIZE  => PCIE_CC_MFB_BLOCK_SIZE,
        CC_MFB_ITEM_WIDTH  => PCIE_CC_MFB_ITEM_WIDTH,

        RQ_MFB_REGIONS     => PCIE_RQ_MFB_REGIONS,
        RQ_MFB_REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
        RQ_MFB_BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
        RQ_MFB_ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

        DMA_PORTS          => PCIE_ENDPOINTS,
        PCIE_ENDPOINT_TYPE => PCIE_MOD_ARCH,
        PCIE_ENDPOINT_MODE => PCIE_ENDPOINT_MODE,
        PCIE_ENDPOINTS     => PCIE_ENDPOINTS,
        PCIE_CLKS          => PCIE_ENDPOINTS,
        PCIE_CONS          => PCIE_CONS,
        PCIE_LANES         => PCIE_LANES,
        PCIE_GEN           => PCIE_GEN,

        CARD_ID_WIDTH       => 0,
        PTC_DISABLE         => true,
        DMA_BAR_ENABLE      => true,
        XVC_ENABLE          => false,
        MISC_TOP2PCIE_WIDTH => 1,
        MISC_PCIE2TOP_WIDTH => MISC_PCIE2TOP_WIDTH,
        DEVICE              => DEVICE
    )
    port map (
        PCIE_SYSCLK_P   => PCIE_SYSCLK_P,
        PCIE_SYSCLK_N   => PCIE_SYSCLK_N,
        -- PERST# of both CPM5 controllers comes through PMC MIO 24/25 inside the CIPS
        PCIE_SYSRST_N   => (others => '1'),
        INIT_DONE_N     => '0',
        PCIE_USER_CLK   => pcie_clks,
        PCIE_USER_RESET => pcie_rsts,
        DMA_CLK         => pcie_clks(0),
        DMA_RESET       => pcie_rsts(0),

        PCIE_RX_P       => PCIE_RX_P,
        PCIE_RX_N       => PCIE_RX_N,
        PCIE_TX_P       => PCIE_TX_P,
        PCIE_TX_N       => PCIE_TX_N,

        PCIE_LINK_UP        => pcie_link_up,
        PCIE_MPS            => open,
        PCIE_MRRS           => open,
        PCIE_EXT_TAG_EN     => open,
        PCIE_10B_TAG_REQ_EN => open,
        PCIE_RCB_SIZE       => open,
        CARD_ID             => (others => (others => '0')),

        -- No requester: RQ stays idle and RC is never used
        DMA_RQ_MFB_DATA    => (others => (others => '0')),
        DMA_RQ_MFB_META    => (others => (others => '0')),
        DMA_RQ_MFB_SOF     => (others => (others => '0')),
        DMA_RQ_MFB_EOF     => (others => (others => '0')),
        DMA_RQ_MFB_SOF_POS => (others => (others => '0')),
        DMA_RQ_MFB_EOF_POS => (others => (others => '0')),
        DMA_RQ_MFB_SRC_RDY => (others => '0'),
        DMA_RQ_MFB_DST_RDY => open,

        DMA_RQ_MVB_DATA    => (others => (others => '0')),
        DMA_RQ_MVB_VLD     => (others => (others => '0')),
        DMA_RQ_MVB_SRC_RDY => (others => '0'),
        DMA_RQ_MVB_DST_RDY => open,

        DMA_RC_MFB_DATA    => open,
        DMA_RC_MFB_META    => open,
        DMA_RC_MFB_SOF     => open,
        DMA_RC_MFB_EOF     => open,
        DMA_RC_MFB_SOF_POS => open,
        DMA_RC_MFB_EOF_POS => open,
        DMA_RC_MFB_SRC_RDY => open,
        DMA_RC_MFB_DST_RDY => (others => '1'),

        DMA_RC_MVB_DATA    => open,
        DMA_RC_MVB_VLD     => open,
        DMA_RC_MVB_SRC_RDY => open,
        DMA_RC_MVB_DST_RDY => (others => '1'),

        DMA_CQ_MFB_DATA    => pcie_cq_mfb_data,
        DMA_CQ_MFB_META    => pcie_cq_mfb_meta,
        DMA_CQ_MFB_SOF     => pcie_cq_mfb_sof,
        DMA_CQ_MFB_EOF     => pcie_cq_mfb_eof,
        DMA_CQ_MFB_SOF_POS => pcie_cq_mfb_sof_pos,
        DMA_CQ_MFB_EOF_POS => pcie_cq_mfb_eof_pos,
        DMA_CQ_MFB_SRC_RDY => pcie_cq_mfb_src_rdy,
        DMA_CQ_MFB_DST_RDY => pcie_cq_mfb_dst_rdy,

        DMA_CC_MFB_DATA    => pcie_cc_mfb_data,
        DMA_CC_MFB_META    => pcie_cc_mfb_meta,
        DMA_CC_MFB_SOF     => pcie_cc_mfb_sof,
        DMA_CC_MFB_EOF     => pcie_cc_mfb_eof,
        DMA_CC_MFB_SOF_POS => pcie_cc_mfb_sof_pos,
        DMA_CC_MFB_EOF_POS => pcie_cc_mfb_eof_pos,
        DMA_CC_MFB_SRC_RDY => pcie_cc_mfb_src_rdy,
        DMA_CC_MFB_DST_RDY => pcie_cc_mfb_dst_rdy,

        MI_CLK   => mi_clk,
        MI_RESET => mi_rst(0),

        MI_DWR  => mi_dwr,
        MI_ADDR => mi_addr,
        MI_BE   => mi_be,
        MI_RD   => mi_rd,
        MI_WR   => mi_wr,
        MI_DRD  => mi_drd,
        MI_ARDY => mi_ardy,
        MI_DRDY => mi_drdy,

        MI_DBG_DWR  => mi_adc_dwr (MI_ADC_PORT_PCI_DBG),
        MI_DBG_ADDR => mi_adc_addr(MI_ADC_PORT_PCI_DBG),
        MI_DBG_BE   => mi_adc_be  (MI_ADC_PORT_PCI_DBG),
        MI_DBG_RD   => mi_adc_rd  (MI_ADC_PORT_PCI_DBG),
        MI_DBG_WR   => mi_adc_wr  (MI_ADC_PORT_PCI_DBG),
        MI_DBG_DRD  => mi_adc_drd (MI_ADC_PORT_PCI_DBG),
        MI_DBG_ARDY => mi_adc_ardy(MI_ADC_PORT_PCI_DBG),
        MI_DBG_DRDY => mi_adc_drdy(MI_ADC_PORT_PCI_DBG),

        MISC_TOP2PCIE => (others => (others => '0')),
        MISC_PCIE2TOP => misc_pcie2top
    );

    -- =========================================================================
    --  MI ADDRESS DECODER (endpoint 0)
    -- =========================================================================
    mi_adc_i : entity work.MI_SPLITTER_PLUS_GEN
    generic map (
        ADDR_WIDTH   => MI_WIDTH,
        DATA_WIDTH   => MI_WIDTH,
        META_WIDTH   => 2,
        PORTS        => MI_ADC_PORTS,
        PIPE_OUT     => (others => true),
        PIPE_TYPE    => "SHREG",
        PIPE_OUTREG  => false,
        ADDR_BASES   => MI_ADC_PORTS,
        ADDR_BASE    => MI_ADC_ADDR_BASE,
        ADDR_MASK    => init_addr_mask_downto(MI_ADC_ADDR_BASE, MI_WIDTH),
        PORT_MAPPING => init_port_mapping_downto(MI_ADC_PORTS, MI_ADC_PORTS),
        DEVICE       => DEVICE
    )
    port map (
        CLK   => mi_clk,
        RESET => mi_rst(1),

        RX_DWR  => mi_dwr (0),
        RX_MWR  => (others => '0'),
        RX_ADDR => mi_addr(0),
        RX_BE   => mi_be  (0),
        RX_RD   => mi_rd  (0),
        RX_WR   => mi_wr  (0),
        RX_ARDY => mi_ardy(0),
        RX_DRD  => mi_drd (0),
        RX_DRDY => mi_drdy(0),

        TX_DWR  => mi_adc_dwr,
        TX_MWR  => mi_adc_mwr,
        TX_ADDR => mi_adc_addr,
        TX_BE   => mi_adc_be,
        TX_RD   => mi_adc_rd,
        TX_WR   => mi_adc_wr,
        TX_ARDY => mi_adc_ardy,
        TX_DRD  => mi_adc_drd,
        TX_DRDY => mi_adc_drdy
    );

    mi_test_space_i : entity work.MI_TEST_SPACE
    generic map (
        DEVICE => DEVICE
    )
    port map (
        CLK     => mi_clk,
        RESET   => mi_rst(2),
        MI_DWR  => mi_adc_dwr (MI_ADC_PORT_TEST),
        MI_ADDR => mi_adc_addr(MI_ADC_PORT_TEST),
        MI_BE   => mi_adc_be  (MI_ADC_PORT_TEST),
        MI_RD   => mi_adc_rd  (MI_ADC_PORT_TEST),
        MI_WR   => mi_adc_wr  (MI_ADC_PORT_TEST),
        MI_DRD  => mi_adc_drd (MI_ADC_PORT_TEST),
        MI_ARDY => mi_adc_ardy(MI_ADC_PORT_TEST),
        MI_DRDY => mi_adc_drdy(MI_ADC_PORT_TEST)
    );

    -- Endpoint 1's PF0 is a dummy no driver binds; its MI root ends in a test space of its own
    mi_test_space_ep1_i : entity work.MI_TEST_SPACE
    generic map (
        DEVICE => DEVICE
    )
    port map (
        CLK     => mi_clk,
        RESET   => mi_rst(3),
        MI_DWR  => mi_dwr (1),
        MI_ADDR => mi_addr(1),
        MI_BE   => mi_be  (1),
        MI_RD   => mi_rd  (1),
        MI_WR   => mi_wr  (1),
        MI_DRD  => mi_drd (1),
        MI_ARDY => mi_ardy(1),
        MI_DRDY => mi_drdy(1)
    );

    -- =========================================================================
    --  PER-ENDPOINT SCRATCHPAD: BAR -> AXI4 -> NMU, status block
    -- =========================================================================
    ep_g : for i in 0 to PCIE_ENDPOINTS-1 generate
        constant EP : natural := i;
    begin
        ep_rst_pipe_p : process (pcie_clks(i))
        begin
            if (rising_edge(pcie_clks(i))) then
                ep_rst_pipe(i) <= ep_rst_pipe(i)(0) & pcie_rsts(i);
            end if;
        end process;

        bar2axi_i : entity work.PCIE_BAR2AXI
        generic map (
            DEVICE          => DEVICE,
            MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
            MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH,
            BAR_ID          => SPAD_BAR_ID,
            FUNC_FILTER_EN  => true,
            FUNC_ID         => SPAD_FUNC_ID,
            BAR_APERTURE    => SPAD_BAR_APERTURE,
            AXI_BASE_ADDR   => SPAD_AXI_BASE,
            AXI_DATA_WIDTH  => NMU_DATA_WIDTH,
            AXI_ADDR_WIDTH  => NMU_ADDR_WIDTH,
            AXI_ID_WIDTH    => NMU_ID_WIDTH,
            AXI_ID          => 0,
            AXI_CACHE       => "0010",
            AXI_PROT        => "000",
            AXI_QOS         => "0000",
            MAX_WR_BYTES    => 1024,
            MAX_RD_BYTES    => 4096,
            RD_OUTSTANDING  => 8,
            RD_BUFFER_BYTES => 16384,
            WR_OUTSTANDING  => 16,
            CNT_WIDTH       => CNT_WIDTH
        )
        port map (
            CLK   => pcie_clks(i),
            RESET => ep_rst_pipe(i)(1),

            CQ_MFB_DATA    => pcie_cq_mfb_data(i),
            CQ_MFB_META    => pcie_cq_mfb_meta(i),
            CQ_MFB_SOF     => pcie_cq_mfb_sof(i),
            CQ_MFB_EOF     => pcie_cq_mfb_eof(i),
            CQ_MFB_SOF_POS => pcie_cq_mfb_sof_pos(i),
            CQ_MFB_EOF_POS => pcie_cq_mfb_eof_pos(i),
            CQ_MFB_SRC_RDY => pcie_cq_mfb_src_rdy(i),
            CQ_MFB_DST_RDY => pcie_cq_mfb_dst_rdy(i),

            CC_MFB_DATA    => pcie_cc_mfb_data(i),
            CC_MFB_META    => pcie_cc_mfb_meta(i),
            CC_MFB_SOF     => pcie_cc_mfb_sof(i),
            CC_MFB_EOF     => pcie_cc_mfb_eof(i),
            CC_MFB_SOF_POS => pcie_cc_mfb_sof_pos(i),
            CC_MFB_EOF_POS => pcie_cc_mfb_eof_pos(i),
            CC_MFB_SRC_RDY => pcie_cc_mfb_src_rdy(i),
            CC_MFB_DST_RDY => pcie_cc_mfb_dst_rdy(i),

            M_AXI_AWID    => axi_awid(i),
            M_AXI_AWADDR  => axi_awaddr(i),
            M_AXI_AWLEN   => axi_awlen(i),
            M_AXI_AWSIZE  => axi_awsize(i),
            M_AXI_AWBURST => axi_awburst(i),
            M_AXI_AWLOCK  => axi_awlock(i),
            M_AXI_AWCACHE => axi_awcache(i),
            M_AXI_AWPROT  => axi_awprot(i),
            M_AXI_AWQOS   => axi_awqos(i),
            M_AXI_AWVALID => axi_awvalid(i),
            M_AXI_AWREADY => axi_awready(i),

            M_AXI_WDATA   => axi_wdata(i),
            M_AXI_WSTRB   => axi_wstrb(i),
            M_AXI_WLAST   => axi_wlast(i),
            M_AXI_WVALID  => axi_wvalid(i),
            M_AXI_WREADY  => axi_wready(i),

            M_AXI_BID     => axi_bid(i),
            M_AXI_BRESP   => axi_bresp(i),
            M_AXI_BVALID  => axi_bvalid(i),
            M_AXI_BREADY  => axi_bready(i),

            M_AXI_ARID    => axi_arid(i),
            M_AXI_ARADDR  => axi_araddr(i),
            M_AXI_ARLEN   => axi_arlen(i),
            M_AXI_ARSIZE  => axi_arsize(i),
            M_AXI_ARBURST => axi_arburst(i),
            M_AXI_ARLOCK  => axi_arlock(i),
            M_AXI_ARCACHE => axi_arcache(i),
            M_AXI_ARPROT  => axi_arprot(i),
            M_AXI_ARQOS   => axi_arqos(i),
            M_AXI_ARVALID => axi_arvalid(i),
            M_AXI_ARREADY => axi_arready(i),

            M_AXI_RID     => axi_rid(i),
            M_AXI_RDATA   => axi_rdata(i),
            M_AXI_RRESP   => axi_rresp(i),
            M_AXI_RLAST   => axi_rlast(i),
            M_AXI_RVALID  => axi_rvalid(i),
            M_AXI_RREADY  => axi_rready(i),

            CNT_WR   => cnt_wr(i),
            CNT_RD   => cnt_rd(i),
            CNT_UR   => cnt_ur(i),
            CNT_DROP => cnt_drop(i),
            CNT_ERR  => cnt_err(i)
        );

        nmu_i : entity work.SCRATCHPAD_NMU
        generic map (
            DATA_WIDTH => NMU_DATA_WIDTH,
            ADDR_WIDTH => NMU_ADDR_WIDTH,
            ID_WIDTH   => NMU_ID_WIDTH
        )
        port map (
            CLK           => pcie_clks(i),

            S_AXI_AWID    => axi_awid(i),
            S_AXI_AWADDR  => axi_awaddr(i),
            S_AXI_AWLEN   => axi_awlen(i),
            S_AXI_AWSIZE  => axi_awsize(i),
            S_AXI_AWBURST => axi_awburst(i),
            S_AXI_AWLOCK  => axi_awlock(i),
            S_AXI_AWCACHE => axi_awcache(i),
            S_AXI_AWPROT  => axi_awprot(i),
            S_AXI_AWQOS   => axi_awqos(i),
            S_AXI_AWVALID => axi_awvalid(i),
            S_AXI_AWREADY => axi_awready(i),

            S_AXI_WDATA   => axi_wdata(i),
            S_AXI_WSTRB   => axi_wstrb(i),
            S_AXI_WLAST   => axi_wlast(i),
            S_AXI_WVALID  => axi_wvalid(i),
            S_AXI_WREADY  => axi_wready(i),

            S_AXI_BID     => axi_bid(i),
            S_AXI_BRESP   => axi_bresp(i),
            S_AXI_BVALID  => axi_bvalid(i),
            S_AXI_BREADY  => axi_bready(i),

            S_AXI_ARID    => axi_arid(i),
            S_AXI_ARADDR  => axi_araddr(i),
            S_AXI_ARLEN   => axi_arlen(i),
            S_AXI_ARSIZE  => axi_arsize(i),
            S_AXI_ARBURST => axi_arburst(i),
            S_AXI_ARLOCK  => axi_arlock(i),
            S_AXI_ARCACHE => axi_arcache(i),
            S_AXI_ARPROT  => axi_arprot(i),
            S_AXI_ARQOS   => axi_arqos(i),
            S_AXI_ARVALID => axi_arvalid(i),
            S_AXI_ARREADY => axi_arready(i),

            S_AXI_RID     => axi_rid(i),
            S_AXI_RDATA   => axi_rdata(i),
            S_AXI_RRESP   => axi_rresp(i),
            S_AXI_RLAST   => axi_rlast(i),
            S_AXI_RVALID  => axi_rvalid(i),
            S_AXI_RREADY  => axi_rready(i)
        );

        mi_status_async_i : entity work.MI_ASYNC
        generic map (
            DATA_WIDTH  => MI_WIDTH,
            ADDR_WIDTH  => MI_WIDTH,
            META_WIDTH  => 2,
            RAM_TYPE    => "LUT",
            RESET_LOGIC => true,
            DEVICE      => DEVICE
        )
        port map (
            CLK_M     => mi_clk,
            RESET_M   => mi_rst(1),
            MI_M_DWR  => mi_adc_dwr (MI_ADC_PORT_STATUS+i),
            MI_M_MWR  => mi_adc_mwr (MI_ADC_PORT_STATUS+i),
            MI_M_ADDR => mi_adc_addr(MI_ADC_PORT_STATUS+i),
            MI_M_RD   => mi_adc_rd  (MI_ADC_PORT_STATUS+i),
            MI_M_WR   => mi_adc_wr  (MI_ADC_PORT_STATUS+i),
            MI_M_BE   => mi_adc_be  (MI_ADC_PORT_STATUS+i),
            MI_M_DRD  => mi_adc_drd (MI_ADC_PORT_STATUS+i),
            MI_M_ARDY => mi_adc_ardy(MI_ADC_PORT_STATUS+i),
            MI_M_DRDY => mi_adc_drdy(MI_ADC_PORT_STATUS+i),

            CLK_S     => pcie_clks(i),
            RESET_S   => ep_rst_pipe(i)(1),
            MI_S_DWR  => mi_st_dwr(i),
            MI_S_MWR  => open,
            MI_S_ADDR => mi_st_addr(i),
            MI_S_RD   => mi_st_rd(i),
            MI_S_WR   => mi_st_wr(i),
            MI_S_BE   => mi_st_be(i),
            MI_S_DRD  => mi_st_drd(i),
            MI_S_ARDY => mi_st_ardy(i),
            MI_S_DRDY => mi_st_drdy(i)
        );

        status_i : entity work.SCRATCHPAD_STATUS
        generic map (
            EP_INDEX  => EP,
            CNT_WIDTH => CNT_WIDTH
        )
        port map (
            CLK      => pcie_clks(i),
            RESET    => ep_rst_pipe(i)(1),

            MI_DWR   => mi_st_dwr(i),
            MI_ADDR  => mi_st_addr(i),
            MI_BE    => mi_st_be(i),
            MI_RD    => mi_st_rd(i),
            MI_WR    => mi_st_wr(i),
            MI_DRD   => mi_st_drd(i),
            MI_ARDY  => mi_st_ardy(i),
            MI_DRDY  => mi_st_drdy(i),

            CNT_WR   => cnt_wr(i),
            CNT_RD   => cnt_rd(i),
            CNT_UR   => cnt_ur(i),
            CNT_DROP => cnt_drop(i),
            CNT_ERR  => cnt_err(i),
            LINK_UP  => pcie_link_up(i)
        );
    end generate;

    -- =========================================================================
    --  HBM (axi_noc with HBM stack 0 channel 0, reached by the NMUs over the NoC)
    -- =========================================================================
    hbm_i : component v80_hbm_wrapper
    port map (
        hbm_ref_clk_0_clk_n(0) => HBM_REFCLK_N,
        hbm_ref_clk_0_clk_p(0) => HBM_REFCLK_P
    );

end architecture;
