-- nvme_sw_manager.vhd: Provides MI access to the Configuration and Status registers of the NVMe
-- Engine
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:
--  1. Add a CQHDBL value to the register array - DONE
--  2. Probably reset registers when the reset of a core is requested - NOTE: Not implemented
--  and only external components are reseted
--  3. Prohibit command trigger when the core is busy - SOLVED: Command trigger is ignored

use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;
use work.nvme_meta_pack.all;

use work.iuventus_bar_map_pkg.all;

entity NVME_SW_MANAGER is

    generic (
        -- 32 as always
        MI_WIDTH    : positive := 32;
        -- The allowed is only "ULTRASCALE"
        DEVICE      : string   := "ULTRASCALE";
        -- Maximum Payload Size according to the PCIe specification is the maximum size of a
        -- transaction in bytes that can be transported over the PCIe bus (up to 4096 B)
        MPS         : positive := 2**13;
        -- Maximum Read Reaquest SIze according to the PCIe specification (up to 4096 B)
        MRRS        : positive := 2**13;
        -- Maximum size of a packet that can be dispatched from the H2C/C2N buffers
        PKT_SIZE_MAX : positive := 2**17;
        -- Number of MFB regions of DBL_UPDATER's dispatch path -- sizes the dispatch-side read
        -- ports of the base-address LUTRAM (CQHDBL_BADDR_RD_QID/SQTDBL_BADDR_RD_QID below): up to
        -- MFB_REGIONS doorbell updates can be dequeued from DBL_UPDATER's own FIFO in the SAME
        -- cycle, each needing an independent (potentially different-queue) base-address lookup.
        MFB_REGIONS : positive := 2;
        -- Number of independent SQ/CQ queues (one per SSD). The MI register map is a COMMON
        -- (shared, low-offset) block followed by a generated PER-QUEUE 2D block (PER_Q_BASE +
        -- q*PER_Q_STRIDE, q = 0..NUM_QUEUES-1 -- queue 0 is just q=0 of that block, not
        -- special-cased). Per-queue registers are stored in NP_LUTRAM (distributed RAM, ITEMS =>
        -- NUM_QUEUES, one instance per field), not per-queue flops -- see the report accompanying
        -- this change for exactly which reader gets which LUTRAM read port. At NUM_QUEUES=1 the
        -- register map is NOT bit-identical to the historical single-queue layout (it has been
        -- intentionally redefined -- see PER_Q_BASE/PER_Q_STRIDE/PQ_* below), but single-queue
        -- behavior is functionally equivalent.
        NUM_QUEUES   : positive := 1
        );

    port (
        CLK : in std_logic;
        RST : in std_logic;

        USER_RST : out std_logic;

        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_ARDY : out std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DRDY : out std_logic;

        -- =======================================================================================
        -- Variaous counter increments for every bar
        -- =======================================================================================
        PCIE_RD_REQ_INCRS : in slv_array_t(3 downto 0)(1 downto 0);
        -- Is actually twice the size fo MRRS since both of the regions can contain its header
        PCIE_RD_REQ_BYTES : in slv_array_t(3 downto 0)(log2(MRRS+1) downto 0);
        PCIE_WR_REQ_INCRS : in slv_array_t(3 downto 0)(1 downto 0);
        PCIE_WR_REQ_BYTES : in slv_array_t(3 downto 0)(log2(MPS+1) -1 downto 0);

        PCIE_RD_REQ_TOTAL_INCR : in std_logic_vector(1 downto 0);
        PCIE_RD_REQ_TOTAL_BYTES : in std_logic_vector(log2(MRRS+1) downto 0);
        PCIE_WR_REQ_TOTAL_INCR : in std_logic_vector(1 downto 0);
        PCIE_WR_REQ_TOTAL_BYTES : in std_logic_vector(log2(MPS+1) -1 downto 0);

        N2C_BUFF_USR_RDS_INCR  : in std_logic;
        N2C_BUFF_USR_RDS_BYTES : in std_logic_vector(log2(PKT_SIZE_MAX+1) -1 downto 0);

        C2N_BUFF_DISP_RDS_CHAN  : in std_logic;
        C2N_BUFF_DISP_RDS_INCR  : in std_logic;
        C2N_BUFF_DISP_RDS_BYTES : in std_logic_vector(13 -1 downto 0);

        -- ========================================================================================
        -- Operation Control (COMMON -- the shared RDBUFF/WRBUFF data pool)
        -- ========================================================================================
        RDBUFF_BADDR         : out std_logic_vector(63 downto 0);
        RDBUFF_PRP_LIST_PTR  : out std_logic_vector(63 downto 0);
        WRBUFF_BADDR         : out std_logic_vector(63 downto 0);
        WRBUFF_PRP_LIST_PTR  : out std_logic_vector(63 downto 0);

        -- Queue (OP_CTRL's own admitted-command qid_reg, mirrored by its C2N_QID output) whose
        -- LBA_SPACE_SIZE/LBA_NUM_MASK OP_CTRL needs this cycle for its OOR check. Always "0" at
        -- NUM_QUEUES=1.
        LBA_CHECK_QID      : in  std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);
        LBA_SPACE_SIZE_OPC : out std_logic_vector(63 downto 0);
        LBA_NUM_MASK_OPC   : out std_logic_vector(15 downto 0);

        -- ========================================================================================
        -- C2N Command dispatcher
        -- ========================================================================================
        -- The current value of SQTDBL, and the queue it belongs to -- routes into that queue's
        -- own PQ_SQTDBL observation register. The SAME qid also selects C2N_CONTROLLER's own
        -- (dispatch-time) DBL_MASK/NAMESPACE_ID/LBA_SPACE_SIZE/LBA_NUM_MASK reads below, since it
        -- mirrors NVME_CMD_DISPATCHER's own QID at the same cycle. Always "0" at NUM_QUEUES=1.
        SQTDBL_DATA     : in  std_logic_vector(15 downto 0);
        SQTDBL_QID      : in  std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);
        TAG_FIFO_STATUS : in std_logic_vector(11 downto 0);
        TAG_INIT_DONE   : in std_logic;

        -- Per-queue configuration of the queue NVME_CMD_DISPATCHER is currently dispatching to
        -- (SQTDBL_QID above).
        DBL_MASK_C2N       : out std_logic_vector(15 downto 0);
        NAMESPACE_ID_C2N   : out std_logic_vector(31 downto 0);
        LBA_SPACE_SIZE_C2N : out std_logic_vector(63 downto 0);
        LBA_NUM_MASK_C2N   : out std_logic_vector(15 downto 0);
        -- COMMON: a single shared metadata pointer for every queue.
        METADATA_PTR   : out std_logic_vector(63 downto 0);

        SQES_DISP_TYPE  : in std_logic_vector(CMD_OPCODE_W -1 downto 0);
        SQES_DISP_INCR  : in std_logic;
        SQES_DISP_BYTES : in std_logic_vector(25 -1 downto 0);

        -- =========================================================================================
        -- N2C Completion processor
        -- =========================================================================================
        -- SQHDBL_DATA/CQHDBL_DATA/LAST_CQ_ENTRY/STATUS_UPD_VLD all describe the SAME completion
        -- event, reported for queue CQHDBL_QID -- routes SQHDBL_DATA/CQHDBL_DATA into that
        -- queue's own PQ_SQHDBL/PQ_CQHDBL observation registers. Always "0" at NUM_QUEUES=1.
        SQHDBL_DATA     : in std_logic_vector(15 downto 0);
        CQHDBL_DATA     : in std_logic_vector(15 downto 0);
        CQHDBL_QID      : in std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);
        -- LAST_CQ_ENTRY/CPL_ERR_MASK stay COMMON: a single system-wide "last completion" snapshot
        -- aggregated across every queue, feeding the aggregate CQE_ERROR_TRACKER below -- not yet
        -- made per-queue (no per-queue consumer identified; see the report accompanying this
        -- change).
        LAST_CQ_ENTRY   : in std_logic_vector(CQ_ENTRY_RANGE);
        STATUS_UPD_VLD  : in std_logic;

        -- Queue (CQE_PROCESSOR's own resp_qidx, undelayed -- unlike CQP_CQE_QID above, which
        -- N2C_CONTROLLER registers) whose DBL_MASK CQE_PROCESSOR needs to interpret THIS cycle's
        -- CQ read response. Always "0" at NUM_QUEUES=1.
        DBL_MASK_RD_QID : in  std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);
        DBL_MASK_N2C    : out std_logic_vector(15 downto 0);

        -- =========================================================================================
        -- DBL Updater
        -- =========================================================================================
        -- One bit per doorbell (indices 0..NUM_QUEUES-1 = CQHDBL[q], NUM_QUEUES..2*NUM_QUEUES-1 =
        -- SQTDBL[q], matching DBL_UPDATER's own dbl_reg indexing), sticky-set once a non-zero PCIe
        -- base address has been written via MI for that doorbell -- see DBL_UPDATER's own port
        -- comment.
        DBL_ENABLED : out std_logic_vector(2*NUM_QUEUES -1 downto 0);

        -- Dispatch-side base-address lookup, one queue at a time per MFB region -- see
        -- DBL_UPDATER's own port comment for why MFB_REGIONS ports (not 1, not NUM_QUEUES).
        CQHDBL_BADDR_RD_QID  : in  slv_array_t(MFB_REGIONS -1 downto 0)(maximum(1, log2(NUM_QUEUES)) -1 downto 0);
        CQHDBL_BADDR_RD_DATA : out slv_array_t(MFB_REGIONS -1 downto 0)(63 downto 0);
        SQTDBL_BADDR_RD_QID  : in  slv_array_t(MFB_REGIONS -1 downto 0)(maximum(1, log2(NUM_QUEUES)) -1 downto 0);
        SQTDBL_BADDR_RD_DATA : out slv_array_t(MFB_REGIONS -1 downto 0)(63 downto 0);

        CQHDBL_REG_UPD_DISP : in std_logic;
        SQTDBL_REG_UPD_DISP : in std_logic;

        -- ========================================================================================
        -- Performance Counters
        -- ========================================================================================
        OPC_TRIGG_DISP : in std_logic;

        -- =======================================================================================
        -- Start/stop control
        -- ======================================================================================
        OPC_START_REQ_VLD : out std_logic;
        OPC_START_REQ_ACK : in std_logic;
        CQP_START_REQ_VLD : out std_logic;
        CQP_START_REQ_ACK : in std_logic;

        OPC_STOP_REQ_VLD  : out std_logic;
        OPC_STOP_REQ_ACK  : in std_logic;
        CQP_STOP_REQ_VLD  : out std_logic;
        CQP_STOP_REQ_ACK  : in std_logic
    );
end entity;

