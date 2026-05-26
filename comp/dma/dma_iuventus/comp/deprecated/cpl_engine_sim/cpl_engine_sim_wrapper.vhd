-- cpl_engine_sim_wrapper.vhd: simulation wrapper that forms the component formerly instantiated as
-- a completion engine
-- Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
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
-- TODO: The transaction buffer needs to be reseted upon CQHDBL rollover

use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;
use work.nvme_meta_pack.all;

entity CPL_ENGINE_SIM_WRAPPER is
    generic (
        -- The width of the MI bus in bits
        MI_WIDTH        : positive := 32;
        -- MFB configuration shared between both PCIe interfaces
        MFB_REGIONS     : natural  := 2;
        MFB_REGION_SIZE : natural  := 1;
        MFB_BLOCK_SIZE  : natural  := 8;
        MFB_ITEM_WIDTH  : natural  := 32;
        -- FPGA device string
        DEVICE          : string   := "ULTRASCALE";
        -- Maximum Payload Size according to the PCIe specification is the maximum size of a
        -- transaction in bytes that can be transported over the PCIe bus (up to 4096 B)
        MPS             : positive := 2**12;
        -- Maximum Read Reaquest SIze according to the PCIe specification (up to 4096 B)
        MRRS            : positive := 2**12);

    port(
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- PCIE Completion Requester interface
        -- =========================================================================================
        PCIE_CQ_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CQ_MFB_META    : in  std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        PCIE_CQ_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        PCIE_CQ_MFB_EOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        PCIE_CQ_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        PCIE_CQ_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_CQ_MFB_SRC_RDY : in  std_logic;
        PCIE_CQ_MFB_DST_RDY : out std_logic;

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
        -- Status interface
        -- =========================================================================================
        STAT_UPD_SQHDBL    : out std_logic_vector(15 downto 0);
        STAT_UPD_CQHDBL    : out std_logic_vector(15 downto 0);
        STAT_UPD_LAST_CQ_ENTRY  : out std_logic_vector(CQ_ENTRY_RANGE);
        -- Asserted when new status information is available
        STAT_UPD_VLD : out std_logic;

        -- Counter update interfaces
        RD_RECEIVED_BYTES  : out std_logic_vector(log2(MPS+1) -1 downto 0);
        RD_RECEIVED_INCR   : out std_logic_vector(log2(MFB_REGIONS+1) -1 downto 0);
        WR_RECEIVED_BYTES  : out std_logic_vector(log2(MPS+1) -1 downto 0);
        WR_RECEIVED_INCR   : out std_logic_vector(log2(MFB_REGIONS+1) -1 downto 0);
        RD_PROCESSED_BYTES : out std_logic_vector(log2(MRRS+1) -1 downto 0);
        LAST_READ_ADDR     : out std_logic_vector(63 downto 0);
        RD_PROCESSED_INCR  : out std_logic;

        -- =========================================================================================
        -- Control interface
        -- =========================================================================================
        -- Mask of the DBL pointer
        DBL_MASK        : in std_logic_vector (15 downto 0)
        );
end entity;

