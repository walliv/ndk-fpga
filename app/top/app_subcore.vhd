-- app_subcore.vhd: User application subcore
-- Copyright (C) 2023 CESNET z. s. p. o.
-- Author(s): Vladislav Valek <valekv@cesnet.cz>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.combo_user_const.all;

entity APP_SUBCORE is
    generic (
        -- MFB parameters
        MFB_REGIONS     : integer := 1;  -- Number of regions in word
        MFB_REGION_SIZE : integer := 2;  -- Number of blocks in region
        MFB_BLOCK_SIZE  : integer := 8;  -- Number of items in block
        MFB_ITEM_WIDTH  : integer := 8;  -- Width of one item in bits

        -- Maximum size of a User packet (in bytes)
        -- Defines width of Packet length signals.
        USR_PKT_SIZE_MAX : natural := 2**11
        );
    port (
        -- =========================================================================
        -- Clock and Resets inputs
        -- =========================================================================
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =====================================================================
        -- RX DMA User-side MFB
        -- =====================================================================
        DMA_RX_MFB_META_PKT_SIZE : out std_logic_vector(log2(USR_PKT_SIZE_MAX + 1) -1 downto 0);

        DMA_RX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        DMA_RX_MFB_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        DMA_RX_MFB_EOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        DMA_RX_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        DMA_RX_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        DMA_RX_MFB_SRC_RDY : out std_logic;
        DMA_RX_MFB_DST_RDY : in  std_logic
        );
end entity;

architecture FULL of APP_SUBCORE is

begin


end architecture;
