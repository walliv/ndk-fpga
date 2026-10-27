-- tx_dma_pcie_trans_buffer_tb_wrapper.vhd: test-only wrapper of TX_DMA_PCIE_TRANS_BUFFER
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.tx_dma_pcie_trans_buffer_pkg.all;

-- Cocotb toplevel in place of TX_DMA_PCIE_TRANS_BUFFER: nvc cannot set a b_array_t generic from the command line, so READ_BARREL_SHIFTER_EN comes in as a bit mask.
entity TX_DMA_PCIE_TRANS_BUFFER_TB_WRAPPER is
    generic (
        DEVICE : string := "ULTRASCALE";

        CHANNELS : natural := 8;

        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;

        POINTER_WIDTH            : natural := 16;
        SPLIT_READ_PORTS         : boolean := FALSE;
        -- Bit p is READ_BARREL_SHIFTER_EN(p); bits from MFB_REGIONS up are ignored.
        READ_BARREL_SHIFTER_MASK : natural := 3;

        RAM_TYPE         : string  := "AUTO";
        MEM_PARTITIONING : boolean := TRUE
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        PCIE_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_MFB_META    : in  slv_array_t(MFB_REGIONS -1 downto 0)(trbuf_meta_width_f(CHANNELS, MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)-1 downto 0);
        PCIE_MFB_SOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_SRC_RDY : in  std_logic;

        RD_CHAN_A     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_A     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RD_ADDR_A     : in  std_logic_vector(POINTER_WIDTH + tsel(MEM_PARTITIONING, 0, log2(CHANNELS)) -1 downto 0);
        RD_EN_A       : in  std_logic;
        RD_DATA_VLD_A : out std_logic;

        RD_CHAN_B     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_B     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RD_ADDR_B     : in  std_logic_vector(POINTER_WIDTH + tsel(MEM_PARTITIONING, 0, log2(CHANNELS)) -1 downto 0);
        RD_EN_B       : in  std_logic;
        RD_DATA_VLD_B : out std_logic
    );
end entity;

architecture FULL of TX_DMA_PCIE_TRANS_BUFFER_TB_WRAPPER is

    function mask_to_b_array_f (mask : natural; width : natural) return b_array_t is
        variable res : b_array_t(width -1 downto 0);
    begin
        for p in 0 to (width -1) loop
            res(p) := ((mask / 2**p) mod 2) = 1;
        end loop;
        return res;
    end function;

begin

    tx_dma_pcie_trans_buffer_i : entity work.TX_DMA_PCIE_TRANS_BUFFER
    generic map (
        DEVICE   => DEVICE,
        CHANNELS => CHANNELS,

        MFB_REGIONS     => MFB_REGIONS,
        MFB_REGION_SIZE => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,

        POINTER_WIDTH          => POINTER_WIDTH,
        SPLIT_READ_PORTS       => SPLIT_READ_PORTS,
        READ_BARREL_SHIFTER_EN => mask_to_b_array_f(READ_BARREL_SHIFTER_MASK, MFB_REGIONS),

        RAM_TYPE         => RAM_TYPE,
        MEM_PARTITIONING => MEM_PARTITIONING
    )
    port map (
        CLK   => CLK,
        RESET => RESET,

        PCIE_MFB_DATA    => PCIE_MFB_DATA,
        PCIE_MFB_META    => PCIE_MFB_META,
        PCIE_MFB_SOF     => PCIE_MFB_SOF,
        PCIE_MFB_SRC_RDY => PCIE_MFB_SRC_RDY,

        RD_CHAN_A     => RD_CHAN_A,
        RD_DATA_A     => RD_DATA_A,
        RD_ADDR_A     => RD_ADDR_A,
        RD_EN_A       => RD_EN_A,
        RD_DATA_VLD_A => RD_DATA_VLD_A,

        RD_CHAN_B     => RD_CHAN_B,
        RD_DATA_B     => RD_DATA_B,
        RD_ADDR_B     => RD_ADDR_B,
        RD_EN_B       => RD_EN_B,
        RD_DATA_VLD_B => RD_DATA_VLD_B
    );

end architecture;
