-- user_core_ent.vhd: Entity declaration of the user core to ensure consistent port names
-- Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.combo_user_const.all;

entity USER_CORE is
    generic (
        -- MI parameters: width of data signals
        MI_DATA_WIDTH : integer := 32;
        -- MI parameters: width of address signal
        MI_ADDR_WIDTH : integer := 32;

        HBM_PORTS       : natural := 32;
        HBM_DATA_WIDTH  : natural := 256;
        HBM_ADDR_WIDTH  : natural := 34;
        HBM_BURST_WIDTH : natural := 2;
        HBM_ID_WIDTH    : natural := 6;
        HBM_LEN_WIDTH   : natural := 4;
        HBM_SIZE_WIDTH  : natural := 3;
        HBM_RESP_WIDTH  : natural := 2;

        FPGA_ID_WIDTH : integer := 16;
        DEVICE        : string  := "ULTRASCALE"
    );
    port (
        -- Custom user clock and reset
        USR_CLK : in std_logic;
        -- Driven from a clock tree and deasserted when the PLL in the MMCM locks
        USR_RST : in std_logic;

        -- =========================================================================================
        -- Memory Interface (MI) bus
        -- =========================================================================================
        MI_CLK : in std_logic;
        -- Driven from a clock tree and deasserted when the PLL in the MMCM locks
        MI_RST : in std_logic;

        -- data from master to slave (write data)
        MI_DWR  : in  std_logic_vector(MI_DATA_WIDTH-1 downto 0);
        -- slave address
        MI_ADDR : in  std_logic_vector(MI_ADDR_WIDTH-1 downto 0);
        -- byte enable for write data
        MI_BE   : in  std_logic_vector((MI_DATA_WIDTH/8)-1 downto 0);
        -- read request
        MI_RD   : in  std_logic;
        -- write request
        MI_WR   : in  std_logic;
        -- ready of slave module
        MI_ARDY : out std_logic;
        -- data from slave to master (read data)
        MI_DRD  : out std_logic_vector(MI_DATA_WIDTH-1 downto 0);
        -- valid of MI_DRD data signal
        MI_DRDY : out std_logic;

        -- =========================================================================================
        -- HBM ports (each driven by its corresponding HBM_AXI_CLK(x))
        -- =========================================================================================
        -- for customization, HBM clock and reset can be driven from user core from USR_CLK or from
        -- a custom clock domain. Be sure that some clock is always connected to HBM_AXI_CLK port
        HBM_AXI_CLK     : out std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_RESET_N : out std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_INIT_DONE   : in std_logic;

        HBM_AXI_AWID    : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_AWADDR  : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_ADDR_WIDTH-1 downto 0);
        HBM_AXI_AWLEN   : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_LEN_WIDTH-1 downto 0);
        HBM_AXI_AWSIZE  : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_SIZE_WIDTH-1 downto 0);
        HBM_AXI_AWBURST : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_BURST_WIDTH-1 downto 0);
        HBM_AXI_AWVALID : out std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_AWREADY : in  std_logic_vector(HBM_PORTS-1 downto 0);

        HBM_AXI_WDATA        : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_DATA_WIDTH-1 downto 0);
        HBM_AXI_WSTRB        : out slv_array_t(HBM_PORTS-1 downto 0)((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_WDATA_PARITY : out slv_array_t(HBM_PORTS-1 downto 0)((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_WLAST        : out std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_WVALID       : out std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_WREADY       : in  std_logic_vector(HBM_PORTS-1 downto 0);

        HBM_AXI_BID    : in  slv_array_t(HBM_PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_BRESP  : in  slv_array_t(HBM_PORTS-1 downto 0)(HBM_RESP_WIDTH-1 downto 0);
        HBM_AXI_BVALID : in  std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_BREADY : out std_logic_vector(HBM_PORTS-1 downto 0);

        HBM_AXI_ARID    : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_ARADDR  : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_ADDR_WIDTH-1 downto 0);
        HBM_AXI_ARLEN   : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_LEN_WIDTH-1 downto 0);
        HBM_AXI_ARSIZE  : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_SIZE_WIDTH-1 downto 0);
        HBM_AXI_ARBURST : out slv_array_t(HBM_PORTS-1 downto 0)(HBM_BURST_WIDTH-1 downto 0);
        HBM_AXI_ARVALID : out std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_ARREADY : in  std_logic_vector(HBM_PORTS-1 downto 0);

        HBM_AXI_RID          : in  slv_array_t(HBM_PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_RDATA        : in  slv_array_t(HBM_PORTS-1 downto 0)(HBM_DATA_WIDTH-1 downto 0);
        HBM_AXI_RDATA_PARITY : in  slv_array_t(HBM_PORTS-1 downto 0)((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_RRESP        : in  slv_array_t(HBM_PORTS-1 downto 0)(HBM_RESP_WIDTH-1 downto 0);
        HBM_AXI_RLAST        : in  std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_RVALID       : in  std_logic_vector(HBM_PORTS-1 downto 0);
        HBM_AXI_RREADY       : out std_logic_vector(HBM_PORTS-1 downto 0);

        -- =========================================================================================
        -- Status signals
        -- =========================================================================================
        -- driven by MI_CLK
        FPGA_ID     : in std_logic_vector(FPGA_ID_WIDTH -1 downto 0);
        -- driven by MI_CLK
        FPGA_ID_VLD : in std_logic
    );
end entity;
