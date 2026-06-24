-- h2c_hyperion_meta_ext.vhd: performs initial processing of packets comming to the DMA
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
use work.pcie_meta_pack.all;

entity H2C_HYPERION_META_EXT is
    generic (
        DEVICE : string := "ULTRASCALE";

        -- Configuration of the input and output MFB interface
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- PCIe MFB interface
        -- =========================================================================================
        PCIE_MFB_BE      : in std_logic_vector((MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto 0);
        PCIE_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        -- More information about the content of this port can be found in *pcie_meta_pack*
        PCIE_MFB_META    : in  std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
        PCIE_MFB_SOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_EOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        PCIE_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_MFB_SRC_RDY : in  std_logic;
        PCIE_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- User MFB signals

        -- Metadata are all valid with SOF except for USR_MFB_META_BYTE_EN.
        -- =========================================================================================
        USR_MFB_META_TR_LEN : out slv_array_t(MFB_REGIONS -1 downto 0)(13 -1 downto 0);
        USR_MFB_META_BE     : out slv_array_t(MFB_REGIONS -1 downto 0)((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto 0);
        USR_MFB_META_ADDR   : out slv_array_t(MFB_REGIONS -1 downto 0)(64 -1 downto 0);

        USR_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        USR_MFB_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        USR_MFB_EOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        USR_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        USR_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        USR_MFB_SRC_RDY : out std_logic;
        USR_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Status counters
        -- =========================================================================================
        PCIE_REQ_TOTAL_BYTES    : out std_logic_vector(13 -1 downto 0);
        PCIE_RD_REQ_TOTAL_INCR  : out std_logic;
        PCIE_WR_REQ_TOTAL_INCR  : out std_logic
    );
end entity;

architecture FULL of H2C_HYPERION_META_EXT is

    constant MFB_LENGTH         : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    constant BAR_APERTURE_INTEL : natural := 24;

    -- package h2c_meta_pkg_i is new work.h2c_meta_pkg
    -- generic map (
    --     MFB_REGION_SIZE => MFB_REGION_SIZE,
    --     MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
    --     MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH);

    -- use h2c_meta_pkg_i.all;

    -- =============================================================================================
    -- Internal Signals
    -- =============================================================================================
    -- the extracted pcie header
    signal pcie_hdr_data_int     : slv_array_t(MFB_REGIONS - 1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);

    -- Input port arrays
    signal pcie_mfb_data_arr     : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
    signal pcie_mfb_meta_arr     : slv_array_t(MFB_REGIONS - 1 downto 0)(PCIE_CQ_META_WIDTH -1 downto 0);

    -- extracted fields from the PCIe header
    signal pcie_hdr_addr         : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
    signal pcie_hdr_bar_aperture : slv_array_t(MFB_REGIONS - 1 downto 0)(5 downto 0);
    signal pcie_hdr_fbe          : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);
    signal pcie_hdr_lbe          : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);
    signal pcie_hdr_dw_count     : slv_array_t(MFB_REGIONS - 1 downto 0)(10 downto 0);
    signal pcie_hdr_req_type     : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);
    signal pcie_is_read_req      : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal pcie_is_write_req     : std_logic_vector(MFB_REGIONS -1 downto 0);

    signal pcie_addr_mask        : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
    signal pcie_addr_masked      : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
    signal pcie_byte_addr        : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);

    signal pcie_tr_byte_cnt  : slv_array_t(MFB_REGIONS - 1 downto 0)(13 -1 downto 0);
    signal pcie_fst_ib       : slv_array_t(MFB_REGIONS - 1 downto 0)(2 -1 downto 0);
