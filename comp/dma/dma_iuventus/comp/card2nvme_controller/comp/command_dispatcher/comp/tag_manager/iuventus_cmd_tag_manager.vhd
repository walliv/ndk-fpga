-- iuventus_cmd_tag_manager.vhd: manager of tags for for the submitted commands to the Submission
-- Queue
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;

-- Note:

entity IUVENTUS_CMD_TAG_MANAGER is

    generic (
        DEVICE      : string   := "ULTRASCALE";
        QUEUE_DEPTH : positive := 2048
        );

    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        INIT_DONE : out std_logic;

        TAG_IN_DATA    : in  std_logic_vector(15 downto 0);
        TAG_IN_SRC_RDY : in  std_logic;

        TAG_OUT_DATA    : out std_logic_vector(15 downto 0);
        TAG_OUT_SRC_RDY : out std_logic;
        TAG_OUT_DST_RDY : in  std_logic;

        TAG_FIFO_STATUS : out std_logic_vector(11 downto 0)
        );

end entity;

architecture FULL of IUVENTUS_CMD_TAG_MANAGER is
    signal tag_fifo_di    : std_logic_vector(15 downto 0);
    signal tag_fifo_wr    : std_logic;
    signal tag_fifo_full  : std_logic;
    signal tag_fifo_rd    : std_logic;
    signal tag_fifo_empty : std_logic;

    signal fifo_init_done : std_logic;

    type init_fsm_state_t is (S_INIT_STAGE, S_OPERATING);
    signal init_fsm_pst : init_fsm_state_t := S_INIT_STAGE;
    signal init_fsm_nst : init_fsm_state_t := S_INIT_STAGE;

    signal tag_counter_pst : unsigned(15 downto 0);
    signal tag_counter_nst : unsigned(15 downto 0);

    signal tag_fifo_status_int : std_logic_vector(log2(QUEUE_DEPTH) downto 0);
begin

    data_overwrite_check_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '0') then
                assert (not(tag_fifo_wr = '1' and tag_fifo_full = '1'))
                    report "IUVENTUS_CMD_TAG_MANAGER: Write occured on a FULL fifo!"
                    severity FAILURE;
            end if;
        end if;
    end process;

    init_fsm_state_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                init_fsm_pst    <= S_INIT_STAGE;
                tag_counter_pst <= (others => '0');
            else
                init_fsm_pst    <= init_fsm_nst;
                tag_counter_pst <= tag_counter_nst;
            end if;
        end if;
    end process;

    init_fsm_nst_logic_p : process (all) is
    begin
        init_fsm_nst    <= init_fsm_pst;
        tag_counter_nst <= tag_counter_pst;
        fifo_init_done  <= '0';
        tag_fifo_di     <= (others => '0');
        tag_fifo_wr     <= '0';

        case init_fsm_pst is
            when S_INIT_STAGE =>
                tag_counter_nst <= tag_counter_pst + 1;
                tag_fifo_di     <= std_logic_vector(tag_counter_pst);
                tag_fifo_wr     <= '1';

                -- Switch to the next state when the FIFO has been filled
                if (tag_counter_pst = to_unsigned(QUEUE_DEPTH-1, tag_counter_pst'length)) then
                    init_fsm_nst <= S_OPERATING;
                end if;

            when S_OPERATING =>
                fifo_init_done  <= '1';
                tag_fifo_di     <= TAG_IN_DATA;
                tag_fifo_wr     <= TAG_IN_SRC_RDY;
                tag_counter_nst <= (others => '0');
        end case;
    end process;

    tag_fifo_i : entity work.FIFOX
        generic map (
            DATA_WIDTH          => 16,
            ITEMS               => QUEUE_DEPTH,
            RAM_TYPE            => "BRAM",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 0,
            ALMOST_EMPTY_OFFSET => 0,
            FAKE_FIFO           => FALSE)
        port map (
            CLK   => CLK,
            RESET => RESET,

            DI   => tag_fifo_di,
            WR   => tag_fifo_wr,
            FULL => tag_fifo_full,

            AFULL  => open,
            STATUS => tag_fifo_status_int,

            DO    => TAG_OUT_DATA,
            RD    => tag_fifo_rd,
            EMPTY => tag_fifo_empty,

            AEMPTY => open);

    tag_fifo_rd     <= TAG_OUT_DST_RDY and (not tag_fifo_empty);
    TAG_OUT_SRC_RDY <= (not tag_fifo_empty) and fifo_init_done;
    INIT_DONE       <= fifo_init_done;

    TAG_FIFO_STATUS <= std_logic_vector(resize(unsigned(tag_fifo_status_int), TAG_FIFO_STATUS'length));
end architecture;
