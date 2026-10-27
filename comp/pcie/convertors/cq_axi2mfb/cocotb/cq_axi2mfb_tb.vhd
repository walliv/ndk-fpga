-- cq_axi2mfb_tb.vhd: Cocotb top of PCIE_CQ_AXI2MFB with a clock for the testbench agents
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

use work.math_pack.all;
use work.pcie_axi_meta_pack.all;

-- The converter is combinational, the clock only paces the agents of the testbench.
entity CQ_AXI2MFB_TB is
    generic (
        MFB_REGIONS      : natural := 2;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        AXI_CQUSER_WIDTH : natural := AXI_CQ512_USER_W;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        STRADDLING       : boolean := true
    );
    port (
        CLK            : in  std_logic;

        CQ_AXI_DATA    : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CQ_AXI_USER    : in  std_logic_vector(AXI_CQUSER_WIDTH-1 downto 0);
        CQ_AXI_LAST    : in  std_logic;
        CQ_AXI_KEEP    : in  std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CQ_AXI_VALID   : in  std_logic;
        CQ_AXI_READY   : out std_logic;

        CQ_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CQ_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CQ_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CQ_MFB_SRC_RDY : out std_logic;
        CQ_MFB_DST_RDY : in  std_logic;

        CQ_TPH_PRESENT : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_TPH_TYPE    : out std_logic_vector(MFB_REGIONS*2-1 downto 0);
        CQ_TPH_ST_TAG  : out std_logic_vector(MFB_REGIONS*8-1 downto 0);
        CQ_FBE         : out std_logic_vector(MFB_REGIONS*4-1 downto 0);
        CQ_LBE         : out std_logic_vector(MFB_REGIONS*4-1 downto 0);
        CQ_BE          : out std_logic_vector(MFB_REGIONS*32-1 downto 0)
    );
end entity;

architecture FULL of CQ_AXI2MFB_TB is
begin

    -- The sizes of the TUSER and TDATA ports have to agree with the PG213 tables the package is built from
    assert (AXI_CQ256_USER_W = 88 and AXI_CC256_USER_W = 33 and AXI_RQ256_USER_W = 62 and AXI_RC256_USER_W = 75
            and AXI_CQ512_USER_W = 183 and AXI_CC512_USER_W = 81 and AXI_RQ512_USER_W = 137 and AXI_RC512_USER_W = 161)
        report "pcie_axi_meta_pack: a TUSER width differs from PG213"
        severity FAILURE;

    dut_i : entity work.PCIE_CQ_AXI2MFB
    generic map (
        MFB_REGIONS      => MFB_REGIONS,
        MFB_REGION_SIZE  => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE   => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH   => MFB_ITEM_WIDTH,
        AXI_CQUSER_WIDTH => AXI_CQUSER_WIDTH,
        AXI_DATA_WIDTH   => AXI_DATA_WIDTH,
        STRADDLING       => STRADDLING,
        DEVICE           => "ULTRASCALE"
    )
    port map (
        CQ_AXI_DATA    => CQ_AXI_DATA,
        CQ_AXI_USER    => CQ_AXI_USER,
        CQ_AXI_LAST    => CQ_AXI_LAST,
        CQ_AXI_KEEP    => CQ_AXI_KEEP,
        CQ_AXI_VALID   => CQ_AXI_VALID,
        CQ_AXI_READY   => CQ_AXI_READY,

        CQ_MFB_DATA    => CQ_MFB_DATA,
        CQ_MFB_SOF     => CQ_MFB_SOF,
        CQ_MFB_EOF     => CQ_MFB_EOF,
        CQ_MFB_SOF_POS => CQ_MFB_SOF_POS,
        CQ_MFB_EOF_POS => CQ_MFB_EOF_POS,
        CQ_MFB_SRC_RDY => CQ_MFB_SRC_RDY,
        CQ_MFB_DST_RDY => CQ_MFB_DST_RDY,

        CQ_TPH_PRESENT => CQ_TPH_PRESENT,
        CQ_TPH_TYPE    => CQ_TPH_TYPE,
        CQ_TPH_ST_TAG  => CQ_TPH_ST_TAG,
        CQ_FBE         => CQ_FBE,
        CQ_LBE         => CQ_LBE,
        CQ_BE          => CQ_BE
    );

end architecture;
