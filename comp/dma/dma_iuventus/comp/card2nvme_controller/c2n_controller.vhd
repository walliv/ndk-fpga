-- c2n_controller.vhd: Controller for Card to NVMe communication (data for write commands and SQ
-- Entries)
-- Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;
use work.nvme_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity C2N_CONTROLLER is
    generic (
        PCIE_MFB_REGIONS     : natural  := 2;
        PCIE_MFB_REGION_SIZE : natural  := 1;
        PCIE_MFB_BLOCK_SIZE  : natural  := 8;
        PCIE_MFB_ITEM_WIDTH  : natural  := 32;

        USR_MFB_REGIONS     : natural  := 1;
        USR_MFB_REGION_SIZE : natural  := 1;
        USR_MFB_BLOCK_SIZE  : natural  := 64;
        USR_MFB_ITEM_WIDTH  : natural  := 8;

        -- The allowed is only "ULTRASCALE"
        DEVICE : string := "ULTRASCALE";
        -- The size of a pointer to a buffer of one channel in the transaction buffer
        BUFF_PTR_WIDTH : positive := 17;
        -- Amount of tags/Command Identifiers available for outstanding NVMe commands
        QUEUE_DEPTH    : positive := 2048;
        -- Number of independent SQ/CQ queues (one per SSD); see NVME_CMD_DISPATCHER. Default 1
        -- is bit-identical to the original single-queue design.
        NUM_QUEUES     : positive := 1
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;
        CMD_DISP_RST : in std_logic;

        -- =========================================================================================
        -- Header from the Metadata Extractor
        -- =========================================================================================
        PCIE_HDR_ADDR     : in  slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(63 downto 0);
        PCIE_HDR_BYTE_CNT : in  slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(13 -1 downto 0);
        PCIE_HDR_DATA_RAW : in  slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);
        PCIE_HDR_VLD      : in  std_logic_vector(PCIE_MFB_REGIONS -1 downto 0);
        PCIE_HDR_SRC_RDY  : in  std_logic;
        PCIE_HDR_DST_RDY  : out std_logic;

        -- =========================================================================================
        -- Write interface with data for NVMe Write commands
        -- =========================================================================================
        WR_REQ_MFB_DATA    : in  std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        -- One bit wider than BUFF_PTR_WIDTH: carries the RDBUFF page's *flat* byte address (the
        -- buffer is flat-addressed, MEM_PARTITIONING => FALSE; RDBUFF pages are 1..BUFF_PAGES-1
        -- of the flat space), which needs one more bit than a single channel's BUFF_PTR_WIDTH.
        WR_REQ_MFB_META    : in  std_logic_vector(USR_MFB_REGIONS*(BUFF_PTR_WIDTH+1) -1 downto 0);
        WR_REQ_MFB_SOF     : in  std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        WR_REQ_MFB_EOF     : in  std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        WR_REQ_MFB_SOF_POS : in  std_logic_vector(USR_MFB_REGIONS*maximum(1, log2(USR_MFB_REGION_SIZE))-1 downto 0);
        WR_REQ_MFB_EOF_POS : in  std_logic_vector(USR_MFB_REGIONS*log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)-1 downto 0);
        WR_REQ_MFB_SRC_RDY : in  std_logic;
        WR_REQ_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- Command Dispatcher interface
        -- =========================================================================================
        -- Dispatch command to the Submission Queue
        TRIGG_DISP : in std_logic;
        -- Backpressure signal that indicates that component is prepared to dispatch signals
        RDY_FOR_DISP : out std_logic;

        -- Parts of the Submission Queue Entry (i.e. the command). DBL_MASK/NAMESPACE_ID/
        -- LBA_SPACE_SIZE/LBA_NUM_MASK are per-queue (one element per queue -- see
        -- NVME_SW_MANAGER's PER_Q_BASE register block); passed through unchanged to
        -- NVME_CMD_DISPATCHER, which indexes them by the queue currently being dispatched to.
        DBL_MASK        : in slv_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);
        CMD_OPCODE      : in std_logic_vector(CMD_OPCODE_W -1 downto 0);
        NAMESPACE_ID    : in slv_array_t(NUM_QUEUES -1 downto 0)(31 downto 0);
        METADATA_PTR    : in std_logic_vector(63 downto 0);
        PRP_ENTRY_1     : in std_logic_vector(63 downto 0);
        PRP_ENTRY_2     : in std_logic_vector(63 downto 0);
        START_LBA_PTR   : in std_logic_vector(63 downto 0);
        LBA_SPACE_SIZE  : in slv_array_t(NUM_QUEUES -1 downto 0)(63 downto 0);
        LBA_NUM         : in std_logic_vector(15 downto 0);
        LBA_NUM_MASK    : in slv_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);
        -- Queue Identifier of the command currently being dispatched -- see NVME_CMD_DISPATCHER.
        -- Always "0" at NUM_QUEUES=1.
        QID             : in std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);

        -- =========================================================================================
        -- Status return interface for Command dispatcher
        -- =========================================================================================
        CPL_STAT_TAG    : in std_logic_vector(15 downto 0);
        CPL_STAT_SQHDBL : in std_logic_vector(15 downto 0);
        CPL_STAT_VLD    : in std_logic;
        -- Queue Identifier the CPL_STAT_* completion belongs to. Always "0" at NUM_QUEUES=1.
        CPL_STAT_QID    : in std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);

        -- =========================================================================================
        -- Status interface
        -- =========================================================================================
        RDBUFF_DISP_RDS_CHAN      : out std_logic;
        RDBUFF_DISP_RDS_BYTES     : out std_logic_vector(13-1 downto 0);
        RDBUFF_DISP_RDS_INCR      : out std_logic;

        SQE_DISP_CNTR_TYPE : out std_logic_vector(CMD_OPCODE_W -1 downto 0);
        SQE_DISP_CNTR_SIZE : out std_logic_vector(24 downto 0);
        SQE_DISP_CNTR_INCR : out std_logic;

        TAG_FIFO_STATUS    : out std_logic_vector(11 downto 0);
        TAG_INIT_DONE      : out std_logic;
        SQTDBL_VAL         : out std_logic_vector(15 downto 0);
        -- Queue Identifier that SQTDBL_VAL/SQE_DISP_CNTR_INCR apply to (mirrors QID). Always "0"
        -- at NUM_QUEUES=1.
        SQTDBL_QID         : out std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);

        -- Command Identifier assigned to the command being dispatched, valid when DISP_CMD_ID_VLD
        -- is asserted
        DISP_CMD_ID        : out std_logic_vector(15 downto 0);
        DISP_CMD_ID_VLD    : out std_logic;

        -- =========================================================================================
        -- PCIE Interface to send responds for PCIe read commands to Submission Queue and Write
        -- Buffer
        -- =========================================================================================
        PCIE_CC_MFB_DATA    : out std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CC_MFB_META    : out std_logic_vector(PCIE_MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
        PCIE_CC_MFB_SOF     : out std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_CC_MFB_EOF     : out std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_CC_MFB_SOF_POS : out std_logic_vector(PCIE_MFB_REGIONS*max(1, log2(PCIE_MFB_REGION_SIZE))-1 downto 0);
        PCIE_CC_MFB_EOF_POS : out std_logic_vector(PCIE_MFB_REGIONS*log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_CC_MFB_SRC_RDY : out std_logic;
        PCIE_CC_MFB_DST_RDY : in  std_logic);
end entity;

architecture FULL of C2N_CONTROLLER is
    -- Width of the RDBUFF/SQ "buffer pointer" field carried through the internal aux/cmdisp/merged
    -- metadata (one bit wider than BUFF_PTR_WIDTH -- see WR_REQ_MFB_META).
    constant META_PTR_WIDTH : natural := BUFF_PTR_WIDTH + 1;

    package iuventus_mfb_meta_pkg_i is new work.iuventus_mfb_meta_pkg
    generic map (
        MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,
        CHANNELS        => 2,
        BUFF_PTR_WIDTH  => BUFF_PTR_WIDTH);

    use iuventus_mfb_meta_pkg_i.all;

    -- nvc 1.21.0 workaround: implicit concurrent signal assignments that read slices with
    -- package-constant bounds crash because nvc can't compute slice-level sensitivity for
    -- generics from non-literal generic package instantiations. Use functions so that the
    -- whole input signal is passed as a parameter, enabling whole-signal sensitivity instead.
    function build_mrg_mfb_meta(
        i_meta     : std_logic_vector;
        be_hi      : natural;
        be_lo      : natural;
        chan_bit    : natural;
        ptr_hi     : natural;
        ptr_lo     : natural
    ) return std_logic_vector is
        constant BE_W   : natural := be_hi - be_lo + 1;
        constant ELEM_W : natural := BE_W + 1 + 62;  -- 62 = META_PCIE_ADDR_W - 2
        variable result : std_logic_vector(ELEM_W downto 0);
    begin
        result(ELEM_W downto ELEM_W-BE_W+1)    := i_meta(be_hi downto be_lo);
        result(ELEM_W-BE_W)                    := i_meta(chan_bit);
        result(ELEM_W-BE_W-1 downto 1)         := std_logic_vector(resize(unsigned(i_meta(ptr_hi downto ptr_lo)), 62));
        result(0)                              := '0';
        return result;
    end function;

    -- nvc 1.21.0 workaround: variable-bounded signal slice drives from process loop bodies
    -- crash in sub-component context. Use functions to compute the full result internally
    -- (local variable assignments at upref 0), then drive the whole signal at once.
    function build_aux_mfb_meta(
        i_aux_mfb_meta : std_logic_vector;
        i_mfb_item_vld : std_logic_vector;
        n_regions      : natural;
        buff_ptr_w     : natural;
        meta_be_w      : natural
    ) return std_logic_vector is
        constant ELEM_W : natural := meta_be_w + 1 + buff_ptr_w;
        variable result : std_logic_vector(n_regions*ELEM_W - 1 downto 0);
    begin
        for i in 0 to n_regions-1 loop
            result((i+1)*ELEM_W-1 downto i*ELEM_W) :=
                i_mfb_item_vld &
                -- The buffer is flat-addressed (MEM_PARTITIONING => FALSE): the write META
                -- channel bit is a don't-care, the address alone (RDBUFF at flat pages 1+)
                -- locates the datum.
                '0' &
                i_aux_mfb_meta((i+1)*buff_ptr_w - 1 downto i*buff_ptr_w);
        end loop;
        return result;
    end function;

    function build_hdr_fifo_din(
        pcie_hdr_addr     : slv_array_t;
        pcie_hdr_data_raw : slv_array_t;
        pcie_hdr_byte_cnt : slv_array_t;
        n_regions         : natural;
        hdr_fifo_data_w   : natural
    ) return std_logic_vector is
        variable result : std_logic_vector(n_regions*hdr_fifo_data_w - 1 downto 0);
    begin
        for i in 0 to n_regions-1 loop
            result((i+1)*hdr_fifo_data_w - 1 downto i*hdr_fifo_data_w) :=
                pcie_hdr_byte_cnt(i) & pcie_hdr_data_raw(i) & pcie_hdr_addr(i);
        end loop;
        return result;
    end function;

    signal aux_mfb_data     : std_logic_vector(WR_REQ_MFB_DATA'range);
    signal aux_mfb_meta     : std_logic_vector(WR_REQ_MFB_META'range);
    -- nvc workaround: flat std_logic_vector avoids slv_array_t element access bug in nvc 1.21.0
    signal aux_mfb_meta_parsed : std_logic_vector(USR_MFB_REGIONS*(META_BE_W + 1 + META_PTR_WIDTH) -1 downto 0);
    signal aux_mfb_sof     : std_logic_vector(WR_REQ_MFB_SOF'range);
    signal aux_mfb_eof     : std_logic_vector(WR_REQ_MFB_EOF'range);
    signal aux_mfb_sof_pos : std_logic_vector(WR_REQ_MFB_SOF_POS'range);
    signal aux_mfb_eof_pos : std_logic_vector(WR_REQ_MFB_EOF_POS'range);
    signal aux_mfb_src_rdy : std_logic;
    signal aux_mfb_dst_rdy : std_logic;
    signal mfb_item_vld    : std_logic_vector(USR_MFB_REGIONS*META_BE_W -1 downto 0);

    signal cmdisp_mfb_data     : std_logic_vector(WR_REQ_MFB_DATA'range);
    signal cmdisp_mfb_meta     : std_logic_vector(USR_MFB_REGIONS*(META_BE_W + 1 + META_PTR_WIDTH)-1 downto 0);
    signal cmdisp_mfb_sof      : std_logic_vector(WR_REQ_MFB_SOF'range);
    signal cmdisp_mfb_eof      : std_logic_vector(WR_REQ_MFB_EOF'range);
    signal cmdisp_mfb_sof_pos  : std_logic_vector(WR_REQ_MFB_SOF_POS'range);
    signal cmdisp_mfb_eof_pos  : std_logic_vector(WR_REQ_MFB_EOF_POS'range);
    signal cmdisp_mfb_src_rdy  : std_logic;
    signal cmdisp_mfb_dst_rdy  : std_logic;

    signal mrg_mfb_data     : std_logic_vector(WR_REQ_MFB_DATA'range);
    -- nvc workaround: use entity-generic expressions instead of package constants in signal
    -- widths to avoid corrupt descriptors when the generic package uses non-literal generics
    signal mrg_mfb_meta        : std_logic_vector((USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH)/8 + 1 + META_PTR_WIDTH - 1 downto 0);
    signal mrg_mfb_meta_parsed : std_logic_vector((USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH)/8 + 63 downto 0);
    signal mrg_mfb_sof      : std_logic_vector(WR_REQ_MFB_SOF'range);
    signal mrg_mfb_src_rdy  : std_logic;
    signal mrg_mfb_dst_rdy  : std_logic;

    signal buff_chan      : std_logic;
    -- One bit wider than BUFF_PTR_WIDTH: the buffer is flat-addressed (MEM_PARTITIONING =>
    -- FALSE), so this address alone must reach the whole flat space (SQ at page 0, RDBUFF at
    -- pages 1+).
    signal buff_addr      : std_logic_vector(BUFF_PTR_WIDTH downto 0);
    signal buff_en        : std_logic;
    signal buff_data      : std_logic_vector(PCIE_CC_MFB_DATA'range);
    signal buff_data_vld  : std_logic;

    -- nvc workaround: flat std_logic_vector avoids slv_array_t element access bug in nvc 1.21.0
    signal hdr_fifo_din      : std_logic_vector(PCIE_MFB_REGIONS*HDR_FIFO_DATA_W -1 downto 0);
    signal hdr_fifo_wr       : std_logic_vector(PCIE_MFB_REGIONS -1 downto 0);
    signal hdr_fifo_full     : std_logic;
    signal hdr_fifo_dout     : std_logic_vector(HDR_FIFO_DATA_W -1 downto 0);
    signal hdr_fifo_rd       : std_logic;
    signal hdr_fifo_empty    : std_logic;

    signal cpl_proc_mfb_data     : std_logic_vector(WR_REQ_MFB_DATA'range);
    signal cpl_proc_mfb_sof      : std_logic_vector(WR_REQ_MFB_SOF'range);
    signal cpl_proc_mfb_eof      : std_logic_vector(WR_REQ_MFB_EOF'range);
    signal cpl_proc_mfb_sof_pos  : std_logic_vector(WR_REQ_MFB_SOF_POS'range);
    signal cpl_proc_mfb_eof_pos  : std_logic_vector(WR_REQ_MFB_EOF_POS'range);
    signal cpl_proc_mfb_src_rdy  : std_logic;
    signal cpl_proc_mfb_dst_rdy  : std_logic;

    signal cc_hdr_data : std_logic_vector(PCIE_META_CPL_HDR_W -1 downto 0);
    signal cc_hdr_src_rdy : std_logic;
    signal cc_hdr_dst_rdy : std_logic;
begin

    assert (USR_MFB_REGIONS = 1 and USR_MFB_REGION_SIZE = 1 and USR_MFB_BLOCK_SIZE = 64 and USR_MFB_ITEM_WIDTH = 8)
        report "C2N_CONTROLLER: Currently only configuration with USR_MFB_REGIONS = 1, " &
            "USR_MFB_REGION_SIZE = 1, USR_MFB_BLOCK_SIZE = 64 and USR_MFB_ITEM_WIDTH = 8 is supported."
        severity failure;

    assert (PCIE_MFB_REGIONS = 2 and PCIE_MFB_REGION_SIZE = 1 and PCIE_MFB_BLOCK_SIZE = 8 and PCIE_MFB_ITEM_WIDTH = 32)
        report "C2N_CONTROLLER: Currently only configuration with PCIE_MFB_REGIONS = 2, " &
            "PCIE_MFB_REGION_SIZE = 1, PCIE_MFB_BLOCK_SIZE = 8 and PCIE_MFB_ITEM_WIDTH = 32 is supported."
        severity failure;

    byte_en_gen_i : entity work.MFB_AUXILIARY_SIGNALS
        generic map (
            REGIONS       => USR_MFB_REGIONS,
            REGION_SIZE   => USR_MFB_REGION_SIZE,
            BLOCK_SIZE    => USR_MFB_BLOCK_SIZE,
            ITEM_WIDTH    => USR_MFB_ITEM_WIDTH,
            META_WIDTH    => META_PTR_WIDTH,
            REGION_AUX_EN => false,
            BLOCK_AUX_EN  => false,
            ITEM_AUX_EN   => true)
        port map (
            CLK              => CLK,
            RESET            => RST,

            RX_DATA          => WR_REQ_MFB_DATA,
            RX_META          => WR_REQ_MFB_META,
            RX_SOF_POS       => WR_REQ_MFB_SOF_POS,
            RX_EOF_POS       => WR_REQ_MFB_EOF_POS,
            RX_SOF           => WR_REQ_MFB_SOF,
            RX_EOF           => WR_REQ_MFB_EOF,
            RX_SRC_RDY       => WR_REQ_MFB_SRC_RDY,
            RX_DST_RDY       => WR_REQ_MFB_DST_RDY,

            TX_DATA          => aux_mfb_data,
            TX_META          => aux_mfb_meta,
            TX_SOF_POS       => aux_mfb_sof_pos,
            TX_EOF_POS       => aux_mfb_eof_pos,
            TX_SOF           => aux_mfb_sof,
            TX_EOF           => aux_mfb_eof,
            TX_SRC_RDY       => aux_mfb_src_rdy,
            TX_DST_RDY       => aux_mfb_dst_rdy,

            TX_REGION_SHARED => open,
            TX_REGION_VLD    => open,
            TX_BLOCK_VLD     => open,
            TX_ITEM_VLD      => mfb_item_vld);

    -- Parsing of the metadata: each region element gets byte_enable bits, channel flag, and buffer pointer
    aux_mfb_meta_parsed <= build_aux_mfb_meta(
        aux_mfb_meta, mfb_item_vld,
        USR_MFB_REGIONS, META_PTR_WIDTH, META_BE_W);

    nvme_cmd_dispatcher_i : entity work.NVME_CMD_DISPATCHER
        generic map (
            CHANNELS        => 2,
            MFB_REGIONS     => USR_MFB_REGIONS,
            MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,
            DEVICE          => DEVICE,
            -- Matches the merged-meta pointer field width (META_PTR_WIDTH), not the buffer's own
            -- BUFF_PTR_WIDTH -- see WR_REQ_MFB_META.
            BUFF_PTR_WIDTH  => META_PTR_WIDTH,
            QUEUE_DEPTH     => QUEUE_DEPTH,
            NUM_QUEUES      => NUM_QUEUES)
        port map (
            CLK                => CLK,
            RST                => RST,
            RST_PTR            => CMD_DISP_RST,

            TRIGG_DISP   => TRIGG_DISP,
            RDY_FOR_DISP => RDY_FOR_DISP,
            DBL_MASK           => DBL_MASK,

            CMD_OPCODE         => CMD_OPCODE,
            NAMESPACE_ID       => NAMESPACE_ID,
            METADATA_PTR       => METADATA_PTR,
            PRP_ENTRY_1        => PRP_ENTRY_1,
            PRP_ENTRY_2        => PRP_ENTRY_2,
            START_LBA_PTR      => START_LBA_PTR,
            LBA_SPACE_SIZE     => LBA_SPACE_SIZE,
            LBA_NUM            => LBA_NUM,
            LBA_NUM_MASK       => LBA_NUM_MASK,
            QID                => QID,

            SQTDBL_VAL         => SQTDBL_VAL,
            SQTDBL_QID         => SQTDBL_QID,
            TAG_FIFO_STATUS    => TAG_FIFO_STATUS,
            TAG_INIT_DONE      => TAG_INIT_DONE,

            DISP_CMD_ID        => DISP_CMD_ID,
            DISP_CMD_ID_VLD    => DISP_CMD_ID_VLD,

            SQE_DISP_CNTR_TYPE => SQE_DISP_CNTR_TYPE,
            SQE_DISP_CNTR_SIZE => SQE_DISP_CNTR_SIZE,
            SQE_DISP_CNTR_INCR => SQE_DISP_CNTR_INCR,

            CPL_STAT_TAG       => CPL_STAT_TAG,
            CPL_STAT_SQHDBL    => CPL_STAT_SQHDBL,
            CPL_STAT_VLD       => CPL_STAT_VLD,
            CPL_STAT_QID       => CPL_STAT_QID,

            SQ_CMD_MFB_DATA    => cmdisp_mfb_data,
            SQ_CMD_MFB_META    => cmdisp_mfb_meta,
            SQ_CMD_MFB_SOF     => cmdisp_mfb_sof,
            SQ_CMD_MFB_EOF     => cmdisp_mfb_eof,
            SQ_CMD_MFB_SOF_POS => cmdisp_mfb_sof_pos,
            SQ_CMD_MFB_EOF_POS => cmdisp_mfb_eof_pos,
            SQ_CMD_MFB_SRC_RDY => cmdisp_mfb_src_rdy,
            SQ_CMD_MFB_DST_RDY => cmdisp_mfb_dst_rdy);

    mfb_merger_i : entity work.MFB_MERGER_SIMPLE
        generic map (
            REGIONS     => USR_MFB_REGIONS,
            REGION_SIZE => USR_MFB_REGION_SIZE,
            BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
            ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,
            META_WIDTH  => META_BE_W + 1 + META_PTR_WIDTH,
            MASKING_EN  => false,
            CNT_MAX     => 2)
        port map (
            CLK             => CLK,
            RST             => RST,

            RX_MFB0_DATA    => aux_mfb_data,
            RX_MFB0_META    => aux_mfb_meta_parsed,
            RX_MFB0_SOF     => aux_mfb_sof,
            RX_MFB0_SOF_POS => aux_mfb_sof_pos,
            RX_MFB0_EOF     => aux_mfb_eof,
            RX_MFB0_EOF_POS => aux_mfb_eof_pos,
            RX_MFB0_SRC_RDY => aux_mfb_src_rdy,
            RX_MFB0_DST_RDY => aux_mfb_dst_rdy,

            RX_MFB1_DATA    => cmdisp_mfb_data,
            RX_MFB1_META    => cmdisp_mfb_meta,
            RX_MFB1_SOF     => cmdisp_mfb_sof,
            RX_MFB1_SOF_POS => cmdisp_mfb_sof_pos,
            RX_MFB1_EOF     => cmdisp_mfb_eof,
            RX_MFB1_EOF_POS => cmdisp_mfb_eof_pos,
            RX_MFB1_SRC_RDY => cmdisp_mfb_src_rdy,
            RX_MFB1_DST_RDY => cmdisp_mfb_dst_rdy,

            TX_MFB_DATA     => mrg_mfb_data,
            TX_MFB_META     => mrg_mfb_meta,
            TX_MFB_SOF      => mrg_mfb_sof,
            TX_MFB_SOF_POS  => open,
            TX_MFB_EOF      => open,
            TX_MFB_EOF_POS  => open,
            TX_MFB_SRC_RDY  => mrg_mfb_src_rdy,
            TX_MFB_DST_RDY  => mrg_mfb_dst_rdy);

    -- WARNING: Assumes that USR_MFB_REGIONS = 1
    -- nvc workaround: pass whole signal and entity-generic-only positions to avoid
    -- package-constant slice sensitivity computation that crashes nvc 1.21.0
    mrg_mfb_meta_parsed <= build_mrg_mfb_meta(
        mrg_mfb_meta,
        -- be_hi = META_PTR_WIDTH + 1 (chan) + META_BE_W - 1, offset by the merged-meta layout
        META_PTR_WIDTH + (USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH)/8,
        -- be_lo = META_PTR_WIDTH + 1
        META_PTR_WIDTH + 1,
        -- chan_bit = META_PTR_WIDTH
        META_PTR_WIDTH,
        -- ptr_hi = META_PTR_WIDTH - 1 (top bit of the META_PTR_WIDTH-bit pointer field)
        META_PTR_WIDTH - 1,
        -- ptr_lo = 2 (the pointer's own low 2 bits are always 0 -- 4096-byte page granularity)
        2
    );
    mrg_mfb_dst_rdy <= '1';

    sq_rd_buffer_i : entity work.TX_DMA_PCIE_TRANS_BUFFER
        generic map (
            DEVICE          => DEVICE,
            CHANNELS        => 2,

            MFB_REGIONS     => 1,
            MFB_REGION_SIZE => 1,
            MFB_BLOCK_SIZE  => 16,
            MFB_ITEM_WIDTH  => 32,

            POINTER_WIDTH   => BUFF_PTR_WIDTH,
            -- Flat addressing: the SQ lives at page 0, RDBUFF at pages 1+, of one flat space.
            MEM_PARTITIONING => FALSE,

            SPLIT_READ_PORTS       => FALSE,
            READ_BARREL_SHIFTER_EN => (FALSE, TRUE))
        port map (
            CLK   => CLK,
            RESET => RST,

            PCIE_MFB_DATA    => mrg_mfb_data,
            PCIE_MFB_META(0) => mrg_mfb_meta_parsed,
            PCIE_MFB_SOF     => mrg_mfb_sof,
            PCIE_MFB_SRC_RDY => mrg_mfb_src_rdy,

            RD_CHAN_A(0)  => buff_chan,
            RD_ADDR_A     => buff_addr,
            RD_EN_A       => buff_en,
            RD_DATA_A     => buff_data,
            RD_DATA_VLD_A => buff_data_vld,

            RD_CHAN_B     => (others => '0'),
            RD_ADDR_B     => (others => '0'),
            RD_EN_B       => '0',
            RD_DATA_B     => open,
            RD_DATA_VLD_B => open);

    hdr_fifo_din <= build_hdr_fifo_din(
        PCIE_HDR_ADDR, PCIE_HDR_DATA_RAW, PCIE_HDR_BYTE_CNT,
        PCIE_MFB_REGIONS, HDR_FIFO_DATA_W);

    hdr_fifo_wr_g : for reg_idx in (PCIE_MFB_REGIONS - 1) downto 0 generate
        hdr_fifo_wr(reg_idx) <= PCIE_HDR_SRC_RDY and PCIE_HDR_VLD(reg_idx);
    end generate;

    PCIE_HDR_DST_RDY <= not hdr_fifo_full;

    -- TODO: Check within some error register that the FIFO does not overflow
    cq_hdr_fifox_multi_i : entity work.FIFOX_MULTI(FULL)
        generic map (
            DATA_WIDTH          => HDR_FIFO_DATA_W,
            ITEMS               => 2**8,
            WRITE_PORTS         => PCIE_MFB_REGIONS,
            READ_PORTS          => 1,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 2,
            ALMOST_EMPTY_OFFSET => 2,
            ALLOW_SINGLE_FIFO   => TRUE,
            SAFE_READ_MODE      => FALSE)
        port map (
            CLK   => CLK,
            RESET => RST,

            DI    => hdr_fifo_din,
            WR    => hdr_fifo_wr,
            FULL  => hdr_fifo_full,
            AFULL => open,

            DO       => hdr_fifo_dout,
            RD(0)    => hdr_fifo_rd,
            EMPTY(0) => hdr_fifo_empty,
            AEMPTY   => open);

    pcie_read_responder_i : entity work.PCIE_READ_RESPONDER
        generic map (
            DEVICE       => DEVICE,
            PKT_SIZE_MAX => 2**12,

            MFB_REGIONS     => USR_MFB_REGIONS,
            MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

            BUFF_POINTER_WIDTH => BUFF_PTR_WIDTH)
        port map (
            CLK   => CLK,
            RESET => RST,

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
            CQ_HDR_DATA     => hdr_fifo_dout(META_HDR_FIFO_HDR_RAW),
            CQ_HDR_BYTE_LNG => hdr_fifo_dout(META_HDR_FIFO_BYTE_CNT),
            CQ_HDR_SRC_RDY  => not hdr_fifo_empty,
            CQ_HDR_DST_RDY  => hdr_fifo_rd,

            DATA_BUFF_RD_CHAN     => buff_chan,
            DATA_BUFF_RD_DATA     => buff_data,
            DATA_BUFF_RD_ADDR     => buff_addr,
            DATA_BUFF_RD_EN       => buff_en,
            DATA_BUFF_RD_DATA_VLD => buff_data_vld,

            RDBUFF_DISP_RDS_CHAN      => RDBUFF_DISP_RDS_CHAN,
            RDBUFF_DISP_RDS_BYTES     => RDBUFF_DISP_RDS_BYTES,
            RDBUFF_DISP_RDS_INCR       => RDBUFF_DISP_RDS_INCR);

    nvme_cc_pkt_dispatcher_i : entity work.NVME_CC_PKT_DISPATCHER
        generic map (
            RX_REGIONS     => USR_MFB_REGIONS,
            RX_REGION_SIZE => USR_MFB_REGION_SIZE,
            RX_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
            RX_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

            TX_REGIONS     => PCIE_MFB_REGIONS,
            TX_REGION_SIZE => PCIE_MFB_REGION_SIZE,
            TX_BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
            TX_ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,

            DEVICE => DEVICE)
        port map (
            CLK => CLK,
            RST => RST,

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
            PCIE_HDR_SRC_RDY => cc_hdr_src_rdy,
            PCIE_HDR_DST_RDY => cc_hdr_dst_rdy);
end architecture;
