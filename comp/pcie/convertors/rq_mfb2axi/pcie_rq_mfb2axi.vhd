-- pcie_rq_mfb2axi.vhd: Convertor from PCIe RQ MFB to the straddled 1024-bit CPM5 AXI4-Stream RQ interface
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.pcie_axi_cpm5_pack.all;

-- Converts RQ MFB words (descriptor in-band) to the straddled Versal CPM5 1024-bit RQ interface. Per
-- PG346 the input must not pause inside a TLP, and a word not continuing a TLP starts its first in region 0.
entity PCIE_RQ_MFB2AXI is
    generic (
        -- =======================================================================
        -- MFB BUS CONFIGURATION:
        --
        -- Supported configuration is: (4,1,8,32)
        -- =======================================================================
        MFB_REGIONS      : natural := 4;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        -- MFB bus: width of single data region in bits, auxiliary parameter, do not change value!
        MFB_REGION_WIDTH : natural := MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        -- =======================================================================
        -- AXI BUS CONFIGURATION:
        --
        -- RQ_USER_WIDTH = 373 for 1024b Versal CPM5 PCIe - with straddling only
        -- =======================================================================
        AXI_RQUSER_WIDTH : natural := AXI_RQ1024_USER_W;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_WIDTH;
        -- Must be enabled, also in the RQ/RC straddle option of the core
        STRADDLING       : boolean := true
    );
    port (
        -- =====================================================================
        -- MFB Requester Request Interface (RQ)
        -- =====================================================================
        -- RQ_MFB: data word with frames (packets)
        RQ_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_WIDTH-1 downto 0);
        -- RQ_MFB: PCIe RQ meta of each region (pcie_meta_pack), valid with SOF; only FBE and LBE are used
        RQ_MFB_META    : in  std_logic_vector(MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
        -- RQ_MFB: Start Of Frame (SOF) flag for each MFB region
        RQ_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        -- RQ_MFB: End Of Frame (EOF) flag for each MFB region
        RQ_MFB_EOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        -- RQ_MFB: SOF position for each MFB region in MFB blocks
        RQ_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        -- RQ_MFB: EOF position for each MFB region in MFB items
        RQ_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        -- RQ_MFB: source ready of each MFB bus
        RQ_MFB_SRC_RDY : in  std_logic;
        -- RQ_MFB: destination ready of each MFB bus
        RQ_MFB_DST_RDY : out std_logic;

        -- =====================================================================
        -- AXI Requester Request Interface (RQ)
        --
        -- See Xilinx PG346 (Versal CPM Mode for PCI Express).
        -- =====================================================================
        -- RQ_AXI: Data word
        RQ_AXI_DATA    : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        -- RQ_AXI: Sideband information of the TLPs in this word
        RQ_AXI_USER    : out std_logic_vector(AXI_RQUSER_WIDTH-1 downto 0);
        -- RQ_AXI: Ignored by the core when straddling is on
        RQ_AXI_LAST    : out std_logic;
        -- RQ_AXI: Ignored by the core when straddling is on, kept all ones
        RQ_AXI_KEEP    : out std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        -- RQ_AXI: Valid word
        RQ_AXI_VALID   : out std_logic;
        -- RQ_AXI: The core accepts the word
        RQ_AXI_READY   : in  std_logic
    );
end entity;

architecture FULL of PCIE_RQ_MFB2AXI is

    constant EOF_POS_WIDTH : natural := max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE));

    signal rq_mfb_meta_arr : slv_array_t(MFB_REGIONS-1 downto 0)(PCIE_RQ_META_WIDTH-1 downto 0);
    signal rq_mfb_fbe_arr  : slv_array_t(MFB_REGIONS-1 downto 0)(PCIE_META_FBE_W-1 downto 0);
    signal rq_mfb_lbe_arr  : slv_array_t(MFB_REGIONS-1 downto 0)(PCIE_META_LBE_W-1 downto 0);

    signal rq_user         : std_logic_vector(AXI_RQUSER_WIDTH-1 downto 0);

begin

    assert (MFB_REGIONS = AXI1024_TLPS and MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 8 and MFB_ITEM_WIDTH = 32
            and AXI_RQUSER_WIDTH = AXI_RQ1024_USER_W and AXI_DATA_WIDTH = 1024 and STRADDLING
            and log2(MFB_REGIONS) + EOF_POS_WIDTH = AXI1024_EOP_PTR_W)
        report "PCIE_RQ_MFB2AXI: Unsupported configuration, the supported is MFB (4,1,8,32) to the 1024b CPM5 RQ interface (AXI_RQUSER_WIDTH = 373) with straddling"
        severity FAILURE;

    rq_mfb_meta_arr <= slv_array_deser(RQ_MFB_META, MFB_REGIONS);

    rq_mfb_be_g : for r in 0 to MFB_REGIONS-1 generate
        rq_mfb_fbe_arr(r) <= rq_mfb_meta_arr(r)(PCIE_RQ_META_FBE);
        rq_mfb_lbe_arr(r) <= rq_mfb_meta_arr(r)(PCIE_RQ_META_LBE);
    end generate;

    -- The n-th TLP of a word takes first_be/last_be n from the region holding the n-th SOF
    rq_user_p : process (all)
        variable tlp : natural range 0 to MFB_REGIONS;
    begin
        rq_user <= (others => '0');
        tlp     := 0;

        for r in 0 to MFB_REGIONS-1 loop
            if (RQ_MFB_SOF(r) = '1') then
                rq_user(AXI_RQ1024_FBE_O + (tlp+1)*PCIE_META_FBE_W-1 downto AXI_RQ1024_FBE_O + tlp*PCIE_META_FBE_W) <= rq_mfb_fbe_arr(r);
                rq_user(AXI_RQ1024_LBE_O + (tlp+1)*PCIE_META_LBE_W-1 downto AXI_RQ1024_LBE_O + tlp*PCIE_META_LBE_W) <= rq_mfb_lbe_arr(r);
                tlp                                                                                                 := tlp + 1;
            end if;
        end loop;

        rq_user(AXI_RQ1024_SOP_PTR_O + AXI_RQ1024_SOP_PTR_W-1 downto AXI_RQ1024_SOP_O) <= axi_straddle_sop_f(RQ_MFB_SOF);
        rq_user(AXI_RQ1024_EOP_PTR_O + AXI_RQ1024_EOP_PTR_W-1 downto AXI_RQ1024_EOP_O) <= axi_straddle_eop_f(RQ_MFB_EOF, RQ_MFB_EOF_POS);
    end process;

    RQ_AXI_DATA    <= RQ_MFB_DATA;
    RQ_AXI_USER    <= rq_user;
    RQ_AXI_LAST    <= or RQ_MFB_EOF;
    RQ_AXI_KEEP    <= (others => '1');
    RQ_AXI_VALID   <= RQ_MFB_SRC_RDY;
    RQ_MFB_DST_RDY <= RQ_AXI_READY;

end architecture;
