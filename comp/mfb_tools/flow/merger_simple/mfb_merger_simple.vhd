-- mfb_merger_simple.vhd: This component switches two mfb input interfaces to one mfb output.
-- Copyright (C) 2019 CESNET z. s. p. o.
-- Author(s): Daniel Kondys <xkondy00@vutbr.cz>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.type_pack.all;
use work.math_pack.all;


-- =========================================================================
--  Description
-- =========================================================================

-- This component merges two MFB streams into a single one.
-- It starts merging from Input 0.
-- After :vhdl:genconstant:`CNT_MAX <mfb_merger_simple.cnt_max>` clock cycles,
-- it tries to switch to the other input.
-- If there are no valid data on the other input, it stays on the current one
-- and waits for the same number of clock cycles before checking again.
entity MFB_MERGER_SIMPLE is
    generic (
        -- Number of Regions in a data word.
        REGIONS          : natural := 2;
        -- Number of Blocks in a Region.
        REGION_SIZE      : natural := 8;
        -- Number of Items in a Block.
        BLOCK_SIZE       : natural := 8;
        -- Number of bits in an Item.
        ITEM_WIDTH       : natural := 8;
        -- Number of bits for metadata in a single Region.
        META_WIDTH       : natural := 8;
        -- Refer to the readme.rst file for information
        MASKING_EN       : boolean := True;
        -- Maximum amount of clock periods with destination ready before it tries to switch to the other input.
        CNT_MAX          : integer := 64;
        -- Refer to the readme.rst file for information
        ARRIVAL_ORDER_EN : boolean := False
    );
    port (
        -- =====================================================================
        -- Clock and Reset
        -- =====================================================================

        CLK             : in  std_logic;
        RST             : in  std_logic;

        -- =====================================================================
        -- RX interface 0
        -- =====================================================================

        RX_MFB0_DATA    : in  std_logic_vector(REGIONS*REGION_SIZE*BLOCK_SIZE*ITEM_WIDTH-1 downto 0);
        RX_MFB0_META    : in  std_logic_vector(REGIONS*META_WIDTH-1 downto 0);
        RX_MFB0_SOF     : in  std_logic_vector(REGIONS-1 downto 0);
        RX_MFB0_SOF_POS : in  std_logic_vector(REGIONS*max(1,log2(REGION_SIZE))-1 downto 0);
        RX_MFB0_EOF     : in  std_logic_vector(REGIONS-1 downto 0);
        RX_MFB0_EOF_POS : in  std_logic_vector(REGIONS*log2(REGION_SIZE*BLOCK_SIZE)-1 downto 0);
        RX_MFB0_SRC_RDY : in  std_logic;
        RX_MFB0_DST_RDY : out std_logic;

        -- =====================================================================
        -- RX interface 1
        -- =====================================================================

        RX_MFB1_DATA    : in  std_logic_vector(REGIONS*REGION_SIZE*BLOCK_SIZE*ITEM_WIDTH-1 downto 0);
        RX_MFB1_META    : in  std_logic_vector(REGIONS*META_WIDTH-1 downto 0);
        RX_MFB1_SOF     : in  std_logic_vector(REGIONS-1 downto 0);
        RX_MFB1_SOF_POS : in  std_logic_vector(REGIONS*max(1,log2(REGION_SIZE))-1 downto 0);
        RX_MFB1_EOF     : in  std_logic_vector(REGIONS-1 downto 0);
        RX_MFB1_EOF_POS : in  std_logic_vector(REGIONS*log2(REGION_SIZE*BLOCK_SIZE)-1 downto 0);
        RX_MFB1_SRC_RDY : in  std_logic;
        RX_MFB1_DST_RDY : out std_logic;

        -- =====================================================================
        -- TX interface
        -- =====================================================================

        TX_MFB_DATA     : out std_logic_vector(REGIONS*REGION_SIZE*BLOCK_SIZE*ITEM_WIDTH-1 downto 0);
        TX_MFB_META     : out std_logic_vector(REGIONS*META_WIDTH-1 downto 0);
        TX_MFB_SOF      : out std_logic_vector(REGIONS-1 downto 0);
        TX_MFB_SOF_POS  : out std_logic_vector(REGIONS*max(1,log2(REGION_SIZE))-1 downto 0);
        TX_MFB_EOF      : out std_logic_vector(REGIONS-1 downto 0);
        TX_MFB_EOF_POS  : out std_logic_vector(REGIONS*log2(REGION_SIZE*BLOCK_SIZE)-1 downto 0);
        TX_MFB_SRC_RDY  : out std_logic;
        TX_MFB_DST_RDY  : in  std_logic
    );
