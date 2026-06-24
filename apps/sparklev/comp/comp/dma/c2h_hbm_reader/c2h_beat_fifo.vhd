-- c2h_beat_fifo.vhd: Individual-register FWFT FIFO (nvc 1.21.0 compatible)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0
--
-- nvc 1.21.0 workaround: ALL array-based storage (custom array types, slv_array_t,
-- std_logic_vector slice assignment, for-loop over array elements) is unreliable
-- in nvc 1.21.0 for signals with entity-generic-derived widths.
-- This implementation uses 16 INDIVIDUAL signal declarations (r00..r15) and
-- explicit static shift chains -- NO arrays, NO dynamic indexing, NO loops.
--
-- Layout (shift-register FIFO): r00 = newest item, r{count-1} = oldest (= DOUT).
-- Write: new data enters r00; existing items shift toward higher registers.
-- Read:  decrement `count` only (no data movement; the mux naturally reveals the next item).
-- DOUT:  static conditional mux on `count` (no to_integer, no arrays).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;

-- DEPTH is fixed at 16 for the static 16-entry implementation.
entity C2H_BEAT_FIFO is
    generic (
        WORD_WIDTH : natural;
        DEPTH      : natural := 16
    );
    port (
        CLK   : in  std_logic;
        RESET : in  std_logic;

        DIN   : in  std_logic_vector(WORD_WIDTH-1 downto 0);
        WR    : in  std_logic;
        FULL  : out std_logic;

        DOUT  : out std_logic_vector(WORD_WIDTH-1 downto 0);
        RD    : in  std_logic;
        EMPTY : out std_logic
    );
end entity;

architecture BEHAVIORAL of C2H_BEAT_FIFO is
    -- 16 individual slot registers: r00 = newest, r{count-1} = oldest.
    signal r00, r01, r02, r03 : std_logic_vector(WORD_WIDTH-1 downto 0) := (others => '0');
    signal r04, r05, r06, r07 : std_logic_vector(WORD_WIDTH-1 downto 0) := (others => '0');
    signal r08, r09, r10, r11 : std_logic_vector(WORD_WIDTH-1 downto 0) := (others => '0');
    signal r12, r13, r14, r15 : std_logic_vector(WORD_WIDTH-1 downto 0) := (others => '0');

    signal count  : unsigned(4 downto 0) := (others => '0');  -- 0 to 16

    signal full_s  : std_logic;
    signal empty_s : std_logic;
begin
    full_s  <= '1' when count = to_unsigned(16, 5) else '0';
    empty_s <= '1' when count = to_unsigned(0,  5) else '0';

    FULL  <= full_s;
    EMPTY <= empty_s;

    -- Output mux: select oldest item r{count-1}.
    -- Purely static signal references; no to_integer, no array indexing.
    DOUT <= r00 when count = to_unsigned(1,  5) else
            r01 when count = to_unsigned(2,  5) else
            r02 when count = to_unsigned(3,  5) else
            r03 when count = to_unsigned(4,  5) else
            r04 when count = to_unsigned(5,  5) else
            r05 when count = to_unsigned(6,  5) else
            r06 when count = to_unsigned(7,  5) else
            r07 when count = to_unsigned(8,  5) else
            r08 when count = to_unsigned(9,  5) else
            r09 when count = to_unsigned(10, 5) else
            r10 when count = to_unsigned(11, 5) else
            r11 when count = to_unsigned(12, 5) else
            r12 when count = to_unsigned(13, 5) else
            r13 when count = to_unsigned(14, 5) else
            r14 when count = to_unsigned(15, 5) else
            r15 when count = to_unsigned(16, 5) else
            (others => '0');

    process (CLK)
        variable do_wr : std_logic;
        variable do_rd : std_logic;
    begin
        if rising_edge(CLK) then
            if RESET = '1' then
                r00 <= (others => '0'); r01 <= (others => '0');
                r02 <= (others => '0'); r03 <= (others => '0');
                r04 <= (others => '0'); r05 <= (others => '0');
                r06 <= (others => '0'); r07 <= (others => '0');
                r08 <= (others => '0'); r09 <= (others => '0');
                r10 <= (others => '0'); r11 <= (others => '0');
                r12 <= (others => '0'); r13 <= (others => '0');
                r14 <= (others => '0'); r15 <= (others => '0');
                count <= (others => '0');
            else
                do_wr := WR and (not full_s);
                do_rd := RD and (not empty_s);

                -- Write: shift existing items toward higher registers; new item into r00.
                -- All assignments are static (no loops, no dynamic indexing).
                if do_wr = '1' then
                    r00 <= DIN;
                    r01 <= r00; r02 <= r01; r03 <= r02; r04 <= r03;
                    r05 <= r04; r06 <= r05; r07 <= r06; r08 <= r07;
                    r09 <= r08; r10 <= r09; r11 <= r10; r12 <= r11;
                    r13 <= r12; r14 <= r13; r15 <= r14;
                end if;

                -- Read: just shrink the valid window; DOUT mux picks the new oldest.
                if do_wr = '1' and do_rd = '0' then
                    count <= count + 1;
                elsif do_wr = '0' and do_rd = '1' then
                    count <= count - 1;
                end if;
            end if;
        end if;
    end process;
end architecture;
