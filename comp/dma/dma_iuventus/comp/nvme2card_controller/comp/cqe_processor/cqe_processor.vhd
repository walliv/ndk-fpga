-- cqe_processor.vhd: processing of Completion Queue Entries
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.nvme_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity CQE_PROCESSOR is
    generic (
        DEVICE : string := "ULTRASCALE";

        -- THe width of data read from the DATA_BUFF
        DATA_WIDTH : positive := 512;
        -- The size of a pointer to a sector in the internal buffer
        BUFF_POINTER_WIDTH : natural := 16
        );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- Start/stop interface
        -- =========================================================================================
        START_REQ_VLD : in  std_logic;
        START_REQ_ACK : out std_logic;
        STOP_REQ_VLD  : in  std_logic;
        STOP_REQ_ACK  : out std_logic;

        -- =========================================================================================
        -- Reading interface to the data buffer
        -- =========================================================================================
        DATA_BUFF_RD_CHAN     : out std_logic_vector(0 downto 0);
        DATA_BUFF_RD_DATA     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        DATA_BUFF_RD_ADDR     : out std_logic_vector(BUFF_POINTER_WIDTH -1 downto 0);
        DATA_BUFF_RD_EN       : out std_logic;
        -- Multiple region support
        DATA_BUFF_RD_DATA_VLD : in  std_logic;

        -- =========================================================================================
        -- Interface to the C/S registers
        --
        -- For pointer update and incrementing of packet counter.
        -- =========================================================================================
        DBL_MASK        : in  std_logic_vector(15 downto 0);
        SQHDBL_UPD_DATA : out std_logic_vector(15 downto 0);
        CQHDBL_UPD_DATA : out std_logic_vector(15 downto 0);
        LAST_CQ_ENTRY   : out std_logic_vector(CQ_ENTRY_RANGE);
        STATUS_UPD_EN   : out std_logic
        );
end entity;

architecture FULL of CQE_PROCESSOR is
    -- The amount of CQ Entries that fit to one output word of the data buffer
    constant DATA_SEGMENTS : natural := DATA_WIDTH/CQ_ENTRY_WIDTH;

    signal cqhdbl_pst : unsigned(15 downto 0);
    signal cqhdbl_nst : unsigned(15 downto 0);

    signal buff_data_segm           : slv_array_t(DATA_SEGMENTS -1 downto 0)(CQ_ENTRY_WIDTH -1 downto 0);
    -- It is a vector of size 1 since I compare it with a single-bit value returned by a range
    signal observed_phase_value_reg : std_logic_vector(0 downto 0);
    signal observed_phase_value_nst : std_logic_vector(0 downto 0);
    signal comp_enabled             : std_logic;
begin

    assert (DATA_WIDTH = 512)
        report "CQE_PROCESSOR: Design has only been tested with data width of 512 bits!"
        severity FAILURE;

    -- =============================================================================================
    -- Start/stop logic
    -- =============================================================================================
    start_stop_fsm_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                comp_enabled  <= '0';
                START_REQ_ACK <= '0';
                STOP_REQ_ACK  <= '0';
            else
                START_REQ_ACK <= '0';
                STOP_REQ_ACK  <= '0';

                if (START_REQ_VLD = '1') then
                    comp_enabled  <= '1';
                    START_REQ_ACK <= '1';
                    
                elsif (STOP_REQ_VLD = '1') then
                    comp_enabled  <= '0';
                    STOP_REQ_ACK  <= '1';
                end if;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- FSM Controlling read from the data buffer and from the Completion Queue
    -- =============================================================================================
    cqhdbl_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            -- The running parametrs get reset when a new start request comes on a disabled 
            -- component
            if (RESET = '1' or (START_REQ_VLD = '1' and comp_enabled = '0')) then
                cqhdbl_pst               <= (others => '0');
                observed_phase_value_reg <= "1";
            else
                cqhdbl_pst               <= cqhdbl_nst;
                observed_phase_value_reg <= observed_phase_value_nst;
            end if;
        end if;
    end process;

    buff_data_segm_g : for segm_idx in 0 to (DATA_SEGMENTS-1) generate
        buff_data_segm(segm_idx) <= DATA_BUFF_RD_DATA(CQ_ENTRY_WIDTH + segm_idx*CQ_ENTRY_WIDTH -1 downto segm_idx*CQ_ENTRY_WIDTH);
    end generate;

    DATA_BUFF_RD_CHAN(0) <= CQ_BUFF_CHAN;
    DATA_BUFF_RD_EN      <= '1';

    -- This machine expects data next clock
    pkt_dispatch_fsm_output_logic_p : process (all) is
        variable segm_idx   : natural range 0 to 3;
        variable cqhdbl_tmp : unsigned(cqhdbl_pst'range);
    begin
        cqhdbl_tmp               := (cqhdbl_pst + 1) and unsigned(DBL_MASK);
        cqhdbl_nst               <= cqhdbl_pst;
        observed_phase_value_nst <= observed_phase_value_reg;

        SQHDBL_UPD_DATA <= (others => '0');
        CQHDBL_UPD_DATA <= (others => '0');
        LAST_CQ_ENTRY   <= (others => '0');
        STATUS_UPD_EN   <= '0';

        DATA_BUFF_RD_ADDR <= std_logic_vector(resize(cqhdbl_pst(15 downto 2), DATA_BUFF_RD_ADDR'length - 6)) & "000000";

        -- WARNING: There can be a problem when RD_DATA_VLD = '0'
        if (comp_enabled = '1' and DATA_BUFF_RD_DATA_VLD = '1' and DBL_MASK /= x"0000") then
            segm_idx := to_integer(cqhdbl_pst(1 downto 0));
            -- If a valid CQ entry is found then update status information
            if (buff_data_segm(segm_idx)(CQ_ENTRY_PHASE_TAG) = observed_phase_value_reg) then
                SQHDBL_UPD_DATA <= buff_data_segm(segm_idx)(CQ_ENTRY_SQHD) and DBL_MASK;
                CQHDBL_UPD_DATA <= std_logic_vector(cqhdbl_tmp);
                LAST_CQ_ENTRY   <= buff_data_segm(segm_idx);
                STATUS_UPD_EN   <= '1';

                cqhdbl_nst <= cqhdbl_tmp;

                -- If the doorbell is going to roll over to the beginning, the NVME controller
                -- starts to send CQ Entries with inverted Phase Tags.
                if (cqhdbl_tmp = x"0000") then
                    observed_phase_value_nst <= not observed_phase_value_reg;
                end if;

                -- If valid data arrived and we are on the last segment of a word, set the next
                -- address to the transaction buffer
                if (segm_idx = 3) then
                    DATA_BUFF_RD_ADDR <= std_logic_vector(resize(cqhdbl_tmp(15 downto 2), DATA_BUFF_RD_ADDR'length - 6)) & "000000";
                end if;
            end if;
        end if;
    end process;
end architecture;
