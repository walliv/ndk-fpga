-- scratchpad_nmu.vhd: AXI4 slave port of one PL NoC master unit (xpm_nmu_mm on the VNoC)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- The NoC connections of xpm_nmu_i are made by a synthesis_pre XDC (noc_hbm.xdc), which names this instance; the AXI address is the NoC system address.
entity SCRATCHPAD_NMU is
    generic (
        DATA_WIDTH : natural := 256;
        ADDR_WIDTH : natural := 64;
        ID_WIDTH   : natural := 4
    );
    port (
        CLK           : in  std_logic;

        S_AXI_AWID    : in  std_logic_vector(ID_WIDTH-1 downto 0);
        S_AXI_AWADDR  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        S_AXI_AWLEN   : in  std_logic_vector(8-1 downto 0);
        S_AXI_AWSIZE  : in  std_logic_vector(3-1 downto 0);
        S_AXI_AWBURST : in  std_logic_vector(2-1 downto 0);
        S_AXI_AWLOCK  : in  std_logic;
        S_AXI_AWCACHE : in  std_logic_vector(4-1 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(3-1 downto 0);
        S_AXI_AWQOS   : in  std_logic_vector(4-1 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;

        S_AXI_WDATA   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        S_AXI_WLAST   : in  std_logic;
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;

        S_AXI_BID     : out std_logic_vector(ID_WIDTH-1 downto 0);
        S_AXI_BRESP   : out std_logic_vector(2-1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;

        S_AXI_ARID    : in  std_logic_vector(ID_WIDTH-1 downto 0);
        S_AXI_ARADDR  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        S_AXI_ARLEN   : in  std_logic_vector(8-1 downto 0);
        S_AXI_ARSIZE  : in  std_logic_vector(3-1 downto 0);
        S_AXI_ARBURST : in  std_logic_vector(2-1 downto 0);
        S_AXI_ARLOCK  : in  std_logic;
        S_AXI_ARCACHE : in  std_logic_vector(4-1 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(3-1 downto 0);
        S_AXI_ARQOS   : in  std_logic_vector(4-1 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;

        S_AXI_RID     : out std_logic_vector(ID_WIDTH-1 downto 0);
        S_AXI_RDATA   : out std_logic_vector(DATA_WIDTH-1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(2-1 downto 0);
        S_AXI_RLAST   : out std_logic;
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic
    );
end entity;

architecture FULL of SCRATCHPAD_NMU is

    constant AUSER_WIDTH : natural := 16;

    -- Declared locally with the SystemVerilog port widths: the xpm VCOMP declaration makes WUSER/RUSER null ranges for DUSER_WIDTH 0 while the module keeps them 1 bit wide.
    component xpm_nmu_mm is
        generic (
            NOC_FABRIC           : string  := "VNOC";
            DATA_WIDTH           : integer := 512;
            ADDR_WIDTH           : integer := 64;
            ID_WIDTH             : integer := 16;
            AUSER_WIDTH          : integer := 16;
            DUSER_WIDTH          : integer := 0;
            ENABLE_FIREWALL      : string  := "false";
            ENABLE_USR_INTERRUPT : string  := "false";
            SIDEBAND_PINS        : string  := "false"
        );
        port (
            S_AXI_ACLK           : in  std_logic;
            S_AXI_AWID           : in  std_logic_vector(ID_WIDTH-1 downto 0);
            S_AXI_AWADDR         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            S_AXI_AWLEN          : in  std_logic_vector(7 downto 0);
            S_AXI_AWSIZE         : in  std_logic_vector(2 downto 0);
            S_AXI_AWBURST        : in  std_logic_vector(1 downto 0);
            S_AXI_AWLOCK         : in  std_logic_vector(0 downto 0);
            S_AXI_AWCACHE        : in  std_logic_vector(3 downto 0);
            S_AXI_AWPROT         : in  std_logic_vector(2 downto 0);
            S_AXI_AWREGION       : in  std_logic_vector(3 downto 0);
            S_AXI_AWQOS          : in  std_logic_vector(3 downto 0);
            S_AXI_AWUSER         : in  std_logic_vector(AUSER_WIDTH-1 downto 0);
            S_AXI_AWVALID        : in  std_logic;
            S_AXI_AWREADY        : out std_logic;
            S_AXI_WID            : in  std_logic_vector(ID_WIDTH-1 downto 0);
            S_AXI_WDATA          : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            S_AXI_WSTRB          : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
            S_AXI_WLAST          : in  std_logic;
            S_AXI_WUSER          : in  std_logic_vector(0 downto 0);
            S_AXI_WVALID         : in  std_logic;
            S_AXI_WREADY         : out std_logic;
            S_AXI_BID            : out std_logic_vector(ID_WIDTH-1 downto 0);
            S_AXI_BRESP          : out std_logic_vector(1 downto 0);
            S_AXI_BUSER          : out std_logic_vector(15 downto 0);
            S_AXI_BVALID         : out std_logic;
            S_AXI_BREADY         : in  std_logic;
            S_AXI_ARID           : in  std_logic_vector(ID_WIDTH-1 downto 0);
            S_AXI_ARADDR         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            S_AXI_ARLEN          : in  std_logic_vector(7 downto 0);
            S_AXI_ARSIZE         : in  std_logic_vector(2 downto 0);
            S_AXI_ARBURST        : in  std_logic_vector(1 downto 0);
            S_AXI_ARLOCK         : in  std_logic_vector(0 downto 0);
            S_AXI_ARCACHE        : in  std_logic_vector(3 downto 0);
            S_AXI_ARPROT         : in  std_logic_vector(2 downto 0);
            S_AXI_ARREGION       : in  std_logic_vector(3 downto 0);
            S_AXI_ARQOS          : in  std_logic_vector(3 downto 0);
            S_AXI_ARUSER         : in  std_logic_vector(AUSER_WIDTH-1 downto 0);
            S_AXI_ARVALID        : in  std_logic;
            S_AXI_ARREADY        : out std_logic;
            S_AXI_RID            : out std_logic_vector(ID_WIDTH-1 downto 0);
            S_AXI_RDATA          : out std_logic_vector(DATA_WIDTH-1 downto 0);
            S_AXI_RRESP          : out std_logic_vector(1 downto 0);
            S_AXI_RLAST          : out std_logic;
            S_AXI_RUSER          : out std_logic_vector(0 downto 0);
            S_AXI_RVALID         : out std_logic;
            S_AXI_RREADY         : in  std_logic;
            NMU_FIREWALL_RD_ERR  : out std_logic;
            NMU_FIREWALL_WR_ERR  : out std_logic;
            NMU_USR_INTERRUPT_IN : in  std_logic_vector(3 downto 0)
        );
    end component;

begin

    xpm_nmu_i : component xpm_nmu_mm
    generic map (
        NOC_FABRIC           => "VNOC",
        DATA_WIDTH           => DATA_WIDTH,
        ADDR_WIDTH           => ADDR_WIDTH,
        ID_WIDTH             => ID_WIDTH,
        AUSER_WIDTH          => AUSER_WIDTH,
        DUSER_WIDTH          => 0,
        ENABLE_FIREWALL      => "false",
        ENABLE_USR_INTERRUPT => "false",
        SIDEBAND_PINS        => "false"
    )
    port map (
        s_axi_aclk           => CLK,
        s_axi_awid           => S_AXI_AWID,
        s_axi_awaddr         => S_AXI_AWADDR,
        s_axi_awlen          => S_AXI_AWLEN,
        s_axi_awsize         => S_AXI_AWSIZE,
        s_axi_awburst        => S_AXI_AWBURST,
        s_axi_awlock(0)      => S_AXI_AWLOCK,
        s_axi_awcache        => S_AXI_AWCACHE,
        s_axi_awprot         => S_AXI_AWPROT,
        s_axi_awregion       => (others => '0'),
        s_axi_awqos          => S_AXI_AWQOS,
        s_axi_awuser         => (others => '0'),
        s_axi_awvalid        => S_AXI_AWVALID,
        s_axi_awready        => S_AXI_AWREADY,
        s_axi_wid            => (others => '0'),
        s_axi_wdata          => S_AXI_WDATA,
        s_axi_wstrb          => S_AXI_WSTRB,
        s_axi_wlast          => S_AXI_WLAST,
        s_axi_wuser          => (others => '0'),
        s_axi_wvalid         => S_AXI_WVALID,
        s_axi_wready         => S_AXI_WREADY,
        s_axi_bid            => S_AXI_BID,
        s_axi_bresp          => S_AXI_BRESP,
        s_axi_buser          => open,
        s_axi_bvalid         => S_AXI_BVALID,
        s_axi_bready         => S_AXI_BREADY,
        s_axi_arid           => S_AXI_ARID,
        s_axi_araddr         => S_AXI_ARADDR,
        s_axi_arlen          => S_AXI_ARLEN,
        s_axi_arsize         => S_AXI_ARSIZE,
        s_axi_arburst        => S_AXI_ARBURST,
        s_axi_arlock(0)      => S_AXI_ARLOCK,
        s_axi_arcache        => S_AXI_ARCACHE,
        s_axi_arprot         => S_AXI_ARPROT,
        s_axi_arregion       => (others => '0'),
        s_axi_arqos          => S_AXI_ARQOS,
        s_axi_aruser         => (others => '0'),
        s_axi_arvalid        => S_AXI_ARVALID,
        s_axi_arready        => S_AXI_ARREADY,
        s_axi_rid            => S_AXI_RID,
        s_axi_rdata          => S_AXI_RDATA,
        s_axi_rresp          => S_AXI_RRESP,
        s_axi_rlast          => S_AXI_RLAST,
        s_axi_ruser          => open,
        s_axi_rvalid         => S_AXI_RVALID,
        s_axi_rready         => S_AXI_RREADY,
        nmu_firewall_rd_err  => open,
        nmu_firewall_wr_err  => open,
        nmu_usr_interrupt_in => (others => '0')
    );

end architecture;
