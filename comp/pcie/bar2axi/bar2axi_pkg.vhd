-- bar2axi_pkg.vhd: Descriptor layouts shared by the PCIE_BAR2AXI sub-components
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

-- Non-posted request descriptor (NPD) passed from the CQ intake via the read engine to the
-- completion engine.
package bar2axi_pkg is

    -- answer with an Unsupported Request completion, no AXI access
    constant NPD_UR_W   : natural := 1;
    -- Byte Count and Lower Address of the first completion
    constant NPD_BC_W   : natural := 13;
    constant NPD_LA_W   : natural := 7;
    -- AXI byte address of the first requested DW
    constant NPD_ADDR_W : natural := 64;
    -- requested length in DWs
    constant NPD_DW_W   : natural := 11;
    -- 128 B chunks, i.e. completions, the request spans; 0 for UR
    constant NPD_NCH_W  : natural := 6;
    -- end of the requested bytes, as an offset from the first chunk's start
    constant NPD_ENDO_W : natural := 13;
    -- request fields echoed in the completion
    constant NPD_TAG_W  : natural := 8;
    constant NPD_RID_W  : natural := 16;
    constant NPD_TC_W   : natural := 3;
    constant NPD_ATTR_W : natural := 3;
    constant NPD_AT_W   : natural := 2;
    constant NPD_FUNC_W : natural := 8;

    constant NPD_UR_O   : natural := 0;
    constant NPD_BC_O   : natural := NPD_UR_O   + NPD_UR_W;
    constant NPD_LA_O   : natural := NPD_BC_O   + NPD_BC_W;
    constant NPD_ADDR_O : natural := NPD_LA_O   + NPD_LA_W;
    constant NPD_DW_O   : natural := NPD_ADDR_O + NPD_ADDR_W;
    constant NPD_NCH_O  : natural := NPD_DW_O   + NPD_DW_W;
    constant NPD_ENDO_O : natural := NPD_NCH_O  + NPD_NCH_W;
    constant NPD_TAG_O  : natural := NPD_ENDO_O + NPD_ENDO_W;
    constant NPD_RID_O  : natural := NPD_TAG_O  + NPD_TAG_W;
    constant NPD_TC_O   : natural := NPD_RID_O  + NPD_RID_W;
    constant NPD_ATTR_O : natural := NPD_TC_O   + NPD_TC_W;
    constant NPD_AT_O   : natural := NPD_ATTR_O + NPD_ATTR_W;
    constant NPD_FUNC_O : natural := NPD_AT_O   + NPD_AT_W;

    constant NPD_WIDTH  : natural := NPD_FUNC_O + NPD_FUNC_W;

    subtype NPD_BC   is natural range NPD_BC_O   + NPD_BC_W   - 1 downto NPD_BC_O;
    subtype NPD_LA   is natural range NPD_LA_O   + NPD_LA_W   - 1 downto NPD_LA_O;
    subtype NPD_ADDR is natural range NPD_ADDR_O + NPD_ADDR_W - 1 downto NPD_ADDR_O;
    subtype NPD_DW   is natural range NPD_DW_O   + NPD_DW_W   - 1 downto NPD_DW_O;
    subtype NPD_NCH  is natural range NPD_NCH_O  + NPD_NCH_W  - 1 downto NPD_NCH_O;
    subtype NPD_ENDO is natural range NPD_ENDO_O + NPD_ENDO_W - 1 downto NPD_ENDO_O;
    subtype NPD_TAG  is natural range NPD_TAG_O  + NPD_TAG_W  - 1 downto NPD_TAG_O;
    subtype NPD_RID  is natural range NPD_RID_O  + NPD_RID_W  - 1 downto NPD_RID_O;
    subtype NPD_TC   is natural range NPD_TC_O   + NPD_TC_W   - 1 downto NPD_TC_O;
    subtype NPD_ATTR is natural range NPD_ATTR_O + NPD_ATTR_W - 1 downto NPD_ATTR_O;
    subtype NPD_AT   is natural range NPD_AT_O   + NPD_AT_W   - 1 downto NPD_AT_O;
    subtype NPD_FUNC is natural range NPD_FUNC_O + NPD_FUNC_W - 1 downto NPD_FUNC_O;

    -- Read completions are cut on 128 B address boundaries; the read buffer is managed in such chunks.
    constant CHUNK_BYTES : natural := 128;
    constant CHUNK_DWS   : natural := CHUNK_BYTES/4;

end package;
