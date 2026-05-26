-- nvme_meta_pack.vhd: The package containing elements of important NVMe datastructures
-- Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;

-- NOTE: The items have been declared according to the NVMe specification v.1.2a (because why would
-- you need newer if your SSD does not support it :)

-- **Completion Queue Entry items description:**
--
-- ============== ============ =======================================================================================================
-- Item bit range Item name    Item description
-- ============== ============ =======================================================================================================
-- 0   to 31      CMD_SPECIFIC Based on command being completed, otherwise reserved
-- 32  to 63      RSV1         Nothing
-- 64  to 79      SQHD         The value of Submission Queue header pointer (the reading pointer)
-- 80  to 95      SQID         Index of a Submission Queue to which the current completion belongs
-- 96  to 111     CID          Command Identifier of the command being completed (paired with SQ ID as a unique identifier)
-- 112            P            Phase Tag - Indicates that an entry is new
-- 113 to 120     SC           Status Code - Error or status information about the completed command
-- 121 to 123     SCT          Indicates an SC type (Generic/Command specific/Vendor specific, etc.)
-- 124 to 125     RSV2         Nothing again
-- 126            M            More - Set to 1 if there are more status information (can be retrieved using the Get Log Page command)
-- 127            DNR          Do Not Retry - asserted means that repeated submission of the same command will fail
-- ============== ============ =======================================================================================================

