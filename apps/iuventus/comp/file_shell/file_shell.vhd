-- file_shell.vhd: the Iuventus file shell, reading input files and writing kernel output via the DMA
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

-- Everything runs on DMA_CLK; only the MI slave crosses from MI_CLK. The DMA-side ports carry
-- USER_CORE's names: FS_RD_ISSUE pairs CIDs there, behind USER_CORE_IF_PIPE's registers.
entity FILE_SHELL is
    generic (
        STREAMS           : natural                       := FS_MAX_STREAMS;
        NUM_QUEUES        : natural                       := 4;
        PCIE_ENDPOINTS    : natural                       := 1;
        KERNEL_ID         : natural                       := FS_KERNEL_DIGEST_FILL;
        MI_WIDTH          : natural                       := 32;
        MFB_REGION_SIZE   : natural                       := 1;
        MFB_BLOCK_SIZE    : natural                       := 64;
        MFB_ITEM_WIDTH    : natural                       := 8;
        CID_W             : natural                       := 16;
        IF_PIPE_STAGES    : natural                       := 6;
        IF_PIPE_REQ_ITEMS : natural                       := 16;
        STAGE_LOG2_BEATS  : natural                       := 12;
        DONE_QUIET        : natural                       := 1024;
        HBM_BASE          : std_logic_vector(33 downto 0) := (others => '0');
        DEVICE            : string                        := "ULTRASCALE"
    );
    port (
        DMA_CLK : in    std_logic;
        DMA_RST : in    std_logic;

        -- =========================================================================================
        -- MI slave
        -- =========================================================================================
        MI_CLK  : in    std_logic;
        MI_RST  : in    std_logic;
        MI_DWR  : in    std_logic_vector(MI_WIDTH-1 downto 0);
        MI_ADDR : in    std_logic_vector(MI_WIDTH-1 downto 0);
        MI_BE   : in    std_logic_vector(MI_WIDTH/8-1 downto 0);
        MI_RD   : in    std_logic;
        MI_WR   : in    std_logic;
        MI_ARDY : out   std_logic;
        MI_DRD  : out   std_logic_vector(MI_WIDTH-1 downto 0);
        MI_DRDY : out   std_logic;

        -- =========================================================================================
        -- DMA Iuventus, as USER_CORE presents it
        -- =========================================================================================
        NVME_RD_REQ_LBA_NUM    : out   std_logic_vector(7 downto 0);
        NVME_RD_REQ_NPAGES_ALL : out   slv_array_t(NUM_QUEUES-1 downto 0)(work.iuventus_sizing_pkg.RD_HEAD_NPAGES_W-1 downto 0);
        NVME_RD_REQ_LBA_PTR    : out   std_logic_vector(63 downto 0);
        NVME_RD_REQ_VLD        : out   std_logic_vector(NUM_QUEUES-1 downto 0);
        NVME_RD_REQ_RDY        : in    std_logic_vector(NUM_QUEUES-1 downto 0);
        NVME_RD_REQ_QID        : out   std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        NVME_RD_REQ_CID        : in    std_logic_vector(CID_W-1 downto 0);
        NVME_RD_REQ_CID_VLD    : in    std_logic;

        NVME_OP_STAT_TYPE : in    std_logic;
        NVME_OP_STAT_QID  : in    std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        NVME_OP_STAT_CID  : in    std_logic_vector(CID_W-1 downto 0);
        NVME_OP_STAT_CODE : in    std_logic_vector(1 downto 0);
        NVME_OP_STAT_VLD  : in    std_logic;

        NVME_RD_MFB_DATA    : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        NVME_RD_MFB_META    : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(max(1, log2(NUM_QUEUES))+CID_W-1 downto 0);
        NVME_RD_MFB_SOF     : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
        NVME_RD_MFB_EOF     : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
        NVME_RD_MFB_SOF_POS : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        NVME_RD_MFB_EOF_POS : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        NVME_RD_MFB_SRC_RDY : in    std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        NVME_RD_MFB_DST_RDY : out   std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

        NVME_WR_MFB_DATA    : out   std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        NVME_WR_MFB_META    : out   std_logic_vector(64+max(1, log2(NUM_QUEUES))-1 downto 0);
        NVME_WR_MFB_SOF     : out   std_logic_vector(0 downto 0);
        NVME_WR_MFB_EOF     : out   std_logic_vector(0 downto 0);
        NVME_WR_MFB_SOF_POS : out   std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        NVME_WR_MFB_EOF_POS : out   std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        NVME_WR_MFB_SRC_RDY : out   std_logic;
        NVME_WR_MFB_DST_RDY : in    std_logic;

        -- =========================================================================================
        -- HBM port, on DMA_CLK; HBM_READY already synchronised to it. HBM_RESET is the port's own
        -- reset, which outlasts DMA_RST: the AXI state of the shell may only reset with it.
        -- =========================================================================================
        HBM_READY : in    std_logic;
        HBM_RESET : in    std_logic;

        HBM_AXI_ARADDR       : out   std_logic_vector(33 downto 0);
        HBM_AXI_ARBURST      : out   std_logic_vector(1 downto 0);
        HBM_AXI_ARID         : out   std_logic_vector(5 downto 0);
        HBM_AXI_ARLEN        : out   std_logic_vector(3 downto 0);
        HBM_AXI_ARSIZE       : out   std_logic_vector(2 downto 0);
        HBM_AXI_ARVALID      : out   std_logic;
        HBM_AXI_ARREADY      : in    std_logic;
        HBM_AXI_AWADDR       : out   std_logic_vector(33 downto 0);
        HBM_AXI_AWBURST      : out   std_logic_vector(1 downto 0);
        HBM_AXI_AWID         : out   std_logic_vector(5 downto 0);
        HBM_AXI_AWLEN        : out   std_logic_vector(3 downto 0);
        HBM_AXI_AWSIZE       : out   std_logic_vector(2 downto 0);
        HBM_AXI_AWVALID      : out   std_logic;
        HBM_AXI_AWREADY      : in    std_logic;
        HBM_AXI_WDATA        : out   std_logic_vector(255 downto 0);
        HBM_AXI_WDATA_PARITY : out   std_logic_vector(31 downto 0);
        HBM_AXI_WLAST        : out   std_logic;
        HBM_AXI_WSTRB        : out   std_logic_vector(31 downto 0);
        HBM_AXI_WVALID       : out   std_logic;
        HBM_AXI_WREADY       : in    std_logic;
        HBM_AXI_BID          : in    std_logic_vector(5 downto 0);
        HBM_AXI_BRESP        : in    std_logic_vector(1 downto 0);
        HBM_AXI_BVALID       : in    std_logic;
        HBM_AXI_BREADY       : out   std_logic;
        HBM_AXI_RDATA        : in    std_logic_vector(255 downto 0);
        HBM_AXI_RID          : in    std_logic_vector(5 downto 0);
        HBM_AXI_RLAST        : in    std_logic;
        HBM_AXI_RRESP        : in    std_logic_vector(1 downto 0);
        HBM_AXI_RVALID       : in    std_logic;
        HBM_AXI_RREADY       : out   std_logic
    );
