-- pkt_dispatcher.vhd: this component dispatches responses to the PCIe read requests
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;

entity PKT_DISPATCHER is
    generic (
        DEVICE : string := "ULTRASCALE";

        PKT_SIZE_MAX : natural := 2**16 -1;

        MFB_REGIONS     : natural := 1;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 64;
        MFB_ITEM_WIDTH  : natural := 8;

        BUFF_PTR_WIDTH : natural := 16;
        -- Mapping of BAR to a memory sector 0 all other BAR indexes go to sector 1
        WRBUFF_CHAN   : natural := 0
        );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- Input interface from header buffer
        --
        -- The values need to be set until RD_RESP_STAT_UPD asserts
        -- =========================================================================================
        BUFF_RD_REQ_ADDR : in std_logic_vector(BUFF_PTR_WIDTH -1 downto 0);
        BUFF_RD_REQ_SIZE : in std_logic_vector(BUFF_PTR_WIDTH downto 0);
        BUFF_RD_REQ_LAST : in std_logic;
        BUFF_RD_REQ_EN   : in std_logic;
        BUFF_RD_REQ_ACK  : out std_logic;

        -- =========================================================================================
        -- Reading interface to the data buffer
        -- =========================================================================================
        DATA_BUFF_RD_CHAN     : out std_logic_vector(0 downto 0);
        DATA_BUFF_RD_DATA     : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        DATA_BUFF_RD_ADDR     : out std_logic_vector(BUFF_PTR_WIDTH -1 downto 0);
        DATA_BUFF_RD_EN       : out std_logic;
        -- Multiple region support
        DATA_BUFF_RD_DATA_VLD : in  std_logic;

        -- =========================================================================================
        -- Interface to the C/S registers
        --
        -- For pointer update and incrementing of packet counter.
        -- =========================================================================================
        WRBUFF_USR_RDS_BYTES     : out std_logic_vector(log2(PKT_SIZE_MAX+1) -1 downto 0);
        -- Acknowledges the finish of a read request from data buffer
        WRBUFF_USR_RDS_INCR      : out std_logic;

        -- =========================================================================================
        -- MFB interface towards user logic 
        -- =========================================================================================
        TX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic);
end entity;

