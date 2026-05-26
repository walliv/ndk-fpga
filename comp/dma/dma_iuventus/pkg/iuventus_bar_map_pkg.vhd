-- iuventus_bar_map_pkg.vhd: package containing mapping for the BARs 
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

package iuventus_bar_map_pkg is
    constant SQ_BAR_ID     : std_logic_vector(2 downto 0) := "000";
    constant CQ_BAR_ID     : std_logic_vector(2 downto 0) := "001";
    constant WRBUFF_BAR_ID : std_logic_vector(2 downto 0) := "010";
    constant RDBUFF_BAR_ID : std_logic_vector(2 downto 0) := "011";

    constant SQ_BAR_ID_INT     : integer := to_integer(unsigned(SQ_BAR_ID));
    constant CQ_BAR_ID_INT     : integer := to_integer(unsigned(CQ_BAR_ID));
    constant WRBUFF_BAR_ID_INT : integer := to_integer(unsigned(WRBUFF_BAR_ID));
    constant RDBUFF_BAR_ID_INT : integer := to_integer(unsigned(RDBUFF_BAR_ID));

    constant SQ_BUFF_CHAN : std_logic := '1';
    constant CQ_BUFF_CHAN : std_logic := '1';
    constant WRBUFF_CHAN  : std_logic := '0';
    constant RDBUFF_CHAN  : std_logic := '0';
end package;

package body iuventus_bar_map_pkg is
end package body;
