-- app_briski_top.vhd: top-level entity for the testing of BRISKI's maximal frequency
-- Copyright (C) 2025 CESNET z. s. p. o.
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;

entity APP_BRISKI_TOP is
    port (
        -- FPGA system clock
        FPGA_SYSCLK0_100M_P : in std_logic;

        -- User LEDs
        USER_LED_G : out std_logic_vector(3 downto 0)
        );
end entity;

architecture FULL of APP_BRISKI_TOP is

    component BRAM
        generic (
            SIZE           : integer := 1024;
            ADDR_WIDTH     : integer := 10;
            COL_WIDTH      : integer := 8;
            NB_COL         : integer := 4;
            INIT_FILE      : string  := "";
            RAM_STYLE_ATTR : string  := "block"
            );
        port (
            clka  : in  std_logic;
            ena   : in  std_logic;
            wea   : in  std_logic_vector(NB_COL-1 downto 0);
            addra : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            dia   : in  std_logic_vector(NB_COL*COL_WIDTH-1 downto 0);
            doa   : out std_logic_vector(NB_COL*COL_WIDTH-1 downto 0);
            clkb  : in  std_logic;
            enb   : in  std_logic;
            web   : in  std_logic_vector(NB_COL-1 downto 0);
            addrb : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            dib   : in  std_logic_vector(NB_COL*COL_WIDTH-1 downto 0);
            dob   : out std_logic_vector(NB_COL*COL_WIDTH-1 downto 0)
            );
    end component;

    component RISCV_core is
        generic (
            NUM_PIPE_STAGES               : natural := 16;
            NUM_THREADS                   : natural := 16;
            ENABLE_BRAM_REGFILE           : boolean := false;
            ENABLE_ALU_DSP                : boolean := false;
            ENABLE_UNIFIED_BARREL_SHIFTER : boolean := true;
            IDcluster                     : natural := 0;
            IDrow                         : natural := 0;
            IDminirow                     : natural := 0;
            IDposx                        : natural := 0
            );
        port (
            clk   : in std_logic;
            reset : in std_logic;

            i_ROM_instruction : in  std_logic_vector(31 downto 0);
            o_ROM_addr        : out std_logic_vector (9 downto 0);

            o_dmem_addr         : out std_logic_vector(13 downto 0);
            o_dmem_write_data   : out std_logic_vector(31 downto 0);
            o_dmem_write_enable : out std_logic_vector(3 downto 0);
            i_dmem_read_data    : in  std_logic_vector(31 downto 0);

            regfile_wr_addr : out std_logic_vector(4 downto 0);
            regfile_wr_data : out std_logic_vector(31 downto 0);
            regfile_wr_en   : out std_logic;

            thread_index_wb    : out std_logic_vector(log2(NUM_THREADS) -1 downto 0);
            thread_index_wrmem : out std_logic_vector(log2(NUM_THREADS) -1 downto 0)
            );
    end component;

    component iopll_ip is
        port (
            RST      : in  std_logic := 'X';
            REFCLK   : in  std_logic := 'X';
            LOCKED   : out std_logic;
            OUTCLK_0 : out std_logic;
            OUTCLK_1 : out std_logic;
            OUTCLK_2 : out std_logic;
            OUTCLK_3 : out std_logic
            );
    end component;

    component reset_release_ip is
        port (
            NINIT_DONE : out std_logic
            );
    end component;

    signal pll_reset : std_logic;
    signal pll_locked : std_logic;

    -- Clock and Reset Signals
    signal clkout0                  : std_logic;
    signal sync_reset               : std_logic;

    -- Done Signals
    signal done     : std_logic;
    signal done_reg : std_logic;

    -- Reset Synchronizer Registers
    signal proc_rst       : std_logic;
    signal proc_rst_reg_1 : std_logic;
    signal proc_rst_reg_2 : std_logic;
    signal proc_rst_reg_3 : std_logic;
    signal proc_rst_reg_4 : std_logic;
    signal proc_rst_reg_5 : std_logic;

    -- Instruction Memory
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_addr : std_logic_vector(9 downto 0);

    -- Data Memory
    signal RVcore_addr    : std_logic_vector(13 downto 0);
    signal RVcore_wr_data : std_logic_vector(31 downto 0);
    signal RVcore_wr_en   : std_logic_vector(3 downto 0);
    signal BRAM_rd_data : std_logic_vector(31 downto 0);

begin

    reset_release_i : component reset_release_ip
        port map (
            ninit_done => pll_reset
            );

    iopll_i : component iopll_ip
        port map (
            rst      => pll_reset,
            refclk   => FPGA_SYSCLK0_100M_P,
            locked   => pll_locked,
            outclk_0 => clkout0
            );

    global_reset_i : entity work.ASYNC_RESET
        generic map (
            TWO_REG  => FALSE,
            OUT_REG  => TRUE,
            REPLICAS => 1
            )
        port map (
            CLK        => clkout0,
            ASYNC_RST  => not pll_locked,
            OUT_RST(0) => proc_rst
            );

    -- RISC-V Core
    RISCV_core_inst : entity work.RISCV_core
        generic map (
            IDcluster => 0,
            IDrow     => 0,
            IDminirow => 0,
            IDposx    => 0
            )
        port map (
            clk                 => clkout0,
            reset               => sync_reset,
            i_ROM_instruction   => rom_data,
            o_ROM_addr          => rom_addr,
            o_dmem_addr         => RVcore_addr,
            o_dmem_write_data   => RVcore_wr_data,
            o_dmem_write_enable => RVcore_wr_en,
            i_dmem_read_data    => BRAM_rd_data,
            regfile_wr_addr     => open,
            regfile_wr_data     => open,
            regfile_wr_en       => open,
            thread_index_wb     => open,
            thread_index_wrmem  => open
            );

    -- BRAM Memory
    instr_and_data_mem : entity work.BRAM
        generic map (
            SIZE       => 1024,
            ADDR_WIDTH => 10,
            COL_WIDTH  => 8,
            NB_COL     => 4,
            INIT_FILE  => ""
            )
        port map (
            clka  => clkout0,
            ena   => '1',
            wea   => RVcore_wr_en,
            addra => RVcore_addr(9 downto 0),
            dia   => RVcore_wr_data,
            doa   => BRAM_rd_data,
            clkb  => clkout0,
            enb   => '1',
            web   => "0000",
            addrb => rom_addr,
            dib   => x"00000000",
            dob   => rom_data
            );

    -- Done signal logic
    done_reg_p : process(clkout0)
    begin
        if rising_edge(clkout0) then
            if RVcore_wr_en /= "0000" then
                done <= '1';
            else
                done <= '0';
            end if;

            done_reg       <= done;

            proc_rst_reg_1 <= proc_rst;
            proc_rst_reg_2 <= proc_rst_reg_1;
            proc_rst_reg_3 <= proc_rst_reg_2;
            proc_rst_reg_4 <= proc_rst_reg_3;
            proc_rst_reg_5 <= proc_rst_reg_4;
            sync_reset     <= proc_rst_reg_5;
        end if;
    end process;

    -- Output buffer
    USER_LED_G  <= done_reg & "00" & done_reg;
end architecture;
