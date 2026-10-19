-- pcie_axi_cpm5_pack.vhd: TUSER fields and straddle encoders of the 1024-bit CPM5 AXI4-Stream PCIe interfaces
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;

-- Layout per PG346 v3.4 Tables 24, 26, 28 and 30. A field present once per straddled TLP
-- (is_sopN_ptr, first_be, ...) is one range holding all four copies, TLP 0 in the lowest bits.
package pcie_axi_cpm5_pack is

    -- =============================================================================================
    -- Straddle geometry
    -- =============================================================================================
    -- TLPs that may start (and end) in one beat
    constant AXI1024_TLPS      : natural := 4;
    -- is_sopN_ptr counts 256-bit slots, is_eopN_ptr counts Dwords of the beat
    constant AXI1024_SOP_PTR_W : natural := 2;
    constant AXI1024_EOP_PTR_W : natural := 5;

    -- =============================================================================================
    -- 1024-bit AXI-Stream CQ Meta fields
    -- =============================================================================================
    constant AXI_CQ1024_BE_W          : natural := 128;
    constant AXI_CQ1024_FBE_W         : natural := 4*AXI1024_TLPS;
    constant AXI_CQ1024_LBE_W         : natural := 4*AXI1024_TLPS;
    constant AXI_CQ1024_SOP_W         : natural := AXI1024_TLPS;
    constant AXI_CQ1024_SOP_PTR_W     : natural := AXI1024_SOP_PTR_W*AXI1024_TLPS;
    constant AXI_CQ1024_EOP_W         : natural := AXI1024_TLPS;
    constant AXI_CQ1024_EOP_PTR_W     : natural := AXI1024_EOP_PTR_W*AXI1024_TLPS;
    constant AXI_CQ1024_DISCON_W      : natural := 1;
    constant AXI_CQ1024_RSV_W         : natural := 44;
    constant AXI_CQ1024_PARITY_W      : natural := 128;
    constant AXI_CQ1024_PASID_VLD_W   : natural := AXI1024_TLPS;
    constant AXI_CQ1024_PASID_W       : natural := 20*AXI1024_TLPS;
    constant AXI_CQ1024_PASID_EXE_W   : natural := AXI1024_TLPS;
    constant AXI_CQ1024_PASID_PMODE_W : natural := AXI1024_TLPS;
    constant AXI_CQ1024_POISONED_W    : natural := AXI1024_TLPS;

    constant AXI_CQ1024_BE_O          : natural := 0;
    constant AXI_CQ1024_FBE_O         : natural := AXI_CQ1024_BE_O          + AXI_CQ1024_BE_W;
    constant AXI_CQ1024_LBE_O         : natural := AXI_CQ1024_FBE_O         + AXI_CQ1024_FBE_W;
    constant AXI_CQ1024_SOP_O         : natural := AXI_CQ1024_LBE_O         + AXI_CQ1024_LBE_W;
    constant AXI_CQ1024_SOP_PTR_O     : natural := AXI_CQ1024_SOP_O         + AXI_CQ1024_SOP_W;
    constant AXI_CQ1024_EOP_O         : natural := AXI_CQ1024_SOP_PTR_O     + AXI_CQ1024_SOP_PTR_W;
    constant AXI_CQ1024_EOP_PTR_O     : natural := AXI_CQ1024_EOP_O         + AXI_CQ1024_EOP_W;
    constant AXI_CQ1024_DISCON_O      : natural := AXI_CQ1024_EOP_PTR_O     + AXI_CQ1024_EOP_PTR_W;
    constant AXI_CQ1024_RSV_O         : natural := AXI_CQ1024_DISCON_O      + AXI_CQ1024_DISCON_W;
    constant AXI_CQ1024_PARITY_O      : natural := AXI_CQ1024_RSV_O         + AXI_CQ1024_RSV_W;
    constant AXI_CQ1024_PASID_VLD_O   : natural := AXI_CQ1024_PARITY_O      + AXI_CQ1024_PARITY_W;
    constant AXI_CQ1024_PASID_O       : natural := AXI_CQ1024_PASID_VLD_O   + AXI_CQ1024_PASID_VLD_W;
    constant AXI_CQ1024_PASID_EXE_O   : natural := AXI_CQ1024_PASID_O       + AXI_CQ1024_PASID_W;
    constant AXI_CQ1024_PASID_PMODE_O : natural := AXI_CQ1024_PASID_EXE_O   + AXI_CQ1024_PASID_EXE_W;
    constant AXI_CQ1024_POISONED_O    : natural := AXI_CQ1024_PASID_PMODE_O + AXI_CQ1024_PASID_PMODE_W;

    subtype AXI_CQ1024_BE is natural range AXI_CQ1024_BE_O + AXI_CQ1024_BE_W -1 downto AXI_CQ1024_BE_O;
    subtype AXI_CQ1024_FBE is natural range AXI_CQ1024_FBE_O + AXI_CQ1024_FBE_W -1 downto AXI_CQ1024_FBE_O;
    subtype AXI_CQ1024_LBE is natural range AXI_CQ1024_LBE_O + AXI_CQ1024_LBE_W -1 downto AXI_CQ1024_LBE_O;
    subtype AXI_CQ1024_SOP is natural range AXI_CQ1024_SOP_O + AXI_CQ1024_SOP_W -1 downto AXI_CQ1024_SOP_O;
    subtype AXI_CQ1024_SOP_PTR is natural range AXI_CQ1024_SOP_PTR_O + AXI_CQ1024_SOP_PTR_W -1 downto AXI_CQ1024_SOP_PTR_O;
    subtype AXI_CQ1024_EOP is natural range AXI_CQ1024_EOP_O + AXI_CQ1024_EOP_W -1 downto AXI_CQ1024_EOP_O;
    subtype AXI_CQ1024_EOP_PTR is natural range AXI_CQ1024_EOP_PTR_O + AXI_CQ1024_EOP_PTR_W -1 downto AXI_CQ1024_EOP_PTR_O;
    subtype AXI_CQ1024_DISCON is natural range AXI_CQ1024_DISCON_O + AXI_CQ1024_DISCON_W -1 downto AXI_CQ1024_DISCON_O;
    subtype AXI_CQ1024_RSV is natural range AXI_CQ1024_RSV_O + AXI_CQ1024_RSV_W -1 downto AXI_CQ1024_RSV_O;
    subtype AXI_CQ1024_PARITY is natural range AXI_CQ1024_PARITY_O + AXI_CQ1024_PARITY_W -1 downto AXI_CQ1024_PARITY_O;
    subtype AXI_CQ1024_PASID_VLD is natural range AXI_CQ1024_PASID_VLD_O + AXI_CQ1024_PASID_VLD_W -1 downto AXI_CQ1024_PASID_VLD_O;
    subtype AXI_CQ1024_PASID is natural range AXI_CQ1024_PASID_O + AXI_CQ1024_PASID_W -1 downto AXI_CQ1024_PASID_O;
    subtype AXI_CQ1024_PASID_EXE is natural range AXI_CQ1024_PASID_EXE_O + AXI_CQ1024_PASID_EXE_W -1 downto AXI_CQ1024_PASID_EXE_O;
    subtype AXI_CQ1024_PASID_PMODE is natural range AXI_CQ1024_PASID_PMODE_O + AXI_CQ1024_PASID_PMODE_W -1 downto AXI_CQ1024_PASID_PMODE_O;
    subtype AXI_CQ1024_POISONED is natural range AXI_CQ1024_POISONED_O + AXI_CQ1024_POISONED_W -1 downto AXI_CQ1024_POISONED_O;

    constant AXI_CQ1024_USER_W : natural := AXI_CQ1024_POISONED_O + AXI_CQ1024_POISONED_W;

    -- =============================================================================================
    -- 1024-bit AXI-Stream CC Meta fields
    -- =============================================================================================
    constant AXI_CC1024_SOP_W     : natural := AXI1024_TLPS;
    constant AXI_CC1024_SOP_PTR_W : natural := AXI1024_SOP_PTR_W*AXI1024_TLPS;
    constant AXI_CC1024_EOP_W     : natural := AXI1024_TLPS;
    constant AXI_CC1024_EOP_PTR_W : natural := AXI1024_EOP_PTR_W*AXI1024_TLPS;
    constant AXI_CC1024_DISCON_W  : natural := 1;
    constant AXI_CC1024_PARITY_W  : natural := 128;

    constant AXI_CC1024_SOP_O     : natural := 0;
    constant AXI_CC1024_SOP_PTR_O : natural := AXI_CC1024_SOP_O     + AXI_CC1024_SOP_W;
    constant AXI_CC1024_EOP_O     : natural := AXI_CC1024_SOP_PTR_O + AXI_CC1024_SOP_PTR_W;
    constant AXI_CC1024_EOP_PTR_O : natural := AXI_CC1024_EOP_O     + AXI_CC1024_EOP_W;
    constant AXI_CC1024_DISCON_O  : natural := AXI_CC1024_EOP_PTR_O + AXI_CC1024_EOP_PTR_W;
    constant AXI_CC1024_PARITY_O  : natural := AXI_CC1024_DISCON_O  + AXI_CC1024_DISCON_W;

    subtype AXI_CC1024_SOP is natural range AXI_CC1024_SOP_O + AXI_CC1024_SOP_W -1 downto AXI_CC1024_SOP_O;
    subtype AXI_CC1024_SOP_PTR is natural range AXI_CC1024_SOP_PTR_O + AXI_CC1024_SOP_PTR_W -1 downto AXI_CC1024_SOP_PTR_O;
    subtype AXI_CC1024_EOP is natural range AXI_CC1024_EOP_O + AXI_CC1024_EOP_W -1 downto AXI_CC1024_EOP_O;
    subtype AXI_CC1024_EOP_PTR is natural range AXI_CC1024_EOP_PTR_O + AXI_CC1024_EOP_PTR_W -1 downto AXI_CC1024_EOP_PTR_O;
    subtype AXI_CC1024_DISCON is natural range AXI_CC1024_DISCON_O + AXI_CC1024_DISCON_W -1 downto AXI_CC1024_DISCON_O;
    subtype AXI_CC1024_PARITY is natural range AXI_CC1024_PARITY_O + AXI_CC1024_PARITY_W -1 downto AXI_CC1024_PARITY_O;

    constant AXI_CC1024_USER_W : natural := AXI_CC1024_PARITY_O + AXI_CC1024_PARITY_W;

    -- =============================================================================================
    -- 1024-bit AXI-Stream RQ Meta fields
    -- =============================================================================================
    constant AXI_RQ1024_FBE_W         : natural := 4*AXI1024_TLPS;
    constant AXI_RQ1024_LBE_W         : natural := 4*AXI1024_TLPS;
    constant AXI_RQ1024_ADDR_OFFS_W   : natural := 4*AXI1024_TLPS;
    constant AXI_RQ1024_SOP_W         : natural := AXI1024_TLPS;
    constant AXI_RQ1024_SOP_PTR_W     : natural := AXI1024_SOP_PTR_W*AXI1024_TLPS;
    constant AXI_RQ1024_EOP_W         : natural := AXI1024_TLPS;
    constant AXI_RQ1024_EOP_PTR_W     : natural := AXI1024_EOP_PTR_W*AXI1024_TLPS;
    constant AXI_RQ1024_DISCON_W      : natural := 1;
    constant AXI_RQ1024_RSV_W         : natural := 44;
    constant AXI_RQ1024_PARITY_W      : natural := 128;
    constant AXI_RQ1024_PASID_VLD_W   : natural := AXI1024_TLPS;
    constant AXI_RQ1024_PASID_W       : natural := 20*AXI1024_TLPS;
    constant AXI_RQ1024_PASID_EXE_W   : natural := AXI1024_TLPS;
    constant AXI_RQ1024_PASID_PMODE_W : natural := AXI1024_TLPS;
    constant AXI_RQ1024_SEQ_NUM_W     : natural := 6*AXI1024_TLPS;

    constant AXI_RQ1024_FBE_O         : natural := 0;
    constant AXI_RQ1024_LBE_O         : natural := AXI_RQ1024_FBE_O         + AXI_RQ1024_FBE_W;
    constant AXI_RQ1024_ADDR_OFFS_O   : natural := AXI_RQ1024_LBE_O         + AXI_RQ1024_LBE_W;
    constant AXI_RQ1024_SOP_O         : natural := AXI_RQ1024_ADDR_OFFS_O   + AXI_RQ1024_ADDR_OFFS_W;
    constant AXI_RQ1024_SOP_PTR_O     : natural := AXI_RQ1024_SOP_O         + AXI_RQ1024_SOP_W;
    constant AXI_RQ1024_EOP_O         : natural := AXI_RQ1024_SOP_PTR_O     + AXI_RQ1024_SOP_PTR_W;
    constant AXI_RQ1024_EOP_PTR_O     : natural := AXI_RQ1024_EOP_O         + AXI_RQ1024_EOP_W;
    constant AXI_RQ1024_DISCON_O      : natural := AXI_RQ1024_EOP_PTR_O     + AXI_RQ1024_EOP_PTR_W;
    constant AXI_RQ1024_RSV_O         : natural := AXI_RQ1024_DISCON_O      + AXI_RQ1024_DISCON_W;
    constant AXI_RQ1024_PARITY_O      : natural := AXI_RQ1024_RSV_O         + AXI_RQ1024_RSV_W;
    constant AXI_RQ1024_PASID_VLD_O   : natural := AXI_RQ1024_PARITY_O      + AXI_RQ1024_PARITY_W;
    constant AXI_RQ1024_PASID_O       : natural := AXI_RQ1024_PASID_VLD_O   + AXI_RQ1024_PASID_VLD_W;
    constant AXI_RQ1024_PASID_EXE_O   : natural := AXI_RQ1024_PASID_O       + AXI_RQ1024_PASID_W;
    constant AXI_RQ1024_PASID_PMODE_O : natural := AXI_RQ1024_PASID_EXE_O   + AXI_RQ1024_PASID_EXE_W;
    constant AXI_RQ1024_SEQ_NUM_O     : natural := AXI_RQ1024_PASID_PMODE_O + AXI_RQ1024_PASID_PMODE_W;

    subtype AXI_RQ1024_FBE is natural range AXI_RQ1024_FBE_O + AXI_RQ1024_FBE_W -1 downto AXI_RQ1024_FBE_O;
    subtype AXI_RQ1024_LBE is natural range AXI_RQ1024_LBE_O + AXI_RQ1024_LBE_W -1 downto AXI_RQ1024_LBE_O;
    subtype AXI_RQ1024_ADDR_OFFS is natural range AXI_RQ1024_ADDR_OFFS_O + AXI_RQ1024_ADDR_OFFS_W -1 downto AXI_RQ1024_ADDR_OFFS_O;
    subtype AXI_RQ1024_SOP is natural range AXI_RQ1024_SOP_O + AXI_RQ1024_SOP_W -1 downto AXI_RQ1024_SOP_O;
    subtype AXI_RQ1024_SOP_PTR is natural range AXI_RQ1024_SOP_PTR_O + AXI_RQ1024_SOP_PTR_W -1 downto AXI_RQ1024_SOP_PTR_O;
    subtype AXI_RQ1024_EOP is natural range AXI_RQ1024_EOP_O + AXI_RQ1024_EOP_W -1 downto AXI_RQ1024_EOP_O;
    subtype AXI_RQ1024_EOP_PTR is natural range AXI_RQ1024_EOP_PTR_O + AXI_RQ1024_EOP_PTR_W -1 downto AXI_RQ1024_EOP_PTR_O;
    subtype AXI_RQ1024_DISCON is natural range AXI_RQ1024_DISCON_O + AXI_RQ1024_DISCON_W -1 downto AXI_RQ1024_DISCON_O;
    subtype AXI_RQ1024_RSV is natural range AXI_RQ1024_RSV_O + AXI_RQ1024_RSV_W -1 downto AXI_RQ1024_RSV_O;
    subtype AXI_RQ1024_PARITY is natural range AXI_RQ1024_PARITY_O + AXI_RQ1024_PARITY_W -1 downto AXI_RQ1024_PARITY_O;
    subtype AXI_RQ1024_PASID_VLD is natural range AXI_RQ1024_PASID_VLD_O + AXI_RQ1024_PASID_VLD_W -1 downto AXI_RQ1024_PASID_VLD_O;
    subtype AXI_RQ1024_PASID is natural range AXI_RQ1024_PASID_O + AXI_RQ1024_PASID_W -1 downto AXI_RQ1024_PASID_O;
    subtype AXI_RQ1024_PASID_EXE is natural range AXI_RQ1024_PASID_EXE_O + AXI_RQ1024_PASID_EXE_W -1 downto AXI_RQ1024_PASID_EXE_O;
    subtype AXI_RQ1024_PASID_PMODE is natural range AXI_RQ1024_PASID_PMODE_O + AXI_RQ1024_PASID_PMODE_W -1 downto AXI_RQ1024_PASID_PMODE_O;
    subtype AXI_RQ1024_SEQ_NUM is natural range AXI_RQ1024_SEQ_NUM_O + AXI_RQ1024_SEQ_NUM_W -1 downto AXI_RQ1024_SEQ_NUM_O;

    constant AXI_RQ1024_USER_W : natural := AXI_RQ1024_SEQ_NUM_O + AXI_RQ1024_SEQ_NUM_W;

    -- =============================================================================================
    -- 1024-bit AXI-Stream RC: 8 TLPs per beat, no MFB converter
    -- =============================================================================================
    constant AXI_RC1024_USER_W : natural := 337;

    -- =============================================================================================
    -- Straddle encoders (MFB to AXI), one TLP start per MFB region
    -- =============================================================================================
    function axi_straddle_sop_f (SOF : std_logic_vector) return std_logic_vector;
    function axi_straddle_eop_f (EOF : std_logic_vector; EOF_POS : std_logic_vector) return std_logic_vector;
