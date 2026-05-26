-- nvme_buffer_unit.vhd: a HDL implementation of a multi-purpose buffer with a PCIe response logic
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note: CQ means either:
--      1. Completer Request interface of the PCIe Hard IP
--      2. Completion Queue specified by the NVMe standard
--
-- Sorry for the confusion but I have not found better distinction yet. I have tried to distinguish
-- them as good as possible.
--
--
use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;

entity NVME_BUFFER_UNIT is
    generic (
        -- Determines the amount of separate address spaces within the buffer
        CHANNELS : natural := 2;
        -- Determines the depth of every separate address space in the buffer
        BUFF_POINTER_WIDTH : natural := 17;
        -- Enables the port B of the transaction buffer
        BUFF_B_PORT_EN : boolean := TRUE;
        -- Enables barrel shifter on the port B of the buffer which enables unaligned reads.
        -- Otherwise the reads are aligned by the multiples of the PCIE_CC_MFB_DATA'length
        BUFF_B_BARREL_SHIFT_EN : boolean := FALSE;

        -- MFB configuration shared between both PCIe interfaces
        MFB_REGIONS     : natural  := 2;
        MFB_REGION_SIZE : natural  := 1;
        MFB_BLOCK_SIZE  : natural  := 8;
        MFB_ITEM_WIDTH  : natural  := 32;
        -- FPGA device string
        DEVICE          : string   := "ULTRASCALE";
        -- Maximum Read Reaquest SIze according to the PCIe specification (up to 4096 B)
        MRRS            : positive := 2**12;
        -- Mapping of BAR to a memory sector 0 all other BAR indexes go to sector 1
        BUFF_SECT0_BAR  : std_logic_vector(2 downto 0) := "000"
        );
    port(
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- Header from the Metadata Extractor
        -- =========================================================================================
        PCIE_HDR_ADDR     : in slv_array_t(MFB_REGIONS -1 downto 0)(63 downto 0);
        PCIE_HDR_DATA_RAW : in slv_array_t(MFB_REGIONS -1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);
        PCIE_HDR_BYTE_CNT : in slv_array_t(MFB_REGIONS -1 downto 0)(13 -1 downto 0);
        PCIE_HDR_VLD      : in std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_HDR_SRC_RDY  : in std_logic;
        PCIE_HDR_DST_RDY  : out std_logic;

        -- =========================================================================================
        -- Incoming PCIe data without PCIe header
        -- =========================================================================================
        RX_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RX_MFB_META    : in  slv_array_t(MFB_REGIONS -1 downto 0)(((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8) + maximum(1, log2(CHANNELS)) + 62 - 1 downto 0);
        RX_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- PCIE Completion Completer interface
        -- =========================================================================================
        PCIE_CC_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CC_MFB_META    : out std_logic_vector(MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
        PCIE_CC_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        PCIE_CC_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        PCIE_CC_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        PCIE_CC_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_CC_MFB_SRC_RDY : out std_logic;
        PCIE_CC_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Free port from the transaction buffer
        -- =========================================================================================
        BUFF_CHAN_B : in std_logic_vector(maximum(1, log2(CHANNELS)) -1 downto 0);
        BUFF_DATA_B : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH -1 downto 0);
        BUFF_ADDR_B : in std_logic_vector(BUFF_POINTER_WIDTH -1 downto 0);
        BUFF_EN_B : in std_logic;
        BUFF_DATA_VLD_B : out std_logic;

        -- =========================================================================================
        -- Status interface
        -- =========================================================================================
        RD_PROCESSED_BYTES : out std_logic_vector(log2(MRRS+1) -1 downto 0);
        LAST_READ_ADDR     : out std_logic_vector(63 downto 0);
        STAT_UPD_EN        : out std_logic
        );
end entity;

architecture FULL of NVME_BUFFER_UNIT is
    constant MFB_LENGTH         : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;

    -- =============================================================================================
    -- Defining ranges for meta signal
    -- =============================================================================================
    constant META_PCIE_ADDR_W    : natural := 64;
    constant META_BYTE_CNT_W     : natural := 13;
    -- constant META_BAR_ID_W       : natural := 3;
    constant META_PCIE_HDR_RAW_W : natural := PCIE_META_REQ_HDR_W;
    -- constant META_BE_W           : natural := (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8;

    constant META_PCIE_ADDR_O    : natural := 0;
    constant META_BYTE_CNT_O     : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    -- constant META_BAR_ID_O       : natural := META_BYTE_CNT_O + META_BYTE_CNT_W;
    constant META_PCIE_HDR_RAW_O : natural := META_BYTE_CNT_O + META_BYTE_CNT_W;
    -- constant META_BE_O           : natural := META_BAR_ID_O + META_BAR_ID_W;

    subtype META_PCIE_ADDR is natural range META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O;
    subtype META_BYTE_CNT is natural range META_BYTE_CNT_O + META_BYTE_CNT_W -1 downto META_BYTE_CNT_O;
    -- subtype META_BAR_ID is natural range META_BAR_ID_O + META_BAR_ID_W -1 downto META_BAR_ID_O;
    subtype META_PCIE_HDR_RAW is natural range META_PCIE_HDR_RAW_O + META_PCIE_HDR_RAW_W -1 downto META_PCIE_HDR_RAW_O;
    -- subtype META_BE is natural range META_BE_O + META_BE_W -1 downto META_BE_O;

    constant HDR_META_WIDTH_INT : natural := META_PCIE_HDR_RAW_O + META_PCIE_HDR_RAW_W;
    -- =============================================================================================

    -- Input metadata for the transaction buffer
    signal rx_mfb_meta_parsed_arr : slv_array_t(MFB_REGIONS -1 downto 0)((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 + maximum(1, log2(CHANNELS))+ META_PCIE_ADDR_W-2 +1 -1 downto 0);

    -- =============================================================================================
    -- PCIe header FIFO
    -- =============================================================================================
    signal hdr_fifo_din      : slv_array_t(MFB_REGIONS -1 downto 0)(HDR_META_WIDTH_INT -1 downto 0);
    signal hdr_fifo_wr       : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal hdr_fifo_full     : std_logic;
    signal hdr_fifo_dout     : std_logic_vector(HDR_META_WIDTH_INT -1 downto 0);
    signal hdr_fifo_rd       : std_logic;
    signal hdr_fifo_empty    : std_logic;

    -- =============================================================================================
    -- Transaction Buffer read interface
    -- =============================================================================================
    signal tr_buff_chan_a     : std_logic_vector(0 downto 0);
    signal tr_buff_data_a     : std_logic_vector(MFB_LENGTH -1 downto 0);
    signal tr_buff_addr_a     : std_logic_vector(BUFF_POINTER_WIDTH -1 downto 0);
    signal tr_buff_en_a       : std_logic;
    signal tr_buff_data_vld_a : std_logic;

    -- =============================================================================================
    -- Generated CC Header for Read Completions
    -- =============================================================================================
    signal cc_hdr_data    : std_logic_vector(PCIE_META_CPL_HDR_W -1 downto 0);
    signal cc_hdr_src_rdy : std_logic;
    signal cc_hdr_dst_rdy : std_logic;

    -- =============================================================================================
    -- Data transported within the Read Completion
    -- =============================================================================================
    signal cpl_proc_mfb_data    : std_logic_vector(RX_MFB_DATA'range);
    signal cpl_proc_mfb_sof     : std_logic_vector(0 downto 0);
    signal cpl_proc_mfb_eof     : std_logic_vector(0 downto 0);
    signal cpl_proc_mfb_sof_pos : std_logic_vector(0 downto 0);
    signal cpl_proc_mfb_eof_pos : std_logic_vector(log2(64) -1 downto 0);
    signal cpl_proc_mfb_src_rdy : std_logic;
    signal cpl_proc_mfb_dst_rdy : std_logic;
begin
    hdr_fifo_input_assign_g : for reg_idx in (MFB_REGIONS - 1) downto 0 generate
        hdr_fifo_din(reg_idx) <= PCIE_HDR_DATA_RAW(reg_idx) & PCIE_HDR_BYTE_CNT(reg_idx) & PCIE_HDR_ADDR(reg_idx);
        hdr_fifo_wr(reg_idx)  <= PCIE_HDR_SRC_RDY and PCIE_HDR_VLD(reg_idx);
    end generate;

    RX_MFB_DST_RDY <= '1';
    PCIE_HDR_DST_RDY <= not hdr_fifo_full;

    pcie_hdr_fifox_multi_i : entity work.FIFOX_MULTI(FULL)
        generic map (
            DATA_WIDTH          => HDR_META_WIDTH_INT,
            ITEMS               => 2**13,
            WRITE_PORTS         => MFB_REGIONS,
            READ_PORTS          => 1,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 2,
            ALMOST_EMPTY_OFFSET => 2,
            ALLOW_SINGLE_FIFO   => TRUE,
            SAFE_READ_MODE      => FALSE)
        port map (
            CLK   => CLK,
            RESET => RESET,

            DI    => slv_array_ser(hdr_fifo_din),
            WR    => hdr_fifo_wr,
            FULL  => hdr_fifo_full,
            AFULL => open,

            DO       => hdr_fifo_dout,
            RD(0)    => hdr_fifo_rd,
            EMPTY(0) => hdr_fifo_empty,
            AEMPTY   => open);

    meta_parsing_g : for reg_idx in 0 to (MFB_REGIONS-1) generate
        rx_mfb_meta_parsed_arr(reg_idx) <= RX_MFB_META(reg_idx) & '0';
    end generate;

    tx_dma_trans_buffer_i : entity work.TX_DMA_PCIE_TRANS_BUFFER
        generic map (
            DEVICE          => DEVICE,
            CHANNELS        => CHANNELS,
            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
            POINTER_WIDTH   => BUFF_POINTER_WIDTH,

            SPLIT_READ_PORTS       => BUFF_B_PORT_EN,
            READ_BARREL_SHIFTER_EN => (BUFF_B_BARREL_SHIFT_EN, TRUE))
        port map (
            CLK   => CLK,
            RESET => RESET,

            PCIE_MFB_DATA    => RX_MFB_DATA,
            PCIE_MFB_META    => rx_mfb_meta_parsed_arr,
            PCIE_MFB_SOF     => RX_MFB_SOF,
            PCIE_MFB_SRC_RDY => RX_MFB_SRC_RDY,

            RD_CHAN_A     => tr_buff_chan_a,
            RD_DATA_A     => tr_buff_data_a,
            RD_ADDR_A     => tr_buff_addr_a,
            RD_EN_A       => tr_buff_en_a,
            RD_DATA_VLD_A => tr_buff_data_vld_a,

            RD_CHAN_B     => BUFF_CHAN_B,
            RD_DATA_B     => BUFF_DATA_B,
            RD_ADDR_B     => BUFF_ADDR_B,
            RD_EN_B       => BUFF_EN_B,
            RD_DATA_VLD_B => BUFF_DATA_VLD_B);

    pcie_read_responder_i : entity work.PCIE_READ_RESPONDER
        generic map (
            DEVICE       => DEVICE,
            PKT_SIZE_MAX => MRRS,

            MFB_REGIONS     => 1,
            MFB_REGION_SIZE => 1,
            MFB_BLOCK_SIZE  => 64,
            MFB_ITEM_WIDTH  => 8,

            BUFF_POINTER_WIDTH => BUFF_POINTER_WIDTH,
            BUFF_SECT0_BAR     => BUFF_SECT0_BAR)
        port map (
            CLK   => CLK,
            RESET => RESET,

            TX_MFB_DATA    => cpl_proc_mfb_data,
            TX_MFB_SOF     => cpl_proc_mfb_sof,
            TX_MFB_EOF     => cpl_proc_mfb_eof,
            TX_MFB_SOF_POS => cpl_proc_mfb_sof_pos,
            TX_MFB_EOF_POS => cpl_proc_mfb_eof_pos,
            TX_MFB_SRC_RDY => cpl_proc_mfb_src_rdy,
            TX_MFB_DST_RDY => cpl_proc_mfb_dst_rdy,

            -- TODO: add a 1 bit information for a specific header if this should be sent without
            -- data
            CC_HDR_DATA    => cc_hdr_data,
            CC_HDR_SRC_RDY => cc_hdr_src_rdy,
            CC_HDR_DST_RDY => cc_hdr_dst_rdy,

            CQ_HDR_ADDR     => hdr_fifo_dout(META_PCIE_ADDR),
            CQ_HDR_DATA     => hdr_fifo_dout(META_PCIE_HDR_RAW),
            CQ_HDR_BYTE_LNG => hdr_fifo_dout(META_BYTE_CNT),
            CQ_HDR_SRC_RDY  => not hdr_fifo_empty,
            CQ_HDR_DST_RDY  => hdr_fifo_rd,

            DATA_BUFF_RD_CHAN     => tr_buff_chan_a,
            DATA_BUFF_RD_DATA     => tr_buff_data_a,
            DATA_BUFF_RD_ADDR     => tr_buff_addr_a,
            DATA_BUFF_RD_EN       => tr_buff_en_a,
            DATA_BUFF_RD_DATA_VLD => tr_buff_data_vld_a,

            RD_CPL_SENT_CNTR_BYTES => RD_PROCESSED_BYTES,
            LAST_READ_ADDR         => LAST_READ_ADDR,
            STAT_UPD_EN            => STAT_UPD_EN);

    nvme_cc_pkt_dispatcher_i : entity work.NVME_CC_PKT_DISPATCHER
        generic map (
            RX_REGIONS     => 1,
            RX_REGION_SIZE => 1,
            RX_BLOCK_SIZE  => 64,
            RX_ITEM_WIDTH  => 8,

            TX_REGIONS     => MFB_REGIONS,
            TX_REGION_SIZE => MFB_REGION_SIZE,
            TX_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            TX_ITEM_WIDTH  => MFB_ITEM_WIDTH,

            DEVICE => DEVICE)
        port map (
            CLK => CLK,
            RST => RESET,

            RX_MFB_DATA    => cpl_proc_mfb_data,
            RX_MFB_SOF     => cpl_proc_mfb_sof,
            RX_MFB_EOF     => cpl_proc_mfb_eof,
            RX_MFB_SOF_POS => cpl_proc_mfb_sof_pos,
            RX_MFB_EOF_POS => cpl_proc_mfb_eof_pos,
            RX_MFB_SRC_RDY => cpl_proc_mfb_src_rdy,
            RX_MFB_DST_RDY => cpl_proc_mfb_dst_rdy,

            TX_MFB_DATA    => PCIE_CC_MFB_DATA,
            TX_MFB_META    => PCIE_CC_MFB_META,
            TX_MFB_SOF     => PCIE_CC_MFB_SOF,
            TX_MFB_EOF     => PCIE_CC_MFB_EOF,
            TX_MFB_SOF_POS => PCIE_CC_MFB_SOF_POS,
            TX_MFB_EOF_POS => PCIE_CC_MFB_EOF_POS,
            TX_MFB_SRC_RDY => PCIE_CC_MFB_SRC_RDY,
            TX_MFB_DST_RDY => PCIE_CC_MFB_DST_RDY,

            PCIE_HDR_DATA    => cc_hdr_data,
            PCIE_HDR_VLD     => '1',
            PCIE_HDR_SRC_RDY => cc_hdr_src_rdy,
            PCIE_HDR_DST_RDY => cc_hdr_dst_rdy);
end architecture;
