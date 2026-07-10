-- tdp_bram_be.vhd: Behavioral true dual-port RAM with per-byte write enables (BRAM/URAM selectable)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;

-- A behavioral, inference-based true dual-port memory with independent per-byte write enables on
-- both ports and a read latency of exactly 1 clock cycle (NO_CHANGE behavior during a write on the
-- same port). It is used as the memory core of TX_DMA_PCIE_TRANS_BUFFER's even/odd row banking
-- scheme, where it replaces the former one-BRAM-per-byte array. The RAM_TYPE generic selects the
-- target primitive: "BRAM" infers a block RAM, "URAM" infers an UltraScale+/Versal Ultra RAM (AMD
-- devices only).
--
-- .. NOTE:: On AMD devices, the shared-variable + two-processes-per-port structure below is the
--    exact template verified (Vivado 2025.1) to synthesize into URAM288/RAMB36 primitives; do not
--    restructure it (e.g. merging the read and write process of a port into one), doing so has been
--    observed to break inference ("Unsupported RAM template" / "invalid write mode"). Vivado emits a
--    benign "shared variables must be of a protected type" warning and a same-address TDP simulation
--    mismatch warning for this construct; both are harmless here since the wrapper never reads data
--    racing a same-port write and cross-port same-row writes always use disjoint byte enables.
entity TDP_BRAM_BE is
    generic (
        -- Data word width in bits, must be a multiple of 8
        DATA_WIDTH : natural := 512;
        -- Depth of the memory in number of data words
        ITEMS      : natural := 4096;
        -- Target memory primitive: "BRAM" or "URAM" ("URAM" is only valid for AMD devices)
        RAM_TYPE   : string  := "BRAM";
        -- Target device, see TX_DMA_PCIE_TRANS_BUFFER's DEVICE generic for the allowed values
        DEVICE     : string  := "ULTRASCALE"
    );
    port (
        CLK : in std_logic;

        -- =========================================================================================
        -- Port A
        -- =========================================================================================
        -- Memory enable of port A: drive with (or WEA) or a read issue
        ENA   : in  std_logic;
        WEA   : in  std_logic_vector(DATA_WIDTH/8 -1 downto 0);
        ADDRA : in  std_logic_vector(log2(ITEMS) -1 downto 0);
        DIA   : in  std_logic_vector(DATA_WIDTH -1 downto 0);
        DOA   : out std_logic_vector(DATA_WIDTH -1 downto 0);

        -- =========================================================================================
        -- Port B
        -- =========================================================================================
        -- Memory enable of port B: drive with (or WEB) or a read issue
        ENB   : in  std_logic;
        WEB   : in  std_logic_vector(DATA_WIDTH/8 -1 downto 0);
        ADDRB : in  std_logic_vector(log2(ITEMS) -1 downto 0);
        DIB   : in  std_logic_vector(DATA_WIDTH -1 downto 0);
        DOB   : out std_logic_vector(DATA_WIDTH -1 downto 0)
    );
end entity;

architecture BEHAV of TDP_BRAM_BE is

    constant NUM_COL      : natural                          := DATA_WIDTH/8;
    constant ZEROS        : std_logic_vector(NUM_COL -1 downto 0) := (others => '0');
    constant IS_INTEL_DEV : boolean                          := (DEVICE = "STRATIX10" or DEVICE = "AGILEX");

