-- cc_mfb2axi_tb.vhd: Cocotb top of PCIE_CC_MFB2AXI with a clock for the testbench agents
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

use work.math_pack.all;
use work.pcie_axi_meta_pack.all;

-- The converter is combinational, the clock only paces the agents of the testbench.
entity CC_MFB2AXI_TB is
    generic (
        MFB_REGIONS      : natural := 2;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        AXI_CCUSER_WIDTH : natural := AXI_CC512_USER_W;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        STRADDLING       : boolean := true
    );
    port (
        CLK            : in  std_logic;

        CC_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CC_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_EOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CC_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CC_MFB_SRC_RDY : in  std_logic;
        CC_MFB_DST_RDY : out std_logic;

        CC_AXI_DATA    : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CC_AXI_USER    : out std_logic_vector(AXI_CCUSER_WIDTH-1 downto 0);
        CC_AXI_LAST    : out std_logic;
        CC_AXI_KEEP    : out std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CC_AXI_VALID   : out std_logic;
        CC_AXI_READY   : in  std_logic
    );
end entity;

architecture FULL of CC_MFB2AXI_TB is
begin

    dut_i : entity work.PCIE_CC_MFB2AXI
    generic map (
        MFB_REGIONS      => MFB_REGIONS,
        MFB_REGION_SIZE  => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE   => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH   => MFB_ITEM_WIDTH,
        AXI_CCUSER_WIDTH => AXI_CCUSER_WIDTH,
        AXI_DATA_WIDTH   => AXI_DATA_WIDTH,
        STRADDLING       => STRADDLING
    )
    port map (
        CC_MFB_DATA    => CC_MFB_DATA,
        CC_MFB_SOF     => CC_MFB_SOF,
        CC_MFB_EOF     => CC_MFB_EOF,
        CC_MFB_SOF_POS => CC_MFB_SOF_POS,
        CC_MFB_EOF_POS => CC_MFB_EOF_POS,
        CC_MFB_SRC_RDY => CC_MFB_SRC_RDY,
        CC_MFB_DST_RDY => CC_MFB_DST_RDY,

        CC_AXI_DATA    => CC_AXI_DATA,
        CC_AXI_USER    => CC_AXI_USER,
        CC_AXI_LAST    => CC_AXI_LAST,
        CC_AXI_KEEP    => CC_AXI_KEEP,
        CC_AXI_VALID   => CC_AXI_VALID,
        CC_AXI_READY   => CC_AXI_READY
    );

end architecture;