end package;

package body pcie_axi_cpm5_pack is

    -- Returns is_sopN_ptr & is_sop: the n-th set bit of SOF becomes is_sop(n) with its region index in is_sopN_ptr.
    function axi_straddle_sop_f (SOF : std_logic_vector) return std_logic_vector is
        constant N     : natural := SOF'length;
        constant PTR_W : natural := log2(N);
        variable sof_v : std_logic_vector(N-1 downto 0);
        variable sop   : std_logic_vector(N-1 downto 0)       := (others => '0');
        variable ptr   : std_logic_vector(N*PTR_W-1 downto 0) := (others => '0');
        variable cnt   : natural range 0 to N                 := 0;
    begin
        sof_v := SOF;
        for r in 0 to N-1 loop
            if (sof_v(r) = '1') then
                sop(cnt)                                 := '1';
                ptr((cnt+1)*PTR_W-1 downto cnt*PTR_W)    := std_logic_vector(to_unsigned(r, PTR_W));
                cnt                                      := cnt + 1;
            end if;
        end loop;
        return ptr & sop;
    end function;

    -- Returns is_eopN_ptr & is_eop: the n-th set bit of EOF becomes is_eop(n), pointing at region & EOF_POS of that region.
    function axi_straddle_eop_f (EOF : std_logic_vector; EOF_POS : std_logic_vector) return std_logic_vector is
        constant N      : natural := EOF'length;
        constant POS_W  : natural := EOF_POS'length/N;
        constant PTR_W  : natural := log2(N) + POS_W;
        variable eof_v  : std_logic_vector(N-1 downto 0);
        variable pos_v  : std_logic_vector(N*POS_W-1 downto 0);
        variable eop    : std_logic_vector(N-1 downto 0)       := (others => '0');
        variable ptr    : std_logic_vector(N*PTR_W-1 downto 0) := (others => '0');
        variable cnt    : natural range 0 to N                 := 0;
    begin
        eof_v := EOF;
        pos_v := EOF_POS;
        for r in 0 to N-1 loop
            if (eof_v(r) = '1') then
                eop(cnt)                              := '1';
                ptr((cnt+1)*PTR_W-1 downto cnt*PTR_W) := std_logic_vector(to_unsigned(r, log2(N))) & pos_v((r+1)*POS_W-1 downto r*POS_W);
                cnt                                   := cnt + 1;
            end if;
        end loop;
        return ptr & eop;
    end function;

end package body;