architecture FULL of CPL_ENGINE_SIM_WRAPPER is
    constant MFB_LENGTH         : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    -- The maximum value that is allowed for a 2-channel PCIE_TRANS_BUFFER using only a single BRAM
    -- array
    constant CPLQ_POINTER_WIDTH : natural := 17;

    constant SQ_BAR_ID         : std_logic_vector(2 downto 0) := "000";
    constant CQ_BAR_ID         : std_logic_vector(2 downto 0) := "010";
    constant CP_BUFF_BAR_ID    : std_logic_vector(2 downto 0) := "100";
    constant CQ_SECT_INDEX     : std_logic_vector(0 downto 0) := "1";
    constant CQ_BUFF_SECT0_BAR : std_logic_vector(2 downto 0) := CP_BUFF_BAR_ID;
    constant SQ_BUFF_SECT0_BAR : std_logic_vector(2 downto 0) := SQ_BAR_ID;

    -- =============================================================================================
    -- Defining ranges for meta signal
    -- =============================================================================================
    constant META_PCIE_ADDR_W    : natural := 64;
    constant META_BYTE_CNT_W     : natural := 13;
    constant META_BAR_ID_W       : natural := 3;
    constant META_PCIE_HDR_RAW_W : natural := PCIE_META_REQ_HDR_W;
    constant META_BE_W           : natural := (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8;

    constant META_PCIE_ADDR_O    : natural := 0;
    constant META_BYTE_CNT_O     : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    constant META_BAR_ID_O       : natural := META_BYTE_CNT_O + META_BYTE_CNT_W;
    constant META_PCIE_HDR_RAW_O : natural := META_BYTE_CNT_O + META_BYTE_CNT_W;
    constant META_BE_O           : natural := META_BAR_ID_O + META_BAR_ID_W;

    subtype META_PCIE_ADDR is natural range META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O;
    subtype META_BYTE_CNT is natural range META_BYTE_CNT_O + META_BYTE_CNT_W -1 downto META_BYTE_CNT_O;
    subtype META_BAR_ID is natural range META_BAR_ID_O + META_BAR_ID_W -1 downto META_BAR_ID_O;
    subtype META_PCIE_HDR_RAW is natural range META_PCIE_HDR_RAW_O + META_PCIE_HDR_RAW_W -1 downto META_PCIE_HDR_RAW_O;
    subtype META_BE is natural range META_BE_O + META_BE_W -1 downto META_BE_O;

    constant MFB_META_WIDTH_INT : natural := META_BE_O + META_BE_W;
    -- =============================================================================================

    -- =============================================================================================
    -- Outputs from the CQ_META_EXTRACTOR
    -- =============================================================================================
    signal meta_ext_mfb_data        : std_logic_vector(PCIE_CQ_MFB_DATA'range);
    signal meta_ext_mfb_meta        : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_META_WIDTH_INT -1 downto 0);
    signal meta_ext_mfb_meta_parsed : slv_array_t(MFB_REGIONS -1 downto 0)(META_BE_W+1+META_PCIE_ADDR_W-2 -1 downto 0);
    signal meta_ext_mfb_sof         : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal meta_ext_mfb_eof         : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal meta_ext_mfb_sof_pos     : std_logic_vector(MFB_REGIONS*maximum(1, log2(MFB_REGION_SIZE)) -1 downto 0);
    signal meta_ext_mfb_eof_pos     : std_logic_vector(MFB_REGIONS*maximum(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
    signal meta_ext_mfb_src_rdy     : std_logic;
    signal meta_ext_mfb_dst_rdy     : std_logic;

    signal cp_buff_chan : std_logic_vector(MFB_REGIONS -1 downto 0);

    -- =============================================================================================
    -- Parsed CQ header
    -- =============================================================================================
    signal pcie_hdr_addr     : slv_array_t(MFB_REGIONS -1 downto 0)(META_PCIE_ADDR_W -1 downto 0);
    signal pcie_hdr_data_raw : slv_array_t(MFB_REGIONS -1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);
    signal pcie_hdr_bar_id   : slv_array_t(MFB_REGIONS -1 downto 0)(META_BAR_ID_W -1 downto 0);
    signal pcie_hdr_byte_cnt : slv_array_t(MFB_REGIONS -1 downto 0)(13 -1 downto 0);
    signal pcie_hdr_vld      : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal cq_pcie_hdr_vld   : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal pcie_hdr_src_rdy  : std_logic;
    signal pcie_hdr_dst_rdy  : std_logic;

    -- =============================================================================================
    -- Transaction Buffer interface
    -- =============================================================================================
    signal buff_chan_b     : std_logic_vector(0 downto 0);
    signal buff_data_b     : std_logic_vector(MFB_LENGTH -1 downto 0);
    signal buff_addr_b     : std_logic_vector(CPLQ_POINTER_WIDTH -1 downto 0);
    signal buff_en_b       : std_logic;
    signal buff_data_vld_b : std_logic;

    -- Increments for status counters
    signal pcie_incr_rd_req : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal pcie_incr_wr_req : std_logic_vector(MFB_REGIONS -1 downto 0);
begin
    pcie_incr_assign_g : for reg_idx in (MFB_REGIONS - 1) downto 0 generate
        pcie_incr_rd_req(reg_idx) <= pcie_hdr_vld(reg_idx) and pcie_hdr_src_rdy and pcie_hdr_dst_rdy;
        pcie_incr_wr_req(reg_idx) <= meta_ext_mfb_sof(reg_idx) and meta_ext_mfb_src_rdy and meta_ext_mfb_dst_rdy;
    end generate;

    stat_cntr_incr_logic_p : process (all) is
        variable running_rd_bytes : unsigned(RD_RECEIVED_BYTES'range);
        variable running_rd_incr  : unsigned(RD_RECEIVED_INCR'range);
        variable running_wr_bytes : unsigned(WR_RECEIVED_BYTES'range);
        variable running_wr_incr  : unsigned(WR_RECEIVED_INCR'range);
    begin
        running_rd_incr  := (others => '0');
        running_rd_bytes := (others => '0');
        running_wr_incr  := (others => '0');
        running_wr_bytes := (others => '0');

        if (pcie_incr_rd_req(0) = '1') then
            running_rd_incr  := running_rd_incr + 1;
            running_rd_bytes := running_rd_bytes + unsigned(pcie_hdr_byte_cnt(0));
        end if;

        if (pcie_incr_rd_req(1) = '1') then
            running_rd_incr  := running_rd_incr + 1;
            running_rd_bytes := running_rd_bytes + unsigned(pcie_hdr_byte_cnt(1));
        end if;

        if (pcie_incr_wr_req(0) = '1') then
            running_wr_incr  := running_wr_incr + 1;
            running_wr_bytes := running_wr_bytes + unsigned(meta_ext_mfb_meta(0)(META_BYTE_CNT));
        end if;

        if (pcie_incr_wr_req(1) = '1') then
            running_wr_incr  := running_wr_incr + 1;
            running_wr_bytes := running_wr_bytes + unsigned(meta_ext_mfb_meta(1)(META_BYTE_CNT));
        end if;

        RD_RECEIVED_BYTES <= std_logic_vector(running_rd_bytes);
        RD_RECEIVED_INCR  <= std_logic_vector(running_rd_incr);
        WR_RECEIVED_BYTES <= std_logic_vector(running_wr_bytes);
        WR_RECEIVED_INCR  <= std_logic_vector(running_wr_incr);
    end process;

    nvme_cq_meta_ext_i : entity work.NVME_CQ_META_EXTRACTOR
        generic map (
            DEVICE          => DEVICE,
            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
            POINTER_WIDTH   => CPLQ_POINTER_WIDTH,
            SQ_BAR_ID       => SQ_BAR_ID)
        port map (
            CLK   => CLK,
            RESET => RESET,

            PCIE_MFB_DATA    => PCIE_CQ_MFB_DATA,
            PCIE_MFB_META    => PCIE_CQ_MFB_META,
            PCIE_MFB_SOF     => PCIE_CQ_MFB_SOF,
            PCIE_MFB_EOF     => PCIE_CQ_MFB_EOF,
            PCIE_MFB_SOF_POS => PCIE_CQ_MFB_SOF_POS,
            PCIE_MFB_EOF_POS => PCIE_CQ_MFB_EOF_POS,
            PCIE_MFB_SRC_RDY => PCIE_CQ_MFB_SRC_RDY,
            PCIE_MFB_DST_RDY => PCIE_CQ_MFB_DST_RDY,

            MVB_DATA_BAR_ID   => pcie_hdr_bar_id,
            MVB_DATA_ADDR     => pcie_hdr_addr,
            MVB_DATA_CQ_HDR   => pcie_hdr_data_raw,
            MVB_DATA_BYTE_CNT => pcie_hdr_byte_cnt,
            MVB_VLD           => pcie_hdr_vld,
            MVB_SRC_RDY       => pcie_hdr_src_rdy,
            MVB_DST_RDY       => pcie_hdr_dst_rdy,

            USR_MFB_DATA    => meta_ext_mfb_data,
            USR_MFB_META    => meta_ext_mfb_meta,
            USR_MFB_SOF     => meta_ext_mfb_sof,
            USR_MFB_EOF     => meta_ext_mfb_eof,
            USR_MFB_SOF_POS => meta_ext_mfb_sof_pos,
            USR_MFB_EOF_POS => meta_ext_mfb_eof_pos,
            USR_MFB_SRC_RDY => meta_ext_mfb_src_rdy,
            USR_MFB_DST_RDY => meta_ext_mfb_dst_rdy);

    meta_ext_mfb_meta_g : for rgn_idx in (MFB_REGIONS -1) downto 0 generate
        cp_buff_chan(rgn_idx) <= (not CQ_SECT_INDEX(0)) when meta_ext_mfb_meta(rgn_idx)(META_BAR_ID) = CP_BUFF_BAR_ID else CQ_SECT_INDEX(0);

        meta_ext_mfb_meta_parsed(rgn_idx) <=
            meta_ext_mfb_meta(rgn_idx)(META_BE) &
            cp_buff_chan(rgn_idx) &
            meta_ext_mfb_meta(rgn_idx)(META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O + 2);

        cq_pcie_hdr_vld(rgn_idx) <= pcie_hdr_vld(rgn_idx) when (pcie_hdr_bar_id(rgn_idx) = CP_BUFF_BAR_ID or pcie_hdr_bar_id(rgn_idx) = CQ_BAR_ID) else '0';
    end generate;

    cp_buff_and_cpl_queue_i : entity work.NVME_BUFFER_UNIT
        generic map (
            CHANNELS               => 2,
            BUFF_POINTER_WIDTH     => CPLQ_POINTER_WIDTH,
            BUFF_B_PORT_EN         => TRUE,
            BUFF_B_BARREL_SHIFT_EN => FALSE,

            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,

            DEVICE => DEVICE,
            MRRS   => MRRS,

            BUFF_SECT0_BAR => CQ_BUFF_SECT0_BAR)
        port map (
            CLK   => CLK,
            RESET => RESET,

            PCIE_HDR_ADDR     => pcie_hdr_addr,
            PCIE_HDR_DATA_RAW => pcie_hdr_data_raw,
            PCIE_HDR_BYTE_CNT => pcie_hdr_byte_cnt,
            PCIE_HDR_VLD      => cq_pcie_hdr_vld,
            PCIE_HDR_SRC_RDY  => pcie_hdr_src_rdy,
            PCIE_HDR_DST_RDY  => pcie_hdr_dst_rdy,

            RX_MFB_DATA    => meta_ext_mfb_data,
            RX_MFB_META    => meta_ext_mfb_meta_parsed,
            RX_MFB_SOF     => meta_ext_mfb_sof,
            RX_MFB_SRC_RDY => meta_ext_mfb_src_rdy,
            RX_MFB_DST_RDY => meta_ext_mfb_dst_rdy,

            PCIE_CC_MFB_DATA    => PCIE_CC_MFB_DATA,
            PCIE_CC_MFB_META    => PCIE_CC_MFB_META,
            PCIE_CC_MFB_SOF     => PCIE_CC_MFB_SOF,
            PCIE_CC_MFB_EOF     => PCIE_CC_MFB_EOF,
            PCIE_CC_MFB_SOF_POS => PCIE_CC_MFB_SOF_POS,
            PCIE_CC_MFB_EOF_POS => PCIE_CC_MFB_EOF_POS,
            PCIE_CC_MFB_SRC_RDY => PCIE_CC_MFB_SRC_RDY,
            PCIE_CC_MFB_DST_RDY => PCIE_CC_MFB_DST_RDY,

            BUFF_CHAN_B     => buff_chan_b,
            BUFF_DATA_B     => buff_data_b,
            BUFF_ADDR_B     => buff_addr_b,
            BUFF_EN_B       => buff_en_b,
            BUFF_DATA_VLD_B => buff_data_vld_b,

            RD_PROCESSED_BYTES => RD_PROCESSED_BYTES,
            LAST_READ_ADDR     => LAST_READ_ADDR,
            STAT_UPD_EN        => RD_PROCESSED_INCR
            );

    cqe_processor_i : entity work.CQE_PROCESSOR
        generic map (
            DEVICE => DEVICE,

            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,

            BUFF_POINTER_WIDTH => CPLQ_POINTER_WIDTH,
            CQ_SECT_INDEX      => CQ_SECT_INDEX)
        port map (
            CLK   => CLK,
            RESET => RESET,

            -- The CQE processor has been connected to the B port of the transaction buffer since
            -- this port is assumed to have less load on the write side and therefore be able to
            -- perform more reads (the writes block the read ports since they have higher priority).
            DATA_BUFF_RD_CHAN     => buff_chan_b,
            DATA_BUFF_RD_DATA     => buff_data_b,
            DATA_BUFF_RD_ADDR     => buff_addr_b,
            DATA_BUFF_RD_EN       => buff_en_b,
            DATA_BUFF_RD_DATA_VLD => buff_data_vld_b,

            DBL_MASK        => DBL_MASK,
            CQHDBL_UPD_DATA => STAT_UPD_CQHDBL,
            SQHDBL_UPD_DATA => STAT_UPD_SQHDBL,
            LAST_CQ_ENTRY   => STAT_UPD_LAST_CQ_ENTRY,
            STATUS_UPD_EN   => STAT_UPD_VLD);
end architecture;
