-- tx_dma_pcie_trans_buffer.vhd: this is a specially made component to buffer PCIe transactions
-- Copyright (C) 2023 CESNET z.s.p.o.
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--            David Benes      <xbenes52@vutbr.cz>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.tx_dma_pcie_trans_buffer_pkg.all;

-- Buffers the PCIe writes of every channel at byte alignment in a per-byte BRAM array. On AMD
-- devices, URAM or flat addressing select two even/odd row banks of XPM memories instead.
entity TX_DMA_PCIE_TRANS_BUFFER is
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
        READ_BARREL_SHIFTER_EN : b_array_t(MFB_REGIONS -1 downto 0) := (others => TRUE);

        -- Memory primitive: AUTO resolves to URAM for 2 regions on UltraScale+/Versal when a bank
        -- holds at least 2048 rows, else BRAM. URAM needs an AMD DEVICE.
        RAM_TYPE : string := "AUTO";

        -- TRUE (default): each channel owns a 2**POINTER_WIDTH-byte region. FALSE: one flat
        -- CHANNELS*2**POINTER_WIDTH-byte space addressed only by the address field; RD_ADDR_*
        -- widens by log2(CHANNELS) bits.
        MEM_PARTITIONING : boolean := TRUE
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
        RD_ADDR_A     : in  std_logic_vector(POINTER_WIDTH + tsel(MEM_PARTITIONING, 0, log2(CHANNELS)) -1 downto 0);
        RD_EN_A       : in  std_logic;
        RD_DATA_VLD_A : out std_logic;

        -- Output reading interface for port B. Unused if SPLIT_READ_PORTS=FALSE or MFB configuration is (1,1,8,32).
        RD_CHAN_B     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_B     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0) := (others => '0');
        RD_ADDR_B     : in  std_logic_vector(POINTER_WIDTH + tsel(MEM_PARTITIONING, 0, log2(CHANNELS)) -1 downto 0);
        RD_EN_B       : in  std_logic;
        RD_DATA_VLD_B : out std_logic := '0'
    );
end entity;

architecture FULL of TX_DMA_PCIE_TRANS_BUFFER is

    constant IS_INTEL_DEV       : boolean := (DEVICE = "STRATIX10" or DEVICE = "AGILEX");
    constant IS_XILINX_URAM_DEV : boolean := (DEVICE = "ULTRASCALE" or DEVICE = "VERSAL");

    -- Rows of one even/odd bank if the channels shared URAM-sized (16384-row) arrays.
    constant BUFFER_DEPTH      : natural := trbuf_buffer_depth_f(POINTER_WIDTH, MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH);
    constant BANK_ITEMS_URAM_C : natural := (trbuf_chans_per_array_f(CHANNELS, BUFFER_DEPTH, TRBUF_DEPTH_URAM) * BUFFER_DEPTH) / 2;
    -- Resolved once here and passed to the banked buffer as its RAM_TYPE.
    constant RES_RAM_TYPE      : string := tsel(
        (RAM_TYPE = "URAM") or (RAM_TYPE = "AUTO" and IS_XILINX_URAM_DEV and MFB_REGIONS = 2 and BANK_ITEMS_URAM_C >= 2048),
        "URAM", "BRAM");
    -- The banked buffer only where the per-byte one cannot serve the generics.
    constant USE_BANKED        : boolean := (not IS_INTEL_DEV) and
        (RES_RAM_TYPE = "URAM" or (not MEM_PARTITIONING));

begin

    impl_g : if (not USE_BANKED) generate

        assert ((RAM_TYPE = "AUTO" or RAM_TYPE = "BRAM") and MEM_PARTITIONING)
            report "TX_DMA_PCIE_TRANS_BUFFER: on an Intel DEVICE, RAM_TYPE must be AUTO or BRAM and MEM_PARTITIONING must keep its default!"
            severity FAILURE;

        trans_buffer_i : entity work.TX_DMA_PCIE_TRANS_BUFFER_IMPL(BYTE)
        generic map (
            DEVICE => DEVICE,

            CHANNELS => CHANNELS,

            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,

            POINTER_WIDTH          => POINTER_WIDTH,
            SPLIT_READ_PORTS       => SPLIT_READ_PORTS,
            READ_BARREL_SHIFTER_EN => READ_BARREL_SHIFTER_EN,

            RAM_TYPE         => RES_RAM_TYPE,
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

    else generate

        trans_buffer_i : entity work.TX_DMA_PCIE_TRANS_BUFFER_IMPL(BANKED)
        generic map (
            DEVICE => DEVICE,

            CHANNELS => CHANNELS,

            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,

            POINTER_WIDTH          => POINTER_WIDTH,
            SPLIT_READ_PORTS       => SPLIT_READ_PORTS,
            READ_BARREL_SHIFTER_EN => READ_BARREL_SHIFTER_EN,

            RAM_TYPE         => RES_RAM_TYPE,
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

    end generate;

end architecture;
