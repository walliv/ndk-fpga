-- h2c_hyperion_axi_adapter.vhd: adapter from MFB to AXI3 interface of the HBM
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;

entity H2C_HYPERION_AXI_ADAPTER is
    generic (
        MFB_REGIONS     : integer := 1;
        MFB_REGION_SIZE : integer := 1;
        MFB_BLOCK_SIZE  : integer := 8;
        MFB_ITEM_WIDTH  : integer := 32;

        -- HBM parameters for its AXI interface
        HBM_DATA_WIDTH  : natural := 256;
        HBM_ADDR_WIDTH  : natural := 34;
        HBM_BURST_WIDTH : natural := 2;
        HBM_ID_WIDTH    : natural := 6;
        HBM_LEN_WIDTH   : natural := 4;
        HBM_SIZE_WIDTH  : natural := 3;
        HBM_RESP_WIDTH  : natural := 2
    );
    port (
        -- =========================================================================================
        -- MFB interface (slave)
        -- =========================================================================================
        RX_MFB_META_TR_LEN : in std_logic_vector(13 -1 downto 0);
        RX_MFB_META_BE     : in std_logic_vector((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto 0);
        RX_MFB_META_ADDR   : in std_logic_vector(64 -1 downto 0);

        RX_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RX_MFB_SOF     : in  std_logic;
        RX_MFB_EOF     : in  std_logic;
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- =====================================================================
        -- AXI4 interface (master)
        -- =====================================================================
        HBM_AXI_AWID    : out std_logic_vector(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_AWADDR  : out std_logic_vector(HBM_ADDR_WIDTH-1 downto 0);
        HBM_AXI_AWLEN   : out std_logic_vector(HBM_LEN_WIDTH-1 downto 0);
        HBM_AXI_AWSIZE  : out std_logic_vector(HBM_SIZE_WIDTH-1 downto 0);
        HBM_AXI_AWBURST : out std_logic_vector(HBM_BURST_WIDTH-1 downto 0);
        HBM_AXI_AWVALID : out std_logic;
        HBM_AXI_AWREADY : in  std_logic;

        HBM_AXI_WDATA        : out std_logic_vector(HBM_DATA_WIDTH-1 downto 0);
        HBM_AXI_WSTRB        : out std_logic_vector((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_WDATA_PARITY : out std_logic_vector((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_WLAST        : out std_logic;
        HBM_AXI_WVALID       : out std_logic;
        HBM_AXI_WREADY       : in  std_logic;

        HBM_AXI_BID    : in  std_logic_vector(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_BRESP  : in  std_logic_vector(HBM_RESP_WIDTH-1 downto 0);
        HBM_AXI_BVALID : in  std_logic;
        HBM_AXI_BREADY : out std_logic
    );
end entity;

architecture FULL of H2C_HYPERION_AXI_ADAPTER is
    constant MFB_W      : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    constant MFB_BYTE_W : natural := MFB_W / 8;

    signal tr_byte_offs : unsigned(4 downto 0);
    signal tr_len_u     : unsigned(RX_MFB_META_TR_LEN'range);
begin
    RX_MFB_DST_RDY  <= HBM_AXI_AWREADY and HBM_AXI_WREADY;

    HBM_AXI_AWID    <= RX_MFB_META_ADDR(HBM_ADDR_WIDTH -1 downto HBM_ADDR_WIDTH-HBM_ID_WIDTH);
    HBM_AXI_AWADDR  <= RX_MFB_META_ADDR(HBM_ADDR_WIDTH -1 downto 5) & "00000";
    -- Round up the length of the burst to whole transfers
    tr_byte_offs    <= unsigned(RX_MFB_META_ADDR(4 downto 0));
    tr_len_u        <= unsigned(RX_MFB_META_TR_LEN) + tr_byte_offs + MFB_BYTE_W -1;
    HBM_AXI_AWLEN   <= std_logic_vector(resize(shift_right(tr_len_u, log2(MFB_BYTE_W)), HBM_LEN_WIDTH) -1);
    HBM_AXI_AWSIZE  <= "101";
    HBM_AXI_AWBURST <= "01";            -- NOTE: INCREMENTING BURST ONLY for our own risk :)
    -- The setting of address and transaction ID is actually a one clock cycle event and it
    -- is therefore tied to the SOF signal.
    HBM_AXI_AWVALID <= RX_MFB_SOF and RX_MFB_SRC_RDY and HBM_AXI_WREADY;

    HBM_AXI_WDATA        <= RX_MFB_DATA;
    HBM_AXI_WSTRB        <= RX_MFB_META_BE;
    HBM_AXI_WDATA_PARITY <= (others => '0');  -- NOTE: implement parity if needed
    HBM_AXI_WLAST        <= RX_MFB_EOF;
    HBM_AXI_WVALID       <= RX_MFB_SRC_RDY and HBM_AXI_AWREADY;

    HBM_AXI_BREADY <= '1';  -- Always ready to accept write responses
end architecture;