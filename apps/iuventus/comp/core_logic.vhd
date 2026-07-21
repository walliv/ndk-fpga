-- core_logic.vhd: Common top level architecture
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
-- use ieee.fixed_pkg.all;

use work.combo_const.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.mi_addr_space_pack.all;
use work.nvme_meta_pack.all;

Library xpm;
use xpm.vcomponents.xpm_cdc_single;
use xpm.vcomponents.xpm_cdc_async_rst;

library unisim;
use unisim.vcomponents.MMCME4_BASE;
use unisim.vcomponents.IBUFDS;
use unisim.vcomponents.BUFG;

entity CORE_LOGIC is
    generic (
        DEVICE         : string  := "ULTRASCALE";
        -- System clock period in ns
        -- PCIE clock period in ns
        SYSCLK_PERIOD  : real    := 10.0;
        -- Settings of the MMCM
        -- Multiply factor of main clock (Xilinx: 2-64)
        PLL_MULT_F     : real    := 12.0;
        -- Division factor of main clock (Xilinx: 1-106)
        PLL_MASTER_DIV : natural := 3;
        -- Output clock dividers (Xilinx: 1-128)
        PLL_OUT0_DIV_F : real    := 3.0;
        PLL_OUT1_DIV   : natural := 4;
        PLL_OUT2_DIV   : natural := 6;
        PLL_OUT3_DIV   : natural := 12;

        PCIE_GEN           : natural := 4;
        -- Number of PCIe connectors present on board
        PCIE_CONS          : natural := 1;
        -- Number of PCIe lanes per connector
        PCIE_LANES         : natural := 16;
        -- Number of instantiated PCIe endpoints
        PCIE_ENDPOINTS     : natural := 1;
        -- Connected PCIe endpoint type: P_TILE, R_TILE, USP
        PCIE_MOD_ARCH : string  := "R_TILE";
        -- Connected PCIe endpoint mode: 0 = 1x16 lanes, 1 = 2x8 lanes
        PCIE_ENDPOINT_MODE : natural := 0;

        -- Amount of status LEDs to the Top-Level FPGA design
        STATUS_LEDS_NUM    : natural := 2;
        -- Width of MISC signal between Top-Level FPGA design and CORE_LOGIC
        MISC_IN_WIDTH  : natural := 0;
        -- Width of MISC signal between CORE_LOGIC and Top-Level FPGA design
        MISC_OUT_WIDTH : natural := 0
    );
    port (
        SYSCLK : in std_logic;
        SYSRST : in std_logic;

        -- PCIe interface
        PCIE_SYSCLK_P : in  std_logic_vector(PCIE_CONS*PCIE_ENDPOINTS-1 downto 0);
        PCIE_SYSCLK_N : in  std_logic_vector(PCIE_CONS*PCIE_ENDPOINTS-1 downto 0);
        PCIE_SYSRST_N : in  std_logic_vector(PCIE_CONS-1 downto 0);
        PCIE_RX_P     : in  std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);
        PCIE_RX_N     : in  std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);
        PCIE_TX_P     : out std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);
        PCIE_TX_N     : out std_logic_vector(PCIE_CONS*PCIE_LANES-1 downto 0);

        STATUS_LEDS : out std_logic_vector(STATUS_LEDS_NUM-1 downto 0);

        BOOT_MI_CLK   : out std_logic;
        BOOT_MI_RESET : out std_logic;
        BOOT_MI_DWR   : out std_logic_vector(31 downto 0);
        BOOT_MI_ADDR  : out std_logic_vector(31 downto 0);
        BOOT_MI_RD    : out std_logic;
        BOOT_MI_WR    : out std_logic;
        BOOT_MI_BE    : out std_logic_vector(3 downto 0);
        BOOT_MI_DRD   : in  std_logic_vector(31 downto 0) := (others => '0');
        BOOT_MI_ARDY  : in  std_logic                     := '0';
        BOOT_MI_DRDY  : in  std_logic                     := '0';

        -- =========================================================================
        -- MISC SIGNALS (the clock signal is not defined)
        -- =========================================================================
        HBM_CATTRIP : out std_logic;
        -- Optional signal for MISC connection from Top-Level FPGA design to CORE_LOGIC.
        MISC_IN     : in  std_logic_vector(MISC_IN_WIDTH-1 downto 0) := (others => '0');
        -- Optional signal for MISC connection from CORE_LOGIC to Top-Level FPGA design.
        MISC_OUT    : out std_logic_vector(MISC_OUT_WIDTH-1 downto 0)
    );
end entity;

