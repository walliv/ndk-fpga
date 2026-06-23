-- h2c_hyperion_data_shifter.vhd: shifter of data that realignes input packet based on the input
-- address. This is need for the AXI3 interface of the HBM
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.type_pack.all;
use work.math_pack.all;

entity H2C_HYPERION_DATA_SHIFTER is
    generic (
        MFB_REGIONS     : integer := 1;
        MFB_REGION_SIZE : integer := 1;
        MFB_BLOCK_SIZE  : integer := 8;
        MFB_ITEM_WIDTH  : integer := 32
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;
        -- =========================================================================================
        RX_MFB_META_TR_LEN : in std_logic_vector(13 -1 downto 0);
        RX_MFB_META_BE     : in std_logic_vector((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto 0);
        RX_MFB_META_ADDR   : in std_logic_vector(64 -1 downto 0);

        RX_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RX_MFB_SOF     : in  std_logic;
        RX_MFB_EOF     : in  std_logic;
        RX_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        RX_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;
        -- =========================================================================================
        TX_MFB_META_TR_LEN : out std_logic_vector(13 -1 downto 0);
        TX_MFB_META_BE     : out std_logic_vector((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto 0);
        TX_MFB_META_ADDR   : out std_logic_vector(64 -1 downto 0);

        TX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        TX_MFB_SOF     : out std_logic;
        TX_MFB_EOF     : out std_logic;
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of H2C_HYPERION_DATA_SHIFTER is
    constant BLOCKS_TO_SHIFT : natural := 2*MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE;

    --=============================================================================================================
    -- Skid buffer signals
    --=============================================================================================================
    signal sb_rx_meta_tr_len : slv_array_t(1 downto 0)(RX_MFB_META_TR_LEN'range);
    signal sb_rx_meta_be     : slv_array_t(1 downto 0)(RX_MFB_META_BE'range);
    signal sb_rx_meta_addr   : slv_array_t(1 downto 0)(RX_MFB_META_ADDR'range);
    signal sb_rx_data    : slv_array_t(1 downto 0)(RX_MFB_DATA'range);
    signal sb_rx_sof     : std_logic_vector(1 downto 0);
    signal sb_rx_eof     : std_logic_vector(1 downto 0);
    signal sb_rx_eof_pos : slv_array_t(1 downto 0)(RX_MFB_EOF_POS'range);
    signal sb_rx_src_rdy : std_logic_vector(1 downto 0);

    signal sb_tx_meta_tr_len : std_logic_vector(TX_MFB_META_TR_LEN'range);
    signal sb_tx_meta_be     : std_logic_vector(TX_MFB_META_BE'range);
    signal sb_tx_meta_addr   : std_logic_vector(TX_MFB_META_ADDR'range);
    signal sb_tx_data    : std_logic_vector(RX_MFB_DATA'range);
    signal sb_tx_sof     : std_logic;
    signal sb_tx_eof     : std_logic;
    signal sb_tx_eof_pos : std_logic_vector(RX_MFB_EOF_POS'range);
    signal sb_tx_src_rdy : std_logic;
    signal sb_tx_dst_rdy : std_logic;

    signal sb_mfb_eof_succ     : std_logic;
    signal sb_mfb_eof_pos_succ : std_logic_vector(RX_MFB_EOF_POS'range);
    signal sb_buff_full        : std_logic;
    signal sb_1buff_tx_dst_rdy : std_logic;

    --=============================================================================================================
    -- Shifting FSM signals
    --=============================================================================================================
    type   pkt_shift_state_type is (PKT_START_DETECT, PKT_NO_SHIFT, PKT_MIDDLE, PKT_END, PKT_START_BREAK);
    signal sh_fsm_pst : pkt_shift_state_type := PKT_START_DETECT;
    signal sh_fsm_nst : pkt_shift_state_type := PKT_START_DETECT;

    signal sh_fsm_tx_sof     : std_logic;
    signal sh_fsm_tx_eof     : std_logic;
    signal sh_fsm_tx_src_rdy : std_logic;
    signal sh_fsm_rx_dst_rdy : std_logic;

    signal shift_sel         : unsigned(log2(BLOCKS_TO_SHIFT) -1 downto 0);
    signal blk_to_shift_reg  : unsigned(log2(BLOCKS_TO_SHIFT) -1 downto 0);
    signal blk_to_shift_next : unsigned(log2(BLOCKS_TO_SHIFT) -1 downto 0);

    signal bshifter_data_out : std_logic_vector(2*TX_MFB_DATA'length - 1 downto 0);
    signal bshifter_be_out   : std_logic_vector(2*(TX_MFB_DATA'length/8) - 1 downto 0);

    signal low_mask_en  : std_logic;
    signal low_mask_idx : unsigned(log2(BLOCKS_TO_SHIFT) -1 downto 0);
    signal high_mask_en  : std_logic;
    signal high_mask_idx : unsigned(log2(BLOCKS_TO_SHIFT) -1 downto 0);
    signal be_out   : slv_array_t(BLOCKS_TO_SHIFT/2 -1 downto 0)(MFB_ITEM_WIDTH/8 -1 downto 0);
    signal be_out_masked : slv_array_t(BLOCKS_TO_SHIFT/2 -1 downto 0)(MFB_ITEM_WIDTH/8 -1 downto 0);
begin
    assert (MFB_REGIONS = 1 and MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 8 and MFB_ITEM_WIDTH = 32)
        report "H2C_HYPERION_DATA_SHIFTER: The architecture is not implemented for the specified generic parameters yet."
        severity FAILURE;

    --=============================================================================================================
    -- SKID BUFFER
    --=============================================================================================================
    -- handles the reception of packets into two registers from which the
    -- barrel shifter is connected
    skid_buffer_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sb_rx_sof     <= (others => '0');
                sb_rx_eof     <= (others => '0');
                sb_rx_src_rdy <= (others => '0');
            else
                if (RX_MFB_DST_RDY = '1') then
                    sb_rx_meta_tr_len(0) <= RX_MFB_META_TR_LEN;
                    sb_rx_meta_be(0)     <= RX_MFB_META_BE;
                    sb_rx_meta_addr(0)   <= RX_MFB_META_ADDR;
                    sb_rx_data(0)    <= RX_MFB_DATA;
                    sb_rx_sof(0)     <= RX_MFB_SOF;
                    sb_rx_eof(0)     <= RX_MFB_EOF;
                    sb_rx_eof_pos(0) <= RX_MFB_EOF_POS;
                    sb_rx_src_rdy(0) <= RX_MFB_SRC_RDY;
                end if;

                if (sb_1buff_tx_dst_rdy = '1') then
                    sb_rx_meta_tr_len(1) <= sb_rx_meta_tr_len(0);
                    sb_rx_meta_be(1)     <= sb_rx_meta_be(0);
                    sb_rx_meta_addr(1)   <= sb_rx_meta_addr(0);
                    sb_rx_data(1)    <= sb_rx_data(0);
                    sb_rx_sof(1)     <= sb_rx_sof(0);
                    sb_rx_eof(1)     <= sb_rx_eof(0);
                    sb_rx_eof_pos(1) <= sb_rx_eof_pos(0);
                    sb_rx_src_rdy(1) <= sb_rx_src_rdy(0);
                end if;
            end if;
        end if;
    end process;

    -- connection of DST_RDY signal from the second buffer of the skid buffer
    sb_1buff_tx_dst_rdy <= sb_tx_dst_rdy or (not sb_rx_src_rdy(1));
    -- connection of the buffers DST_RDY signal to the previous component, that is packet divider
    RX_MFB_DST_RDY      <= sb_1buff_tx_dst_rdy or (not sb_rx_src_rdy(0));

    --=============================================================================================================
    -- Simple interconnect between Skid buffer and Shifting FSM
    --=============================================================================================================
    sb_tx_meta_tr_len <= sb_rx_meta_tr_len(1);
    sb_tx_meta_be     <= sb_rx_meta_be(1);
    sb_tx_meta_addr   <= sb_rx_meta_addr(1);

    sb_tx_data    <= sb_rx_data(1);
    sb_tx_sof     <= sb_rx_sof(1);
    sb_tx_eof     <= sb_rx_eof(1);
    sb_tx_eof_pos <= sb_rx_eof_pos(1);
    sb_tx_src_rdy <= sb_rx_src_rdy(1);
    sb_tx_dst_rdy <= sh_fsm_rx_dst_rdy;

    -- there is a need for these two signals because I have to know that EOF is coming in advance
    sb_mfb_eof_succ     <= sb_rx_eof(0);
    sb_mfb_eof_pos_succ <= sb_rx_eof_pos(0);
    sb_buff_full        <= and sb_rx_src_rdy;

    --=============================================================================================================
    -- SHIFTING FSM WITH BARREL SHIFTER
    --=============================================================================================================
    fsm_pst_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sh_fsm_pst        <= PKT_START_DETECT;
                blk_to_shift_reg  <= (others => '0');
            elsif (TX_MFB_DST_RDY = '1') then
                sh_fsm_pst        <= sh_fsm_nst;
                blk_to_shift_reg  <= blk_to_shift_next;
            end if;
        end if;
    end process;

    fsm_nst_logic_p : process (all)
        -- I declared tese to variables to make some calculation in this process more readable
        variable sof_pos_un     : unsigned(log2(BLOCKS_TO_SHIFT) -2 downto 0);
        variable eof_blk_pos    : unsigned(log2(BLOCKS_TO_SHIFT) -2 downto 0);
        variable shift_sel_int  : unsigned(shift_sel'range);
        variable new_eof_pos_v  : unsigned(shift_sel'range);
    begin
        sh_fsm_nst <= sh_fsm_pst;

        sof_pos_un  := to_unsigned(4, log2(BLOCKS_TO_SHIFT)-1);
        -- select only EOF's block position from the next
        eof_blk_pos := unsigned(sb_mfb_eof_pos_succ(sb_mfb_eof_pos_succ'high downto (sb_mfb_eof_pos_succ'high - log2(BLOCKS_TO_SHIFT) + 2)));

        case sh_fsm_pst is
            -- the FSM wait for the detection of the SOF_POS in the Skid buffer
            when PKT_START_DETECT =>

                shift_sel_int := ('0' & sof_pos_un) - unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2));

                if (sb_tx_src_rdy = '1' and sb_tx_sof = '1') then
                    -- the packet needs to be shifted to the upper index block than in which it currently occurs.
                    -- The state machine stops the transmission because some data in the current word are not send
                    -- and need to be in the next cycle.
                    if (sof_pos_un < unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2))) then

                        new_eof_pos_v := resize(unsigned(sb_tx_eof_pos), shift_sel'length) - shift_sel_int;

                        -- There is an EOF in the current word but the shift does not shift it out of the word
                        if (sb_tx_eof = '1' and new_eof_pos_v <= 7) then
                            sh_fsm_nst <= PKT_START_DETECT;
                        else
                            sh_fsm_nst <= PKT_START_BREAK;
                        end if;

                    -- no shift of the packet is needed, it already begins on the desired position
                    elsif (sof_pos_un = unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2))) then
                        -- also the EOF occurs in the current word, no transition to the next state is needed
                        if (sb_tx_eof = '1') then
                            sh_fsm_nst <= PKT_START_DETECT;

                        -- the next state consideres the situation when the packet ends or continues in the next
                        -- word but the waiting for this is controlled in the PKT_NO_SHIFT state so I dont have to
                        -- control if the Skid buffer is full
                        else
                            sh_fsm_nst <= PKT_NO_SHIFT;
                        end if;

                    -- the packet needs to be shifted to the lower index block than in which it currently occurs
                    else
                        if (sb_buff_full = '1' and sb_tx_eof = '0') then
                            -- In case EOF accurs in the next word: when packet is shifted, its whole content
                            -- occurs in the current word and no transition is needed
                            if (sb_mfb_eof_succ = '1' and eof_blk_pos < shift_sel_int) then
                                sh_fsm_nst <= PKT_START_DETECT;

                            -- In case EOF occurs in the next word: When packet is shifted, its whole content does
                            -- not occur in the current word so the additional processing of the EOF is needed.
                            elsif (sb_mfb_eof_succ = '1' and eof_blk_pos >= shift_sel_int) then
                                sh_fsm_nst <= PKT_END;
                            else
                                sh_fsm_nst <= PKT_MIDDLE;
                            end if;
                        end if;
                    end if;
                end if;

            when PKT_START_BREAK =>

                if (sb_buff_full = '1' and sb_tx_eof = '0') then
                    if (sb_mfb_eof_succ = '1') then
                        if (eof_blk_pos < blk_to_shift_reg((blk_to_shift_reg'high - 1) downto 0)) then
                            sh_fsm_nst <= PKT_START_DETECT;
                        else
                            sh_fsm_nst <= PKT_END;
                        end if;
                    else
                        sh_fsm_nst <= PKT_MIDDLE;
                    end if;
                elsif (sb_tx_eof = '1') then
                    sh_fsm_nst <= PKT_START_DETECT;
                end if;

            when PKT_NO_SHIFT =>

                if (sb_tx_eof = '1' and sb_tx_src_rdy = '1') then
                    sh_fsm_nst <= PKT_START_DETECT;
                end if;

            when PKT_MIDDLE =>

                if (sb_buff_full = '1' and sb_mfb_eof_succ = '1') then
                    if (eof_blk_pos < blk_to_shift_reg((blk_to_shift_reg'high - 1) downto 0)) then
                        sh_fsm_nst <= PKT_START_DETECT;
                    else
                        sh_fsm_nst <= PKT_END;
                    end if;
                end if;

            when PKT_END =>
                sh_fsm_nst <= PKT_START_DETECT;
        end case;
    end process;

    fsm_output_logic_p : process (all)
        variable sof_pos_un  : unsigned(log2(BLOCKS_TO_SHIFT) -2 downto 0);
        variable eof_blk_pos : unsigned(log2(BLOCKS_TO_SHIFT) -2 downto 0);
        variable shift_sel_int  : unsigned(shift_sel'range);
        variable new_eof_pos_v  : unsigned(shift_sel'range);
    begin
        sh_fsm_tx_sof     <= '0';
        sh_fsm_tx_eof     <= '0';
        sh_fsm_tx_src_rdy <= '0';
        sh_fsm_rx_dst_rdy <= '0';
        low_mask_en           <= '0';
        low_mask_idx          <= (others => '0');
        high_mask_en           <= '0';
        high_mask_idx          <= (others => '0');

        shift_sel           <= (others => '0');
        blk_to_shift_next   <= blk_to_shift_reg;
        sof_pos_un          := to_unsigned(4, log2(BLOCKS_TO_SHIFT)-1);

        case sh_fsm_pst is
            when PKT_START_DETECT =>

                shift_sel_int     := ('0' & sof_pos_un) - unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2));
                shift_sel         <= shift_sel_int;
                sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                if (sb_tx_src_rdy = '1' and sb_tx_sof = '1') then
                    -- packet can be sent to the output but the Skid buffer needs to be stopped because there still
                    -- some beginning of the packet left
                    if (sof_pos_un < unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2))) then
                        sh_fsm_tx_sof     <= '1';
                        sh_fsm_tx_src_rdy <= '1';
                        sh_fsm_rx_dst_rdy <= '0';

                        low_mask_en  <= '1';
                        low_mask_idx <= '0' & unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2)) - sof_pos_un - 1;
                        blk_to_shift_next <= shift_sel_int + BLOCKS_TO_SHIFT/2;

                        new_eof_pos_v := resize(unsigned(sb_tx_eof_pos), shift_sel'length) - shift_sel_int;
                        if (sb_tx_eof = '1' and new_eof_pos_v <= 7) then
                            sh_fsm_tx_eof <= '1';
                            sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;
                        end if;

                    -- packet is free to be sent to the output without stopping the Skid buffer
                    elsif (sof_pos_un = unsigned(sb_tx_meta_addr(log2(BLOCKS_TO_SHIFT)-2+2 downto 2))) then
                        sh_fsm_tx_sof     <= '1';
                        sh_fsm_tx_src_rdy <= '1';

                        -- if FSM is ready to send data then it should respect the TX_MFB_DST_RDY signal this
                        -- behavior is maintained throughoutthe whole design
                        sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;
                        blk_to_shift_next <= (others => '0');

                        if (sb_tx_eof = '1') then
                            sh_fsm_tx_eof <= '1';
                        end if;

                    -- packet cannot be sent to the output until two valid words occur in the Skid buffer. If
                    -- second buffered word is invalid, the data shift causes the invalid data to occur on the
                    -- output. These data cannot be considered as valid.
                    else
                        sh_fsm_rx_dst_rdy <= '0';
                        blk_to_shift_next <= shift_sel_int;

                        if (sb_buff_full = '1' and sb_tx_eof = '0') then
                            sh_fsm_tx_sof     <= '1';
                            sh_fsm_tx_src_rdy <= '1';
                            sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                            eof_blk_pos := unsigned(sb_mfb_eof_pos_succ(sb_mfb_eof_pos_succ'high downto (sb_mfb_eof_pos_succ'high - log2(BLOCKS_TO_SHIFT) + 2)));

                            if (sb_mfb_eof_succ = '1' and eof_blk_pos < shift_sel_int) then
                                sh_fsm_tx_eof <= '1';
                            end if;
                        elsif (sb_tx_eof = '1') then
                            sh_fsm_tx_sof     <= '1';
                            sh_fsm_tx_eof     <= '1';
                            sh_fsm_tx_src_rdy <= '1';
                            sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                            eof_blk_pos := unsigned(sb_tx_eof_pos(sb_mfb_eof_pos_succ'high downto (sb_mfb_eof_pos_succ'high - log2(BLOCKS_TO_SHIFT) + 2)));

                            high_mask_en  <= '1';
                            high_mask_idx <= ('0' & eof_blk_pos) - unsigned(shift_sel_int) + 1;
                        end if;
                    end if;
                end if;

            -- Although the SOF has already been propagated to the outpu, there are still some unread data in
            -- a current word
            when PKT_START_BREAK =>
                shift_sel  <= blk_to_shift_reg;

                sh_fsm_rx_dst_rdy <= '0';

                if (sb_buff_full = '1' and sb_tx_eof = '0') then
                    sh_fsm_tx_src_rdy <= '1';
                    sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                    eof_blk_pos := unsigned(sb_mfb_eof_pos_succ(sb_mfb_eof_pos_succ'high downto (sb_mfb_eof_pos_succ'high - log2(BLOCKS_TO_SHIFT) + 2)));
                    if (sb_mfb_eof_succ = '1' and eof_blk_pos < blk_to_shift_reg((blk_to_shift_reg'high - 1) downto 0)) then
                        sh_fsm_tx_eof <= '1';
                    end if;

                elsif (sb_tx_eof = '1') then
                    sh_fsm_tx_eof     <= '1';
                    sh_fsm_tx_src_rdy <= '1';
                    sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                    high_mask_en  <= '1';
                    high_mask_idx <= ('0' & unsigned(sb_tx_eof_pos)) - unsigned(blk_to_shift_reg) + 1;
                end if;

            -- special state where no shift of output data is needed and they are simply passed to the output
            when PKT_NO_SHIFT =>
                sh_fsm_tx_src_rdy <= sb_tx_src_rdy;
                sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                -- when EOF occurs then move to the beginning state
                if (sb_tx_eof = '1' and sb_tx_src_rdy = '1') then
                    sh_fsm_tx_eof <= '1';
                end if;

            -- state that is most used which is in the middle of a packet
            when PKT_MIDDLE =>
                -- shift select is calculated using the SOF_VALUE stored from time when packet arrived
                shift_sel  <= blk_to_shift_reg;

                sh_fsm_rx_dst_rdy <= '0';

                if (sb_buff_full = '1') then
                    -- this variable points to a block in which an EOF of a packet is located
                    eof_blk_pos := unsigned(sb_mfb_eof_pos_succ(sb_mfb_eof_pos_succ'high downto (sb_mfb_eof_pos_succ'high - log2(BLOCKS_TO_SHIFT) + 2)));

                    -- one exception to the behavior in the middle of a packet is the situation when the EOF of the
                    -- packet occurs and current shift causes its EOF to appear in the current word
                    if (sb_mfb_eof_succ = '1' and (eof_blk_pos < blk_to_shift_reg((blk_to_shift_reg'high - 1) downto 0))) then
                        sh_fsm_tx_eof <= '1';
                    end if;

                    sh_fsm_tx_src_rdy <= '1';
                    sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;
                end if;

            -- sending the rest of a packet ending
            when PKT_END =>
                shift_sel         <= blk_to_shift_reg;
                sh_fsm_tx_eof     <= '1';
                sh_fsm_tx_src_rdy <= '1';
                sh_fsm_rx_dst_rdy <= TX_MFB_DST_RDY;

                eof_blk_pos := unsigned(sb_tx_eof_pos(sb_mfb_eof_pos_succ'high downto (sb_mfb_eof_pos_succ'high - log2(BLOCKS_TO_SHIFT) + 2)));

                high_mask_en  <= '1';
                high_mask_idx <= ('0' & eof_blk_pos) - unsigned(blk_to_shift_reg) + 1;
        end case;
    end process;

    byte_en_shifter_i : entity work.BARREL_SHIFTER_GEN
    generic map (
        BLOCKS     => 2*(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE),
        BLOCK_SIZE => MFB_ITEM_WIDTH/8,
        SHIFT_LEFT => FALSE
    )
    port map (
        DATA_IN  => sb_rx_meta_be(0) & sb_rx_meta_be(1),
        DATA_OUT => bshifter_be_out,
        SEL      => std_logic_vector(shift_sel)
    );

    -- The shifting is done by DWords
    data_shifter_i : entity work.BARREL_SHIFTER_GEN
    generic map (
        BLOCKS     => 2*(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE),
        BLOCK_SIZE => MFB_ITEM_WIDTH,
        SHIFT_LEFT => FALSE
    )
    port map (
        DATA_IN  => sb_rx_data(0) & sb_rx_data(1),
        DATA_OUT => bshifter_data_out,
        SEL      => std_logic_vector(shift_sel)
    );

    -- =============================================================================================
    -- Masking of byte enable
    --
    -- This is relevant when the data need to be shifted to upper blocks. When the shifting of the
    -- barrel shifter takes place in this case, the data are actually rotated and whe the second
    -- word contains valid DWords on its last blocks, these would appear in the first word.
    -- =============================================================================================
    be_out <= slv_array_deser(bshifter_be_out(TX_MFB_META_BE'range), BLOCKS_TO_SHIFT/2);

    be_mask_g : for blk_idx in 0 to (BLOCKS_TO_SHIFT/2 -1) generate
        be_mask_assign_p : process(all)
        begin
            if ((low_mask_en = '1' and low_mask_idx >= blk_idx) or (high_mask_en = '1' and high_mask_idx <= blk_idx)) then
                be_out_masked(blk_idx) <= (others => '0');
            else
                be_out_masked(blk_idx) <= be_out(blk_idx);
            end if;
        end process;
    end generate;

    -- =============================================================================================
    -- Output register
    -- =============================================================================================
    output_register_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                TX_MFB_SRC_RDY <= '0';

            elsif (TX_MFB_DST_RDY = '1') then
                TX_MFB_META_TR_LEN <= sb_tx_meta_tr_len;
                TX_MFB_META_BE     <= slv_array_ser(be_out_masked);
                TX_MFB_META_ADDR   <= sb_tx_meta_addr;

                TX_MFB_DATA    <= bshifter_data_out(TX_MFB_DATA'range);
                TX_MFB_SOF     <= sh_fsm_tx_sof;
                TX_MFB_EOF     <= sh_fsm_tx_eof;
                TX_MFB_SRC_RDY <= sh_fsm_tx_src_rdy;
            end if;
        end if;
    end process;
end architecture;