package nvme_meta_pack is

    -- =============================================================================================
    -- Sumbmission entry fields definitions
    -- =============================================================================================
    constant SQE_LBA_PTR_W     : natural := 64;

    -- =============================================================================================
    -- Completion entry fields definitions
    -- =============================================================================================
    constant CQ_ENTRY_CMD_SPECIFIC_W : natural := 32;
    constant CQ_ENTRY_RSV1_W         : natural := 32;
    constant CQ_ENTRY_SQHD_W         : natural := 16;
    constant CQ_ENTRY_SQID_W         : natural := 16;
    constant CQ_ENTRY_CMD_ID_W       : natural := 16;
    constant CQ_ENTRY_PHASE_TAG_W    : natural := 1;
    constant CQ_ENTRY_STAT_CODE_W    : natural := 8;
    constant CQ_ENTRY_SC_TYPE_W      : natural := 3;
    constant CQ_ENTRY_RSV2_W         : natural := 2;
    constant CQ_ENTRY_MORE_W         : natural := 1;
    constant CQ_ENTRY_DNR_W          : natural := 1;

    constant CQ_ENTRY_CMD_SPECIFIC_O : natural := 0;
    constant CQ_ENTRY_RSV1_O         : natural := CQ_ENTRY_CMD_SPECIFIC_O + CQ_ENTRY_CMD_SPECIFIC_W;
    constant CQ_ENTRY_SQHD_O         : natural := CQ_ENTRY_RSV1_O         + CQ_ENTRY_RSV1_W        ;
    constant CQ_ENTRY_SQID_O         : natural := CQ_ENTRY_SQHD_O         + CQ_ENTRY_SQHD_W        ;
    constant CQ_ENTRY_CMD_ID_O       : natural := CQ_ENTRY_SQID_O         + CQ_ENTRY_SQID_W        ;
    constant CQ_ENTRY_PHASE_TAG_O    : natural := CQ_ENTRY_CMD_ID_O       + CQ_ENTRY_CMD_ID_W      ;
    constant CQ_ENTRY_STAT_CODE_O    : natural := CQ_ENTRY_PHASE_TAG_O    + CQ_ENTRY_PHASE_TAG_W   ;
    constant CQ_ENTRY_SC_TYPE_O      : natural := CQ_ENTRY_STAT_CODE_O    + CQ_ENTRY_STAT_CODE_W   ;
    constant CQ_ENTRY_RSV2_O         : natural := CQ_ENTRY_SC_TYPE_O      + CQ_ENTRY_SC_TYPE_W     ;
    constant CQ_ENTRY_MORE_O         : natural := CQ_ENTRY_RSV2_O         + CQ_ENTRY_RSV2_W        ;
    constant CQ_ENTRY_DNR_O          : natural := CQ_ENTRY_MORE_O         + CQ_ENTRY_MORE_W        ;

    subtype CQ_ENTRY_CMD_SPECIFIC is natural range CQ_ENTRY_CMD_SPECIFIC_O + CQ_ENTRY_CMD_SPECIFIC_W -1 downto CQ_ENTRY_CMD_SPECIFIC_O;
    subtype CQ_ENTRY_RSV1         is natural range CQ_ENTRY_RSV1_O         + CQ_ENTRY_RSV1_W         -1 downto CQ_ENTRY_RSV1_O        ;
    subtype CQ_ENTRY_SQHD         is natural range CQ_ENTRY_SQHD_O         + CQ_ENTRY_SQHD_W         -1 downto CQ_ENTRY_SQHD_O        ;
    subtype CQ_ENTRY_SQID         is natural range CQ_ENTRY_SQID_O         + CQ_ENTRY_SQID_W         -1 downto CQ_ENTRY_SQID_O        ;
    subtype CQ_ENTRY_CMD_ID       is natural range CQ_ENTRY_CMD_ID_O       + CQ_ENTRY_CMD_ID_W       -1 downto CQ_ENTRY_CMD_ID_O      ;
    subtype CQ_ENTRY_PHASE_TAG    is natural range CQ_ENTRY_PHASE_TAG_O    + CQ_ENTRY_PHASE_TAG_W    -1 downto CQ_ENTRY_PHASE_TAG_O   ;
    subtype CQ_ENTRY_STAT_CODE    is natural range CQ_ENTRY_STAT_CODE_O    + CQ_ENTRY_STAT_CODE_W    -1 downto CQ_ENTRY_STAT_CODE_O   ;
    subtype CQ_ENTRY_SC_TYPE      is natural range CQ_ENTRY_SC_TYPE_O      + CQ_ENTRY_SC_TYPE_W      -1 downto CQ_ENTRY_SC_TYPE_O     ;
    subtype CQ_ENTRY_RSV2         is natural range CQ_ENTRY_RSV2_O         + CQ_ENTRY_RSV2_W         -1 downto CQ_ENTRY_RSV2_O        ;
    subtype CQ_ENTRY_MORE         is natural range CQ_ENTRY_MORE_O         + CQ_ENTRY_MORE_W         -1 downto CQ_ENTRY_MORE_O        ;
    subtype CQ_ENTRY_DNR          is natural range CQ_ENTRY_DNR_O          + CQ_ENTRY_DNR_W          -1 downto CQ_ENTRY_DNR_O         ;

    constant CQ_ENTRY_WIDTH      : natural := CQ_ENTRY_DNR_O + CQ_ENTRY_DNR_W;
    constant CQ_ENTRY_BYTE_WIDTH : natural := CQ_ENTRY_WIDTH / 8;

    subtype CQ_ENTRY_RANGE is natural range  CQ_ENTRY_WIDTH -1 downto 0;

    -- =============================================================================================
    -- Status code type (SCT) field values
    -- =============================================================================================
    constant SCT_GENERIC_CMD          : std_logic_vector(2 downto 0) := "000";
    constant SCT_CMD_SPECIFIC         : std_logic_vector(2 downto 0) := "001";
    constant SCT_MEDIA_DATA_INTEGRITY : std_logic_vector(2 downto 0) := "010";
    constant SCT_VENDOR_SPECIFIC      : std_logic_vector(2 downto 0) := "111";

    -- =============================================================================================
    -- Status codes (SC) based on the SCT value
    -- =============================================================================================
    -- Generic Command status codes (all command sets)
    constant SC_SUCCESS                     : std_logic_vector(7 downto 0) := x"00";
    constant SC_INVALID_OPCODE              : std_logic_vector(7 downto 0) := x"01";
    constant SC_INVALID_FIELD               : std_logic_vector(7 downto 0) := x"02";
    constant SC_COMMAND_ID_CONFLICT         : std_logic_vector(7 downto 0) := x"03";
    constant SC_DATA_TRANSFER_ERROR         : std_logic_vector(7 downto 0) := x"04";
    constant SC_ABORTED_BY_POWER_LOSS       : std_logic_vector(7 downto 0) := x"05";
    constant SC_INTERNAL_ERROR              : std_logic_vector(7 downto 0) := x"06";
    constant SC_ABORT_REQUESTED             : std_logic_vector(7 downto 0) := x"07";
    constant SC_ABORT_DUE_TO_SQ_DELETE      : std_logic_vector(7 downto 0) := x"08";
    constant SC_ABORT_FAILED_FUSED          : std_logic_vector(7 downto 0) := x"09";
    constant SC_ABORT_MISSING_FUSED         : std_logic_vector(7 downto 0) := x"0A";
    constant SC_INVALID_NAMESPACE_OR_FORMAT : std_logic_vector(7 downto 0) := x"0B";
    constant SC_COMMAND_SEQ_ERROR           : std_logic_vector(7 downto 0) := x"0C";
    constant SC_INVALID_SGL_SEGMENT         : std_logic_vector(7 downto 0) := x"0D";
    constant SC_INVALID_NUM_SGL_DESCRIPTORS : std_logic_vector(7 downto 0) := x"0E";
    constant SC_DATA_SGL_LENGTH_INVALID     : std_logic_vector(7 downto 0) := x"0F";
    constant SC_METADATA_SGL_LENGTH_INVALID : std_logic_vector(7 downto 0) := x"10";
    constant SC_SGL_DESCRIPTOR_TYPE_INVALID : std_logic_vector(7 downto 0) := x"11";
    constant SC_INVALID_USE_CMB             : std_logic_vector(7 downto 0) := x"12";
    constant SC_PRP_OFFSET_INVALID          : std_logic_vector(7 downto 0) := x"13";
    constant SC_ATOMIC_WRITE_UNIT_EXCEEDED  : std_logic_vector(7 downto 0) := x"14";

    -- Generic Command status codes (NVME command set)
    constant SC_LBA_OUT_OF_RANGE     : std_logic_vector(7 downto 0) := x"80";
    constant SC_CAPACITY_EXCEEDED    : std_logic_vector(7 downto 0) := x"81";
    constant SC_NAMESPACE_NOT_READY  : std_logic_vector(7 downto 0) := x"82";
    constant SC_RESERVATION_CONFLICT : std_logic_vector(7 downto 0) := x"83";
    constant SC_FORMAT_IN_PROGRESS   : std_logic_vector(7 downto 0) := x"84";

    -- Command specific status codes (NVME command set)
    constant SC_CONFLICTING_ATTRS     : std_logic_vector(7 downto 0) := x"80";  -- for Read, Write
    constant SC_INVALID_PROT_INFO     : std_logic_vector(7 downto 0) := x"81";  -- for Read, Write
    constant SC_ATTEMT_WR_TO_RO_RANGE : std_logic_vector(7 downto 0) := x"82";  -- for Write

    -- Media and Data Integrity Error Codes (NVME command set)
    constant SC_WRITE_FAULT                  : std_logic_vector(7 downto 0) := x"80";
    constant SC_UNRECOVERED_READ_ERROR       : std_logic_vector(7 downto 0) := x"81";
    constant SC_E2E_GUARD_CHECK_ERROR        : std_logic_vector(7 downto 0) := x"82";
    constant SC_E2E_APP_TAG_CHECK_ERROR      : std_logic_vector(7 downto 0) := x"83";
    constant SC_E2E_REF_TAG_CHECK_ERROR      : std_logic_vector(7 downto 0) := x"84";
    constant SC_COMPARE_FAILURE              : std_logic_vector(7 downto 0) := x"85";
    constant SC_ACCESS_DENIED                : std_logic_vector(7 downto 0) := x"86";
    constant SC_DEALLOCATED_OR_UNWRITTEN_LBA : std_logic_vector(7 downto 0) := x"87";

    type status_code_info_r is record
        SCT : std_logic_vector(CQ_ENTRY_SC_TYPE_W -1 downto 0);
        SC  : std_logic_vector(CQ_ENTRY_STAT_CODE_W -1 downto 0);
    end record;

    constant NUM_ERROR_CODES : integer := 36;

    type status_code_t is array(0 to NUM_ERROR_CODES - 1) of status_code_info_r;
    constant ERROR_CODES : status_code_t := (
        (SCT => SCT_GENERIC_CMD, SC => SC_INVALID_OPCODE),
        (SCT => SCT_GENERIC_CMD, SC => SC_INVALID_FIELD),
        (SCT => SCT_GENERIC_CMD, SC => SC_COMMAND_ID_CONFLICT),
        (SCT => SCT_GENERIC_CMD, SC => SC_DATA_TRANSFER_ERROR),
        (SCT => SCT_GENERIC_CMD, SC => SC_ABORTED_BY_POWER_LOSS),
        (SCT => SCT_GENERIC_CMD, SC => SC_INTERNAL_ERROR),
        (SCT => SCT_GENERIC_CMD, SC => SC_ABORT_REQUESTED),
        (SCT => SCT_GENERIC_CMD, SC => SC_ABORT_DUE_TO_SQ_DELETE),
        (SCT => SCT_GENERIC_CMD, SC => SC_ABORT_FAILED_FUSED),
        (SCT => SCT_GENERIC_CMD, SC => SC_ABORT_MISSING_FUSED),
        (SCT => SCT_GENERIC_CMD, SC => SC_INVALID_NAMESPACE_OR_FORMAT),
        (SCT => SCT_GENERIC_CMD, SC => SC_COMMAND_SEQ_ERROR),
        (SCT => SCT_GENERIC_CMD, SC => SC_INVALID_SGL_SEGMENT),
        (SCT => SCT_GENERIC_CMD, SC => SC_INVALID_NUM_SGL_DESCRIPTORS),
        (SCT => SCT_GENERIC_CMD, SC => SC_DATA_SGL_LENGTH_INVALID),
        (SCT => SCT_GENERIC_CMD, SC => SC_METADATA_SGL_LENGTH_INVALID),
        (SCT => SCT_GENERIC_CMD, SC => SC_SGL_DESCRIPTOR_TYPE_INVALID),
        (SCT => SCT_GENERIC_CMD, SC => SC_INVALID_USE_CMB),
        (SCT => SCT_GENERIC_CMD, SC => SC_PRP_OFFSET_INVALID),
        (SCT => SCT_GENERIC_CMD, SC => SC_ATOMIC_WRITE_UNIT_EXCEEDED),

        (SCT => SCT_GENERIC_CMD, SC => SC_LBA_OUT_OF_RANGE),
        (SCT => SCT_GENERIC_CMD, SC => SC_CAPACITY_EXCEEDED),
        (SCT => SCT_GENERIC_CMD, SC => SC_NAMESPACE_NOT_READY),
        (SCT => SCT_GENERIC_CMD, SC => SC_RESERVATION_CONFLICT),
        (SCT => SCT_GENERIC_CMD, SC => SC_FORMAT_IN_PROGRESS),

        (SCT => SCT_CMD_SPECIFIC, SC => SC_CONFLICTING_ATTRS),
        (SCT => SCT_CMD_SPECIFIC, SC => SC_INVALID_PROT_INFO),
        (SCT => SCT_CMD_SPECIFIC, SC => SC_ATTEMT_WR_TO_RO_RANGE),

        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_WRITE_FAULT),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_UNRECOVERED_READ_ERROR),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_E2E_GUARD_CHECK_ERROR),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_E2E_APP_TAG_CHECK_ERROR),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_E2E_REF_TAG_CHECK_ERROR),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_COMPARE_FAILURE),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_ACCESS_DENIED),
        (SCT => SCT_MEDIA_DATA_INTEGRITY, SC => SC_DEALLOCATED_OR_UNWRITTEN_LBA)
    );

    constant ERR_MASK_W : integer := ((NUM_ERROR_CODES + 31) / 32) * 32;

    constant CMD_OPCODE_W : natural := 2;
    constant FLUSH_CMD_OPCODE : std_logic_vector(CMD_OPCODE_W -1 downto 0) := "00";
    constant WR_CMD_OPCODE    : std_logic_vector(CMD_OPCODE_W -1 downto 0) := "01";
    constant RD_CMD_OPCODE    : std_logic_vector(CMD_OPCODE_W -1 downto 0) := "10";
end package;

package body nvme_meta_pack is
end package body;