architecture FULL of CORE_LOGIC is
    constant HEARTBEAT_CNT_W    : natural := 27;
    constant CLK_COUNT          : natural := 3;
    constant DMA_STREAMS        : natural := PCIE_ENDPOINTS;
    constant PCIE_MPS           : natural := 256;
    constant PCIE_MRRS          : natural := 512;
    constant IS_USP_PCIE_EP     : boolean := (PCIE_MOD_ARCH = "USP" or PCIE_MOD_ARCH = "USP_PCIE4" or PCIE_MOD_ARCH = "USP_PCIE4C");
    constant RESET_WIDTH        : natural := 10;
    constant FPGA_ID_WIDTH      : natural := tsel(DEVICE = "ULTRASCALE", 96, 64);
    constant MI_WIDTH           : integer := 32;
    constant DMA_HDR_META_WIDTH : integer := 12;

    function pcie_mfb_regions_calc_f (PCIE_DIR : string) return natural is
        variable pcie_mfb_regions : natural;
    begin
        pcie_mfb_regions := 0;

        if (PCIE_ENDPOINT_MODE = 0 or (PCIE_GEN = 4 and PCIE_ENDPOINT_MODE = 2)) then     -- x16 of higher gen x8
            pcie_mfb_regions := 2;           -- 1x512b
        elsif (PCIE_ENDPOINT_MODE = 1) then  -- x8x8
            pcie_mfb_regions := 2;           -- 2x512b
        elsif (PCIE_ENDPOINT_MODE = 2 or PCIE_ENDPOINT_MODE = 3) then  -- x8
            pcie_mfb_regions := 1;           -- 1x256b
        end if;

        if (PCIE_DIR = "RC") then            -- USP RC support up to 4 TLP in word
            pcie_mfb_regions := pcie_mfb_regions*2;
        end if;

        return pcie_mfb_regions;
    end function;

    constant DMA_MFB_REGIONS     : natural := 1;
    constant DMA_MFB_REGION_SIZE : natural := 1;
    constant DMA_MFB_BLOCK_SIZE  : natural := 64;  -- Number of items in block
    constant DMA_MFB_ITEM_WIDTH  : natural := 8;  -- Width of one item in bits

    -- Number of independent SQ/CQ queues (one per SSD) the DMA_IUVENTUS core and USER_CORE are
    -- built with. QUEUE_DEPTH is left at its DMA_IUVENTUS default (16) here.
    constant NUM_QUEUES : natural := 4;

    -- DMA MFB RQ parameters
    constant PCIE_RQ_MFB_REGIONS     : natural := pcie_mfb_regions_calc_f("RQ");
    constant PCIE_RQ_MFB_REGION_SIZE : natural := 1;
    constant PCIE_RQ_MFB_BLOCK_SIZE  : natural := 8;
    constant PCIE_RQ_MFB_ITEM_WIDTH  : natural := 32;

    -- DMA MFB RC parameters
    constant PCIE_RC_MFB_REGIONS     : natural := pcie_mfb_regions_calc_f("RC");
    constant PCIE_RC_MFB_REGION_SIZE : natural := 1;
    constant PCIE_RC_MFB_BLOCK_SIZE  : natural := 4;
    constant PCIE_RC_MFB_ITEM_WIDTH  : natural := 32;

    constant PCIE_CQ_MFB_REGIONS     : natural := pcie_mfb_regions_calc_f("CQ");
    constant PCIE_CQ_MFB_REGION_SIZE : natural := PCIE_RQ_MFB_REGION_SIZE;
    constant PCIE_CQ_MFB_BLOCK_SIZE  : natural := PCIE_RQ_MFB_BLOCK_SIZE;
    constant PCIE_CQ_MFB_ITEM_WIDTH  : natural := PCIE_RQ_MFB_ITEM_WIDTH;

    constant PCIE_CC_MFB_REGIONS     : natural := pcie_mfb_regions_calc_f("CC");
    constant PCIE_CC_MFB_REGION_SIZE : natural := PCIE_CQ_MFB_REGION_SIZE;
    -- this remains the same as RQ interface beacuse on straddling option enabled, the core supports
    -- only two TLPs on CC interface
    constant PCIE_CC_MFB_BLOCK_SIZE  : natural := PCIE_CQ_MFB_BLOCK_SIZE;
    constant PCIE_CC_MFB_ITEM_WIDTH  : natural := PCIE_CQ_MFB_ITEM_WIDTH;

    signal heartbeat_cnt : unsigned(HEARTBEAT_CNT_W-1 downto 0);

    signal pll_locked    : std_logic;
    signal clkfbout      : std_logic;
    signal mmcm_usr_clks : std_logic_vector(7-1 downto 0);

    signal global_reset : std_logic;
    signal rst_vector   : std_logic_vector(CLK_COUNT*RESET_WIDTH-1 downto 0);

    constant MI_CLK_IDX   : natural := 2;
    constant BOOT_CLK_IDX : natural := 1;
    constant APP_CLK_IDX  : natural := 0;

    signal usr_clks   : std_logic_vector(CLK_COUNT-1 downto 0);
    signal pcie_clks  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal clk_mi     : std_logic;
    signal clk_dma    : std_logic;
    signal clk_dma_x2 : std_logic;
    signal clk_app    : std_logic;

    signal usr_rsts   : slv_array_t(CLK_COUNT -1 downto 0)(RESET_WIDTH -1 downto 0);
    signal pcie_rsts  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal rst_mi     : std_logic_vector(RESET_WIDTH-1 downto 0);
    signal rst_dma    : std_logic_vector(RESET_WIDTH-1 downto 0);
    signal rst_dma_x2 : std_logic_vector(RESET_WIDTH-1 downto 0);
    signal rst_app    : std_logic_vector(RESET_WIDTH-1 downto 0);

    signal pcie_link_up     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal app_pcie_link_up : std_logic_vector(PCIE_ENDPOINTS-1 downto 0) := (others => '0');

    signal fpga_id      : std_logic_vector(FPGA_ID_WIDTH-1 downto 0);
    signal fpga_id_vld  : std_logic := '0';
    signal pcie_fpga_id : slv_array_t (PCIE_ENDPOINTS-1 downto 0)(FPGA_ID_WIDTH-1 downto 0);

    -- MI32 interface signals
    signal mi_dwr  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal mi_addr : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal mi_be   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3 downto 0);
    signal mi_rd   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_wr   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_drd  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal mi_ardy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal mi_drdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    -- MI interfaces for individual components (clocked at clk_mi)
    signal mi_adc_dwr  : slv_array_t (MI_ADC_PORTS-1 downto 0)(32-1 downto 0);
    signal mi_adc_addr : slv_array_t (MI_ADC_PORTS-1 downto 0)(32-1 downto 0);
    signal mi_adc_be   : slv_array_t (MI_ADC_PORTS-1 downto 0)(32/8-1 downto 0);
    signal mi_adc_rd   : std_logic_vector(MI_ADC_PORTS-1 downto 0);
    signal mi_adc_wr   : std_logic_vector(MI_ADC_PORTS-1 downto 0);
    signal mi_adc_drd  : slv_array_t (MI_ADC_PORTS-1 downto 0)(32-1 downto 0);
    signal mi_adc_ardy : std_logic_vector(MI_ADC_PORTS-1 downto 0);
    signal mi_adc_drdy : std_logic_vector(MI_ADC_PORTS-1 downto 0);

    signal dma_mi_dwr  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal dma_mi_addr : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal dma_mi_be   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3 downto 0);
    signal dma_mi_rd   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal dma_mi_wr   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal dma_mi_drd  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal dma_mi_ardy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal dma_mi_drdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal pcie_rq_mfb_data    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH-1 downto 0);
    signal pcie_rq_mfb_meta    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH -1 downto 0);
    signal pcie_rq_mfb_sof     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS-1 downto 0);
    signal pcie_rq_mfb_eof     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS-1 downto 0);
    signal pcie_rq_mfb_sof_pos : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE))-1 downto 0);
    signal pcie_rq_mfb_eof_pos : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1, log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE))-1 downto 0);
    signal pcie_rq_mfb_src_rdy : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_rq_mfb_dst_rdy : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal pcie_cq_mfb_data    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
    signal pcie_cq_mfb_meta    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
    signal pcie_cq_mfb_sof     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS-1 downto 0);
    signal pcie_cq_mfb_eof     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS-1 downto 0);
    signal pcie_cq_mfb_sof_pos : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE))-1 downto 0);
    signal pcie_cq_mfb_eof_pos : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE))-1 downto 0);
    signal pcie_cq_mfb_src_rdy : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_cq_mfb_dst_rdy : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal pcie_cc_mfb_data    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE*PCIE_CC_MFB_ITEM_WIDTH-1 downto 0);
    signal pcie_cc_mfb_meta    : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*PCIE_CC_META_WIDTH -1 downto 0);
    signal pcie_cc_mfb_sof     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS-1 downto 0);
    signal pcie_cc_mfb_eof     : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS-1 downto 0);
    signal pcie_cc_mfb_sof_pos : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*max(1, log2(PCIE_CC_MFB_REGION_SIZE))-1 downto 0);
    signal pcie_cc_mfb_eof_pos : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*max(1, log2(PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE))-1 downto 0);
    signal pcie_cc_mfb_src_rdy : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_cc_mfb_dst_rdy : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal nvme_rd_req_lba_num : slv_array_t(DMA_STREAMS-1 downto 0)(7 downto 0);
    signal nvme_rd_req_lba_ptr : slv_array_t(DMA_STREAMS-1 downto 0)(SQE_LBA_PTR_W -1 downto 0);
    signal nvme_rd_req_vld     : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal nvme_rd_req_rdy     : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal nvme_rd_req_qid     : slv_array_t(DMA_STREAMS-1 downto 0)(maximum(1, log2(NUM_QUEUES)) -1 downto 0);

    signal nvme_op_stat_type : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal nvme_op_stat_code : slv_array_t(DMA_STREAMS-1 downto 0)(1 downto 0);
    signal nvme_op_stat_vld  : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal nvme_rd_mfb_data    : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
    signal nvme_rd_mfb_sof     : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS-1 downto 0);
    signal nvme_rd_mfb_eof     : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS-1 downto 0);
    signal nvme_rd_mfb_sof_pos : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
    signal nvme_rd_mfb_eof_pos : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE))-1 downto 0);
    signal nvme_rd_mfb_src_rdy : std_logic_vector(DMA_STREAMS -1 downto 0);
    signal nvme_rd_mfb_dst_rdy : std_logic_vector(DMA_STREAMS -1 downto 0);

    signal nvme_wr_mfb_data    : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
    signal nvme_wr_mfb_meta    : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + maximum(1, log2(NUM_QUEUES)))-1 downto 0);
    signal nvme_wr_mfb_sof     : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS-1 downto 0);
    signal nvme_wr_mfb_eof     : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS-1 downto 0);
    signal nvme_wr_mfb_sof_pos : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
    signal nvme_wr_mfb_eof_pos : slv_array_t(DMA_STREAMS -1 downto 0)(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE))-1 downto 0);
    signal nvme_wr_mfb_src_rdy : std_logic_vector(DMA_STREAMS -1 downto 0);
    signal nvme_wr_mfb_dst_rdy : std_logic_vector(DMA_STREAMS -1 downto 0);