architecture FULL of PKT_DISPATCHER is
    -- =============================================================================================
    -- Dispatch FSM signals
    -- =============================================================================================
    type pkt_dispatch_state_t is (S_IDLE, S_PKT_BEGIN, S_PKT_MIDDLE);
    signal pkt_dispatch_pst : pkt_dispatch_state_t := S_IDLE;
    signal pkt_dispatch_nst : pkt_dispatch_state_t := S_IDLE;
    signal addr_cntr_pst    : unsigned(DATA_BUFF_RD_ADDR'range);
    signal addr_cntr_nst    : unsigned(DATA_BUFF_RD_ADDR'range);
    signal byte_cntr_pst    : unsigned(log2(PKT_SIZE_MAX+1) -1 downto 0);
    signal byte_cntr_nst    : unsigned(log2(PKT_SIZE_MAX+1) -1 downto 0);
    signal fst_cluster_reg  : std_logic;
    signal fst_cluster_next : std_logic;

    signal disp_fsm_mfb_sof     : std_logic_vector(TX_MFB_SOF'range);
    signal disp_fsm_mfb_eof     : std_logic_vector(TX_MFB_EOF'range);
    signal disp_fsm_mfb_eof_pos : std_logic_vector(TX_MFB_EOF_POS'range);
    signal disp_fsm_mfb_src_rdy : std_logic;
begin
    pkt_dispatch_fsm_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                pkt_dispatch_pst <= S_IDLE;
                byte_cntr_pst    <= (others => '0');
                addr_cntr_pst    <= (others => '0');
                fst_cluster_reg  <= '1';

            elsif (TX_MFB_DST_RDY = '1') then
                pkt_dispatch_pst <= pkt_dispatch_nst;
                byte_cntr_pst    <= byte_cntr_nst;
                addr_cntr_pst    <= addr_cntr_nst;
                fst_cluster_reg  <= fst_cluster_next;

            end if;
        end if;
    end process;

    pkt_dispatch_fsm_nst_logic_p : process (all) is
    begin
        pkt_dispatch_nst <= pkt_dispatch_pst;
        case pkt_dispatch_pst is
            when S_IDLE =>
                if (BUFF_RD_REQ_EN = '1') then
                    pkt_dispatch_nst <= S_PKT_BEGIN;
                end if;

            when S_PKT_BEGIN =>
                if (DATA_BUFF_RD_DATA_VLD = '1') then
                    if (byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        pkt_dispatch_nst <= S_IDLE;
                    else
                        pkt_dispatch_nst <= S_PKT_MIDDLE;
                    end if;
                end if;

            when S_PKT_MIDDLE =>
                if (byte_cntr_pst <= (TX_MFB_DATA'length /8) and DATA_BUFF_RD_DATA_VLD = '1') then
                    pkt_dispatch_nst <= S_IDLE;
                end if;
        end case;
    end process;

    pkt_dispatch_fsm_output_logic_p : process (all) is
        variable data_ptr_v    : unsigned(BUFF_PTR_WIDTH -1 downto 0);
        variable data_length_v : unsigned(BUFF_RD_REQ_SIZE'range);
    begin
        addr_cntr_nst    <= addr_cntr_pst;
        byte_cntr_nst    <= byte_cntr_pst;
        fst_cluster_next <= fst_cluster_reg;

        disp_fsm_mfb_sof     <= (others => '0');
        disp_fsm_mfb_eof     <= (others => '0');
        disp_fsm_mfb_eof_pos <= (others => '0');
        disp_fsm_mfb_src_rdy <= '0';

        DATA_BUFF_RD_ADDR <= std_logic_vector(addr_cntr_pst);
        DATA_BUFF_RD_EN   <= '0';

        WRBUFF_USR_RDS_INCR <= '0';
        BUFF_RD_REQ_ACK     <= '0';

        data_ptr_v    := unsigned(BUFF_RD_REQ_ADDR);
        -- The length of a Read response with a padding added to the beginning of the first
        -- transaction in order to be DW-aligned
        data_length_v := unsigned(BUFF_RD_REQ_SIZE);

        case pkt_dispatch_pst is
            when S_IDLE =>

                -- A valid PCIE header results in the start of a Read Completion
                if (BUFF_RD_REQ_EN = '1') then
                    -- We are interested only in a Dword aligned address
                    addr_cntr_nst <= data_ptr_v + (TX_MFB_DATA'length /8);
                    byte_cntr_nst <= resize(data_length_v, byte_cntr_nst'length);

                    DATA_BUFF_RD_ADDR <= std_logic_vector(data_ptr_v);
                    DATA_BUFF_RD_EN   <= '1';
                end if;

            when S_PKT_BEGIN =>

                DATA_BUFF_RD_EN <= TX_MFB_DST_RDY;

                if (DATA_BUFF_RD_DATA_VLD = '1') then
                    addr_cntr_nst    <= addr_cntr_pst + (TX_MFB_DATA'length /8);
                    byte_cntr_nst    <= byte_cntr_pst - (TX_MFB_DATA'length /8);
                    fst_cluster_next <= '0';

                    disp_fsm_mfb_sof(0)  <= fst_cluster_reg;
                    disp_fsm_mfb_src_rdy <= '1';

                    -- When the packet, according to its length, fits in the output word, then
                    -- assign EOF and do not count next address for the reading.
                    if (byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        fst_cluster_next     <= BUFF_RD_REQ_LAST;
                        disp_fsm_mfb_eof     <= (others => BUFF_RD_REQ_LAST);
                        -- take only the lower bits from the frame length
                        disp_fsm_mfb_eof_pos <= std_logic_vector(data_length_v(TX_MFB_EOF_POS'range) - 1);
                        WRBUFF_USR_RDS_INCR  <= TX_MFB_DST_RDY;
                        BUFF_RD_REQ_ACK      <= TX_MFB_DST_RDY;
                    end if;
                else
                    DATA_BUFF_RD_ADDR <= std_logic_vector(addr_cntr_pst - (TX_MFB_DATA'length /8));
                end if;

            when S_PKT_MIDDLE =>

                DATA_BUFF_RD_EN <= TX_MFB_DST_RDY;

                if (DATA_BUFF_RD_DATA_VLD = '1') then
                    addr_cntr_nst <= addr_cntr_pst + (TX_MFB_DATA'length /8);
                    byte_cntr_nst <= byte_cntr_pst - (TX_MFB_DATA'length /8);

                    disp_fsm_mfb_src_rdy <= '1';

                    if (byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        -- If this is the last segment to read then assert EOF with EOF_POS and
                        -- return fst_cluster_reg to 1
                        fst_cluster_next     <= BUFF_RD_REQ_LAST;
                        disp_fsm_mfb_eof     <= (others => BUFF_RD_REQ_LAST);
                        disp_fsm_mfb_eof_pos <= std_logic_vector(data_length_v(TX_MFB_EOF_POS'range) - 1);
                        WRBUFF_USR_RDS_INCR  <= TX_MFB_DST_RDY;
                        BUFF_RD_REQ_ACK      <= TX_MFB_DST_RDY;
                    end if;
                else
                    DATA_BUFF_RD_ADDR <= std_logic_vector(addr_cntr_pst - (TX_MFB_DATA'length /8));
                end if;
        end case;
    end process;

    DATA_BUFF_RD_CHAN        <= std_logic_vector(to_unsigned(WRBUFF_CHAN, DATA_BUFF_RD_CHAN'length));
    WRBUFF_USR_RDS_BYTES     <= BUFF_RD_REQ_SIZE;

    -- This process delays the set of all output MFB signals because the data come from the data
    -- buffer one clock cycle after the address and enable signal have been set.
    out_delay_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                TX_MFB_SRC_RDY <= '0';
            elsif (TX_MFB_DST_RDY = '1') then
                TX_MFB_DATA    <= DATA_BUFF_RD_DATA;
                TX_MFB_SOF     <= disp_fsm_mfb_sof;
                TX_MFB_EOF     <= disp_fsm_mfb_eof;
                TX_MFB_EOF_POS <= disp_fsm_mfb_eof_pos;
                TX_MFB_SRC_RDY <= disp_fsm_mfb_src_rdy;
            end if;
        end if;
    end process;

    TX_MFB_SOF_POS <= (others => '0');
end architecture;
