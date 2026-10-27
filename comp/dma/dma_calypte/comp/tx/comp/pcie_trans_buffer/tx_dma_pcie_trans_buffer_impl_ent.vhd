-- tx_dma_pcie_trans_buffer_impl_ent.vhd: entity of the implementations of the PCIe transaction buffer
-- Copyright (C) 2023 CESNET z.s.p.o.
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--            David Benes      <xbenes52@vutbr.cz>
--            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.tx_dma_pcie_trans_buffer_pkg.all;

-- The implementations of TX_DMA_PCIE_TRANS_BUFFER, with its generics and ports: the BYTE architecture with a per-byte
-- BRAM array and the BANKED architecture with two even/odd row banks of XPM memories for AMD devices.
entity TX_DMA_PCIE_TRANS_BUFFER_IMPL is
    generic (
        DEVICE : string := "ULTRASCALE";

        -- Total number of DMA Channels within this DMA Endpoint
        CHANNELS : natural := 8;

        -- Input MFB interface
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;

        -- Determines the number of bytes that can be stored in the buffer.
        -- The amount of bytes equals 2\*\*POINTER_WIDTH
        POINTER_WIDTH          : natural := 16;
        -- If true, each port of the TDPs (used by the 2,1,8,32 MFB configuration) is controlled by
        -- separate interfaces
        SPLIT_READ_PORTS       : boolean := FALSE;
        -- Per read port (A = 0, B = 1): TRUE shifts the read data to the address low-bit offset, FALSE
        -- returns the plain MFB-word-aligned row. Index 1 applies only with SPLIT_READ_PORTS; otherwise
        -- port A serves every read and index 0 is used.
        READ_BARREL_SHIFTER_EN : b_array_t(MFB_REGIONS -1 downto 0) := (others => TRUE)
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- Input MFB bus (quasi BRAM writing interface)
        -- =========================================================================================
        PCIE_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_MFB_META    : in  slv_array_t(MFB_REGIONS -1 downto 0)(trbuf_meta_width_f(CHANNELS, MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)-1 downto 0);
        PCIE_MFB_SOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_SRC_RDY : in  std_logic;

        -- Output reading interface for port A of the TDP or the single read port of the SDP
        RD_CHAN_A     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_A     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RD_ADDR_A     : in  std_logic_vector(POINTER_WIDTH -1 downto 0);
        RD_EN_A       : in  std_logic;
        RD_DATA_VLD_A : out std_logic;

        -- Output reading interface for port B. Unused if SPLIT_READ_PORTS=FALSE or MFB configuration is (1,1,8,32).
        RD_CHAN_B     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_B     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0) := (others => '0');
        RD_ADDR_B     : in  std_logic_vector(POINTER_WIDTH -1 downto 0);
        RD_EN_B       : in  std_logic;
        RD_DATA_VLD_B : out std_logic := '0'
    );
end entity;