begin
    mmcm_i : component MMCME4_BASE
        generic map (
            BANDWIDTH        => "OPTIMIZED",
            DIVCLK_DIVIDE    => PLL_MASTER_DIV,
            CLKFBOUT_MULT_F  => PLL_MULT_F,
            CLKOUT0_DIVIDE_F => PLL_OUT0_DIV_F,
            CLKOUT1_DIVIDE   => PLL_OUT1_DIV,
            CLKOUT2_DIVIDE   => PLL_OUT2_DIV,
            CLKOUT3_DIVIDE   => PLL_OUT3_DIV,
            CLKOUT4_DIVIDE   => 10,
            CLKOUT5_DIVIDE   => 10,
            CLKOUT6_DIVIDE   => 10,
            CLKIN1_PERIOD    => SYSCLK_PERIOD
        ) port map (
            CLKFBOUT  => clkfbout,
            CLKFBOUTB => open,
            CLKOUT0   => mmcm_usr_clks(0),
            CLKOUT0B  => open,
            CLKOUT1   => mmcm_usr_clks(1),
            CLKOUT1B  => open,
            CLKOUT2   => mmcm_usr_clks(2),
            CLKOUT2B  => open,
            CLKOUT3   => mmcm_usr_clks(3),
            CLKOUT3B  => open,
            CLKOUT4   => mmcm_usr_clks(4),
            CLKOUT5   => mmcm_usr_clks(5),
            CLKOUT6   => mmcm_usr_clks(6),
            CLKFBIN   => clkfbout,
            CLKIN1    => SYSCLK,
            LOCKED    => pll_locked,
            PWRDWN    => '0',
            RST       => SYSRST
        );

    usr_clk_bufg_g : for clk_idx in 0 to (CLK_COUNT -1) generate
        usr_clk_bufg_i : component BUFG
            port map (
                I => mmcm_usr_clks(clk_idx),
                O => usr_clks(clk_idx));
    end generate;

    global_reset_i : entity work.ASYNC_RESET
        generic map (
            TWO_REG  => FALSE,
            OUT_REG  => TRUE,
            REPLICAS => 1
        )
        port map (
            CLK        => SYSCLK,
            ASYNC_RST  => not pll_locked,
            OUT_RST(0) => global_reset
        );

    reset_tree_gen_i : entity work.RESET_TREE_GEN
        generic map (
            CLK_COUNT    => CLK_COUNT,
            RST_REPLICAS => RESET_WIDTH
        )
        port map (
            STABLE_CLK   => SYSCLK,
            GLOBAL_RESET => global_reset,
            CLK_VECTOR   => usr_clks,
            RST_VECTOR   => rst_vector
        );

    usr_rsts <= slv_array_deser(rst_vector, CLK_COUNT);

    -- usefull clocks for boot control in top-level
    MISC_OUT(0) <= usr_clks(MI_CLK_IDX);    -- AXI SPI clock (around 100 MHz)
    MISC_OUT(1) <= usr_rsts(MI_CLK_IDX)(0);
    MISC_OUT(2) <= usr_clks(BOOT_CLK_IDX);  -- BOOT_CTRL clock (up to 200 MHz)
    MISC_OUT(3) <= usr_rsts(BOOT_CLK_IDX)(0);

    -- =========================================================================
    --                      PCIe module instance and connections
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

            PTC_DISABLE         => TRUE,
            DMA_BAR_ENABLE      => TRUE,
            XVC_ENABLE          => FALSE,
            CARD_ID_WIDTH       => FPGA_ID_WIDTH,
            MISC_TOP2PCIE_WIDTH => 10,
            MISC_PCIE2TOP_WIDTH => 10,
            DEVICE              => DEVICE
        )
        port map (
            PCIE_SYSCLK_P   => PCIE_SYSCLK_P,
            PCIE_SYSCLK_N   => PCIE_SYSCLK_N,
            PCIE_SYSRST_N   => PCIE_SYSRST_N,
            INIT_DONE_N     => '0',
            PCIE_RX_P       => PCIE_RX_P,
            PCIE_RX_N       => PCIE_RX_N,
            PCIE_TX_P       => PCIE_TX_P,
            PCIE_TX_N       => PCIE_TX_N,
            PCIE_USER_CLK   => pcie_clks,
            PCIE_USER_RESET => pcie_rsts,
            PCIE_LINK_UP    => pcie_link_up,

            CARD_ID => pcie_fpga_id,

            DMA_CLK   => pcie_clks(0),
            DMA_RESET => pcie_rsts(0),

            DMA_RQ_MFB_DATA    => pcie_rq_mfb_data,
            DMA_RQ_MFB_META    => pcie_rq_mfb_meta,
            DMA_RQ_MFB_SOF     => pcie_rq_mfb_sof,
            DMA_RQ_MFB_EOF     => pcie_rq_mfb_eof,
            DMA_RQ_MFB_SOF_POS => pcie_rq_mfb_sof_pos,
            DMA_RQ_MFB_EOF_POS => pcie_rq_mfb_eof_pos,
            DMA_RQ_MFB_SRC_RDY => pcie_rq_mfb_src_rdy,
            DMA_RQ_MFB_DST_RDY => pcie_rq_mfb_dst_rdy,

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

            MI_CLK   => usr_clks(MI_CLK_IDX),
            MI_RESET => usr_rsts(MI_CLK_IDX)(1),

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
            MI_DBG_BE   => mi_adc_be (MI_ADC_PORT_PCI_DBG),
            MI_DBG_RD   => mi_adc_rd (MI_ADC_PORT_PCI_DBG),
            MI_DBG_WR   => mi_adc_wr (MI_ADC_PORT_PCI_DBG),
            MI_DBG_DRD  => mi_adc_drd (MI_ADC_PORT_PCI_DBG),
            MI_DBG_ARDY => mi_adc_ardy(MI_ADC_PORT_PCI_DBG),
            MI_DBG_DRDY => mi_adc_drdy(MI_ADC_PORT_PCI_DBG),

            MISC_TOP2PCIE => (others => (others => '0')),
            MISC_PCIE2TOP => open
        );

    cdc_pcie_up_g : for i in 0 to PCIE_ENDPOINTS-1 generate
        cdc_pcie_up_app_i : entity work.ASYNC_OPEN_LOOP
            generic map (
                IN_REG  => TRUE,
                TWO_REG => FALSE
            )
            port map (
                ACLK     => pcie_clks(i),
                BCLK     => usr_clks(APP_CLK_IDX),
                ARST     => '0',
                BRST     => '0',
                ADATAIN  => pcie_link_up(i),
                BDATAOUT => app_pcie_link_up(i)
            );

        cdc_pcie_fpga_id_i : entity work.ASYNC_OPEN_LOOP_SMD
            generic map (
                DATA_WIDTH => FPGA_ID_WIDTH
            )
            port map (
                ACLK     => usr_clks(MI_CLK_IDX),
                BCLK     => pcie_clks(i),
                ARST     => '0',
                BRST     => '0',
                ADATAIN  => fpga_id,
                BDATAOUT => pcie_fpga_id(i)
            );
    end generate;

    -- =========================================================================
    --  MI ADDRESS DECODER
    -- =========================================================================
    mi_adc_i : entity work.MI_SPLITTER_PLUS_GEN
        generic map (
            ADDR_WIDTH => MI_WIDTH,
            DATA_WIDTH => MI_WIDTH,
            -- defined in mi_addr_space_pack
            PORTS      => MI_ADC_PORTS,
            ADDR_BASE  => MI_ADC_ADDR_BASE,
            DEVICE     => DEVICE
        )
        port map (
            CLK   => usr_clks(MI_CLK_IDX),
            RESET => usr_rsts(MI_CLK_IDX)(2),

            RX_DWR  => mi_dwr (0),
            RX_ADDR => mi_addr(0),
            RX_BE   => mi_be (0),
            RX_RD   => mi_rd (0),
            RX_WR   => mi_wr (0),
            RX_ARDY => mi_ardy(0),
            RX_DRD  => mi_drd (0),
            RX_DRDY => mi_drdy(0),

            TX_DWR  => mi_adc_dwr,
            TX_ADDR => mi_adc_addr,
            TX_BE   => mi_adc_be,
            TX_RD   => mi_adc_rd,
            TX_WR   => mi_adc_wr,
            TX_ARDY => mi_adc_ardy,
            TX_DRD  => mi_adc_drd,
            TX_DRDY => mi_adc_drdy
        );

    -- boot control module is in top-level
    BOOT_MI_CLK                   <= usr_clks(MI_CLK_IDX);
    BOOT_MI_RESET                 <= usr_rsts(MI_CLK_IDX)(3);
    BOOT_MI_DWR                   <= mi_adc_dwr (MI_ADC_PORT_BOOT);
    BOOT_MI_ADDR                  <= mi_adc_addr(MI_ADC_PORT_BOOT);
    BOOT_MI_BE                    <= mi_adc_be (MI_ADC_PORT_BOOT);
    BOOT_MI_RD                    <= mi_adc_rd (MI_ADC_PORT_BOOT);
    BOOT_MI_WR                    <= mi_adc_wr (MI_ADC_PORT_BOOT);
    mi_adc_ardy(MI_ADC_PORT_BOOT) <= BOOT_MI_ARDY;
    mi_adc_drd (MI_ADC_PORT_BOOT) <= BOOT_MI_DRD;
    mi_adc_drdy(MI_ADC_PORT_BOOT) <= BOOT_MI_DRDY;

    -- =========================================================================
    --  MI TEST SPACE AND SDM/SYSMON INTERFACE
    -- =========================================================================
    mi_test_space_i : entity work.MI_TEST_SPACE
        generic map (
            DEVICE => DEVICE
        )
        port map (
            CLK     => usr_clks(MI_CLK_IDX),
            RESET   => usr_rsts(MI_CLK_IDX)(4),
            MI_DWR  => mi_adc_dwr(MI_ADC_PORT_TEST),
            MI_ADDR => mi_adc_addr(MI_ADC_PORT_TEST),
            MI_BE   => mi_adc_be(MI_ADC_PORT_TEST),
            MI_RD   => mi_adc_rd(MI_ADC_PORT_TEST),
            MI_WR   => mi_adc_wr(MI_ADC_PORT_TEST),
            MI_DRD  => mi_adc_drd(MI_ADC_PORT_TEST),
            MI_ARDY => mi_adc_ardy(MI_ADC_PORT_TEST),
            MI_DRDY => mi_adc_drdy(MI_ADC_PORT_TEST)
        );

    sdm_ctrl_i : entity work.SDM_CTRL
        generic map (
            DATA_WIDTH => 32,
            ADDR_WIDTH => 32,
            DEVICE     => DEVICE
        )
        port map (
            CLK     => usr_clks(MI_CLK_IDX),
            RESET   => usr_rsts(MI_CLK_IDX)(5),
            MI_DWR  => mi_adc_dwr(MI_ADC_PORT_SENSOR),
            MI_ADDR => mi_adc_addr(MI_ADC_PORT_SENSOR),
            MI_RD   => mi_adc_rd(MI_ADC_PORT_SENSOR),
            MI_WR   => mi_adc_wr(MI_ADC_PORT_SENSOR),
            MI_BE   => mi_adc_be(MI_ADC_PORT_SENSOR),
            MI_DRD  => mi_adc_drd(MI_ADC_PORT_SENSOR),
            MI_ARDY => mi_adc_ardy(MI_ADC_PORT_SENSOR),
            MI_DRDY => mi_adc_drdy(MI_ADC_PORT_SENSOR),

            CHIP_ID     => open,
            CHIP_ID_VLD => open
        );

    -- =========================================================================
    -- FPGA ID LOGIC
    -- =========================================================================
    hwid_i : entity work.HWID
        generic map (
            DEVICE => DEVICE
        )
        port map (
            CLK            => usr_clks(MI_CLK_IDX),
            XILINX_DNA     => fpga_id,
            XILINX_DNA_VLD => fpga_id_vld
        );

    -- =========================================================================
    --  DMA MODULE
    -- =========================================================================
    dma_g : for str in 0 to (DMA_STREAMS-1) generate
        dma_i : entity work.DMA_IUVENTUS
            generic map (
                DEVICE => DEVICE,
                MI_WIDTH => MI_WIDTH,
                MI_SAME_CLK => FALSE,

                NUM_QUEUES => NUM_QUEUES,
                -- Timing-closure lever for the N=4 multi-queue build: the per-queue tag pools /
                -- context table / FIFOs (x NUM_QUEUES) congest the CQ/WRBUFF trans-buffer ->
                -- pkt_dispatcher path. Moving the per-queue register file into NP_LUTRAM freed
                -- ~1152 flops at N=4, so QUEUE_DEPTH is raised from 4 to 8 (N=4 x QD8 = 32 total
                -- outstanding commands); rebuild confirms the LUTRAM area drop closes timing at QD8.
                QUEUE_DEPTH => 8,
                -- Production keepalive width (2**28 DMA_CLK cycles, ~1 s); explicitly assigned
                -- (equals DMA_IUVENTUS's own default) per the "always assign every generic" rule.
                FLUSH_DELAY_CNTR_WIDTH => 28,

                USR_MFB_REGIONS     => DMA_MFB_REGIONS,
                USR_MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
                USR_MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
                USR_MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,

                PCIE_MFB_REGIONS     => PCIE_RQ_MFB_REGIONS,
                PCIE_MFB_REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
                PCIE_MFB_BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
                PCIE_MFB_ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH
            )
            port map (
                CLK      => pcie_clks(str),
                RST      => pcie_rsts(str),

                NVME_RD_REQ_LBA_NUM => nvme_rd_req_lba_num(str),
                NVME_RD_REQ_LBA_PTR => nvme_rd_req_lba_ptr(str),
                NVME_RD_REQ_VLD     => nvme_rd_req_vld(str),
                NVME_RD_REQ_RDY     => nvme_rd_req_rdy(str),
                NVME_RD_REQ_QID     => nvme_rd_req_qid(str),

                OP_STAT_TYPE => nvme_op_stat_type(str),
                OP_STAT_CODE => nvme_op_stat_code(str),
                OP_STAT_VLD  => nvme_op_stat_vld(str),

                WR_MFB_DATA    => nvme_wr_mfb_data(str),
                WR_MFB_META    => nvme_wr_mfb_meta(str),
                WR_MFB_SOF     => nvme_wr_mfb_sof(str),
                WR_MFB_EOF     => nvme_wr_mfb_eof(str),
                WR_MFB_SOF_POS => nvme_wr_mfb_sof_pos(str),
                WR_MFB_EOF_POS => nvme_wr_mfb_eof_pos(str),
                WR_MFB_SRC_RDY => nvme_wr_mfb_src_rdy(str),
                WR_MFB_DST_RDY => nvme_wr_mfb_dst_rdy(str),

                RD_MFB_DATA    => nvme_rd_mfb_data(str),
                RD_MFB_SOF     => nvme_rd_mfb_sof(str),
                RD_MFB_EOF     => nvme_rd_mfb_eof(str),
                RD_MFB_SOF_POS => nvme_rd_mfb_sof_pos(str),
                RD_MFB_EOF_POS => nvme_rd_mfb_eof_pos(str),
                RD_MFB_SRC_RDY => nvme_rd_mfb_src_rdy(str),
                RD_MFB_DST_RDY => nvme_rd_mfb_dst_rdy(str),

                PCIE_RQ_MFB_DATA    => pcie_rq_mfb_data(str),
                PCIE_RQ_MFB_META    => pcie_rq_mfb_meta(str),
                PCIE_RQ_MFB_SOF     => pcie_rq_mfb_sof(str),
                PCIE_RQ_MFB_EOF     => pcie_rq_mfb_eof(str),
                PCIE_RQ_MFB_SOF_POS => pcie_rq_mfb_sof_pos(str),
                PCIE_RQ_MFB_EOF_POS => pcie_rq_mfb_eof_pos(str),
                PCIE_RQ_MFB_SRC_RDY => pcie_rq_mfb_src_rdy(str),
                PCIE_RQ_MFB_DST_RDY => pcie_rq_mfb_dst_rdy(str),

                PCIE_CQ_MFB_DATA    => pcie_cq_mfb_data(str),
                PCIE_CQ_MFB_META    => pcie_cq_mfb_meta(str),
                PCIE_CQ_MFB_SOF     => pcie_cq_mfb_sof(str),
                PCIE_CQ_MFB_EOF     => pcie_cq_mfb_eof(str),
                PCIE_CQ_MFB_SOF_POS => pcie_cq_mfb_sof_pos(str),
                PCIE_CQ_MFB_EOF_POS => pcie_cq_mfb_eof_pos(str),
                PCIE_CQ_MFB_SRC_RDY => pcie_cq_mfb_src_rdy(str),
                PCIE_CQ_MFB_DST_RDY => pcie_cq_mfb_dst_rdy(str),

                PCIE_CC_MFB_DATA    => pcie_cc_mfb_data(str),
                PCIE_CC_MFB_META    => pcie_cc_mfb_meta(str),
                PCIE_CC_MFB_SOF     => pcie_cc_mfb_sof(str),
                PCIE_CC_MFB_EOF     => pcie_cc_mfb_eof(str),
                PCIE_CC_MFB_SOF_POS => pcie_cc_mfb_sof_pos(str),
                PCIE_CC_MFB_EOF_POS => pcie_cc_mfb_eof_pos(str),
                PCIE_CC_MFB_SRC_RDY => pcie_cc_mfb_src_rdy(str),
                PCIE_CC_MFB_DST_RDY => pcie_cc_mfb_dst_rdy(str),

                MI_CLK => usr_clks(MI_CLK_IDX),
                MI_RST => usr_rsts(MI_CLK_IDX)(6),

                MI_ADDR => dma_mi_addr(str),
                MI_DWR  => dma_mi_dwr(str),
                MI_BE   => dma_mi_be(str),
                MI_RD   => dma_mi_rd(str),
                MI_WR   => dma_mi_wr(str),
                MI_DRD  => dma_mi_drd(str),
                MI_ARDY => dma_mi_ardy(str),
                MI_DRDY => dma_mi_drdy(str)
            );
    end generate ;

    -- MI interface connection
    dma_mi_pr : process (all)
    begin
        -- Connect directly to MTC by default
        dma_mi_dwr                         <= mi_dwr;
        dma_mi_addr                        <= mi_addr;
        dma_mi_rd                          <= mi_rd;
        dma_mi_wr                          <= mi_wr;
        dma_mi_be                          <= mi_be;
        mi_drd (PCIE_ENDPOINTS-1 downto 1) <= dma_mi_drd (PCIE_ENDPOINTS-1 downto 1);
        mi_ardy(PCIE_ENDPOINTS-1 downto 1) <= dma_mi_ardy(PCIE_ENDPOINTS-1 downto 1);
        mi_drdy(PCIE_ENDPOINTS-1 downto 1) <= dma_mi_drdy(PCIE_ENDPOINTS-1 downto 1);

        -- Connect to MI ADC for PCIe Endpoint 0
        dma_mi_dwr (0)               <= mi_adc_dwr(MI_ADC_PORT_DMA);
        dma_mi_addr(0)               <= mi_adc_addr(MI_ADC_PORT_DMA);
        dma_mi_rd (0)                <= mi_adc_rd(MI_ADC_PORT_DMA);
        dma_mi_wr (0)                <= mi_adc_wr(MI_ADC_PORT_DMA);
        dma_mi_be (0)                <= mi_adc_be(MI_ADC_PORT_DMA);
        mi_adc_drd(MI_ADC_PORT_DMA)  <= dma_mi_drd (0);
        mi_adc_ardy(MI_ADC_PORT_DMA) <= dma_mi_ardy(0);
        mi_adc_drdy(MI_ADC_PORT_DMA) <= dma_mi_drdy(0);
    end process;

    -- =========================================================================
    --  THE APPLICATION
    -- =========================================================================
    user_core_i : entity work.USER_CORE
        generic map (
            MI_WIDTH         => MI_WIDTH,
            DMA_STREAMS      => DMA_STREAMS,
            NUM_QUEUES       => NUM_QUEUES,

            DMA_MFB_REGIONS     => DMA_MFB_REGIONS,
            DMA_MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
            DMA_MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
            DMA_MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,

            FPGA_ID_WIDTH => FPGA_ID_WIDTH,
            DEVICE        => DEVICE
        )
        port map (
            MI_CLK => usr_clks(MI_CLK_IDX),
            MI_RST => usr_rsts(MI_CLK_IDX)(7),

            MI_DWR  => mi_adc_dwr(MI_ADC_PORT_USERAPP),
            MI_ADDR => mi_adc_addr(MI_ADC_PORT_USERAPP),
            MI_BE   => mi_adc_be(MI_ADC_PORT_USERAPP),
            MI_RD   => mi_adc_rd(MI_ADC_PORT_USERAPP),
            MI_WR   => mi_adc_wr(MI_ADC_PORT_USERAPP),
            MI_DRD  => mi_adc_drd(MI_ADC_PORT_USERAPP),
            MI_ARDY => mi_adc_ardy(MI_ADC_PORT_USERAPP),
            MI_DRDY => mi_adc_drdy(MI_ADC_PORT_USERAPP),

            DMA_CLK => pcie_clks(0),
            DMA_RST => pcie_rsts(0),

            USR_CLK => usr_clks(APP_CLK_IDX),
            USR_RST => usr_rsts(APP_CLK_IDX)(0),

            NVME_RD_REQ_LBA_NUM => nvme_rd_req_lba_num(0),
            NVME_RD_REQ_LBA_PTR => nvme_rd_req_lba_ptr(0),
            NVME_RD_REQ_VLD     => nvme_rd_req_vld(0),
            NVME_RD_REQ_RDY     => nvme_rd_req_rdy(0),
            NVME_RD_REQ_QID     => nvme_rd_req_qid(0),

            NVME_OP_STAT_TYPE => nvme_op_stat_type(0),
            NVME_OP_STAT_CODE => nvme_op_stat_code(0),
            NVME_OP_STAT_VLD  => nvme_op_stat_vld(0),

            NVME_WR_MFB_DATA    => nvme_wr_mfb_data(0),
            NVME_WR_MFB_META    => nvme_wr_mfb_meta(0),
            NVME_WR_MFB_SOF     => nvme_wr_mfb_sof(0),
            NVME_WR_MFB_EOF     => nvme_wr_mfb_eof(0),
            NVME_WR_MFB_SOF_POS => nvme_wr_mfb_sof_pos(0),
            NVME_WR_MFB_EOF_POS => nvme_wr_mfb_eof_pos(0),
            NVME_WR_MFB_SRC_RDY => nvme_wr_mfb_src_rdy(0),
            NVME_WR_MFB_DST_RDY => nvme_wr_mfb_dst_rdy(0),

            NVME_RD_MFB_DATA    => nvme_rd_mfb_data(0),
            NVME_RD_MFB_SOF     => nvme_rd_mfb_sof(0),
            NVME_RD_MFB_EOF     => nvme_rd_mfb_eof(0),
            NVME_RD_MFB_SOF_POS => nvme_rd_mfb_sof_pos(0),
            NVME_RD_MFB_EOF_POS => nvme_rd_mfb_eof_pos(0),
            NVME_RD_MFB_SRC_RDY => nvme_rd_mfb_src_rdy(0),
            NVME_RD_MFB_DST_RDY => nvme_rd_mfb_dst_rdy(0),

            PCIE_LINK_UP => app_pcie_link_up(0),
            FPGA_ID      => fpga_id,
            FPGA_ID_VLD  => fpga_id_vld
        );

    -- =========================================================================
    --  STATUS LEDs
    -- =========================================================================
    process (usr_clks(MI_CLK_IDX))
    begin
        if rising_edge(usr_clks(MI_CLK_IDX)) then
            if (usr_rsts(MI_CLK_IDX)(8) = '1') then
                heartbeat_cnt <= (others => '0');
            else
                heartbeat_cnt <= heartbeat_cnt + 1;
            end if;
            STATUS_LEDS(0) <= heartbeat_cnt(HEARTBEAT_CNT_W-1);
        end if;
    end process;

    STATUS_LEDS(1) <= (and app_pcie_link_up);
end architecture;
