-- h2c_dma_hyperion.vhd: Host-to-Card controller for DMA Hyperion
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;

entity H2C_DMA_HYPERION is
    generic (
        DEVICE : string := "ULTRASCALE";
        MI_WIDTH : natural := 32;

        -- HBM parameters for its AXI interface
        HBM_DATA_WIDTH  : natural := 256;
        HBM_ADDR_WIDTH  : natural := 34;
        HBM_BURST_WIDTH : natural := 2;
        HBM_ID_WIDTH    : natural := 6;
        HBM_LEN_WIDTH   : natural := 4;
        HBM_SIZE_WIDTH  : natural := 3;
        HBM_RESP_WIDTH  : natural := 2;

        -- PCIe MFB configuration (Completer Request interface)
        PCIE_CQ_MFB_REGIONS     : natural := 1;
        PCIE_CQ_MFB_REGION_SIZE : natural := 1;
        PCIE_CQ_MFB_BLOCK_SIZE  : natural := 8;
        PCIE_CQ_MFB_ITEM_WIDTH  : natural := 32
        );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- PCIe Completer Request MFB interface
        --
        -- Receives transactions from the PCIe domain
        -- =========================================================================================
        PCIE_CQ_MFB_BE      : in std_logic_vector((PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH)/8 -1 downto 0);
        PCIE_CQ_MFB_DATA    : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CQ_MFB_META    : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
        PCIE_CQ_MFB_SOF     : in  std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_EOF     : in  std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
        PCIE_CQ_MFB_SOF_POS : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0) := (others => '0');
        PCIE_CQ_MFB_EOF_POS : in  std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_CQ_MFB_SRC_RDY : in  std_logic;
        PCIE_CQ_MFB_DST_RDY : out std_logic := '1';

        -- =========================================================================================
        -- HBM output interface
        -- =========================================================================================
        HBM_AXI_AWID    : out std_logic_vector(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_AWADDR  : out std_logic_vector(HBM_ADDR_WIDTH-1 downto 0);
        HBM_AXI_AWLEN   : out std_logic_vector(HBM_LEN_WIDTH-1 downto 0);
        HBM_AXI_AWSIZE  : out std_logic_vector(HBM_SIZE_WIDTH-1 downto 0);
        HBM_AXI_AWBURST : out std_logic_vector(HBM_BURST_WIDTH-1 downto 0);
        HBM_AXI_AWVALID : out std_logic;
        HBM_AXI_AWREADY : in  std_logic;

        HBM_AXI_WDATA        : out std_logic_vector(HBM_DATA_WIDTH-1 downto 0);
        HBM_AXI_WSTRB        : out std_logic_vector((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_WDATA_PARITY : out std_logic_vector((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_WLAST        : out std_logic;
        HBM_AXI_WVALID       : out std_logic;
        HBM_AXI_WREADY       : in  std_logic;

        HBM_AXI_BID    : in  std_logic_vector(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_BRESP  : in  std_logic_vector(HBM_RESP_WIDTH-1 downto 0);
        HBM_AXI_BVALID : in  std_logic;
        HBM_AXI_BREADY : out std_logic;

        -- =========================================================================================
        -- Control MI bus for software access
        -- =========================================================================================
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ARDY : out std_logic;
        MI_DRDY : out std_logic
    );
end entity;

architecture FULL of H2C_DMA_HYPERION is
    signal inp_fifo_mfb_data    : std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
    signal inp_fifo_mfb_be      : std_logic_vector((PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH)/8 -1 downto 0);
    signal inp_fifo_mfb_meta    : std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
    signal inp_fifo_mfb_meta_comp : std_logic_vector((PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH)/8 + PCIE_CQ_META_WIDTH -1 downto 0);
    signal inp_fifo_mfb_sof     : std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
    signal inp_fifo_mfb_eof     : std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
    signal inp_fifo_mfb_sof_pos : std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0);
    signal inp_fifo_mfb_eof_pos : std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
    signal inp_fifo_mfb_src_rdy : std_logic;
    signal inp_fifo_mfb_dst_rdy : std_logic;

    signal inp_fifo_afull   : std_logic;
    signal cq_drop_eff      : std_logic;   -- effective drop decision for the current cycle
    signal cq_drop_held     : std_logic;   -- registered SOF decision, held across the frame
    signal cq_to_fifo_srdy  : std_logic;   -- gated SRC_RDY into the FIFO
    signal cq_drop_pulse    : std_logic;   -- one pulse per dropped frame (at its SOF)

    signal mex_mfb_meta_tr_len : slv_array_t(PCIE_CQ_MFB_REGIONS -1 downto 0)(13 -1 downto 0);
    signal mex_mfb_meta_be     : slv_array_t(PCIE_CQ_MFB_REGIONS -1 downto 0)((PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH)/8 -1 downto 0);
    signal mex_mfb_meta_addr   : slv_array_t(PCIE_CQ_MFB_REGIONS -1 downto 0)(64 -1 downto 0);

    signal mex_mfb_data        : std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
    signal mex_mfb_sof         : std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
    signal mex_mfb_eof         : std_logic_vector(PCIE_CQ_MFB_REGIONS -1 downto 0);
    signal mex_mfb_sof_pos     : std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE)) -1 downto 0);
    signal mex_mfb_eof_pos     : std_logic_vector(PCIE_CQ_MFB_REGIONS*max(1, log2(PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE)) -1 downto 0);
    signal mex_mfb_src_rdy     : std_logic;
    signal mex_mfb_dst_rdy     : std_logic;

    signal shfr_mfb_meta_tr_len : std_logic_vector(13 -1 downto 0);
    signal shfr_mfb_meta_be     : std_logic_vector((PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH)/8 -1 downto 0);
    signal shfr_mfb_meta_addr   : std_logic_vector(64 -1 downto 0);

    signal shfr_mfb_data        : std_logic_vector(PCIE_CQ_MFB_REGIONS*PCIE_CQ_MFB_REGION_SIZE*PCIE_CQ_MFB_BLOCK_SIZE*PCIE_CQ_MFB_ITEM_WIDTH-1 downto 0);
    signal shfr_mfb_sof         : std_logic;
    signal shfr_mfb_eof         : std_logic;
    signal shfr_mfb_src_rdy     : std_logic;
    signal shfr_mfb_dst_rdy     : std_logic;

    signal pcie_req_total_bytes    : std_logic_vector(12 downto 0);
    signal pcie_rd_req_total_incr  : std_logic;
    signal pcie_wr_req_total_incr  : std_logic;

    signal cq_in_hdr      : std_logic_vector(PCIE_META_REQ_HDR_W -1 downto 0);
    signal cq_in_dw_count : std_logic_vector(10 downto 0);
    signal cq_in_fbe      : std_logic_vector(3 downto 0);
    signal cq_in_lbe      : std_logic_vector(3 downto 0);
    signal cq_drop_bytes  : std_logic_vector(13 -1 downto 0);
begin

    assert (PCIE_CQ_MFB_REGIONS = 1 and PCIE_CQ_MFB_REGION_SIZE = 1 and PCIE_CQ_MFB_BLOCK_SIZE = 8 and PCIE_CQ_MFB_ITEM_WIDTH = 32)
        report "Currently only configuration with 1 region of size 1 block of 8 items of 32 bits width is supported for the PCIe CQ MFB interface."
        severity FAILURE;

    sw_manager_i : entity work.H2C_DMA_HYPERION_SW_MGR
    generic map (
        MI_WIDTH => MI_WIDTH
    )
    port map (
        CLK   => CLK,
        RESET => RESET,

        MI_ADDR => MI_ADDR,
        MI_DWR  => MI_DWR,
        MI_BE   => MI_BE,
        MI_RD   => MI_RD,
        MI_WR   => MI_WR,
        MI_DRD  => MI_DRD,
        MI_ARDY => MI_ARDY,
        MI_DRDY => MI_DRDY,

        PCIE_REQ_TOTAL_BYTES => pcie_req_total_bytes,
        PCIE_RD_REQ_TOTAL_INCR => pcie_rd_req_total_incr,
        PCIE_WR_REQ_TOTAL_INCR => pcie_wr_req_total_incr,

        PCIE_CQ_MFB_SRC_RDY => PCIE_CQ_MFB_SRC_RDY,
        PCIE_CQ_MFB_DST_RDY => PCIE_CQ_MFB_DST_RDY,
        PCIE_CQ_DROP_INCR  => cq_drop_pulse,
        PCIE_CQ_DROP_BYTES => cq_drop_bytes,

        HBM_AXI_AWVALID => HBM_AXI_AWVALID,
        HBM_AXI_AWREADY => HBM_AXI_AWREADY,

        HBM_AXI_WSTRB  => HBM_AXI_WSTRB,
        HBM_AXI_WVALID => HBM_AXI_WVALID,
        HBM_AXI_WREADY => HBM_AXI_WREADY
    );

    input_fifox_i : entity work.MFB_FIFOX
        generic map (
            REGIONS             => PCIE_CQ_MFB_REGIONS,
            REGION_SIZE         => PCIE_CQ_MFB_REGION_SIZE,
            BLOCK_SIZE          => PCIE_CQ_MFB_BLOCK_SIZE,
            ITEM_WIDTH          => PCIE_CQ_MFB_ITEM_WIDTH,
            META_WIDTH          => PCIE_CQ_META_WIDTH + (PCIE_CQ_MFB_DATA'length / 8),
            FIFO_DEPTH          => 512,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 144,
            ALMOST_EMPTY_OFFSET => 2)
        port map (
            CLK         => CLK,
            RST         => RESET,

            RX_DATA     => PCIE_CQ_MFB_DATA,
            RX_META     => (PCIE_CQ_MFB_BE, PCIE_CQ_MFB_META),
            RX_SOF_POS  => PCIE_CQ_MFB_SOF_POS,
            RX_EOF_POS  => PCIE_CQ_MFB_EOF_POS,
            RX_SOF      => PCIE_CQ_MFB_SOF,
            RX_EOF      => PCIE_CQ_MFB_EOF,
            RX_SRC_RDY  => cq_to_fifo_srdy,
            RX_DST_RDY  => open,

            TX_DATA     => inp_fifo_mfb_data,
            TX_META     => inp_fifo_mfb_meta_comp,
            TX_SOF_POS  => inp_fifo_mfb_sof_pos,
            TX_EOF_POS  => inp_fifo_mfb_eof_pos,
            TX_SOF      => inp_fifo_mfb_sof,
            TX_EOF      => inp_fifo_mfb_eof,
            TX_SRC_RDY  => inp_fifo_mfb_src_rdy,
            TX_DST_RDY  => inp_fifo_mfb_dst_rdy,

            FIFO_STATUS => open,
            FIFO_AFULL  => inp_fifo_afull,
            FIFO_AEMPTY => open);

    (inp_fifo_mfb_be, inp_fifo_mfb_meta) <= inp_fifo_mfb_meta_comp;

    -- The H2C input must never back-pressure the shared PCIe CQ (doing so wedges the
    -- whole endpoint). Always accept CQ words; for each incoming frame decide AT SOF
    -- whether the input FIFO has room for a whole max-size frame (FIFO_AFULL = not enough
    -- room). If not, drop the entire frame and pulse a drop counter. Because a frame is
    -- only forwarded when a full frame fits, the FIFO never fills mid-frame, so its
    -- RX_DST_RDY stays asserted throughout and the CQ is consumed at line rate.
    PCIE_CQ_MFB_DST_RDY <= '1';

    cq_drop_eff    <= inp_fifo_afull when (PCIE_CQ_MFB_SOF(0) = '1') else cq_drop_held;
    cq_to_fifo_srdy <= PCIE_CQ_MFB_SRC_RDY and (not cq_drop_eff);
    cq_drop_pulse  <= PCIE_CQ_MFB_SRC_RDY and PCIE_CQ_MFB_SOF(0) and inp_fifo_afull;

    cq_drop_hold_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                cq_drop_held <= '0';
            elsif (PCIE_CQ_MFB_SRC_RDY = '1') then
                cq_drop_held <= cq_drop_eff;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- CQ header extraction for dropped-frame byte counting
    --
    -- Mirrors the per-region header extraction in H2C_HYPERION_META_EXT
    -- (REGIONS=1, region 0 only). The deparser and byte-count components are
    -- driven from the raw CQ input so that frames dropped before the input
    -- FIFO are still measured.
    -- =========================================================================
    cq_drop_hdr_sel_g : if (DEVICE = "ULTRASCALE") generate
        cq_in_hdr <= PCIE_CQ_MFB_DATA(PCIE_CQ_META_HEADER);
    else generate
        cq_in_hdr <= PCIE_CQ_MFB_META(PCIE_CQ_META_HEADER);
    end generate;

    cq_drop_hdr_deparser_i : entity work.PCIE_CQ_HDR_DEPARSER
    generic map (
        DEVICE => DEVICE
    )
    port map (
        OUT_TAG          => open,
        OUT_ADDRESS      => open,
        OUT_REQ_ID       => open,
        OUT_TC           => open,
        OUT_DW_CNT       => cq_in_dw_count,
        OUT_ATTRIBUTES   => open,
        OUT_FBE          => cq_in_fbe,
        OUT_LBE          => cq_in_lbe,
        OUT_ADDRESS_TYPE => open,
        OUT_TARGET_FUNC  => open,
        OUT_BAR_ID       => open,
        OUT_BAR_APERTURE => open,
        OUT_ADDR_LEN     => open,
        OUT_REQ_TYPE     => open,

        IN_HEADER     => cq_in_hdr,
        IN_FBE        => PCIE_CQ_MFB_META(PCIE_CQ_META_FBE),
        IN_LBE        => PCIE_CQ_MFB_META(PCIE_CQ_META_LBE),
        IN_INTEL_META => std_logic_vector(to_unsigned(24, 6)) & PCIE_CQ_MFB_META(PCIE_CQ_META_BAR) & (8 - 1 downto 0 => '0')
    );

    cq_drop_byte_count_i : entity work.PCIE_BYTE_COUNT
    generic map (
        OUTPUT_REG => FALSE
    )
    port map (
        CLK         => CLK,
        RESET       => RESET,

        IN_DW_COUNT  => cq_in_dw_count,
        IN_FIRST_BE  => cq_in_fbe,
        IN_LAST_BE   => cq_in_lbe,

        OUT_FIRST_IB  => open,
        OUT_LAST_IB   => open,
        OUT_BYTE_COUNT => cq_drop_bytes
    );

    h2c_dma_hyperion_meta_ext_i : entity work.H2C_HYPERION_META_EXT
        generic map (
            DEVICE          => DEVICE,
            MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
            MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH)
        port map (
            CLK                    => CLK,
            RESET                  => RESET,

            PCIE_MFB_BE            => inp_fifo_mfb_be,
            PCIE_MFB_DATA          => inp_fifo_mfb_data,
            PCIE_MFB_META          => inp_fifo_mfb_meta,
            PCIE_MFB_SOF           => inp_fifo_mfb_sof,
            PCIE_MFB_EOF           => inp_fifo_mfb_eof,
            PCIE_MFB_SOF_POS       => inp_fifo_mfb_sof_pos,
            PCIE_MFB_EOF_POS       => inp_fifo_mfb_eof_pos,
            PCIE_MFB_SRC_RDY       => inp_fifo_mfb_src_rdy,
            PCIE_MFB_DST_RDY       => inp_fifo_mfb_dst_rdy,

            USR_MFB_META_TR_LEN    => mex_mfb_meta_tr_len,
            USR_MFB_META_BE        => mex_mfb_meta_be,
            USR_MFB_META_ADDR      => mex_mfb_meta_addr,

            USR_MFB_DATA           => mex_mfb_data,
            USR_MFB_SOF            => mex_mfb_sof,
            USR_MFB_EOF            => mex_mfb_eof,
            USR_MFB_SOF_POS        => mex_mfb_sof_pos,
            USR_MFB_EOF_POS        => mex_mfb_eof_pos,
            USR_MFB_SRC_RDY        => mex_mfb_src_rdy,
            USR_MFB_DST_RDY        => mex_mfb_dst_rdy,

            PCIE_REQ_TOTAL_BYTES   => pcie_req_total_bytes,
            PCIE_RD_REQ_TOTAL_INCR => pcie_rd_req_total_incr,
            PCIE_WR_REQ_TOTAL_INCR => pcie_wr_req_total_incr);

    data_shifter_i : entity work.H2C_HYPERION_DATA_SHIFTER
        generic map (
            MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
            MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH)
        port map (
            CLK                => CLK,
            RST                => RESET,

            RX_MFB_META_TR_LEN => mex_mfb_meta_tr_len(0),
            RX_MFB_META_BE     => mex_mfb_meta_be(0),
            RX_MFB_META_ADDR   => mex_mfb_meta_addr(0),

            RX_MFB_DATA        => mex_mfb_data,
            RX_MFB_SOF         => mex_mfb_sof(0),
            RX_MFB_EOF         => mex_mfb_eof(0),
            RX_MFB_SOF_POS     => mex_mfb_sof_pos,
            RX_MFB_EOF_POS     => mex_mfb_eof_pos,
            RX_MFB_SRC_RDY     => mex_mfb_src_rdy,
            RX_MFB_DST_RDY     => mex_mfb_dst_rdy,

            TX_MFB_META_TR_LEN => shfr_mfb_meta_tr_len,
            TX_MFB_META_BE     => shfr_mfb_meta_be,
            TX_MFB_META_ADDR   => shfr_mfb_meta_addr,

            TX_MFB_DATA        => shfr_mfb_data,
            TX_MFB_SOF         => shfr_mfb_sof,
            TX_MFB_EOF         => shfr_mfb_eof,
            TX_MFB_SRC_RDY     => shfr_mfb_src_rdy,
            TX_MFB_DST_RDY     => shfr_mfb_dst_rdy);

    axi_adapter_i : entity work.H2C_HYPERION_AXI_ADAPTER
        generic map (
            MFB_REGIONS     => PCIE_CQ_MFB_REGIONS,
            MFB_REGION_SIZE => PCIE_CQ_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => PCIE_CQ_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => PCIE_CQ_MFB_ITEM_WIDTH,

            HBM_DATA_WIDTH  => HBM_DATA_WIDTH,
            HBM_ADDR_WIDTH  => HBM_ADDR_WIDTH,
            HBM_BURST_WIDTH => HBM_BURST_WIDTH,
            HBM_ID_WIDTH    => HBM_ID_WIDTH,
            HBM_LEN_WIDTH   => HBM_LEN_WIDTH,
            HBM_SIZE_WIDTH  => HBM_SIZE_WIDTH,
            HBM_RESP_WIDTH  => HBM_RESP_WIDTH)
        port map (
            RX_MFB_META_TR_LEN  => shfr_mfb_meta_tr_len,
            RX_MFB_META_BE      => shfr_mfb_meta_be,
            RX_MFB_META_ADDR    => shfr_mfb_meta_addr,
            RX_MFB_DATA         => shfr_mfb_data,
            RX_MFB_SOF          => shfr_mfb_sof,
            RX_MFB_EOF          => shfr_mfb_eof,
            RX_MFB_SRC_RDY      => shfr_mfb_src_rdy,
            RX_MFB_DST_RDY      => shfr_mfb_dst_rdy,

            HBM_AXI_AWID        => HBM_AXI_AWID,
            HBM_AXI_AWADDR      => HBM_AXI_AWADDR,
            HBM_AXI_AWLEN       => HBM_AXI_AWLEN,
            HBM_AXI_AWSIZE      => HBM_AXI_AWSIZE,
            HBM_AXI_AWBURST     => HBM_AXI_AWBURST,
            HBM_AXI_AWVALID     => HBM_AXI_AWVALID,
            HBM_AXI_AWREADY     => HBM_AXI_AWREADY,

            HBM_AXI_WDATA           => HBM_AXI_WDATA,
            HBM_AXI_WSTRB           => HBM_AXI_WSTRB,
            HBM_AXI_WDATA_PARITY    => HBM_AXI_WDATA_PARITY,
            HBM_AXI_WLAST           => HBM_AXI_WLAST,
            HBM_AXI_WVALID          => HBM_AXI_WVALID,
            HBM_AXI_WREADY          => HBM_AXI_WREADY,

            HBM_AXI_BID        => HBM_AXI_BID,
            HBM_AXI_BRESP      => HBM_AXI_BRESP,
            HBM_AXI_BVALID     => HBM_AXI_BVALID,
            HBM_AXI_BREADY     => HBM_AXI_BREADY);
end architecture;
