-- user_core_test_arch.vhd: Testing architecture of the user core
-- Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

library unisim;
use unisim.vcomponents.BUFG;

architecture TEST of USER_CORE is
    signal hbm_rst_n_bufg : std_logic;
begin
    -- =============================================================================================
    -- HBM memory tester
    -- =============================================================================================
    HBM_AXI_CLK   <= (others => USR_CLK);

    sysclk_bufg_i : component BUFG
    port map (
        I => not USR_RST,
        O => hbm_rst_n_bufg
    );
    HBM_AXI_RESET_N <= (others => hbm_rst_n_bufg);

    hbm_tester_i : entity work.HBM_TESTER
    generic map (
        DEBUG           => True,

        PORTS           => HBM_PORTS,
        CNT_WIDTH       => 24,

        AXI_ADDR_WIDTH  => HBM_ADDR_WIDTH,
        AXI_DATA_WIDTH  => HBM_DATA_WIDTH,
        AXI_BURST_WIDTH => HBM_BURST_WIDTH,
        AXI_ID_WIDTH    => HBM_ID_WIDTH,
        AXI_LEN_WIDTH   => HBM_LEN_WIDTH,
        AXI_SIZE_WIDTH  => HBM_SIZE_WIDTH,
        AXI_RESP_WIDTH  => HBM_RESP_WIDTH,
        USR_DATA_WIDTH  => HBM_DATA_WIDTH,
        -- HBM address bits:
        --     - Stack Select:            33
        --     - Destination AXI Port: 32:29
        --     - HBM Address Bits      28:5
        --     - Unused Address Bits    4:0
        PORT_ADDR_HBIT  => 28,
        DEVICE          => DEVICE
    )
    port map (
        HBM_CLK             => USR_CLK,
        HBM_RESET           => not hbm_rst_n_bufg,

        MI_CLK              => MI_CLK,
        MI_RESET            => MI_RST,
        MI_DWR              => MI_DWR,
        MI_ADDR             => MI_ADDR,
        MI_BE               => MI_BE,
        MI_RD               => MI_RD,
        MI_WR               => MI_WR,
        MI_ARDY             => MI_ARDY,
        MI_DRD              => MI_DRD,
        MI_DRDY             => MI_DRDY,

        WR_ADDR             => (others => (others => '0')),
        WR_DATA             => (others => (others => '0')),
        WR_DATA_LAST        => (others => '0'),
        WR_VALID            => (others => '0'),
        WR_READY            => open,
        WR_RSP_ACK          => open,
        WR_RSP_VALID        => open,
        WR_RSP_READY        => (others => '1'),
        RD_ADDR             => (others => (others => '0')),
        RD_ADDR_VALID       => (others => '0'),
        RD_ADDR_READY       => open,
        RD_DATA             => open,
        RD_DATA_LAST        => open,
        RD_DATA_VALID       => open,
        RD_DATA_READY       => (others => '1'),

        AXI_AWID            => HBM_AXI_AWID,
        AXI_AWADDR          => HBM_AXI_AWADDR,
        AXI_AWLEN           => HBM_AXI_AWLEN,
        AXI_AWSIZE          => HBM_AXI_AWSIZE,
        AXI_AWBURST         => HBM_AXI_AWBURST,
        AXI_AWPROT          => open,
        AXI_AWQOS           => open,
        AXI_AWUSER          => open,
        AXI_AWVALID         => HBM_AXI_AWVALID,
        AXI_AWREADY         => HBM_AXI_AWREADY,
        AXI_WDATA           => HBM_AXI_WDATA,
        AXI_WSTRB           => HBM_AXI_WSTRB,
        AXI_WUSER_DATA      => HBM_AXI_WDATA_PARITY,
        AXI_WUSER_STRB      => open,
        AXI_WLAST           => HBM_AXI_WLAST,
        AXI_WVALID          => HBM_AXI_WVALID,
        AXI_WREADY          => HBM_AXI_WREADY,
        AXI_BID             => HBM_AXI_BID,
        AXI_BRESP           => HBM_AXI_BRESP,
        AXI_BVALID          => HBM_AXI_BVALID,
        AXI_BREADY          => HBM_AXI_BREADY,
        AXI_ARID            => HBM_AXI_ARID,
        AXI_ARADDR          => HBM_AXI_ARADDR,
        AXI_ARLEN           => HBM_AXI_ARLEN,
        AXI_ARSIZE          => HBM_AXI_ARSIZE,
        AXI_ARBURST         => HBM_AXI_ARBURST,
        AXI_ARPROT          => open,
        AXI_ARQOS           => open,
        AXI_ARUSER          => open,
        AXI_ARVALID         => HBM_AXI_ARVALID,
        AXI_ARREADY         => HBM_AXI_ARREADY,
        AXI_RID             => HBM_AXI_RID,
        AXI_RDATA           => HBM_AXI_RDATA,
        AXI_RUSER_DATA      => HBM_AXI_RDATA_PARITY,
        AXI_RUSER_ERR_DBE   => (others => '0'),
        AXI_RRESP           => HBM_AXI_RRESP,
        AXI_RLAST           => HBM_AXI_RLAST,
        AXI_RVALID          => HBM_AXI_RVALID,
        AXI_RREADY          => HBM_AXI_RREADY
    );
end architecture;