end entity;

architecture FULL of FILE_SHELL is

    constant QID_W      : natural := max(1, log2(NUM_QUEUES));
    constant SOF_POS_W  : natural := max(1, log2(MFB_REGION_SIZE));
    constant EOF_POS_W  : natural := log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE);
    constant XCTX_W     : natural := QID_W + FS_TAG_W + FS_CTX_W;
    constant FETCHERS   : natural := 2*STREAMS;
    -- Argument window of one stream: the address bits above FS_ARGS_ADDR_W name it.
    constant ARG_SEL_LO : natural := FS_ARGS_ADDR_W;

    signal eng_rst : std_logic;

    -- MI on DMA_CLK
    signal mi_addr_s : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_dwr_s  : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_be_s   : std_logic_vector(MI_WIDTH/8-1 downto 0);
    signal mi_rd_s   : std_logic;
    signal mi_wr_s   : std_logic;
    signal mi_ardy_s : std_logic;
    signal mi_drd_s  : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_drdy_s : std_logic;

    -- FS_REGS
    signal ctrl_start    : std_logic;
    signal ctrl_abort    : std_logic;
    signal ctrl_clear    : std_logic;
    signal stream_mask   : std_logic_vector(STREAMS-1 downto 0);
    signal stripe_drives : std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
    signal stripe_chunk  : std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
    signal in_tail       : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal out_tail      : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal status_busy   : std_logic;
    signal status_done   : std_logic;
    signal status_err    : std_logic;
    signal status_state  : std_logic_vector(7 downto 0);
    signal in_files      : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal in_head       : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal out_head      : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal in_bytes      : slv_array_t(STREAMS-1 downto 0)(63 downto 0);
    signal out_bytes     : slv_array_t(STREAMS-1 downto 0)(63 downto 0);
    signal stream_status : slv_array_t(STREAMS-1 downto 0)(3 downto 0);
    signal err_info      : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal ring_req_vld    : std_logic;
    signal ring_req_wr     : std_logic;
    signal ring_req_addr   : std_logic_vector(FS_RING_HBM_ADDR_W-1 downto 0);
    signal ring_req_data   : std_logic_vector(31 downto 0);
    signal ring_req_be     : std_logic_vector(3 downto 0);
    signal ring_req_rdy    : std_logic;
    signal ring_rsp_vld    : std_logic;
    signal ring_rsp_data   : std_logic_vector(31 downto 0);
    signal ring_wr_pending : std_logic;

    -- Kernel arguments: FS_REGS master, per-stream slaves
    signal arg_awaddr  : std_logic_vector(FS_ARGS_WIN_W-1 downto 0);
    signal arg_awvalid : std_logic;
    signal arg_awready : std_logic;
    signal arg_wdata   : std_logic_vector(31 downto 0);
    signal arg_wstrb   : std_logic_vector(3 downto 0);
    signal arg_wvalid  : std_logic;
    signal arg_wready  : std_logic;
    signal arg_bresp   : std_logic_vector(1 downto 0);
    signal arg_bvalid  : std_logic;
    signal arg_bready  : std_logic;
    signal arg_araddr  : std_logic_vector(FS_ARGS_WIN_W-1 downto 0);
    signal arg_arvalid : std_logic;
    signal arg_arready : std_logic;
    signal arg_rdata   : std_logic_vector(31 downto 0);
    signal arg_rresp   : std_logic_vector(1 downto 0);
    signal arg_rvalid  : std_logic;
    signal arg_rready  : std_logic;

    signal arg_wsel : natural range 0 to FS_MAX_STREAMS-1;
    signal arg_rsel : natural range 0 to FS_MAX_STREAMS-1;

    signal k_awvalid : std_logic_vector(STREAMS-1 downto 0);
    signal k_awready : std_logic_vector(STREAMS-1 downto 0);
    signal k_wvalid  : std_logic_vector(STREAMS-1 downto 0);
    signal k_wready  : std_logic_vector(STREAMS-1 downto 0);
    signal k_bresp   : slv_array_t(STREAMS-1 downto 0)(1 downto 0);
    signal k_bvalid  : std_logic_vector(STREAMS-1 downto 0);
    signal k_bready  : std_logic_vector(STREAMS-1 downto 0);
    signal k_arvalid : std_logic_vector(STREAMS-1 downto 0);
    signal k_arready : std_logic_vector(STREAMS-1 downto 0);
    signal k_rdata   : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal k_rresp   : slv_array_t(STREAMS-1 downto 0)(1 downto 0);
    signal k_rvalid  : std_logic_vector(STREAMS-1 downto 0);
    signal k_rready  : std_logic_vector(STREAMS-1 downto 0);

    -- Answers accesses to the argument windows of unbuilt streams, so MI never hangs there.
    signal nul_wr     : std_logic;
    signal nul_bvalid : std_logic;
    signal nul_rvalid : std_logic;

    -- FS_HBM_PORT clients
    signal freq_vld   : std_logic_vector(FETCHERS-1 downto 0);
    signal freq_addr  : slv_array_t(FETCHERS-1 downto 0)(FS_RING_HBM_ADDR_W-1 downto 0);
    signal freq_beats : slv_array_t(FETCHERS-1 downto 0)(4 downto 0);
    signal freq_rdy   : std_logic_vector(FETCHERS-1 downto 0);
    signal frsp_vld   : std_logic_vector(FETCHERS-1 downto 0);
    signal frsp_data  : std_logic_vector(255 downto 0);
    signal frsp_last  : std_logic;
    signal hbm_err    : std_logic;

    -- FS_CTRL
    signal plane_clear : std_logic;
    signal plane_start : std_logic_vector(STREAMS-1 downto 0);
    signal plane_abort : std_logic;
    signal enable      : std_logic_vector(STREAMS-1 downto 0);
    signal sink        : std_logic;

    -- Per stream
    signal in_ent_vld  : std_logic_vector(STREAMS-1 downto 0);
    signal in_ent_data : slv_array_t(STREAMS-1 downto 0)(FS_ENTRY_W-1 downto 0);
    signal in_ent_rdy  : std_logic_vector(STREAMS-1 downto 0);

    signal out_ent_vld  : std_logic_vector(STREAMS-1 downto 0);
    signal out_ent_data : slv_array_t(STREAMS-1 downto 0)(FS_ENTRY_W-1 downto 0);
    signal out_ent_rdy  : std_logic_vector(STREAMS-1 downto 0);

    signal creq_vld  : std_logic_vector(STREAMS-1 downto 0);
    signal creq_rdy  : std_logic_vector(STREAMS-1 downto 0);
    signal creq_qid  : slv_array_t(STREAMS-1 downto 0)(QID_W-1 downto 0);
    signal creq_lba  : slv_array_t(STREAMS-1 downto 0)(FS_LBA_W-1 downto 0);
    signal creq_nlba : slv_array_t(STREAMS-1 downto 0)(7 downto 0);
    signal creq_ctx  : slv_array_t(STREAMS-1 downto 0)(FS_CTX_W-1 downto 0);

    signal in_done       : std_logic_vector(STREAMS-1 downto 0);
    signal kernel_end    : std_logic_vector(STREAMS-1 downto 0);
    signal plan_err      : std_logic_vector(STREAMS-1 downto 0);
    signal plan_err_info : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal kout_vld   : std_logic_vector(STREAMS-1 downto 0);
    signal kout_rdy   : std_logic_vector(STREAMS-1 downto 0);
    signal kout_data  : slv_array_t(STREAMS-1 downto 0)(FS_DATA_W-1 downto 0);
    signal kout_bytes : slv_array_t(STREAMS-1 downto 0)(FS_BYTES_W-1 downto 0);
    signal kout_last  : std_logic_vector(STREAMS-1 downto 0);
    signal arg_err    : std_logic_vector(STREAMS-1 downto 0);
    signal kin_rdy_s  : slv_array_t(STREAMS-1 downto 0)(PCIE_ENDPOINTS-1 downto 0);

    signal need_space      : std_logic_vector(STREAMS-1 downto 0);
    signal out_done        : std_logic_vector(STREAMS-1 downto 0);
    signal wr_busy         : std_logic_vector(STREAMS-1 downto 0);
    signal writer_err      : std_logic_vector(STREAMS-1 downto 0);
    signal writer_err_info : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal wreq_vld    : std_logic_vector(STREAMS-1 downto 0);
    signal wreq_rdy    : std_logic_vector(STREAMS-1 downto 0);
    signal wreq_qid    : slv_array_t(STREAMS-1 downto 0)(QID_W-1 downto 0);
    signal wreq_lba    : slv_array_t(STREAMS-1 downto 0)(FS_LBA_W-1 downto 0);
    signal wreq_nlba   : slv_array_t(STREAMS-1 downto 0)(7 downto 0);
    signal wreq_nbytes : slv_array_t(STREAMS-1 downto 0)(FS_VBYTES_W-1 downto 0);
    signal wdat_vld    : std_logic_vector(STREAMS-1 downto 0);
    signal wdat_rdy    : std_logic_vector(STREAMS-1 downto 0);
    signal wdat_data   : slv_array_t(STREAMS-1 downto 0)(FS_DATA_W-1 downto 0);

    signal wr_outstanding : std_logic_vector(STREAMS-1 downto 0);
    signal werr_vld       : std_logic;
    signal werr_mask      : std_logic_vector(STREAMS-1 downto 0);
    signal werr_info      : std_logic_vector(31 downto 0);

    -- Read plane
    signal rerr_vld  : std_logic;
    signal rerr_mask : std_logic_vector(STREAMS-1 downto 0);
    signal rerr_info : std_logic_vector(31 downto 0);
    signal rd_idle   : std_logic;

    signal xctx_vld  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal xctx_data : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(XCTX_W-1 downto 0);
    signal xctx_rd   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal kin_vld      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
    signal kin_rdy      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
    signal kin_data     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_DATA_W-1 downto 0);
    signal kin_bytes    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_BYTES_W-1 downto 0);
    signal kin_fidx     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_INDEX_W-1 downto 0);
    signal kin_fofs     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_FOFS_W-1 downto 0);
    signal kin_cofs     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_COFS_W-1 downto 0);
    signal cdone_vld    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
    signal cdone_fslot  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_FSLOT_W-1 downto 0);
    signal bytes_vld    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
    signal bytes_n      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_BYTES_W-1 downto 0);
    signal rd_data_idle : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal rd_eof       : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    -- USER_CORE_IF_PIPE engine side
    signal eng_rd_req_lba_ptr : std_logic_vector(63 downto 0);
    signal eng_rd_req_lba_num : std_logic_vector(7 downto 0);
    signal eng_rd_req_qid     : std_logic_vector(QID_W-1 downto 0);
    signal eng_rd_req_vld     : std_logic;
    signal eng_rd_req_rdy     : std_logic_vector(NUM_QUEUES-1 downto 0);

    signal eng_op_stat_type : std_logic;
    signal eng_op_stat_code : std_logic_vector(1 downto 0);
    signal eng_op_stat_qid  : std_logic_vector(QID_W-1 downto 0);
    signal eng_op_stat_cid  : std_logic_vector(CID_W-1 downto 0);
    signal eng_op_stat_vld  : std_logic;

    signal eng_rd_mfb_data    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_DATA_W-1 downto 0);
    signal eng_rd_mfb_meta    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(QID_W+CID_W-1 downto 0);
    signal eng_rd_mfb_sof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
    signal eng_rd_mfb_eof     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(0 downto 0);
    signal eng_rd_mfb_sof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(SOF_POS_W-1 downto 0);
    signal eng_rd_mfb_eof_pos : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(EOF_POS_W-1 downto 0);
    signal eng_rd_mfb_src_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal eng_rd_mfb_dst_rdy : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal eng_wr_mfb_data    : std_logic_vector(FS_DATA_W-1 downto 0);
    signal eng_wr_mfb_meta    : std_logic_vector(QID_W+64-1 downto 0);
    signal eng_wr_mfb_sof     : std_logic_vector(0 downto 0);
    signal eng_wr_mfb_eof     : std_logic_vector(0 downto 0);
    -- FS_WR_ARB's SOF_POS is fixed at 3 bits and always 0; the if_pipe takes its low bits.
    signal eng_wr_mfb_sof_pos : std_logic_vector(2 downto 0);
    signal eng_wr_mfb_eof_pos : std_logic_vector(5 downto 0);
    signal eng_wr_mfb_src_rdy : std_logic;
    signal eng_wr_mfb_dst_rdy : std_logic;

    signal wr_frame  : std_logic;
    signal wr_status : std_logic;

    signal nvme_rd_req_vld_i : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal nvme_rd_req_qid_i : std_logic_vector(QID_W-1 downto 0);

