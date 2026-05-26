-- dma_calypte_wrapper_arch.vhd: DMA Calypte Module Wrapper
-- Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
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

architecture IUVENTUS of DMA_WRAPPER is
    -- =============================================================================================
    -- Setup constants
    -- =============================================================================================
    constant OUT_PIPE_EN  : boolean := TRUE;
    constant USE_ASFIFO   : boolean := FALSE;

    -- =============================================================================================
    -- Select clock and reset depending on if the ASFIFO is used or not
    -- =============================================================================================
    signal dma_clk_sel : std_logic_vector(PCIE_ENDPOINTS -1 downto 0);
    signal dma_rst_sel : std_logic_vector(PCIE_ENDPOINTS -1 downto 0);

    -- =============================================================================================
    -- Piped PCIE interfaces
    -- =============================================================================================
    signal pcie_rq_mfb_data_piped      : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE*PCIE_RQ_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_rq_mfb_meta_piped      : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*PCIE_RQ_META_WIDTH                                                    -1 downto 0);
    signal pcie_rq_mfb_sof_piped       : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS                                                                       -1 downto 0);
    signal pcie_rq_mfb_eof_piped       : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS                                                                       -1 downto 0);
    signal pcie_rq_mfb_sof_pos_piped   : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1,log2(PCIE_RQ_MFB_REGION_SIZE))                                  -1 downto 0);
    signal pcie_rq_mfb_eof_pos_piped   : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_RQ_MFB_REGIONS*max(1,log2(PCIE_RQ_MFB_REGION_SIZE*PCIE_RQ_MFB_BLOCK_SIZE))           -1 downto 0);
    signal pcie_rq_mfb_src_rdy_piped   : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_rq_mfb_dst_rdy_piped   : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal pcie_cq_mfb_data_piped      : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_cq_mfb_meta_piped      : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH                                                    -1 downto 0);
    signal pcie_cq_mfb_sof_piped       : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS                                                                       -1 downto 0);
    signal pcie_cq_mfb_eof_piped       : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS                                                                       -1 downto 0);
    signal pcie_cq_mfb_sof_pos_piped   : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1,log2(PCIE_CQ_MFB_REGION_SIZE))                                  -1 downto 0);
    signal pcie_cq_mfb_eof_pos_piped   : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CQ_MFB_REGIONS*max(1,log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE))           -1 downto 0);
    signal pcie_cq_mfb_src_rdy_piped   : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_cq_mfb_dst_rdy_piped   : std_logic_vector(DMA_STREAMS-1 downto 0);

    signal pcie_cc_mfb_data_piped      : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE*PCIE_CC_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_cc_mfb_meta_piped      : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*PCIE_CC_META_WIDTH                                                    -1 downto 0);
    signal pcie_cc_mfb_sof_piped       : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS                                                                       -1 downto 0);
    signal pcie_cc_mfb_eof_piped       : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS                                                                       -1 downto 0);
    signal pcie_cc_mfb_sof_pos_piped   : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*max(1,log2(PCIE_CC_MFB_REGION_SIZE))                                  -1 downto 0);
    signal pcie_cc_mfb_eof_pos_piped   : slv_array_t(DMA_STREAMS-1 downto 0)(PCIE_CC_MFB_REGIONS*max(1,log2(PCIE_CC_MFB_REGION_SIZE*PCIE_CC_MFB_BLOCK_SIZE))           -1 downto 0);
    signal pcie_cc_mfb_src_rdy_piped   : std_logic_vector(DMA_STREAMS-1 downto 0);
    signal pcie_cc_mfb_dst_rdy_piped   : std_logic_vector(DMA_STREAMS-1 downto 0);

    -- attribute mark_debug : string;

    -- attribute mark_debug of PCIE_RC_MFB_DATA    : signal is "true";
    -- attribute mark_debug of PCIE_RC_MFB_SOF     : signal is "true";
    -- attribute mark_debug of PCIE_RC_MFB_EOF     : signal is "true";
    -- attribute mark_debug of PCIE_RC_MFB_SOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_RC_MFB_EOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_RC_MFB_SRC_RDY : signal is "true";
