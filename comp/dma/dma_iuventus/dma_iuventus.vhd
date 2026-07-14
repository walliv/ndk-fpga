-- dma_iuventus.vhd: the top entity of the DMA engine for NVMe access
-- Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note: The component require 4 BARs configured for the PCIe domain.
--  1. BAR0 for Submission Queue (128 KiB)
--  2. BAR1 for Completion Queue (128 KiB)
--  3. BAR2 for Write Buffer (128 KiB)
--  4. BAR3 for Read Buffer (128 KiB)

use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;
use work.nvme_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity DMA_IUVENTUS is
    generic (
        PCIE_MFB_REGIONS     : natural  := 2;
        PCIE_MFB_REGION_SIZE : natural  := 1;
        PCIE_MFB_BLOCK_SIZE  : natural  := 8;
        PCIE_MFB_ITEM_WIDTH  : natural  := 32;

        USR_MFB_REGIONS     : natural  := 1;
        USR_MFB_REGION_SIZE : natural  := 1;
        USR_MFB_BLOCK_SIZE  : natural  := 64;
        USR_MFB_ITEM_WIDTH  : natural  := 8;

        -- 32 as always
        MI_WIDTH        : positive := 32;
        -- If True the MI clock is the same as CLK and no CDC is necessary
        MI_SAME_CLK     : boolean  := false;
        -- The allowed is only "ULTRASCALE"
        DEVICE          : string   := "ULTRASCALE";
        -- Amount of tags/Command Identifiers available for outstanding NVMe commands
        QUEUE_DEPTH     : natural  := 16;
        -- Number of independent SQ/CQ queues (one per SSD): pages 0..NUM_QUEUES-1 hold SQ[q]/CQ[q],
        -- pages NUM_QUEUES..127 are the shared data pool. A single round-robin CQE arbiter and a
        -- single SQ dispatch pipe serve all N queues (see cqe_processor.vhd/nvme_cmd_dispatcher.vhd).
        -- At NUM_QUEUES=1 (the default) this design is bit-identical to the original single-queue
        -- implementation.
        NUM_QUEUES      : natural  := 1;
        -- Width of each queue's own one-shot FLUSH keepalive delay counter (see OP_CTRL). 28 bits
        -- is the real production value; only a testbench should ever override this (to a much
        -- smaller value, so the FLUSH path is reachable in a reasonable simulation time) -- never
        -- change the default itself.
        FLUSH_DELAY_CNTR_WIDTH : positive := 28
        );

    port (
        CLK : in std_logic;
        RST : in std_logic;

        MI_CLK : in std_logic;
        MI_RST : in std_logic;

        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_ARDY : out std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DRDY : out std_logic;

        -- =========================================================================================
        -- Read operation submit interface
        -- =========================================================================================
        -- The size of data (only for read operations, 0-based value).
        NVME_RD_REQ_LBA_NUM : in  std_logic_vector(7 downto 0);
        -- This is a LBA address (not a byte address) to the NVMe
        NVME_RD_REQ_LBA_PTR : in  std_logic_vector(SQE_LBA_PTR_W -1 downto 0);
        -- Queue Identifier this read request targets. Left "open"/undriven by a single-queue
        -- caller defaults to "0" (see the := (others => '0') default below), so existing
        -- NUM_QUEUES=1 callers are unaffected.
        NVME_RD_REQ_QID     : in  std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0) := (others => '0');
        NVME_RD_REQ_VLD     : in  std_logic;
        NVME_RD_REQ_RDY     : out std_logic;

        -- =========================================================================================
        -- Operation status interface
        -- =========================================================================================
        -- 0 for write, 1 for read
        OP_STAT_TYPE : out std_logic;
        OP_STAT_CODE : out std_logic_vector(1 downto 0);
        OP_STAT_VLD  : out std_logic;

        -- =========================================================================================
        -- Read interface
        -- =========================================================================================
        RD_MFB_DATA    : out std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        RD_MFB_SOF     : out std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        RD_MFB_EOF     : out std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        RD_MFB_SOF_POS : out std_logic_vector(USR_MFB_REGIONS*maximum(1, log2(USR_MFB_REGION_SIZE))-1 downto 0);
        RD_MFB_EOF_POS : out std_logic_vector(USR_MFB_REGIONS*log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)-1 downto 0);
        RD_MFB_SRC_RDY : out std_logic;
        RD_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Write interface
        --
        -- Althougn the data size seems unlimited, the maximum is 128 KiB, or 256 LBAs/32 pages
        -- =========================================================================================
        WR_MFB_DATA    : in  std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        -- Per region: bits [SQE_LBA_PTR_W-1:0] = LBA to which data should be written; bits
        -- [SQE_LBA_PTR_W+QID_W-1:SQE_LBA_PTR_W] = Queue Identifier this write request targets
        -- (see NVME_WR_REQ_QID below). A single-queue caller supplying only the low
        -- SQE_LBA_PTR_W bits gets the high QID bits zero-extended (QID=0) automatically.
        WR_MFB_META    : in  std_logic_vector(USR_MFB_REGIONS*(SQE_LBA_PTR_W + maximum(1, log2(NUM_QUEUES))) -1 downto 0);
        WR_MFB_SOF     : in  std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        WR_MFB_EOF     : in  std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        WR_MFB_SOF_POS : in  std_logic_vector(USR_MFB_REGIONS*maximum(1, log2(USR_MFB_REGION_SIZE))-1 downto 0);
        WR_MFB_EOF_POS : in  std_logic_vector(USR_MFB_REGIONS*log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)-1 downto 0);
        WR_MFB_SRC_RDY : in  std_logic;
        WR_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- PCIe interface to receive Completion Queue Entries and user data from NVMe
        -- =========================================================================================
        PCIE_CQ_MFB_DATA    : in  std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CQ_MFB_META    : in  std_logic_vector(PCIE_MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        PCIE_CQ_MFB_SOF     : in  std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_CQ_MFB_EOF     : in  std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_CQ_MFB_SOF_POS : in  std_logic_vector(PCIE_MFB_REGIONS*max(1, log2(PCIE_MFB_REGION_SIZE))-1 downto 0);
        PCIE_CQ_MFB_EOF_POS : in  std_logic_vector(PCIE_MFB_REGIONS*log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_CQ_MFB_SRC_RDY : in  std_logic;
        PCIE_CQ_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- PCIe interface to send responses for reads from Submission Queue and data for write
        -- commands
        -- =========================================================================================
        PCIE_CC_MFB_DATA    : out std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_CC_MFB_META    : out std_logic_vector(PCIE_MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
        PCIE_CC_MFB_SOF     : out std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_CC_MFB_EOF     : out std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_CC_MFB_SOF_POS : out std_logic_vector(PCIE_MFB_REGIONS*max(1, log2(PCIE_MFB_REGION_SIZE))-1 downto 0);
        PCIE_CC_MFB_EOF_POS : out std_logic_vector(PCIE_MFB_REGIONS*log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_CC_MFB_SRC_RDY : out std_logic;
        PCIE_CC_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- PCIE interface to send Doorbell updates
        -- =========================================================================================
        PCIE_RQ_MFB_DATA    : out std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH-1 downto 0);
        PCIE_RQ_MFB_META    : out std_logic_vector(PCIE_MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
        PCIE_RQ_MFB_SOF     : out std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_RQ_MFB_EOF     : out std_logic_vector(PCIE_MFB_REGIONS-1 downto 0);
        PCIE_RQ_MFB_SOF_POS : out std_logic_vector(PCIE_MFB_REGIONS*max(1, log2(PCIE_MFB_REGION_SIZE))-1 downto 0);
        PCIE_RQ_MFB_EOF_POS : out std_logic_vector(PCIE_MFB_REGIONS*log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_RQ_MFB_SRC_RDY : out std_logic;
        PCIE_RQ_MFB_DST_RDY : in  std_logic);

end entity;

architecture FULL of DMA_IUVENTUS is
    constant USR_MFB_LENGTH : natural := USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH;
    constant CHANNELS       : natural := 2;

    constant PCIE_TRANS_SIZE_MAX : natural := 2**12;
    -- The maximum value that is allowed for a 2-channel PCIE_TRANS_BUFFER using only a single BRAM
    -- array
    constant POINTER_WIDTH  : natural := 18;

    constant UPDATE_DELAY : positive := 2**8;

    -- Width of a Queue Identifier value (0 to NUM_QUEUES-1).
    constant QID_W : natural := maximum(1, log2(NUM_QUEUES));

    package iuventus_mfb_meta_pkg_i is new work.iuventus_mfb_meta_pkg
    generic map (
        MFB_REGION_SIZE => PCIE_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH);

    use iuventus_mfb_meta_pkg_i.all;

    -- =============================================================================================
    -- MI synchronizer followed by the splitter
    -- =============================================================================================
    signal mi_sync_dwr  : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_sync_addr : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_sync_be   : std_logic_vector(MI_WIDTH/8 -1 downto 0);
    signal mi_sync_rd   : std_logic;
    signal mi_sync_wr   : std_logic;
    signal mi_sync_drd  : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_sync_ardy : std_logic;
    signal mi_sync_drdy : std_logic;

    constant MI_SPLIT_PORTS : natural := 2;
    constant MI_SPLIT_BASES : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH-1 downto 0) := (
        0 => x"00000000", -- SW Manager with DataLogger
        1 => x"00002000"); -- CQ Speed meter
    constant MI_SPLIT_ADDR_MASK : std_logic_vector(MI_WIDTH-1 downto 0) := x"00002000";

    signal mi_split_dwr  : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_addr : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_be   : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH/8 -1 downto 0);
    signal mi_split_rd   : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_wr   : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_drd  : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_ardy : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_drdy : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);

    -- =============================================================================================
    -- Status interface
    -- =============================================================================================
    signal mex_pcie_rd_req_incrs    : slv_array_t(3 downto 0)(PCIE_MFB_REGIONS -1 downto 0);
    signal mex_pcie_rd_req_bytes    : slv_array_t(3 downto 0)(log2(PCIE_TRANS_SIZE_MAX+1) downto 0);
    signal mex_pcie_wr_req_incrs    : slv_array_t(3 downto 0)(PCIE_MFB_REGIONS -1 downto 0);
    signal mex_pcie_wr_req_bytes    : slv_array_t(3 downto 0)(log2(PCIE_TRANS_SIZE_MAX+1) -1 downto 0);

    signal mex_pcie_rd_req_total_incr   : std_logic_vector(PCIE_MFB_REGIONS -1 downto 0);
    signal mex_pcie_rd_req_total_bytes  : std_logic_vector(log2(PCIE_TRANS_SIZE_MAX+1) downto 0);
    signal mex_pcie_wr_req_total_incr   : std_logic_vector(PCIE_MFB_REGIONS -1 downto 0);
    signal mex_pcie_wr_req_total_bytes  : std_logic_vector(log2(PCIE_TRANS_SIZE_MAX+1) -1 downto 0);

    signal dup_cqhdbl_reg_upd_disp : std_logic;
    signal dup_sqtdbl_reg_upd_disp : std_logic;

    signal cqp_sqhdbl      : std_logic_vector(15 downto 0);
    signal cqp_cqhdbl      : std_logic_vector(15 downto 0);
    signal cqp_last_cqe    : std_logic_vector(CQ_ENTRY_RANGE);
    signal cqp_status_upd  : std_logic;
    -- Queue Identifier of the completion reported alongside cqp_last_cqe/cqp_status_upd. Always
    -- "0" at NUM_QUEUES=1 -- see CQE_PROCESSOR.
    signal cqp_cqe_qid     : std_logic_vector(QID_W -1 downto 0);

    signal disp_cmd_id     : std_logic_vector(15 downto 0);
    signal disp_cmd_id_vld : std_logic;

    -- Queue Identifier of the command currently being dispatched (op_ctrl -> c2n_controller ->
    -- nvme_cmd_dispatcher). Always "0" at NUM_QUEUES=1. Also reused (unchanged) as the read
    -- address for NVME_SW_MANAGER's per-queue LBA_SPACE_SIZE/LBA_NUM_MASK OOR-check read port
    -- (op_ctrl's own C2N_QID/qid_reg -- see LBA_CHECK_QID below).
    signal opc_c2n_qid     : std_logic_vector(QID_W -1 downto 0);
    -- Queue Identifier that c2n_sqtdbl_data/c2n_sqes_disp_incr apply to (mirrors opc_c2n_qid at
    -- the dispatch commit cycle). Always "0" at NUM_QUEUES=1. Also reused (unchanged) as the read
    -- address for NVME_SW_MANAGER's per-queue DBL_MASK/NAMESPACE_ID/LBA_SPACE_SIZE/LBA_NUM_MASK
    -- "C2N" (dispatcher) read ports.
    signal c2n_sqtdbl_qid  : std_logic_vector(QID_W -1 downto 0);
    -- Queue whose DBL_MASK CQE_PROCESSOR needs THIS cycle to interpret its CQ read response
    -- (mirrors resp_qidx, undelayed -- unlike cqp_cqe_qid, which N2C_CONTROLLER registers).
    signal n2c_dbl_mask_rd_qid : std_logic_vector(QID_W -1 downto 0);

    -- ============================================================================================
    -- Software management interface
    -- ============================================================================================
    signal swm_rdbuff_baddr         : std_logic_vector(63 downto 0);
    signal swm_rdbuff_prp_list_ptr  : std_logic_vector(63 downto 0);
    signal swm_wrbuff_baddr         : std_logic_vector(63 downto 0);
    signal swm_wrbuff_prp_list_ptr  : std_logic_vector(63 downto 0);

    -- Per-queue configuration, resolved by NVME_SW_MANAGER's per-queue NP_LUTRAM to a plain
    -- scalar per physical reader (op_ctrl's own admission-time OOR check ["OPC"], and
    -- NVME_CMD_DISPATCHER's dispatch-time use ["C2N"]) -- see NVME_SW_MANAGER's own port comments.
    signal swm_lba_space_size_opc : std_logic_vector(63 downto 0);
    signal swm_lba_num_mask_opc   : std_logic_vector(15 downto 0);
    signal swm_dbl_mask_c2n       : std_logic_vector(15 downto 0);
    signal swm_namespace_id_c2n   : std_logic_vector(31 downto 0);
    signal swm_lba_space_size_c2n : std_logic_vector(63 downto 0);
    signal swm_lba_num_mask_c2n   : std_logic_vector(15 downto 0);
    signal swm_dbl_mask_n2c       : std_logic_vector(15 downto 0);
    -- COMMON: a single shared metadata pointer for every queue.
    signal swm_metadata_ptr   : std_logic_vector(63 downto 0);

    -- One bit per doorbell (0..NUM_QUEUES-1 = CQHDBL[q], NUM_QUEUES..2*NUM_QUEUES-1 = SQTDBL[q]) --
    -- see NVME_SW_MANAGER's/DBL_UPDATER's own DBL_ENABLED port comment.
    signal swm_dbl_enabled : std_logic_vector(2*NUM_QUEUES -1 downto 0);
    -- Dispatch-side base-address lookup, one queue at a time per MFB region -- see DBL_UPDATER's
    -- own port comment.
    signal dup_cqhdbl_baddr_rd_qid  : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(QID_W -1 downto 0);
    signal dup_cqhdbl_baddr_rd_data : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(63 downto 0);
    signal dup_sqtdbl_baddr_rd_qid  : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(QID_W -1 downto 0);
    signal dup_sqtdbl_baddr_rd_data : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(63 downto 0);

    -- =============================================================================================
    -- Write-request QID (parsed out of the widened WR_MFB_META -- see the entity port comment)
    -- =============================================================================================
    -- The LBA-pointer portion of WR_MFB_META, at the same low-bit position/width as before.
    signal wr_mfb_meta_lba_ptr : std_logic_vector(USR_MFB_REGIONS*SQE_LBA_PTR_W -1 downto 0);
    -- The Queue Identifier this write request targets, appended at the high end of WR_MFB_META.
    signal wr_mfb_meta_qid     : std_logic_vector(QID_W -1 downto 0);

    -- =============================================================================================
    -- PCIe Header interface from Metadata Extractor
    -- =============================================================================================
    signal pcie_hdr_addr     : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(META_PCIE_ADDR_W -1 downto 0);
    signal pcie_hdr_data_raw : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);
    signal pcie_hdr_byte_cnt : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(META_BYTE_CNT_W -1 downto 0);
    signal pcie_hdr_bar_id   : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(META_BAR_ID_W -1 downto 0);
    signal pcie_hdr_vld      : std_logic_vector(PCIE_MFB_REGIONS -1 downto 0);
    signal pcie_hdr_src_rdy  : std_logic;
    signal pcie_hdr_dst_rdy  : std_logic;

    -- =============================================================================================
    -- MFB data interface from Metadata Extractor
    -- =============================================================================================
    signal meta_ext_mfb_data        : std_logic_vector(PCIE_CQ_MFB_DATA'range);
    signal meta_ext_mfb_meta        : slv_array_t(PCIE_MFB_REGIONS -1 downto 0)(META_BE_W + META_BAR_ID_W + META_PCIE_ADDR_W -1 downto 0);
    signal meta_ext_mfb_sof         : std_logic_vector(PCIE_CQ_MFB_SOF'range);
    signal meta_ext_mfb_eof         : std_logic_vector(PCIE_CQ_MFB_EOF'range);
    signal meta_ext_mfb_sof_pos     : std_logic_vector(PCIE_CQ_MFB_SOF_POS'range);
    signal meta_ext_mfb_eof_pos     : std_logic_vector(PCIE_CQ_MFB_EOF_POS'range);
    signal meta_ext_mfb_src_rdy     : std_logic;
    signal meta_ext_mfb_dst_rdy     : std_logic;

    -- =============================================================================================
    -- Operation control
    -- =============================================================================================
    -- One bit wider than POINTER_WIDTH: the buffer is flat-addressed (MEM_PARTITIONING =>
    -- FALSE), so this address alone must reach the whole flat space (WRBUFF at pages 1+).
    signal opc_wrbuff_rd_req_addr : std_logic_vector(POINTER_WIDTH downto 0);
    signal opc_wrbuff_rd_req_size : std_logic_vector(POINTER_WIDTH downto 0);
    signal opc_wrbuff_rd_req_last : std_logic;
    signal opc_wrbuff_rd_req_en   : std_logic;
    signal opc_wrbuff_rd_req_ack  : std_logic;
    signal opc_wrbuff_rd_req_fns  : std_logic;

    signal opc_trigg_disp    : std_logic;
    signal opc_rdy_for_disp  : std_logic;
    signal opc_cmd_opcode    : std_logic_vector(CMD_OPCODE_W -1 downto 0);
    signal opc_prp_entry_1   : std_logic_vector(63 downto 0);
    signal opc_prp_entry_2   : std_logic_vector(63 downto 0);
    signal opc_start_lba_ptr : std_logic_vector(63 downto 0);
    signal opc_lba_num       : std_logic_vector(15 downto 0);

    -- signal opc_nvme_wr_req_lba_ptr   : std_logic_vector(63 downto 0);
    -- signal opc_nvme_wr_req_start     : std_logic;
    -- signal opc_nvme_wr_req_frame_lng : std_logic_vector(POINTER_WIDTH downto 0);
    -- signal opc_nvme_wr_req_end       : std_logic;

    -- =============================================================================================
    -- Card to NVMe controller interface signals
    -- =============================================================================================
    signal c2n_sqtdbl_data        : std_logic_vector(15 downto 0);
    signal c2n_tag_fifo_status    : std_logic_vector(11 downto 0);
    signal c2n_tag_init_done      : std_logic;

    signal c2n_sqes_disp_type : std_logic_vector(CMD_OPCODE_W -1 downto 0);
    signal c2n_sqes_disp_incr : std_logic;
    signal c2n_sqes_disp_bytes : std_logic_vector(24 downto 0);

    signal c2n_buff_disp_rds_chan : std_logic;
    signal c2n_buff_disp_rds_incr : std_logic;
    signal c2n_buff_disp_rds_bytes : std_logic_vector(13-1 downto 0);

    -- =============================================================================================
    -- NVMe to Card controller interface signals
    -- =============================================================================================
    signal n2c_buff_usr_rds_incr  : std_logic;
    signal n2c_buff_usr_rds_bytes : std_logic_vector(POINTER_WIDTH downto 0);

    -- =============================================================================================
    -- Miscellaneous signals
    -- =============================================================================================
    signal user_rst : std_logic;
    signal cmd_disp_rst : std_logic;

    -- =============================================================================================
    -- Start/stop signals
    -- =============================================================================================
    signal opc_start_req_vld   : std_logic;
    signal opc_start_req_ack   : std_logic;
    signal cqp_start_req_vld   : std_logic;
    signal cqp_start_req_ack   : std_logic;
    signal opc_stop_req_vld    : std_logic;
    signal opc_stop_req_ack    : std_logic;
    signal cqp_stop_req_vld    : std_logic;
    signal cqp_stop_req_ack    : std_logic;

    signal in_packet_state_reg  : std_logic;
    signal in_packet_state_next : std_logic;

    -- =============================================================================================
    -- MFB Dropper output
    -- =============================================================================================
    signal inp_mfb_src_rdy : std_logic;
    signal inp_mfb_dst_rdy : std_logic;

    -- =============================================================================================
    -- Frame length meter
    -- =============================================================================================
    signal fr_lng_mfb_data    : std_logic_vector(USR_MFB_LENGTH -1 downto 0);
    signal fr_lng_mfb_meta    : std_logic_vector(USR_MFB_REGIONS*SQE_LBA_PTR_W -1 downto 0);
    signal fr_lng_mfb_sof     : std_logic_vector(USR_MFB_REGIONS -1 downto 0);
    signal fr_lng_mfb_eof     : std_logic_vector(USR_MFB_REGIONS -1 downto 0);
    signal fr_lng_mfb_sof_pos : std_logic_vector(USR_MFB_REGIONS*maximum(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0);
    signal fr_lng_mfb_eof_pos : std_logic_vector(USR_MFB_REGIONS*log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE) -1 downto 0);
    signal fr_lng_mfb_src_rdy : std_logic;
    signal fr_lng_mfb_dst_rdy : std_logic;

    signal wr_frame_tmp_lng   : std_logic_vector(USR_MFB_REGIONS*(POINTER_WIDTH+1) -1 downto 0);
    signal wr_frame_lng       : std_logic_vector(USR_MFB_REGIONS*(POINTER_WIDTH+1) -1 downto 0);
    signal wr_frame_lng_sel   : std_logic_vector(USR_MFB_REGIONS*(POINTER_WIDTH+1) -1 downto 0);
    signal wr_frame_lng_vld   : std_logic;
    signal ovs_force_drp_next : std_logic;
    signal ovs_force_drp_reg  : std_logic;
    signal ovs_mfb_eof        : std_logic_vector(USR_MFB_REGIONS -1 downto 0);
    signal opc_wr_mfb_dst_rdy : std_logic;
    -- Page (within RDBUFF) reserved for the write currently in flight; becomes the WR_REQ_MFB_META
    -- fed to the C2N controller's write-data path. One bit wider than POINTER_WIDTH: the buffer is
    -- flat-addressed (MEM_PARTITIONING => FALSE), so this address alone must reach the whole flat
    -- space (RDBUFF at pages 1+).
    signal opc_wr_buff_page_addr : std_logic_vector(POINTER_WIDTH downto 0);

    -- =============================================================================================
    -- Otput pipe interfaces
    -- =============================================================================================
    signal rd_mfb_data_piped      : std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH -1 downto 0);
    signal rd_mfb_sof_piped       : std_logic_vector(USR_MFB_REGIONS -1 downto 0);
    signal rd_mfb_eof_piped       : std_logic_vector(USR_MFB_REGIONS -1 downto 0);
    signal rd_mfb_sof_pos_piped   : std_logic_vector(USR_MFB_REGIONS*maximum(1, log2(USR_MFB_REGION_SIZE)) -1 downto 0);
    signal rd_mfb_eof_pos_piped   : std_logic_vector(USR_MFB_REGIONS*log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE) -1 downto 0);
    signal rd_mfb_src_rdy_piped   : std_logic;
    signal rd_mfb_dst_rdy_piped   : std_logic;

    signal pcie_rq_mfb_data_piped      : std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_rq_mfb_meta_piped      : std_logic_vector(PCIE_MFB_REGIONS*PCIE_RQ_META_WIDTH                                           -1 downto 0);
    signal pcie_rq_mfb_sof_piped       : std_logic_vector(PCIE_MFB_REGIONS                                                              -1 downto 0);
    signal pcie_rq_mfb_eof_piped       : std_logic_vector(PCIE_MFB_REGIONS                                                              -1 downto 0);
    signal pcie_rq_mfb_sof_pos_piped   : std_logic_vector(PCIE_MFB_REGIONS*max(1,log2(PCIE_MFB_REGION_SIZE))                            -1 downto 0);
    signal pcie_rq_mfb_eof_pos_piped   : std_logic_vector(PCIE_MFB_REGIONS*max(1,log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE))        -1 downto 0);
    signal pcie_rq_mfb_src_rdy_piped   : std_logic;
    signal pcie_rq_mfb_dst_rdy_piped   : std_logic;

    signal pcie_cq_mfb_data_piped      : std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_cq_mfb_meta_piped      : std_logic_vector(PCIE_MFB_REGIONS*PCIE_CQ_META_WIDTH                                           -1 downto 0);
    signal pcie_cq_mfb_sof_piped       : std_logic_vector(PCIE_MFB_REGIONS                                                              -1 downto 0);
    signal pcie_cq_mfb_eof_piped       : std_logic_vector(PCIE_MFB_REGIONS                                                              -1 downto 0);
    signal pcie_cq_mfb_sof_pos_piped   : std_logic_vector(PCIE_MFB_REGIONS*max(1,log2(PCIE_MFB_REGION_SIZE))                            -1 downto 0);
    signal pcie_cq_mfb_eof_pos_piped   : std_logic_vector(PCIE_MFB_REGIONS*max(1,log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE))        -1 downto 0);
    signal pcie_cq_mfb_src_rdy_piped   : std_logic;
    signal pcie_cq_mfb_dst_rdy_piped   : std_logic;

    signal pcie_cc_mfb_data_piped      : std_logic_vector(PCIE_MFB_REGIONS*PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE*PCIE_MFB_ITEM_WIDTH -1 downto 0);
    signal pcie_cc_mfb_meta_piped      : std_logic_vector(PCIE_MFB_REGIONS*PCIE_CC_META_WIDTH                                           -1 downto 0);
    signal pcie_cc_mfb_sof_piped       : std_logic_vector(PCIE_MFB_REGIONS                                                              -1 downto 0);
    signal pcie_cc_mfb_eof_piped       : std_logic_vector(PCIE_MFB_REGIONS                                                              -1 downto 0);
    signal pcie_cc_mfb_sof_pos_piped   : std_logic_vector(PCIE_MFB_REGIONS*max(1,log2(PCIE_MFB_REGION_SIZE))                            -1 downto 0);
    signal pcie_cc_mfb_eof_pos_piped   : std_logic_vector(PCIE_MFB_REGIONS*max(1,log2(PCIE_MFB_REGION_SIZE*PCIE_MFB_BLOCK_SIZE))        -1 downto 0);
    signal pcie_cc_mfb_src_rdy_piped   : std_logic;
    signal pcie_cc_mfb_dst_rdy_piped   : std_logic;

    -- =============================================================================================
    -- Initialize debug probes
    -- =============================================================================================
    -- attribute mark_debug : string;

    -- attribute mark_debug of PCIE_RQ_MFB_DATA    : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_META    : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_SOF     : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_EOF     : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_SOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_EOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_SRC_RDY : signal is "true";
    -- attribute mark_debug of PCIE_RQ_MFB_DST_RDY : signal is "true";

    -- attribute mark_debug of PCIE_CQ_MFB_DATA    : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_META    : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_SOF     : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_EOF     : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_SOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_EOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_SRC_RDY : signal is "true";
    -- attribute mark_debug of PCIE_CQ_MFB_DST_RDY : signal is "true";

    -- attribute mark_debug of PCIE_CC_MFB_DATA    : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_META    : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_SOF     : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_EOF     : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_SOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_EOF_POS : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_SRC_RDY : signal is "true";
    -- attribute mark_debug of PCIE_CC_MFB_DST_RDY : signal is "true";

    -- attribute mark_debug of sqhdbl_data    : signal is "true";
    -- attribute mark_debug of cqhdbl_data    : signal is "true";
    -- attribute mark_debug of last_cq_entry  : signal is "true";
    -- attribute mark_debug of status_upd_vld : signal is "true";
begin
    -- =============================================================================================
    -- Parse the Queue Identifier out of the widened WR_MFB_META (see the entity port comment).
    -- Assumes USR_MFB_REGIONS = 1, as already assumed by the direct WR_MFB_META->LBA_PTR wiring
    -- this replaces (and by the OP_CTRL/C2N_CONTROLLER instances downstream).
    -- =============================================================================================
    wr_mfb_meta_lba_ptr <= WR_MFB_META(SQE_LBA_PTR_W -1 downto 0);
    wr_mfb_meta_qid     <= WR_MFB_META(SQE_LBA_PTR_W + QID_W -1 downto SQE_LBA_PTR_W);

    -- =============================================================================================
    -- MI Access logic
    -- =============================================================================================
    mi_async_g : if (not MI_SAME_CLK) generate
        mi_async_i : entity work.MI_ASYNC
            generic map(
                ADDR_WIDTH  => MI_WIDTH,
                DATA_WIDTH  => MI_WIDTH,
                META_WIDTH  => 0,
                RAM_TYPE    => "LUT",
                RESET_LOGIC => TRUE,
                DEVICE      => DEVICE
                )
            port map(
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

                CLK_S     => CLK,
                RESET_S   => RST,
                MI_S_ADDR => mi_sync_addr,
                MI_S_DWR  => mi_sync_dwr,
                MI_S_MWR  => open,
                MI_S_BE   => mi_sync_be,
                MI_S_RD   => mi_sync_rd,
                MI_S_WR   => mi_sync_wr,
                MI_S_ARDY => mi_sync_ardy,
                MI_S_DRDY => mi_sync_drdy,
                MI_S_DRD  => mi_sync_drd);
    else generate
        mi_sync_addr <= MI_ADDR;
        mi_sync_dwr  <= MI_DWR;
        mi_sync_be   <= MI_BE;
        mi_sync_rd   <= MI_RD;
        mi_sync_wr   <= MI_WR;
        MI_ARDY      <= mi_sync_ardy;
        MI_DRDY      <= mi_sync_drdy;
        MI_DRD       <= mi_sync_drd;
    end generate;

    mi_splitter_i : entity work.MI_SPLITTER_PLUS_GEN
        generic map (
            ADDR_WIDTH => MI_WIDTH,
            DATA_WIDTH => MI_WIDTH,
            META_WIDTH => 0,
            PORTS      => MI_SPLIT_PORTS,
            PIPE_OUT   => (others => FALSE),

            ADDR_BASES => MI_SPLIT_PORTS,
            ADDR_BASE  => MI_SPLIT_BASES,
            ADDR_MASK  => MI_SPLIT_ADDR_MASK,

            DEVICE => DEVICE)
        port map (
            CLK   => CLK,
            RESET => RST,

            RX_DWR  => mi_sync_dwr,
            RX_MWR  => (others => '0'),
            RX_ADDR => mi_sync_addr,
            RX_BE   => mi_sync_be,
            RX_RD   => mi_sync_rd,
            RX_WR   => mi_sync_wr,
            RX_ARDY => mi_sync_ardy,
            RX_DRD  => mi_sync_drd,
            RX_DRDY => mi_sync_drdy,

            TX_DWR  => mi_split_dwr,
            TX_MWR  => open,
            TX_ADDR => mi_split_addr,
            TX_BE   => mi_split_be,
            TX_RD   => mi_split_rd,
            TX_WR   => mi_split_wr,
            TX_ARDY => mi_split_ardy,
            TX_DRD  => mi_split_drd,
            TX_DRDY => mi_split_drdy);

    -- =============================================================================================
    -- Software access
    -- =============================================================================================
    nvme_sw_manager_i : entity work.NVME_SW_MANAGER
    generic map (
        MI_WIDTH     => MI_WIDTH,
        DEVICE       => DEVICE,
        MPS          => PCIE_TRANS_SIZE_MAX,
        MRRS         => PCIE_TRANS_SIZE_MAX,
        -- Matches the WRBUFF drain packet size cap (2**POINTER_WIDTH, the buffer's per-channel
        -- span), so N2C_BUFF_USR_RDS_BYTES is wide enough for n2c_buff_usr_rds_bytes.
        PKT_SIZE_MAX => 2**POINTER_WIDTH,
        MFB_REGIONS  => PCIE_MFB_REGIONS,
        NUM_QUEUES   => NUM_QUEUES)
    port map (
        CLK      => CLK,
        RST      => RST,
        USER_RST => user_rst,

        MI_DWR  => mi_split_dwr(0),
        MI_ADDR => mi_split_addr(0),
        MI_BE   => mi_split_be(0),
        MI_RD   => mi_split_rd(0),
        MI_WR   => mi_split_wr(0),
        MI_ARDY => mi_split_ardy(0),
        MI_DRD  => mi_split_drd(0),
        MI_DRDY => mi_split_drdy(0),

        PCIE_RD_REQ_INCRS => mex_pcie_rd_req_incrs,
        PCIE_RD_REQ_BYTES => mex_pcie_rd_req_bytes,
        PCIE_WR_REQ_INCRS => mex_pcie_wr_req_incrs,
        PCIE_WR_REQ_BYTES => mex_pcie_wr_req_bytes,

        PCIE_RD_REQ_TOTAL_INCR  => mex_pcie_rd_req_total_incr,
        PCIE_RD_REQ_TOTAL_BYTES => mex_pcie_rd_req_total_bytes,
        PCIE_WR_REQ_TOTAL_INCR  => mex_pcie_wr_req_total_incr,
        PCIE_WR_REQ_TOTAL_BYTES => mex_pcie_wr_req_total_bytes,

        -- Does not need channel selection since the read is only relevant for Write buffer
        N2C_BUFF_USR_RDS_INCR  => n2c_buff_usr_rds_incr,
        N2C_BUFF_USR_RDS_BYTES => n2c_buff_usr_rds_bytes,

        C2N_BUFF_DISP_RDS_CHAN  => c2n_buff_disp_rds_chan,
        C2N_BUFF_DISP_RDS_INCR  => c2n_buff_disp_rds_incr,
        C2N_BUFF_DISP_RDS_BYTES => c2n_buff_disp_rds_bytes,

        RDBUFF_BADDR         => swm_rdbuff_baddr,
        RDBUFF_PRP_LIST_PTR  => swm_rdbuff_prp_list_ptr,
        WRBUFF_BADDR         => swm_wrbuff_baddr,
        WRBUFF_PRP_LIST_PTR  => swm_wrbuff_prp_list_ptr,

        LBA_CHECK_QID      => opc_c2n_qid,
        LBA_SPACE_SIZE_OPC => swm_lba_space_size_opc,
        LBA_NUM_MASK_OPC   => swm_lba_num_mask_opc,

        SQTDBL_DATA     => c2n_sqtdbl_data,
        SQTDBL_QID      => c2n_sqtdbl_qid,
        TAG_FIFO_STATUS => c2n_tag_fifo_status,
        TAG_INIT_DONE   => c2n_tag_init_done,

        DBL_MASK_C2N       => swm_dbl_mask_c2n,
        NAMESPACE_ID_C2N   => swm_namespace_id_c2n,
        LBA_SPACE_SIZE_C2N => swm_lba_space_size_c2n,
        LBA_NUM_MASK_C2N   => swm_lba_num_mask_c2n,
        METADATA_PTR       => swm_metadata_ptr,

        SQES_DISP_TYPE  => c2n_sqes_disp_type,
        SQES_DISP_INCR  => c2n_sqes_disp_incr,
        SQES_DISP_BYTES => c2n_sqes_disp_bytes,

        SQHDBL_DATA    => cqp_sqhdbl,
        CQHDBL_DATA    => cqp_cqhdbl,
        CQHDBL_QID     => cqp_cqe_qid,
        LAST_CQ_ENTRY  => cqp_last_cqe,
        STATUS_UPD_VLD => cqp_status_upd,

        DBL_MASK_RD_QID => n2c_dbl_mask_rd_qid,
        DBL_MASK_N2C    => swm_dbl_mask_n2c,

        DBL_ENABLED => swm_dbl_enabled,

        CQHDBL_BADDR_RD_QID  => dup_cqhdbl_baddr_rd_qid,
        CQHDBL_BADDR_RD_DATA => dup_cqhdbl_baddr_rd_data,
        SQTDBL_BADDR_RD_QID  => dup_sqtdbl_baddr_rd_qid,
        SQTDBL_BADDR_RD_DATA => dup_sqtdbl_baddr_rd_data,

        CQHDBL_REG_UPD_DISP  => dup_cqhdbl_reg_upd_disp,
        SQTDBL_REG_UPD_DISP  => dup_sqtdbl_reg_upd_disp,

        OPC_TRIGG_DISP  => opc_trigg_disp,

        OPC_START_REQ_VLD => opc_start_req_vld,
        OPC_START_REQ_ACK => opc_start_req_ack,
        CQP_START_REQ_VLD => cqp_start_req_vld,
        CQP_START_REQ_ACK => cqp_start_req_ack,

        OPC_STOP_REQ_VLD => opc_stop_req_vld,
        OPC_STOP_REQ_ACK => opc_stop_req_ack,
        CQP_STOP_REQ_VLD => cqp_stop_req_vld,
        CQP_STOP_REQ_ACK => cqp_stop_req_ack
    );

    operation_control_i : entity work.OP_CTRL
    generic map (
        BUFF_PTR_WIDTH         => POINTER_WIDTH,
        QUEUE_DEPTH            => QUEUE_DEPTH,
        NUM_QUEUES             => NUM_QUEUES,
        FLUSH_DELAY_CNTR_WIDTH => FLUSH_DELAY_CNTR_WIDTH)
    port map (
        CLK => CLK,
        RST => RST or user_rst,
        CMD_DISP_RST => cmd_disp_rst,

        START_REQ_VLD => opc_start_req_vld,
        START_REQ_ACK => opc_start_req_ack,
        STOP_REQ_VLD  => opc_stop_req_vld,
        STOP_REQ_ACK  => opc_stop_req_ack,

        LBA_NUM_MASK        => swm_lba_num_mask_opc,
        LBA_SPACE_SIZE      => swm_lba_space_size_opc,
        RDBUFF_BADDR        => swm_rdbuff_baddr,
        RDBUFF_PRP_LIST_PTR => swm_rdbuff_prp_list_ptr,
        WRBUFF_BADDR        => swm_wrbuff_baddr,
        WRBUFF_PRP_LIST_PTR => swm_wrbuff_prp_list_ptr,

        NVME_RD_REQ_LBA_NUM => NVME_RD_REQ_LBA_NUM,
        NVME_RD_REQ_LBA_PTR => NVME_RD_REQ_LBA_PTR,
        NVME_RD_REQ_QID     => NVME_RD_REQ_QID,
        NVME_RD_REQ_VLD     => NVME_RD_REQ_VLD,
        NVME_RD_REQ_RDY     => NVME_RD_REQ_RDY,

        OP_STAT_TYPE => OP_STAT_TYPE,
        OP_STAT_CODE => OP_STAT_CODE,
        OP_STAT_VLD  => OP_STAT_VLD,

        WRBUFF_RD_REQ_ADDR => opc_wrbuff_rd_req_addr,
        WRBUFF_RD_REQ_SIZE => opc_wrbuff_rd_req_size,
        WRBUFF_RD_REQ_LAST => opc_wrbuff_rd_req_last,
        WRBUFF_RD_REQ_EN   => opc_wrbuff_rd_req_en,
        WRBUFF_RD_REQ_ACK  => opc_wrbuff_rd_req_ack,
        WRBUFF_RD_REQ_FNS  => opc_wrbuff_rd_req_fns,

        CQP_CQE_SC_TYPE   => cqp_last_cqe(CQ_ENTRY_SC_TYPE),
        CQP_CQE_STAT_CODE => cqp_last_cqe(CQ_ENTRY_STAT_CODE),
        CQP_CQE_VLD       => cqp_status_upd,
        CQP_CQE_CID       => cqp_last_cqe(CQ_ENTRY_CMD_ID),
        CQP_CQE_QID       => cqp_cqe_qid,

        DISP_CMD_ID     => disp_cmd_id,
        DISP_CMD_ID_VLD => disp_cmd_id_vld,

        C2N_TRIGG_DISP    => opc_trigg_disp,
        C2N_RDY_FOR_DISP  => opc_rdy_for_disp,
        C2N_CMD_OPCODE    => opc_cmd_opcode,
        C2N_PRP_ENTRY_1   => opc_prp_entry_1,
        C2N_PRP_ENTRY_2   => opc_prp_entry_2,
        C2N_START_LBA_PTR => opc_start_lba_ptr,
        C2N_LBA_NUM       => opc_lba_num,
        C2N_QID           => opc_c2n_qid,

        NVME_WR_REQ_LBA_PTR         => wr_mfb_meta_lba_ptr,
        NVME_WR_REQ_QID             => wr_mfb_meta_qid,
        NVME_WR_REQ_START           => WR_MFB_SOF(0) and WR_MFB_SRC_RDY,
        NVME_WR_REQ_END             => WR_MFB_EOF(0) and WR_MFB_SRC_RDY and inp_mfb_dst_rdy,
        NVME_WR_REQ_FRAME_LNG       => wr_frame_lng_sel,
        NVME_WR_REQ_FRAME_LNG_VLD   => wr_frame_lng_vld,
        WR_MFB_DST_RDY              => opc_wr_mfb_dst_rdy,

        WR_BUFF_PAGE_ADDR           => opc_wr_buff_page_addr
    );

    -- =============================================================================================
    --  mmmmm                    #                         m    #
    --  #   "#  mmm    mmm    mmm#         mmmm    mmm   mm#mm  # mm
    --  #mmmm" #"  #  "   #  #" "#         #" "#  "   #    #    #"  #
    --  #   "m #""""  m"""#  #   #         #   #  m"""#    #    #   #
    --  #    " "#mm"  "mm"#  "#m##         ##m#"  "mm"#    "mm  #   #
    --                                     #
    --                                     "
    -- =============================================================================================
    nvme_cq_meta_ext_i : entity work.NVME_CQ_META_EXTRACTOR
        generic map (
            DEVICE          => DEVICE,
            MFB_REGIONS     => PCIE_MFB_REGIONS,
            MFB_REGION_SIZE => PCIE_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,
            POINTER_WIDTH   => POINTER_WIDTH,
            NUM_QUEUES      => NUM_QUEUES)
        port map (
            CLK   => CLK,
            RESET => RST or user_rst,

            PCIE_MFB_DATA    => pcie_cq_mfb_data_piped,
            PCIE_MFB_META    => pcie_cq_mfb_meta_piped,
            PCIE_MFB_SOF     => pcie_cq_mfb_sof_piped,
            PCIE_MFB_EOF     => pcie_cq_mfb_eof_piped,
            PCIE_MFB_SOF_POS => pcie_cq_mfb_sof_pos_piped,
            PCIE_MFB_EOF_POS => pcie_cq_mfb_eof_pos_piped,
            PCIE_MFB_SRC_RDY => pcie_cq_mfb_src_rdy_piped,
            PCIE_MFB_DST_RDY => pcie_cq_mfb_dst_rdy_piped,

            MVB_DATA_BAR_ID   => pcie_hdr_bar_id,
            MVB_DATA_ADDR     => pcie_hdr_addr,
            MVB_DATA_CQ_HDR   => pcie_hdr_data_raw,
            MVB_DATA_BYTE_CNT => pcie_hdr_byte_cnt,
            MVB_VLD           => pcie_hdr_vld,
            MVB_SRC_RDY       => pcie_hdr_src_rdy,
            MVB_DST_RDY       => pcie_hdr_dst_rdy,

            PCIE_RD_REQ_INCRS => mex_pcie_rd_req_incrs,
            PCIE_RD_REQ_BYTES => mex_pcie_rd_req_bytes,
            PCIE_WR_REQ_INCRS => mex_pcie_wr_req_incrs,
            PCIE_WR_REQ_BYTES => mex_pcie_wr_req_bytes,

            PCIE_RD_REQ_TOTAL_INCR  => mex_pcie_rd_req_total_incr,
            PCIE_RD_REQ_TOTAL_BYTES => mex_pcie_rd_req_total_bytes,
            PCIE_WR_REQ_TOTAL_INCR  => mex_pcie_wr_req_total_incr,
            PCIE_WR_REQ_TOTAL_BYTES => mex_pcie_wr_req_total_bytes,

            USR_MFB_DATA    => meta_ext_mfb_data,
            USR_MFB_META    => meta_ext_mfb_meta,
            USR_MFB_SOF     => meta_ext_mfb_sof,
            USR_MFB_EOF     => meta_ext_mfb_eof,
            USR_MFB_SOF_POS => meta_ext_mfb_sof_pos,
            USR_MFB_EOF_POS => meta_ext_mfb_eof_pos,
            USR_MFB_SRC_RDY => meta_ext_mfb_src_rdy,
            USR_MFB_DST_RDY => meta_ext_mfb_dst_rdy);

    nvme2card_ctrl_i : entity work.N2C_CONTROLLER
        generic map (
            EXT_MFB_REGIONS     => PCIE_MFB_REGIONS,
            EXT_MFB_REGION_SIZE => PCIE_MFB_REGION_SIZE,
            EXT_MFB_BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
            EXT_MFB_ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,
            EXT_MFB_META_WIDTH  => MFB_META_REDUCED_WIDTH_INT,

            USR_MFB_REGIONS     => USR_MFB_REGIONS,
            USR_MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
            USR_MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
            USR_MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

            MI_WIDTH            => MI_WIDTH,
            DEVICE              => DEVICE,
            BUFF_PTR_WIDTH      => POINTER_WIDTH,
            NUM_QUEUES          => NUM_QUEUES)
        port map (
            CLK => CLK,
            RST => RST or user_rst,

            MI_DWR  => mi_split_dwr(1),
            MI_ADDR => mi_split_addr(1),
            MI_BE   => mi_split_be(1),
            MI_RD   => mi_split_rd(1),
            MI_WR   => mi_split_wr(1),
            MI_ARDY => mi_split_ardy(1),
            MI_DRD  => mi_split_drd(1),
            MI_DRDY => mi_split_drdy(1),

            CQP_START_REQ_VLD => cqp_start_req_vld,
            CQP_START_REQ_ACK => cqp_start_req_ack,
            CQP_STOP_REQ_VLD  => cqp_stop_req_vld,
            CQP_STOP_REQ_ACK  => cqp_stop_req_ack,
            DBL_MASK          => swm_dbl_mask_n2c,
            DBL_MASK_RD_QID   => n2c_dbl_mask_rd_qid,

            BUFF_RD_REQ_ADDR       => opc_wrbuff_rd_req_addr,
            BUFF_RD_REQ_SIZE       => opc_wrbuff_rd_req_size,
            BUFF_RD_REQ_LAST       => opc_wrbuff_rd_req_last,
            BUFF_RD_REQ_EN         => opc_wrbuff_rd_req_en,
            BUFF_RD_REQ_ACK        => opc_wrbuff_rd_req_ack,

            CQP_CQHDBL             => cqp_cqhdbl,
            CQP_SQHDBL             => cqp_sqhdbl,
            CQP_LAST_CQE           => cqp_last_cqe,
            CQP_STATUS_UPD         => cqp_status_upd,
            CQP_CQE_QID            => cqp_cqe_qid,

            WRBUFF_USR_RDS_INCR      => n2c_buff_usr_rds_incr,
            WRBUFF_USR_RDS_BYTES     => n2c_buff_usr_rds_bytes,

            EXT_MFB_DATA           => meta_ext_mfb_data,
            EXT_MFB_META           => meta_ext_mfb_meta,
            EXT_MFB_SOF            => meta_ext_mfb_sof,
            EXT_MFB_EOF            => meta_ext_mfb_eof,
            EXT_MFB_SOF_POS        => meta_ext_mfb_sof_pos,
            EXT_MFB_EOF_POS        => meta_ext_mfb_eof_pos,
            EXT_MFB_SRC_RDY        => meta_ext_mfb_src_rdy,
            EXT_MFB_DST_RDY        => meta_ext_mfb_dst_rdy,

            RD_RESP_MFB_DATA       => rd_mfb_data_piped,
            RD_RESP_MFB_SOF        => rd_mfb_sof_piped,
            RD_RESP_MFB_EOF        => rd_mfb_eof_piped,
            RD_RESP_MFB_SOF_POS    => rd_mfb_sof_pos_piped,
            RD_RESP_MFB_EOF_POS    => rd_mfb_eof_pos_piped,
            RD_RESP_MFB_SRC_RDY    => rd_mfb_src_rdy_piped,
            RD_RESP_MFB_DST_RDY    => rd_mfb_dst_rdy_piped);

    opc_wrbuff_rd_req_fns <= (or RD_MFB_EOF) and RD_MFB_SRC_RDY and RD_MFB_DST_RDY;

    -- =============================================================================================
    -- m     m          "      m                                  m    #
    -- #  #  #  m mm  mmm    mm#mm   mmm          mmmm    mmm   mm#mm  # mm
    -- " #"# #  #"  "   #      #    #"  #         #" "#  "   #    #    #"  #
    --  ## ##"  #       #      #    #""""         #   #  m"""#    #    #   #
    --  #   #   #     mm#mm    "mm  "#mm"         ##m#"  "mm"#    "mm  #   #
    --                                            #
    --                                            "
    -- =============================================================================================
    inp_mfb_src_rdy <= WR_MFB_SRC_RDY and opc_wr_mfb_dst_rdy;
    WR_MFB_DST_RDY <= inp_mfb_dst_rdy and opc_wr_mfb_dst_rdy;

    in_pkt_state_reg_p : process (CLK) is
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                in_packet_state_reg <= '0';
            else
                in_packet_state_reg <= in_packet_state_next;
            end if;
        end if;
    end process;

    in_pkt_nst_logic_p : process (all) is
    begin
        in_packet_state_next <= in_packet_state_reg;

        if (WR_MFB_SOF = "1" and inp_mfb_src_rdy = '1' and inp_mfb_dst_rdy = '1') then
            in_packet_state_next <= '1';
        elsif (WR_MFB_EOF = "1" and inp_mfb_src_rdy = '1' and inp_mfb_dst_rdy = '1') then
            in_packet_state_next <= '0';
        end if;
    end process;

    mfb_frame_lng_i : entity work.MFB_FRAME_LNG
        generic map (
            REGIONS        => USR_MFB_REGIONS,
            REGION_SIZE    => USR_MFB_REGION_SIZE,
            BLOCK_SIZE     => USR_MFB_BLOCK_SIZE,
            ITEM_WIDTH     => USR_MFB_ITEM_WIDTH,
            META_WIDTH     => SQE_LBA_PTR_W,

            LNG_WIDTH      => POINTER_WIDTH+1,
            REG_BITMAP     => "111",
            SATURATION     => FALSE,
            IMPLEMENTATION => "parallel")
        port map (
            CLK          => CLK,
            RESET        => RST or user_rst,

            RX_DATA      => WR_MFB_DATA,
            -- Only the LBA-pointer portion of the (now QID-widened) WR_MFB_META; TX_META
            -- (fr_lng_mfb_meta) is unused downstream, but the port width must still match
            -- META_WIDTH => SQE_LBA_PTR_W above.
            RX_META      => wr_mfb_meta_lba_ptr,
            RX_SOF       => WR_MFB_SOF,
            RX_EOF       => WR_MFB_EOF,
            RX_SOF_POS   => WR_MFB_SOF_POS,
            RX_EOF_POS   => WR_MFB_EOF_POS,
            RX_SRC_RDY   => inp_mfb_src_rdy,
            RX_DST_RDY   => inp_mfb_dst_rdy,

            TX_COF       => open,
            TX_TEMP_LNG  => wr_frame_tmp_lng,
            TX_FRAME_LNG => wr_frame_lng,
            TX_FRAME_OVF => open,

            TX_DATA      => fr_lng_mfb_data,
            TX_META      => fr_lng_mfb_meta,
            TX_SOF_POS   => fr_lng_mfb_sof_pos,
            TX_EOF_POS   => fr_lng_mfb_eof_pos,
            TX_SOF       => fr_lng_mfb_sof,
            TX_EOF       => fr_lng_mfb_eof,
            TX_SRC_RDY   => fr_lng_mfb_src_rdy,
            TX_DST_RDY   => fr_lng_mfb_dst_rdy or ovs_force_drp_reg);

    wr_frame_lng_vld <= ovs_mfb_eof(0) and fr_lng_mfb_src_rdy and fr_lng_mfb_dst_rdy;

    ovs_force_drp_reg_p : process (CLK) is
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                ovs_force_drp_reg <= '0';
            else
                ovs_force_drp_reg <= ovs_force_drp_next;
            end if;
        end if;
    end process;

    -- drops oversized frame when its length exceeds the buffer size
    ovs_pkt_drop_p : process (all) is
    begin
        ovs_force_drp_next <= ovs_force_drp_reg;
        ovs_mfb_eof        <= fr_lng_mfb_eof;
        wr_frame_lng_sel   <= wr_frame_lng;

        if (fr_lng_mfb_src_rdy = '1' and fr_lng_mfb_dst_rdy = '1') then
            if (fr_lng_mfb_eof = "0" and unsigned(wr_frame_tmp_lng) >= to_unsigned(2**POINTER_WIDTH, POINTER_WIDTH+1)) then
                ovs_mfb_eof        <= "1";
                wr_frame_lng_sel   <= wr_frame_tmp_lng;
                ovs_force_drp_next <= '1';
            end if;

            if (fr_lng_mfb_eof = "1" and ovs_force_drp_reg = '1') then
                ovs_force_drp_next <= '0';
            end if;
        end if;
    end process;

    card2nvme_ctrl_i: entity work.C2N_CONTROLLER
        generic map (
            PCIE_MFB_REGIONS     => PCIE_MFB_REGIONS,
            PCIE_MFB_REGION_SIZE => PCIE_MFB_REGION_SIZE,
            PCIE_MFB_BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
            PCIE_MFB_ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,

            USR_MFB_REGIONS      => USR_MFB_REGIONS,
            USR_MFB_REGION_SIZE  => USR_MFB_REGION_SIZE,
            USR_MFB_BLOCK_SIZE   => USR_MFB_BLOCK_SIZE,
            USR_MFB_ITEM_WIDTH   => USR_MFB_ITEM_WIDTH,

            DEVICE               => DEVICE,
            BUFF_PTR_WIDTH       => POINTER_WIDTH,
            QUEUE_DEPTH          => QUEUE_DEPTH,
            NUM_QUEUES           => NUM_QUEUES)
        port map (
            CLK                 => CLK,
            RST                 => RST or user_rst,
            CMD_DISP_RST        => cmd_disp_rst,

            PCIE_HDR_ADDR       => pcie_hdr_addr,
            PCIE_HDR_DATA_RAW   => pcie_hdr_data_raw,
            PCIE_HDR_BYTE_CNT   => pcie_hdr_byte_cnt,
            PCIE_HDR_VLD        => pcie_hdr_vld,
            PCIE_HDR_SRC_RDY    => pcie_hdr_src_rdy,
            PCIE_HDR_DST_RDY    => pcie_hdr_dst_rdy,

            WR_REQ_MFB_DATA     => fr_lng_mfb_data,
            -- Flat byte offset of the page reserved by OP_CTRL's write-side allocator for the
            -- frame currently in flight (always the first data page, i.e. flat page 1, with the
            -- default MAX_WR_PAGES, i.e. whole-data-buffer reservation; flat page 0 is reserved
            -- for the queue).
            WR_REQ_MFB_META     => opc_wr_buff_page_addr,
            WR_REQ_MFB_SOF      => fr_lng_mfb_sof,
            WR_REQ_MFB_EOF      => ovs_mfb_eof,
            WR_REQ_MFB_SOF_POS  => fr_lng_mfb_sof_pos,
            WR_REQ_MFB_EOF_POS  => fr_lng_mfb_eof_pos,
            WR_REQ_MFB_SRC_RDY  => fr_lng_mfb_src_rdy and not ovs_force_drp_reg,
            WR_REQ_MFB_DST_RDY  => fr_lng_mfb_dst_rdy,

            TRIGG_DISP      => opc_trigg_disp,
            RDY_FOR_DISP    => opc_rdy_for_disp,
            DBL_MASK        => swm_dbl_mask_c2n,
            CMD_OPCODE      => opc_cmd_opcode,
            NAMESPACE_ID    => swm_namespace_id_c2n,
            METADATA_PTR    => swm_metadata_ptr,
            PRP_ENTRY_1     => opc_prp_entry_1,
            PRP_ENTRY_2     => opc_prp_entry_2,
            START_LBA_PTR   => opc_start_lba_ptr,
            LBA_SPACE_SIZE  => swm_lba_space_size_c2n,
            LBA_NUM         => opc_lba_num,
            LBA_NUM_MASK    => swm_lba_num_mask_c2n,
            QID             => opc_c2n_qid,

            CPL_STAT_TAG        => cqp_last_cqe(CQ_ENTRY_CMD_ID),
            CPL_STAT_SQHDBL     => cqp_sqhdbl,
            CPL_STAT_VLD        => cqp_status_upd,
            CPL_STAT_QID        => cqp_cqe_qid,

            RDBUFF_DISP_RDS_CHAN      => c2n_buff_disp_rds_chan,
            RDBUFF_DISP_RDS_BYTES     => c2n_buff_disp_rds_bytes,
            RDBUFF_DISP_RDS_INCR      => c2n_buff_disp_rds_incr,

            SQE_DISP_CNTR_TYPE  => c2n_sqes_disp_type,
            SQE_DISP_CNTR_SIZE  => c2n_sqes_disp_bytes,
            SQE_DISP_CNTR_INCR  => c2n_sqes_disp_incr,

            TAG_FIFO_STATUS     => c2n_tag_fifo_status,
            TAG_INIT_DONE       => c2n_tag_init_done,
            SQTDBL_VAL          => c2n_sqtdbl_data,
            SQTDBL_QID          => c2n_sqtdbl_qid,

            DISP_CMD_ID         => disp_cmd_id,
            DISP_CMD_ID_VLD     => disp_cmd_id_vld,

            PCIE_CC_MFB_DATA    => pcie_cc_mfb_data_piped,
            PCIE_CC_MFB_META    => pcie_cc_mfb_meta_piped,
            PCIE_CC_MFB_SOF     => pcie_cc_mfb_sof_piped,
            PCIE_CC_MFB_EOF     => pcie_cc_mfb_eof_piped,
            PCIE_CC_MFB_SOF_POS => pcie_cc_mfb_sof_pos_piped,
            PCIE_CC_MFB_EOF_POS => pcie_cc_mfb_eof_pos_piped,
            PCIE_CC_MFB_SRC_RDY => pcie_cc_mfb_src_rdy_piped,
            PCIE_CC_MFB_DST_RDY => pcie_cc_mfb_dst_rdy_piped);

    dbl_updater_i : entity work.DBL_UPDATER
        generic map (
            DEVICE          => DEVICE,
            MFB_REGIONS     => PCIE_MFB_REGIONS,
            MFB_REGION_SIZE => PCIE_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,
            UPDATE_DELAY    => UPDATE_DELAY,
            NUM_QUEUES      => NUM_QUEUES)
        port map (
            CLK => CLK,
            RST => RST or user_rst or cmd_disp_rst,

            DBL_ENABLED      => swm_dbl_enabled,

            CQHDBL_DATA      => cqp_cqhdbl,
            CQHDBL_VLD       => cqp_status_upd,
            CQHDBL_QID       => cqp_cqe_qid,

            SQTDBL_DATA      => c2n_sqtdbl_data,
            SQTDBL_VLD       => c2n_sqes_disp_incr,
            SQTDBL_QID       => c2n_sqtdbl_qid,

            CQHDBL_BADDR_RD_QID  => dup_cqhdbl_baddr_rd_qid,
            CQHDBL_BADDR_RD_DATA => dup_cqhdbl_baddr_rd_data,
            SQTDBL_BADDR_RD_QID  => dup_sqtdbl_baddr_rd_qid,
            SQTDBL_BADDR_RD_DATA => dup_sqtdbl_baddr_rd_data,

            CQHDBL_REG_UPD_DISP => dup_cqhdbl_reg_upd_disp,
            SQTDBL_REG_UPD_DISP => dup_sqtdbl_reg_upd_disp,

            PCIE_RQ_MFB_DATA    => pcie_rq_mfb_data_piped,
            PCIE_RQ_MFB_META    => pcie_rq_mfb_meta_piped,
            PCIE_RQ_MFB_SOF     => pcie_rq_mfb_sof_piped,
            PCIE_RQ_MFB_EOF     => pcie_rq_mfb_eof_piped,
            PCIE_RQ_MFB_SOF_POS => pcie_rq_mfb_sof_pos_piped,
            PCIE_RQ_MFB_EOF_POS => pcie_rq_mfb_eof_pos_piped,
            PCIE_RQ_MFB_SRC_RDY => pcie_rq_mfb_src_rdy_piped,
            PCIE_RQ_MFB_DST_RDY => pcie_rq_mfb_dst_rdy_piped);

    -- =============================================================================================
    -- Output pipes
    -- =============================================================================================

    rd_mfb_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => USR_MFB_REGIONS,
        REGION_SIZE => USR_MFB_REGION_SIZE,
        BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
        ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

        META_WIDTH  => 0,
        FAKE_PIPE   => FALSE,
        USE_DST_RDY => TRUE,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RST,

        RX_DATA    => rd_mfb_data_piped,
        RX_META    => (others => '0'),
        RX_SOF_POS => rd_mfb_sof_pos_piped,
        RX_EOF_POS => rd_mfb_eof_pos_piped,
        RX_SOF     => rd_mfb_sof_piped,
        RX_EOF     => rd_mfb_eof_piped,
        RX_SRC_RDY => rd_mfb_src_rdy_piped,
        RX_DST_RDY => rd_mfb_dst_rdy_piped,

        TX_DATA    => RD_MFB_DATA,
        TX_META    => open,
        TX_SOF_POS => RD_MFB_SOF_POS,
        TX_EOF_POS => RD_MFB_EOF_POS,
        TX_SOF     => RD_MFB_SOF,
        TX_EOF     => RD_MFB_EOF,
        TX_SRC_RDY => RD_MFB_SRC_RDY,
        TX_DST_RDY => RD_MFB_DST_RDY
    );

    pcie_rq_mfb_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => PCIE_MFB_REGIONS,
        REGION_SIZE => PCIE_MFB_REGION_SIZE,
        BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
        ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,

        META_WIDTH  => PCIE_RQ_META_WIDTH,
        FAKE_PIPE   => FALSE,
        USE_DST_RDY => TRUE,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RST,

        RX_DATA    => pcie_rq_mfb_data_piped,
        RX_META    => pcie_rq_mfb_meta_piped,
        RX_SOF_POS => pcie_rq_mfb_sof_pos_piped,
        RX_EOF_POS => pcie_rq_mfb_eof_pos_piped,
        RX_SOF     => pcie_rq_mfb_sof_piped,
        RX_EOF     => pcie_rq_mfb_eof_piped,
        RX_SRC_RDY => pcie_rq_mfb_src_rdy_piped,
        RX_DST_RDY => pcie_rq_mfb_dst_rdy_piped,

        TX_DATA    => PCIE_RQ_MFB_DATA,
        TX_META    => PCIE_RQ_MFB_META,
        TX_SOF_POS => PCIE_RQ_MFB_SOF_POS,
        TX_EOF_POS => PCIE_RQ_MFB_EOF_POS,
        TX_SOF     => PCIE_RQ_MFB_SOF,
        TX_EOF     => PCIE_RQ_MFB_EOF,
        TX_SRC_RDY => PCIE_RQ_MFB_SRC_RDY,
        TX_DST_RDY => PCIE_RQ_MFB_DST_RDY
    );

    pcie_cq_mfb_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => PCIE_MFB_REGIONS,
        REGION_SIZE => PCIE_MFB_REGION_SIZE,
        BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
        ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,

        META_WIDTH  => PCIE_CQ_META_WIDTH,
        FAKE_PIPE   => FALSE,
        USE_DST_RDY => TRUE,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RST,

        RX_DATA    => PCIE_CQ_MFB_DATA,
        RX_META    => PCIE_CQ_MFB_META,
        RX_SOF_POS => PCIE_CQ_MFB_SOF_POS,
        RX_EOF_POS => PCIE_CQ_MFB_EOF_POS,
        RX_SOF     => PCIE_CQ_MFB_SOF,
        RX_EOF     => PCIE_CQ_MFB_EOF,
        RX_SRC_RDY => PCIE_CQ_MFB_SRC_RDY,
        RX_DST_RDY => PCIE_CQ_MFB_DST_RDY,

        TX_DATA    => pcie_cq_mfb_data_piped,
        TX_META    => pcie_cq_mfb_meta_piped,
        TX_SOF_POS => pcie_cq_mfb_sof_pos_piped,
        TX_EOF_POS => pcie_cq_mfb_eof_pos_piped,
        TX_SOF     => pcie_cq_mfb_sof_piped,
        TX_EOF     => pcie_cq_mfb_eof_piped,
        TX_SRC_RDY => pcie_cq_mfb_src_rdy_piped,
        TX_DST_RDY => pcie_cq_mfb_dst_rdy_piped
    );

    pcie_cc_mfb_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => PCIE_MFB_REGIONS,
        REGION_SIZE => PCIE_MFB_REGION_SIZE,
        BLOCK_SIZE  => PCIE_MFB_BLOCK_SIZE,
        ITEM_WIDTH  => PCIE_MFB_ITEM_WIDTH,

        META_WIDTH  => PCIE_CC_META_WIDTH,
        FAKE_PIPE   => FALSE,
        USE_DST_RDY => TRUE,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RST,

        RX_DATA    => pcie_cc_mfb_data_piped,
        RX_META    => pcie_cc_mfb_meta_piped,
        RX_SOF_POS => pcie_cc_mfb_sof_pos_piped,
        RX_EOF_POS => pcie_cc_mfb_eof_pos_piped,
        RX_SOF     => pcie_cc_mfb_sof_piped,
        RX_EOF     => pcie_cc_mfb_eof_piped,
        RX_SRC_RDY => pcie_cc_mfb_src_rdy_piped,
        RX_DST_RDY => pcie_cc_mfb_dst_rdy_piped,

        TX_DATA    => PCIE_CC_MFB_DATA,
        TX_META    => PCIE_CC_MFB_META,
        TX_SOF_POS => PCIE_CC_MFB_SOF_POS,
        TX_EOF_POS => PCIE_CC_MFB_EOF_POS,
        TX_SOF     => PCIE_CC_MFB_SOF,
        TX_EOF     => PCIE_CC_MFB_EOF,
        TX_SRC_RDY => PCIE_CC_MFB_SRC_RDY,
        TX_DST_RDY => PCIE_CC_MFB_DST_RDY
    );
end architecture;
