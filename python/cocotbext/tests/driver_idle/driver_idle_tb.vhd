-- driver_idle_tb.vhd: top level whose every port the driver bench drives, DST_RDY included
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;

use work.math_pack.all;

-- Only inputs: the bench plays the sink, so it decides DST_RDY in every cycle while the drivers send.
entity DRIVER_IDLE_TB is
    generic (
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 4;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 8;
        MVB_ITEMS       : natural := 4;
        MVB_ITEM_WIDTH  : natural := 16
    );
    port (
        CLK : in    std_logic;

        RX_MFB_DATA    : in    std_logic_vector(MFB_REGIONS * MFB_REGION_SIZE * MFB_BLOCK_SIZE * MFB_ITEM_WIDTH - 1 downto 0);
        RX_MFB_SOF     : in    std_logic_vector(MFB_REGIONS - 1 downto 0);
        RX_MFB_EOF     : in    std_logic_vector(MFB_REGIONS - 1 downto 0);
        RX_MFB_SOF_POS : in    std_logic_vector(MFB_REGIONS * max(1, log2(MFB_REGION_SIZE)) - 1 downto 0);
        RX_MFB_EOF_POS : in    std_logic_vector(MFB_REGIONS * max(1, log2(MFB_REGION_SIZE * MFB_BLOCK_SIZE)) - 1 downto 0);
        RX_MFB_SRC_RDY : in    std_logic;
        RX_MFB_DST_RDY : in    std_logic;
        RX_MFB_BE      : in    std_logic_vector(MFB_REGIONS * MFB_REGION_SIZE * MFB_BLOCK_SIZE * MFB_ITEM_WIDTH / 8 - 1 downto 0);

        RX_MVB_DATA    : in    std_logic_vector(MVB_ITEMS * MVB_ITEM_WIDTH - 1 downto 0);
        RX_MVB_VLD     : in    std_logic_vector(MVB_ITEMS - 1 downto 0);
        RX_MVB_SRC_RDY : in    std_logic;
        RX_MVB_DST_RDY : in    std_logic
    );
end entity;

architecture FULL of DRIVER_IDLE_TB is

begin

end architecture;