begin
    assert (DMA_STREAMS = PCIE_ENDPOINTS)
        report "DMA_WRAPPER(CALYPTE): This DMA core does not support multiple DMA endpoints. Only one DMA Module is allowed per PCIE endpoint"
        severity FAILURE;

    dma_pcie_endp_g : for i in 0 to PCIE_ENDPOINTS-1 generate

        RX_USR_MFB_DST_RDY(i) <= '1';
        RX_USR_MVB_DST_RDY(i) <= '1';

        TX_USR_MVB_LEN(i)      <= (others => '0');
        TX_USR_MVB_HDR_META(i) <= (others => '0');
        TX_USR_MVB_CHANNEL(i)  <= (others => '0');
        TX_USR_MVB_SRC_RDY(i)  <= '0';

        TX_USR_MFB_DATA(i) <= (others => '0');
        TX_USR_MFB_SOF(i) <= (others => '0');
        TX_USR_MFB_EOF(i) <= (others => '0');
        TX_USR_MFB_SOF_POS(i) <= (others => '0');
        TX_USR_MFB_EOF_POS(i) <= (others => '0');
        TX_USR_MFB_SRC_RDY(i) <= '0';

        --==============================================================================================
        --  DMA Iuventus Module
        --==============================================================================================
        dma_iuventus_i : entity work.DMA_IUVENTUS
            generic map(
                DEVICE => DEVICE,

                MFB_REGIONS     => PCIE_RQ_MFB_REGIONS,
                MFB_REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
                MFB_BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
                MFB_ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

                MI_WIDTH    => MI_WIDTH,
                MI_SAME_CLK => false,

                MPS =>  PCIE_MPS,
                MRRS => PCIE_MRRS
                )
            port map(
                CLK => dma_clk_sel(i),
                RST => dma_rst_sel(i),

                MI_CLK => MI_CLK,
                MI_RST => MI_RESET,

                PCIE_RQ_MFB_DATA    => pcie_rq_mfb_data_piped(i),
                PCIE_RQ_MFB_META    => pcie_rq_mfb_meta_piped(i),
                PCIE_RQ_MFB_SOF     => pcie_rq_mfb_sof_piped(i),
                PCIE_RQ_MFB_EOF     => pcie_rq_mfb_eof_piped(i),
                PCIE_RQ_MFB_SOF_POS => pcie_rq_mfb_sof_pos_piped(i),
                PCIE_RQ_MFB_EOF_POS => pcie_rq_mfb_eof_pos_piped(i),
                PCIE_RQ_MFB_SRC_RDY => pcie_rq_mfb_src_rdy_piped(i),
                PCIE_RQ_MFB_DST_RDY => pcie_rq_mfb_dst_rdy_piped(i),

                PCIE_CQ_MFB_DATA    => pcie_cq_mfb_data_piped(i),
                PCIE_CQ_MFB_META    => pcie_cq_mfb_meta_piped(i),
                PCIE_CQ_MFB_SOF     => pcie_cq_mfb_sof_piped(i),
                PCIE_CQ_MFB_EOF     => pcie_cq_mfb_eof_piped(i),
                PCIE_CQ_MFB_SOF_POS => pcie_cq_mfb_sof_pos_piped(i),
                PCIE_CQ_MFB_EOF_POS => pcie_cq_mfb_eof_pos_piped(i),
                PCIE_CQ_MFB_SRC_RDY => pcie_cq_mfb_src_rdy_piped(i),
                PCIE_CQ_MFB_DST_RDY => pcie_cq_mfb_dst_rdy_piped(i),

                PCIE_CC_MFB_DATA    => pcie_cc_mfb_data_piped(i),
                PCIE_CC_MFB_META    => pcie_cc_mfb_meta_piped(i),
                PCIE_CC_MFB_SOF     => pcie_cc_mfb_sof_piped(i),
                PCIE_CC_MFB_EOF     => pcie_cc_mfb_eof_piped(i),
                PCIE_CC_MFB_SOF_POS => pcie_cc_mfb_sof_pos_piped(i),
                PCIE_CC_MFB_EOF_POS => pcie_cc_mfb_eof_pos_piped(i),
                PCIE_CC_MFB_SRC_RDY => pcie_cc_mfb_src_rdy_piped(i),
                PCIE_CC_MFB_DST_RDY => pcie_cc_mfb_dst_rdy_piped(i),

                MI_ADDR => MI_ADDR(i),
                MI_DWR  => MI_DWR(i),
                MI_BE   => MI_BE(i),
                MI_RD   => MI_RD(i),
                MI_WR   => MI_WR(i),
                MI_DRD  => MI_DRD(i),
                MI_ARDY => MI_ARDY(i),
                MI_DRDY => MI_DRDY(i));

        pcie_mfb_asfifo_g : if (USE_ASFIFO) generate
            dma_clk_sel(i) <= USR_CLK;
            dma_rst_sel(i) <= USR_RESET;

            pcie_rq_mfb_asfifox_i : entity work.MFB_ASFIFOX
                generic map (
                    MFB_REGIONS         => PCIE_RQ_MFB_REGIONS,
                    MFB_REG_SIZE        => PCIE_RQ_MFB_REGION_SIZE,
                    MFB_BLOCK_SIZE      => PCIE_RQ_MFB_BLOCK_SIZE,
                    MFB_ITEM_WIDTH      => PCIE_RQ_MFB_ITEM_WIDTH,

                    FIFO_ITEMS          => 512,
                    RAM_TYPE            => "BRAM",
                    FWFT_MODE           => true,
                    OUTPUT_REG          => true,
                    METADATA_WIDTH      => PCIE_RQ_META_WIDTH,
                    DEVICE              => DEVICE,
                    ALMOST_FULL_OFFSET  => 2,
                    ALMOST_EMPTY_OFFSET => 2)
                port map (
                    RX_CLK     => USR_CLK,
                    RX_RESET   => USR_RESET,

                    RX_DATA    => pcie_rq_mfb_data_piped(i),
                    RX_META    => pcie_rq_mfb_meta_piped(i),
                    RX_SOF_POS => pcie_rq_mfb_sof_pos_piped(i),
                    RX_EOF_POS => pcie_rq_mfb_eof_pos_piped(i),
                    RX_SOF     => pcie_rq_mfb_sof_piped(i),
                    RX_EOF     => pcie_rq_mfb_eof_piped(i),
                    RX_SRC_RDY => pcie_rq_mfb_src_rdy_piped(i),
                    RX_DST_RDY => pcie_rq_mfb_dst_rdy_piped(i),

                    RX_AFULL   => open,
                    RX_STATUS  => open,

                    TX_CLK     => PCIE_USR_CLK(i),
                    TX_RESET   => PCIE_USR_RESET(i),

                    TX_DATA    => PCIE_RQ_MFB_DATA(i),
                    TX_META    => PCIE_RQ_MFB_META(i),
                    TX_SOF_POS => PCIE_RQ_MFB_SOF_POS(i),
                    TX_EOF_POS => PCIE_RQ_MFB_EOF_POS(i),
                    TX_SOF     => PCIE_RQ_MFB_SOF(i),
                    TX_EOF     => PCIE_RQ_MFB_EOF(i),
                    TX_SRC_RDY => PCIE_RQ_MFB_SRC_RDY(i),
                    TX_DST_RDY => PCIE_RQ_MFB_DST_RDY(i),

                    TX_AEMPTY  => open,
                    TX_STATUS  => open);

            pcie_cq_mfb_asfifox_i : entity work.MFB_ASFIFOX
                generic map (
                    MFB_REGIONS         => PCIE_CQ_MFB_REGIONS,
                    MFB_REG_SIZE        => PCIE_CQ_MFB_REGION_SIZE,
                    MFB_BLOCK_SIZE      => PCIE_CQ_MFB_BLOCK_SIZE,
                    MFB_ITEM_WIDTH      => PCIE_CQ_MFB_ITEM_WIDTH,

                    FIFO_ITEMS          => 512,
                    RAM_TYPE            => "BRAM",
                    FWFT_MODE           => true,
                    OUTPUT_REG          => true,
                    METADATA_WIDTH      => PCIE_CQ_META_WIDTH,
                    DEVICE              => DEVICE,
                    ALMOST_FULL_OFFSET  => 2,
                    ALMOST_EMPTY_OFFSET => 2)
                port map (
                    RX_CLK     => PCIE_USR_CLK(i),
                    RX_RESET   => PCIE_USR_RESET(i),

                    RX_DATA    => PCIE_CQ_MFB_DATA(i),
                    RX_META    => PCIE_CQ_MFB_META(i),
                    RX_SOF_POS => PCIE_CQ_MFB_SOF_POS(i),
                    RX_EOF_POS => PCIE_CQ_MFB_EOF_POS(i),
                    RX_SOF     => PCIE_CQ_MFB_SOF(i),
                    RX_EOF     => PCIE_CQ_MFB_EOF(i),
                    RX_SRC_RDY => PCIE_CQ_MFB_SRC_RDY(i),
                    RX_DST_RDY => PCIE_CQ_MFB_DST_RDY(i),

                    RX_AFULL   => open,
                    RX_STATUS  => open,

                    TX_CLK     => USR_CLK,
                    TX_RESET   => USR_RESET,

                    TX_DATA    => pcie_cq_mfb_data_piped(i),
                    TX_META    => pcie_cq_mfb_meta_piped(i),
                    TX_SOF_POS => pcie_cq_mfb_sof_pos_piped(i),
                    TX_EOF_POS => pcie_cq_mfb_eof_pos_piped(i),
                    TX_SOF     => pcie_cq_mfb_sof_piped(i),
                    TX_EOF     => pcie_cq_mfb_eof_piped(i),
                    TX_SRC_RDY => pcie_cq_mfb_src_rdy_piped(i),
                    TX_DST_RDY => pcie_cq_mfb_dst_rdy_piped(i),

                    TX_AEMPTY  => open,
                    TX_STATUS  => open);

            pcie_cc_mfb_asfifox_i : entity work.MFB_ASFIFOX
                generic map (
                    MFB_REGIONS         => PCIE_CC_MFB_REGIONS,
                    MFB_REG_SIZE        => PCIE_CC_MFB_REGION_SIZE,
                    MFB_BLOCK_SIZE      => PCIE_CC_MFB_BLOCK_SIZE,
                    MFB_ITEM_WIDTH      => PCIE_CC_MFB_ITEM_WIDTH,

                    FIFO_ITEMS          => 512,
                    RAM_TYPE            => "BRAM",
                    FWFT_MODE           => true,
                    OUTPUT_REG          => true,
                    METADATA_WIDTH      => PCIE_CC_META_WIDTH,
                    DEVICE              => DEVICE,
                    ALMOST_FULL_OFFSET  => 2,
                    ALMOST_EMPTY_OFFSET => 2)
                port map (
                    RX_CLK     => USR_CLK,
                    RX_RESET   => USR_RESET,

                    RX_DATA    => pcie_cc_mfb_data_piped(i),
                    RX_META    => pcie_cc_mfb_meta_piped(i),
                    RX_SOF_POS => pcie_cc_mfb_sof_pos_piped(i),
                    RX_EOF_POS => pcie_cc_mfb_eof_pos_piped(i),
                    RX_SOF     => pcie_cc_mfb_sof_piped(i),
                    RX_EOF     => pcie_cc_mfb_eof_piped(i),
                    RX_SRC_RDY => pcie_cc_mfb_src_rdy_piped(i),
                    RX_DST_RDY => pcie_cc_mfb_dst_rdy_piped(i),

                    RX_AFULL   => open,
                    RX_STATUS  => open,

                    TX_CLK     => PCIE_USR_CLK(i),
                    TX_RESET   => PCIE_USR_RESET(i),

                    TX_DATA    => PCIE_CC_MFB_DATA(i),
                    TX_META    => PCIE_CC_MFB_META(i),
                    TX_SOF_POS => PCIE_CC_MFB_SOF_POS(i),
                    TX_EOF_POS => PCIE_CC_MFB_EOF_POS(i),
                    TX_SOF     => PCIE_CC_MFB_SOF(i),
                    TX_EOF     => PCIE_CC_MFB_EOF(i),
                    TX_SRC_RDY => PCIE_CC_MFB_SRC_RDY(i),
                    TX_DST_RDY => PCIE_CC_MFB_DST_RDY(i),

                    TX_AEMPTY  => open,
                    TX_STATUS  => open);
        else generate
            dma_clk_sel(i) <= PCIE_USR_CLK(i);
            dma_rst_sel(i) <= PCIE_USR_RESET(i);

            pcie_rq_mfb_pipe_i : entity work.MFB_PIPE
                generic map (
                    REGIONS     => PCIE_RQ_MFB_REGIONS,
                    REGION_SIZE => PCIE_RQ_MFB_REGION_SIZE,
                    BLOCK_SIZE  => PCIE_RQ_MFB_BLOCK_SIZE,
                    ITEM_WIDTH  => PCIE_RQ_MFB_ITEM_WIDTH,

                    META_WIDTH  => PCIE_RQ_META_WIDTH,
                    FAKE_PIPE   => (not OUT_PIPE_EN),
                    USE_DST_RDY => TRUE,
                    PIPE_TYPE   => "REG",
                    DEVICE      => DEVICE)
                port map (
                    CLK        => PCIE_USR_CLK(i),
                    RESET      => PCIE_USR_RESET(i),

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
                    FAKE_PIPE   => (not OUT_PIPE_EN),
                    USE_DST_RDY => TRUE,
                    PIPE_TYPE   => "REG",
                    DEVICE      => DEVICE)
                port map (
                    CLK        => PCIE_USR_CLK(i),
                    RESET      => PCIE_USR_RESET(i),

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

            pcie_cc_mfb_pipe_i : entity work.MFB_PIPE
                generic map (
                    REGIONS     => PCIE_CC_MFB_REGIONS,
                    REGION_SIZE => PCIE_CC_MFB_REGION_SIZE,
                    BLOCK_SIZE  => PCIE_CC_MFB_BLOCK_SIZE,
                    ITEM_WIDTH  => PCIE_CC_MFB_ITEM_WIDTH,

                    META_WIDTH  => PCIE_CC_META_WIDTH,
                    FAKE_PIPE   => (not OUT_PIPE_EN),
                    USE_DST_RDY => TRUE,
                    PIPE_TYPE   => "REG",
                    DEVICE      => DEVICE)
                port map (
                    CLK        => PCIE_USR_CLK(i),
                    RESET      => PCIE_USR_RESET(i),

                    RX_DATA    => pcie_cc_mfb_data_piped(i),
                    RX_META    => pcie_cc_mfb_meta_piped(i),
                    RX_SOF_POS => pcie_cc_mfb_sof_pos_piped(i),
                    RX_EOF_POS => pcie_cc_mfb_eof_pos_piped(i),
                    RX_SOF     => pcie_cc_mfb_sof_piped(i),
                    RX_EOF     => pcie_cc_mfb_eof_piped(i),
                    RX_SRC_RDY => pcie_cc_mfb_src_rdy_piped(i),
                    RX_DST_RDY => pcie_cc_mfb_dst_rdy_piped(i),

                    TX_DATA    => PCIE_CC_MFB_DATA(i),
                    TX_META    => PCIE_CC_MFB_META(i),
                    TX_SOF_POS => PCIE_CC_MFB_SOF_POS(i),
                    TX_EOF_POS => PCIE_CC_MFB_EOF_POS(i),
                    TX_SOF     => PCIE_CC_MFB_SOF(i),
                    TX_EOF     => PCIE_CC_MFB_EOF(i),
                    TX_SRC_RDY => PCIE_CC_MFB_SRC_RDY(i),
                    TX_DST_RDY => PCIE_CC_MFB_DST_RDY(i));
        end generate;
    end generate;
end architecture;
