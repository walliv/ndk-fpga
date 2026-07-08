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
        PKT_SIZE_MAX : positive := 2**17
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
        -- Operation Control
        -- ========================================================================================
        RDBUFF_BADDR         : out std_logic_vector(63 downto 0);
        RDBUFF_PRP_LIST_PTR  : out std_logic_vector(63 downto 0);
        WRBUFF_BADDR         : out std_logic_vector(63 downto 0);
        WRBUFF_PRP_LIST_PTR  : out std_logic_vector(63 downto 0);

        -- ========================================================================================
        -- C2N Command dispatcher
        -- ========================================================================================
        -- The current value of SQTDBL
        SQTDBL_DATA     : in  std_logic_vector(15 downto 0);
        TAG_FIFO_STATUS : in std_logic_vector(11 downto 0);
        TAG_INIT_DONE   : in std_logic;

        DBL_MASK       : out std_logic_vector(15 downto 0);
        NAMESPACE_ID   : out std_logic_vector(31 downto 0);
        METADATA_PTR   : out std_logic_vector(63 downto 0);
        LBA_NUM_MASK   : out std_logic_vector(15 downto 0);
        LBA_SPACE_SIZE : out std_logic_vector(63 downto 0);

        SQES_DISP_TYPE  : in std_logic_vector(CMD_OPCODE_W -1 downto 0);
        SQES_DISP_INCR  : in std_logic;
        SQES_DISP_BYTES : in std_logic_vector(25 -1 downto 0);

        -- =========================================================================================
        -- N2C Completion processor
        -- =========================================================================================
        SQHDBL_DATA     : in std_logic_vector(15 downto 0);
        CQHDBL_DATA     : in std_logic_vector(15 downto 0);
        LAST_CQ_ENTRY   : in std_logic_vector(CQ_ENTRY_RANGE);
        STATUS_UPD_VLD  : in std_logic;

        -- =========================================================================================
        -- DBL Updater
        -- =========================================================================================
        CQHDBL_BASE_ADDR : out std_logic_vector(63 downto 0);
        SQTDBL_BASE_ADDR : out std_logic_vector(63 downto 0);

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
    constant ADDR_LENGTH : positive := 9;
    constant CNTR_WIDTH  : positive := 64;

    constant R_CONTROL                      : natural := 0;
    constant R_STATUS                       : natural := 1;
    constant R_SQTDBL                       : natural := 2;
    constant R_SQHDBL                       : natural := 3;
    constant R_CQHDBL                       : natural := 4;
    constant R_DBL_MASK                     : natural := 5;
    constant R_SQTDBL_BADDR_L               : natural := 6;
    constant R_SQTDBL_BADDR_H               : natural := 7;
    constant R_CQHDBL_BADDR_L               : natural := 8;
    constant R_CQHDBL_BADDR_H               : natural := 9;
    constant R_RDBUFF_BADDR_L               : natural := 10;
    constant R_RDBUFF_BADDR_H               : natural := 11;
    constant R_RDBUFF_PRP_LIST_PTR_L        : natural := 12;
    constant R_RDBUFF_PRP_LIST_PTR_H        : natural := 13;
    constant R_WRBUFF_BADDR_L               : natural := 14;
    constant R_WRBUFF_BADDR_H               : natural := 15;
    constant R_WRBUFF_PRP_LIST_PTR_L        : natural := 16;
    constant R_WRBUFF_PRP_LIST_PTR_H        : natural := 17;
    constant R_LAST_CQ_ENTRY_0              : natural := 18;
    constant R_LAST_CQ_ENTRY_1              : natural := 19;
    constant R_LAST_CQ_ENTRY_2              : natural := 20;
    constant R_LAST_CQ_ENTRY_3              : natural := 21;
    constant R_SQE_DISP_CNTR_L              : natural := 22;
    constant R_SQE_DISP_CNTR_H              : natural := 23;
    constant R_CQE_PROC_CNTR_L              : natural := 24;
    constant R_CQE_PROC_CNTR_H              : natural := 25;
    constant R_PCIE_RDS_CNTR_L              : natural := 26;
    constant R_PCIE_RDS_CNTR_H              : natural := 27;
    constant R_PCIE_RD_BYTES_CNTR_L         : natural := 28;
    constant R_PCIE_RD_BYTES_CNTR_H         : natural := 29;
    constant R_PCIE_WRS_CNTR_L              : natural := 30;
    constant R_PCIE_WRS_CNTR_H              : natural := 31;
    constant R_PCIE_WR_BYTES_CNTR_L         : natural := 32;
    constant R_PCIE_WR_BYTES_CNTR_H         : natural := 33;
    constant R_SQ_PCIE_RDS_CNTR_L           : natural := 34;
    constant R_SQ_PCIE_RDS_CNTR_H           : natural := 35;
    constant R_SQ_PCIE_RD_BYTES_CNTR_L      : natural := 36;
    constant R_SQ_PCIE_RD_BYTES_CNTR_H      : natural := 37;
    constant R_LBA_NUM_MASK                 : natural := 38;
    constant R_SUCC_COMPL_CNTR_L            : natural := 39;
    constant R_SUCC_COMPL_CNTR_H            : natural := 40;
    constant R_UNSUCC_COMPL_CNTR_L          : natural := 41;
    constant R_UNSUCC_COMPL_CNTR_H          : natural := 42;
    constant R_CPL_ERR_MASK_L               : natural := 43;
    constant R_CPL_ERR_MASK_H               : natural := 44;
    constant R_RDBUFF_PCIE_RDS_CNTR_L       : natural := 45;
    constant R_RDBUFF_PCIE_RDS_CNTR_H       : natural := 46;
    constant R_RDBUFF_PCIE_RD_BYTES_CNTR_L  : natural := 47;
    constant R_RDBUFF_PCIE_RD_BYTES_CNTR_H  : natural := 48;
    constant R_WRBUFF_PCIE_WRS_CNTR_L       : natural := 49;
    constant R_WRBUFF_PCIE_WRS_CNTR_H       : natural := 50;
    constant R_WRBUFF_PCIE_WR_BYTES_CNTR_L  : natural := 51;
    constant R_WRBUFF_PCIE_WR_BYTES_CNTR_H  : natural := 52;
    constant R_LBA_SPACE_SIZE_L             : natural := 53;
    constant R_LBA_SPACE_SIZE_H             : natural := 54;
    constant R_CQ_PCIE_WRS_CNTR_L           : natural := 55;
    constant R_CQ_PCIE_WRS_CNTR_H           : natural := 56;
    constant R_CQ_PCIE_WR_BYTES_CNTR_L      : natural := 57;
    constant R_CQ_PCIE_WR_BYTES_CNTR_H      : natural := 58;
    constant R_CQHDBL_REG_UPDS_CNTR_L       : natural := 59;
    constant R_CQHDBL_REG_UPDS_CNTR_H       : natural := 60;
    constant R_CQHDBL_RPT_UPDS_CNTR_L       : natural := 61;
    constant R_CQHDBL_RPT_UPDS_CNTR_H       : natural := 62;
    constant R_SQTDBL_REG_UPDS_CNTR_L       : natural := 63;
    constant R_SQTDBL_REG_UPDS_CNTR_H       : natural := 64;
    constant R_SQTDBL_RPT_UPDS_CNTR_L       : natural := 65;
    constant R_SQTDBL_RPT_UPDS_CNTR_H       : natural := 66;
    constant R_META_PTR_L                   : natural := 67;
    constant R_META_PTR_H                   : natural := 68;
    constant R_NVME_RD_BYTES_CNTR_L         : natural := 69;
    constant R_NVME_RD_BYTES_CNTR_H         : natural := 70;
    constant R_NVME_WR_BYTES_CNTR_L         : natural := 71;
    constant R_NVME_WR_BYTES_CNTR_H         : natural := 72;
    constant R_WRBUFF_USR_RDS_CNTR_L        : natural := 73;
    constant R_WRBUFF_USR_RDS_CNTR_H        : natural := 74;
    constant R_WRBUFF_USR_RD_BYTES_CNTR_L   : natural := 75;
    constant R_WRBUFF_USR_RD_BYTES_CNTR_H   : natural := 76;
    constant R_RDBUFF_DISP_RDS_CNTR_L       : natural := 77;
    constant R_RDBUFF_DISP_RDS_CNTR_H       : natural := 78;
    constant R_RDBUFF_DISP_RD_BYTES_CNTR_L  : natural := 79;
    constant R_RDBUFF_DISP_RD_BYTES_CNTR_H  : natural := 80;
    constant R_SQ_DISP_RDS_CNTR_L           : natural := 81;
    constant R_SQ_DISP_RDS_CNTR_H           : natural := 82;
    constant R_SQ_DISP_RD_BYTES_CNTR_L      : natural := 83;
    constant R_SQ_DISP_RD_BYTES_CNTR_H      : natural := 84;
    constant R_TAG_FIFO_STATUS              : natural := 85;
    constant R_NVME_FLUSH_CMD_DISP_CNTR_L   : natural := 86;
    constant R_NVME_FLUSH_CMD_DISP_CNTR_H   : natural := 87;

    constant REGS : natural := 88;

    constant R_ADDRS : n_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => 16#000#,
        R_STATUS                        => 16#004#,
        R_SQTDBL                        => 16#008#,
        R_SQHDBL                        => 16#00C#,
        R_CQHDBL                        => 16#010#,
        R_DBL_MASK                      => 16#014#,
        R_SQTDBL_BADDR_L                => 16#018#,
        R_SQTDBL_BADDR_H                => 16#01C#,
        R_CQHDBL_BADDR_L                => 16#020#,
        R_CQHDBL_BADDR_H                => 16#024#,
        R_RDBUFF_BADDR_L                => 16#028#,
        R_RDBUFF_BADDR_H                => 16#02C#,
        R_RDBUFF_PRP_LIST_PTR_L         => 16#030#,
        R_RDBUFF_PRP_LIST_PTR_H         => 16#034#,
        R_WRBUFF_BADDR_L                => 16#038#,
        R_WRBUFF_BADDR_H                => 16#03C#,
        R_WRBUFF_PRP_LIST_PTR_L         => 16#040#,
        R_WRBUFF_PRP_LIST_PTR_H         => 16#044#,
        R_LAST_CQ_ENTRY_0               => 16#048#,
        R_LAST_CQ_ENTRY_1               => 16#04C#,
        R_LAST_CQ_ENTRY_2               => 16#050#,
        R_LAST_CQ_ENTRY_3               => 16#054#,
        R_SQE_DISP_CNTR_L               => 16#058#,
        R_SQE_DISP_CNTR_H               => 16#05C#,
        R_CQE_PROC_CNTR_L               => 16#060#,
        R_CQE_PROC_CNTR_H               => 16#064#,
        R_PCIE_RDS_CNTR_L               => 16#068#,
        R_PCIE_RDS_CNTR_H               => 16#06C#,
        R_PCIE_RD_BYTES_CNTR_L          => 16#070#,
        R_PCIE_RD_BYTES_CNTR_H          => 16#074#,
        R_PCIE_WRS_CNTR_L               => 16#078#,
        R_PCIE_WRS_CNTR_H               => 16#07C#,
        R_PCIE_WR_BYTES_CNTR_L          => 16#080#,
        R_PCIE_WR_BYTES_CNTR_H          => 16#084#,
        R_SQ_PCIE_RDS_CNTR_L            => 16#088#,
        R_SQ_PCIE_RDS_CNTR_H            => 16#08C#,
        R_SQ_PCIE_RD_BYTES_CNTR_L       => 16#090#,
        R_SQ_PCIE_RD_BYTES_CNTR_H       => 16#094#,
        R_LBA_NUM_MASK                  => 16#098#,
        R_SUCC_COMPL_CNTR_L             => 16#09C#,
        R_SUCC_COMPL_CNTR_H             => 16#0A0#,
        R_UNSUCC_COMPL_CNTR_L           => 16#0A4#,
        R_UNSUCC_COMPL_CNTR_H           => 16#0A8#,
        R_CPL_ERR_MASK_L                => 16#0AC#,
        R_CPL_ERR_MASK_H                => 16#0B0#,
        R_RDBUFF_PCIE_RDS_CNTR_L        => 16#0B4#,
        R_RDBUFF_PCIE_RDS_CNTR_H        => 16#0B8#,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => 16#0BC#,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => 16#0C0#,
        R_WRBUFF_PCIE_WRS_CNTR_L        => 16#0C4#,
        R_WRBUFF_PCIE_WRS_CNTR_H        => 16#0C8#,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => 16#0CC#,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => 16#0D0#,
        R_LBA_SPACE_SIZE_L              => 16#0D4#,
        R_LBA_SPACE_SIZE_H              => 16#0D8#,
        R_CQ_PCIE_WRS_CNTR_L            => 16#0DC#,
        R_CQ_PCIE_WRS_CNTR_H            => 16#0E0#,
        R_CQ_PCIE_WR_BYTES_CNTR_L       => 16#0E4#,
        R_CQ_PCIE_WR_BYTES_CNTR_H       => 16#0E8#,
        R_CQHDBL_REG_UPDS_CNTR_L        => 16#0EC#,
        R_CQHDBL_REG_UPDS_CNTR_H        => 16#0F0#,
        R_CQHDBL_RPT_UPDS_CNTR_L        => 16#0F4#,
        R_CQHDBL_RPT_UPDS_CNTR_H        => 16#0F8#,
        R_SQTDBL_REG_UPDS_CNTR_L        => 16#0FC#,
        R_SQTDBL_REG_UPDS_CNTR_H        => 16#100#,
        R_SQTDBL_RPT_UPDS_CNTR_L        => 16#104#,
        R_SQTDBL_RPT_UPDS_CNTR_H        => 16#108#,
        R_META_PTR_L                    => 16#10C#,
        R_META_PTR_H                    => 16#110#,
        R_NVME_RD_BYTES_CNTR_L          => 16#114#,
        R_NVME_RD_BYTES_CNTR_H          => 16#118#,
        R_NVME_WR_BYTES_CNTR_L          => 16#11C#,
        R_NVME_WR_BYTES_CNTR_H          => 16#120#,
        R_WRBUFF_USR_RDS_CNTR_L         => 16#124#,
        R_WRBUFF_USR_RDS_CNTR_H         => 16#128#,
        R_WRBUFF_USR_RD_BYTES_CNTR_L    => 16#12C#,
        R_WRBUFF_USR_RD_BYTES_CNTR_H    => 16#130#,
        R_RDBUFF_DISP_RDS_CNTR_L        => 16#134#,
        R_RDBUFF_DISP_RDS_CNTR_H        => 16#138#,
        R_RDBUFF_DISP_RD_BYTES_CNTR_L   => 16#13C#,
        R_RDBUFF_DISP_RD_BYTES_CNTR_H   => 16#140#,
        R_SQ_DISP_RDS_CNTR_L            => 16#144#,
        R_SQ_DISP_RDS_CNTR_H            => 16#148#,
        R_SQ_DISP_RD_BYTES_CNTR_L       => 16#14C#,
        R_SQ_DISP_RD_BYTES_CNTR_H       => 16#150#,
        R_TAG_FIFO_STATUS               => 16#154#,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => 16#158#,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => 16#15C#
    );

    -- Write enable (set to False for read-only registers)
    -- Must be set to True, when the coresponding index in STROBE_EN is True
    constant WR_EN : b_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => TRUE,
        R_STATUS                        => FALSE,
        R_SQTDBL                        => FALSE,
        R_SQHDBL                        => FALSE,
        R_CQHDBL                        => FALSE,
        R_DBL_MASK                      => TRUE,
        R_SQTDBL_BADDR_L                => TRUE,
        R_SQTDBL_BADDR_H                => TRUE,
        R_CQHDBL_BADDR_L                => TRUE,
        R_CQHDBL_BADDR_H                => TRUE,
        R_RDBUFF_BADDR_L                => TRUE,
        R_RDBUFF_BADDR_H                => TRUE,
        R_RDBUFF_PRP_LIST_PTR_L         => TRUE,
        R_RDBUFF_PRP_LIST_PTR_H         => TRUE,
        R_WRBUFF_BADDR_L                => TRUE,
        R_WRBUFF_BADDR_H                => TRUE,
        R_WRBUFF_PRP_LIST_PTR_L         => TRUE,
        R_WRBUFF_PRP_LIST_PTR_H         => TRUE,
        R_LAST_CQ_ENTRY_0               => FALSE,
        R_LAST_CQ_ENTRY_1               => FALSE,
        R_LAST_CQ_ENTRY_2               => FALSE,
        R_LAST_CQ_ENTRY_3               => FALSE,
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
        R_LBA_NUM_MASK                  => TRUE,
        R_SUCC_COMPL_CNTR_L             => FALSE,
        R_SUCC_COMPL_CNTR_H             => FALSE,
        R_UNSUCC_COMPL_CNTR_L           => FALSE,
        R_UNSUCC_COMPL_CNTR_H           => FALSE,
        R_CPL_ERR_MASK_L                => FALSE,
        R_CPL_ERR_MASK_H                => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_L        => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_H        => FALSE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => FALSE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => FALSE,
        R_WRBUFF_PCIE_WRS_CNTR_L        => FALSE,
        R_WRBUFF_PCIE_WRS_CNTR_H        => FALSE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => FALSE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => FALSE,
        R_LBA_SPACE_SIZE_L              => TRUE,
        R_LBA_SPACE_SIZE_H              => TRUE,
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
        R_META_PTR_L                    => TRUE,
        R_META_PTR_H                    => TRUE,
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
        R_TAG_FIFO_STATUS               => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => FALSE
    );

    constant STROBE_EN : b_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => FALSE,
        R_STATUS                        => FALSE,
        R_SQTDBL                        => FALSE,
        R_SQHDBL                        => FALSE,
        R_CQHDBL                        => FALSE,
        R_DBL_MASK                      => FALSE,
        R_SQTDBL_BADDR_L                => FALSE,
        R_SQTDBL_BADDR_H                => FALSE,
        R_CQHDBL_BADDR_L                => FALSE,
        R_CQHDBL_BADDR_H                => FALSE,
        R_RDBUFF_BADDR_L                => FALSE,
        R_RDBUFF_BADDR_H                => FALSE,
        R_RDBUFF_PRP_LIST_PTR_L         => FALSE,
        R_RDBUFF_PRP_LIST_PTR_H         => FALSE,
        R_WRBUFF_BADDR_L                => FALSE,
        R_WRBUFF_BADDR_H                => FALSE,
        R_WRBUFF_PRP_LIST_PTR_L         => FALSE,
        R_WRBUFF_PRP_LIST_PTR_H         => FALSE,
        R_LAST_CQ_ENTRY_0               => TRUE,
        R_LAST_CQ_ENTRY_1               => TRUE,
        R_LAST_CQ_ENTRY_2               => TRUE,
        R_LAST_CQ_ENTRY_3               => TRUE,
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
        R_LBA_NUM_MASK                  => FALSE,
        R_SUCC_COMPL_CNTR_L             => TRUE,
        R_SUCC_COMPL_CNTR_H             => TRUE,
        R_UNSUCC_COMPL_CNTR_L           => TRUE,
        R_UNSUCC_COMPL_CNTR_H           => TRUE,
        R_CPL_ERR_MASK_L                => FALSE,
        R_CPL_ERR_MASK_H                => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_L        => TRUE,
        R_RDBUFF_PCIE_RDS_CNTR_H        => TRUE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => TRUE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => TRUE,
        R_WRBUFF_PCIE_WRS_CNTR_L        => TRUE,
        R_WRBUFF_PCIE_WRS_CNTR_H        => TRUE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => TRUE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => TRUE,
        R_LBA_SPACE_SIZE_L              => FALSE,
        R_LBA_SPACE_SIZE_H              => FALSE,
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
        R_META_PTR_L                    => FALSE,
        R_META_PTR_H                    => FALSE,
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
        R_TAG_FIFO_STATUS               => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => TRUE,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => TRUE
    );

    constant REG_IS_CNTR : b_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => FALSE,
        R_STATUS                        => FALSE,
        R_SQTDBL                        => FALSE,
        R_SQHDBL                        => FALSE,
        R_CQHDBL                        => FALSE,
        R_DBL_MASK                      => FALSE,
        R_SQTDBL_BADDR_L                => FALSE,
        R_SQTDBL_BADDR_H                => FALSE,
        R_CQHDBL_BADDR_L                => FALSE,
        R_CQHDBL_BADDR_H                => FALSE,
        R_RDBUFF_BADDR_L                => FALSE,
        R_RDBUFF_BADDR_H                => FALSE,
        R_RDBUFF_PRP_LIST_PTR_L         => FALSE,
        R_RDBUFF_PRP_LIST_PTR_H         => FALSE,
        R_WRBUFF_BADDR_L                => FALSE,
        R_WRBUFF_BADDR_H                => FALSE,
        R_WRBUFF_PRP_LIST_PTR_L         => FALSE,
        R_WRBUFF_PRP_LIST_PTR_H         => FALSE,
        R_LAST_CQ_ENTRY_0               => FALSE,
        R_LAST_CQ_ENTRY_1               => FALSE,
        R_LAST_CQ_ENTRY_2               => FALSE,
        R_LAST_CQ_ENTRY_3               => FALSE,
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
        R_LBA_NUM_MASK                  => FALSE,
        R_SUCC_COMPL_CNTR_L             => TRUE,
        R_SUCC_COMPL_CNTR_H             => FALSE,
        R_UNSUCC_COMPL_CNTR_L           => TRUE,
        R_UNSUCC_COMPL_CNTR_H           => FALSE,
        R_CPL_ERR_MASK_L                => FALSE,
        R_CPL_ERR_MASK_H                => FALSE,
        R_RDBUFF_PCIE_RDS_CNTR_L        => TRUE,
        R_RDBUFF_PCIE_RDS_CNTR_H        => FALSE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => TRUE,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => FALSE,
        R_WRBUFF_PCIE_WRS_CNTR_L        => TRUE,
        R_WRBUFF_PCIE_WRS_CNTR_H        => FALSE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => TRUE,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => FALSE,
        R_LBA_SPACE_SIZE_L              => FALSE,
        R_LBA_SPACE_SIZE_H              => FALSE,
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
        R_META_PTR_L                    => FALSE,
        R_META_PTR_H                    => FALSE,
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
        R_TAG_FIFO_STATUS               => FALSE,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => TRUE,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => FALSE
    );

    constant REG_WIDTH : n_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => 6,
        R_STATUS                        => 3,
        R_SQTDBL                        => 16,
        R_SQHDBL                        => 16,
        R_CQHDBL                        => 16,
        R_DBL_MASK                      => 16,
        R_SQTDBL_BADDR_L                => 32,
        R_SQTDBL_BADDR_H                => 32,
        R_CQHDBL_BADDR_L                => 32,
        R_CQHDBL_BADDR_H                => 32,
        R_RDBUFF_BADDR_L                => 32,
        R_RDBUFF_BADDR_H                => 32,
        R_RDBUFF_PRP_LIST_PTR_L         => 32,
        R_RDBUFF_PRP_LIST_PTR_H         => 32,
        R_WRBUFF_BADDR_L                => 32,
        R_WRBUFF_BADDR_H                => 32,
        R_WRBUFF_PRP_LIST_PTR_L         => 32,
        R_WRBUFF_PRP_LIST_PTR_H         => 32,
        R_LAST_CQ_ENTRY_0               => 32,
        R_LAST_CQ_ENTRY_1               => 32,
        R_LAST_CQ_ENTRY_2               => 32,
        R_LAST_CQ_ENTRY_3               => 32,
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
        R_LBA_NUM_MASK                  => 16,
        R_SUCC_COMPL_CNTR_L             => 32,
        R_SUCC_COMPL_CNTR_H             => 32,
        R_UNSUCC_COMPL_CNTR_L           => 32,
        R_UNSUCC_COMPL_CNTR_H           => 32,
        R_CPL_ERR_MASK_L                => 32,
        R_CPL_ERR_MASK_H                => 32,
        R_RDBUFF_PCIE_RDS_CNTR_L        => 32,
        R_RDBUFF_PCIE_RDS_CNTR_H        => 32,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_L   => 32,
        R_RDBUFF_PCIE_RD_BYTES_CNTR_H   => 32,
        R_WRBUFF_PCIE_WRS_CNTR_L        => 32,
        R_WRBUFF_PCIE_WRS_CNTR_H        => 32,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_L   => 32,
        R_WRBUFF_PCIE_WR_BYTES_CNTR_H   => 32,
        R_LBA_SPACE_SIZE_L              => 32,
        R_LBA_SPACE_SIZE_H              => 32,
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
        R_META_PTR_L                    => 32,
        R_META_PTR_H                    => 32,
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
        R_TAG_FIFO_STATUS               => 12,
        R_NVME_FLUSH_CMD_DISP_CNTR_L    => 32,
        R_NVME_FLUSH_CMD_DISP_CNTR_H    => 32
    );

    -- =============================================================================================
    -- Input registers
    -- =============================================================================================
    signal sqtdbl_reg                  : std_logic_vector(15 downto 0);
    signal sqhdbl_reg                  : std_logic_vector(15 downto 0);
    signal cqhdbl_reg                  : std_logic_vector(15 downto 0);
    -- Input register that gets updated only when STATUS_UPD_VLD is set
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
    -- Register array declaratiions
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
    -- The next value of the SQTDBL pointer (the value has to anticipate the possible doorbell
    -- pointer rollover and is therefore masked)
    signal sqtdbl_next_val           : std_logic_vector(15 downto 0);

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
begin
    assert (MPS <= 4096)
        report "NVME_CPL_SW_MANAGER: The set size of MPS exceeded the maximum defined by the PCIe Specification (up to 4096 B, current is " &
        to_string(MPS) & ")"
        severity FAILURE;

    assert (MRRS <= 4096)
        report "NVME_CPL_SW_MANAGER: The set size of MRRS exceeded the maximum defined by the PCIe Specification (4096 B, current is " &
        to_string(MRRS) & ")"
        severity FAILURE;

    -- The status information gets sampled only when the status update is actually done
    inp_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or dlogger_sw_rst = '1' or CQP_START_REQ_VLD = '1') then
                sqhdbl_reg             <= (others => '0');
                cqhdbl_reg             <= (others => '0');
                last_cq_entry_inp_reg  <= (others => '0');
                succ_compl_cntr_incr   <= '0';
                unsucc_compl_cntr_incr <= '0';
            else
                succ_compl_cntr_incr   <= '0';
                unsucc_compl_cntr_incr <= '0';

                if (STATUS_UPD_VLD = '1') then
                    sqhdbl_reg            <= SQHDBL_DATA;
                    cqhdbl_reg            <= CQHDBL_DATA;
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

    sqtdbl_reg_p: process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or dlogger_sw_rst = '1' or CQP_START_REQ_VLD = '1') then
                sqtdbl_reg <= (others => '0');
            elsif (SQES_DISP_INCR = '1') then
                sqtdbl_reg <= SQTDBL_DATA;
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

    regs_arr(R_SQTDBL)(REG_WIDTH(R_SQTDBL) -1 downto 0) <= sqtdbl_reg;
    regs_arr(R_SQHDBL)(REG_WIDTH(R_SQHDBL) -1 downto 0) <= sqhdbl_reg;
    regs_arr(R_CQHDBL)(REG_WIDTH(R_CQHDBL) -1 downto 0) <= cqhdbl_reg;

    (regs_arr(R_CPL_ERR_MASK_H), regs_arr(R_CPL_ERR_MASK_L))              <= cpl_err_mask;
    regs_arr(R_TAG_FIFO_STATUS)(REG_WIDTH(R_TAG_FIFO_STATUS) -1 downto 0) <= tag_fifo_status;

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
    cntr_incrs(R_RDBUFF_DISP_RDS_CNTR_L)                <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = RDBUFF_CHAN else '0';
    cntr_incrs_sizes(R_RDBUFF_DISP_RDS_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_RDBUFF_DISP_RD_BYTES_CNTR_L)           <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = RDBUFF_CHAN else '0';
    cntr_incrs_sizes(R_RDBUFF_DISP_RD_BYTES_CNTR_L)     <= std_logic_vector(resize(unsigned(C2N_BUFF_DISP_RDS_BYTES), CNTR_WIDTH));
    cntr_incrs(R_SQ_DISP_RDS_CNTR_L)                    <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = SQ_BUFF_CHAN else '0';
    cntr_incrs_sizes(R_SQ_DISP_RDS_CNTR_L)              <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_SQ_DISP_RD_BYTES_CNTR_L)               <= C2N_BUFF_DISP_RDS_INCR when C2N_BUFF_DISP_RDS_CHAN = SQ_BUFF_CHAN else '0';
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

    DBL_MASK         <= regs_arr(R_DBL_MASK)(REG_WIDTH(R_DBL_MASK)-1 downto 0);
    NAMESPACE_ID     <= x"00000001";
    METADATA_PTR     <= regs_arr(R_META_PTR_H) & regs_arr(R_META_PTR_L);
    LBA_SPACE_SIZE   <= regs_arr(R_LBA_SPACE_SIZE_H) & regs_arr(R_LBA_SPACE_SIZE_L);
    LBA_NUM_MASK     <= regs_arr(R_LBA_NUM_MASK)(REG_WIDTH(R_LBA_NUM_MASK)-1 downto 0);

    SQTDBL_BASE_ADDR <= regs_arr(R_SQTDBL_BADDR_H) & regs_arr(R_SQTDBL_BADDR_L);
    CQHDBL_BASE_ADDR <= regs_arr(R_CQHDBL_BADDR_H) & regs_arr(R_CQHDBL_BADDR_L);

    -- =============================================================================================
    -- Selecting registers to READ
    -- =============================================================================================
    read_from_regs_p : process (CLK)
        variable reg_sel_addr : std_logic_vector(ADDR_LENGTH - 1 downto 0);
    begin
        if (rising_edge(CLK)) then
            mi_split_drd(0) <= (others => '0');

            reg_sel_addr := mi_split_addr(0)(ADDR_LENGTH - 1 downto 0);

            for reg_idx in 0 to (REGS-1) loop
                if (reg_sel_addr = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH))) then
                    mi_split_drd(0)(REG_WIDTH(reg_idx)-1 downto 0) <= regs_arr(reg_idx)(REG_WIDTH(reg_idx)-1 downto 0);
                end if;
            end loop;
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
    sqtdbl_next_val <= std_logic_vector(unsigned(sqtdbl_reg) + 1) and regs_arr(R_DBL_MASK)(REG_WIDTH(R_DBL_MASK)-1 downto 0);
    -- The blocking when Submission Queue is full (measured over the whole time when TRIGG_DISPATCH
    -- is set in the contiguous mode)
    sq_write_blocking          <= '1' when (sqtdbl_next_val = sqhdbl_reg) else '0';
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
