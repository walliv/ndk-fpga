-- fs_rd_tb_top.vhd: FS_RD_ISSUE and FS_RD_DATA behind the real USER_CORE_IF_PIPE, for cocotb
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.fs_pkg.all;

-- The DMA-side ports carry USER_CORE's names, so the shared multi-queue DMA model drives them.
entity FS_RD_TB_TOP is
    generic (
        STREAMS        : natural := 4;
        NUM_QUEUES     : natural := 4;
        PCIE_ENDPOINTS : natural := 2;
        STAGES         : natural := 6;
        REQ_FIFO_ITEMS : natural := 16;
        XCTX_ITEMS     : natural := 512
    );
    port (
        CLK     : in std_logic;
        DMA_RST : in std_logic;

        -- =========================================================================================
        -- Engine side
        -- =========================================================================================
        CREQ_VLD  : in  std_logic_vector(STREAMS-1 downto 0);
        CREQ_RDY  : out std_logic_vector(STREAMS-1 downto 0);
        CREQ_QID  : in  slv_array_t(STREAMS-1 downto 0)(max(1, log2(NUM_QUEUES))-1 downto 0);
        CREQ_LBA  : in  slv_array_t(STREAMS-1 downto 0)(FS_LBA_W-1 downto 0);
        CREQ_NLBA : in  slv_array_t(STREAMS-1 downto 0)(7 downto 0);
        CREQ_CTX  : in  slv_array_t(STREAMS-1 downto 0)(FS_CTX_W-1 downto 0);

        SINK : in std_logic;

        KIN_VLD     : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
        KIN_RDY     : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
        KIN_DATA    : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_DATA_W-1 downto 0);
        KIN_BYTES   : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_BYTES_W-1 downto 0);
        KIN_FIDX    : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_INDEX_W-1 downto 0);
        KIN_FOFS    : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_FOFS_W-1 downto 0);
        KIN_COFS    : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_COFS_W-1 downto 0);
        CDONE_VLD   : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
        CDONE_FSLOT : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_FSLOT_W-1 downto 0);
        BYTES_VLD   : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
        BYTES_N     : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_BYTES_W-1 downto 0);
        DATA_IDLE   : out std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

        RERR_VLD  : out std_logic;
        RERR_MASK : out std_logic_vector(STREAMS-1 downto 0);
        RERR_INFO : out std_logic_vector(31 downto 0);
        RD_IDLE   : out std_logic;

        -- =========================================================================================
        -- DMA side, as USER_CORE presents it
        -- =========================================================================================
        NVME_RD_REQ_LBA_NUM    : out std_logic_vector(7 downto 0);
        NVME_RD_REQ_NPAGES_ALL : out slv_array_t(NUM_QUEUES-1 downto 0)(work.iuventus_sizing_pkg.RD_HEAD_NPAGES_W-1 downto 0);
        NVME_RD_REQ_LBA_PTR    : out std_logic_vector(63 downto 0);
        NVME_RD_REQ_VLD        : out std_logic_vector(NUM_QUEUES-1 downto 0);
        NVME_RD_REQ_RDY        : in  std_logic_vector(NUM_QUEUES-1 downto 0);
        NVME_RD_REQ_QID        : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        NVME_RD_REQ_CID        : in  std_logic_vector(15 downto 0);
        NVME_RD_REQ_CID_VLD    : in  std_logic;

        NVME_OP_STAT_TYPE : in std_logic;
        NVME_OP_STAT_QID  : in std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        NVME_OP_STAT_CID  : in std_logic_vector(15 downto 0);
        NVME_OP_STAT_CODE : in std_logic_vector(1 downto 0);
        NVME_OP_STAT_VLD  : in std_logic;

        NVME_RD_MFB_DATA    : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_DATA_W-1 downto 0);
        NVME_RD_MFB_META    : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(max(1, log2(NUM_QUEUES))+16-1 downto 0);
        NVME_RD_MFB_SOF     : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
        NVME_RD_MFB_EOF     : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
        NVME_RD_MFB_SOF_POS : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
        NVME_RD_MFB_EOF_POS : in  slv_array_t(PCIE_ENDPOINTS-1 downto 0)(5 downto 0);
        NVME_RD_MFB_SRC_RDY : in  std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        NVME_RD_MFB_DST_RDY : out std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

        NVME_WR_MFB_DATA    : out std_logic_vector(FS_DATA_W-1 downto 0);
        NVME_WR_MFB_META    : out std_logic_vector(max(1, log2(NUM_QUEUES))+64-1 downto 0);
        NVME_WR_MFB_SOF     : out std_logic_vector(0 downto 0);
        NVME_WR_MFB_EOF     : out std_logic_vector(0 downto 0);
        NVME_WR_MFB_SOF_POS : out std_logic_vector(0 downto 0);
        NVME_WR_MFB_EOF_POS : out std_logic_vector(5 downto 0);
        NVME_WR_MFB_SRC_RDY : out std_logic;
        NVME_WR_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of FS_RD_TB_TOP is

    constant QID_W  : natural := max(1, log2(NUM_QUEUES));
    constant XCTX_W : natural := QID_W + FS_TAG_W + FS_CTX_W;

    signal eng_rst : std_logic;

    signal eng_req_lba : std_logic_vector(63 downto 0);
    signal eng_req_num : std_logic_vector(7 downto 0);
    signal eng_req_qid : std_logic_vector(QID_W-1 downto 0);
    signal eng_req_vld : std_logic;
    signal eng_req_rdy : std_logic_vector(NUM_QUEUES-1 downto 0);

    signal nvme_req_vld : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal nvme_req_qid : std_logic_vector(QID_W-1 downto 0);

    signal eng_rd_data    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_DATA_W-1 downto 0);
    signal eng_rd_meta    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(QID_W+16-1 downto 0);
    signal eng_rd_sof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
    signal eng_rd_eof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
    signal eng_rd_sof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
    signal eng_rd_eof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(5 downto 0);
    signal eng_rd_src_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal eng_rd_dst_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal xctx_vld  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal xctx_data : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(XCTX_W-1 downto 0);
    signal xctx_rd   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

