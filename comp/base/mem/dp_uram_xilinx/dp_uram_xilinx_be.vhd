-- dp_uram_xilinx_be.vhd: Dual port implementation of URAM with byte enable
-- Copyright (C) 2025 CESNET
-- Author(s): Vladislav Valek <valekv@cesnet.cz>
--
-- SPDX-License-Identifier: BSD-3-Clause

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

-- Note:

entity DP_URAM_XILINX_BE is
    generic (
        --! Input/output data width.
        DATA_WIDTH     : integer := 72;
        --! Address bus width.
        ITEMS          : integer := 12;
        --! Enables additional output registers. WARNING! May cause request loss if PIPE_EN is '0'
        ADDITIONAL_REG : integer := 0;
        );
    port (
        CLK : in std_logic;

        RSTA     : in  std_logic
        PIPE_ENA : in  std_logic;
        REA      : in  std_logic;
        WEA      : in  std_logic;
        ADDRA    : in  std_logic_vector(ADDRESS_WIDTH-1 downto 0);
        DIA      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        DOA      : out std_logic_vector(DATA_WIDTH-1 downto 0);
        DOA_DV   : out std_logic;

        RSTB     : in  std_logic
        PIPE_ENB : in  std_logic;
        REB      : in  std_logic;
        WEB      : in  std_logic;
        ADDRB    : in  std_logic_vector(ADDRESS_WIDTH-1 downto 0);
        DIB      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        DOB      : out std_logic_vector(DATA_WIDTH-1 downto 0);
        DOB_DV   : out std_logic
        );
end entity;

architecture FULL of DP_URAM_XILINX_BE is
    constant READ_LATENCY : integer := 1 + ADDITIONAL_REG;

    signal reg_data_a_vld : std_logic_vector(READ_LATENCY-1 downto 0);
    signal reg_data_b_vld : std_logic_vector(READ_LATENCY-1 downto 0);
begin
    xpm_tdp_macro_i : component xpm_memory_tdpram
        generic map (
            --! Common memory genercis
            MEMORY_SIZE             => 2**ADDRESS_WIDTH*DATA_WIDTH,  -- Positive integer
            MEMORY_PRIMITIVE        => "ultra",  -- string "auto", "distributed, "block" "ultra"
            CLOCKING_MODE           => "common_clock",  -- string "common_clock" or "independent_clock"
            MEMORY_INIT_FILE        => "none",   -- string "none: or "<filename>.mem"
            MEMORY_INIT_PARAM       => "",       -- string
            USE_MEM_INIT            => 0,        -- integer 0,1
            WAKEUP_TIME             => "disable_sleep",  -- string "disable_sleep" or "use_sleep_pin"
            MESSAGE_CONTROL         => 0,        -- integer
            ECC_MODE                => "no_ecc",        -- string
            AUTO_SLEEP_TIME         => 0,        -- do not change
            USE_EMBEDDED_CONSTRAINT => 0,        -- integer
            MEMORY_OPTIMIZATION     => "true",   -- string "true" or "false"

            -- Port A module generics
            WRITE_DATA_WIDTH_A => DATA_WIDTH,   -- Positive integer
            READ_DATA_WIDTH_A  => DATA_WIDTH,   -- positive integer
            BYTE_WRITE_WIDTH_A => 8,    -- positive integer 8,9 or WRITE_DATA_WIDTH_A
            ADDR_WIDTH_A       => log2(ITEMS),  -- positive integer
            READ_RESET_VALUE_A => "0",  -- string
            READ_LATENCY_A     => READ_LATENCY,  -- non negative integer
            WRITE_MODE_A       => "NO_CHANGE",  -- Do not change. UltraRAM does not support different write modes on true dual port units

            -- Port B module generics
            WRITE_DATA_WIDTH_B => DATA_WIDTH,  -- Positive integer
            READ_DATA_WIDTH_B  => DATA_WIDTH,  -- positive integer
            BYTE_WRITE_WIDTH_B => 8,    -- positive integer 8,9 or WRITE_DATA_WIDTH_A
            ADDR_WIDTH_B       => log2(ITEMS),   -- positive integer
            READ_RESET_VALUE_B => "0",  -- string
            READ_LATENCY_B     => READ_LATENCY,  -- non negative integer
            WRITE_MODE_B       => "NO_CHANGE"  -- DO not change. UltraRam does not support different write modes on true dual port units
            )
        port map (
            sleep => '0',

            clka           => CLK,
            rsta           => RSTA,
            ena            => PIPE_ENA,
            regcea         => PIPE_ENA,
            wea            => WEA,
            addra          => ADDRA,
            dina           => DIA,
            injectsbiterra => '0',
            injectdbiterra => '0',
            douta          => DOA,
            sbiterra       => open,
            dbiterra       => open,

            clkb           => CLK,
            rstb           => RSTB,
            enb            => PIPE_ENB,
            regceb         => PIPE_ENB,
            web            => WEB,
            addrb          => ADDRB,
            dinb           => DIB,
            injectsbiterrb => '0',
            injectdbiterrb => '0',
            doutb          => DOB,
            sbiterrb       => open,
            dbiterrb       => open
            );

    rd_data_vld_regs_g : if (READ_LATENCY > 1) generate
        rd_data_vld_a : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (RSTA = '1') then
                    reg_data_a_vld <= (others => '0');
                elsif (PIPE_ENA = '1') then
                    reg_data_a_vld <= reg_data_a_vld(READ_LATENCY -2 downto 0) & REA;
                end if;
            end if;
        end process;

        rd_data_vld_b : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (RSTB = '1') then
                    reg_data_b_vld <= (others => '0');
                elsif (PIPE_ENB = '1') then
                    reg_data_b_vld <= reg_data_b_vld(READ_LATENCY -2 downto 0) & REB;
                end if;
            end if;
        end process;

        DOA_DV <= reg_data_a_vld(READ_LATENCY-1);
        DOB_DV <= reg_data_b_vld(READ_LATENCY-1);

    else generate
        rd_data_vld_a : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (RSTA = '1') then
                    DOA_DV <= '0';
                elsif (PIPE_ENA = '1') then
                    DOA_DV <= REA;
                end if;
            end if;
        end process;

        rd_data_vld_b : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (RSTB = '1') then
                    DOB_DV <= '0';
                elsif (PIPE_ENB = '1') then
                    DOB_DV <= REB;
                end if;
            end if;
        end process;
    end generate;
end architecture;