begin

    assert (RAM_TYPE = "BRAM" or RAM_TYPE = "URAM")
        report "TDP_BRAM_BE: Illegal value of RAM_TYPE, allowed values are: BRAM, URAM!"
        severity failure;

    assert (not (RAM_TYPE = "URAM" and IS_INTEL_DEV))
        report "TDP_BRAM_BE: RAM_TYPE=URAM is only supported on AMD devices!"
        severity failure;

    -- =============================================================================================
    -- AMD (Xilinx) devices: shared-variable inference template, BRAM or URAM selectable through the
    -- ram_style attribute literal. Two generate branches (instead of one parametrized by a variable
    -- attribute value) because Vivado only reliably infers URAM/BRAM from a literal string.
    -- =============================================================================================
    xilinx_g : if (not IS_INTEL_DEV) generate

        uram_g : if (RAM_TYPE = "URAM") generate
            type            mem_t is array (0 to ITEMS -1) of std_logic_vector(DATA_WIDTH -1 downto 0);
            shared variable mem_v : mem_t;

            signal memrega : std_logic_vector(DATA_WIDTH -1 downto 0);
            signal memregb : std_logic_vector(DATA_WIDTH -1 downto 0);

            attribute ram_style : string;
            attribute ram_style of mem_v : variable is "ultra";
        begin
            wr_a_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENA = '1') then
                        for i in 0 to NUM_COL -1 loop
                            if (WEA(i) = '1') then
                                mem_v(to_integer(unsigned(ADDRA)))((i+1)*8 -1 downto i*8) := DIA((i+1)*8 -1 downto i*8);
                            end if;
                        end loop;
                    end if;
                end if;
            end process;

            rd_a_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENA = '1') then
                        if (WEA = ZEROS) then
                            memrega <= mem_v(to_integer(unsigned(ADDRA)));
                        end if;
                    end if;
                end if;
            end process;

            DOA <= memrega;

            wr_b_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENB = '1') then
                        for i in 0 to NUM_COL -1 loop
                            if (WEB(i) = '1') then
                                mem_v(to_integer(unsigned(ADDRB)))((i+1)*8 -1 downto i*8) := DIB((i+1)*8 -1 downto i*8);
                            end if;
                        end loop;
                    end if;
                end if;
            end process;

            rd_b_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENB = '1') then
                        if (WEB = ZEROS) then
                            memregb <= mem_v(to_integer(unsigned(ADDRB)));
                        end if;
                    end if;
                end if;
            end process;

            DOB <= memregb;
        end generate;

        bram_g : if (RAM_TYPE = "BRAM") generate
            type            mem_t is array (0 to ITEMS -1) of std_logic_vector(DATA_WIDTH -1 downto 0);
            shared variable mem_v : mem_t;

            signal memrega : std_logic_vector(DATA_WIDTH -1 downto 0);
            signal memregb : std_logic_vector(DATA_WIDTH -1 downto 0);

            attribute ram_style : string;
            attribute ram_style of mem_v : variable is "block";
        begin
            wr_a_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENA = '1') then
                        for i in 0 to NUM_COL -1 loop
                            if (WEA(i) = '1') then
                                mem_v(to_integer(unsigned(ADDRA)))((i+1)*8 -1 downto i*8) := DIA((i+1)*8 -1 downto i*8);
                            end if;
                        end loop;
                    end if;
                end if;
            end process;

            rd_a_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENA = '1') then
                        if (WEA = ZEROS) then
                            memrega <= mem_v(to_integer(unsigned(ADDRA)));
                        end if;
                    end if;
                end if;
            end process;

            DOA <= memrega;

            wr_b_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENB = '1') then
                        for i in 0 to NUM_COL -1 loop
                            if (WEB(i) = '1') then
                                mem_v(to_integer(unsigned(ADDRB)))((i+1)*8 -1 downto i*8) := DIB((i+1)*8 -1 downto i*8);
                            end if;
                        end loop;
                    end if;
                end if;
            end process;

            rd_b_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    if (ENB = '1') then
                        if (WEB = ZEROS) then
                            memregb <= mem_v(to_integer(unsigned(ADDRB)));
                        end if;
                    end if;
                end if;
            end process;

            DOB <= memregb;
        end generate;

    end generate;

    -- =============================================================================================
    -- Intel devices: structural mapping, one 8-bit DP_BRAM_BEHAV column per byte, all columns of a
    -- port sharing that port's address. This is functionally identical to the pre-banking
    -- implementation (Quartus inference of a shared-variable byte-enable TDP is unreliable, so it is
    -- not attempted here).
    -- =============================================================================================
    intel_g : if (IS_INTEL_DEV) generate
        columns_g : for i in 0 to NUM_COL -1 generate
            dp_bram_be_i : entity work.DP_BRAM_BEHAV
            generic map (
                DATA_WIDTH => 8,
                ITEMS      => ITEMS,
                OUTPUT_REG => FALSE,
                RDW_MODE_A => "WRITE_FIRST",
                RDW_MODE_B => "WRITE_FIRST"
            )
            port map (
                CLK => CLK,
                RST => '0',

                PIPE_ENA => ENA,
                REA      => '0',
                WEA      => WEA(i),
                ADDRA    => ADDRA,
                DIA      => DIA((i+1)*8 -1 downto i*8),
                DOA      => DOA((i+1)*8 -1 downto i*8),
                DOA_DV   => open,

                PIPE_ENB => ENB,
                REB      => '0',
                WEB      => WEB(i),
                ADDRB    => ADDRB,
                DIB      => DIB((i+1)*8 -1 downto i*8),
                DOB      => DOB((i+1)*8 -1 downto i*8),
                DOB_DV   => open
            );
        end generate;
    end generate;

end architecture;