architecture FULL of NVME_SW_MANAGER is
    -- MI register address width (bits of MI_ADDR matched against R_ADDRS). Must cover the whole
    -- PER_Q_BASE + NUM_QUEUES*PER_Q_STRIDE per-queue block below (see the assertion in the
    -- architecture body) while staying inside this component's own MI_SPLIT_ADDR_MASK=0x1000
    -- window (see MI_SPLIT_ADDR_MASK below) -- 12 bits reaches the whole 0x000-0xFFF span, i.e.
    -- everything below the DATA_LOGGER's own 0x1000 base.
    constant ADDR_LENGTH : positive := 12;
    constant CNTR_WIDTH  : positive := 64;

    -- Width of a Queue Identifier value (0 to NUM_QUEUES-1) as used on every QID port throughout
    -- this design (always at least 1 bit, even at NUM_QUEUES=1).
    constant QID_W : positive := maximum(1, log2(NUM_QUEUES));
    -- Actual per-queue LUTRAM depth: NUM_QUEUES rounded up to at least 2, so that
    -- log2(LUTRAM_ITEMS) always equals QID_W exactly (log2(1) = 0 would otherwise give a
    -- 0-bit -- null-range -- NP_LUTRAM address port at NUM_QUEUES=1, which is unnecessary risk
    -- for one wasted, never-addressed extra row of distributed RAM).
    constant LUTRAM_ITEMS : positive := maximum(2, NUM_QUEUES);

    -- =============================================================================================
    -- COMMON register block (shared across every queue): CONTROL/STATUS, the shared RDBUFF/WRBUFF
    -- data-pool base addresses/PRP list pointers, METADATA_PTR, LAST_CQ_ENTRY/CPL_ERR_MASK/
    -- TAG_FIFO_STATUS status, and every *_CNTR performance counter (all of these remain
    -- aggregated across queues for now -- see the report accompanying this change for exactly
    -- which ones, and whether any should become per-queue in a later pass). Stored in plain flops
    -- (regs_arr below), unchanged from before -- only the PER-QUEUE block (further below) moved
    -- to NP_LUTRAM.
    -- =============================================================================================
    constant R_CONTROL                      : natural := 0;
    constant R_STATUS                       : natural := 1;
    constant R_RDBUFF_BADDR_L               : natural := 2;
    constant R_RDBUFF_BADDR_H               : natural := 3;
    constant R_RDBUFF_PRP_LIST_PTR_L        : natural := 4;
    constant R_RDBUFF_PRP_LIST_PTR_H        : natural := 5;
    constant R_WRBUFF_BADDR_L               : natural := 6;
    constant R_WRBUFF_BADDR_H               : natural := 7;
    constant R_WRBUFF_PRP_LIST_PTR_L        : natural := 8;
    constant R_WRBUFF_PRP_LIST_PTR_H        : natural := 9;
    constant R_META_PTR_L                   : natural := 10;
    constant R_META_PTR_H                   : natural := 11;
    constant R_LAST_CQ_ENTRY_0              : natural := 12;
    constant R_LAST_CQ_ENTRY_1              : natural := 13;
    constant R_LAST_CQ_ENTRY_2              : natural := 14;
    constant R_LAST_CQ_ENTRY_3              : natural := 15;
    constant R_CPL_ERR_MASK_L               : natural := 16;
    constant R_CPL_ERR_MASK_H               : natural := 17;
    constant R_TAG_FIFO_STATUS              : natural := 18;
    constant R_SQE_DISP_CNTR_L              : natural := 19;
    constant R_SQE_DISP_CNTR_H              : natural := 20;
    constant R_CQE_PROC_CNTR_L              : natural := 21;
    constant R_CQE_PROC_CNTR_H              : natural := 22;
    constant R_PCIE_RDS_CNTR_L              : natural := 23;
    constant R_PCIE_RDS_CNTR_H              : natural := 24;
    constant R_PCIE_RD_BYTES_CNTR_L         : natural := 25;
    constant R_PCIE_RD_BYTES_CNTR_H         : natural := 26;
    constant R_PCIE_WRS_CNTR_L              : natural := 27;
    constant R_PCIE_WRS_CNTR_H              : natural := 28;
    constant R_PCIE_WR_BYTES_CNTR_L         : natural := 29;
    constant R_PCIE_WR_BYTES_CNTR_H         : natural := 30;
    constant R_SQ_PCIE_RDS_CNTR_L           : natural := 31;
    constant R_SQ_PCIE_RDS_CNTR_H           : natural := 32;
    constant R_SQ_PCIE_RD_BYTES_CNTR_L      : natural := 33;
    constant R_SQ_PCIE_RD_BYTES_CNTR_H      : natural := 34;
    constant R_SUCC_COMPL_CNTR_L            : natural := 35;
    constant R_SUCC_COMPL_CNTR_H            : natural := 36;
    constant R_UNSUCC_COMPL_CNTR_L          : natural := 37;
    constant R_UNSUCC_COMPL_CNTR_H          : natural := 38;
    constant R_RDBUFF_PCIE_RDS_CNTR_L       : natural := 39;
    constant R_RDBUFF_PCIE_RDS_CNTR_H       : natural := 40;
    constant R_RDBUFF_PCIE_RD_BYTES_CNTR_L  : natural := 41;
    constant R_RDBUFF_PCIE_RD_BYTES_CNTR_H  : natural := 42;
    constant R_WRBUFF_PCIE_WRS_CNTR_L       : natural := 43;
    constant R_WRBUFF_PCIE_WRS_CNTR_H       : natural := 44;
    constant R_WRBUFF_PCIE_WR_BYTES_CNTR_L  : natural := 45;
    constant R_WRBUFF_PCIE_WR_BYTES_CNTR_H  : natural := 46;
    constant R_CQ_PCIE_WRS_CNTR_L           : natural := 47;
    constant R_CQ_PCIE_WRS_CNTR_H           : natural := 48;
    constant R_CQ_PCIE_WR_BYTES_CNTR_L      : natural := 49;
    constant R_CQ_PCIE_WR_BYTES_CNTR_H      : natural := 50;
    constant R_CQHDBL_REG_UPDS_CNTR_L       : natural := 51;
    constant R_CQHDBL_REG_UPDS_CNTR_H       : natural := 52;
    constant R_CQHDBL_RPT_UPDS_CNTR_L       : natural := 53;
    constant R_CQHDBL_RPT_UPDS_CNTR_H       : natural := 54;
    constant R_SQTDBL_REG_UPDS_CNTR_L       : natural := 55;
    constant R_SQTDBL_REG_UPDS_CNTR_H       : natural := 56;
    constant R_SQTDBL_RPT_UPDS_CNTR_L       : natural := 57;
    constant R_SQTDBL_RPT_UPDS_CNTR_H       : natural := 58;
    constant R_NVME_RD_BYTES_CNTR_L         : natural := 59;
    constant R_NVME_RD_BYTES_CNTR_H         : natural := 60;
    constant R_NVME_WR_BYTES_CNTR_L         : natural := 61;
    constant R_NVME_WR_BYTES_CNTR_H         : natural := 62;
    constant R_WRBUFF_USR_RDS_CNTR_L        : natural := 63;
    constant R_WRBUFF_USR_RDS_CNTR_H        : natural := 64;
    constant R_WRBUFF_USR_RD_BYTES_CNTR_L   : natural := 65;
    constant R_WRBUFF_USR_RD_BYTES_CNTR_H   : natural := 66;
    constant R_RDBUFF_DISP_RDS_CNTR_L       : natural := 67;
    constant R_RDBUFF_DISP_RDS_CNTR_H       : natural := 68;
    constant R_RDBUFF_DISP_RD_BYTES_CNTR_L  : natural := 69;
    constant R_RDBUFF_DISP_RD_BYTES_CNTR_H  : natural := 70;
    constant R_SQ_DISP_RDS_CNTR_L           : natural := 71;
    constant R_SQ_DISP_RDS_CNTR_H           : natural := 72;
    constant R_SQ_DISP_RD_BYTES_CNTR_L      : natural := 73;
    constant R_SQ_DISP_RD_BYTES_CNTR_H      : natural := 74;
    constant R_NVME_FLUSH_CMD_DISP_CNTR_L   : natural := 75;
    constant R_NVME_FLUSH_CMD_DISP_CNTR_H   : natural := 76;

    -- Number of registers in the COMMON block above; also the total register count (REGS), since
    -- the PER-QUEUE block is no longer part of regs_arr/R_ADDRS -- see PQ_* below instead.
    constant COMMON_REGS : natural := 77;
    constant REGS        : natural := COMMON_REGS;

    constant R_ADDRS : n_array_t(0 to REGS-1) := (
        R_CONTROL                       => 16#000#,
        R_STATUS                        => 16#004#,
        R_RDBUFF_BADDR_L                => 16#008#,
        R_RDBUFF_BADDR_H                => 16#00C#,
        R_RDBUFF_PRP_LIST_PTR_L         => 16#010#,
        R_RDBUFF_PRP_LIST_PTR_H         => 16#014#,
        R_WRBUFF_BADDR_L                => 16#018#,
        R_WRBUFF_BADDR_H                => 16#01C#,
        R_WRBUFF_PRP_LIST_PTR_L         => 16#020#,
        R_WRBUFF_PRP_LIST_PTR_H         => 16#024#,
        R_META_PTR_L                    => 16#028#,
        R_META_PTR_H                    => 16#02C#,
        R_LAST_CQ_ENTRY_0               => 16#030#,
        R_LAST_CQ_ENTRY_1               => 16#034#,
        R_LAST_CQ_ENTRY_2               => 16#038#,
        R_LAST_CQ_ENTRY_3               => 16#03C#,
        R_CPL_ERR_MASK_L                => 16#040#,
        R_CPL_ERR_MASK_H                => 16#044#,
        R_TAG_FIFO_STATUS               => 16#048#,
        R_SQE_DISP_CNTR_L               => 16#04C#,
        R_SQE_DISP_CNTR_H               => 16#050#,
        R_CQE_PROC_CNTR_L               => 16#054#,
        R_CQE_PROC_CNTR_H               => 16#058#,
        R_PCIE_RDS_CNTR_L               => 16#05C#,
        R_PCIE_RDS_CNTR_H               => 16#060#,
        R_PCIE_RD_BYTES_CNTR_L          => 16#064#,
        R_PCIE_RD_BYTES_CNTR_H          => 16#068#,
        R_PCIE_WRS_CNTR_L               => 16#06C#,
        R_PCIE_WRS_CNTR_H               => 16#070#,
        R_PCIE_WR_BYTES_CNTR_L          => 16#074#,
        R_PCIE_WR_BYTES_CNTR_H          => 16#078#,
        R_SQ_PCIE_RDS_CNTR_L            => 16#07C#,
        R_SQ_PCIE_RDS_CNTR_H            => 16#080#,
        R_SQ_PCIE_RD_BYTES_CNTR_L       => 16#084#,
        R_SQ_PCIE_RD_BYTES_CNTR_H       => 16#088#,
        R_SUCC_COMPL_CNTR_L             => 16#08C#,
        R_SUCC_COMPL_CNTR_H             => 16#090#,
        R_UNSUCC_COMPL_CNTR_L           => 16#094#,
        R_UNSUCC_COMPL_CNTR_H           => 16#098#,
        R_RDBUFF_PCIE_RDS_CNTR_L        => 16#09C#,
        R_RDBUFF_PCIE_RDS_CNTR_H        => 16#0A0#,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => 16#0A4#,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => 16#0A8#,
        R_WRBUFF_PCIE_WRS_CNTR_L        => 16#0AC#,
        R_WRBUFF_PCIE_WRS_CNTR_H        => 16#0B0#,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => 16#0B4#,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => 16#0B8#,
        R_CQ_PCIE_WRS_CNTR_L            => 16#0BC#,
        R_CQ_PCIE_WRS_CNTR_H            => 16#0C0#,
        R_CQ_PCIE_WR_BYTES_CNTR_L       => 16#0C4#,
        R_CQ_PCIE_WR_BYTES_CNTR_H       => 16#0C8#,
        R_CQHDBL_REG_UPDS_CNTR_L        => 16#0CC#,
        R_CQHDBL_REG_UPDS_CNTR_H        => 16#0D0#,
        R_CQHDBL_RPT_UPDS_CNTR_L        => 16#0D4#,
        R_CQHDBL_RPT_UPDS_CNTR_H        => 16#0D8#,
        R_SQTDBL_REG_UPDS_CNTR_L        => 16#0DC#,
        R_SQTDBL_REG_UPDS_CNTR_H        => 16#0E0#,
        R_SQTDBL_RPT_UPDS_CNTR_L        => 16#0E4#,
        R_SQTDBL_RPT_UPDS_CNTR_H        => 16#0E8#,
        R_NVME_RD_BYTES_CNTR_L          => 16#0EC#,
        R_NVME_RD_BYTES_CNTR_H          => 16#0F0#,
        R_NVME_WR_BYTES_CNTR_L          => 16#0F4#,
        R_NVME_WR_BYTES_CNTR_H          => 16#0F8#,
        R_WRBUFF_USR_RDS_CNTR_L         => 16#0FC#,
        R_WRBUFF_USR_RDS_CNTR_H         => 16#100#,
        R_WRBUFF_USR_RD_BYTES_CNTR_L    => 16#104#,
        R_WRBUFF_USR_RD_BYTES_CNTR_H    => 16#108#,
        R_RDBUFF_DISP_RDS_CNTR_L        => 16#10C#,
        R_RDBUFF_DISP_RDS_CNTR_H        => 16#110#,
        R_RDBUFF_DISP_RD_BYTES_CNTR_L   => 16#114#,
        R_RDBUFF_DISP_RD_BYTES_CNTR_H   => 16#118#,
        R_SQ_DISP_RDS_CNTR_L            => 16#11C#,
        R_SQ_DISP_RDS_CNTR_H            => 16#120#,
        R_SQ_DISP_RD_BYTES_CNTR_L       => 16#124#,
        R_SQ_DISP_RD_BYTES_CNTR_H       => 16#128#,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => 16#12C#,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => 16#130#
    );

    constant WR_EN : b_array_t(0 to REGS-1) := (
        R_CONTROL                       => TRUE,
        R_STATUS                        => FALSE,
        R_RDBUFF_BADDR_L                => TRUE,
        R_RDBUFF_BADDR_H                => TRUE,
        R_RDBUFF_PRP_LIST_PTR_L         => TRUE,
        R_RDBUFF_PRP_LIST_PTR_H         => TRUE,
        R_WRBUFF_BADDR_L                => TRUE,
        R_WRBUFF_BADDR_H                => TRUE,
        R_WRBUFF_PRP_LIST_PTR_L         => TRUE,
        R_WRBUFF_PRP_LIST_PTR_H         => TRUE,
        R_META_PTR_L                    => TRUE,
        R_META_PTR_H                    => TRUE,
        R_LAST_CQ_ENTRY_0               => FALSE,
        R_LAST_CQ_ENTRY_1               => FALSE,
        R_LAST_CQ_ENTRY_2               => FALSE,
        R_LAST_CQ_ENTRY_3               => FALSE,
        R_CPL_ERR_MASK_L                => FALSE,
        R_CPL_ERR_MASK_H                => FALSE,
        R_TAG_FIFO_STATUS               => FALSE,
        R_SQE_DISP_CNTR_L               => FALSE,
        R_SQE_DISP_CNTR_H               => FALSE,
        R_CQE_PROC_CNTR_L               => FALSE,
        R_CQE_PROC_CNTR_H               => FALSE,
        R_PCIE_RDS_CNTR_L               => FALSE,
        R_PCIE_RDS_CNTR_H               => FALSE,
        R_PCIE_RD_BYTES_CNTR_L          => FALSE,
        R_PCIE_RD_BYTES_CNTR_H          => FALSE,
        R_PCIE_WRS_CNTR_L               => FALSE,
        R_PCIE_WRS_CNTR_H               => FALSE,
        R_PCIE_WR_BYTES_CNTR_L          => FALSE,
        R_PCIE_WR_BYTES_CNTR_H          => FALSE,
        R_SQ_PCIE_RDS_CNTR_L            => FALSE,
        R_SQ_PCIE_RDS_CNTR_H            => FALSE,
        R_SQ_PCIE_RD_BYTES_CNTR_L       => FALSE,
        R_SQ_PCIE_RD_BYTES_CNTR_H       => FALSE,
        R_SUCC_COMPL_CNTR_L             => FALSE,
        R_SUCC_COMPL_CNTR_H             => FALSE,
        R_UNSUCC_COMPL_CNTR_L           => FALSE,
        R_UNSUCC_COMPL_CNTR_H           => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_L        => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_H        => FALSE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => FALSE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => FALSE,
        R_WRBUFF_PCIE_WRS_CNTR_L        => FALSE,
        R_WRBUFF_PCIE_WRS_CNTR_H        => FALSE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => FALSE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => FALSE,
        R_CQ_PCIE_WRS_CNTR_L            => FALSE,
        R_CQ_PCIE_WRS_CNTR_H            => FALSE,
        R_CQ_PCIE_WR_BYTES_CNTR_L       => FALSE,
        R_CQ_PCIE_WR_BYTES_CNTR_H       => FALSE,
        R_CQHDBL_REG_UPDS_CNTR_L        => FALSE,
        R_CQHDBL_REG_UPDS_CNTR_H        => FALSE,
        R_CQHDBL_RPT_UPDS_CNTR_L        => FALSE,
        R_CQHDBL_RPT_UPDS_CNTR_H        => FALSE,
        R_SQTDBL_REG_UPDS_CNTR_L        => FALSE,
        R_SQTDBL_REG_UPDS_CNTR_H        => FALSE,
        R_SQTDBL_RPT_UPDS_CNTR_L        => FALSE,
        R_SQTDBL_RPT_UPDS_CNTR_H        => FALSE,
        R_NVME_RD_BYTES_CNTR_L          => FALSE,
        R_NVME_RD_BYTES_CNTR_H          => FALSE,
        R_NVME_WR_BYTES_CNTR_L          => FALSE,
        R_NVME_WR_BYTES_CNTR_H          => FALSE,
        R_WRBUFF_USR_RDS_CNTR_L         => FALSE,
        R_WRBUFF_USR_RDS_CNTR_H         => FALSE,
        R_WRBUFF_USR_RD_BYTES_CNTR_L    => FALSE,
        R_WRBUFF_USR_RD_BYTES_CNTR_H    => FALSE,
        R_RDBUFF_DISP_RDS_CNTR_L        => FALSE,
        R_RDBUFF_DISP_RDS_CNTR_H        => FALSE,
        R_RDBUFF_DISP_RD_BYTES_CNTR_L   => FALSE,
        R_RDBUFF_DISP_RD_BYTES_CNTR_H   => FALSE,
        R_SQ_DISP_RDS_CNTR_L            => FALSE,
        R_SQ_DISP_RDS_CNTR_H            => FALSE,
        R_SQ_DISP_RD_BYTES_CNTR_L       => FALSE,
        R_SQ_DISP_RD_BYTES_CNTR_H       => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => FALSE
    );

    constant STROBE_EN : b_array_t(0 to REGS-1) := (
        R_CONTROL                       => FALSE,
        R_STATUS                        => FALSE,
        R_RDBUFF_BADDR_L                => FALSE,
        R_RDBUFF_BADDR_H                => FALSE,
        R_RDBUFF_PRP_LIST_PTR_L         => FALSE,
        R_RDBUFF_PRP_LIST_PTR_H         => FALSE,
        R_WRBUFF_BADDR_L                => FALSE,
        R_WRBUFF_BADDR_H                => FALSE,
        R_WRBUFF_PRP_LIST_PTR_L         => FALSE,
        R_WRBUFF_PRP_LIST_PTR_H         => FALSE,
        R_META_PTR_L                    => FALSE,
        R_META_PTR_H                    => FALSE,
        R_LAST_CQ_ENTRY_0               => TRUE,
        R_LAST_CQ_ENTRY_1               => TRUE,
        R_LAST_CQ_ENTRY_2               => TRUE,
        R_LAST_CQ_ENTRY_3               => TRUE,
        R_CPL_ERR_MASK_L                => FALSE,
        R_CPL_ERR_MASK_H                => FALSE,
        R_TAG_FIFO_STATUS               => FALSE,
        R_SQE_DISP_CNTR_L               => TRUE,
        R_SQE_DISP_CNTR_H               => TRUE,
        R_CQE_PROC_CNTR_L               => TRUE,
        R_CQE_PROC_CNTR_H               => TRUE,
        R_PCIE_RDS_CNTR_L               => TRUE,
        R_PCIE_RDS_CNTR_H               => TRUE,
        R_PCIE_RD_BYTES_CNTR_L          => TRUE,
        R_PCIE_RD_BYTES_CNTR_H          => TRUE,
        R_PCIE_WRS_CNTR_L               => TRUE,
        R_PCIE_WRS_CNTR_H               => TRUE,
        R_PCIE_WR_BYTES_CNTR_L          => TRUE,
        R_PCIE_WR_BYTES_CNTR_H          => TRUE,
        R_SQ_PCIE_RDS_CNTR_L            => TRUE,
        R_SQ_PCIE_RDS_CNTR_H            => TRUE,
        R_SQ_PCIE_RD_BYTES_CNTR_L       => TRUE,
        R_SQ_PCIE_RD_BYTES_CNTR_H       => TRUE,
        R_SUCC_COMPL_CNTR_L             => TRUE,
        R_SUCC_COMPL_CNTR_H             => TRUE,
        R_UNSUCC_COMPL_CNTR_L           => TRUE,
        R_UNSUCC_COMPL_CNTR_H           => TRUE,
        R_RDBUFF_PCIE_RDS_CNTR_L        => TRUE,
        R_RDBUFF_PCIE_RDS_CNTR_H        => TRUE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => TRUE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => TRUE,
        R_WRBUFF_PCIE_WRS_CNTR_L        => TRUE,
        R_WRBUFF_PCIE_WRS_CNTR_H        => TRUE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => TRUE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => TRUE,
        R_CQ_PCIE_WRS_CNTR_L            => TRUE,
        R_CQ_PCIE_WRS_CNTR_H            => TRUE,
        R_CQ_PCIE_WR_BYTES_CNTR_L       => TRUE,
        R_CQ_PCIE_WR_BYTES_CNTR_H       => TRUE,
        R_CQHDBL_REG_UPDS_CNTR_L        => TRUE,
        R_CQHDBL_REG_UPDS_CNTR_H        => TRUE,
        R_CQHDBL_RPT_UPDS_CNTR_L        => TRUE,
        R_CQHDBL_RPT_UPDS_CNTR_H        => TRUE,
        R_SQTDBL_REG_UPDS_CNTR_L        => TRUE,
        R_SQTDBL_REG_UPDS_CNTR_H        => TRUE,
        R_SQTDBL_RPT_UPDS_CNTR_L        => TRUE,
        R_SQTDBL_RPT_UPDS_CNTR_H        => TRUE,
        R_NVME_RD_BYTES_CNTR_L          => TRUE,
        R_NVME_RD_BYTES_CNTR_H          => TRUE,
        R_NVME_WR_BYTES_CNTR_L          => TRUE,
        R_NVME_WR_BYTES_CNTR_H          => TRUE,
        R_WRBUFF_USR_RDS_CNTR_L         => TRUE,
        R_WRBUFF_USR_RDS_CNTR_H         => TRUE,
        R_WRBUFF_USR_RD_BYTES_CNTR_L    => TRUE,
        R_WRBUFF_USR_RD_BYTES_CNTR_H    => TRUE,
        R_RDBUFF_DISP_RDS_CNTR_L        => TRUE,
        R_RDBUFF_DISP_RDS_CNTR_H        => TRUE,
        R_RDBUFF_DISP_RD_BYTES_CNTR_L   => TRUE,
        R_RDBUFF_DISP_RD_BYTES_CNTR_H   => TRUE,
        R_SQ_DISP_RDS_CNTR_L            => TRUE,
        R_SQ_DISP_RDS_CNTR_H            => TRUE,
        R_SQ_DISP_RD_BYTES_CNTR_L       => TRUE,
        R_SQ_DISP_RD_BYTES_CNTR_H       => TRUE,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => TRUE,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => TRUE
    );

    constant REG_IS_CNTR : b_array_t(0 to REGS-1) := (
        R_CONTROL                       => FALSE,
        R_STATUS                        => FALSE,
        R_RDBUFF_BADDR_L                => FALSE,
        R_RDBUFF_BADDR_H                => FALSE,
        R_RDBUFF_PRP_LIST_PTR_L         => FALSE,
        R_RDBUFF_PRP_LIST_PTR_H         => FALSE,
        R_WRBUFF_BADDR_L                => FALSE,
        R_WRBUFF_BADDR_H                => FALSE,
        R_WRBUFF_PRP_LIST_PTR_L         => FALSE,
        R_WRBUFF_PRP_LIST_PTR_H         => FALSE,
        R_META_PTR_L                    => FALSE,
        R_META_PTR_H                    => FALSE,
        R_LAST_CQ_ENTRY_0               => FALSE,
        R_LAST_CQ_ENTRY_1               => FALSE,
        R_LAST_CQ_ENTRY_2               => FALSE,
        R_LAST_CQ_ENTRY_3               => FALSE,
        R_CPL_ERR_MASK_L                => FALSE,
        R_CPL_ERR_MASK_H                => FALSE,
        R_TAG_FIFO_STATUS               => FALSE,
        R_SQE_DISP_CNTR_L               => TRUE,
        R_SQE_DISP_CNTR_H               => FALSE,
        R_CQE_PROC_CNTR_L               => TRUE,
        R_CQE_PROC_CNTR_H               => FALSE,
        R_PCIE_RDS_CNTR_L               => TRUE,
        R_PCIE_RDS_CNTR_H               => FALSE,
        R_PCIE_RD_BYTES_CNTR_L          => TRUE,
        R_PCIE_RD_BYTES_CNTR_H          => FALSE,
        R_PCIE_WRS_CNTR_L               => TRUE,
        R_PCIE_WRS_CNTR_H               => FALSE,
        R_PCIE_WR_BYTES_CNTR_L          => TRUE,
        R_PCIE_WR_BYTES_CNTR_H          => FALSE,
        R_SQ_PCIE_RDS_CNTR_L            => TRUE,
        R_SQ_PCIE_RDS_CNTR_H            => FALSE,
        R_SQ_PCIE_RD_BYTES_CNTR_L       => TRUE,
        R_SQ_PCIE_RD_BYTES_CNTR_H       => FALSE,
        R_SUCC_COMPL_CNTR_L             => TRUE,
        R_SUCC_COMPL_CNTR_H             => FALSE,
        R_UNSUCC_COMPL_CNTR_L           => TRUE,
        R_UNSUCC_COMPL_CNTR_H           => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_L        => TRUE,
        R_RDBUFF_PCIE_RDS_CNTR_H        => FALSE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => TRUE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => FALSE,
        R_WRBUFF_PCIE_WRS_CNTR_L        => TRUE,
        R_WRBUFF_PCIE_WRS_CNTR_H        => FALSE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => TRUE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => FALSE,
        R_CQ_PCIE_WRS_CNTR_L            => TRUE,
        R_CQ_PCIE_WRS_CNTR_H            => FALSE,
        R_CQ_PCIE_WR_BYTES_CNTR_L       => TRUE,
        R_CQ_PCIE_WR_BYTES_CNTR_H       => FALSE,
        R_CQHDBL_REG_UPDS_CNTR_L        => TRUE,
        R_CQHDBL_REG_UPDS_CNTR_H        => FALSE,
        R_CQHDBL_RPT_UPDS_CNTR_L        => TRUE,
        R_CQHDBL_RPT_UPDS_CNTR_H        => FALSE,
        R_SQTDBL_REG_UPDS_CNTR_L        => TRUE,
        R_SQTDBL_REG_UPDS_CNTR_H        => FALSE,
        R_SQTDBL_RPT_UPDS_CNTR_L        => TRUE,
        R_SQTDBL_RPT_UPDS_CNTR_H        => FALSE,
        R_NVME_RD_BYTES_CNTR_L          => TRUE,
        R_NVME_RD_BYTES_CNTR_H          => FALSE,
        R_NVME_WR_BYTES_CNTR_L          => TRUE,
        R_NVME_WR_BYTES_CNTR_H          => FALSE,
        R_WRBUFF_USR_RDS_CNTR_L         => TRUE,
        R_WRBUFF_USR_RDS_CNTR_H         => FALSE,
        R_WRBUFF_USR_RD_BYTES_CNTR_L    => TRUE,
        R_WRBUFF_USR_RD_BYTES_CNTR_H    => FALSE,
        R_RDBUFF_DISP_RDS_CNTR_L        => TRUE,
        R_RDBUFF_DISP_RDS_CNTR_H        => FALSE,
        R_RDBUFF_DISP_RD_BYTES_CNTR_L   => TRUE,
        R_RDBUFF_DISP_RD_BYTES_CNTR_H   => FALSE,
        R_SQ_DISP_RDS_CNTR_L            => TRUE,
        R_SQ_DISP_RDS_CNTR_H            => FALSE,
        R_SQ_DISP_RD_BYTES_CNTR_L       => TRUE,
        R_SQ_DISP_RD_BYTES_CNTR_H       => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => TRUE,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => FALSE
    );

    constant REG_WIDTH : n_array_t(0 to REGS-1) := (
        R_CONTROL                       => 6,
        R_STATUS                        => 3,
        R_RDBUFF_BADDR_L                => 32,
        R_RDBUFF_BADDR_H                => 32,
        R_RDBUFF_PRP_LIST_PTR_L         => 32,
        R_RDBUFF_PRP_LIST_PTR_H         => 32,
        R_WRBUFF_BADDR_L                => 32,
        R_WRBUFF_BADDR_H                => 32,
        R_WRBUFF_PRP_LIST_PTR_L         => 32,
        R_WRBUFF_PRP_LIST_PTR_H         => 32,
        R_META_PTR_L                    => 32,
        R_META_PTR_H                    => 32,
        R_LAST_CQ_ENTRY_0               => 32,
        R_LAST_CQ_ENTRY_1               => 32,
        R_LAST_CQ_ENTRY_2               => 32,
        R_LAST_CQ_ENTRY_3               => 32,
        R_CPL_ERR_MASK_L                => 32,
        R_CPL_ERR_MASK_H                => 32,
        R_TAG_FIFO_STATUS               => 12,
        R_SQE_DISP_CNTR_L               => 32,
        R_SQE_DISP_CNTR_H               => 32,
        R_CQE_PROC_CNTR_L               => 32,
        R_CQE_PROC_CNTR_H               => 32,
        R_PCIE_RDS_CNTR_L               => 32,
        R_PCIE_RDS_CNTR_H               => 32,
        R_PCIE_RD_BYTES_CNTR_L          => 32,
        R_PCIE_RD_BYTES_CNTR_H          => 32,
        R_PCIE_WRS_CNTR_L               => 32,
        R_PCIE_WRS_CNTR_H               => 32,
        R_PCIE_WR_BYTES_CNTR_L          => 32,
        R_PCIE_WR_BYTES_CNTR_H          => 32,
        R_SQ_PCIE_RDS_CNTR_L            => 32,
        R_SQ_PCIE_RDS_CNTR_H            => 32,
        R_SQ_PCIE_RD_BYTES_CNTR_L       => 32,
        R_SQ_PCIE_RD_BYTES_CNTR_H       => 32,
        R_SUCC_COMPL_CNTR_L             => 32,
        R_SUCC_COMPL_CNTR_H             => 32,
        R_UNSUCC_COMPL_CNTR_L           => 32,
        R_UNSUCC_COMPL_CNTR_H           => 32,
        R_RDBUFF_PCIE_RDS_CNTR_L        => 32,
        R_RDBUFF_PCIE_RDS_CNTR_H        => 32,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => 32,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => 32,
        R_WRBUFF_PCIE_WRS_CNTR_L        => 32,
        R_WRBUFF_PCIE_WRS_CNTR_H        => 32,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => 32,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => 32,
        R_CQ_PCIE_WRS_CNTR_L            => 32,
        R_CQ_PCIE_WRS_CNTR_H            => 32,
        R_CQ_PCIE_WR_BYTES_CNTR_L       => 32,
        R_CQ_PCIE_WR_BYTES_CNTR_H       => 32,
        R_CQHDBL_REG_UPDS_CNTR_L        => 32,
        R_CQHDBL_REG_UPDS_CNTR_H        => 32,
        R_CQHDBL_RPT_UPDS_CNTR_L        => 32,
        R_CQHDBL_RPT_UPDS_CNTR_H        => 32,
        R_SQTDBL_REG_UPDS_CNTR_L        => 32,
        R_SQTDBL_REG_UPDS_CNTR_H        => 32,
        R_SQTDBL_RPT_UPDS_CNTR_L        => 32,
        R_SQTDBL_RPT_UPDS_CNTR_H        => 32,
        R_NVME_RD_BYTES_CNTR_L          => 32,
        R_NVME_RD_BYTES_CNTR_H          => 32,
        R_NVME_WR_BYTES_CNTR_L          => 32,
        R_NVME_WR_BYTES_CNTR_H          => 32,
        R_WRBUFF_USR_RDS_CNTR_L         => 32,
        R_WRBUFF_USR_RDS_CNTR_H         => 32,
        R_WRBUFF_USR_RD_BYTES_CNTR_L    => 32,
        R_WRBUFF_USR_RD_BYTES_CNTR_H    => 32,
        R_RDBUFF_DISP_RDS_CNTR_L        => 32,
        R_RDBUFF_DISP_RDS_CNTR_H        => 32,
        R_RDBUFF_DISP_RD_BYTES_CNTR_L   => 32,
        R_RDBUFF_DISP_RD_BYTES_CNTR_H   => 32,
        R_SQ_DISP_RDS_CNTR_L            => 32,
        R_SQ_DISP_RDS_CNTR_H            => 32,
        R_SQ_DISP_RD_BYTES_CNTR_L       => 32,
        R_SQ_DISP_RD_BYTES_CNTR_H       => 32,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => 32,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => 32
    );

    -- =============================================================================================
    -- PER-QUEUE 2D register block: base PER_Q_BASE, one PER_Q_STRIDE-byte slot per queue
    -- q = 0..NUM_QUEUES-1 (queue 0 is just q=0 of this block -- no special-casing). Each field is
    -- one NP_LUTRAM (ITEMS => LUTRAM_ITEMS, i.e. NUM_QUEUES rounded up to >= 2 -- see LUTRAM_ITEMS
    -- above), at PQ_OFFSETS(i) relative to PER_Q_BASE + q*PER_Q_STRIDE. PQ_SQTDBL..PQ_LBA_NUM_MASK
    -- (0..11) double as both the field's MI word index (PQ_OFFSETS(i) = i*4) and the index into
    -- pq_mi_dob below -- see pq_word_idx.
    -- =============================================================================================
    constant PER_Q_BASE   : natural := 16#200#;
    constant PER_Q_STRIDE : natural := 16#040#;
    constant PER_Q_BASE_SLOTS : natural := PER_Q_BASE / PER_Q_STRIDE;

    constant PQ_SQTDBL           : natural := 0;
    constant PQ_SQHDBL           : natural := 1;
    constant PQ_CQHDBL           : natural := 2;
    constant PQ_DBL_MASK         : natural := 3;
    constant PQ_SQTDBL_BADDR_L   : natural := 4;
    constant PQ_SQTDBL_BADDR_H   : natural := 5;
    constant PQ_CQHDBL_BADDR_L   : natural := 6;
    constant PQ_CQHDBL_BADDR_H   : natural := 7;
    constant PQ_LBA_SPACE_SIZE_L : natural := 8;
    constant PQ_LBA_SPACE_SIZE_H : natural := 9;
    constant PQ_NAMESPACE_ID     : natural := 10;
    constant PQ_LBA_NUM_MASK     : natural := 11;
    constant PQ_REGS             : natural := 12;

    -- Element width (16 or 32 bits) actually meaningful within each field's 32-bit MI word --
    -- indexed by the same PQ_* constants / pq_word_idx.
    constant PQ_REG_WIDTH : n_array_t(0 to PQ_REGS-1) := (
        PQ_SQTDBL           => 16,
        PQ_SQHDBL           => 16,
        PQ_CQHDBL           => 16,
        PQ_DBL_MASK         => 16,
        PQ_SQTDBL_BADDR_L   => 32,
        PQ_SQTDBL_BADDR_H   => 32,
        PQ_CQHDBL_BADDR_L   => 32,
        PQ_CQHDBL_BADDR_H   => 32,
        PQ_LBA_SPACE_SIZE_L => 32,
        PQ_LBA_SPACE_SIZE_H => 32,
        PQ_NAMESPACE_ID     => 32,
        PQ_LBA_NUM_MASK     => 16
    );

    -- =============================================================================================
    -- Input registers (COMMON)
    -- =============================================================================================
    -- A single system-wide "last completion" snapshot (whichever queue's CQE was processed most
    -- recently), used only to feed the aggregate CQE_ERROR_TRACKER below.
    signal last_cq_entry_inp_reg     : std_logic_vector(CQ_ENTRY_RANGE);

    -- =============================================================================================
    -- Control register fields
    -- =============================================================================================
    constant CTRL_DESIGN_EN      : natural := 0;
    constant CTRL_SAMPLE_CNTRS   : natural := 1;
    constant CTRL_CLR_ERR_MASK   : natural := 2;
    constant CTRL_RST_CNTRS      : natural := 3;
    -- Bit 4 (formerly CTRL_RPT_PTR_UPDATE, doorbell repeat-update enable) is retired: the doorbell
    -- repeat-update logic was removed (re-writing an unchanged doorbell is an NVMe "Invalid Doorbell
    -- Write Value"). The CONTROL bit is now ignored; kept reserved to preserve the register map.

    -- ============================================================================================
    -- Status register fields
    -- =============================================================================================
    constant STAT_DESIGN_RUN       : natural := 0;
    constant STAT_DLOGGER_RST_DONE : natural := 1;
    constant STAT_TAG_INIT_DONE    : natural := 2;

    -- =============================================================================================
    -- Start/stop logic
    -- ============================================================================================
    type run_state_t is (S_IDLE, S_START_CQP, S_START_OPC, S_RUNNING, S_STOP_CQP, S_STOP_OPC);
    signal run_state_reg       : run_state_t;
    signal run_state_next      : run_state_t;
    signal wr_mfb_block_en_reg : std_logic;
    signal wr_mfb_block_en_next : std_logic;
    signal design_running      : std_logic;

    -- =============================================================================================
    -- Register array declaratiions (COMMON only)
    -- =============================================================================================
    signal regs_arr : slv_array_t(REGS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal sample_regs_ins : slv_array_t(REGS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal cntr_incrs   : std_logic_vector(REGS-1 downto 0);
    signal cntr_incrs_sizes : slv_array_t(REGS-1 downto 0)(CNTR_WIDTH -1 downto 0);
    signal cntr_outs   : slv_array_t(REGS-1 downto 0)(CNTR_WIDTH -1 downto 0);

    -- =============================================================================================
    -- Miscellaneous
    -- =============================================================================================
    -- Increments for the counters of (un)successful completions
    signal succ_compl_cntr_incr      : std_logic;
    signal unsucc_compl_cntr_incr    : std_logic;
    -- The error mask of the previously captured errors with regards to the completion status
    signal cpl_err_mask              : std_logic_vector(ERR_MASK_W -1 downto 0);
    -- Next value of queue 0's SQTDBL pointer (anticipates the possible doorbell pointer rollover
    -- and is therefore masked), feeding the single COMMON sq_write_blocking perf-counter input
    -- below. Queue-0-only (not truly per-queue): this was already an approximation before this
    -- change (an OR-reduction across queues), and a genuinely per-queue version would need a
    -- dedicated extra read port per queue on the DBL_MASK LUTRAM for this one non-critical
    -- debug/perf statistic alone -- not worth the extra ports. At NUM_QUEUES=1 queue 0 IS the only
    -- queue, so this remains exactly correct there.
    signal sqtdbl_next_val_q0    : std_logic_vector(15 downto 0);
    -- Fixed qid=0 literal, used only to address DBL_MASK's dedicated sq_write_blocking read port
    -- (see pq_dbl_mask_i further down) -- SQTDBL/SQHDBL below are plain flop arrays instead (see
    -- their own comment), so queue 0's value is read directly, without any extra LUTRAM port.
    signal sq_write_blocking_qid0 : std_logic_vector(QID_W -1 downto 0) := (others => '0');
    signal dbl_mask_q0_dob        : std_logic_vector(MI_WIDTH -1 downto 0);

    -- =============================================================================================
    -- SQTDBL/SQHDBL/CQHDBL doorbell VALUE observation mirrors: kept as plain flop arrays (NOT
    -- NP_LUTRAM, unlike every other per-queue register below), because NP_LUTRAM has no bulk-clear
    -- port and these three are explicitly reset on every CQP_START_REQ_VLD pulse (a
    -- disable/re-enable cycle, not just power-up RST) -- matching the model/testbench's own
    -- expectation that a fresh completion-processor start begins these back at 0. At 16 bits x
    -- NUM_QUEUES each, the three of them are a comparatively small fraction of the per-queue flop
    -- footprint this whole change is meant to reduce (DBL_MASK/base-address/LBA_SPACE_SIZE/
    -- NAMESPACE_ID/LBA_NUM_MASK -- 32/64-bit fields -- are the ones moved to NP_LUTRAM).
    -- =============================================================================================
    signal sqtdbl_reg_arr : slv_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);
    signal sqhdbl_reg_arr : slv_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);
    signal cqhdbl_reg_arr : slv_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);

    -- =============================================================================================
    -- Data Logger related signals
    -- =============================================================================================
    constant PERF_CNTR_NUM            : positive := 2;
    constant EVCR_MAX_INTERVAL_CYCLES : positive := 2**24-1;

    signal dlogger_sw_rst             : std_logic;
    signal dlogger_sw_rst_done        : std_logic;
    signal data_logger_ctrlo          : std_logic_vector(log2(EVCR_MAX_INTERVAL_CYCLES+1) + 1 -1 downto 0);
    signal sq_write_blocking          : std_logic;
    signal cmd_disp_trigg_active_incr : std_logic;
    signal perf_cntr_incr_packed      : std_logic_vector(PERF_CNTR_NUM -1 downto 0);

    signal evctr_interval_cycles     : std_logic_vector(log2(EVCR_MAX_INTERVAL_CYCLES+1) -1 downto 0);
    signal evctr_interval_set        : std_logic;
    signal sqiops_val_current : std_logic_vector(log2((EVCR_MAX_INTERVAL_CYCLES+1) *2) -1 downto 0);
    signal sqiops_evctr_total_events : std_logic_vector(log2((EVCR_MAX_INTERVAL_CYCLES+1) *2) -1 downto 0);
    signal sqiops_evctr_total_cycles : std_logic_vector(log2(EVCR_MAX_INTERVAL_CYCLES+1) -1 downto 0);
    signal sqiops_evctr_update       : std_logic;

    -- =============================================================================================
    -- MI splitter tree
    -- =============================================================================================
    constant MI_SPLIT_PORTS : natural := 2;
    constant MI_SPLIT_BASES : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH-1 downto 0) := (
        0 => x"00000000",
        1 => x"00001000");
    constant MI_SPLIT_ADDR_MASK : std_logic_vector(MI_WIDTH-1 downto 0) := x"00001000";

    signal mi_split_dwr  : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_addr : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_be   : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH/8 -1 downto 0);
    signal mi_split_rd   : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_wr   : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_drd  : slv_array_t(MI_SPLIT_PORTS -1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_ardy : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);
    signal mi_split_drdy : std_logic_vector(MI_SPLIT_PORTS -1 downto 0);

    -- =============================================================================================
    -- Per-queue MI address decode: PER_Q_STRIDE (0x40) is a power of 2, so the queue index is the
    -- address bits above the per-slot field offset, and the field is the low 6 bits.
    -- =============================================================================================
    signal pq_valid    : std_logic;
    signal pq_qid      : std_logic_vector(QID_W -1 downto 0);
    signal pq_field    : std_logic_vector(5 downto 0);
    signal pq_word_idx : natural range 0 to 63;

    -- MI-port (read port 0) data-out of every per-queue field's own NP_LUTRAM -- see pq_word_idx.
    signal pq_mi_dob : slv_array_t(0 to PQ_REGS-1)(MI_WIDTH -1 downto 0);
    -- MI write-enable per per-queue field (pq_we(PQ_XXX)): a conditional-expression port map
    -- actual (WE(0) => '1' when ... else '0') is not accepted by nvc, so this is computed as an
    -- ordinary concurrent signal assignment instead and referenced by name in each NP_LUTRAM's own
    -- port map below.
    signal pq_we : std_logic_vector(0 to PQ_REGS-1);

    -- One bit per doorbell (indices 0..NUM_QUEUES-1 = CQHDBL[q], NUM_QUEUES..2*NUM_QUEUES-1 =
    -- SQTDBL[q]) -- see DBL_ENABLED's port comment.
    signal dbl_enabled_reg : std_logic_vector(2*NUM_QUEUES -1 downto 0);

    -- =============================================================================================
    -- Per-queue LUTRAM DI/WE/ADDRA/ADDRB/DOB signals: every NP_LUTRAM port below is associated as
    -- a WHOLE array signal (never an indexed or sliced formal element -- e.g. never "DOB(1) =>" or
    -- "DOB(1)(15 downto 0) =>" directly in a port map). Vivado XST rejects mixing a sliced formal
    -- element with a full one on the same unconstrained-element array port (nvc accepts it, XST
    -- does not); building the full array here and slicing/assigning element-by-element in ordinary
    -- concurrent signal assignments around the instance -- exactly like
    -- tx_dma_sw_manager.vhd's reg_di/reg_we/reg_addra/reg_addrb/reg_dob -- avoids the whole
    -- class of issue.
    -- =============================================================================================
    signal dbl_mask_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal dbl_mask_we    : std_logic_vector(0 downto 0);
    signal dbl_mask_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal dbl_mask_addrb : slv_array_t(3 downto 0)(QID_W -1 downto 0);
    signal dbl_mask_dob   : slv_array_t(3 downto 0)(MI_WIDTH -1 downto 0);

    signal lba_space_size_l_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal lba_space_size_l_we    : std_logic_vector(0 downto 0);
    signal lba_space_size_l_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal lba_space_size_l_addrb : slv_array_t(2 downto 0)(QID_W -1 downto 0);
    signal lba_space_size_l_dob   : slv_array_t(2 downto 0)(MI_WIDTH -1 downto 0);

    signal lba_space_size_h_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal lba_space_size_h_we    : std_logic_vector(0 downto 0);
    signal lba_space_size_h_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal lba_space_size_h_addrb : slv_array_t(2 downto 0)(QID_W -1 downto 0);
    signal lba_space_size_h_dob   : slv_array_t(2 downto 0)(MI_WIDTH -1 downto 0);

    signal namespace_id_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal namespace_id_we    : std_logic_vector(0 downto 0);
    signal namespace_id_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal namespace_id_addrb : slv_array_t(1 downto 0)(QID_W -1 downto 0);
    signal namespace_id_dob   : slv_array_t(1 downto 0)(MI_WIDTH -1 downto 0);

    signal lba_num_mask_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal lba_num_mask_we    : std_logic_vector(0 downto 0);
    signal lba_num_mask_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal lba_num_mask_addrb : slv_array_t(2 downto 0)(QID_W -1 downto 0);
    signal lba_num_mask_dob   : slv_array_t(2 downto 0)(MI_WIDTH -1 downto 0);

    -- SQTDBL_BADDR_L/H, CQHDBL_BADDR_L/H DI/WE/ADDRA (ADDRB/DOB are already whole-port, declared
    -- locally inside their own block statements further down).
    signal sqtdbl_baddr_l_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal sqtdbl_baddr_l_we    : std_logic_vector(0 downto 0);
    signal sqtdbl_baddr_l_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal sqtdbl_baddr_h_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal sqtdbl_baddr_h_we    : std_logic_vector(0 downto 0);
    signal sqtdbl_baddr_h_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal cqhdbl_baddr_l_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal cqhdbl_baddr_l_we    : std_logic_vector(0 downto 0);
    signal cqhdbl_baddr_l_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
    signal cqhdbl_baddr_h_di    : slv_array_t(0 downto 0)(MI_WIDTH -1 downto 0);
    signal cqhdbl_baddr_h_we    : std_logic_vector(0 downto 0);
    signal cqhdbl_baddr_h_addra : slv_array_t(0 downto 0)(QID_W -1 downto 0);
