-- stat_cntr.vhd: a statistics counter with variable increment value
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

entity STAT_CNTR is

    generic (
        CNTR_WIDTH : positive := 64);

    port (
        CLK       : in  std_logic;
        RST       : in  std_logic;
        CE        : in  std_logic;
        INCR_VAL  : in  std_logic_vector(CNTR_WIDTH -1 downto 0);
        OUT_COUNT : out std_logic_vector(CNTR_WIDTH -1 downto 0));

end entity;

architecture FULL of STAT_CNTR is
    signal cntr_int : unsigned(CNTR_WIDTH -1 downto 0);
begin
    stat_cntr_i : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                cntr_int <= (others => '0');
            elsif (CE = '1') then
                cntr_int <= cntr_int + unsigned(INCR_VAL);
            end if;
        end if;
    end process;

    OUT_COUNT <= std_logic_vector(cntr_int);
end architecture;