begin

    assert (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH = FS_DATA_W and EOF_POS_W = 6 and SOF_POS_W <= 3)
        report "FILE_SHELL: the DMA user MFB must be one 512 b region of 64 bytes."
        severity FAILURE;
    assert (KERNEL_ID = FS_KERNEL_DIGEST_FILL)
        report "FILE_SHELL: KERNEL_ID " & integer'image(KERNEL_ID) & " is not built into this shell."
        severity FAILURE;
    assert (CID_W = 16)
        report "FILE_SHELL: CID_W must be 16 (FS_WR_ARB's status CID)."
        severity FAILURE;

    -- =============================================================================================
    -- MI: cross into DMA_CLK, then the register file
    -- =============================================================================================
    mi_async_i : entity work.MI_ASYNC
    generic map (
        DATA_WIDTH  => MI_WIDTH,
        ADDR_WIDTH  => MI_WIDTH,
        META_WIDTH  => 2,
        RAM_TYPE    => "LUT",
        RESET_LOGIC => true,
        DEVICE      => DEVICE
    )
    port map (
        CLK_M     => MI_CLK,
        RESET_M   => MI_RST,
        MI_M_ADDR => MI_ADDR,
        MI_M_DWR  => MI_DWR,
        MI_M_MWR  => (others => '0'),
        MI_M_BE   => MI_BE,
        MI_M_RD   => MI_RD,
        MI_M_WR   => MI_WR,
        MI_M_ARDY => MI_ARDY,
        MI_M_DRDY => MI_DRDY,
        MI_M_DRD  => MI_DRD,
        CLK_S     => DMA_CLK,
        RESET_S   => eng_rst,
        MI_S_ADDR => mi_addr_s,
        MI_S_DWR  => mi_dwr_s,
        MI_S_MWR  => open,
        MI_S_BE   => mi_be_s,
        MI_S_RD   => mi_rd_s,
        MI_S_WR   => mi_wr_s,
        MI_S_ARDY => mi_ardy_s,
        MI_S_DRDY => mi_drdy_s,
        MI_S_DRD  => mi_drd_s
    );

    regs_i : entity work.FS_REGS
    generic map (
        STREAMS   => STREAMS,
        KERNEL_ID => KERNEL_ID
    )
    port map (
        CLK   => DMA_CLK,
        RESET => eng_rst,
        -- FS_REGS zeroes the tails on its own CTRL_CLEAR; the plane CLEAR may come later, after
        -- the host already wrote the next job's tails.
        CLEAR => '0',

        MI_ADDR => mi_addr_s,
        MI_DWR  => mi_dwr_s,
        MI_BE   => mi_be_s,
        MI_RD   => mi_rd_s,
        MI_WR   => mi_wr_s,
        MI_ARDY => mi_ardy_s,
        MI_DRD  => mi_drd_s,
        MI_DRDY => mi_drdy_s,

        CTRL_START         => ctrl_start,
        CTRL_ABORT         => ctrl_abort,
        CTRL_CLEAR         => ctrl_clear,
        STREAM_MASK        => stream_mask,
        STRIPE_LOG2_DRIVES => stripe_drives,
        STRIPE_LOG2_CHUNK  => stripe_chunk,
        IN_TAIL            => in_tail,
        OUT_TAIL           => out_tail,

        STATUS_BUSY   => status_busy,
        STATUS_DONE   => status_done,
        STATUS_ERR    => status_err,
        STATUS_STATE  => status_state,
        IN_FILES      => in_files,
        IN_HEAD       => in_head,
        OUT_HEAD      => out_head,
        IN_BYTES      => in_bytes,
        OUT_BYTES     => out_bytes,
        STREAM_STATUS => stream_status,
        ERR_INFO      => err_info,

        RING_REQ_VLD    => ring_req_vld,
        RING_REQ_WR     => ring_req_wr,
        RING_REQ_ADDR   => ring_req_addr,
        RING_REQ_DATA   => ring_req_data,
        RING_REQ_BE     => ring_req_be,
        RING_REQ_RDY    => ring_req_rdy,
        RING_RSP_VLD    => ring_rsp_vld,
        RING_RSP_DATA   => ring_rsp_data,
        RING_WR_PENDING => ring_wr_pending,

        ARG_AXIL_AWADDR  => arg_awaddr,
        ARG_AXIL_AWVALID => arg_awvalid,
        ARG_AXIL_AWREADY => arg_awready,
        ARG_AXIL_WDATA   => arg_wdata,
        ARG_AXIL_WSTRB   => arg_wstrb,
        ARG_AXIL_WVALID  => arg_wvalid,
        ARG_AXIL_WREADY  => arg_wready,
        ARG_AXIL_BRESP   => arg_bresp,
        ARG_AXIL_BVALID  => arg_bvalid,
        ARG_AXIL_BREADY  => arg_bready,
        ARG_AXIL_ARADDR  => arg_araddr,
        ARG_AXIL_ARVALID => arg_arvalid,
        ARG_AXIL_ARREADY => arg_arready,
        ARG_AXIL_RDATA   => arg_rdata,
        ARG_AXIL_RRESP   => arg_rresp,
        ARG_AXIL_RVALID  => arg_rvalid,
        ARG_AXIL_RREADY  => arg_rready
    );

    -- =============================================================================================
    -- Kernel argument demultiplexer: FS_REGS holds one access at a time with a stable address
    -- =============================================================================================
    arg_wsel <= to_integer(unsigned(arg_awaddr(FS_ARGS_WIN_W-1 downto ARG_SEL_LO)));
    arg_rsel <= to_integer(unsigned(arg_araddr(FS_ARGS_WIN_W-1 downto ARG_SEL_LO)));

    arg_sel_g : for s in 0 to STREAMS-1 generate
        k_awvalid(s) <= arg_awvalid when (arg_wsel = s) else '0';
        k_wvalid(s)  <= arg_wvalid when (arg_wsel = s) else '0';
        k_bready(s)  <= arg_bready when (arg_wsel = s) else '0';
        k_arvalid(s) <= arg_arvalid when (arg_rsel = s) else '0';
        k_rready(s)  <= arg_rready when (arg_rsel = s) else '0';
    end generate;

    nul_wr <= '1' when (arg_wsel >= STREAMS and arg_awvalid = '1' and arg_wvalid = '1' and nul_bvalid = '0') else '0';

    nul_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (nul_bvalid = '1' and arg_bready = '1') then
                nul_bvalid <= '0';
            end if;
            if (nul_wr = '1') then
                nul_bvalid <= '1';
            end if;
            if (nul_rvalid = '1' and arg_rready = '1') then
                nul_rvalid <= '0';
            end if;
            if (arg_rsel >= STREAMS and arg_arvalid = '1' and nul_rvalid = '0') then
                nul_rvalid <= '1';
            end if;
            if (eng_rst = '1') then
                nul_bvalid <= '0';
                nul_rvalid <= '0';
            end if;
        end if;
    end process;

    arg_mux_p : process (all) is
    begin
        arg_awready <= nul_wr;
        arg_wready  <= nul_wr;
        arg_bresp   <= "00";
        arg_bvalid  <= nul_bvalid;
        arg_arready <= not nul_rvalid;
        arg_rdata   <= (others => '0');
        arg_rresp   <= "00";
        arg_rvalid  <= nul_rvalid;
        if (arg_wsel < STREAMS) then
            arg_awready <= k_awready(arg_wsel);
            arg_wready  <= k_wready(arg_wsel);
            arg_bresp   <= k_bresp(arg_wsel);
            arg_bvalid  <= k_bvalid(arg_wsel);
        end if;
        if (arg_rsel < STREAMS) then
            arg_arready <= k_arready(arg_rsel);
            arg_rdata   <= k_rdata(arg_rsel);
            arg_rresp   <= k_rresp(arg_rsel);
            arg_rvalid  <= k_rvalid(arg_rsel);
        end if;
    end process;

    -- =============================================================================================
    -- HBM port: the MI ring client and one burst-read client per ring (input s, output STREAMS+s)
    -- =============================================================================================
    hbm_port_i : entity work.FS_HBM_PORT
    generic map (
        FETCHERS => FETCHERS,
        HBM_BASE => HBM_BASE
    )
    port map (
        CLK       => DMA_CLK,
        RESET     => eng_rst,
        HBM_RESET => HBM_RESET,
        CLEAR     => plane_clear,
        HBM_READY => HBM_READY,

        RING_REQ_VLD    => ring_req_vld,
        RING_REQ_WR     => ring_req_wr,
        RING_REQ_ADDR   => ring_req_addr,
        RING_REQ_DATA   => ring_req_data,
        RING_REQ_BE     => ring_req_be,
        RING_REQ_RDY    => ring_req_rdy,
        RING_RSP_VLD    => ring_rsp_vld,
        RING_RSP_DATA   => ring_rsp_data,
        RING_WR_PENDING => ring_wr_pending,

        FREQ_VLD   => freq_vld,
        FREQ_ADDR  => freq_addr,
        FREQ_BEATS => freq_beats,
        FREQ_RDY   => freq_rdy,
        FRSP_VLD   => frsp_vld,
        FRSP_DATA  => frsp_data,
        FRSP_LAST  => frsp_last,

        HBM_ERR => hbm_err,

        M_AXI_ARADDR       => HBM_AXI_ARADDR,
        M_AXI_ARBURST      => HBM_AXI_ARBURST,
        M_AXI_ARID         => HBM_AXI_ARID,
        M_AXI_ARLEN        => HBM_AXI_ARLEN,
        M_AXI_ARSIZE       => HBM_AXI_ARSIZE,
        M_AXI_ARVALID      => HBM_AXI_ARVALID,
        M_AXI_ARREADY      => HBM_AXI_ARREADY,
        M_AXI_AWADDR       => HBM_AXI_AWADDR,
        M_AXI_AWBURST      => HBM_AXI_AWBURST,
        M_AXI_AWID         => HBM_AXI_AWID,
        M_AXI_AWLEN        => HBM_AXI_AWLEN,
        M_AXI_AWSIZE       => HBM_AXI_AWSIZE,
        M_AXI_AWVALID      => HBM_AXI_AWVALID,
        M_AXI_AWREADY      => HBM_AXI_AWREADY,
        M_AXI_WDATA        => HBM_AXI_WDATA,
        M_AXI_WDATA_PARITY => HBM_AXI_WDATA_PARITY,
        M_AXI_WLAST        => HBM_AXI_WLAST,
        M_AXI_WSTRB        => HBM_AXI_WSTRB,
        M_AXI_WVALID       => HBM_AXI_WVALID,
        M_AXI_WREADY       => HBM_AXI_WREADY,
        M_AXI_BID          => HBM_AXI_BID,
        M_AXI_BRESP        => HBM_AXI_BRESP,
        M_AXI_BVALID       => HBM_AXI_BVALID,
        M_AXI_BREADY       => HBM_AXI_BREADY,
        M_AXI_RDATA        => HBM_AXI_RDATA,
        M_AXI_RID          => HBM_AXI_RID,
        M_AXI_RLAST        => HBM_AXI_RLAST,
        M_AXI_RRESP        => HBM_AXI_RRESP,
        M_AXI_RVALID       => HBM_AXI_RVALID,
        M_AXI_RREADY       => HBM_AXI_RREADY
    );

    -- =============================================================================================
    -- Per stream: rings, planner, kernel, writer
    -- =============================================================================================
    stream_g : for s in 0 to STREAMS-1 generate
        signal k_in_vld   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        signal k_in_files : std_logic_vector(31 downto 0);
    begin
        in_fetch_i : entity work.FS_RING_FETCH
        generic map (
            LOG2_DEPTH   => FS_IN_RING_LOG2,
            RING_BASE    => FS_IN_RING_MI_BASE - FS_RING_MI_BASE + s*FS_IN_RING_STRIDE,
            FIFO_ENTRIES => 64,
            DEVICE       => DEVICE
        )
        port map (
            CLK    => DMA_CLK,
            RESET  => eng_rst,
            CLEAR  => plane_clear,
            ENABLE => enable(s),
            TAIL   => in_tail(s),
            HEAD   => in_head(s),

            FREQ_VLD   => freq_vld(s),
            FREQ_ADDR  => freq_addr(s),
            FREQ_BEATS => freq_beats(s),
            FREQ_RDY   => freq_rdy(s),
            FRSP_VLD   => frsp_vld(s),
            FRSP_DATA  => frsp_data,
            FRSP_LAST  => frsp_last,

            ENT_VLD  => in_ent_vld(s),
            ENT_DATA => in_ent_data(s),
            ENT_RDY  => in_ent_rdy(s)
        );

        out_fetch_i : entity work.FS_RING_FETCH
        generic map (
            LOG2_DEPTH   => FS_OUT_RING_LOG2,
            RING_BASE    => FS_OUT_RING_MI_BASE - FS_RING_MI_BASE + s*FS_OUT_RING_STRIDE,
            FIFO_ENTRIES => 64,
            DEVICE       => DEVICE
        )
        port map (
            CLK    => DMA_CLK,
            RESET  => eng_rst,
            CLEAR  => plane_clear,
            ENABLE => enable(s),
            TAIL   => out_tail(s),
            HEAD   => out_head(s),

            FREQ_VLD   => freq_vld(STREAMS+s),
            FREQ_ADDR  => freq_addr(STREAMS+s),
            FREQ_BEATS => freq_beats(STREAMS+s),
            FREQ_RDY   => freq_rdy(STREAMS+s),
            FRSP_VLD   => frsp_vld(STREAMS+s),
            FRSP_DATA  => frsp_data,
            FRSP_LAST  => frsp_last,

            ENT_VLD  => out_ent_vld(s),
            ENT_DATA => out_ent_data(s),
            ENT_RDY  => out_ent_rdy(s)
        );

        planner_i : entity work.FS_IN_PLANNER
        generic map (
            STREAM_IDX  => s,
            NUM_QUEUES  => NUM_QUEUES,
            CDONE_LANES => PCIE_ENDPOINTS
        )
        port map (
            CLK    => DMA_CLK,
            RESET  => eng_rst,
            CLEAR  => plane_clear,
            START  => plane_start(s),
            ENABLE => enable(s),

            STRIPE_LOG2_DRIVES => stripe_drives,
            STRIPE_LOG2_CHUNK  => stripe_chunk,

            ENT_VLD  => in_ent_vld(s),
            ENT_DATA => in_ent_data(s),
            ENT_RDY  => in_ent_rdy(s),

            CREQ_VLD  => creq_vld(s),
            CREQ_RDY  => creq_rdy(s),
            CREQ_QID  => creq_qid(s),
            CREQ_LBA  => creq_lba(s),
            CREQ_NLBA => creq_nlba(s),
            CREQ_CTX  => creq_ctx(s),

            CDONE_VLD   => k_in_vld,
            CDONE_FSLOT => cdone_fslot,

            IN_FILES   => k_in_files,
            IN_DONE    => in_done(s),
            KERNEL_END => kernel_end(s),
            ERR        => plan_err(s),
            ERR_INFO   => plan_err_info(s)
        );

        in_files(s) <= k_in_files;

        lane_g : for e in 0 to PCIE_ENDPOINTS-1 generate
            k_in_vld(e)   <= cdone_vld(e)(s);
            kin_rdy(e)(s) <= kin_rdy_s(s)(e);
        end generate;

        kernel_g : if (KERNEL_ID = FS_KERNEL_DIGEST_FILL) generate
            signal lane_vld : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        begin
            lane_vld_g : for e in 0 to PCIE_ENDPOINTS-1 generate
                lane_vld(e) <= kin_vld(e)(s);
            end generate;

            kernel_i : entity work.FS_KERNEL_DIGEST_FILL
            generic map (
                LANES => PCIE_ENDPOINTS
            )
            port map (
                CLK   => DMA_CLK,
                RESET => eng_rst,
                CLEAR => plane_clear,
                START => plane_start(s),

                S_AXIL_AWADDR  => arg_awaddr(FS_ARGS_ADDR_W-1 downto 0),
                S_AXIL_AWVALID => k_awvalid(s),
                S_AXIL_AWREADY => k_awready(s),
                S_AXIL_WDATA   => arg_wdata,
                S_AXIL_WSTRB   => arg_wstrb,
                S_AXIL_WVALID  => k_wvalid(s),
                S_AXIL_WREADY  => k_wready(s),
                S_AXIL_BRESP   => k_bresp(s),
                S_AXIL_BVALID  => k_bvalid(s),
                S_AXIL_BREADY  => k_bready(s),
                S_AXIL_ARADDR  => arg_araddr(FS_ARGS_ADDR_W-1 downto 0),
                S_AXIL_ARVALID => k_arvalid(s),
                S_AXIL_ARREADY => k_arready(s),
                S_AXIL_RDATA   => k_rdata(s),
                S_AXIL_RRESP   => k_rresp(s),
                S_AXIL_RVALID  => k_rvalid(s),
                S_AXIL_RREADY  => k_rready(s),

                IN_VLD   => lane_vld,
                IN_RDY   => kin_rdy_s(s),
                IN_DATA  => kin_data,
                IN_BYTES => kin_bytes,
                IN_FIDX  => kin_fidx,
                IN_FOFS  => kin_fofs,
                IN_COFS  => kin_cofs,
                IN_END   => kernel_end(s),
                IN_FILES => k_in_files,

                OUT_VLD   => kout_vld(s),
                OUT_RDY   => kout_rdy(s),
                OUT_DATA  => kout_data(s),
                OUT_BYTES => kout_bytes(s),
                OUT_LAST  => kout_last(s),

                ARG_ERR => arg_err(s)
            );
        end generate;

        writer_i : entity work.FS_OUT_WRITER
        generic map (
            NUM_QUEUES       => NUM_QUEUES,
            STAGE_LOG2_BEATS => STAGE_LOG2_BEATS
        )
        port map (
            CLK    => DMA_CLK,
            RESET  => eng_rst,
            CLEAR  => plane_clear,
            START  => plane_start(s),
            ABORT  => plane_abort,
            ENABLE => enable(s),

            STRIPE_LOG2_DRIVES => stripe_drives,
            STRIPE_LOG2_CHUNK  => stripe_chunk,

            KOUT_VLD   => kout_vld(s),
            KOUT_RDY   => kout_rdy(s),
            KOUT_DATA  => kout_data(s),
            KOUT_BYTES => kout_bytes(s),
            KOUT_LAST  => kout_last(s),

            ENT_VLD    => out_ent_vld(s),
            ENT_DATA   => out_ent_data(s),
            ENT_RDY    => out_ent_rdy(s),
            OUT_HEAD   => out_head(s),
            OUT_TAIL   => out_tail(s),
            NEED_SPACE => need_space(s),

            WREQ_VLD    => wreq_vld(s),
            WREQ_RDY    => wreq_rdy(s),
            WREQ_QID    => wreq_qid(s),
            WREQ_LBA    => wreq_lba(s),
            WREQ_NLBA   => wreq_nlba(s),
            WREQ_NBYTES => wreq_nbytes(s),

            WDAT_VLD  => wdat_vld(s),
            WDAT_RDY  => wdat_rdy(s),
            WDAT_DATA => wdat_data(s),

            WR_OUTSTANDING => wr_outstanding(s),
            OUT_DONE       => out_done(s),
            BUSY           => wr_busy(s),
            ERR            => writer_err(s),
            ERR_INFO       => writer_err_info(s)
        );
    end generate;

    -- =============================================================================================
    -- Read plane
    -- =============================================================================================
    rd_issue_i : entity work.FS_RD_ISSUE
    generic map (
        STREAMS        => STREAMS,
        NUM_QUEUES     => NUM_QUEUES,
        PCIE_ENDPOINTS => PCIE_ENDPOINTS,
        CID_W          => CID_W,
        CTX_FIFO_ITEMS => 64,
        XCTX_ITEMS     => 512,
        DEVICE         => DEVICE
    )
    port map (
        CLK   => DMA_CLK,
        RESET => eng_rst,
        CLEAR => plane_clear,

        CREQ_VLD  => creq_vld,
        CREQ_RDY  => creq_rdy,
        CREQ_QID  => creq_qid,
        CREQ_LBA  => creq_lba,
        CREQ_NLBA => creq_nlba,
        CREQ_CTX  => creq_ctx,

        ENG_RD_REQ_LBA_PTR => eng_rd_req_lba_ptr,
        ENG_RD_REQ_LBA_NUM => eng_rd_req_lba_num,
        ENG_RD_REQ_QID     => eng_rd_req_qid,
        ENG_RD_REQ_VLD     => eng_rd_req_vld,
        ENG_RD_REQ_RDY     => eng_rd_req_rdy,

        DMA_RD_REQ_VLD     => nvme_rd_req_vld_i,
        DMA_RD_REQ_RDY     => NVME_RD_REQ_RDY,
        DMA_RD_REQ_QID     => nvme_rd_req_qid_i,
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

        RERR_VLD  => rerr_vld,
        RERR_MASK => rerr_mask,
        RERR_INFO => rerr_info,

        RD_IDLE => rd_idle
    );

    rd_data_g : for e in 0 to PCIE_ENDPOINTS-1 generate
        rd_data_i : entity work.FS_RD_DATA
        generic map (
            STREAMS         => STREAMS,
            NUM_QUEUES      => NUM_QUEUES,
            CID_W           => CID_W,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE
        )
        port map (
            CLK   => DMA_CLK,
            RESET => eng_rst,
            CLEAR => plane_clear,
            SINK  => sink,

            RX_MFB_DATA    => eng_rd_mfb_data(e),
            RX_MFB_META    => eng_rd_mfb_meta(e),
            RX_MFB_SOF     => eng_rd_mfb_sof(e),
            RX_MFB_EOF     => eng_rd_mfb_eof(e),
            RX_MFB_SOF_POS => eng_rd_mfb_sof_pos(e),
            RX_MFB_EOF_POS => eng_rd_mfb_eof_pos(e),
            RX_MFB_SRC_RDY => eng_rd_mfb_src_rdy(e),
            RX_MFB_DST_RDY => eng_rd_mfb_dst_rdy(e),

            XCTX_VLD  => xctx_vld(e),
            XCTX_DATA => xctx_data(e),
            XCTX_RD   => xctx_rd(e),

            KIN_VLD   => kin_vld(e),
            KIN_RDY   => kin_rdy(e),
            KIN_DATA  => kin_data(e),
            KIN_BYTES => kin_bytes(e),
            KIN_FIDX  => kin_fidx(e),
            KIN_FOFS  => kin_fofs(e),
            KIN_COFS  => kin_cofs(e),

            CDONE_VLD   => cdone_vld(e),
            CDONE_FSLOT => cdone_fslot(e),
            BYTES_VLD   => bytes_vld(e),
            BYTES_N     => bytes_n(e),

            IDLE => rd_data_idle(e)
        );

        rd_eof(e) <= eng_rd_mfb_src_rdy(e) and eng_rd_mfb_dst_rdy(e) and eng_rd_mfb_eof(e)(0);
    end generate;

    -- =============================================================================================
    -- Write plane
    -- =============================================================================================
    wr_arb_i : entity work.FS_WR_ARB
    generic map (
        STREAMS        => STREAMS,
        NUM_QUEUES     => NUM_QUEUES,
        CPL_FIFO_ITEMS => 72,
        DEVICE         => DEVICE
    )
    port map (
        CLK   => DMA_CLK,
        RESET => eng_rst,
        CLEAR => plane_clear,

        WREQ_VLD    => wreq_vld,
        WREQ_RDY    => wreq_rdy,
        WREQ_QID    => wreq_qid,
        WREQ_LBA    => wreq_lba,
        WREQ_NLBA   => wreq_nlba,
        WREQ_NBYTES => wreq_nbytes,

        WDAT_VLD  => wdat_vld,
        WDAT_RDY  => wdat_rdy,
        WDAT_DATA => wdat_data,

        WR_MFB_DATA    => eng_wr_mfb_data,
        WR_MFB_META    => eng_wr_mfb_meta,
        WR_MFB_SOF     => eng_wr_mfb_sof,
        WR_MFB_EOF     => eng_wr_mfb_eof,
        WR_MFB_SOF_POS => eng_wr_mfb_sof_pos,
        WR_MFB_EOF_POS => eng_wr_mfb_eof_pos,
        WR_MFB_SRC_RDY => eng_wr_mfb_src_rdy,
        WR_MFB_DST_RDY => eng_wr_mfb_dst_rdy,

        OP_STAT_TYPE => eng_op_stat_type,
        OP_STAT_CODE => eng_op_stat_code,
        OP_STAT_QID  => eng_op_stat_qid,
        OP_STAT_CID  => eng_op_stat_cid,
        OP_STAT_VLD  => eng_op_stat_vld,

        OUT_BYTES      => out_bytes,
        WR_OUTSTANDING => wr_outstanding,
        WERR_VLD       => werr_vld,
        WERR_MASK      => werr_mask,
        WERR_INFO      => werr_info
    );

    -- =============================================================================================
    -- Job control
    -- =============================================================================================
    wr_frame  <= eng_wr_mfb_src_rdy and eng_wr_mfb_dst_rdy and eng_wr_mfb_sof(0);
    wr_status <= eng_op_stat_vld and not eng_op_stat_type;

    ctrl_i : entity work.FS_CTRL
    generic map (
        STREAMS        => STREAMS,
        NUM_QUEUES     => NUM_QUEUES,
        PCIE_ENDPOINTS => PCIE_ENDPOINTS,
        DONE_QUIET     => DONE_QUIET
    )
    port map (
        CLK   => DMA_CLK,
        RESET => eng_rst,

        CTRL_START         => ctrl_start,
        CTRL_ABORT         => ctrl_abort,
        CTRL_CLEAR         => ctrl_clear,
        STREAM_MASK        => stream_mask,
        STRIPE_LOG2_DRIVES => stripe_drives,
        STRIPE_LOG2_CHUNK  => stripe_chunk,

        PLANE_CLEAR => plane_clear,
        PLANE_START => plane_start,
        PLANE_ABORT => plane_abort,
        ENABLE      => enable,
        SINK        => sink,

        STATUS_BUSY   => status_busy,
        STATUS_DONE   => status_done,
        STATUS_ERR    => status_err,
        STATUS_STATE  => status_state,
        STREAM_STATUS => stream_status,
        ERR_INFO      => err_info,
        IN_BYTES      => in_bytes,

        IN_DONE    => in_done,
        OUT_DONE   => out_done,
        NEED_SPACE => need_space,

        PLAN_ERR        => plan_err,
        PLAN_ERR_INFO   => plan_err_info,
        WRITER_ERR      => writer_err,
        WRITER_ERR_INFO => writer_err_info,
        ARG_ERR         => arg_err,
        RERR_VLD        => rerr_vld,
        RERR_MASK       => rerr_mask,
        RERR_INFO       => rerr_info,
        WERR_VLD        => werr_vld,
        WERR_MASK       => werr_mask,
        WERR_INFO       => werr_info,
        HBM_ERR         => hbm_err,

        RD_IDLE        => rd_idle,
        RD_DATA_IDLE   => rd_data_idle,
        RD_EOF         => rd_eof,
        WR_BUSY        => wr_busy,
        WR_OUTSTANDING => wr_outstanding,
        WR_FRAME       => wr_frame,
        WR_STATUS      => wr_status,
        BYTES_VLD      => bytes_vld,
        BYTES_N        => bytes_n
    );

    -- =============================================================================================
    -- Interface pipeline to the DMA
    -- =============================================================================================
    if_pipe_i : entity work.USER_CORE_IF_PIPE
    generic map (
        NUM_QUEUES      => NUM_QUEUES,
        PCIE_ENDPOINTS  => PCIE_ENDPOINTS,
        LBA_PTR_W       => 64,
        MFB_REGION_SIZE => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        CID_W           => CID_W,
        STAGES          => IF_PIPE_STAGES,
        REQ_FIFO_ITEMS  => IF_PIPE_REQ_ITEMS,
        DEVICE          => DEVICE
    )
    port map (
        CLK       => DMA_CLK,
        RESET     => DMA_RST,
        ENG_RESET => eng_rst,

        ENG_RD_REQ_LBA_PTR => eng_rd_req_lba_ptr,
        ENG_RD_REQ_LBA_NUM => eng_rd_req_lba_num,
        ENG_RD_REQ_QID     => eng_rd_req_qid,
        ENG_RD_REQ_VLD     => eng_rd_req_vld,
        ENG_RD_REQ_RDY     => eng_rd_req_rdy,
        ENG_RD_REQ_CID     => open,
        ENG_RD_REQ_CID_VLD => open,

        ENG_OP_STAT_TYPE => eng_op_stat_type,
        ENG_OP_STAT_CODE => eng_op_stat_code,
        ENG_OP_STAT_QID  => eng_op_stat_qid,
        ENG_OP_STAT_CID  => eng_op_stat_cid,
        ENG_OP_STAT_VLD  => eng_op_stat_vld,

        ENG_RD_MFB_DATA    => eng_rd_mfb_data,
        ENG_RD_MFB_META    => eng_rd_mfb_meta,
        ENG_RD_MFB_SOF     => eng_rd_mfb_sof,
        ENG_RD_MFB_EOF     => eng_rd_mfb_eof,
        ENG_RD_MFB_SOF_POS => eng_rd_mfb_sof_pos,
        ENG_RD_MFB_EOF_POS => eng_rd_mfb_eof_pos,
        ENG_RD_MFB_SRC_RDY => eng_rd_mfb_src_rdy,
        ENG_RD_MFB_DST_RDY => eng_rd_mfb_dst_rdy,

        ENG_WR_MFB_DATA    => eng_wr_mfb_data,
        ENG_WR_MFB_META    => eng_wr_mfb_meta,
        ENG_WR_MFB_SOF     => eng_wr_mfb_sof,
        ENG_WR_MFB_EOF     => eng_wr_mfb_eof,
        ENG_WR_MFB_SOF_POS => eng_wr_mfb_sof_pos(SOF_POS_W-1 downto 0),
        ENG_WR_MFB_EOF_POS => eng_wr_mfb_eof_pos,
        ENG_WR_MFB_SRC_RDY => eng_wr_mfb_src_rdy,
        ENG_WR_MFB_DST_RDY => eng_wr_mfb_dst_rdy,

        DMA_RD_REQ_LBA_PTR    => NVME_RD_REQ_LBA_PTR,
        DMA_RD_REQ_LBA_NUM    => NVME_RD_REQ_LBA_NUM,
        DMA_RD_REQ_QID        => nvme_rd_req_qid_i,
        DMA_RD_REQ_VLD        => nvme_rd_req_vld_i,
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

    NVME_RD_REQ_VLD <= nvme_rd_req_vld_i;
    NVME_RD_REQ_QID <= nvme_rd_req_qid_i;

end architecture;
