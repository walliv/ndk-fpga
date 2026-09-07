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
    constant DLOGGER_HIST_EN : boolean := FALSE;
    -- Queue-Identifier width for round-robin distribution across DMA queues. At NUM_QUEUES = 1,
    -- QID_W collapses to 1 bit but every QID-related signal below is explicitly forced to 0,
    -- reproducing today's single-queue behaviour bit-for-bit.
    constant QID_W              : natural := maximum(1, log2(NUM_QUEUES));
    -- LENGTH_WIDTH used by the write-side throughput generator (mirrors the value passed to
    -- MFB_GENERATOR_MI32 below); needed only to size/slice the raw generator TX_MFB_META.
    constant GEN_LENGTH_WIDTH   : natural := 18;

    constant ADDR_LENGTH        : natural := 7;   -- decode 0x00..0x7C (integrity regs live at 0x30..0x54)
    constant MI_SPLIT_PORTS     : natural := 3;
    constant MI_SPLIT_BASES     : slv_array_t(MI_SPLIT_PORTS-1 downto 0)(MI_WIDTH-1 downto 0) := (
        0 => X"00000000",                         -- Control and Status Registers
        1 => X"00000100",                         -- MFB Generator
        2 => X"00000200"                          -- Data Logger for latency meter
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
    -- Read-side QID round-robin registers: min/max queue and burst size (0x58/0x5C).
    signal rd_ch_minmax_reg_sel             : std_logic;
    signal rd_burst_reg_sel                 : std_logic;

    -- Registers
    signal nvme_rd_req_lba_ptr_reg : std_logic_vector(SQE_LBA_PTR_W -1 downto 0);
    signal nvme_rd_req_lba_num_reg : std_logic_vector(NVME_RD_REQ_LBA_NUM'range);
    signal nvme_wr_req_lba_ptr_reg : std_logic_vector(SQE_LBA_PTR_W -1 downto 0);
    signal op_stat_reg             : std_logic_vector(2 + NVME_OP_STAT_CODE'length -1 downto 0);
    -- Last-seen command identities, published so a completion/returned frame can be attributed to
    -- the request that produced it. Sticky valid bits say "captured since reset", so a reader can
    -- tell a real CID 0 from a never-written register.
    signal nvme_rd_mfb_dst_rdy_s   : std_logic;
    signal op_stat_qid_reg         : std_logic_vector(QID_W -1 downto 0);
    signal op_stat_cid_reg         : std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
    signal op_stat_id_vld_reg      : std_logic;
    signal rd_req_cid_reg          : std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
    signal rd_req_cid_vld_reg      : std_logic;
    signal rd_mfb_qid_reg          : std_logic_vector(QID_W -1 downto 0);
    signal rd_mfb_cid_reg          : std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
    signal rd_mfb_id_vld_reg       : std_logic;
    signal wr_mfb_pkt_cnt_reg      : unsigned(15 downto 0);
    signal wr_mfb_word_cnt_reg     : unsigned(15 downto 0);

    -- Read-side QID round-robin: min/max queue for the range and burst (read requests sent to a
    -- queue before advancing), mirroring MFB_GENERATOR_MI32 semantics. Default (0,0) keeps every
    -- read on queue 0 until configured.
    signal rd_ch_min_reg   : std_logic_vector(QID_W -1 downto 0);
    signal rd_ch_max_reg   : std_logic_vector(QID_W -1 downto 0);
    signal rd_burst_reg    : std_logic_vector(15 downto 0);
    signal rd_qid_cntr     : unsigned(QID_W -1 downto 0);
    signal rd_burst_cntr   : unsigned(15 downto 0);
    -- Round-robin QID for the read-request submit interface; forced to 0 when NUM_QUEUES = 1.
    signal gen_rd_req_qid  : std_logic_vector(QID_W -1 downto 0);
    -- Next ready queue at/after rd_qid_cntr in [rd_ch_min_reg, rd_ch_max_reg] (from
    -- rd_qid_select_p), skipping full queues: the DMA accepts one request at a time, so
    -- presenting a full queue would stall every other queue too.
    signal rd_qid_cand     : unsigned(QID_W -1 downto 0);
    -- '1' when rd_qid_cand is actually ready (some queue in [min,max] currently has room); '0'
    -- when every queue in range is full -- gates NVME_RD_REQ_VLD off so the generator holds
    -- instead of presenting a request to a queue that would just stall.
    signal rd_qid_cand_rdy : std_logic;
    -- Scalar view of the per-queue read handshake, so the generator/checker logic below stays
    -- queue-agnostic: request offered, and the RDY bit of the queue QID names.
    signal rd_req_vld_s      : std_logic;
    signal rd_req_accepted_s : std_logic;
    signal chk_rd_req_rdy    : std_logic;
    signal nvme_rd_req_qid_s : std_logic_vector(QID_W -1 downto 0);
    -- QID that the integrity checker's write/read requests are tagged with (queue 0 / rd_ch_min);
    -- forced to 0 when NUM_QUEUES = 1.
    signal checker_qid     : std_logic_vector(QID_W -1 downto 0);

    -- MFB Generator outputs
    signal gen_mfb_sof     : std_logic_vector(NVME_WR_MFB_SOF'range);
    signal gen_mfb_eof     : std_logic_vector(NVME_WR_MFB_EOF'range);
    signal gen_mfb_sof_pos : std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*2) -1 downto 0);
    signal gen_mfb_eof_pos : std_logic_vector(NVME_WR_MFB_EOF_POS'range);
    signal gen_mfb_src_rdy : std_logic;
    signal gen_mfb_dst_rdy : std_logic;

    -- MFB_GENERATOR_MI32's round-robin channel (CHANNELS_WIDTH=QID_W) is the target QID; its per-
    -- region meta is threaded through MFB_RECONFIGURATOR alongside the frame data so the channel
    -- stays aligned with a re-timed/FIFO-buffered frame.
    signal gen_mfb_meta          : std_logic_vector(DMA_MFB_REGIONS*(QID_W + GEN_LENGTH_WIDTH) -1 downto 0);
    signal gen_mfb_qid           : std_logic_vector(DMA_MFB_REGIONS*QID_W -1 downto 0);
    signal gen_nvme_wr_qid       : std_logic_vector(DMA_MFB_REGIONS*QID_W -1 downto 0);
    -- Same as gen_nvme_wr_qid but forced to 0 when NUM_QUEUES = 1.
    signal gen_nvme_wr_qid_mskd  : std_logic_vector(DMA_MFB_REGIONS*QID_W -1 downto 0);
    -- LBA-pointer part of the write meta (unchanged generator/checker addressing logic).
    signal gen_wr_meta_lba       : std_logic_vector(SQE_LBA_PTR_W -1 downto 0);

    function gen_wr_mfb_data (
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
            flag_byte := flag_byte or X"80";
        end if;

        if (unsigned(eof) /= to_unsigned(0, eof'length)) then
            flag_byte := flag_byte or X"40";
        end if;

        for byte_idx in 0 to (NVME_WR_MFB_DATA'length/8) - 1 loop
            tile_idx := to_unsigned(byte_idx/8, tile_idx'length);

            case (byte_idx mod 8) is
                when 0 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := X"4E"; -- N
                when 1 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := X"56"; -- V
                when 2 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := X"4D"; -- M
                when 3 => ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := X"45"; -- E
                when 4 =>
                    dyn_byte                                         := resize(word_cnt(7 downto 0), dyn_byte'length) + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
                when 5 =>
                    dyn_byte                                         := resize(word_cnt(15 downto 8), dyn_byte'length) + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
                when 6 =>
                    dyn_byte                                         := resize(pkt_cnt(7 downto 0), dyn_byte'length) + tile_idx;
                    ret_data((byte_idx + 1)*8 - 1 downto byte_idx*8) := std_logic_vector(dyn_byte);
                when others =>
                    dyn_byte                                         := flag_byte + tile_idx;
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
    constant EVCR_MAX_INTERVAL_CYCLES : natural := 2**28;
    -- OP_STAT_CODE encoding on the DMA interface: "00" SUCCESS, "01" FAILURE, "10" LBA out of range.
    -- Same value the integrity checker declares locally (iuventus_integrity_checker.vhd).
    constant OP_STAT_SUCCESS          : std_logic_vector(1 downto 0) := "00";

    type   lat_meas_fsm_state_t is (S_IDLE, S_COUNT_TESTING_PACKETS);
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
    -- Latency mode (TST_SEQ_RAND_SEL bit 4): serialises the read generator to ONE operation in
    -- flight -- LATENCY_METER pairs positionally with no tag, so concurrency would pair a
    -- completion with the wrong start. Deliberately QD1, not a throughput mode.
    signal lat_meas_mode        : std_logic;
    -- '0' while a measured operation is still outstanding.
    signal lat_meas_issue_ok    : std_logic;
    -- Registered one-outstanding interlock. lat_meas_fifo_items alone is NOT enough: FIFOX STATUS
    -- only updates the cycle AFTER START_EVENT, so a second request slips through that gap.
    signal lat_outstanding_r    : std_logic;
    -- '1' between an accepted write SOF and its EOF. The write gate may only withhold at a frame
    -- boundary -- deasserting SRC_RDY mid-frame would stall a partially-transferred frame.
    signal lat_wr_in_frame_r    : std_logic;
    signal lat_wr_issue_ok      : std_logic;
    signal lat_wr_new_frame_s   : std_logic;
    -- The meter's own START_EVENT, shared with the interlock so both count the same thing.
    signal lat_start_event_s    : std_logic;
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

    -- ---- SSD data-integrity self-test (write pattern -> read back -> compare in fabric) -------
    -- Control registers (0x30..0x3C) and status (0x40..0x54); integ_en steers the WR/RD MFB and
    -- RD_REQ ports away from the throughput generator to the checker.
    signal integ_en             : std_logic;
    signal integ_start          : std_logic;
    signal integ_lba_base_reg   : std_logic_vector(63 downto 0);
    signal integ_lba_count_reg  : std_logic_vector(31 downto 0);
    signal integ_ctrl_reg_sel   : std_logic;
    signal integ_base_l_reg_sel : std_logic;
    signal integ_base_h_reg_sel : std_logic;
    signal integ_count_reg_sel  : std_logic;

    signal chk_busy    : std_logic;
    signal chk_done    : std_logic;
    signal chk_err_cnt : std_logic_vector(31 downto 0);
    signal chk_err_lba : std_logic_vector(63 downto 0);
    signal chk_err_exp : std_logic_vector(31 downto 0);
    signal chk_err_got : std_logic_vector(31 downto 0);

    signal chk_state      : std_logic_vector(2 downto 0);
    signal chk_beat_idx   : std_logic_vector(7 downto 0);
    signal chk_opstat_cnt : std_logic_vector(7 downto 0);
    signal chk_op_err     : std_logic;

    -- Checker datapath (write side) and read request.
    signal chk_wr_data        : std_logic_vector(NVME_WR_MFB_DATA'range);
    -- LBA-only meta (matches IUVENTUS_INTEGRITY_CHECKER's fixed LBA_PTR_W=64 WR_MFB_META port);
    -- the QID (checker_qid) is appended separately when assembling NVME_WR_MFB_META below.
    signal chk_wr_meta        : std_logic_vector(63 downto 0);
    signal chk_wr_sof         : std_logic_vector(NVME_WR_MFB_SOF'range);
    signal chk_wr_eof         : std_logic_vector(NVME_WR_MFB_EOF'range);
    signal chk_wr_sof_pos     : std_logic_vector(NVME_WR_MFB_SOF_POS'range);
    signal chk_wr_eof_pos     : std_logic_vector(NVME_WR_MFB_EOF_POS'range);
    signal chk_wr_src_rdy     : std_logic;
    signal chk_rd_req_lba_ptr : std_logic_vector(63 downto 0);
    signal chk_rd_req_lba_num : std_logic_vector(7 downto 0);
    signal chk_rd_req_vld     : std_logic;
    signal chk_rd_mfb_dst_rdy : std_logic;

    -- Throughput-generator write path (formerly wired straight to the entity WR MFB outputs).
    signal gen_nvme_wr_sof     : std_logic_vector(NVME_WR_MFB_SOF'range);
    signal gen_nvme_wr_eof     : std_logic_vector(NVME_WR_MFB_EOF'range);
    signal gen_nvme_wr_sof_pos : std_logic_vector(NVME_WR_MFB_SOF_POS'range);
    signal gen_nvme_wr_eof_pos : std_logic_vector(NVME_WR_MFB_EOF_POS'range);
    signal gen_nvme_wr_src_rdy : std_logic;
    signal gen_nvme_wr_dst_rdy : std_logic;
    signal gen_nvme_rd_req_vld : std_logic;

    -- Registered stage between MFB_RECONFIGURATOR and the WR MFB outputs. Breaks the
    -- DMA-to-user-core critical path: NVME_WR_MFB_DST_RDY is driven combinationally from inside
    -- the DMA and was landing 20 logic levels later, WNS -1.246 ns.
    signal pip_nvme_wr_sof     : std_logic_vector(NVME_WR_MFB_SOF'range);
    signal pip_nvme_wr_eof     : std_logic_vector(NVME_WR_MFB_EOF'range);
    signal pip_nvme_wr_sof_pos : std_logic_vector(NVME_WR_MFB_SOF_POS'range);
    signal pip_nvme_wr_eof_pos : std_logic_vector(NVME_WR_MFB_EOF_POS'range);
    signal pip_nvme_wr_src_rdy : std_logic;
    signal pip_nvme_wr_dst_rdy : std_logic;
    -- Write meta rides THROUGH the pipe so the LBA stays aligned with its own frame: it is sourced
    -- from a separate address register, so leaving it unpiped would pair a delayed SOF with an
    -- already-advanced LBA.
    signal gen_wr_meta_full    : std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + QID_W) -1 downto 0);
    signal pip_wr_meta         : std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + QID_W) -1 downto 0);

    attribute mark_debug : string;
    -- DISABLED. mark_debug preserves a net from optimisation and nothing consumes these: the ILA
    -- that probed them is commented out in src/ilas.xdc. report_qor_assessment flags them on the
    -- very bus carrying the paths already over the Net/LUT budget. Re-enable TOGETHER with
    -- ilas.xdc, never on their own.
    -- attribute mark_debug of NVME_RD_MFB_DATA    : signal is "true";
    -- attribute mark_debug of NVME_RD_MFB_SOF     : signal is "true";
    -- attribute mark_debug of NVME_RD_MFB_EOF     : signal is "true";
    -- attribute mark_debug of NVME_RD_MFB_SOF_POS : signal is "true";
    -- attribute mark_debug of NVME_RD_MFB_EOF_POS : signal is "true";
    -- attribute mark_debug of NVME_RD_MFB_SRC_RDY : signal is "true";
    -- attribute mark_debug of NVME_RD_MFB_DST_RDY : signal is "true";

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

    reg_sel_proc : process (all)
        variable reg_sel_addr : std_logic_vector(7 downto 0);
    begin
        -- Default selections
        nvme_rd_req_vld_reg_sel                 <= '0';
        nvme_rd_req_lba_ptr_low_reg_sel         <= '0';
        nvme_rd_req_lba_ptr_high_reg_sel        <= '0';
        nvme_rd_req_lba_num_reg_sel             <= '0';
        nvme_wr_req_lba_ptr_low_reg_sel         <= '0';
        nvme_wr_req_lba_ptr_high_reg_sel        <= '0';
        tst_iterations_reg_sel                  <= '0';
        tst_sel_reg_sel                         <= '0';
        evcr_interval_reg_sel                   <= '0';
        integ_ctrl_reg_sel                      <= '0';
        integ_base_l_reg_sel                    <= '0';
        integ_base_h_reg_sel                    <= '0';
        integ_count_reg_sel                     <= '0';
        rd_ch_minmax_reg_sel                    <= '0';
        rd_burst_reg_sel                        <= '0';

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
            when x"30" => integ_ctrl_reg_sel                 <= '1';
            when x"34" => integ_base_l_reg_sel               <= '1';
            when x"38" => integ_base_h_reg_sel               <= '1';
            when x"3C" => integ_count_reg_sel                <= '1';
            when x"58" => rd_ch_minmax_reg_sel               <= '1';
            when x"5C" => rd_burst_reg_sel                   <= '1';
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

    -- OP_STAT identity. Captured on the same pulse as op_stat_reg above, so the two always
    -- describe the same completion.
    op_stat_id_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                op_stat_qid_reg    <= (others => '0');
                op_stat_cid_reg    <= (others => '0');
                op_stat_id_vld_reg <= '0';
            elsif (NVME_OP_STAT_VLD = '1') then
                op_stat_qid_reg    <= NVME_OP_STAT_QID;
                op_stat_cid_reg    <= NVME_OP_STAT_CID;
                op_stat_id_vld_reg <= '1';
            end if;
        end if;
    end process;

    -- Tag the DMA assigned to the last accepted read.
    rd_req_cid_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                rd_req_cid_reg     <= (others => '0');
                rd_req_cid_vld_reg <= '0';
            elsif (NVME_RD_REQ_CID_VLD = '1') then
                rd_req_cid_reg     <= NVME_RD_REQ_CID;
                rd_req_cid_vld_reg <= '1';
            end if;
        end if;
    end process;

    -- Identity of the frame currently landing on RD_MFB. Sampled at SOF of region 0 on a real
    -- transfer: META is only defined for a region carrying a frame start.
    rd_mfb_id_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                rd_mfb_qid_reg   <= (others => '0');
                rd_mfb_cid_reg   <= (others => '0');
                rd_mfb_id_vld_reg <= '0';
            elsif (NVME_RD_MFB_SOF(0) = '1' and NVME_RD_MFB_SRC_RDY = '1'
                   and nvme_rd_mfb_dst_rdy_s = '1') then
                rd_mfb_cid_reg   <= NVME_RD_MFB_META(CQ_ENTRY_CMD_ID_W -1 downto 0);
                rd_mfb_qid_reg   <= NVME_RD_MFB_META(CQ_ENTRY_CMD_ID_W + QID_W -1 downto CQ_ENTRY_CMD_ID_W);
                rd_mfb_id_vld_reg <= '1';
            end if;
        end if;
    end process;

    rd_req_vld_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                gen_nvme_rd_req_vld <= '0';
            else
                if ((nvme_rd_req_vld_reg_sel = '1' and mi_split_wr(0) = '1')
                    or (tst_finished = '0' and tst_sel_reg(1) = '1')
                    or (contig_test = '1' and tst_sel_reg(1) = '1')) then

                    gen_nvme_rd_req_vld <= '1';
                -- The RDY bit of the queue this request is aimed at, not the whole vector: with
                -- a per-queue handshake another queue going ready must not retire this request.
                elsif (chk_rd_req_rdy = '1') then
                    gen_nvme_rd_req_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    -- SSD data-integrity control registers (0x30 CTRL[start,en], 0x34/0x38 LBA base, 0x3C count).
    integ_ctrl_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                integ_en            <= '0';
                integ_start         <= '0';
                integ_lba_base_reg  <= (others => '0');
                integ_lba_count_reg <= (others => '0');
            else
                integ_start <= '0';
                if (mi_split_wr(0) = '1') then
                    if (integ_ctrl_reg_sel = '1') then
                        integ_start <= mi_split_dwr(0)(0);
                        integ_en    <= mi_split_dwr(0)(1);
                    end if;
                    if (integ_base_l_reg_sel = '1') then
                        integ_lba_base_reg(31 downto 0) <= mi_split_dwr(0);
                    end if;
                    if (integ_base_h_reg_sel = '1') then
                        integ_lba_base_reg(63 downto 32) <= mi_split_dwr(0);
                    end if;
                    if (integ_count_reg_sel = '1') then
                        integ_lba_count_reg <= mi_split_dwr(0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Read-side QID round-robin registers. 0x58 RD_CH_MINMAX: [QID_W-1:0]=rd_ch_min,
    -- [16+QID_W-1:16]=rd_ch_max (mirrors MFB_GENERATOR_MI32 at 0x0C). 0x5C RD_BURST:
    -- [15:0]=requests/queue before advancing (default 1); both reset to queue-0-only.
    rd_ch_minmax_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                rd_ch_min_reg <= (others => '0');
                rd_ch_max_reg <= (others => '0');
            elsif (rd_ch_minmax_reg_sel = '1' and mi_split_wr(0) = '1') then
                rd_ch_min_reg <= mi_split_dwr(0)(QID_W -1 downto 0);
                rd_ch_max_reg <= mi_split_dwr(0)(16 + QID_W -1 downto 16);
            end if;
        end if;
    end process;

    rd_burst_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                rd_burst_reg <= std_logic_vector(to_unsigned(1, rd_burst_reg'length));
            elsif (rd_burst_reg_sel = '1' and mi_split_wr(0) = '1') then
                rd_burst_reg <= mi_split_dwr(0)(15 downto 0);
            end if;
        end if;
    end process;

    -- Combinational round-robin scan: pick the next ready queue at/after rd_qid_cntr within
    -- [rd_ch_min_reg, rd_ch_max_reg] (wrapping). At NUM_QUEUES=1 this always resolves to queue 0,
    -- rd_qid_cand_rdy mirroring core_rd_req_rdy(0).
    rd_qid_select_p : process (all)
        variable cand_v  : unsigned(QID_W -1 downto 0);
        variable found_v : std_logic;
    begin
        cand_v  := rd_qid_cntr;
        found_v := '0';

        -- Pass 1: rd_qid_cntr .. rd_ch_max_reg (no wrap)
        for q in 0 to NUM_QUEUES -1 loop
            if (found_v = '0' and to_unsigned(q, QID_W) >= rd_qid_cntr
                and to_unsigned(q, QID_W) <= unsigned(rd_ch_max_reg)) then
                if (NVME_RD_REQ_RDY(q) = '1') then
                    cand_v  := to_unsigned(q, QID_W);
                    found_v := '1';
                end if;
            end if;
        end loop;

        -- Pass 2 (wrap): rd_ch_min_reg .. rd_ch_max_reg, only if pass 1 found nothing
        if (found_v = '0') then
            for q in 0 to NUM_QUEUES -1 loop
                if (found_v = '0' and to_unsigned(q, QID_W) >= unsigned(rd_ch_min_reg)
                    and to_unsigned(q, QID_W) <= unsigned(rd_ch_max_reg)) then
                    if (NVME_RD_REQ_RDY(q) = '1') then
                        cand_v  := to_unsigned(q, QID_W);
                        found_v := '1';
                    end if;
                end if;
            end loop;
        end if;

        rd_qid_cand     <= cand_v;
        rd_qid_cand_rdy <= found_v;
    end process;

    -- Advances by one queue every rd_burst accepted requests, wrapping rd_ch_max -> rd_ch_min.
    -- Tracks rd_qid_cand (the queue actually used, which may skip ahead) rather than the raw
    -- counter, so progress continues even when the nominal next queue is full.
    rd_qid_rr_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1') then
                rd_qid_cntr   <= (others => '0');
                rd_burst_cntr <= (others => '0');
            elsif (rd_req_accepted_s = '1') then
                if (rd_burst_cntr + 1 >= unsigned(rd_burst_reg)) then
                    rd_burst_cntr <= (others => '0');
                    if (rd_qid_cand >= unsigned(rd_ch_max_reg)) then
                        rd_qid_cntr <= resize(unsigned(rd_ch_min_reg), rd_qid_cntr'length);
                    else
                        rd_qid_cntr <= rd_qid_cand + 1;
                    end if;
                else
                    rd_burst_cntr <= rd_burst_cntr + 1;
                    rd_qid_cntr   <= rd_qid_cand;
                end if;
            end if;
        end if;
    end process;

    gen_rd_req_qid <= (others => '0') when (NUM_QUEUES = 1) else std_logic_vector(rd_qid_cand);
    checker_qid    <= (others => '0') when (NUM_QUEUES = 1) else rd_ch_min_reg;

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
                tst_sel_reg    <= (others => '0');
                tmsp_ovf_reg   <= '0';
                contig_test    <= '0';
                lat_meas_mode  <= '0';
            else
                if ((lat_meas_val_vld = '1') and (unsigned(lat_meas_val) >= (2**LOG_TIMESTAMP_WIDTH))) then
                    tmsp_ovf_reg <= '1';
                end if;

                if ((tst_sel_reg_sel = '1') and (mi_split_wr(0) = '1')) then
                    tst_sel_reg    <= mi_split_dwr(0)(1 downto 0);
                    tmsp_ovf_reg   <= mi_split_dwr(0)(2);
                    contig_test    <= mi_split_dwr(0)(3);
                    lat_meas_mode  <= mi_split_dwr(0)(4);
                end if;
            end if;
        end if;
    end process;

    -- Datapath steering: the integrity checker owns the WR/RD MFB and the read request when
    -- integ_en = '1'; otherwise the throughput generator drives them (behaviour unchanged).
    NVME_RD_REQ_LBA_PTR <= chk_rd_req_lba_ptr when (integ_en = '1') else
                           nvme_rd_req_lba_ptr_reg when (tst_finished = '1' and contig_test = '0') else
                           std_logic_vector(resize(std_logic_vector(tst_addr), NVME_RD_REQ_LBA_PTR'length));
    NVME_RD_REQ_LBA_NUM <= chk_rd_req_lba_num when (integ_en = '1') else nvme_rd_req_lba_num_reg;
    -- Latency mode allows one measured operation at a time: gating only on SQ room lets a run
    -- issue until the page pool empties without retiring its count, so tst_finished never
    -- asserts. Accept wins when accept/completion coincide.
    lat_start_event_s <= ((or NVME_WR_MFB_SOF) and NVME_WR_MFB_SRC_RDY and NVME_WR_MFB_DST_RDY) or
                         rd_req_accepted_s;

    lat_outstanding_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1' or data_logger_rst = '1') then
                lat_outstanding_r <= '0';
            elsif (lat_start_event_s = '1') then
                lat_outstanding_r <= '1';
            elsif (NVME_OP_STAT_VLD = '1') then
                lat_outstanding_r <= '0';
            end if;
        end if;
    end process;

    lat_wr_in_frame_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (DMA_RST = '1' or data_logger_rst = '1') then
                lat_wr_in_frame_r <= '0';
            elsif (NVME_WR_MFB_SRC_RDY = '1' and NVME_WR_MFB_DST_RDY = '1') then
                if ((or NVME_WR_MFB_EOF) = '1') then
                    lat_wr_in_frame_r <= '0';
                elsif ((or NVME_WR_MFB_SOF) = '1') then
                    lat_wr_in_frame_r <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Block ONLY a new frame's first beat. lat_wr_in_frame_r is set the cycle AFTER SOF, so
    -- gating on it stalls the beat after SOF and lets a frame start that cannot finish. Deciding
    -- from the offered beat's own SOF makes this pure frame admission.
    lat_wr_new_frame_s <= '1' when (lat_wr_in_frame_r = '0' and (or pip_nvme_wr_sof) = '1') else '0';

    lat_wr_issue_ok    <= '0' when (lat_meas_mode = '1' and lat_wr_new_frame_s = '1' and
                                    (lat_outstanding_r = '1' or unsigned(lat_meas_fifo_items) /= 0)) else '1';

    -- Both terms are needed: the register closes the accept-to-STATUS gap, the FIFO term holds
    -- issue off until the meter has actually drained the pair.
    lat_meas_issue_ok   <= '0' when (lat_meas_mode = '1' and (lat_outstanding_r = '1' or unsigned(lat_meas_fifo_items) /= 0)) else '1';

    -- One-hot on the queue QID names: the DMA's payload bus is shared, and it asserts both the
    -- one-hot property and the VLD/QID agreement in PSL.
    rd_req_vld_s        <= chk_rd_req_vld when (integ_en = '1')
                           else (gen_nvme_rd_req_vld and rd_qid_cand_rdy and lat_meas_issue_ok);
    nvme_rd_req_vld_oh_p : process (all) is
    begin
        NVME_RD_REQ_VLD <= (others => '0');
        NVME_RD_REQ_VLD(to_integer(unsigned(nvme_rd_req_qid_s))) <= rd_req_vld_s;
    end process;

    chk_rd_req_rdy      <= NVME_RD_REQ_RDY(to_integer(unsigned(nvme_rd_req_qid_s)));
    rd_req_accepted_s   <= rd_req_vld_s and chk_rd_req_rdy;
    -- Read-request QID: round-robin counter for the throughput generator, queue 0 / rd_ch_min for
    -- the checker; both are forced to 0 above when NUM_QUEUES = 1.
    nvme_rd_req_qid_s   <= checker_qid when (integ_en = '1') else gen_rd_req_qid;
    NVME_RD_REQ_QID     <= nvme_rd_req_qid_s;

    gen_wr_meta_lba <= nvme_wr_req_lba_ptr_reg when (tst_finished = '1' and contig_test = '0') else
                       std_logic_vector(resize(std_logic_vector(tst_addr), NVME_RD_REQ_LBA_PTR'length));

    -- Write meta per region: [QID (high QID_W bits) | LBA_PTR (low SQE_LBA_PTR_W bits)]. LBA is not
    -- region-indexed (single active address counter); only QID differs per region.
    nvme_wr_mfb_meta_g : for r in 0 to DMA_MFB_REGIONS -1 generate
        -- Pre-pipe meta, per region: [QID (high QID_W bits) | LBA_PTR (low SQE_LBA_PTR_W bits)].
        gen_wr_meta_full((r+1)*(SQE_LBA_PTR_W + QID_W) -1 downto r*(SQE_LBA_PTR_W + QID_W)) <=
            gen_nvme_wr_qid_mskd((r+1)*QID_W -1 downto r*QID_W) & gen_wr_meta_lba;

        NVME_WR_MFB_META((r+1)*(SQE_LBA_PTR_W + QID_W) -1 downto r*(SQE_LBA_PTR_W + QID_W)) <=
            (checker_qid & chk_wr_meta) when (integ_en = '1') else
            pip_wr_meta((r+1)*(SQE_LBA_PTR_W + QID_W) -1 downto r*(SQE_LBA_PTR_W + QID_W));
    end generate;

    -- Data is generated from the framing rather than carried through the reconfigurator, built
    -- from the PIPED SOF/EOF: wr_mfb_data_cnt_p counts on the write handshake, now this pipe's TX
    -- side, keeping counters and framing in step.
    NVME_WR_MFB_DATA    <= chk_wr_data when (integ_en = '1') else
                           gen_wr_mfb_data(wr_mfb_pkt_cnt_reg, wr_mfb_word_cnt_reg, pip_nvme_wr_sof, pip_nvme_wr_eof);
    NVME_WR_MFB_SOF     <= chk_wr_sof     when (integ_en = '1') else pip_nvme_wr_sof;
    NVME_WR_MFB_EOF     <= chk_wr_eof     when (integ_en = '1') else pip_nvme_wr_eof;
    NVME_WR_MFB_SOF_POS <= chk_wr_sof_pos when (integ_en = '1') else pip_nvme_wr_sof_pos;
    NVME_WR_MFB_EOF_POS <= chk_wr_eof_pos when (integ_en = '1') else pip_nvme_wr_eof_pos;
    NVME_WR_MFB_SRC_RDY <= chk_wr_src_rdy when (integ_en = '1') else (pip_nvme_wr_src_rdy and lat_wr_issue_ok);
    -- Stall the generator's writes while the checker owns the bus, at the pipe's TX side so
    -- back-pressure reaches the reconfigurator. The latency gate must reach TX_DST_RDY too:
    -- masking only SRC_RDY lets a never-presented beat advance, orphaning the EOF.
    pip_nvme_wr_dst_rdy <= (NVME_WR_MFB_DST_RDY and lat_wr_issue_ok) when (integ_en = '0') else '0';

    nvme_rd_mfb_dst_rdy_s <= chk_rd_mfb_dst_rdy when (integ_en = '1') else '1';
    NVME_RD_MFB_DST_RDY   <= nvme_rd_mfb_dst_rdy_s;

    integrity_checker_i : entity work.IUVENTUS_INTEGRITY_CHECKER
    generic map (
        MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,
        SECT_SIZE       => 512,
        LBA_PTR_W       => 64
    )
    port map (
        CLK => DMA_CLK,
        RST => DMA_RST,

        CTL_START     => integ_start,
        CTL_LBA_BASE  => integ_lba_base_reg,
        CTL_LBA_COUNT => integ_lba_count_reg,

        STS_BUSY          => chk_busy,
        STS_DONE          => chk_done,
        STS_ERR_CNT       => chk_err_cnt,
        STS_ERR_FIRST_LBA => chk_err_lba,
        STS_ERR_FIRST_EXP => chk_err_exp,
        STS_ERR_FIRST_GOT => chk_err_got,

        STS_STATE      => chk_state,
        STS_BEAT_IDX   => chk_beat_idx,
        STS_OPSTAT_CNT => chk_opstat_cnt,
        STS_OP_ERR     => chk_op_err,

        WR_MFB_DATA    => chk_wr_data,
        WR_MFB_META    => chk_wr_meta,
        WR_MFB_SOF     => chk_wr_sof,
        WR_MFB_EOF     => chk_wr_eof,
        WR_MFB_SOF_POS => chk_wr_sof_pos,
        WR_MFB_EOF_POS => chk_wr_eof_pos,
        WR_MFB_SRC_RDY => chk_wr_src_rdy,
        WR_MFB_DST_RDY => NVME_WR_MFB_DST_RDY,

        RD_REQ_LBA_PTR => chk_rd_req_lba_ptr,
        RD_REQ_LBA_NUM => chk_rd_req_lba_num,
        RD_REQ_VLD     => chk_rd_req_vld,
        RD_REQ_RDY     => chk_rd_req_rdy,

        OP_STAT_VLD    => NVME_OP_STAT_VLD,
        OP_STAT_CODE   => NVME_OP_STAT_CODE,

        RD_MFB_DATA    => NVME_RD_MFB_DATA,
        RD_MFB_SOF     => NVME_RD_MFB_SOF,
        RD_MFB_EOF     => NVME_RD_MFB_EOF,
        RD_MFB_SRC_RDY => NVME_RD_MFB_SRC_RDY,
        RD_MFB_DST_RDY => chk_rd_mfb_dst_rdy
    );

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
                when x"00" => mi_split_drd(0)(1 downto 0)                                    <= chk_rd_req_rdy & rd_req_vld_s;
                when x"04" => mi_split_drd(0)                                                <= nvme_rd_req_lba_ptr_reg(31 downto 0);
                when x"08" => mi_split_drd(0)                                                <= nvme_rd_req_lba_ptr_reg(63 downto 32);
                when x"0C" => mi_split_drd(0)(7 downto 0)                                    <= nvme_rd_req_lba_num_reg;
                when x"10" => mi_split_drd(0)                                                <= nvme_wr_req_lba_ptr_reg(31 downto 0);
                when x"14" => mi_split_drd(0)                                                <= nvme_wr_req_lba_ptr_reg(63 downto 32);
                when x"18" => mi_split_drd(0)(op_stat_reg'range)                             <= op_stat_reg;
                when x"1C" => mi_split_drd(0)                                                <= tst_iterations_reg;
                -- lat_meas_mode (bit 4) MUST be read-backable: the software sets it with a
                -- read-modify-write set_bit(), and it is the only way to confirm QD1 mode engaged.
                when x"20" => mi_split_drd(0)(4 downto 0)                                    <= lat_meas_mode & contig_test & tmsp_ovf_reg & tst_sel_reg;
                when x"24" => mi_split_drd(0)(evcr_interval_cycles_reg'length - 1 downto 0)  <= evcr_interval_cycles_reg;
                when x"28" => mi_split_drd(0)(evcr_total_events_reg'length - 1 downto 0)     <= evcr_total_events_reg;
                when x"2C" => mi_split_drd(0)(evcr_total_cycles_reg'length - 1 downto 0)     <= evcr_total_cycles_reg;
                when x"30" => mi_split_drd(0)(1)                                             <= integ_en;
                when x"34" => mi_split_drd(0)                                                <= integ_lba_base_reg(31 downto 0);
                when x"38" => mi_split_drd(0)                                                <= integ_lba_base_reg(63 downto 32);
                when x"3C" => mi_split_drd(0)                                                <= integ_lba_count_reg;
                -- STATUS: [0]=busy [1]=done [2]=op_err(sweep aborted on OOR/failure) [6:4]=FSM state
                --         [15:8]=beat_idx [23:16]=OP_STAT_VLD count
                when x"40" => mi_split_drd(0) <= X"00" & chk_opstat_cnt & chk_beat_idx & '0' & chk_state & '0' & chk_op_err & chk_done & chk_busy;
                when x"44" => mi_split_drd(0)                                                <= chk_err_cnt;
                when x"48" => mi_split_drd(0)                                                <= chk_err_lba(31 downto 0);
                when x"4C" => mi_split_drd(0)                                                <= chk_err_lba(63 downto 32);
                when x"50" => mi_split_drd(0)                                                <= chk_err_exp;
                when x"54" => mi_split_drd(0)                                                <= chk_err_got;
                when x"58" => mi_split_drd(0)(QID_W -1 downto 0)                             <= rd_ch_min_reg;
                    mi_split_drd(0)(16 + QID_W -1 downto 16)                                 <= rd_ch_max_reg;
                when x"5C" => mi_split_drd(0)(15 downto 0)                                    <= rd_burst_reg;

                -- Command identities (RO). Bit 31 = "captured since reset", so a reader can tell a
                -- genuine CID/QID of 0 from a register that was never written.
                when x"60" =>
                    mi_split_drd(0)(CQ_ENTRY_CMD_ID_W -1 downto 0)          <= op_stat_cid_reg;
                    mi_split_drd(0)(16 + QID_W -1 downto 16)                <= op_stat_qid_reg;
                    mi_split_drd(0)(31)                                     <= op_stat_id_vld_reg;
                when x"64" =>
                    mi_split_drd(0)(CQ_ENTRY_CMD_ID_W -1 downto 0)          <= rd_req_cid_reg;
                    mi_split_drd(0)(31)                                     <= rd_req_cid_vld_reg;
                when x"68" =>
                    mi_split_drd(0)(CQ_ENTRY_CMD_ID_W -1 downto 0)          <= rd_mfb_cid_reg;
                    mi_split_drd(0)(16 + QID_W -1 downto 16)                <= rd_mfb_qid_reg;
                    mi_split_drd(0)(31)                                     <= rd_mfb_id_vld_reg;
                when others => mi_split_drd(0)                                               <= X"CAFEBABE";
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

        LENGTH_WIDTH   => GEN_LENGTH_WIDTH,
        CHANNELS_WIDTH => QID_W,

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
        TX_MFB_META    => gen_mfb_meta,
        TX_MFB_SOF     => gen_mfb_sof,
        TX_MFB_EOF     => gen_mfb_eof,
        TX_MFB_SOF_POS => gen_mfb_sof_pos,
        TX_MFB_EOF_POS => gen_mfb_eof_pos,
        TX_MFB_SRC_RDY => gen_mfb_src_rdy,
        TX_MFB_DST_RDY => gen_mfb_dst_rdy
    );

    -- Extract each region's channel field (target QID) from the generator's raw meta
    -- ([channel(high QID_W bits) | length(low GEN_LENGTH_WIDTH bits)]).
    gen_mfb_qid_extract_g : for r in 0 to DMA_MFB_REGIONS -1 generate
        gen_mfb_qid((r+1)*QID_W -1 downto r*QID_W) <=
                                                      gen_mfb_meta((r+1)*(QID_W + GEN_LENGTH_WIDTH) -1 downto (r+1)*(QID_W + GEN_LENGTH_WIDTH) - QID_W);
    end generate;

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

        META_WIDTH            => QID_W,
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
        RX_META    => gen_mfb_qid,
        RX_SOF     => gen_mfb_sof,
        RX_EOF     => gen_mfb_eof,
        RX_SOF_POS => gen_mfb_sof_pos,
        RX_EOF_POS => gen_mfb_eof_pos,
        RX_SRC_RDY => gen_mfb_src_rdy,
        RX_DST_RDY => gen_mfb_dst_rdy,

        TX_DATA    => open,
        TX_META    => gen_nvme_wr_qid,
        TX_SOF     => gen_nvme_wr_sof,
        TX_EOF     => gen_nvme_wr_eof,
        TX_SOF_POS => gen_nvme_wr_sof_pos,
        TX_EOF_POS => gen_nvme_wr_eof_pos,
        TX_SRC_RDY => gen_nvme_wr_src_rdy,
        TX_DST_RDY => gen_nvme_wr_dst_rdy
    );

    -- QID threaded alongside the write frame through the reconfigurator; forced to 0 when
    -- NUM_QUEUES = 1 so the single-queue behaviour is unchanged regardless of the generator's
    -- (unconfigured) channel default.
    gen_nvme_wr_qid_mskd <= (others => '0') when (NUM_QUEUES = 1) else gen_nvme_wr_qid;

    -- Registered stage on the reconfigurator's TX side. RX_DATA is tied off and TX_DATA left open
    -- since this path carries framing and meta only, so synthesis trims the data registers.
    -- "REG" registers the DST_RDY direction -- the tight timing path.
    mfb_wr_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => DMA_MFB_REGIONS,
        REGION_SIZE => DMA_MFB_REGION_SIZE,
        BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
        ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,
        META_WIDTH  => SQE_LBA_PTR_W + QID_W,
        FAKE_PIPE   => false,
        USE_DST_RDY => true,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => DMA_CLK,
        RESET      => DMA_RST,

        RX_DATA    => (others => '0'),
        RX_META    => gen_wr_meta_full,
        RX_SOF_POS => gen_nvme_wr_sof_pos,
        RX_EOF_POS => gen_nvme_wr_eof_pos,
        RX_SOF     => gen_nvme_wr_sof,
        RX_EOF     => gen_nvme_wr_eof,
        RX_SRC_RDY => gen_nvme_wr_src_rdy,
        RX_DST_RDY => gen_nvme_wr_dst_rdy,

        TX_DATA    => open,
        TX_META    => pip_wr_meta,
        TX_SOF_POS => pip_nvme_wr_sof_pos,
        TX_EOF_POS => pip_nvme_wr_eof_pos,
        TX_SOF     => pip_nvme_wr_sof,
        TX_EOF     => pip_nvme_wr_eof,
        TX_SRC_RDY => pip_nvme_wr_src_rdy,
        TX_DST_RDY => pip_nvme_wr_dst_rdy
    );

    -- ---- Latency measurement -- WARNING: presumes NVMe storage >= 512 GiB (sizes ADDR_CNTR_WIDTH) ----
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
        SUM_EN  => (others => TRUE),
        HIST_EN => (others => DLOGGER_HIST_EN),

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

        START_EVENT         => lat_start_event_s,
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
        tst_finished  <= '0';

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
                -- NVME_RD_REQ_LBA_NUM is 0-based (0 => 1 LBA); advance the sequential address by
                -- lba_num+1 so reads/writes stay contiguous (the SQE's NLB field stays 0-based;
                -- only the address step is corrected here).
                seq_addr_cntr <= seq_addr_cntr + resize(unsigned(nvme_rd_req_lba_num_reg), seq_addr_cntr'length) + 1;
            end if;
        end if;
    end process;

    tst_addr <= std_logic_vector(seq_addr_cntr) when tst_sel_reg(0) = '0' else lfsr_rand_addr_out;

    iops_cntr_i : entity work.EVENT_COUNTER
    generic map (
        MAX_INTERVAL_CYCLES   => EVCR_MAX_INTERVAL_CYCLES,
        MAX_CONCURRENT_EVENTS => 1,
        -- ~30-bit accumulator: one DSP48E2 instead of a carry chain on the 250 MHz DMA_CLK.
        -- Opt-in, so no other card's EVENT_COUNTER instance is affected.
        DSP_ACCUM             => TRUE
    )
    port map (
        CLK   => DMA_CLK,
        RESET => DMA_RST,

        INTERVAL_CYCLES => evcr_interval_cycles_reg,
        INTERVAL_SET    => evcr_interval_set,

        EVENT_CNT => (others => '1'),
        EVENT_VLD => evcr_event_vld,

        TOTAL_EVENTS => evcr_total_events,
        TOTAL_CYCLES => evcr_total_cycles,
        TOTAL_UPDATE => evcr_update
    );

    -- Count SUCCESSFUL COMPLETIONS, not accepted requests, against EVENT_COUNTER's own
    -- TOTAL_CYCLES so the IOPS carries no host-timing bias. Counting ACCEPTS gives an issue rate,
    -- which keeps counting even if the DMA's completion pipeline stalls.
    evcr_event_vld <= '1' when (NVME_OP_STAT_VLD = '1' and NVME_OP_STAT_CODE = OP_STAT_SUCCESS) else '0';

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
    -- psl default clock is rising_edge(DMA_CLK);

    -- In latency mode at most one operation may be outstanding: the meter pairs positionally, so
    -- a second concurrent start would be matched against the first completion.
    -- psl LAT_MEAS_SINGLE_OUTSTANDING :
    --      assert always ((DMA_RST or data_logger_rst) = '0' -> (lat_meas_mode = '0' or unsigned(lat_meas_fifo_items) <= 1))
    --      report "USER_CORE: more than one operation outstanding during a latency measurement -- the meter pairs positionally and would report a wrong latency";

    -- The gate must never be the reason a NON-measurement run stalls.
    -- psl LAT_MEAS_GATE_IDLE_WHEN_OFF :
    --      assert always (DMA_RST = '0' -> (lat_meas_mode = '1' or lat_meas_issue_ok = '1'))
    --      report "USER_CORE: the latency serialisation gate engaged outside latency mode";

    -- psl LAT_MEAS_COVER_GATED : cover {lat_meas_issue_ok = '0'};

    -- The write gate must never withhold mid-frame: that would stall a partially transferred frame.
    -- psl LAT_MEAS_WR_GATE_NOT_MIDFRAME :
    --      assert always (DMA_RST = '0' -> (lat_wr_in_frame_r = '0' or lat_wr_issue_ok = '1'))
    --      report "USER_CORE: the latency write gate withheld SRC_RDY mid-frame";

    -- psl LAT_MEAS_WR_GATE_IDLE_WHEN_OFF :
    --      assert always (DMA_RST = '0' -> (lat_meas_mode = '1' or lat_wr_issue_ok = '1'))
    --      report "USER_CORE: the latency write gate engaged outside latency mode";

    -- psl LAT_MEAS_COVER_WR_GATED : cover {lat_wr_issue_ok = '0'};

end architecture;