end entity;

architecture BEHAVIORAL of MFB_MERGER_SIMPLE is

    constant META_SIGNAL_WIDTH  : natural := REGIONS*META_WIDTH;
    constant DATA_WIDTH         : natural := REGIONS*REGION_SIZE*BLOCK_SIZE*ITEM_WIDTH;
    constant EOF_POS_WIDTH      : natural := REGIONS*log2(REGION_SIZE*BLOCK_SIZE);
    constant SOF_POS_WIDTH      : natural := REGIONS*max(1,log2(REGION_SIZE));

    -- MFB0 input signals
    signal data0_rx_dly         : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal meta0_rx_dly         : std_logic_vector(META_SIGNAL_WIDTH-1 downto 0);
    signal sof0_rx              : std_logic_vector(REGIONS-1 downto 0);
    signal eof0_rx              : std_logic_vector(REGIONS-1 downto 0);
    signal sof0_rx_dly          : std_logic_vector(REGIONS-1 downto 0);
    signal eof0_rx_dly          : std_logic_vector(REGIONS-1 downto 0);
    signal sof_pos0_rx_dly      : std_logic_vector(SOF_POS_WIDTH-1 downto 0);
    signal eof_pos0_rx_dly      : std_logic_vector(EOF_POS_WIDTH-1 downto 0);
    signal src_rdy0_rx          : std_logic;
    signal src_rdy0_rx_dly      : std_logic;
    signal dst_rdy0_rx          : std_logic;

    -- MFB1 input signals
    signal data1_rx_dly         : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal meta1_rx_dly         : std_logic_vector(META_SIGNAL_WIDTH-1 downto 0);
    signal sof1_rx              : std_logic_vector(REGIONS-1 downto 0);
    signal eof1_rx              : std_logic_vector(REGIONS-1 downto 0);
    signal sof1_rx_dly          : std_logic_vector(REGIONS-1 downto 0);
    signal eof1_rx_dly          : std_logic_vector(REGIONS-1 downto 0);
    signal sof_pos1_rx_dly      : std_logic_vector(SOF_POS_WIDTH-1 downto 0);
    signal eof_pos1_rx_dly      : std_logic_vector(EOF_POS_WIDTH-1 downto 0);
    signal src_rdy1_rx          : std_logic;
    signal src_rdy1_rx_dly      : std_logic;
    signal dst_rdy1_rx          : std_logic;

    -- inner signals
    signal mux_addr             : std_logic;
    signal mux_addr_change_to_0 : std_logic;
    signal mux_addr_change_to_1 : std_logic;
    signal sof0_masked          : std_logic;                            -- signals whether sof0 has been masked or not
    signal sof1_masked          : std_logic;                            -- signals whether sof1 has been masked or not
    signal sof0_masked_reg      : std_logic;                            -- signal conserves last value of sof0_masked
    signal sof1_masked_reg      : std_logic;                            -- signal conserves last value of sof1_masked
    signal masked_sof0_rx_dly   : std_logic_vector(REGIONS-1 downto 0); -- sof0_rx_dly after masking process, may not be masked at all
    signal masked_sof1_rx_dly   : std_logic_vector(REGIONS-1 downto 0); -- sof1_rx_dly after masking process, may not be masked at all
    signal masked_eof0_rx_dly   : std_logic_vector(REGIONS-1 downto 0); -- eof0_rx_dly after masking process, may not be masked at all
    signal masked_eof1_rx_dly   : std_logic_vector(REGIONS-1 downto 0); -- eof1_rx_dly after masking process, may not be masked at all
    signal sof0_to_be_masked    : std_logic;                            -- signals whether sof will have to be masked or not
    signal sof1_to_be_masked    : std_logic;                            -- signals whether sof will have to be masked or not
    signal pkt_cnt              : unsigned(log2(CNT_MAX)-1 downto 0);   -- after some changes this signal does not count packets but incremets every clock cycle when dst_rdy_tx is asserted
    signal pkt_cnt_reached      : std_logic;
    signal src_not_rdy          : std_logic;                            -- is true when the counter reaches its limit and the other input has src_rdy deasserted
    signal cnt_rst              : std_logic;                            -- reset of the counter
    signal inc_pkt0             : std_logic_vector(REGIONS downto 0);   -- incomplete packet in this data word
    signal inc_pkt1             : std_logic_vector(REGIONS downto 0);   -- incomplete packet in this data word
    signal sw_right_now0        : std_logic;                            -- signals whether it is possibe to switch from one input to other input right now
    signal sw_right_now1        : std_logic;                            -- signals whether it is possibe to switch from one input to other input right now

    -- state signals for FSM
    type   state is (SEL0, SEL1, MASK_SOF0, MASK_SOF1, MASK_EOF0, MASK_EOF1);
    signal present_st           : state := SEL0;
    signal next_st              : state := SEL0;

    -- output signals
    signal data_tx              : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal meta_tx              : std_logic_vector(META_SIGNAL_WIDTH-1 downto 0);
    signal sof_tx               : std_logic_vector(REGIONS-1 downto 0);
    signal eof_tx               : std_logic_vector(REGIONS-1 downto 0);
    signal sof_pos_tx           : std_logic_vector(SOF_POS_WIDTH-1 downto 0);
    signal eof_pos_tx           : std_logic_vector(EOF_POS_WIDTH-1 downto 0);
    signal src_rdy_tx           : std_logic;
    signal dst_rdy_tx           : std_logic;
    -- source ready of the output register, taken from the mode in use
    signal src_rdy_out          : std_logic;

    -- arrival order mode: per input register stage, ownership of the output and frame tracking
    signal ao_data              : slv_array_t(1 downto 0)(DATA_WIDTH-1 downto 0);
    signal ao_meta              : slv_array_t(1 downto 0)(META_SIGNAL_WIDTH-1 downto 0);
    signal ao_sof               : slv_array_t(1 downto 0)(REGIONS-1 downto 0);
    signal ao_eof               : slv_array_t(1 downto 0)(REGIONS-1 downto 0);
    signal ao_sof_pos           : slv_array_t(1 downto 0)(SOF_POS_WIDTH-1 downto 0);
    signal ao_eof_pos           : slv_array_t(1 downto 0)(EOF_POS_WIDTH-1 downto 0);
    signal ao_vld               : std_logic_vector(1 downto 0);
    signal ao_rx_data           : slv_array_t(1 downto 0)(DATA_WIDTH-1 downto 0);
    signal ao_rx_meta           : slv_array_t(1 downto 0)(META_SIGNAL_WIDTH-1 downto 0);
    signal ao_rx_sof            : slv_array_t(1 downto 0)(REGIONS-1 downto 0);
    signal ao_rx_eof            : slv_array_t(1 downto 0)(REGIONS-1 downto 0);
    signal ao_rx_sof_pos        : slv_array_t(1 downto 0)(SOF_POS_WIDTH-1 downto 0);
    signal ao_rx_eof_pos        : slv_array_t(1 downto 0)(EOF_POS_WIDTH-1 downto 0);
    signal ao_rx_src_rdy        : std_logic_vector(1 downto 0);
    signal ao_rx_dst_rdy        : std_logic_vector(1 downto 0);
    signal ao_rx_acc            : std_logic_vector(1 downto 0);
    -- a frame of the input is open after its last accepted word
    signal ao_open              : std_logic_vector(1 downto 0);
    signal ao_open_next         : std_logic_vector(1 downto 0);
    signal ao_owner             : natural range 0 to 1;
    signal ao_other             : natural range 0 to 1;
    signal ao_owner_chg         : std_logic;
    signal ao_owner_bound       : std_logic;
    signal ao_owner_q           : natural range 0 to 1;
    signal ao_handover_open     : std_logic;
    signal ao_sel               : natural range 0 to 1;
    signal ao_sel_next          : natural range 0 to 1;
    signal ao_sel_formula       : natural range 0 to 1;
    signal ao_owner_next        : natural range 0 to 1;
    signal ao_vld_next          : std_logic_vector(1 downto 0);
    signal ao_cnt               : unsigned(max(1, log2(CNT_MAX))-1 downto 0);
    signal ao_cnt_reached       : std_logic;

    -- Whether a frame is open after a region with the given SOF and EOF, open_in telling whether one was open before it.
    function frame_open_f (sof : std_logic; eof : std_logic; open_in : std_logic) return std_logic is
    begin
        return (sof and not eof and not open_in) or (sof and eof and open_in) or (not sof and not eof and open_in);
    end function;