begin

    if_pipe_i : entity work.USER_CORE_IF_PIPE
    generic map (
        NUM_QUEUES      => NUM_QUEUES,
        PCIE_ENDPOINTS  => PCIE_ENDPOINTS,
        LBA_PTR_W       => 64,
        MFB_REGION_SIZE => 1,
        MFB_BLOCK_SIZE  => 64,
        MFB_ITEM_WIDTH  => 8,
        CID_W           => 16,
        STAGES          => STAGES,
        REQ_FIFO_ITEMS  => REQ_FIFO_ITEMS,
        DEVICE          => "ULTRASCALE"
    )
    port map (
        CLK       => CLK,
        RESET     => DMA_RST,
        ENG_RESET => eng_rst,

        ENG_RD_REQ_LBA_PTR => eng_req_lba,
        ENG_RD_REQ_LBA_NUM => eng_req_num,
        ENG_RD_REQ_QID     => eng_req_qid,
        ENG_RD_REQ_VLD     => eng_req_vld,
        ENG_RD_REQ_RDY     => eng_req_rdy,
        ENG_RD_REQ_CID     => open,
        ENG_RD_REQ_CID_VLD => open,

        ENG_OP_STAT_TYPE => open,
        ENG_OP_STAT_CODE => open,
        ENG_OP_STAT_QID  => open,
        ENG_OP_STAT_CID  => open,
        ENG_OP_STAT_VLD  => open,

        ENG_RD_MFB_DATA    => eng_rd_data,
        ENG_RD_MFB_META    => eng_rd_meta,
        ENG_RD_MFB_SOF     => eng_rd_sof,
        ENG_RD_MFB_EOF     => eng_rd_eof,
        ENG_RD_MFB_SOF_POS => eng_rd_sof_pos,
        ENG_RD_MFB_EOF_POS => eng_rd_eof_pos,
        ENG_RD_MFB_SRC_RDY => eng_rd_src_rdy,
        ENG_RD_MFB_DST_RDY => eng_rd_dst_rdy,

        ENG_WR_MFB_DATA    => (others => '0'),
        ENG_WR_MFB_META    => (others => '0'),
        ENG_WR_MFB_SOF     => "0",
        ENG_WR_MFB_EOF     => "0",
        ENG_WR_MFB_SOF_POS => (others => '0'),
        ENG_WR_MFB_EOF_POS => (others => '0'),
        ENG_WR_MFB_SRC_RDY => '0',
        ENG_WR_MFB_DST_RDY => open,

        DMA_RD_REQ_LBA_PTR    => NVME_RD_REQ_LBA_PTR,
        DMA_RD_REQ_LBA_NUM    => NVME_RD_REQ_LBA_NUM,
        DMA_RD_REQ_QID        => nvme_req_qid,
        DMA_RD_REQ_VLD        => nvme_req_vld,
        DMA_RD_REQ_RDY        => NVME_RD_REQ_RDY,
        DMA_RD_REQ_NPAGES_ALL => NVME_RD_REQ_NPAGES_ALL,
        DMA_RD_REQ_CID        => NVME_RD_REQ_CID,
        DMA_RD_REQ_CID_VLD    => NVME_RD_REQ_CID_VLD,

        DMA_OP_STAT_TYPE => NVME_OP_STAT_TYPE,
        DMA_OP_STAT_CODE => NVME_OP_STAT_CODE,
        DMA_OP_STAT_QID  => NVME_OP_STAT_QID,
        DMA_OP_STAT_CID  => NVME_OP_STAT_CID,
        DMA_OP_STAT_VLD  => NVME_OP_STAT_VLD,

        DMA_RD_MFB_DATA    => NVME_RD_MFB_DATA,
        DMA_RD_MFB_META    => NVME_RD_MFB_META,
        DMA_RD_MFB_SOF     => NVME_RD_MFB_SOF,
        DMA_RD_MFB_EOF     => NVME_RD_MFB_EOF,
        DMA_RD_MFB_SOF_POS => NVME_RD_MFB_SOF_POS,
        DMA_RD_MFB_EOF_POS => NVME_RD_MFB_EOF_POS,
        DMA_RD_MFB_SRC_RDY => NVME_RD_MFB_SRC_RDY,
        DMA_RD_MFB_DST_RDY => NVME_RD_MFB_DST_RDY,

        DMA_WR_MFB_DATA    => NVME_WR_MFB_DATA,
        DMA_WR_MFB_META    => NVME_WR_MFB_META,
        DMA_WR_MFB_SOF     => NVME_WR_MFB_SOF,
        DMA_WR_MFB_EOF     => NVME_WR_MFB_EOF,
        DMA_WR_MFB_SOF_POS => NVME_WR_MFB_SOF_POS,
        DMA_WR_MFB_EOF_POS => NVME_WR_MFB_EOF_POS,
        DMA_WR_MFB_SRC_RDY => NVME_WR_MFB_SRC_RDY,
        DMA_WR_MFB_DST_RDY => NVME_WR_MFB_DST_RDY
    );

    NVME_RD_REQ_VLD <= nvme_req_vld;
    NVME_RD_REQ_QID <= nvme_req_qid;

    rd_issue_i : entity work.FS_RD_ISSUE
    generic map (
        STREAMS        => STREAMS,
        NUM_QUEUES     => NUM_QUEUES,
        PCIE_ENDPOINTS => PCIE_ENDPOINTS,
        CID_W          => 16,
        CTX_FIFO_ITEMS => 64,
        XCTX_ITEMS     => XCTX_ITEMS,
        DEVICE         => "ULTRASCALE"
    )
    port map (
        CLK   => CLK,
        RESET => eng_rst,
        CLEAR => '0',

        CREQ_VLD  => CREQ_VLD,
        CREQ_RDY  => CREQ_RDY,
        CREQ_QID  => CREQ_QID,
        CREQ_LBA  => CREQ_LBA,
        CREQ_NLBA => CREQ_NLBA,
        CREQ_CTX  => CREQ_CTX,

        ENG_RD_REQ_LBA_PTR => eng_req_lba,
        ENG_RD_REQ_LBA_NUM => eng_req_num,
        ENG_RD_REQ_QID     => eng_req_qid,
        ENG_RD_REQ_VLD     => eng_req_vld,
        ENG_RD_REQ_RDY     => eng_req_rdy,

        DMA_RD_REQ_VLD     => nvme_req_vld,
        DMA_RD_REQ_RDY     => NVME_RD_REQ_RDY,
        DMA_RD_REQ_QID     => nvme_req_qid,
        DMA_RD_REQ_CID     => NVME_RD_REQ_CID,
        DMA_RD_REQ_CID_VLD => NVME_RD_REQ_CID_VLD,

        DMA_OP_STAT_TYPE => NVME_OP_STAT_TYPE,
        DMA_OP_STAT_CODE => NVME_OP_STAT_CODE,
        DMA_OP_STAT_QID  => NVME_OP_STAT_QID,
        DMA_OP_STAT_CID  => NVME_OP_STAT_CID,
        DMA_OP_STAT_VLD  => NVME_OP_STAT_VLD,

        XCTX_VLD  => xctx_vld,
        XCTX_DATA => xctx_data,
        XCTX_RD   => xctx_rd,

        RERR_VLD  => RERR_VLD,
        RERR_MASK => RERR_MASK,
        RERR_INFO => RERR_INFO,

        RD_IDLE => RD_IDLE
    );

    rd_data_g : for e in 0 to PCIE_ENDPOINTS-1 generate
        rd_data_i : entity work.FS_RD_DATA
        generic map (
            STREAMS         => STREAMS,
            NUM_QUEUES      => NUM_QUEUES,
            CID_W           => 16,
            MFB_REGION_SIZE => 1,
            MFB_BLOCK_SIZE  => 64
        )
        port map (
            CLK   => CLK,
            RESET => eng_rst,
            CLEAR => '0',
            SINK  => SINK,

            RX_MFB_DATA    => eng_rd_data(e),
            RX_MFB_META    => eng_rd_meta(e),
            RX_MFB_SOF     => eng_rd_sof(e),
            RX_MFB_EOF     => eng_rd_eof(e),
            RX_MFB_SOF_POS => eng_rd_sof_pos(e),
            RX_MFB_EOF_POS => eng_rd_eof_pos(e),
            RX_MFB_SRC_RDY => eng_rd_src_rdy(e),
            RX_MFB_DST_RDY => eng_rd_dst_rdy(e),

            XCTX_VLD  => xctx_vld(e),
            XCTX_DATA => xctx_data(e),
            XCTX_RD   => xctx_rd(e),

            KIN_VLD   => KIN_VLD(e),
            KIN_RDY   => KIN_RDY(e),
            KIN_DATA  => KIN_DATA(e),
            KIN_BYTES => KIN_BYTES(e),
            KIN_FIDX  => KIN_FIDX(e),
            KIN_FOFS  => KIN_FOFS(e),
            KIN_COFS  => KIN_COFS(e),

            CDONE_VLD   => CDONE_VLD(e),
            CDONE_FSLOT => CDONE_FSLOT(e),
            BYTES_VLD   => BYTES_VLD(e),
            BYTES_N     => BYTES_N(e),

            IDLE => DATA_IDLE(e)
        );
    end generate;

end architecture;
