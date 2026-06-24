-- h2c_meta_pkg.vhd: package containing the structure of metadata signal inside the controller
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.pcie_meta_pack.all;

package h2c_meta_pkg is
    generic (
        MFB_REGION_SIZE : positive;
        MFB_BLOCK_SIZE  : positive;
        MFB_ITEM_WIDTH  : positive);

    constant META_PCIE_ADDR_W  : natural := 62;
    constant META_BE_W         : natural := (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8;
    constant META_BYTE_CNT_W   : natural := 13;

    constant META_PCIE_ADDR_O  : natural := 0;
    constant META_BE_O         : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    constant META_BYTE_CNT_O   : natural := META_BE_O + META_BE_W;

    subtype META_PCIE_ADDR is natural range META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O;
    subtype META_BE is natural range META_BE_O + META_BE_W -1 downto META_BE_O;
    subtype META_BYTE_CNT is natural range META_BYTE_CNT_O + META_BYTE_CNT_W -1 downto META_BYTE_CNT_O;
end package;

package body h2c_meta_pkg is
end package body;