begin
    src_rdy0_rx <= RX_MFB0_SRC_RDY;
    src_rdy1_rx <= RX_MFB1_SRC_RDY;
    sof0_rx     <= RX_MFB0_SOF;
    sof1_rx     <= RX_MFB1_SOF;
    eof0_rx     <= RX_MFB0_EOF;
    eof1_rx     <= RX_MFB1_EOF;

    dst_rdy_tx <= TX_MFB_DST_RDY;

    reg_src_rdy0_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                src_rdy0_rx_dly <= '0';
            elsif (dst_rdy0_rx = '1') then
                src_rdy0_rx_dly <= RX_MFB0_SRC_RDY;
            end if;
        end if;
    end process;

    reg_in0_data_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (dst_rdy0_rx = '1') then
                data0_rx_dly       <= RX_MFB0_DATA;
                meta0_rx_dly       <= RX_MFB0_META;
                sof0_rx_dly        <= RX_MFB0_SOF;
                eof0_rx_dly        <= RX_MFB0_EOF;
                sof_pos0_rx_dly    <= RX_MFB0_SOF_POS;
                eof_pos0_rx_dly    <= RX_MFB0_EOF_POS;
            end if;
        end if;
    end process;

    reg_src_rdy1_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                src_rdy1_rx_dly <= '0';
            elsif (dst_rdy1_rx = '1') then
                src_rdy1_rx_dly <= RX_MFB1_SRC_RDY;
            end if;
        end if;
    end process;

    reg_in1_data_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (dst_rdy1_rx = '1') then
                data1_rx_dly    <= RX_MFB1_DATA;
                meta1_rx_dly    <= RX_MFB1_META;
                sof1_rx_dly     <= RX_MFB1_SOF;
                eof1_rx_dly     <= RX_MFB1_EOF;
                sof_pos1_rx_dly <= RX_MFB1_SOF_POS;
                eof_pos1_rx_dly <= RX_MFB1_EOF_POS;
            end if;
        end if;
    end process;

    pkt_cnt_reached <= '0' when pkt_cnt < (CNT_MAX-1) else '1';

    -- the src_not_rdy signal is used to reset the counter when pkt_cnt is equal to PKT_CNT_MAX value and the other input is not ready to send data
    src_not_rdy_p : process (all)
    begin
        case mux_addr is
            when '0' => src_not_rdy <= not src_rdy1_rx_dly;
            when '1' => src_not_rdy <= not src_rdy0_rx_dly;
            when others => null;
        end case;
    end process;

    -- packet counting process; after its value is equal to the maximum count (PKT_CNT_MAX), the counter resets
    pkt_counting_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if ((RST = '1') or (cnt_rst = '1') or (src_not_rdy = '1')) then
                pkt_cnt <= (others => '0');
            elsif ((dst_rdy_tx = '1') and (pkt_cnt_reached = '0')) then
                pkt_cnt <= pkt_cnt + 1;
            end if;
        end if;
    end process;

    -- ================================
    -- masking logic
    -- ================================
    -- this logic calculates whether or not current data word ends with an incomplete packet, according to which is decided, if masking is needed or
    -- if it is possible to switch at this moment
    inc_pkt0_g : for i in 0 to REGIONS-1 generate
        inc_pkt0(i+1) <= frame_open_f(sof0_rx(i), eof0_rx(i), inc_pkt0(i));
    end generate;

    incomplete_pkt0_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                inc_pkt0(0) <= '0';
            elsif (src_rdy0_rx = '1' and dst_rdy0_rx = '1') then
                inc_pkt0(0) <= inc_pkt0(REGIONS);
            end if;
        end if;
    end process;

    sof0_to_be_masked <= inc_pkt0(REGIONS) and (or eof0_rx) and src_rdy0_rx;
    sw_right_now0     <= (not inc_pkt0(0) and (or eof0_rx_dly) and src_rdy0_rx_dly) or (not inc_pkt0(0) and not src_rdy0_rx_dly);

    inc_pkt1_g : for i in 0 to REGIONS-1 generate
        inc_pkt1(i+1) <= frame_open_f(sof1_rx(i), eof1_rx(i), inc_pkt1(i));
    end generate;

    incomplete_pkt1_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                inc_pkt1(0) <= '0';
            elsif (src_rdy1_rx = '1' and dst_rdy1_rx = '1') then
                inc_pkt1(0) <= inc_pkt1(REGIONS);
            end if;
        end if;
    end process;

    sof1_to_be_masked <= inc_pkt1(REGIONS) and (or eof1_rx) and src_rdy1_rx;
    sw_right_now1     <= (not inc_pkt1(0) and (or eof1_rx_dly) and src_rdy1_rx_dly) or (not inc_pkt1(0) and not src_rdy1_rx_dly);

    -- ============================
    -- masking processes
    -- ============================
    -- the correct (masked or not masked) sof and eof signals, that are here generated, are later tranferred to the output according to address
    masking0_p : process (all)
    begin
        if (present_st = MASK_SOF0) then
            masked_sof0_rx_dly <= sof0_rx_dly;
            masked_eof0_rx_dly <= eof0_rx_dly;
            mask_sof0_l : for i in REGIONS-1 downto 0 loop
                if (sof0_rx_dly(i) = '1') then
                    masked_sof0_rx_dly(i) <= '0';
                    exit;
                end if;
            end loop;
        elsif (present_st = MASK_EOF0) then
            masked_sof0_rx_dly <= (others => '0');
            masked_eof0_rx_dly <= (others => '0');
            mask_eof0_l : for i in REGIONS-1 downto 0 loop
                if (sof0_rx_dly(i) = '1') then
                    masked_sof0_rx_dly(i) <= '1';
                    exit;
                end if;
            end loop;
        else
            masked_sof0_rx_dly <= sof0_rx_dly;
            masked_eof0_rx_dly <= eof0_rx_dly;
        end if;
    end process;

    masking1_p : process (all)
    begin
        if (present_st = MASK_SOF1) then
            masked_sof1_rx_dly <= sof1_rx_dly;
            masked_eof1_rx_dly <= eof1_rx_dly;
            mask_sof1_l : for i in REGIONS-1 downto 0 loop
                if (sof1_rx_dly(i) = '1') then
                    masked_sof1_rx_dly(i) <= '0';
                    exit;
                end if;
            end loop;
        elsif (present_st = MASK_EOF1) then
            masked_sof1_rx_dly <= (others => '0');
            masked_eof1_rx_dly <= (others => '0');
            mask_eof1_l : for i in REGIONS-1 downto 0 loop
                if (sof1_rx_dly(i) = '1') then
                    masked_sof1_rx_dly(i) <= '1';
                    exit;
                end if;
            end loop;
        else
            masked_sof1_rx_dly <= sof1_rx_dly;
            masked_eof1_rx_dly <= eof1_rx_dly;
        end if;
    end process;

    -- register for storing the information about the last data word from a cerain input (0 / 1), whether there was masking or not
    sof_masked_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sof0_masked_reg <= '0';
                sof1_masked_reg <= '0';
            else
                sof0_masked_reg <= sof0_masked;
                sof1_masked_reg <= sof1_masked;
            end if;
        end if;
    end process;

    -- ============================
    --    ###  FSM  ###
    -- ============================
    --! present state
    present_state_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                present_st <= SEL0;
            elsif (dst_rdy_tx = '1') then
                present_st <= next_st;
            end if;
        end if;
    end process;

    --! next state
    -- right now the address changes only when packet count is reached, but if needed, it could be made more complex
    mux_addr_change_to_0 <= pkt_cnt_reached;
    mux_addr_change_to_1 <= pkt_cnt_reached;

    next_state_p : process (all)
    begin
        case present_st is

            when SEL0 =>
                if ((mux_addr_change_to_1 = '1') and (sof1_masked = '0') and (sw_right_now0 = '1')) then
                    next_st <= SEL1;
                elsif ((mux_addr_change_to_1 = '1') and (sof0_to_be_masked = '1') and MASKING_EN) then
                    next_st <= MASK_SOF0;
                elsif ((mux_addr_change_to_1 = '1') and (sof1_masked = '1') and (sw_right_now0 = '1') and MASKING_EN) then
                    next_st <= MASK_EOF1;
                else
                    next_st <= SEL0;
                end if;

            when SEL1 =>
                if ((mux_addr_change_to_0 = '1') and (sof0_masked = '0') and (sw_right_now1 = '1')) then
                    next_st <= SEL0;
                elsif ((mux_addr_change_to_0 = '1') and (sof1_to_be_masked = '1') and MASKING_EN) then
                    next_st <= MASK_SOF1;
                elsif ((mux_addr_change_to_0 = '1') and (sof0_masked = '1') and (sw_right_now1 = '1') and MASKING_EN) then
                    next_st <= MASK_EOF0;
                else
                    next_st <= SEL1;
                end if;

            when MASK_SOF0 =>

                if (sof1_masked = '0') then
                    next_st <= SEL1;
                else
                    next_st <= MASK_EOF1;
                end if;

            when MASK_SOF1 =>
                if (sof0_masked = '0') then
                    next_st <= SEL0;
                else
                    next_st <= MASK_EOF0;
                end if;

            when MASK_EOF0 =>
                next_st <= SEL0;

            when MASK_EOF1 =>
                next_st <= SEL1;

            when others =>
                next_st <= SEL0;

        end case;
    end process;

    output_logic_p : process (all)
    begin
        -- default values of FSM
        mux_addr    <= '0';
        src_rdy_tx  <= '0';
        dst_rdy0_rx <= '0';
        dst_rdy1_rx <= '0';
        sof0_masked <= '0';
        sof1_masked <= '0';
        cnt_rst     <= '1';

        case present_st is
            -- in this state the data form input 0 are transferred to the output
            when SEL0 =>
                mux_addr    <= '0';
                src_rdy_tx  <= src_rdy0_rx_dly;
                dst_rdy0_rx <= dst_rdy_tx or not src_rdy0_rx_dly;
                dst_rdy1_rx <= not src_rdy1_rx_dly;                                                      -- or '0'
                sof0_masked <= sof0_masked_reg;
                sof1_masked <= sof1_masked_reg;
                cnt_rst     <= '0';
                if ((dst_rdy_tx = '1') and (mux_addr_change_to_1 = '1') and (sw_right_now0 = '1') ) then
                    cnt_rst <= '1';
                end if;
            -- in this state the data form input 1 are transferred to the output
            when SEL1 =>
                mux_addr    <= '1';
                src_rdy_tx  <= src_rdy1_rx_dly;
                dst_rdy0_rx <= not src_rdy0_rx_dly;                                                      -- or '0'
                dst_rdy1_rx <= dst_rdy_tx or not src_rdy1_rx_dly;
                sof0_masked <= sof0_masked_reg;
                sof1_masked <= sof1_masked_reg;
                cnt_rst     <= '0';
                if ((dst_rdy_tx = '1') and (mux_addr_change_to_0 = '1') and (sw_right_now1 = '1')) then
                    cnt_rst <= '1';
                end if;
            -- in this state the last data word is transferred form input 0 to output with the incomplete packet being masked
            when MASK_SOF0 =>
                mux_addr    <= '0';
                src_rdy_tx  <= src_rdy0_rx_dly;
                dst_rdy0_rx <= '0';
                dst_rdy1_rx <= not src_rdy1_rx_dly;                                                      -- or '0'
                sof0_masked <= '1';
                sof1_masked <= sof1_masked_reg;
                cnt_rst     <= '1';
            -- in this state the last data word is transferred form input 1 to output with the incomplete packet being masked
            when MASK_SOF1 =>
                mux_addr    <= '1';
                src_rdy_tx  <= src_rdy0_rx_dly;
                dst_rdy0_rx <= not src_rdy0_rx_dly;                                                      -- or '0'
                dst_rdy1_rx <= '0';
                sof0_masked <= sof0_masked_reg;
                sof1_masked <= '1';
                cnt_rst     <= '1';
            -- in this state the input has been switched form 1 to 0 and only the incomplete part of packet that were previously masked is sent
            when MASK_EOF0 =>
                mux_addr    <= '0';
                src_rdy_tx  <= src_rdy0_rx_dly;
                dst_rdy0_rx <= dst_rdy_tx or not src_rdy0_rx_dly;
                dst_rdy1_rx <= not src_rdy1_rx_dly;                                                      -- or '0'
                sof0_masked <= '0';
                sof1_masked <= sof1_masked_reg;
                cnt_rst     <= '1';
            -- in this state the input has been switched form 0 to 1 and only the incomplete part of packet that were previously masked is sent
            when MASK_EOF1 =>
                mux_addr    <= '1';
                src_rdy_tx  <= src_rdy1_rx_dly;
                dst_rdy0_rx <= not src_rdy0_rx_dly;                                                      -- or '0'
                dst_rdy1_rx <= dst_rdy_tx or not src_rdy1_rx_dly;
                sof0_masked <= sof0_masked_reg;
                sof1_masked <= '0';
                cnt_rst     <= '1';

        end case;
    end process;

    -- In both modes the output advances with DST_RDY only, so constant input bits fold into the output register's reset.
    reg_out_data_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (dst_rdy_tx = '1') then
                TX_MFB_DATA    <= data_tx;
                TX_MFB_META    <= meta_tx;
                TX_MFB_SOF     <= sof_tx;
                TX_MFB_EOF     <= eof_tx;
                TX_MFB_SOF_POS <= sof_pos_tx;
                TX_MFB_EOF_POS <= eof_pos_tx;
            end if;
        end if;
    end process;

    reg_out_src_rdy_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                TX_MFB_SRC_RDY <= '0';
            elsif (dst_rdy_tx = '1') then
                TX_MFB_SRC_RDY <= src_rdy_out;
            end if;
        end if;
    end process;

    -- psl default clock is rising_edge(CLK);

    output_g : if (not ARRIVAL_ORDER_EN) generate

        RX_MFB0_DST_RDY <= dst_rdy0_rx;
        RX_MFB1_DST_RDY <= dst_rdy1_rx;

        -- the actual switching between inputs 0 and 1 according to the mux address
        data_tx    <= data0_rx_dly when mux_addr = '0' else
                      data1_rx_dly;

        meta_tx    <= meta0_rx_dly when mux_addr = '0' else
                      meta1_rx_dly;

        sof_tx     <= masked_sof0_rx_dly when mux_addr = '0' else
                      masked_sof1_rx_dly;

        eof_tx     <= masked_eof0_rx_dly when mux_addr = '0' else
                      masked_eof1_rx_dly;

        sof_pos_tx <= sof_pos0_rx_dly when mux_addr = '0' else
                      sof_pos1_rx_dly;

        eof_pos_tx <= eof_pos0_rx_dly when mux_addr = '0' else
                      eof_pos1_rx_dly;

        src_rdy_out <= src_rdy_tx;

    else generate

        ao_rx_data    <= (RX_MFB1_DATA, RX_MFB0_DATA);
        ao_rx_meta    <= (RX_MFB1_META, RX_MFB0_META);
        ao_rx_sof     <= (RX_MFB1_SOF, RX_MFB0_SOF);
        ao_rx_eof     <= (RX_MFB1_EOF, RX_MFB0_EOF);
        ao_rx_sof_pos <= (RX_MFB1_SOF_POS, RX_MFB0_SOF_POS);
        ao_rx_eof_pos <= (RX_MFB1_EOF_POS, RX_MFB0_EOF_POS);
        ao_rx_src_rdy <= RX_MFB1_SRC_RDY & RX_MFB0_SRC_RDY;

        RX_MFB0_DST_RDY <= ao_rx_dst_rdy(0);
        RX_MFB1_DST_RDY <= ao_rx_dst_rdy(1);

        ao_other    <= 1 - ao_owner;

        -- The register of the input that lost ownership holds words older than any of the owner's. The selection is
        -- registered from the next state, so the data multiplexer has a single select input.
        ao_sel_formula <= ao_other when (ao_vld(ao_other) = '1') else ao_owner;
        ao_owner_next  <= ao_other when (ao_owner_chg = '1') else ao_owner;
        ao_sel_next    <= 1 - ao_owner_next when (ao_vld_next(1 - ao_owner_next) = '1') else ao_owner_next;

        ao_sel_reg_p : process (CLK)
        begin
            if (rising_edge(CLK)) then
                ao_sel <= ao_sel_next;
                if (RST = '1') then
                    ao_sel <= 0;
                end if;
            end if;
        end process;

        ao_dst_rdy_g : for i in 0 to 1 generate
            ao_rx_dst_rdy(i) <= '1' when (ao_owner = i and (ao_vld(i) = '0' or (ao_sel = i and dst_rdy_tx = '1'))) else '0';
            ao_rx_acc(i)     <= ao_rx_src_rdy(i) and ao_rx_dst_rdy(i);

            ao_open_next_p : process (all)
                variable open_v : std_logic;
            begin
                open_v := ao_open(i);
                for r in 0 to REGIONS-1 loop
                    open_v := frame_open_f(ao_rx_sof(i)(r), ao_rx_eof(i)(r), open_v);
                end loop;
                ao_open_next(i) <= open_v;
            end process;

            ao_vld_next(i) <= '0' when (RST = '1') else
                              '1' when (ao_rx_acc(i) = '1') else
                              '0' when (ao_sel = i and dst_rdy_tx = '1') else
                              ao_vld(i);

            ao_in_reg_p : process (CLK)
            begin
                if (rising_edge(CLK)) then
                    if (ao_rx_acc(i) = '1') then
                        ao_data(i)    <= ao_rx_data(i);
                        ao_meta(i)    <= ao_rx_meta(i);
                        ao_sof(i)     <= ao_rx_sof(i);
                        ao_eof(i)     <= ao_rx_eof(i);
                        ao_sof_pos(i) <= ao_rx_sof_pos(i);
                        ao_eof_pos(i) <= ao_rx_eof_pos(i);
                        ao_open(i)    <= ao_open_next(i);
                    end if;
                    ao_vld(i) <= ao_vld_next(i);
                    if (RST = '1') then
                        ao_open(i) <= '0';
                    end if;
                end if;
            end process;
        end generate;

        -- Ownership passes only after a word that leaves no frame of the owner open and once the old owner's
        -- register is empty, so the output order is the acceptance order and no word is ever split.
        ao_owner_bound <= not ao_open_next(ao_owner) when (ao_rx_acc(ao_owner) = '1') else not ao_open(ao_owner);
        ao_owner_chg   <= ao_owner_bound and ao_rx_src_rdy(ao_other) and not ao_vld(ao_other) and
                          (ao_cnt_reached or not ao_rx_src_rdy(ao_owner));

        ao_cnt_reached <= '0' when (ao_cnt < CNT_MAX-1) else '1';

        ao_owner_p : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (ao_owner_chg = '1') then
                    ao_owner <= ao_other;
                    ao_cnt   <= (others => '0');
                elsif (TX_MFB_DST_RDY = '1' and ao_rx_src_rdy(ao_other) = '1' and ao_cnt_reached = '0') then
                    ao_cnt <= ao_cnt + 1;
                end if;
                if (RST = '1') then
                    ao_owner <= 0;
                    ao_cnt   <= (others => '0');
                end if;
            end if;
        end process;

        data_tx     <= ao_data(ao_sel);
        meta_tx     <= ao_meta(ao_sel);
        sof_tx      <= ao_sof(ao_sel);
        eof_tx      <= ao_eof(ao_sel);
        sof_pos_tx  <= ao_sof_pos(ao_sel);
        eof_pos_tx  <= ao_eof_pos(ao_sel);
        src_rdy_out <= ao_vld(ao_sel);

        -- psl assert_ao_sel_oldest :
        --      assert always (ao_sel = ao_sel_formula) abort (RST)
        --      report "MFB_MERGER_SIMPLE: the output does not take the oldest registered word!";

        -- psl assert_ao_one_input_accepted :
        --      assert always (ao_rx_dst_rdy /= "11") abort (RST)
        --      report "MFB_MERGER_SIMPLE: both inputs ready in the arrival order mode!";

        ao_owner_q_p : process (CLK)
        begin
            if (rising_edge(CLK)) then
                ao_owner_q <= ao_owner;
            end if;
        end process;

        ao_handover_open <= '1' when (ao_owner /= ao_owner_q and ao_open(ao_owner_q) = '1') else '0';

        -- psl assert_ao_handover_at_frame_end :
        --      assert always (ao_handover_open = '0') abort (RST)
        --      report "MFB_MERGER_SIMPLE: ownership passed while a frame of the previous owner was open!";

    end generate;

end architecture;
