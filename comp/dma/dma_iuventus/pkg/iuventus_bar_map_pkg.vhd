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
    -- Flat-addressed 2-BAR peer layout: physical PCIe BAR0 carries the SQ (flat page 0) and the
    -- Read Buffer (flat pages 1..127); physical PCIe BAR1 carries the CQ (flat page 0) and the
    -- Write Buffer (flat pages 1..127). These constants identify the four buffers with four
    -- distinct LOGICAL BAR_IDs; the (physical BAR_ID, flat page) pair coming off the PCIe header
    -- is translated to one of these logical IDs once, close to the PCIe input (see
    -- nvme_cq_meta_extractor.vhd), so that every existing BAR_ID-indexed counter/route downstream
    -- keeps working unchanged.
    constant SQ_BAR_ID     : std_logic_vector(2 downto 0) := "000";
    constant CQ_BAR_ID     : std_logic_vector(2 downto 0) := "001";
    constant WRBUFF_BAR_ID : std_logic_vector(2 downto 0) := "010";
    constant RDBUFF_BAR_ID : std_logic_vector(2 downto 0) := "011";

    constant SQ_BAR_ID_INT     : integer := to_integer(unsigned(SQ_BAR_ID));
    constant CQ_BAR_ID_INT     : integer := to_integer(unsigned(CQ_BAR_ID));
    constant WRBUFF_BAR_ID_INT : integer := to_integer(unsigned(WRBUFF_BAR_ID));
    constant RDBUFF_BAR_ID_INT : integer := to_integer(unsigned(RDBUFF_BAR_ID));
end package;

package body iuventus_bar_map_pkg is
end package body;
