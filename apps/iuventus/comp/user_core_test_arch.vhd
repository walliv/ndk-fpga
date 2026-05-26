-- user_core_test_arch.vhd: Testing architecture of the user core
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

architecture TEST of USER_CORE is
    constant ADDR_LENGTH    : natural := 6;
    constant MI_SPLIT_PORTS : natural := 5;
    constant MI_SPLIT_BASES : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH-1 downto 0) := (
        0 => X"00000000",       -- Control and Status Registers
        1 => X"00000100",       -- MFB Generator
        2 => X"00000200",       -- Data Logger for latency meter
        3 => X"00000300",       -- MFB speed meter for NVME_RD_MFB_*
        4 => X"00000400"        -- MFB speed meter for NVME_WR_MFB_*
        );
    constant MI_SPLIT_ADDR_MASK : std_logic_vector(MI_WIDTH -1 downto 0) := X"00000700";

    -- MI Asynchronous crossing
    signal mi_dwr_sync  : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_addr_sync : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_be_sync   : std_logic_vector(MI_WIDTH/8 -1 downto 0);
    signal mi_rd_sync   : std_logic;
    signal mi_wr_sync   : std_logic;
    signal mi_drd_sync  : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_ardy_sync : std_logic;
    signal mi_drdy_sync : std_logic;

    -- MI Splitter outputs
    signal mi_split_dwr  : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_addr : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_be   : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH/8 -1 downto 0);
    signal mi_split_rd   : std_logic_vector(MI_SPLIT_PORTS-1 downto 0);
    signal mi_split_wr   : std_logic_vector(MI_SPLIT_PORTS-1 downto 0);
    signal mi_split_drd  : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal mi_split_ardy : std_logic_vector(MI_SPLIT_PORTS-1 downto 0);
    signal mi_split_drdy : std_logic_vector(MI_SPLIT_PORTS-1 downto 0);

    -- Register selections
    signal nvme_rd_req_vld_reg_sel          : std_logic;
    signal nvme_rd_req_lba_ptr_low_reg_sel  : std_logic;
    signal nvme_rd_req_lba_ptr_high_reg_sel : std_logic;
    signal nvme_rd_req_lba_num_reg_sel      : std_logic;
    signal nvme_wr_req_lba_ptr_low_reg_sel  : std_logic;
    signal nvme_wr_req_lba_ptr_high_reg_sel : std_logic;
    signal tst_iterations_reg_sel           : std_logic;
    signal tst_sel_reg_sel                  : std_logic;
    signal evcr_interval_reg_sel            : std_logic;

    -- Registers
    signal nvme_rd_req_lba_ptr_reg : std_logic_vector(SQE_LBA_PTR_W -1 downto 0);
    signal nvme_rd_req_lba_num_reg : std_logic_vector(NVME_RD_REQ_LBA_NUM'range);
    signal nvme_wr_req_lba_ptr_reg : std_logic_vector(SQE_LBA_PTR_W -1 downto 0);
    signal op_stat_reg             : std_logic_vector(2 + NVME_OP_STAT_CODE'length -1 downto 0);
    signal wr_mfb_pkt_cnt_reg      : unsigned(15 downto 0);
    signal wr_mfb_word_cnt_reg     : unsigned(15 downto 0);

    -- MFB Generator outputs
    signal gen_mfb_sof     : std_logic_vector(NVME_WR_MFB_SOF'range);
    signal gen_mfb_eof     : std_logic_vector(NVME_WR_MFB_EOF'range);
    signal gen_mfb_sof_pos : std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*2) -1 downto 0);
    signal gen_mfb_eof_pos : std_logic_vector(NVME_WR_MFB_EOF_POS'range);
    signal gen_mfb_src_rdy : std_logic;
    signal gen_mfb_dst_rdy : std_logic;

    function gen_wr_mfb_data(
        pkt_cnt : unsigned(15 downto 0);
        word_cnt : unsigned(15 downto 0);
        sof      : std_logic_vector;
        eof      : std_logic_vector
    ) return std_logic_vector is
        variable ret_data  : std_logic_vector(NVME_WR_MFB_DATA'range);
        variable tile_idx  : unsigned(7 downto 0);
        variable dyn_byte  : unsigned(7 downto 0);
        variable flag_byte : unsigned(7 downto 0);
    begin
        flag_byte := resize(pkt_cnt(15 downto 8), flag_byte'length);

        if (unsigned(sof) /= to_unsigned(0, sof'length)) then
            flag_byte := flag_byte or x"80";
        end if;

        if (unsigned(eof) /= to_unsigned(0, eof'length)) then
            flag_byte := flag_byte or x"40";
        end if;

        for byte_idx in 0 to (NVME_WR_MFB_DATA'length/8) - 1 loop
            tile_idx := to_unsigned(byte_idx/8, tile_idx'length);

            case (byte_idx mod 8) is
                when 0 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := x"4E"; -- N
                when 1 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := x"56"; -- V
                when 2 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := x"4D"; -- M
                when 3 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := x"45"; -- E
                when 4 =>
                    dyn_byte := resize(word_cnt(7 downto 0), dyn_byte'length) + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
                when 5 =>
                    dyn_byte := resize(word_cnt(15 downto 8), dyn_byte'length) + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
                when 6 =>
                    dyn_byte := resize(pkt_cnt(7 downto 0), dyn_byte'length) + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
                when others =>
                    dyn_byte := flag_byte + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
            end case;
        end loop;

        return ret_data;
    end function;

    constant ADDR_CNTR_WIDTH          : natural := 21; -- Supports up to 512 GiB
    constant TIMESTAMP_WIDTH          : natural := 28; -- allows little over 1 s
    constant LOG_TIMESTAMP_WIDTH      : natural := 22; -- allows little over 16 ms, which should be more than enough for an NVMe read/write operation latency
    constant LAT_PARAL_EVENTS         : natural := 2;
    constant HIST_BOX_CNT             : natural := 2**15;
    constant SM_CNT_TICKS_WIDTH       : natural := 28;
    constant SM_CNT_BYTES_WIDTH       : natural := 35;
    constant EVCR_MAX_INTERVAL_CYCLES : natural := 2**SM_CNT_TICKS_WIDTH;

    type lat_meas_fsm_state_t is (S_IDLE, S_COUNT_TESTING_PACKETS);
    signal meas_fsm_pst : lat_meas_fsm_state_t := S_IDLE;
    signal meas_fsm_nst : lat_meas_fsm_state_t := S_IDLE;
    signal pkt_cnt_pst  : unsigned(MI_WIDTH -1 downto 0);
    signal pkt_cnt_nst  : unsigned(MI_WIDTH -1 downto 0);

    signal data_logger_rst      : std_logic;
    signal lat_meas_val         : std_logic_vector(TIMESTAMP_WIDTH -1 downto 0);
    signal lat_meas_val_vld     : std_logic;
    signal lat_meas_fifo_items  : std_logic_vector(log2(LAT_PARAL_EVENTS) downto 0);
    signal lat_meas_fifo_full   : std_logic;
    signal tmsp_ovf_reg         : std_logic;

    signal contig_test          : std_logic;
    signal tst_trigg            : std_logic;
    signal tst_iterations_reg   : std_logic_vector(31 downto 0);
    signal tst_sel_reg          : std_logic_vector(1 downto 0);
    signal tst_finished         : std_logic;
    signal tst_addr             : std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);
    signal seq_addr_cntr        : unsigned(ADDR_CNTR_WIDTH -1 downto 0);
    signal lfsr_rand_addr_out   : std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);

    signal evcr_interval_cycles_reg  : std_logic_vector(log2(EVCR_MAX_INTERVAL_CYCLES + 1) -1 downto 0);
    signal evcr_interval_set         : std_logic;
    signal evcr_event_vld            : std_logic;
    signal evcr_total_events         : std_logic_vector(log2((EVCR_MAX_INTERVAL_CYCLES + 1)*2) -1 downto 0);
    signal evcr_total_cycles         : std_logic_vector(log2(EVCR_MAX_INTERVAL_CYCLES + 1) -1 downto 0);
    signal evcr_total_events_reg     : std_logic_vector(log2((EVCR_MAX_INTERVAL_CYCLES + 1)*2) -1 downto 0);
    signal evcr_total_cycles_reg     : std_logic_vector(log2(EVCR_MAX_INTERVAL_CYCLES + 1) -1 downto 0);
    signal evcr_update               : std_logic;

    attribute mark_debug                        : string;
    attribute mark_debug of NVME_RD_MFB_DATA    : signal is "true";
    attribute mark_debug of NVME_RD_MFB_SOF     : signal is "true";
    attribute mark_debug of NVME_RD_MFB_EOF     : signal is "true";
    attribute mark_debug of NVME_RD_MFB_SOF_POS : signal is "true";
    attribute mark_debug of NVME_RD_MFB_EOF_POS : signal is "true";
    attribute mark_debug of NVME_RD_MFB_SRC_RDY : signal is "true";
    attribute mark_debug of NVME_RD_MFB_DST_RDY : signal is "true";

    -- attribute mark_debug of tst_trigg        : signal is "true";
    -- attribute mark_debug of meas_fsm_pst     : signal is "true";
    -- attribute mark_debug of pkt_cnt_pst      : signal is "true";
    -- attribute mark_debug of tst_finished     : signal is "true";
    -- attribute mark_debug of tst_addr         : signal is "true";
    -- attribute mark_debug of NVME_OP_STAT_VLD : signal is "true";
begin
    mi_async_i : entity work.MI_ASYNC
    generic map (
        ADDR_WIDTH => MI_WIDTH,
        DATA_WIDTH => MI_WIDTH,
        DEVICE     => DEVICE
    )
    port map (
        CLK_M   => MI_CLK,
        RESET_M => MI_RST,

        MI_M_ADDR => MI_ADDR,
        MI_M_DWR  => MI_DWR,
        MI_M_BE   => MI_BE,
        MI_M_RD   => MI_RD,
        MI_M_WR   => MI_WR,
        MI_M_ARDY => MI_ARDY,
        MI_M_DRDY => MI_DRDY,
        MI_M_DRD  => MI_DRD,

        CLK_S   => DMA_CLK,
        RESET_S => DMA_RST,

        MI_S_ADDR => mi_addr_sync,
        MI_S_DWR  => mi_dwr_sync,
        MI_S_BE   => mi_be_sync,
        MI_S_RD   => mi_rd_sync,
        MI_S_WR   => mi_wr_sync,
        MI_S_ARDY => mi_ardy_sync,
        MI_S_DRDY => mi_drdy_sync,
        MI_S_DRD  => mi_drd_sync
    );

    mi_gen_spl_i : entity work.MI_SPLITTER_PLUS_GEN
    generic map (
        ADDR_WIDTH => MI_WIDTH,
        DATA_WIDTH => MI_WIDTH,
        META_WIDTH => 0,
        PORTS      => MI_SPLIT_PORTS,
        PIPE_OUT   => (others => TRUE),

        ADDR_MASK  => MI_SPLIT_ADDR_MASK,
        ADDR_BASES => MI_SPLIT_PORTS,
        ADDR_BASE  => MI_SPLIT_BASES,

        DEVICE => DEVICE
    )
    port map (
        CLK   => DMA_CLK,
        RESET => DMA_RST,

        RX_DWR  => mi_dwr_sync,
        RX_MWR  => (others => '0'),
        RX_ADDR => mi_addr_sync,
        RX_BE   => mi_be_sync,
        RX_RD   => mi_rd_sync,
        RX_WR   => mi_wr_sync,
        RX_ARDY => mi_ardy_sync,
        RX_DRD  => mi_drd_sync,
        RX_DRDY => mi_drdy_sync,

        TX_DWR  => mi_split_dwr,
        TX_MWR  => open,
        TX_ADDR => mi_split_addr,
        TX_BE   => mi_split_be,
        TX_RD   => mi_split_rd,
        TX_WR   => mi_split_wr,
        TX_ARDY => mi_split_ardy,
        TX_DRD  => mi_split_drd,
        TX_DRDY => mi_split_drdy
    );

    reg_sel_proc : process(all)
        variable reg_sel_addr : std_logic_vector(7 downto 0);
    begin
        -- Default selections
        nvme_rd_req_vld_reg_sel                <= '0';
        nvme_rd_req_lba_ptr_low_reg_sel        <= '0';
        nvme_rd_req_lba_ptr_high_reg_sel       <= '0';
        nvme_rd_req_lba_num_reg_sel            <= '0';
        nvme_wr_req_lba_ptr_low_reg_sel        <= '0';
        nvme_wr_req_lba_ptr_high_reg_sel       <= '0';
        tst_iterations_reg_sel                 <= '0';
        tst_sel_reg_sel                        <= '0';
        evcr_interval_reg_sel                  <= '0';

        -- Zero-extend to 12 bits to match x"000" style
        reg_sel_addr                          := (others => '0');
        reg_sel_addr(ADDR_LENGTH -1 downto 0) := mi_split_addr(0)(ADDR_LENGTH -1 downto 0);

        case reg_sel_addr is
            when x"00" => nvme_rd_req_vld_reg_sel            <= '1';
            when x"04" => nvme_rd_req_lba_ptr_low_reg_sel    <= '1';
            when x"08" => nvme_rd_req_lba_ptr_high_reg_sel   <= '1';
            when x"0C" => nvme_rd_req_lba_num_reg_sel        <= '1';
            when x"10" => nvme_wr_req_lba_ptr_low_reg_sel    <= '1';
            when x"14" => nvme_wr_req_lba_ptr_high_reg_sel   <= '1';
            when x"1C" => tst_iterations_reg_sel             <= '1';
            when x"20" => tst_sel_reg_sel                    <= '1';
            when x"24" => evcr_interval_reg_sel              <= '1';
            when others => null;
        end case;
    end process;

    op_stat_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                op_stat_reg <= (others => '0');
            elsif (NVME_OP_STAT_VLD = '1') then
                op_stat_reg <= NVME_OP_STAT_VLD & NVME_OP_STAT_TYPE & NVME_OP_STAT_CODE;
            end if;
        end if;
    end process;

    rd_req_vld_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                NVME_RD_REQ_VLD <= '0';
            else
                if ((nvme_rd_req_vld_reg_sel = '1' and mi_split_wr(0) = '1')
                    or (tst_finished = '0' and tst_sel_reg(1) = '1')
                    or (contig_test = '1' and tst_sel_reg(1) = '1')) then

                    NVME_RD_REQ_VLD <= '1';
                elsif (NVME_RD_REQ_RDY = '1') then
                    NVME_RD_REQ_VLD <= '0';
                end if;
            end if;
        end if;
    end process;

    rd_req_lba_num_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                nvme_rd_req_lba_num_reg <= (others => '0');
            elsif ((nvme_rd_req_lba_num_reg_sel = '1') and (mi_split_wr(0) = '1')) then
                nvme_rd_req_lba_num_reg <= mi_split_dwr(0)(NVME_RD_REQ_LBA_NUM'range);
            end if;
        end if;
    end process;

    rd_req_lba_ptr_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                nvme_rd_req_lba_ptr_reg <= (others => '0');
            elsif (mi_split_wr(0) = '1') then
                if (nvme_rd_req_lba_ptr_low_reg_sel = '1') then
                    nvme_rd_req_lba_ptr_reg(31 downto 0) <= mi_split_dwr(0);
                elsif (nvme_rd_req_lba_ptr_high_reg_sel = '1') then
                    nvme_rd_req_lba_ptr_reg(63 downto 32) <= mi_split_dwr(0);
                end if;
            end if;
        end if;
    end process;

    wr_req_lba_ptr_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                nvme_wr_req_lba_ptr_reg <= (others => '0');
            elsif (mi_split_wr(0) = '1') then
                if (nvme_wr_req_lba_ptr_low_reg_sel = '1') then
                    nvme_wr_req_lba_ptr_reg(31 downto 0) <= mi_split_dwr(0);
                elsif (nvme_wr_req_lba_ptr_high_reg_sel = '1') then
                    nvme_wr_req_lba_ptr_reg(63 downto 32) <= mi_split_dwr(0);
                end if;
            end if;
        end if;
    end process;

    tst_iterations_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                tst_trigg          <= '0';
                tst_iterations_reg <= (others => '0');
            else
                tst_trigg <= '0';

                if (tst_iterations_reg_sel = '1' and mi_split_wr(0) = '1') then
                    tst_trigg          <= '1';
                    tst_iterations_reg <= mi_split_dwr(0);
                end if;
            end if;
        end if;
    end process;

    evcr_interval_cycles_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                evcr_interval_cycles_reg <= (others => '1');
            else
                evcr_interval_set <= '0';

                if (mi_split_wr(0) = '1' and evcr_interval_reg_sel = '1') then
                    evcr_interval_cycles_reg <= mi_split_dwr(0)(evcr_interval_cycles_reg'length -1 downto 0);
                    evcr_interval_set        <= '1';
                end if;
            end if;
        end if;
    end process;

    tst_sel_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                tst_sel_reg  <= (others => '0');
                tmsp_ovf_reg <= '0';
                contig_test    <= '0';
            else
                if ((lat_meas_val_vld = '1') and (unsigned(lat_meas_val) >= (2**LOG_TIMESTAMP_WIDTH))) then
                    tmsp_ovf_reg <= '1';
                end if;

                if ((tst_sel_reg_sel = '1') and (mi_split_wr(0) = '1')) then
                    tst_sel_reg  <= mi_split_dwr(0)(1 downto 0);
                    tmsp_ovf_reg <= mi_split_dwr(0)(2);
                    contig_test    <= mi_split_dwr(0)(3);
                end if;
            end if;
        end if;
    end process;

    NVME_RD_REQ_LBA_PTR <= nvme_rd_req_lba_ptr_reg when (tst_finished = '1' and contig_test = '0') else std_logic_vector(resize(std_logic_vector(tst_addr), NVME_RD_REQ_LBA_PTR'length));
    NVME_RD_REQ_LBA_NUM <= nvme_rd_req_lba_num_reg;
    NVME_WR_MFB_META    <= nvme_wr_req_lba_ptr_reg when (tst_finished = '1' and contig_test = '0') else std_logic_vector(resize(std_logic_vector(tst_addr), NVME_RD_REQ_LBA_PTR'length));
    NVME_WR_MFB_DATA    <= gen_wr_mfb_data(wr_mfb_pkt_cnt_reg, wr_mfb_word_cnt_reg, NVME_WR_MFB_SOF, NVME_WR_MFB_EOF);

    NVME_RD_MFB_DST_RDY <= '1'; -- Always ready to receive data for testing

    wr_mfb_data_cnt_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                wr_mfb_pkt_cnt_reg  <= (others => '0');
                wr_mfb_word_cnt_reg <= (others => '0');
            elsif ((NVME_WR_MFB_SRC_RDY = '1') and (NVME_WR_MFB_DST_RDY = '1')) then
                if (unsigned(NVME_WR_MFB_EOF) /= to_unsigned(0, NVME_WR_MFB_EOF'length)) then
                    wr_mfb_pkt_cnt_reg  <= wr_mfb_pkt_cnt_reg + 1;
                    wr_mfb_word_cnt_reg <= (others => '0');
                else
                    wr_mfb_word_cnt_reg <= wr_mfb_word_cnt_reg + 1;
                end if;
            end if;
        end if;
    end process;

    read_from_regs_p : process (DMA_CLK)
        variable reg_sel_addr : std_logic_vector(7 downto 0);
    begin
        if (rising_edge(DMA_CLK)) then
            mi_split_drd(0) <= (others => '0');

            reg_sel_addr                           := (others => '0');
            reg_sel_addr(ADDR_LENGTH - 1 downto 0) := mi_split_addr(0)(ADDR_LENGTH - 1 downto 0);

            case reg_sel_addr is
                when x"00" => mi_split_drd(0)(1 downto 0)                                    <= NVME_RD_REQ_RDY & NVME_RD_REQ_VLD;
                when x"04" => mi_split_drd(0)                                                <= nvme_rd_req_lba_ptr_reg(31 downto 0);
                when x"08" => mi_split_drd(0)                                                <= nvme_rd_req_lba_ptr_reg(63 downto 32);
                when x"0C" => mi_split_drd(0)(7 downto 0)                                    <= nvme_rd_req_lba_num_reg;
                when x"10" => mi_split_drd(0)                                                <= nvme_wr_req_lba_ptr_reg(31 downto 0);
                when x"14" => mi_split_drd(0)                                                <= nvme_wr_req_lba_ptr_reg(63 downto 32);
                when x"18" => mi_split_drd(0)(op_stat_reg'range)                             <= op_stat_reg;
                when x"1C" => mi_split_drd(0)                                                <= tst_iterations_reg;
                when x"20" => mi_split_drd(0)(3 downto 0)                                    <= contig_test & tmsp_ovf_reg & tst_sel_reg;
                when x"24" => mi_split_drd(0)(evcr_interval_cycles_reg'length - 1 downto 0)  <= evcr_interval_cycles_reg;
                when x"28" => mi_split_drd(0)(evcr_total_events_reg'length - 1 downto 0)     <= evcr_total_events_reg;
                when x"2C" => mi_split_drd(0)(evcr_total_cycles_reg'length - 1 downto 0)     <= evcr_total_cycles_reg;
                when others => mi_split_drd(0)                                               <= x"CAFEBABE";
            end case;
        end if;
    end process;

    mi_split_ardy(0) <= mi_split_rd(0) or mi_split_wr(0);

    drdy_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                mi_split_drdy(0) <= '0';
            else
                mi_split_drdy(0) <= mi_split_rd(0);
            end if;
        end if;
    end process;

    mfb_generator_i : entity work.MFB_GENERATOR_MI32
    generic map (
        REGIONS     => DMA_MFB_REGIONS,
        -- Just some adjustements since this shitty component does not support to have a
        -- region size of one block
        REGION_SIZE => DMA_MFB_REGION_SIZE*2,
        BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE/2,
        ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,

        LENGTH_WIDTH   => 18,
        CHANNELS_WIDTH => 1,

        PKT_CNT_WIDTH => 64,
        USE_PACP_ARCH => FALSE,
        DEVICE        => DEVICE
    )
    port map (
        CLK => DMA_CLK,
        RST => DMA_RST,

        MI_ADDR => mi_split_addr(1),
        MI_RD   => mi_split_rd(1),
        MI_WR   => mi_split_wr(1),
        MI_ARDY => mi_split_ardy(1),
        MI_DWR  => mi_split_dwr(1),
        MI_BE   => mi_split_be(1),
        MI_DRD  => mi_split_drd(1),
        MI_DRDY => mi_split_drdy(1),

        TX_MFB_DATA    => open,
        TX_MFB_META    => open,
        TX_MFB_SOF     => gen_mfb_sof,
        TX_MFB_EOF     => gen_mfb_eof,
        TX_MFB_SOF_POS => gen_mfb_sof_pos,
        TX_MFB_EOF_POS => gen_mfb_eof_pos,
        TX_MFB_SRC_RDY => gen_mfb_src_rdy,
        TX_MFB_DST_RDY => gen_mfb_dst_rdy
    );

    mfb_reconfigurator_i : entity work.MFB_RECONFIGURATOR
        generic map (
            RX_REGIONS            => DMA_MFB_REGIONS,
            RX_REGION_SIZE        => DMA_MFB_REGION_SIZE*2,
            RX_BLOCK_SIZE         => DMA_MFB_BLOCK_SIZE/2,
            RX_ITEM_WIDTH         => DMA_MFB_ITEM_WIDTH,

            TX_REGIONS            => DMA_MFB_REGIONS,
            TX_REGION_SIZE        => DMA_MFB_REGION_SIZE,
            TX_BLOCK_SIZE         => DMA_MFB_BLOCK_SIZE,
            TX_ITEM_WIDTH         => DMA_MFB_ITEM_WIDTH,

            META_WIDTH            => 0,
            META_MODE             => 0,
            FIFO_SIZE             => 32,
            FRAMES_OVER_TX_BLOCK  => 1,
            FRAMES_OVER_TX_REGION => 1,
            DEVICE                => DEVICE
        )
        port map (
            CLK        => DMA_CLK,
            RESET      => DMA_RST,

            RX_DATA    => (others => '0'),
            RX_META    => (others => '0'),
            RX_SOF     => gen_mfb_sof,
            RX_EOF     => gen_mfb_eof,
            RX_SOF_POS => gen_mfb_sof_pos,
            RX_EOF_POS => gen_mfb_eof_pos,
            RX_SRC_RDY => gen_mfb_src_rdy,
            RX_DST_RDY => gen_mfb_dst_rdy,

            TX_DATA    => open,
            TX_META    => open,
            TX_SOF     => NVME_WR_MFB_SOF,
            TX_EOF     => NVME_WR_MFB_EOF,
            TX_SOF_POS => NVME_WR_MFB_SOF_POS,
            TX_EOF_POS => NVME_WR_MFB_EOF_POS,
            TX_SRC_RDY => NVME_WR_MFB_SRC_RDY,
            TX_DST_RDY => NVME_WR_MFB_DST_RDY
        );

    -- =============================================================================
    -- Latency measurement
    --
    -- WARNING: Presumes that the size of the NVMe storage be at least 512 GiB because
    -- the addresses count with this range
    -- =============================================================================
    data_logger_i : entity work.DATA_LOGGER
    generic map (
        MI_DATA_WIDTH => MI_WIDTH,
        MI_ADDR_WIDTH => MI_WIDTH,

        CNTER_CNT => 0,
        VALUE_CNT => 1,

        CTRLO_WIDTH => 0,
        CTRLI_WIDTH => 1+log2(LAT_PARAL_EVENTS)+1+1,

        CNTER_WIDTH => 64,
        VALUE_WIDTH => (others => LOG_TIMESTAMP_WIDTH),

        MIN_EN  => (others => TRUE),
        MAX_EN  => (others => TRUE),
        SUM_EN  => (others => FALSE),
        HIST_EN => (others => TRUE),

        SUM_EXTRA_WIDTH => (others => 16),
        HIST_BOX_CNT    => (others => HIST_BOX_CNT),
        HIST_BOX_WIDTH  => (others => 32),
        CTRLO_DEFAULT   => (others => '0')
    )
    port map (
        CLK => DMA_CLK,
        RST => DMA_RST,

        RST_DONE => open,
        SW_RST   => data_logger_rst,

        CTRLO => open,
        CTRLI => (
                tst_finished &
                lat_meas_fifo_items &
                lat_meas_fifo_full),

        CNTERS_INCR   => (others => '0'),
        CNTERS_SUBMIT => (others => '0'),
        CNTERS_DIFF   => (others => (others => '0')),

        VALUES_VLD => (others => lat_meas_val_vld),
        VALUES     => lat_meas_val(LOG_TIMESTAMP_WIDTH -1 downto 0),

        MI_DWR  => mi_split_dwr(2),
        MI_ADDR => mi_split_addr(2),
        MI_BE   => mi_split_be(2),
        MI_RD   => mi_split_rd(2),
        MI_WR   => mi_split_wr(2),
        MI_ARDY => mi_split_ardy(2),
        MI_DRD  => mi_split_drd(2),
        MI_DRDY => mi_split_drdy(2)
    );

    latency_meter_i : entity work.LATENCY_METER
    generic map (
        DATA_WIDTH         => TIMESTAMP_WIDTH,
        MAX_PARALEL_EVENTS => LAT_PARAL_EVENTS,
        DEVICE             => DEVICE
    )
    port map (
        CLK => DMA_CLK,
        RST => DMA_RST or data_logger_rst,

        START_EVENT         => ((or NVME_WR_MFB_SOF) and NVME_WR_MFB_SRC_RDY and NVME_WR_MFB_DST_RDY) or
                               (NVME_RD_REQ_VLD and NVME_RD_REQ_RDY),
        START_EVENT_META    => (others => '0'),
        END_EVENT           => NVME_OP_STAT_VLD,
        END_EVENT_META      => (others => '0'),

        LATENCY_VLD        => lat_meas_val_vld,
        LATENCY            => lat_meas_val,
        LATENCY_START_META => open,
        LATENCY_END_META   => open,

        FIFO_FULL  => lat_meas_fifo_full,
        FIFO_ITEMS => lat_meas_fifo_items
    );

    meas_director_fsm_reg_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1' or data_logger_rst = '1') then
                meas_fsm_pst <= S_IDLE;
                pkt_cnt_pst  <= (others => '0');
            else
                meas_fsm_pst <= meas_fsm_nst;
                pkt_cnt_pst  <= pkt_cnt_nst;
            end if;
        end if;
    end process;

    meas_director_fsm_nst_logic_p : process (all) is
    begin
        meas_fsm_nst  <= meas_fsm_pst;
        pkt_cnt_nst   <= pkt_cnt_pst;
        tst_finished <= '0';

        case meas_fsm_pst is
            when S_IDLE =>
                tst_finished <= '1';

                -- Enable testing check only when burst mode in the generator is enabled
                if (tst_trigg = '1') then
                    meas_fsm_nst <= S_COUNT_TESTING_PACKETS;
                    pkt_cnt_nst  <= unsigned(tst_iterations_reg);
                end if;

            when S_COUNT_TESTING_PACKETS =>

                if (NVME_OP_STAT_VLD = '1' and pkt_cnt_pst > 0) then
                    pkt_cnt_nst <= pkt_cnt_pst -1;
                end if;

                if (pkt_cnt_pst = 0 and unsigned(lat_meas_fifo_items) = 0) then
                    meas_fsm_nst <= S_IDLE;
                end if;
        end case;
    end process;

    lfsr_rand_addr_gen_i : entity work.LFSR_SIMPLE_RANDOM_GEN
    generic map (
        DATA_WIDTH  => ADDR_CNTR_WIDTH,
        -- Some stuff
        RESET_SEED  => "000011010110011100001"
    )
    port map (
        CLK    => DMA_CLK,
        RESET  => DMA_RST or data_logger_rst,
        ENABLE => NVME_OP_STAT_VLD and ((not tst_finished) or contig_test),
        DATA   => lfsr_rand_addr_out
    );

    seq_addr_cntr_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1' or data_logger_rst = '1' or tst_trigg = '1') then
                seq_addr_cntr <= resize(unsigned(nvme_rd_req_lba_ptr_reg), seq_addr_cntr'length);
            elsif (NVME_OP_STAT_VLD = '1' and (tst_finished = '0' or contig_test = '1')) then
                seq_addr_cntr <= seq_addr_cntr + resize(unsigned(nvme_rd_req_lba_num_reg), seq_addr_cntr'length);
            end if;
        end if;
    end process;

    tst_addr <= std_logic_vector(seq_addr_cntr) when tst_sel_reg(0) = '0' else lfsr_rand_addr_out;

    rd_mfb_speed_meter_i : entity work.MFB_SPEED_METER_MI
    generic map (
        REGIONS          => DMA_MFB_REGIONS,
        REGION_SIZE      => DMA_MFB_REGION_SIZE,
        BLOCK_SIZE       => DMA_MFB_BLOCK_SIZE,
        ITEM_WIDTH       => DMA_MFB_ITEM_WIDTH,
        CNT_TICKS_WIDTH  => SM_CNT_TICKS_WIDTH,
        -- Based on the recommendation from the component declaration
        CNT_BYTES_WIDTH  => SM_CNT_BYTES_WIDTH,
        CNT_PKTS_WIDTH   => 32,
        DISABLE_ON_CLR   => true,
        COUNT_PACKETS    => true,
        ADD_ARR_PKTS     => false,
        FREQUENCY        => 250,
        MI_DATA_WIDTH    => MI_WIDTH,
        MI_ADDRESS_WIDTH => MI_WIDTH
    )
    port map (
        CLK        => DMA_CLK,
        RST        => DMA_RST,

        MI_DWR     => mi_split_dwr(3),
        MI_ADDR    => mi_split_addr(3),
        MI_BE      => mi_split_be(3),
        MI_RD      => mi_split_rd(3),
        MI_WR      => mi_split_wr(3),
        MI_ARDY    => mi_split_ardy(3),
        MI_DRD     => mi_split_drd(3),
        MI_DRDY    => mi_split_drdy(3),

        RX_SOF_POS => NVME_RD_MFB_SOF_POS,
        RX_EOF_POS => NVME_RD_MFB_EOF_POS,
        RX_SOF     => NVME_RD_MFB_SOF,
        RX_EOF     => NVME_RD_MFB_EOF,
        RX_SRC_RDY => NVME_RD_MFB_SRC_RDY,
        RX_DST_RDY => NVME_RD_MFB_DST_RDY
    );

    wr_mfb_speed_meter_i : entity work.MFB_SPEED_METER_MI
    generic map (
        REGIONS          => DMA_MFB_REGIONS,
        REGION_SIZE      => DMA_MFB_REGION_SIZE,
        BLOCK_SIZE       => DMA_MFB_BLOCK_SIZE,
        ITEM_WIDTH       => DMA_MFB_ITEM_WIDTH,
        CNT_TICKS_WIDTH  => SM_CNT_TICKS_WIDTH,
        -- Based on the recommendation from the component declaration
        CNT_BYTES_WIDTH  => SM_CNT_BYTES_WIDTH,
        CNT_PKTS_WIDTH   => 32,
        DISABLE_ON_CLR   => true,
        COUNT_PACKETS    => true,
        ADD_ARR_PKTS     => false,
        FREQUENCY        => 250,
        MI_DATA_WIDTH    => MI_WIDTH,
        MI_ADDRESS_WIDTH => MI_WIDTH
    )
    port map (
        CLK        => DMA_CLK,
        RST        => DMA_RST,

        MI_DWR     => mi_split_dwr(4),
        MI_ADDR    => mi_split_addr(4),
        MI_BE      => mi_split_be(4),
        MI_RD      => mi_split_rd(4),
        MI_WR      => mi_split_wr(4),
        MI_ARDY    => mi_split_ardy(4),
        MI_DRD     => mi_split_drd(4),
        MI_DRDY    => mi_split_drdy(4),

        RX_SOF_POS => NVME_WR_MFB_SOF_POS,
        RX_EOF_POS => NVME_WR_MFB_EOF_POS,
        RX_SOF     => NVME_WR_MFB_SOF,
        RX_EOF     => NVME_WR_MFB_EOF,
        RX_SRC_RDY => NVME_WR_MFB_SRC_RDY,
        RX_DST_RDY => NVME_WR_MFB_DST_RDY
    );

    iops_cntr_i : entity work.EVENT_COUNTER
    generic map (
        MAX_INTERVAL_CYCLES   => EVCR_MAX_INTERVAL_CYCLES,
        MAX_CONCURRENT_EVENTS => 1)
    port map (
        CLK   => DMA_CLK,
        RESET => DMA_RST,

        INTERVAL_CYCLES => evcr_interval_cycles_reg,
        INTERVAL_SET    => evcr_interval_set,

        EVENT_CNT => (others => '1'),
        EVENT_VLD => evcr_event_vld,

        TOTAL_EVENTS => evcr_total_events,
        TOTAL_CYCLES => evcr_total_cycles,
        TOTAL_UPDATE => evcr_update);

    evcr_event_vld <= (NVME_RD_REQ_VLD and NVME_RD_REQ_RDY) or (NVME_WR_MFB_SOF(0) and NVME_WR_MFB_SRC_RDY and NVME_WR_MFB_DST_RDY);

    evcr_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                evcr_total_events_reg <= (others => '0');
                evcr_total_cycles_reg <= (others => '0');
            elsif (evcr_update = '1') then
                evcr_total_events_reg <= evcr_total_events;
                evcr_total_cycles_reg <= evcr_total_cycles;
            end if;
        end if;
    end process;
end architecture;