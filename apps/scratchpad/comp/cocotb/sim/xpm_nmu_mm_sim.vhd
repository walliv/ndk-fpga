-- xpm_nmu_mm_sim.vhd: simulation stand-in for the xpm_nmu_mm NoC master unit
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

-- Exposes the AXI4 slave port as AXI_* signals, where the bench's AXI memory model (the NoC and HBM) attaches.
entity XPM_NMU_MM is
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
end entity;

architecture SIM of XPM_NMU_MM is

    signal axi_awid    : std_logic_vector(ID_WIDTH-1 downto 0);
    signal axi_awaddr  : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal axi_awlen   : std_logic_vector(7 downto 0);
    signal axi_awsize  : std_logic_vector(2 downto 0);
    signal axi_awburst : std_logic_vector(1 downto 0);
    signal axi_awlock  : std_logic_vector(0 downto 0);
    signal axi_awcache : std_logic_vector(3 downto 0);
    signal axi_awprot  : std_logic_vector(2 downto 0);
    signal axi_awqos   : std_logic_vector(3 downto 0);
    signal axi_awvalid : std_logic;
    signal axi_awready : std_logic := '0';
    signal axi_wdata   : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal axi_wstrb   : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal axi_wlast   : std_logic;
    signal axi_wvalid  : std_logic;
    signal axi_wready  : std_logic := '0';
    signal axi_bid     : std_logic_vector(ID_WIDTH-1 downto 0) := (others => '0');
    signal axi_bresp   : std_logic_vector(1 downto 0) := (others => '0');
    signal axi_bvalid  : std_logic := '0';
    signal axi_bready  : std_logic;
    signal axi_arid    : std_logic_vector(ID_WIDTH-1 downto 0);
    signal axi_araddr  : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal axi_arlen   : std_logic_vector(7 downto 0);
    signal axi_arsize  : std_logic_vector(2 downto 0);
    signal axi_arburst : std_logic_vector(1 downto 0);
    signal axi_arlock  : std_logic_vector(0 downto 0);
    signal axi_arcache : std_logic_vector(3 downto 0);
    signal axi_arprot  : std_logic_vector(2 downto 0);
    signal axi_arqos   : std_logic_vector(3 downto 0);
    signal axi_arvalid : std_logic;
    signal axi_arready : std_logic := '0';
    signal axi_rid     : std_logic_vector(ID_WIDTH-1 downto 0) := (others => '0');
    signal axi_rdata   : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal axi_rresp   : std_logic_vector(1 downto 0) := (others => '0');
    signal axi_rlast   : std_logic := '0';
    signal axi_rvalid  : std_logic := '0';
    signal axi_rready  : std_logic;

begin

    axi_awid      <= S_AXI_AWID;
    axi_awaddr    <= S_AXI_AWADDR;
    axi_awlen     <= S_AXI_AWLEN;
    axi_awsize    <= S_AXI_AWSIZE;
    axi_awburst   <= S_AXI_AWBURST;
    axi_awlock    <= S_AXI_AWLOCK;
    axi_awcache   <= S_AXI_AWCACHE;
    axi_awprot    <= S_AXI_AWPROT;
    axi_awqos     <= S_AXI_AWQOS;
    axi_awvalid   <= S_AXI_AWVALID;
    S_AXI_AWREADY <= axi_awready;
    axi_wdata     <= S_AXI_WDATA;
    axi_wstrb     <= S_AXI_WSTRB;
    axi_wlast     <= S_AXI_WLAST;
    axi_wvalid    <= S_AXI_WVALID;
    S_AXI_WREADY  <= axi_wready;
    S_AXI_BID     <= axi_bid;
    S_AXI_BRESP   <= axi_bresp;
    S_AXI_BUSER   <= (others => '0');
    S_AXI_BVALID  <= axi_bvalid;
    axi_bready    <= S_AXI_BREADY;
    axi_arid      <= S_AXI_ARID;
    axi_araddr    <= S_AXI_ARADDR;
    axi_arlen     <= S_AXI_ARLEN;
    axi_arsize    <= S_AXI_ARSIZE;
    axi_arburst   <= S_AXI_ARBURST;
    axi_arlock    <= S_AXI_ARLOCK;
    axi_arcache   <= S_AXI_ARCACHE;
    axi_arprot    <= S_AXI_ARPROT;
    axi_arqos     <= S_AXI_ARQOS;
    axi_arvalid   <= S_AXI_ARVALID;
    S_AXI_ARREADY <= axi_arready;
    S_AXI_RID     <= axi_rid;
    S_AXI_RDATA   <= axi_rdata;
    S_AXI_RRESP   <= axi_rresp;
    S_AXI_RLAST   <= axi_rlast;
    S_AXI_RUSER   <= (others => '0');
    S_AXI_RVALID  <= axi_rvalid;
    axi_rready    <= S_AXI_RREADY;

    NMU_FIREWALL_RD_ERR <= '0';
    NMU_FIREWALL_WR_ERR <= '0';

end architecture;
