-- nvme_cmd_composer.vhd: this component creates a Submission Queue Entry for read and write
-- operations within NVM Command Set
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.type_pack.all;

entity NVME_CMD_COMPOSER is
    port (
        CMD_ID        : in std_logic_vector(15 downto 0);

        -- 00 - FLUSH
        -- 01 - WRITE
        -- 10 - READ
        CMD_OPCODE    : in std_logic_vector(1 downto 0);

        NAMESPACE_ID  : in std_logic_vector(31 downto 0);
        METADATA_PTR  : in std_logic_vector(63 downto 0);
        PRP_ENTRY_1   : in std_logic_vector(63 downto 0);
        PRP_ENTRY_2   : in std_logic_vector(63 downto 0);
        -- Start pointer of the LBA required to be read/written to.
        START_LBA_PTR : in std_logic_vector(63 downto 0);
        -- The amount of LBAs that will be read consecutively.
        LBA_NUM       : in std_logic_vector(15 downto 0);

        SQ_CMD_ENTRY : out std_logic_vector(511 downto 0));
end entity;

architecture FULL of NVME_CMD_COMPOSER is
    signal cmd_dwords : slv_array_t(15 downto 0)(31 downto 0);
begin
    cmd_dwords(0)  <= CMD_ID & "00000000000000" & CMD_OPCODE;
    cmd_dwords(1)  <= NAMESPACE_ID;
    cmd_dwords(2)  <= (others => '0');  -- Reserved
    cmd_dwords(3)  <= (others => '0');  -- Reserved
    cmd_dwords(4)  <= METADATA_PTR(31 downto 0);
    cmd_dwords(5)  <= METADATA_PTR(63 downto 32);
    cmd_dwords(6)  <= PRP_ENTRY_1(31 downto 0);
    cmd_dwords(7)  <= PRP_ENTRY_1(63 downto 32);
    cmd_dwords(8)  <= PRP_ENTRY_2(31 downto 0);
    cmd_dwords(9)  <= PRP_ENTRY_2(63 downto 32);
    cmd_dwords(10) <= START_LBA_PTR(31 downto 0);
    cmd_dwords(11) <= START_LBA_PTR(63 downto 32);
    cmd_dwords(12) <= x"0000" & LBA_NUM;
    cmd_dwords(13) <= (others => '0');  -- Dataset Management bits
    cmd_dwords(14) <= (others => '0');  -- Some stuff considered with end-to-end protection
    cmd_dwords(15) <= (others => '0');  -- Some other stuff considered with end-to-end protection

    SQ_CMD_ENTRY <= slv_array_ser(cmd_dwords);
end architecture;