begin
    assert (MPS <= 4096)
        report "NVME_CPL_SW_MANAGER: The set size of MPS exceeded the maximum defined by the PCIe Specification (up to 4096 B, current is " &
        to_string(MPS) & ")"
        severity FAILURE;

    assert (MRRS <= 4096)
        report "NVME_CPL_SW_MANAGER: The set size of MRRS exceeded the maximum defined by the PCIe Specification (4096 B, current is " &
        to_string(MRRS) & ")"
        severity FAILURE;

    assert (PER_Q_BASE + NUM_QUEUES*PER_Q_STRIDE <= 2**ADDR_LENGTH)
        report "NVME_SW_MANAGER: PER_Q_BASE + NUM_QUEUES*PER_Q_STRIDE exceeds the ADDR_LENGTH-bit MI register address space"
        severity FAILURE;

    -- The status information gets sampled only when the status update is actually done. Single
    -- process, dynamically indexed by CQHDBL_QID -- a single, unambiguous driver of the whole
    -- sqhdbl_reg_arr/cqhdbl_reg_arr arrays (see the note near dbl_reg_wr_g in dbl_updater.vhd for
    -- why this must stay one process, not several).
    inp_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or dlogger_sw_rst = '1' or CQP_START_REQ_VLD = '1') then
                sqhdbl_reg_arr         <= (others => (others => '0'));
                cqhdbl_reg_arr         <= (others => (others => '0'));
                last_cq_entry_inp_reg  <= (others => '0');
                succ_compl_cntr_incr   <= '0';
                unsucc_compl_cntr_incr <= '0';
            else
                succ_compl_cntr_incr   <= '0';
                unsucc_compl_cntr_incr <= '0';

                if (STATUS_UPD_VLD = '1') then
                    sqhdbl_reg_arr(to_integer(unsigned(CQHDBL_QID))) <= SQHDBL_DATA;
                    cqhdbl_reg_arr(to_integer(unsigned(CQHDBL_QID))) <= CQHDBL_DATA;
                    last_cq_entry_inp_reg <= LAST_CQ_ENTRY;

                    if (LAST_CQ_ENTRY(CQ_ENTRY_SC_TYPE) = SCT_GENERIC_CMD and LAST_CQ_ENTRY(CQ_ENTRY_STAT_CODE) = SC_SUCCESS) then
                        succ_compl_cntr_incr <= '1';
                    else
                        unsucc_compl_cntr_incr <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Single process, dynamically indexed by SQTDBL_QID -- same single-driver rule as inp_reg_p
    -- above.
    sqtdbl_reg_p: process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or dlogger_sw_rst = '1' or CQP_START_REQ_VLD = '1') then
                sqtdbl_reg_arr <= (others => (others => '0'));
            elsif (SQES_DISP_INCR = '1') then
                sqtdbl_reg_arr(to_integer(unsigned(SQTDBL_QID))) <= SQTDBL_DATA;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- MI Access logic
    -- =============================================================================================
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

            RX_DWR  => MI_DWR,
            RX_MWR  => (others => '0'),
            RX_ADDR => MI_ADDR,
            RX_BE   => MI_BE,
            RX_RD   => MI_RD,
            RX_WR   => MI_WR,
            RX_ARDY => MI_ARDY,
            RX_DRD  => MI_DRD,
            RX_DRDY => MI_DRDY,

            TX_DWR  => mi_split_dwr,
            TX_MWR  => open,
            TX_ADDR => mi_split_addr,
            TX_BE   => mi_split_be,
            TX_RD   => mi_split_rd,
            TX_WR   => mi_split_wr,
            TX_ARDY => mi_split_ardy,
            TX_DRD  => mi_split_drd,
            TX_DRDY => mi_split_drdy);

    mi_split_ardy(0) <= mi_split_rd(0) or mi_split_wr(0);

    -- =============================================================================================
    -- Per-queue MI address decode (COMMON register range vs PER_Q_BASE block). Combinational, so
    -- it settles the SAME cycle as mi_split_addr(0)/reg_sel_addr, matching read_from_regs_p's own
    -- COMMON-register decode timing exactly.
    -- =============================================================================================
    pq_mi_decode_p : process (all)
        variable addr_slots_v : natural;
    begin
        pq_field <= mi_split_addr(0)(5 downto 0);
        addr_slots_v := to_integer(unsigned(mi_split_addr(0)(ADDR_LENGTH-1 downto 6)));

        if (addr_slots_v >= PER_Q_BASE_SLOTS and (addr_slots_v - PER_Q_BASE_SLOTS) < NUM_QUEUES) then
            pq_valid <= '1';
            pq_qid   <= std_logic_vector(to_unsigned(addr_slots_v - PER_Q_BASE_SLOTS, QID_W));
        else
            pq_valid <= '0';
            pq_qid   <= (others => '0');
        end if;
    end process;

    pq_word_idx <= to_integer(unsigned(pq_field(5 downto 2)));

    pq_we_g : for i in 0 to PQ_REGS -1 generate
        pq_we(i) <= '1' when (pq_valid = '1' and mi_split_wr(0) = '1' and pq_word_idx = i) else '0';
    end generate;

    regs_g : for reg_idx in 0 to (REGS-1) generate
        wr_en_g : if (WR_EN(reg_idx) and not REG_IS_CNTR(reg_idx)) generate
            reg_type_g : if (reg_idx = R_CONTROL) generate
                ctrl_reg_wr_p : process (CLK)
                begin
                    if (rising_edge(CLK)) then
                        if (RST = '1' or dlogger_sw_rst = '1') then
                            regs_arr(reg_idx) <= (others => '0');
                        else
                            regs_arr(reg_idx)(CTRL_SAMPLE_CNTRS)   <= '0';
                            regs_arr(reg_idx)(CTRL_CLR_ERR_MASK)   <= '0';
                            regs_arr(reg_idx)(CTRL_RST_CNTRS)      <= '0';

                            if (mi_split_addr(0)(ADDR_LENGTH -1 downto 0) = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH)) and mi_split_wr(0) = '1') then
                                regs_arr(reg_idx)(REG_WIDTH(reg_idx) -1 downto 0) <= mi_split_dwr(0)(REG_WIDTH(reg_idx)-1 downto 0);
                            end if;
                        end if;
                    end if;
                end process;

            else generate
                generic_reg_wr_p : process (CLK)
                begin
                    if (rising_edge(CLK)) then
                        if (RST = '1') then
                            regs_arr(reg_idx) <= (others => '0');
                        elsif (mi_split_addr(0)(ADDR_LENGTH -1 downto 0) = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH)) and mi_split_wr(0) = '1') then
                            regs_arr(reg_idx)(REG_WIDTH(reg_idx) -1 downto 0) <= mi_split_dwr(0)(REG_WIDTH(reg_idx)-1 downto 0);
                        end if;
                    end if;
                end process;
            end generate;
        end generate;

        sample_reg_g : if (STROBE_EN(reg_idx)) generate
            cntr_sample_reg_p : process (CLK)
            begin
                if (rising_edge(CLK)) then
                    if (RST = '1' or regs_arr(R_CONTROL)(CTRL_RST_CNTRS) = '1') then
                        regs_arr(reg_idx) <= (others => '0');
                    elsif (regs_arr(R_CONTROL)(CTRL_SAMPLE_CNTRS) = '1') then
                        regs_arr(reg_idx) <= sample_regs_ins(reg_idx);
                    end if;
                end if;
            end process;
        end generate;

        cntr_g : if (REG_IS_CNTR(reg_idx)) generate
            -- As set by REG_IS_CNTR constant, initialize only that many counters that are needed which
            -- is not the total amount of counter registers
            cntr_i : entity work.STAT_CNTR
            generic map (CNTR_WIDTH => CNTR_WIDTH)
            port map (CLK => CLK, RST => RST or regs_arr(R_CONTROL)(CTRL_RST_CNTRS),
                CE        => cntr_incrs(reg_idx),
                INCR_VAL  => cntr_incrs_sizes(reg_idx),
                OUT_COUNT => cntr_outs(reg_idx));
        end generate;
    end generate;

    -- =============================================================================================
    -- Connecting status inputs to registers
    -- =============================================================================================
    design_running <= '1' when (run_state_reg = S_RUNNING) else '0';

    regs_arr(R_STATUS) <= (
        STAT_DESIGN_RUN        => design_running,
        STAT_DLOGGER_RST_DONE  => dlogger_sw_rst_done,
        STAT_TAG_INIT_DONE     => TAG_INIT_DONE,
        others => '0');

    (regs_arr(R_CPL_ERR_MASK_H), regs_arr(R_CPL_ERR_MASK_L))              <= cpl_err_mask;
    regs_arr(R_TAG_FIFO_STATUS)(REG_WIDTH(R_TAG_FIFO_STATUS) -1 downto 0) <= TAG_FIFO_STATUS;

    -- =============================================================================================
    -- PER-QUEUE register storage: one NP_LUTRAM (ITEMS => LUTRAM_ITEMS) per field. READ_PORTS is
    -- sized to the number of distinct PHYSICAL modules that read that field (never NUM_QUEUES):
    -- port 0 of both WRITE and READ is always MI; further ports are the actual consumers, each
    -- addressed by that consumer's own qid on its own read port.
    -- =============================================================================================

    -- ---- SQTDBL/SQHDBL/CQHDBL doorbell VALUE observation mirrors -----------------------------
    -- Plain flop arrays (sqtdbl_reg_arr/sqhdbl_reg_arr/cqhdbl_reg_arr, written in inp_reg_p/
    -- sqtdbl_reg_p above) -- see their own declaration comment for why NOT NP_LUTRAM. Read back
    -- for MI directly here, combinationally addressed by pq_qid (same timing as every other
    -- field's MI-port NP_LUTRAM read below).
    pq_mi_dob(PQ_SQTDBL) <= (MI_WIDTH -1 downto 16 => '0') & sqtdbl_reg_arr(to_integer(unsigned(pq_qid)));
    pq_mi_dob(PQ_SQHDBL) <= (MI_WIDTH -1 downto 16 => '0') & sqhdbl_reg_arr(to_integer(unsigned(pq_qid)));
    pq_mi_dob(PQ_CQHDBL) <= (MI_WIDTH -1 downto 16 => '0') & cqhdbl_reg_arr(to_integer(unsigned(pq_qid)));

    -- ---- DBL_MASK ------------------------------------------------------------------------------
    -- WRITE_PORTS=1 (MI). READ_PORTS=4: 0=MI, 1=NVME_CMD_DISPATCHER (via SQTDBL_QID, the dispatch
    -- qid), 2=CQE_PROCESSOR (via DBL_MASK_RD_QID, resp_qidx), 3=sq_write_blocking (fixed qid=0).
    dbl_mask_di(0)    <= mi_split_dwr(0);
    dbl_mask_we(0)    <= pq_we(PQ_DBL_MASK);
    dbl_mask_addra(0) <= pq_qid;
    dbl_mask_addrb(0) <= pq_qid;
    dbl_mask_addrb(1) <= SQTDBL_QID;
    dbl_mask_addrb(2) <= DBL_MASK_RD_QID;
    dbl_mask_addrb(3) <= sq_write_blocking_qid0;

    pq_dbl_mask_i : entity work.NP_LUTRAM
        generic map (
            DATA_WIDTH => MI_WIDTH,
            ITEMS => LUTRAM_ITEMS,
            WRITE_PORTS => 1,
            READ_PORTS => 4,
            DEVICE => DEVICE
        )
        port map (
            WCLK  => CLK,
            DI    => dbl_mask_di,
            WE    => dbl_mask_we,
            ADDRA => dbl_mask_addra,
            ADDRB => dbl_mask_addrb,
            DOB   => dbl_mask_dob
        );

    pq_mi_dob(PQ_DBL_MASK) <= dbl_mask_dob(0);
    DBL_MASK_C2N           <= dbl_mask_dob(1)(15 downto 0);
    DBL_MASK_N2C           <= dbl_mask_dob(2)(15 downto 0);
    dbl_mask_q0_dob        <= dbl_mask_dob(3);

    -- ---- SQTDBL_BADDR_L/H, CQHDBL_BADDR_L/H -----------------------------------------------------
    -- WRITE_PORTS=1 (MI). READ_PORTS = 1 (MI) + MFB_REGIONS (DBL_UPDATER's dispatch, one lookup
    -- per region -- see DBL_UPDATER's own port comment for why not just 1).
    sqtdbl_baddr_l_g : block is
        signal addrb : slv_array_t(MFB_REGIONS downto 0)(QID_W -1 downto 0);
        signal dob   : slv_array_t(MFB_REGIONS downto 0)(MI_WIDTH -1 downto 0);
    begin
        addrb(0) <= pq_qid;
        addrb_g : for rgn in 0 to MFB_REGIONS -1 generate
            addrb(1+rgn) <= SQTDBL_BADDR_RD_QID(rgn);
        end generate;
        dob_g : for rgn in 0 to MFB_REGIONS -1 generate
            SQTDBL_BADDR_RD_DATA(rgn)(31 downto 0) <= dob(1+rgn);
        end generate;

        sqtdbl_baddr_l_di(0)    <= mi_split_dwr(0);
        sqtdbl_baddr_l_we(0)    <= pq_we(PQ_SQTDBL_BADDR_L);
        sqtdbl_baddr_l_addra(0) <= pq_qid;

        pq_sqtdbl_baddr_l_i : entity work.NP_LUTRAM
            generic map (
                DATA_WIDTH => MI_WIDTH,
                ITEMS => LUTRAM_ITEMS,
                WRITE_PORTS => 1,
                READ_PORTS => 1 + MFB_REGIONS,
                DEVICE => DEVICE
            )
            port map (
                WCLK  => CLK,
                DI    => sqtdbl_baddr_l_di,
                WE    => sqtdbl_baddr_l_we,
                ADDRA => sqtdbl_baddr_l_addra,
                ADDRB => addrb,
                DOB   => dob
            );
        pq_mi_dob(PQ_SQTDBL_BADDR_L) <= dob(0);
    end block sqtdbl_baddr_l_g;

    sqtdbl_baddr_h_g : block is
        signal addrb : slv_array_t(MFB_REGIONS downto 0)(QID_W -1 downto 0);
        signal dob   : slv_array_t(MFB_REGIONS downto 0)(MI_WIDTH -1 downto 0);
    begin
        addrb(0) <= pq_qid;
        addrb_g : for rgn in 0 to MFB_REGIONS -1 generate
            addrb(1+rgn) <= SQTDBL_BADDR_RD_QID(rgn);
        end generate;
        dob_g : for rgn in 0 to MFB_REGIONS -1 generate
            SQTDBL_BADDR_RD_DATA(rgn)(63 downto 32) <= dob(1+rgn);
        end generate;

        sqtdbl_baddr_h_di(0)    <= mi_split_dwr(0);
        sqtdbl_baddr_h_we(0)    <= pq_we(PQ_SQTDBL_BADDR_H);
        sqtdbl_baddr_h_addra(0) <= pq_qid;

        pq_sqtdbl_baddr_h_i : entity work.NP_LUTRAM
            generic map (
                DATA_WIDTH => MI_WIDTH,
                ITEMS => LUTRAM_ITEMS,
                WRITE_PORTS => 1,
                READ_PORTS => 1 + MFB_REGIONS,
                DEVICE => DEVICE
            )
            port map (
                WCLK  => CLK,
                DI    => sqtdbl_baddr_h_di,
                WE    => sqtdbl_baddr_h_we,
                ADDRA => sqtdbl_baddr_h_addra,
                ADDRB => addrb,
                DOB   => dob
            );
        pq_mi_dob(PQ_SQTDBL_BADDR_H) <= dob(0);
    end block sqtdbl_baddr_h_g;

    cqhdbl_baddr_l_g : block is
        signal addrb : slv_array_t(MFB_REGIONS downto 0)(QID_W -1 downto 0);
        signal dob   : slv_array_t(MFB_REGIONS downto 0)(MI_WIDTH -1 downto 0);
    begin
        addrb(0) <= pq_qid;
        addrb_g : for rgn in 0 to MFB_REGIONS -1 generate
            addrb(1+rgn) <= CQHDBL_BADDR_RD_QID(rgn);
        end generate;
        dob_g : for rgn in 0 to MFB_REGIONS -1 generate
            CQHDBL_BADDR_RD_DATA(rgn)(31 downto 0) <= dob(1+rgn);
        end generate;

        cqhdbl_baddr_l_di(0)    <= mi_split_dwr(0);
        cqhdbl_baddr_l_we(0)    <= pq_we(PQ_CQHDBL_BADDR_L);
        cqhdbl_baddr_l_addra(0) <= pq_qid;

        pq_cqhdbl_baddr_l_i : entity work.NP_LUTRAM
            generic map (
                DATA_WIDTH => MI_WIDTH,
                ITEMS => LUTRAM_ITEMS,
                WRITE_PORTS => 1,
                READ_PORTS => 1 + MFB_REGIONS,
                DEVICE => DEVICE
            )
            port map (
                WCLK  => CLK,
                DI    => cqhdbl_baddr_l_di,
                WE    => cqhdbl_baddr_l_we,
                ADDRA => cqhdbl_baddr_l_addra,
                ADDRB => addrb,
                DOB   => dob
            );
        pq_mi_dob(PQ_CQHDBL_BADDR_L) <= dob(0);
    end block cqhdbl_baddr_l_g;

    cqhdbl_baddr_h_g : block is
        signal addrb : slv_array_t(MFB_REGIONS downto 0)(QID_W -1 downto 0);
        signal dob   : slv_array_t(MFB_REGIONS downto 0)(MI_WIDTH -1 downto 0);
    begin
        addrb(0) <= pq_qid;
        addrb_g : for rgn in 0 to MFB_REGIONS -1 generate
            addrb(1+rgn) <= CQHDBL_BADDR_RD_QID(rgn);
        end generate;
        dob_g : for rgn in 0 to MFB_REGIONS -1 generate
            CQHDBL_BADDR_RD_DATA(rgn)(63 downto 32) <= dob(1+rgn);
        end generate;

        cqhdbl_baddr_h_di(0)    <= mi_split_dwr(0);
        cqhdbl_baddr_h_we(0)    <= pq_we(PQ_CQHDBL_BADDR_H);
        cqhdbl_baddr_h_addra(0) <= pq_qid;

        pq_cqhdbl_baddr_h_i : entity work.NP_LUTRAM
            generic map (
                DATA_WIDTH => MI_WIDTH,
                ITEMS => LUTRAM_ITEMS,
                WRITE_PORTS => 1,
                READ_PORTS => 1 + MFB_REGIONS,
                DEVICE => DEVICE
            )
            port map (
                WCLK  => CLK,
                DI    => cqhdbl_baddr_h_di,
                WE    => cqhdbl_baddr_h_we,
                ADDRA => cqhdbl_baddr_h_addra,
                ADDRB => addrb,
                DOB   => dob
            );
        pq_mi_dob(PQ_CQHDBL_BADDR_H) <= dob(0);
    end block cqhdbl_baddr_h_g;

    -- ---- LBA_SPACE_SIZE_L/H ----------------------------------------------------------------------
    -- WRITE_PORTS=1 (MI). READ_PORTS=3: 0=MI, 1=OP_CTRL (via LBA_CHECK_QID, the admitted command's
    -- own qid), 2=NVME_CMD_DISPATCHER (via SQTDBL_QID, the dispatch qid -- NVME_CMD_DISPATCHER
    -- ALSO caps a command's LBA_NUM against LBA_SPACE_SIZE at dispatch time, independently of
    -- OP_CTRL's own admission-time OOR check).
    lba_space_size_l_di(0)    <= mi_split_dwr(0);
    lba_space_size_l_we(0)    <= pq_we(PQ_LBA_SPACE_SIZE_L);
    lba_space_size_l_addra(0) <= pq_qid;
    lba_space_size_l_addrb(0) <= pq_qid;
    lba_space_size_l_addrb(1) <= LBA_CHECK_QID;
    lba_space_size_l_addrb(2) <= SQTDBL_QID;

    pq_lba_space_size_l_i : entity work.NP_LUTRAM
        generic map (
            DATA_WIDTH => MI_WIDTH,
            ITEMS => LUTRAM_ITEMS,
            WRITE_PORTS => 1,
            READ_PORTS => 3,
            DEVICE => DEVICE
        )
        port map (
            WCLK  => CLK,
            DI    => lba_space_size_l_di,
            WE    => lba_space_size_l_we,
            ADDRA => lba_space_size_l_addra,
            ADDRB => lba_space_size_l_addrb,
            DOB   => lba_space_size_l_dob
        );

    pq_mi_dob(PQ_LBA_SPACE_SIZE_L)  <= lba_space_size_l_dob(0);
    LBA_SPACE_SIZE_OPC(31 downto 0) <= lba_space_size_l_dob(1);
    LBA_SPACE_SIZE_C2N(31 downto 0) <= lba_space_size_l_dob(2);

    lba_space_size_h_di(0)    <= mi_split_dwr(0);
    lba_space_size_h_we(0)    <= pq_we(PQ_LBA_SPACE_SIZE_H);
    lba_space_size_h_addra(0) <= pq_qid;
    lba_space_size_h_addrb(0) <= pq_qid;
    lba_space_size_h_addrb(1) <= LBA_CHECK_QID;
    lba_space_size_h_addrb(2) <= SQTDBL_QID;

    pq_lba_space_size_h_i : entity work.NP_LUTRAM
        generic map (
            DATA_WIDTH => MI_WIDTH,
            ITEMS => LUTRAM_ITEMS,
            WRITE_PORTS => 1,
            READ_PORTS => 3,
            DEVICE => DEVICE
        )
        port map (
            WCLK  => CLK,
            DI    => lba_space_size_h_di,
            WE    => lba_space_size_h_we,
            ADDRA => lba_space_size_h_addra,
            ADDRB => lba_space_size_h_addrb,
            DOB   => lba_space_size_h_dob
        );

    pq_mi_dob(PQ_LBA_SPACE_SIZE_H)   <= lba_space_size_h_dob(0);
    LBA_SPACE_SIZE_OPC(63 downto 32) <= lba_space_size_h_dob(1);
    LBA_SPACE_SIZE_C2N(63 downto 32) <= lba_space_size_h_dob(2);

    -- ---- NAMESPACE_ID ---------------------------------------------------------------------------
    -- WRITE_PORTS=1 (MI). READ_PORTS=2: 0=MI, 1=NVME_CMD_DISPATCHER (via SQTDBL_QID). Previously
    -- hardcoded to x"00000001" -- now a real writable register; software must program it.
    namespace_id_di(0)    <= mi_split_dwr(0);
    namespace_id_we(0)    <= pq_we(PQ_NAMESPACE_ID);
    namespace_id_addra(0) <= pq_qid;
    namespace_id_addrb(0) <= pq_qid;
    namespace_id_addrb(1) <= SQTDBL_QID;

    pq_namespace_id_i : entity work.NP_LUTRAM
        generic map (
            DATA_WIDTH => MI_WIDTH,
            ITEMS => LUTRAM_ITEMS,
            WRITE_PORTS => 1,
            READ_PORTS => 2,
            DEVICE => DEVICE
        )
        port map (
            WCLK  => CLK,
            DI    => namespace_id_di,
            WE    => namespace_id_we,
            ADDRA => namespace_id_addra,
            ADDRB => namespace_id_addrb,
            DOB   => namespace_id_dob
        );

    pq_mi_dob(PQ_NAMESPACE_ID) <= namespace_id_dob(0);
    NAMESPACE_ID_C2N           <= namespace_id_dob(1);

    -- ---- LBA_NUM_MASK -----------------------------------------------------------------------------
    -- WRITE_PORTS=1 (MI). READ_PORTS=3: 0=MI, 1=OP_CTRL (via LBA_CHECK_QID), 2=NVME_CMD_DISPATCHER
    -- (via SQTDBL_QID) -- same reasoning as LBA_SPACE_SIZE above.
    lba_num_mask_di(0)    <= mi_split_dwr(0);
    lba_num_mask_we(0)    <= pq_we(PQ_LBA_NUM_MASK);
    lba_num_mask_addra(0) <= pq_qid;
    lba_num_mask_addrb(0) <= pq_qid;
    lba_num_mask_addrb(1) <= LBA_CHECK_QID;
    lba_num_mask_addrb(2) <= SQTDBL_QID;

    pq_lba_num_mask_i : entity work.NP_LUTRAM
        generic map (
            DATA_WIDTH => MI_WIDTH,
            ITEMS => LUTRAM_ITEMS,
            WRITE_PORTS => 1,
            READ_PORTS => 3,
            DEVICE => DEVICE
        )
        port map (
            WCLK  => CLK,
            DI    => lba_num_mask_di,
            WE    => lba_num_mask_we,
            ADDRA => lba_num_mask_addra,
            ADDRB => lba_num_mask_addrb,
            DOB   => lba_num_mask_dob
        );

    pq_mi_dob(PQ_LBA_NUM_MASK) <= lba_num_mask_dob(0);
    LBA_NUM_MASK_OPC           <= lba_num_mask_dob(1)(15 downto 0);
    LBA_NUM_MASK_C2N           <= lba_num_mask_dob(2)(15 downto 0);

    -- =============================================================================================
    -- Per-queue base-address "enabled" sticky flags -- see DBL_ENABLED's port comment. Single
    -- process, dynamically indexed by pq_qid -- a single, unambiguous driver of the whole
    -- dbl_enabled_reg array (see the note near dbl_reg_wr_g in dbl_updater.vhd for the general
    -- rule this follows).
    -- =============================================================================================
    dbl_enabled_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                dbl_enabled_reg <= (others => '0');
            elsif (pq_valid = '1' and mi_split_wr(0) = '1' and mi_split_dwr(0) /= x"00000000") then
                if (pq_word_idx = PQ_CQHDBL_BADDR_L or pq_word_idx = PQ_CQHDBL_BADDR_H) then
                    dbl_enabled_reg(to_integer(unsigned(pq_qid))) <= '1';
                elsif (pq_word_idx = PQ_SQTDBL_BADDR_L or pq_word_idx = PQ_SQTDBL_BADDR_H) then
                    dbl_enabled_reg(NUM_QUEUES + to_integer(unsigned(pq_qid))) <= '1';
                end if;
            end if;
        end if;
    end process;

    DBL_ENABLED <= dbl_enabled_reg;

    -- =============================================================================================
    -- Connecting counter increment inputs to system inputs
    -- =============================================================================================
    cntr_incrs(R_SQE_DISP_CNTR_L)                       <= SQES_DISP_INCR;
    cntr_incrs_sizes(R_SQE_DISP_CNTR_L)                 <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_CQE_PROC_CNTR_L)                       <= STATUS_UPD_VLD;
    cntr_incrs_sizes(R_CQE_PROC_CNTR_L)                 <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_PCIE_RDS_CNTR_L)                       <= or PCIE_RD_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_RDS_CNTR_L)                 <= std_logic_vector(resize(unsigned(PCIE_RD_REQ_TOTAL_INCR), CNTR_WIDTH));
    cntr_incrs(R_PCIE_RD_BYTES_CNTR_L)                  <= or PCIE_RD_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_RD_BYTES_CNTR_L)            <= std_logic_vector(resize(unsigned(PCIE_RD_REQ_TOTAL_BYTES), CNTR_WIDTH));
    cntr_incrs(R_PCIE_WRS_CNTR_L)                       <= or PCIE_WR_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_WRS_CNTR_L)                 <= std_logic_vector(resize(unsigned(PCIE_WR_REQ_TOTAL_INCR), CNTR_WIDTH));
    cntr_incrs(R_PCIE_WR_BYTES_CNTR_L)                  <= or PCIE_WR_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_WR_BYTES_CNTR_L)            <= std_logic_vector(resize(unsigned(PCIE_WR_REQ_TOTAL_BYTES), CNTR_WIDTH));
    cntr_incrs(R_SQ_PCIE_RDS_CNTR_L)                    <= or PCIE_RD_REQ_INCRS(SQ_BAR_ID_INT);
    cntr_incrs_sizes(R_SQ_PCIE_RDS_CNTR_L)              <= std_logic_vector(resize(unsigned(PCIE_RD_REQ_INCRS(SQ_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_SQ_PCIE_RD_BYTES_CNTR_L)               <= or PCIE_RD_REQ_INCRS(SQ_BAR_ID_INT);
    cntr_incrs_sizes(R_SQ_PCIE_RD_BYTES_CNTR_L)         <= std_logic_vector(resize(unsigned(PCIE_RD_REQ_BYTES(SQ_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_SUCC_COMPL_CNTR_L)                     <= succ_compl_cntr_incr;
    cntr_incrs_sizes(R_SUCC_COMPL_CNTR_L)               <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_UNSUCC_COMPL_CNTR_L)                   <= unsucc_compl_cntr_incr;
    cntr_incrs_sizes(R_UNSUCC_COMPL_CNTR_L)             <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_RDBUFF_PCIE_RDS_CNTR_L)                <= or PCIE_RD_REQ_INCRS(RDBUFF_BAR_ID_INT);
    cntr_incrs_sizes(R_RDBUFF_PCIE_RDS_CNTR_L)          <= std_logic_vector(resize(unsigned(PCIE_RD_REQ_INCRS(RDBUFF_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_RDBUFF_PCIE_RD_BYTES_CNTR_L)           <= or PCIE_RD_REQ_INCRS(RDBUFF_BAR_ID_INT);
    cntr_incrs_sizes(R_RDBUFF_PCIE_RD_BYTES_CNTR_L)     <= std_logic_vector(resize(unsigned(PCIE_RD_REQ_BYTES(RDBUFF_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_WRBUFF_PCIE_WRS_CNTR_L)                <= or PCIE_WR_REQ_INCRS(WRBUFF_BAR_ID_INT);
    cntr_incrs_sizes(R_WRBUFF_PCIE_WRS_CNTR_L)          <= std_logic_vector(resize(unsigned(PCIE_WR_REQ_INCRS(WRBUFF_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_WRBUFF_PCIE_WR_BYTES_CNTR_L)           <= or PCIE_WR_REQ_INCRS(WRBUFF_BAR_ID_INT);
    cntr_incrs_sizes(R_WRBUFF_PCIE_WR_BYTES_CNTR_L)     <= std_logic_vector(resize(unsigned(PCIE_WR_REQ_BYTES(WRBUFF_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_CQ_PCIE_WRS_CNTR_L)                    <= or PCIE_WR_REQ_INCRS(CQ_BAR_ID_INT);
    cntr_incrs_sizes(R_CQ_PCIE_WRS_CNTR_L)              <= std_logic_vector(resize(unsigned(PCIE_WR_REQ_INCRS(CQ_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_CQ_PCIE_WR_BYTES_CNTR_L)               <= or PCIE_WR_REQ_INCRS(CQ_BAR_ID_INT);
    cntr_incrs_sizes(R_CQ_PCIE_WR_BYTES_CNTR_L)         <= std_logic_vector(resize(unsigned(PCIE_WR_REQ_BYTES(CQ_BAR_ID_INT)), CNTR_WIDTH));
    cntr_incrs(R_CQHDBL_REG_UPDS_CNTR_L)                <= CQHDBL_REG_UPD_DISP;
    cntr_incrs_sizes(R_CQHDBL_REG_UPDS_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    -- Reserved counter (doorbell repeat-update removed); kept at 0 to preserve the register map.
    cntr_incrs(R_CQHDBL_RPT_UPDS_CNTR_L)                <= '0';
    cntr_incrs_sizes(R_CQHDBL_RPT_UPDS_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_SQTDBL_REG_UPDS_CNTR_L)                <= SQTDBL_REG_UPD_DISP;
    cntr_incrs_sizes(R_SQTDBL_REG_UPDS_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    -- Reserved counter (doorbell repeat-update removed); kept at 0 to preserve the register map.
    cntr_incrs(R_SQTDBL_RPT_UPDS_CNTR_L)                <= '0';
    cntr_incrs_sizes(R_SQTDBL_RPT_UPDS_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_NVME_RD_BYTES_CNTR_L)                  <= SQES_DISP_INCR when SQES_DISP_TYPE = RD_CMD_OPCODE else '0';
    cntr_incrs_sizes(R_NVME_RD_BYTES_CNTR_L)            <= std_logic_vector(resize(unsigned(SQES_DISP_BYTES), CNTR_WIDTH));
    cntr_incrs(R_NVME_WR_BYTES_CNTR_L)                  <= SQES_DISP_INCR when SQES_DISP_TYPE = WR_CMD_OPCODE else '0';
    cntr_incrs_sizes(R_NVME_WR_BYTES_CNTR_L)            <= std_logic_vector(resize(unsigned(SQES_DISP_BYTES), CNTR_WIDTH));
    cntr_incrs(R_WRBUFF_USR_RDS_CNTR_L)                 <= N2C_BUFF_USR_RDS_INCR;
    cntr_incrs_sizes(R_WRBUFF_USR_RDS_CNTR_L)           <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_WRBUFF_USR_RD_BYTES_CNTR_L)            <= N2C_BUFF_USR_RDS_INCR;
    cntr_incrs_sizes(R_WRBUFF_USR_RD_BYTES_CNTR_L)      <= std_logic_vector(resize(unsigned(N2C_BUFF_USR_RDS_BYTES), CNTR_WIDTH));
    -- C2N_BUFF_DISP_RDS_CHAN is a stats-only classification bit (produced by pcie_read_responder
    -- from a BAR-ID compare, independent of the (now flat-addressed) buffer's channel port):
    -- '0' => RDBUFF read dispatched, '1' => SQ read dispatched.
    cntr_incrs(R_RDBUFF_DISP_RDS_CNTR_L)                <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = '0' else '0';
    cntr_incrs_sizes(R_RDBUFF_DISP_RDS_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_RDBUFF_DISP_RD_BYTES_CNTR_L)           <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = '0' else '0';
    cntr_incrs_sizes(R_RDBUFF_DISP_RD_BYTES_CNTR_L)     <= std_logic_vector(resize(unsigned(C2N_BUFF_DISP_RDS_BYTES), CNTR_WIDTH));
    cntr_incrs(R_SQ_DISP_RDS_CNTR_L)                    <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = '1' else '0';
    cntr_incrs_sizes(R_SQ_DISP_RDS_CNTR_L)              <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_SQ_DISP_RD_BYTES_CNTR_L)               <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = '1' else '0';
    cntr_incrs_sizes(R_SQ_DISP_RD_BYTES_CNTR_L)         <= std_logic_vector(resize(unsigned(C2N_BUFF_DISP_RDS_BYTES), CNTR_WIDTH));
    cntr_incrs(R_NVME_FLUSH_CMD_DISP_CNTR_L)            <= SQES_DISP_INCR when SQES_DISP_TYPE = FLUSH_CMD_OPCODE else '0';
    cntr_incrs_sizes(R_NVME_FLUSH_CMD_DISP_CNTR_L)      <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));

    -- =============================================================================================
    -- Connecting sample register input to system inputs
    -- =============================================================================================
    (sample_regs_ins(R_LAST_CQ_ENTRY_3),
    sample_regs_ins(R_LAST_CQ_ENTRY_2),
    sample_regs_ins(R_LAST_CQ_ENTRY_1),
    sample_regs_ins(R_LAST_CQ_ENTRY_0)) <= last_cq_entry_inp_reg;

    (sample_regs_ins(R_SQE_DISP_CNTR_H),sample_regs_ins(R_SQE_DISP_CNTR_L))                             <= cntr_outs(R_SQE_DISP_CNTR_L);
    (sample_regs_ins(R_CQE_PROC_CNTR_H),sample_regs_ins(R_CQE_PROC_CNTR_L))                             <= cntr_outs(R_CQE_PROC_CNTR_L);
    (sample_regs_ins(R_PCIE_RDS_CNTR_H),sample_regs_ins(R_PCIE_RDS_CNTR_L))                             <= cntr_outs(R_PCIE_RDS_CNTR_L);
    (sample_regs_ins(R_PCIE_RD_BYTES_CNTR_H),sample_regs_ins(R_PCIE_RD_BYTES_CNTR_L))                   <= cntr_outs(R_PCIE_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_PCIE_WRS_CNTR_H),sample_regs_ins(R_PCIE_WRS_CNTR_L))                             <= cntr_outs(R_PCIE_WRS_CNTR_L);
    (sample_regs_ins(R_PCIE_WR_BYTES_CNTR_H),sample_regs_ins(R_PCIE_WR_BYTES_CNTR_L))                   <= cntr_outs(R_PCIE_WR_BYTES_CNTR_L);
    (sample_regs_ins(R_SQ_PCIE_RDS_CNTR_H),sample_regs_ins(R_SQ_PCIE_RDS_CNTR_L))                       <= cntr_outs(R_SQ_PCIE_RDS_CNTR_L);
    (sample_regs_ins(R_SQ_PCIE_RD_BYTES_CNTR_H),sample_regs_ins(R_SQ_PCIE_RD_BYTES_CNTR_L))             <= cntr_outs(R_SQ_PCIE_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_SUCC_COMPL_CNTR_H),sample_regs_ins(R_SUCC_COMPL_CNTR_L))                         <= cntr_outs(R_SUCC_COMPL_CNTR_L);
    (sample_regs_ins(R_UNSUCC_COMPL_CNTR_H),sample_regs_ins(R_UNSUCC_COMPL_CNTR_L))                     <= cntr_outs(R_UNSUCC_COMPL_CNTR_L);
    (sample_regs_ins(R_RDBUFF_PCIE_RDS_CNTR_H),sample_regs_ins(R_RDBUFF_PCIE_RDS_CNTR_L))               <= cntr_outs(R_RDBUFF_PCIE_RDS_CNTR_L);
    (sample_regs_ins(R_RDBUFF_PCIE_RD_BYTES_CNTR_H),sample_regs_ins(R_RDBUFF_PCIE_RD_BYTES_CNTR_L))     <= cntr_outs(R_RDBUFF_PCIE_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_WRBUFF_PCIE_WRS_CNTR_H),sample_regs_ins(R_WRBUFF_PCIE_WRS_CNTR_L))               <= cntr_outs(R_WRBUFF_PCIE_WRS_CNTR_L);
    (sample_regs_ins(R_WRBUFF_PCIE_WR_BYTES_CNTR_H),sample_regs_ins(R_WRBUFF_PCIE_WR_BYTES_CNTR_L))     <= cntr_outs(R_WRBUFF_PCIE_WR_BYTES_CNTR_L);
    (sample_regs_ins(R_CQ_PCIE_WRS_CNTR_H),sample_regs_ins(R_CQ_PCIE_WRS_CNTR_L))                       <= cntr_outs(R_CQ_PCIE_WRS_CNTR_L);
    (sample_regs_ins(R_CQ_PCIE_WR_BYTES_CNTR_H),sample_regs_ins(R_CQ_PCIE_WR_BYTES_CNTR_L))             <= cntr_outs(R_CQ_PCIE_WR_BYTES_CNTR_L);
    (sample_regs_ins(R_CQHDBL_REG_UPDS_CNTR_H),sample_regs_ins(R_CQHDBL_REG_UPDS_CNTR_L))               <= cntr_outs(R_CQHDBL_REG_UPDS_CNTR_L);
    (sample_regs_ins(R_CQHDBL_RPT_UPDS_CNTR_H),sample_regs_ins(R_CQHDBL_RPT_UPDS_CNTR_L))               <= cntr_outs(R_CQHDBL_RPT_UPDS_CNTR_L);
    (sample_regs_ins(R_SQTDBL_REG_UPDS_CNTR_H),sample_regs_ins(R_SQTDBL_REG_UPDS_CNTR_L))               <= cntr_outs(R_SQTDBL_REG_UPDS_CNTR_L);
    (sample_regs_ins(R_SQTDBL_RPT_UPDS_CNTR_H),sample_regs_ins(R_SQTDBL_RPT_UPDS_CNTR_L))               <= cntr_outs(R_SQTDBL_RPT_UPDS_CNTR_L);
    (sample_regs_ins(R_NVME_RD_BYTES_CNTR_H),sample_regs_ins(R_NVME_RD_BYTES_CNTR_L))                   <= cntr_outs(R_NVME_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_NVME_WR_BYTES_CNTR_H),sample_regs_ins(R_NVME_WR_BYTES_CNTR_L))                   <= cntr_outs(R_NVME_WR_BYTES_CNTR_L);
    (sample_regs_ins(R_WRBUFF_USR_RDS_CNTR_H),sample_regs_ins(R_WRBUFF_USR_RDS_CNTR_L))                 <= cntr_outs(R_WRBUFF_USR_RDS_CNTR_L);
    (sample_regs_ins(R_WRBUFF_USR_RD_BYTES_CNTR_H),sample_regs_ins(R_WRBUFF_USR_RD_BYTES_CNTR_L))       <= cntr_outs(R_WRBUFF_USR_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_RDBUFF_DISP_RDS_CNTR_H),sample_regs_ins(R_RDBUFF_DISP_RDS_CNTR_L))               <= cntr_outs(R_RDBUFF_DISP_RDS_CNTR_L);
    (sample_regs_ins(R_RDBUFF_DISP_RD_BYTES_CNTR_H),sample_regs_ins(R_RDBUFF_DISP_RD_BYTES_CNTR_L))     <= cntr_outs(R_RDBUFF_DISP_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_SQ_DISP_RDS_CNTR_H),sample_regs_ins(R_SQ_DISP_RDS_CNTR_L))                       <= cntr_outs(R_SQ_DISP_RDS_CNTR_L);
    (sample_regs_ins(R_SQ_DISP_RD_BYTES_CNTR_H),sample_regs_ins(R_SQ_DISP_RD_BYTES_CNTR_L))             <= cntr_outs(R_SQ_DISP_RD_BYTES_CNTR_L);
    (sample_regs_ins(R_NVME_FLUSH_CMD_DISP_CNTR_H),sample_regs_ins(R_NVME_FLUSH_CMD_DISP_CNTR_L))       <= cntr_outs(R_NVME_FLUSH_CMD_DISP_CNTR_L);

    -- =============================================================================================
    -- Connecting register outputs to external ports
    -- =============================================================================================
    RDBUFF_BADDR         <= regs_arr(R_RDBUFF_BADDR_H) & regs_arr(R_RDBUFF_BADDR_L);
    RDBUFF_PRP_LIST_PTR  <= regs_arr(R_RDBUFF_PRP_LIST_PTR_H) & regs_arr(R_RDBUFF_PRP_LIST_PTR_L);
    WRBUFF_BADDR         <= regs_arr(R_WRBUFF_BADDR_H) & regs_arr(R_WRBUFF_BADDR_L);
    WRBUFF_PRP_LIST_PTR  <= regs_arr(R_WRBUFF_PRP_LIST_PTR_H) & regs_arr(R_WRBUFF_PRP_LIST_PTR_L);
    METADATA_PTR         <= regs_arr(R_META_PTR_H) & regs_arr(R_META_PTR_L);

    -- =============================================================================================
    -- Selecting registers to READ
    -- =============================================================================================
    read_from_regs_p : process (CLK)
        variable reg_sel_addr : std_logic_vector(ADDR_LENGTH - 1 downto 0);
    begin
        if (rising_edge(CLK)) then
            mi_split_drd(0) <= (others => '0');

            reg_sel_addr := mi_split_addr(0)(ADDR_LENGTH - 1 downto 0);

            -- COMMON block.
            for reg_idx in 0 to (REGS-1) loop
                if (reg_sel_addr = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH))) then
                    mi_split_drd(0)(REG_WIDTH(reg_idx)-1 downto 0) <= regs_arr(reg_idx)(REG_WIDTH(reg_idx)-1 downto 0);
                end if;
            end loop;

            -- PER-QUEUE block: pq_valid/pq_word_idx are combinational decodes of mi_split_addr(0)
            -- (settled the same cycle as reg_sel_addr above), and pq_mi_dob(pq_word_idx) is that
            -- field's own MI-port NP_LUTRAM read (also combinational, addressed by pq_qid) -- so
            -- this registers the per-queue value with the SAME 1-cycle MI-read latency as every
            -- COMMON register above (no cocotb model timing change is needed for MI reads).
            if (pq_valid = '1' and pq_word_idx <= PQ_LBA_NUM_MASK) then
                mi_split_drd(0)(PQ_REG_WIDTH(pq_word_idx) -1 downto 0) <= pq_mi_dob(pq_word_idx)(PQ_REG_WIDTH(pq_word_idx) -1 downto 0);
            end if;
        end if;
    end process;

    drdy_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                mi_split_drdy(0) <= '0';
            else
                mi_split_drdy(0) <= mi_split_rd(0);
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Completion Error tracking
    -- =============================================================================================
    cqe_error_tracker_i : entity work.CQE_ERROR_TRACKER
        port map (
            CLK        => CLK,
            CLR        => RST or regs_arr(R_CONTROL)(CTRL_CLR_ERR_MASK),
            SCT        => last_cq_entry_inp_reg(CQ_ENTRY_SC_TYPE),
            SC         => last_cq_entry_inp_reg(CQ_ENTRY_STAT_CODE),
            ERROR_MASK => cpl_err_mask);

    -- =============================================================================================
    -- Start/stop control
    -- =============================================================================================

    running_state_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or dlogger_sw_rst = '1') then
                run_state_reg <= S_IDLE;
                wr_mfb_block_en_reg <= '1';
            else
                run_state_reg <= run_state_next;
                wr_mfb_block_en_reg <= wr_mfb_block_en_next;
            end if;
        end if;
    end process;

    running_state_nst_logic_p : process (all) is
    begin
        run_state_next       <= run_state_reg;
        wr_mfb_block_en_next <= wr_mfb_block_en_reg;
        OPC_START_REQ_VLD    <= '0';
        CQP_START_REQ_VLD    <= '0';
        OPC_STOP_REQ_VLD     <= '0';
        CQP_STOP_REQ_VLD     <= '0';

        case run_state_reg is
            when S_IDLE =>
                if (regs_arr(R_CONTROL)(CTRL_DESIGN_EN) = '1' and regs_arr(R_STATUS)(STAT_DESIGN_RUN) = '0') then
                    run_state_next <= S_START_CQP;
                end if;

            when S_START_CQP =>
                CQP_START_REQ_VLD <= '1';
                if (CQP_START_REQ_ACK = '1') then
                    run_state_next <= S_START_OPC;
                end if;

            when S_START_OPC =>
                OPC_START_REQ_VLD <= '1';
                if (OPC_START_REQ_ACK = '1') then
                    run_state_next       <= S_RUNNING;
                    wr_mfb_block_en_next <= '0';
                end if;

            when S_RUNNING =>
                if (regs_arr(R_CONTROL)(CTRL_DESIGN_EN) = '0' and regs_arr(R_STATUS)(STAT_DESIGN_RUN) = '1') then
                    run_state_next       <= S_STOP_OPC;
                    wr_mfb_block_en_next <= '1';
                end if;

            when S_STOP_OPC =>
                OPC_STOP_REQ_VLD <= '1';
                if (OPC_STOP_REQ_ACK = '1') then
                    run_state_next <= S_STOP_CQP;
                end if;

            when S_STOP_CQP =>
                CQP_STOP_REQ_VLD <= '1';
                if (CQP_STOP_REQ_ACK = '1') then
                    run_state_next <= S_IDLE;
                end if;
        end case;
    end process;

    -- =============================================================================================
    -- Performance counters
    -- =============================================================================================
    -- "SQ write blocking" (queue 0's SQTDBL would collide with its own SQHDBL) -- queue-0-only, see
    -- sqtdbl_next_val_q0's own comment above for why. At NUM_QUEUES=1 queue 0 IS the only queue, so
    -- this is exactly the original single-queue check.
    sqtdbl_next_val_q0 <= std_logic_vector((unsigned(sqtdbl_reg_arr(0)) + 1) and unsigned(dbl_mask_q0_dob(15 downto 0)));
    sq_write_blocking  <= '1' when (sqtdbl_next_val_q0 = sqhdbl_reg_arr(0)) else '0';

    -- The amount of clocks when the trigger is active
    cmd_disp_trigg_active_incr <= OPC_TRIGG_DISP;

    perf_cntr_incr_packed <= cmd_disp_trigg_active_incr
                             & sq_write_blocking;

    sq_iops_cntr_i : entity work.EVENT_COUNTER
        generic map (
            MAX_INTERVAL_CYCLES   => EVCR_MAX_INTERVAL_CYCLES,
            MAX_CONCURRENT_EVENTS => 1)
        port map (
            CLK   => CLK,
            RESET => RST or dlogger_sw_rst,

            INTERVAL_CYCLES => evctr_interval_cycles,
            INTERVAL_SET    => evctr_interval_set,

            EVENT_CNT => (others => '1'),
            EVENT_VLD => SQES_DISP_INCR,

            TOTAL_EVENTS => sqiops_evctr_total_events,
            TOTAL_CYCLES => sqiops_evctr_total_cycles,
            TOTAL_UPDATE => sqiops_evctr_update);

    (evctr_interval_set, evctr_interval_cycles) <= data_logger_ctrlo;

    perf_counters_dlogger_p : entity work.DATA_LOGGER
        generic map (
            MI_DATA_WIDTH => MI_WIDTH,
            MI_ADDR_WIDTH => MI_WIDTH,

            CNTER_CNT => PERF_CNTR_NUM,
            VALUE_CNT => 1,

            CTRLO_WIDTH => 1 + log2(EVCR_MAX_INTERVAL_CYCLES+1),
            CTRLI_WIDTH => log2((EVCR_MAX_INTERVAL_CYCLES+1)*2) + log2(EVCR_MAX_INTERVAL_CYCLES+1),

            CNTER_WIDTH => CNTR_WIDTH,
            VALUE_WIDTH => (others => log2((EVCR_MAX_INTERVAL_CYCLES+1)*2)),

            MIN_EN  => (others => TRUE),
            MAX_EN  => (others => TRUE),
            SUM_EN  => (others => FALSE),
            HIST_EN => (others => FALSE),

            SUM_EXTRA_WIDTH => (others => 8),
            HIST_BOX_CNT    => (others => 2**16),
            HIST_BOX_WIDTH  => (others => 32),
            CTRLO_DEFAULT   => (others => '0'))
        port map (
            CLK => CLK,
            RST => RST,

            RST_DONE => dlogger_sw_rst_done,
            SW_RST   => dlogger_sw_rst,

            CTRLO => data_logger_ctrlo,
            CTRLI => sqiops_val_current & sqiops_evctr_total_cycles,

            CNTERS_INCR   => perf_cntr_incr_packed,
            CNTERS_SUBMIT => perf_cntr_incr_packed,
            CNTERS_DIFF   => (others => std_logic_vector(to_unsigned(1, CNTR_WIDTH))),

            VALUES_VLD => (others => sqiops_evctr_update),
            VALUES     => sqiops_evctr_total_events,

            MI_DWR  => mi_split_dwr(1),
            MI_ADDR => mi_split_addr(1),
            MI_BE   => mi_split_be(1),
            MI_RD   => mi_split_rd(1),
            MI_WR   => mi_split_wr(1),
            MI_ARDY => mi_split_ardy(1),
            MI_DRD  => mi_split_drd(1),
            MI_DRDY => mi_split_drdy(1));

    sqiops_val_reg: process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (sqiops_evctr_update = '1') then
                sqiops_val_current <= sqiops_evctr_total_events;
            end if;
        end if;
    end process;

    USER_RST <= dlogger_sw_rst;
end architecture;