begin

    assert (MFB_REGIONS = 1 and MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 8 and MFB_ITEM_WIDTH = 32)
        report "H2C_HYPERION_META_EXT: only MFB configuration with 1 region of size 1 block of 8 items of 32 bits is supported"
        severity FAILURE;

    -- =============================================================================================
    -- Deserialize input data
    --
    -- NOTE: pcie_hdr_addr_len is not used but it does not make sense anyway since the BAR aperture
    -- is never greater than 32 bits. The top 32 bits are always 0.
    -- =============================================================================================
    pcie_mfb_data_arr   <= slv_array_deser(PCIE_MFB_DATA, MFB_REGIONS);
    pcie_mfb_meta_arr   <= slv_array_deser(PCIE_MFB_META, MFB_REGIONS);

    pcie_hdr_deparser_g: for i in MFB_REGIONS - 1 downto 0 generate
        device_sel_pcie_hdr_g: if (DEVICE = "ULTRASCALE") generate
            pcie_hdr_data_int(i) <= pcie_mfb_data_arr(i)(PCIE_CQ_META_HEADER);
        else generate
            pcie_hdr_data_int(i) <= pcie_mfb_meta_arr(i)(PCIE_CQ_META_HEADER);
        end generate;

        pcie_hdr_deparser_i : entity work.PCIE_CQ_HDR_DEPARSER
        generic map (
            DEVICE => DEVICE
        )
        port map (
            OUT_TAG          => open,
            OUT_ADDRESS      => pcie_hdr_addr(i),
            OUT_REQ_ID       => open,
            OUT_TC           => open,
            OUT_DW_CNT       => pcie_hdr_dw_count(i),
            OUT_ATTRIBUTES   => open,
            OUT_FBE          => pcie_hdr_fbe(i),
            OUT_LBE          => pcie_hdr_lbe(i),
            OUT_ADDRESS_TYPE => open,
            OUT_TARGET_FUNC  => open,
            OUT_BAR_ID       => open,
            OUT_BAR_APERTURE => pcie_hdr_bar_aperture(i),
            OUT_ADDR_LEN     => open,
            OUT_REQ_TYPE     => pcie_hdr_req_type(i),

            IN_HEADER     => pcie_hdr_data_int(i),
            IN_FBE        => pcie_mfb_meta_arr(i)(PCIE_CQ_META_FBE),
            IN_LBE        => pcie_mfb_meta_arr(i)(PCIE_CQ_META_LBE),

            -- Only for Intel devices
            IN_INTEL_META => std_logic_vector(to_unsigned(BAR_APERTURE_INTEL, 6)) & pcie_mfb_meta_arr(i)(PCIE_CQ_META_BAR) & (8 - 1 downto 0 => '0')
        );

        -- =============================================================================================
        -- creates mask for pcie addr based on the BAR APERTURE value in the PCIE header
        -- =============================================================================================
        addr_mask_gen_p : process (all)
            variable mask_var : slv_array_t(MFB_REGIONS - 1 downto 0)(63  downto 0);
        begin
            mask_var(i) := (others => '0');
            for j in 0 to 63 loop
                if (j < unsigned(pcie_hdr_bar_aperture(i))) then
                    mask_var(i)(j) := '1';
                end if;
            end loop;
            pcie_addr_mask(i) <= mask_var(i);
        end process;

        pcie_addr_masked(i) <= pcie_hdr_addr(i) and pcie_addr_mask(i);
        pcie_byte_addr(i) <= std_logic_vector(unsigned(pcie_addr_masked(i)) + unsigned(pcie_fst_ib(i)));

        pcie_byte_count_i : entity work.PCIE_BYTE_COUNT
        generic map (
            OUTPUT_REG => FALSE
        )
        port map (
            CLK            => CLK,
            RESET          => RESET,

            IN_DW_COUNT    => pcie_hdr_dw_count(i),
            IN_FIRST_BE    => pcie_hdr_fbe(i),
            IN_LAST_BE     => pcie_hdr_lbe(i),

            OUT_FIRST_IB   => pcie_fst_ib(i),
            OUT_LAST_IB    => open,
            OUT_BYTE_COUNT => pcie_tr_byte_cnt(i)
        );

        pcie_is_write_req(i) <= '1' when pcie_hdr_req_type(i) = "0010" else '0';
        pcie_is_read_req(i)  <= '1' when pcie_hdr_req_type(i) = "0001" else '0';

        USR_MFB_META_TR_LEN(i) <= pcie_tr_byte_cnt(i);
        USR_MFB_META_BE(i)     <= PCIE_MFB_BE((i+1)*(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto i*(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8);
        USR_MFB_META_ADDR(i)   <= pcie_byte_addr(i);
    end generate;

    PCIE_REQ_TOTAL_BYTES   <= pcie_tr_byte_cnt(0);
    PCIE_RD_REQ_TOTAL_INCR <= pcie_is_read_req(0) and PCIE_MFB_SOF(0) and PCIE_MFB_SRC_RDY and PCIE_MFB_DST_RDY;
    PCIE_WR_REQ_TOTAL_INCR <= pcie_is_write_req(0) and PCIE_MFB_SOF(0) and PCIE_MFB_SRC_RDY and PCIE_MFB_DST_RDY;

    USR_MFB_DATA     <= PCIE_MFB_DATA;
    USR_MFB_SOF      <= PCIE_MFB_SOF;
    USR_MFB_EOF      <= PCIE_MFB_EOF;
    USR_MFB_SOF_POS  <= PCIE_MFB_SOF_POS;
    USR_MFB_EOF_POS  <= PCIE_MFB_EOF_POS;
    USR_MFB_SRC_RDY  <= PCIE_MFB_SRC_RDY;
    PCIE_MFB_DST_RDY <= USR_MFB_DST_RDY;
end architecture;
