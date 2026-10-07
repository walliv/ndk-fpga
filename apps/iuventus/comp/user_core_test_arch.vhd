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
use work.iuventus_sizing_pkg.all;

architecture TEST of USER_CORE is

    -- MFB_GENERATOR_MI32 needs more than one block per region, each dividing its 384-bit header, so
    -- the generator and the reconfigurator behind it split every DMA block into this many.
    constant GEN_BLOCK_SPLIT    : natural := 4;
    constant DLOGGER_HIST_EN    : boolean := FALSE;
    -- Queue-Identifier width for round-robin distribution across DMA queues. At NUM_QUEUES = 1,
    -- QID_W collapses to 1 bit but every QID-related signal below is explicitly forced to 0,
    -- reproducing today's single-queue behaviour bit-for-bit.
    constant QID_W              : natural := maximum(1, log2(NUM_QUEUES));

    -- Core-side halves of the DMA interfaces; user_core_if_pipe_i sits between these and the ports.
    signal core_rst             : std_logic;
    signal core_rd_req_lba_ptr  : std_logic_vector(SQE_LBA_PTR_W-1 downto 0);
    signal core_rd_req_lba_num  : std_logic_vector(7 downto 0);
    signal core_rd_req_rdy      : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal core_rd_req_cid      : std_logic_vector(CQ_ENTRY_CMD_ID_W-1 downto 0);
    signal core_rd_req_cid_vld  : std_logic;
    signal core_op_stat_type    : std_logic;
    signal core_op_stat_code    : std_logic_vector(1 downto 0);
    signal core_op_stat_qid     : std_logic_vector(QID_W-1 downto 0);
    signal core_op_stat_cid     : std_logic_vector(CQ_ENTRY_CMD_ID_W-1 downto 0);
    signal core_op_stat_vld     : std_logic;
    -- One read stream per DMA endpoint, each carrying only the queues that endpoint serves.
    signal core_rd_mfb_data     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
    signal core_rd_mfb_meta     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(DMA_MFB_REGIONS*(QID_W + CQ_ENTRY_CMD_ID_W)-1 downto 0);
    signal core_rd_mfb_sof      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(DMA_MFB_REGIONS-1 downto 0);
    signal core_rd_mfb_eof      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(DMA_MFB_REGIONS-1 downto 0);
    signal core_rd_mfb_sof_pos  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(DMA_MFB_REGIONS*maximum(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
    signal core_rd_mfb_eof_pos  : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)-1 downto 0);
    signal core_rd_mfb_src_rdy  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal core_rd_mfb_dst_rdy  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal core_wr_mfb_data     : std_logic_vector(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
    signal core_wr_mfb_meta     : std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + QID_W)-1 downto 0);
    signal core_wr_mfb_sof      : std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
    signal core_wr_mfb_eof      : std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
    signal core_wr_mfb_sof_pos  : std_logic_vector(DMA_MFB_REGIONS*maximum(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
    signal core_wr_mfb_eof_pos  : std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)-1 downto 0);
    signal core_wr_mfb_src_rdy  : std_logic;
    signal core_wr_mfb_dst_rdy  : std_logic;

    -- Register stages on each interface, and the per-queue request buffer backing the credits.
    constant IF_PIPE_STAGES     : natural := 4;
    constant IF_PIPE_REQ_ITEMS  : natural := 16;
    -- Its own hierarchy: flattened, synthesis folds engine logic into cells named under the pipeline,
    -- which the user core's pblock leaves out, and the placer drags them to the pipeline's far stages.
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of user_core_if_pipe_i : label is "soft";
    -- LENGTH_WIDTH used by the write-side throughput generator (mirrors the value passed to
    -- MFB_GENERATOR_MI32 below); needed only to size/slice the raw generator TX_MFB_META.
    constant GEN_LENGTH_WIDTH   : natural := 18;

    constant ADDR_LENGTH        : natural := 8;   -- decode 0x00..0xFC (integrity regs live at 0x30..0x54)
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
    signal seq_addr_sel_reg_sel             : std_logic;
    signal rd_hold_period_reg_sel           : std_logic;
    signal rd_hold_len_reg_sel              : std_logic;

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

    -- Periodic RD MFB hold (stress knob, 0x80 period / 0x84 length in DMA_CLK cycles): read
    -- streams are refused for the first LEN cycles of every PERIOD, so completed reads pile up in
    -- WRBUFF, then drain at full rate. PERIOD = 0 disables it.
    signal rd_hold_period_reg : unsigned(31 downto 0);
    signal rd_hold_len_reg    : unsigned(31 downto 0);
    signal rd_hold_cnt_r      : unsigned(31 downto 0);
    signal rd_hold_r          : std_logic;

    -- Read-side QID round-robin: min/max queue and burst count (requests per queue before advancing),
    -- mirroring MFB_GENERATOR_MI32. Default (0,0) keeps reads on queue 0 until software sets the range.
    signal rd_ch_min_reg     : std_logic_vector(QID_W -1 downto 0);
    signal rd_ch_max_reg     : std_logic_vector(QID_W -1 downto 0);
    signal rd_burst_reg      : std_logic_vector(15 downto 0);
    -- Which queue's sequential address counter the readback at 0x6C shows. Debug only:
    -- the counter is ADDR_CNTR_WIDTH bits, so a sequential stream repeats its LBA range
    -- once it wraps, and only a live readback says where in that cycle a run sits.
    signal rd_qid_cntr       : unsigned(QID_W -1 downto 0);
    signal rd_burst_cntr     : unsigned(15 downto 0);
    -- Round-robin QID for the read-request submit interface; forced to 0 when NUM_QUEUES = 1.
    signal gen_rd_req_qid    : std_logic_vector(QID_W -1 downto 0);
    -- Next ready queue at/after rd_qid_cntr in [rd_ch_min_reg, rd_ch_max_reg] (from
    -- rd_qid_select_p), skipping full queues: the DMA accepts one request at a time, so
    -- presenting a full queue would stall every other queue too.
    signal rd_qid_cand       : unsigned(QID_W -1 downto 0);
    -- '1' when rd_qid_cand is actually ready (some queue in [min,max] currently has room); '0'
    -- when every queue in range is full -- gates NVME_RD_REQ_VLD off so the generator holds
    -- instead of presenting a request to a queue that would just stall.
    signal rd_qid_cand_rdy   : std_logic;
    -- Scalar view of the per-queue read handshake, so the generator/checker logic below stays
    -- queue-agnostic: request offered, and the RDY bit of the queue QID names.
    signal rd_req_vld_s      : std_logic;
    signal rd_req_accepted_s : std_logic;
    signal chk_rd_req_rdy    : std_logic;
    signal nvme_rd_req_qid_s : std_logic_vector(QID_W -1 downto 0);
    -- QID that the integrity checker's write/read requests are tagged with (queue 0 / rd_ch_min);
    -- forced to 0 when NUM_QUEUES = 1.
    signal checker_qid       : std_logic_vector(QID_W -1 downto 0);
    -- Endpoint serving checker_qid, hence which read stream carries the checker's data. Software
    -- may retarget the checker at run time, so this is a live mux select, not a constant.
    signal checker_ep_s      : natural range 0 to PCIE_ENDPOINTS -1;

    -- MFB Generator outputs
    signal gen_mfb_sof     : std_logic_vector(NVME_WR_MFB_SOF'range);
    signal gen_mfb_eof     : std_logic_vector(NVME_WR_MFB_EOF'range);
    signal gen_mfb_sof_pos : std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*GEN_BLOCK_SPLIT) -1 downto 0);
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
    type   wr_meta_lba_arr_t is array (0 to DMA_MFB_REGIONS -1) of std_logic_vector(SQE_LBA_PTR_W -1 downto 0);
    signal gen_wr_meta_lba       : wr_meta_lba_arr_t;

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

        for byte_idx in 0 to (core_wr_mfb_data'length/8) - 1 loop
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

    -- Wide enough to address every LBA of the attached namespace, so a sequential stream walks
    -- the whole device instead of repeatedly rewriting one region.
    constant ADDR_CNTR_WIDTH          : natural := 33;
    -- LBAs in the namespace: Samsung 990 PRO 4 TB at 512 B/sector -- lower for a smaller drive. A
    -- past-end LBA is an I/O error, not a slow access. Built by shift: 7_814_037_168 exceeds a
    -- 32-bit signed VHDL literal (Vivado rejects it; nvc doesn't).
    constant TST_LBA_COUNT            : unsigned(ADDR_CNTR_WIDTH -1 downto 0) := shift_left(to_unsigned(488377323, ADDR_CNTR_WIDTH), 4);
    -- Sector size the namespace is formatted with. The write generator is configured in bytes,
    -- so its frame length converts to a count of LBAs by this.
    constant SECT_SIZE_B              : natural := 512;
    -- The SSD maps 4 KiB units, so a request straddling two of them is split and serialised by it.
    -- Test addresses keep these low bits clear; TST_LBA_COUNT is a multiple of the unit, so folds keep them too.
    constant LBA_ALIGN_W              : natural := log2(4096/SECT_SIZE_B);
    -- The sequential counter in whole drive units, one bit wider for the carry of rounding up.
    constant SEQ_UP_W                 : natural := ADDR_CNTR_WIDTH - LBA_ALIGN_W;
    constant SEQ_UP_FOLD0             : unsigned(SEQ_UP_W downto 0) := to_unsigned(0, SEQ_UP_W + 1)
                                                                       - resize(TST_LBA_COUNT(ADDR_CNTR_WIDTH -1 downto LBA_ALIGN_W), SEQ_UP_W + 1);
    constant SEQ_UP_FOLD1             : unsigned(SEQ_UP_W downto 0) := SEQ_UP_FOLD0 + 1;
    -- Random starts fold short of the namespace end by the largest request, so none of them runs past it.
    constant RAND_LBA_SPAN            : unsigned(ADDR_CNTR_WIDTH -1 downto 0) := TST_LBA_COUNT - 2**core_rd_req_lba_num'length;
    -- Widths of one write frame's LBA count (length/SECT_SIZE_B) and of a cycle's whole advance
    -- (one read plus one write per region), so a single ADDR_CNTR_WIDTH carry chain separates
    -- seq_addr_cntr from its D input.
    constant WR_LBA_CNT_W             : natural := GEN_LENGTH_WIDTH - log2(SECT_SIZE_B) + 1;
    constant SEQ_DELTA_W              : natural := log2(2**core_rd_req_lba_num'length
                                                        + DMA_MFB_REGIONS*2**(WR_LBA_CNT_W -1) + 1);
    -- Every advance one cycle can apply to a queue: k accepted write frames (0..DMA_MFB_REGIONS,
    -- all of one length) and j accepted reads (0..1), candidate k*2+j.
    constant SEQ_CANDS                : natural := (DMA_MFB_REGIONS + 1)*2;

    -- QID_W is log2 rounded up, so at NUM_QUEUES = 1 or 3 a QID value can name a queue that does
    -- not exist. Indexing a per-queue array with it directly would be an out-of-range fatal.
    function seq_idx_f (q : unsigned) return natural is
    begin
        if (to_integer(q) > NUM_QUEUES -1) then
            return 0;
        end if;
        return to_integer(q);
    end function;
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
    -- Registered "the meter still holds a pair". lat_wr_issue_ok fans out to every SRL enable of
    -- the write pipe, so the meter's own FIFO status must not reach that net directly -- one net
    -- from the meter to the pipe cannot make both hops in a period.
    signal lat_meas_fifo_ne_r   : std_logic;
    signal lat_wr_new_frame_s   : std_logic;
    -- The meter's own START_EVENT, shared with the interlock so both count the same thing.
    signal lat_start_event_s    : std_logic;
    signal tst_trigg            : std_logic;
    signal tst_iterations_reg   : std_logic_vector(31 downto 0);
    signal tst_sel_reg          : std_logic_vector(1 downto 0);
    signal tst_finished         : std_logic;
    signal tst_addr             : std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);
    -- One sequential address per queue: a single shared counter would advance only on completion,
    -- so at low queue counts issuance outruns it and many in-flight commands carry the SAME LBA,
    -- collapsing sequential throughput.
    type   seq_addr_cntr_arr_t is array (0 to NUM_QUEUES -1) of unsigned(ADDR_CNTR_WIDTH -1 downto 0);
    type   tst_addr_arr_t is array (0 to NUM_QUEUES -1) of std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);
    signal seq_addr_cntr        : seq_addr_cntr_arr_t;
    -- The accepts arrive late through the queue scan, the credits and the write pipe, so they only
    -- select among next values built from registers: each candidate's advance, and it minus
    -- TST_LBA_COUNT.
    type   seq_ofs_arr_t is array (0 to SEQ_CANDS -1) of unsigned(SEQ_DELTA_W -1 downto 0);
    type   seq_ofs_fold_arr_t is array (0 to SEQ_CANDS -1) of unsigned(ADDR_CNTR_WIDTH downto 0);
    type   seq_cand_q_t is array (0 to SEQ_CANDS -1) of unsigned(ADDR_CNTR_WIDTH -1 downto 0);
    type   seq_cand_arr_t is array (0 to NUM_QUEUES -1) of seq_cand_q_t;
    type   seq_sel_arr_t is array (0 to NUM_QUEUES -1) of natural range 0 to SEQ_CANDS -1;
    signal rd_lba_inc_nxt       : unsigned(core_rd_req_lba_num'length downto 0);
    signal seq_ofs_r            : seq_ofs_arr_t;
    signal seq_ofs_fold_r       : seq_ofs_fold_arr_t;
    signal seq_cand             : seq_cand_arr_t;
    signal seq_sel              : seq_sel_arr_t;
    signal seq_load             : std_logic;
    signal seq_en               : std_logic;
    -- A point starts where the previous one stopped, so each queue's counter is rounded up to a drive
    -- unit: registered, and taken as the no-accept candidate so an accept still only selects.
    signal seq_align_set        : std_logic;
    signal seq_align_pend       : std_logic_vector(NUM_QUEUES -1 downto 0);
    signal seq_up               : seq_addr_cntr_arr_t;
    -- Which queue's sequential address counter the 0x74/0x78 readback shows (debug): the counter
    -- wraps, and only a live readback says where in its cycle a run sits.
    signal seq_addr_sel_reg     : std_logic_vector(7 downto 0);
    signal seq_addr_sel_vld     : std_logic;
    signal seq_addr_idx         : natural range 0 to NUM_QUEUES -1;
    signal seq_addr_view        : std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);
    signal tst_addr_q           : tst_addr_arr_t;

    -- Random stream: a 64-bit LFSR, the address from its low bits (32 would cap it at 2 TiB). Each
    -- accept takes its own draw: slot 0 the read, slot r+1 write region r, one of each per cycle.
    constant RAND_SLOTS         : natural := 1 + DMA_MFB_REGIONS;
    -- Steps between draws: a whole register, so consecutive draws share no state bit.
    constant LFSR_LEAP          : natural := 64;
    constant LFSR_SEED          : std_logic_vector(63 downto 0) := "0000110101100111000010000110101100001101011001110000100001101011";
    -- An affine map of the state over GF(2): element i is state bit i's mask, bit 64 its constant.
    type     lfsr_map_t is array (0 to 63) of std_logic_vector(64 downto 0);
    type     lfsr_leap_arr_t is array (1 to RAND_SLOTS) of lfsr_map_t;
    type     lfsr_slot_arr_t is array (0 to RAND_SLOTS -1) of std_logic_vector(63 downto 0);
    type     lfsr_cand_arr_t is array (0 to 2*RAND_SLOTS -1) of std_logic_vector(63 downto 0);
    type     rand_draw_arr_t is array (0 to RAND_SLOTS -1) of std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);
    type     wr_addr_arr_t is array (0 to DMA_MFB_REGIONS -1) of std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);

    -- One step of LFSR_SIMPLE_RANDOM_GEN at DATA_WIDTH 64 (XNOR taps 64, 63, 61, 60), which this
    -- register replaced: that component steps at most once a cycle.
    function lfsr_step_f (s : std_logic_vector(63 downto 0)) return std_logic_vector is
    begin
        return s(62 downto 0) & (s(63) xnor s(62) xnor s(60) xnor s(59));
    end function;

    function lfsr_steps_f (s : std_logic_vector(63 downto 0); steps : natural) return std_logic_vector is
        variable ret : std_logic_vector(63 downto 0) := s;
    begin
        for t in 1 to steps loop
            ret := lfsr_step_f(ret);
        end loop;
        return ret;
    end function;

    -- The map of `steps` steps: the identity map stepped symbolically, so the taps alone define it.
    function lfsr_map_f (steps : natural) return lfsr_map_t is
        variable map_v : lfsr_map_t;
        variable fb_v  : std_logic_vector(64 downto 0);
    begin
        for i in 0 to 63 loop
            map_v(i)    := (others => '0');
            map_v(i)(i) := '1';
        end loop;
        for t in 1 to steps loop
            -- XNOR of the four taps is their XOR inverted once.
            fb_v     := map_v(63) xor map_v(62) xor map_v(60) xor map_v(59);
            fb_v(64) := not fb_v(64);
            map_v    := fb_v & map_v(0 to 62);
        end loop;
        return map_v;
    end function;

    function lfsr_leaps_f return lfsr_leap_arr_t is
        variable ret : lfsr_leap_arr_t;
    begin
        for j in 1 to RAND_SLOTS loop
            ret(j) := lfsr_map_f(LFSR_LEAP*j);
        end loop;
        return ret;
    end function;

    -- M^(64*j) for j = 1..RAND_SLOTS.
    constant LFSR_LEAPS         : lfsr_leap_arr_t := lfsr_leaps_f;

    function lfsr_apply_f (map_v : lfsr_map_t; s : std_logic_vector(63 downto 0)) return std_logic_vector is
        variable ret : std_logic_vector(63 downto 0);
    begin
        for i in 0 to 63 loop
            ret(i) := map_v(i)(64) xor (xor (map_v(i)(63 downto 0) and s));
        end loop;
        return ret;
    end function;

    function lfsr_slots_init_f return lfsr_slot_arr_t is
        variable ret : lfsr_slot_arr_t;
    begin
        ret(0) := LFSR_SEED;
        for k in 1 to RAND_SLOTS -1 loop
            ret(k) := lfsr_apply_f(LFSR_LEAPS(k), LFSR_SEED);
        end loop;
        return ret;
    end function;

    constant LFSR_SLOTS_INIT    : lfsr_slot_arr_t := lfsr_slots_init_f;

    -- Slot k holds the state k draws on, so every draw an accept takes is a flop.
    signal rand_slot_r          : lfsr_slot_arr_t := LFSR_SLOTS_INIT;
    -- Slot 0: the stream's state, the draw a read takes.
    signal lfsr_r               : std_logic_vector(63 downto 0);
    -- The state i draws on, i = 0..2*RAND_SLOTS-1: slots, then the last slot leapt on.
    signal lfsr_cand            : lfsr_cand_arr_t;
    signal lfsr_adv             : natural range 0 to RAND_SLOTS;
    signal rand_draw            : rand_draw_arr_t;
    signal tst_addr_wr          : wr_addr_arr_t;

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
    signal chk_wr_data        : std_logic_vector(core_wr_mfb_data'range);
    -- LBA-only meta (matches IUVENTUS_INTEGRITY_CHECKER's fixed LBA_PTR_W=64 WR_MFB_META port);
    -- the QID (checker_qid) is appended separately when assembling core_wr_mfb_meta below.
    signal chk_wr_meta        : std_logic_vector(63 downto 0);
    signal chk_wr_sof         : std_logic_vector(core_wr_mfb_sof'range);
    signal chk_wr_eof         : std_logic_vector(core_wr_mfb_eof'range);
    signal chk_wr_sof_pos     : std_logic_vector(core_wr_mfb_sof_pos'range);
    signal chk_wr_eof_pos     : std_logic_vector(core_wr_mfb_eof_pos'range);
    signal chk_wr_src_rdy     : std_logic;
    signal chk_rd_req_lba_ptr : std_logic_vector(63 downto 0);
    signal chk_rd_req_lba_num : std_logic_vector(7 downto 0);
    signal chk_rd_req_vld     : std_logic;
    signal chk_rd_mfb_dst_rdy : std_logic;

    -- Throughput-generator write path (formerly wired straight to the entity WR MFB outputs).
    signal gen_nvme_wr_sof     : std_logic_vector(core_wr_mfb_sof'range);
    signal gen_nvme_wr_eof     : std_logic_vector(core_wr_mfb_eof'range);
    signal gen_nvme_wr_sof_pos : std_logic_vector(core_wr_mfb_sof_pos'range);
    signal gen_nvme_wr_eof_pos : std_logic_vector(core_wr_mfb_eof_pos'range);
    signal gen_nvme_wr_src_rdy : std_logic;
    signal gen_nvme_wr_dst_rdy : std_logic;
    signal gen_nvme_rd_req_vld : std_logic;
    -- Per-region write-frame accept at mfb_wr_pipe_i's RX handshake. Per region because several
    -- regions of one word can each start a frame, each with its own QID.
    signal gen_nvme_wr_accept  : std_logic_vector(DMA_MFB_REGIONS -1 downto 0);
    -- Number of LBAs one generated write frame covers.
    signal wr_frame_lba_cnt    : unsigned(WR_LBA_CNT_W -1 downto 0);

    -- Registered stage between MFB_RECONFIGURATOR and the WR MFB outputs. Breaks the
    -- DMA-to-user-core critical path: core_wr_mfb_dst_rdy is driven combinationally from inside
    -- the DMA and was landing 20 logic levels later, WNS -1.246 ns.
    signal pip_nvme_wr_sof     : std_logic_vector(core_wr_mfb_sof'range);
    signal pip_nvme_wr_eof     : std_logic_vector(core_wr_mfb_eof'range);
    signal pip_nvme_wr_sof_pos : std_logic_vector(core_wr_mfb_sof_pos'range);
    signal pip_nvme_wr_eof_pos : std_logic_vector(core_wr_mfb_eof_pos'range);
    signal pip_nvme_wr_src_rdy : std_logic;
    signal pip_nvme_wr_dst_rdy : std_logic;
    -- Write meta rides THROUGH the pipe so the LBA stays aligned with its own frame: it is sourced
    -- from a separate address register, so leaving it unpiped would pair a delayed SOF with an
    -- already-advanced LBA.
    signal gen_wr_meta_full    : std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + QID_W) -1 downto 0);
    signal pip_wr_meta         : std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + QID_W) -1 downto 0);

    -- ---- Line-rate read-data checker (DATA_CHECK, see data_check_g) ------------------------------
    -- Pattern word: qid & sector & word index in the sector, MSB first, so a read proves its drive and block.
    function dc_pat_word_f (
        qid  : std_logic_vector;
        sec  : unsigned(47 downto 0);
        bis  : unsigned(2 downto 0);
        widx : unsigned(2 downto 0)
    ) return std_logic_vector is
    begin
        return std_logic_vector(resize(unsigned(qid), 4)) & std_logic_vector(sec) & "000000"
               & std_logic_vector(bis) & std_logic_vector(widx);
    end function;

    function dc_pat_beat_f (
        qid : std_logic_vector;
        sec : unsigned(47 downto 0);
        bis : unsigned(2 downto 0)
    ) return std_logic_vector is
        variable ret : std_logic_vector(511 downto 0);
    begin
        for k in 0 to 7 loop
            ret(64*k + 63 downto 64*k) := dc_pat_word_f(qid, sec, bis, to_unsigned(k, 3));
        end loop;
        return ret;
    end function;

    -- Tied off outside data_check_g, so the generator and address paths below stay as they were.
    signal dc_pat_wr_en   : std_logic;
    signal dc_wr_pat_data : std_logic_vector(core_wr_mfb_data'range);
    signal dc_addr_mask   : std_logic_vector(ADDR_CNTR_WIDTH -1 downto 0);
    signal dc_mi_drd      : std_logic_vector(MI_WIDTH -1 downto 0);

    attribute mark_debug : string;
    -- mark_debug preserves a net from optimisation; nothing consumes these since the ILA that
    -- probed them is commented out in src/ilas.xdc, and report_qor_assessment flags them on a bus
    -- already over budget. Re-enable together with ilas.xdc only.
    -- attribute mark_debug of core_rd_mfb_data    : signal is "true";
    -- attribute mark_debug of core_rd_mfb_sof     : signal is "true";
    -- attribute mark_debug of core_rd_mfb_eof     : signal is "true";
    -- attribute mark_debug of core_rd_mfb_sof_pos : signal is "true";
    -- attribute mark_debug of core_rd_mfb_eof_pos : signal is "true";
    -- attribute mark_debug of core_rd_mfb_src_rdy : signal is "true";
    -- attribute mark_debug of core_rd_mfb_dst_rdy : signal is "true";

    -- attribute mark_debug of tst_trigg        : signal is "true";
    -- attribute mark_debug of meas_fsm_pst     : signal is "true";
    -- attribute mark_debug of pkt_cnt_pst      : signal is "true";
    -- attribute mark_debug of tst_finished     : signal is "true";
    -- attribute mark_debug of tst_addr         : signal is "true";
    -- attribute mark_debug of core_op_stat_vld : signal is "true";
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
        RESET_S => core_rst,

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
        RESET => core_rst,

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
        seq_addr_sel_reg_sel                    <= '0';
        rd_hold_period_reg_sel                  <= '0';
        rd_hold_len_reg_sel                     <= '0';

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
            when x"70" => seq_addr_sel_reg_sel               <= '1';
            when x"80" => rd_hold_period_reg_sel             <= '1';
            when x"84" => rd_hold_len_reg_sel                <= '1';
            when others => null;
        end case;
    end process;

    op_stat_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                op_stat_reg <= (others => '0');
            elsif (core_op_stat_vld = '1') then
                op_stat_reg <= core_op_stat_vld & core_op_stat_type & core_op_stat_code;
            end if;
        end if;
    end process;

    -- OP_STAT identity. Captured on the same pulse as op_stat_reg above, so the two always
    -- describe the same completion.
    op_stat_id_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                op_stat_qid_reg    <= (others => '0');
                op_stat_cid_reg    <= (others => '0');
                op_stat_id_vld_reg <= '0';
            elsif (core_op_stat_vld = '1') then
                op_stat_qid_reg    <= core_op_stat_qid;
                op_stat_cid_reg    <= core_op_stat_cid;
                op_stat_id_vld_reg <= '1';
            end if;
        end if;
    end process;

    -- Tag the DMA assigned to the last accepted read.
    rd_req_cid_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                rd_req_cid_reg     <= (others => '0');
                rd_req_cid_vld_reg <= '0';
            elsif (core_rd_req_cid_vld = '1') then
                rd_req_cid_reg     <= core_rd_req_cid;
                rd_req_cid_vld_reg <= '1';
            end if;
        end if;
    end process;

    -- Identity of the frame currently landing on the ENDPOINT-0 read stream, which is the only
    -- one this debug register observes. Sampled at SOF of region 0 on a real transfer: META is
    -- only defined for a region carrying a frame start.
    rd_mfb_id_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                rd_mfb_qid_reg    <= (others => '0');
                rd_mfb_cid_reg    <= (others => '0');
                rd_mfb_id_vld_reg <= '0';
            elsif (core_rd_mfb_sof(0)(0) = '1' and core_rd_mfb_src_rdy(0) = '1'
                   and nvme_rd_mfb_dst_rdy_s = '1') then
                -- DMA_IUVENTUS lays RD_MFB_META out as CID & QID: the queue sits in the low bits.
                rd_mfb_qid_reg    <= core_rd_mfb_meta(0)(QID_W -1 downto 0);
                rd_mfb_cid_reg    <= core_rd_mfb_meta(0)(QID_W + CQ_ENTRY_CMD_ID_W -1 downto QID_W);
                rd_mfb_id_vld_reg <= '1';
            end if;
        end if;
    end process;

    rd_req_vld_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
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
            if (core_rst = '1') then
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
            if (core_rst = '1') then
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
            if (core_rst = '1') then
                rd_burst_reg <= std_logic_vector(to_unsigned(1, rd_burst_reg'length));
            elsif (rd_burst_reg_sel = '1' and mi_split_wr(0) = '1') then
                rd_burst_reg <= mi_split_dwr(0)(15 downto 0);
            end if;
        end if;
    end process;

    rd_hold_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                rd_hold_period_reg <= (others => '0');
                rd_hold_len_reg    <= (others => '0');
            elsif (mi_split_wr(0) = '1') then
                if (rd_hold_period_reg_sel = '1') then
                    rd_hold_period_reg <= unsigned(mi_split_dwr(0));
                end if;
                if (rd_hold_len_reg_sel = '1') then
                    rd_hold_len_reg <= unsigned(mi_split_dwr(0));
                end if;
            end if;
        end if;
    end process;

    rd_hold_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1' or rd_hold_period_reg = 0 or rd_hold_cnt_r + 1 >= rd_hold_period_reg) then
                rd_hold_cnt_r <= (others => '0');
            else
                rd_hold_cnt_r <= rd_hold_cnt_r + 1;
            end if;
            if (core_rst = '1' or rd_hold_period_reg = 0 or rd_hold_cnt_r >= rd_hold_len_reg) then
                rd_hold_r <= '0';
            else
                rd_hold_r <= '1';
            end if;
        end if;
    end process;

    -- Selected queue's counter, muxed outside the MI read path so the read mux stays a plain
    -- assignment and an index naming no built queue reads back invalid instead of aliasing onto
    -- queue 0.
    seq_addr_sel_vld <= '1' when (unsigned(seq_addr_sel_reg) < NUM_QUEUES) else '0';
    seq_addr_idx     <= to_integer(unsigned(seq_addr_sel_reg)) when seq_addr_sel_vld = '1' else 0;
    seq_addr_view    <= std_logic_vector(seq_addr_cntr(seq_addr_idx));

    seq_addr_sel_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                seq_addr_sel_reg <= (others => '0');
            elsif (seq_addr_sel_reg_sel = '1' and mi_split_wr(0) = '1') then
                seq_addr_sel_reg <= mi_split_dwr(0)(7 downto 0);
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
                if (core_rd_req_rdy(q) = '1') then
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
                    if (core_rd_req_rdy(q) = '1') then
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
            if (core_rst = '1') then
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
            if (core_rst = '1') then
                nvme_rd_req_lba_num_reg <= (others => '0');
            elsif ((nvme_rd_req_lba_num_reg_sel = '1') and (mi_split_wr(0) = '1')) then
                nvme_rd_req_lba_num_reg <= mi_split_dwr(0)(core_rd_req_lba_num'range);
            end if;
        end if;
    end process;

    rd_req_lba_ptr_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
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
            if (core_rst = '1') then
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
            if (core_rst = '1') then
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
            if (core_rst = '1') then
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
            if (core_rst = '1') then
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
    core_rd_req_lba_ptr <= chk_rd_req_lba_ptr when (integ_en = '1') else
                           nvme_rd_req_lba_ptr_reg when (tst_finished = '1' and contig_test = '0') else
                           std_logic_vector(resize(std_logic_vector(tst_addr), core_rd_req_lba_ptr'length));
    core_rd_req_lba_num <= chk_rd_req_lba_num when (integ_en = '1') else nvme_rd_req_lba_num_reg;
    -- Latency mode allows one op at a time: gating only on SQ room would let a run issue until the
    -- pool empties without retiring its count, so tst_finished never asserts. An accept beats a
    -- same-cycle completion (which belongs to the PREVIOUS op).
    lat_start_event_s   <= ((or core_wr_mfb_sof) and core_wr_mfb_src_rdy and core_wr_mfb_dst_rdy) or
                           rd_req_accepted_s;

    lat_outstanding_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1' or data_logger_rst = '1') then
                lat_outstanding_r <= '0';
            elsif (lat_start_event_s = '1') then
                lat_outstanding_r <= '1';
            elsif (core_op_stat_vld = '1') then
                lat_outstanding_r <= '0';
            end if;
        end if;
    end process;

    lat_wr_in_frame_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1' or data_logger_rst = '1') then
                lat_wr_in_frame_r <= '0';
            elsif (core_wr_mfb_src_rdy = '1' and core_wr_mfb_dst_rdy = '1') then
                if ((or core_wr_mfb_eof) = '1') then
                    lat_wr_in_frame_r <= '0';
                elsif ((or core_wr_mfb_sof) = '1') then
                    lat_wr_in_frame_r <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Block ONLY a new frame's first beat. lat_wr_in_frame_r is set the cycle AFTER SOF, so
    -- gating on it stalls the beat after SOF and lets a frame start that cannot finish. Deciding
    -- from the offered beat's own SOF makes this pure frame admission.
    lat_wr_new_frame_s <= '1' when (lat_wr_in_frame_r = '0' and (or pip_nvme_wr_sof) = '1') else '0';

    lat_meas_fifo_ne_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1' or data_logger_rst = '1') then
                lat_meas_fifo_ne_r <= '0';
            elsif (unsigned(lat_meas_fifo_items) /= 0) then
                lat_meas_fifo_ne_r <= '1';
            else
                lat_meas_fifo_ne_r <= '0';
            end if;
        end if;
    end process;

    -- lat_outstanding_r stays unregistered: it covers the cycle the FIFO status rises in, so the
    -- registered FIFO term can only release the gate late, never early. Registering it too would
    -- let a single-beat frame over-issue.
    lat_wr_issue_ok    <= '0' when (lat_meas_mode = '1' and lat_wr_new_frame_s = '1' and
                                    (lat_outstanding_r = '1' or lat_meas_fifo_ne_r = '1')) else
 '1';

    -- Both terms are needed: the register closes the accept-to-STATUS gap, the FIFO term holds
    -- issue off until the meter has actually drained the pair.
    lat_meas_issue_ok   <= '0' when (lat_meas_mode = '1' and (lat_outstanding_r = '1' or unsigned(lat_meas_fifo_items) /= 0)) else '1';

    -- One-hot on the queue QID names: the DMA's payload bus is shared, and it asserts both the
    -- one-hot property and the VLD/QID agreement in PSL.
    rd_req_vld_s        <= chk_rd_req_vld when (integ_en = '1') else
                           (gen_nvme_rd_req_vld and rd_qid_cand_rdy and lat_meas_issue_ok);
    chk_rd_req_rdy      <= core_rd_req_rdy(to_integer(unsigned(nvme_rd_req_qid_s)));
    rd_req_accepted_s   <= rd_req_vld_s and chk_rd_req_rdy;
    -- Read-request QID: round-robin counter for the throughput generator, queue 0 / rd_ch_min for
    -- the checker; both are forced to 0 above when NUM_QUEUES = 1.
    nvme_rd_req_qid_s   <= checker_qid when (integ_en = '1') else gen_rd_req_qid;

    -- Write meta per region: [QID (high QID_W bits) | LBA_PTR (low SQE_LBA_PTR_W bits)]. Each
    -- region carries its own QID, so it must take that queue's address -- one shared LBA would put
    -- every region of a beat on the same block.
    nvme_wr_mfb_meta_g : for r in 0 to DMA_MFB_REGIONS -1 generate
        -- A random write takes its region's own draw, never the one a same-cycle read takes.
        tst_addr_wr(r) <= (std_logic_vector(seq_addr_cntr(seq_idx_f(unsigned(
                              gen_nvme_wr_qid_mskd((r+1)*QID_W -1 downto r*QID_W))))) and dc_addr_mask)
                          when tst_sel_reg(0) = '0' else
                          (rand_draw(r + 1) and dc_addr_mask);

        gen_wr_meta_lba(r) <= nvme_wr_req_lba_ptr_reg when (tst_finished = '1' and contig_test = '0') else
                              std_logic_vector(resize(unsigned(tst_addr_wr(r)), core_rd_req_lba_ptr'length));

        gen_wr_meta_full((r+1)*(SQE_LBA_PTR_W + QID_W) -1 downto r*(SQE_LBA_PTR_W + QID_W)) <=
                                                                                               gen_nvme_wr_qid_mskd((r+1)*QID_W -1 downto r*QID_W) & gen_wr_meta_lba(r);

        core_wr_mfb_meta((r+1)*(SQE_LBA_PTR_W + QID_W) -1 downto r*(SQE_LBA_PTR_W + QID_W)) <=
            (checker_qid & chk_wr_meta) when (integ_en = '1') else
            pip_wr_meta((r+1)*(SQE_LBA_PTR_W + QID_W) -1 downto r*(SQE_LBA_PTR_W + QID_W));
    end generate;

    -- Data is generated from the framing rather than carried through the reconfigurator, built
    -- from the PIPED SOF/EOF: wr_mfb_data_cnt_p counts on the write handshake, now this pipe's TX
    -- side, keeping counters and framing in step.
    core_wr_mfb_data    <= chk_wr_data when (integ_en = '1') else
                           dc_wr_pat_data when (dc_pat_wr_en = '1') else
                           gen_wr_mfb_data(wr_mfb_pkt_cnt_reg, wr_mfb_word_cnt_reg, pip_nvme_wr_sof, pip_nvme_wr_eof);
    core_wr_mfb_sof     <= chk_wr_sof     when (integ_en = '1') else pip_nvme_wr_sof;
    core_wr_mfb_eof     <= chk_wr_eof     when (integ_en = '1') else pip_nvme_wr_eof;
    core_wr_mfb_sof_pos <= chk_wr_sof_pos when (integ_en = '1') else pip_nvme_wr_sof_pos;
    core_wr_mfb_eof_pos <= chk_wr_eof_pos when (integ_en = '1') else pip_nvme_wr_eof_pos;
    core_wr_mfb_src_rdy <= chk_wr_src_rdy when (integ_en = '1') else (pip_nvme_wr_src_rdy and lat_wr_issue_ok);
    -- Stall the generator's writes while the checker owns the bus, at the pipe's TX side so
    -- back-pressure reaches the reconfigurator. The latency gate must reach TX_DST_RDY too:
    -- masking only SRC_RDY lets a never-presented beat advance, orphaning the EOF.
    pip_nvme_wr_dst_rdy <= (core_wr_mfb_dst_rdy and lat_wr_issue_ok) when (integ_en = '0') else '0';

    checker_ep_s <= queue_ep_f(to_integer(unsigned(checker_qid)), NUM_QUEUES, PCIE_ENDPOINTS);

    -- The checker consumes one read at a time on the stream of ITS OWN queue; every other stream
    -- is simply accepted and discarded, exactly as the generator does with all of them, outside a
    -- periodic stress hold.
    rd_dst_rdy_g : for ep in 0 to PCIE_ENDPOINTS-1 generate
        core_rd_mfb_dst_rdy(ep) <= chk_rd_mfb_dst_rdy when (integ_en = '1' and checker_ep_s = ep) else
                                   not rd_hold_r;
    end generate;

    -- Endpoint 0's own ready, which is what rd_mfb_id_reg_p above qualifies its capture with.
    nvme_rd_mfb_dst_rdy_s <= core_rd_mfb_dst_rdy(0);

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
        RST => core_rst,

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
        WR_MFB_DST_RDY => core_wr_mfb_dst_rdy,

        RD_REQ_LBA_PTR => chk_rd_req_lba_ptr,
        RD_REQ_LBA_NUM => chk_rd_req_lba_num,
        RD_REQ_VLD     => chk_rd_req_vld,
        RD_REQ_RDY     => chk_rd_req_rdy,

        OP_STAT_VLD    => core_op_stat_vld,
        OP_STAT_CODE   => core_op_stat_code,

        RD_MFB_DATA    => core_rd_mfb_data(checker_ep_s),
        RD_MFB_SOF     => core_rd_mfb_sof(checker_ep_s),
        RD_MFB_EOF     => core_rd_mfb_eof(checker_ep_s),
        RD_MFB_SRC_RDY => core_rd_mfb_src_rdy(checker_ep_s),
        RD_MFB_DST_RDY => chk_rd_mfb_dst_rdy
    );

    wr_mfb_data_cnt_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                wr_mfb_pkt_cnt_reg  <= (others => '0');
                wr_mfb_word_cnt_reg <= (others => '0');
            elsif ((core_wr_mfb_src_rdy = '1') and (core_wr_mfb_dst_rdy = '1')) then
                if (unsigned(core_wr_mfb_eof) /= to_unsigned(0, core_wr_mfb_eof'length)) then
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

                -- Sequential-address readback (debug): 0x70 selects the queue, 0x74 shows its live
                -- LBA. Bit 31 of 0x74 flags a select naming no built queue, so queue 0's address
                -- isn't mistaken for it; only this readback says where a wrapped stream sits.
                when x"70" =>
                    mi_split_drd(0)(7 downto 0)                             <= seq_addr_sel_reg;
                when x"74" =>
                    mi_split_drd(0)                                         <= seq_addr_view(31 downto 0);
                -- The counter is wider than one MI register, so its top bits and the select-valid
                -- flag live here rather than aliasing onto bits of the address itself.
                when x"78" =>
                    mi_split_drd(0)(ADDR_CNTR_WIDTH -33 downto 0)           <= seq_addr_view(ADDR_CNTR_WIDTH -1 downto 32);
                    mi_split_drd(0)(31)                                     <= not seq_addr_sel_vld;
                when x"80" => mi_split_drd(0)                                               <= std_logic_vector(rd_hold_period_reg);
                when x"84" => mi_split_drd(0)                                               <= std_logic_vector(rd_hold_len_reg);
                -- Data-check registers; dc_mi_drd reads X"CAFEBABE" in a build without DATA_CHECK.
                when x"88" | x"8C" | x"90" | x"94" | x"98" | x"9C" | x"A0" | x"A4" | x"A8" | x"AC"
                     | x"B0" | x"B4" | x"B8" | x"BC" => mi_split_drd(0)                    <= dc_mi_drd;
                when others => mi_split_drd(0)                                               <= X"CAFEBABE";
            end case;
        end if;
    end process;

    mi_split_ardy(0) <= mi_split_rd(0) or mi_split_wr(0);

    drdy_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
                mi_split_drdy(0) <= '0';
            else
                mi_split_drdy(0) <= mi_split_rd(0);
            end if;
        end if;
    end process;

    mfb_generator_i : entity work.MFB_GENERATOR_MI32
    generic map (
        REGIONS     => DMA_MFB_REGIONS,
        REGION_SIZE => DMA_MFB_REGION_SIZE*GEN_BLOCK_SPLIT,
        BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE/GEN_BLOCK_SPLIT,
        ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,

        LENGTH_WIDTH   => GEN_LENGTH_WIDTH,
        CHANNELS_WIDTH => QID_W,

        PKT_CNT_WIDTH => 64,
        USE_PACP_ARCH => FALSE,
        DEVICE        => DEVICE
    )
    port map (
        CLK => DMA_CLK,
        RST => core_rst,

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
        RX_REGION_SIZE        => DMA_MFB_REGION_SIZE*GEN_BLOCK_SPLIT,
        RX_BLOCK_SIZE         => DMA_MFB_BLOCK_SIZE/GEN_BLOCK_SPLIT,
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
        RESET      => core_rst,

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
        RESET      => core_rst,

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
        RST => core_rst,

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
        RST => core_rst or data_logger_rst,

        START_EVENT         => lat_start_event_s,
        START_EVENT_META    => (others => '0'),
        END_EVENT           => core_op_stat_vld,
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
            if (core_rst = '1' or data_logger_rst = '1') then
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

                if (core_op_stat_vld = '1' and pkt_cnt_pst > 0) then
                    pkt_cnt_nst <= pkt_cnt_pst -1;
                end if;

                if (pkt_cnt_pst = 0 and unsigned(lat_meas_fifo_items) = 0) then
                    meas_fsm_nst <= S_IDLE;
                end if;
        end case;
    end process;

    -- Steps per accepted request: stepping per completion gave every read admitted between two
    -- completions one LBA. Candidates come from the slots alone; an accept only selects one.
    assert lfsr_apply_f(LFSR_LEAPS(1), LFSR_SEED) = lfsr_steps_f(LFSR_SEED, LFSR_LEAP)
        report "USER_CORE: the LFSR leap map disagrees with stepping the LFSR"
        severity failure;

    lfsr_slot_cand_g : for i in 0 to RAND_SLOTS -1 generate
        lfsr_cand(i) <= rand_slot_r(i);
    end generate;

    -- M^64 and M^128 take 4..9 state bits per output bit, at most two LUT levels.
    lfsr_leap_cand_g : for j in 1 to RAND_SLOTS generate
        lfsr_cand(RAND_SLOTS -1 + j) <= lfsr_apply_f(LFSR_LEAPS(j), rand_slot_r(RAND_SLOTS -1));
    end generate;

    lfsr_r <= rand_slot_r(0);

    -- Past the highest slot taken this cycle, so no draw is used twice. The draws are only used
    -- while seq_en is set; a manual request carries its own pointer and leaves the stream alone.
    lfsr_adv_p : process (all)
        variable adv_v : natural range 0 to RAND_SLOTS;
    begin
        adv_v := 0;
        if (rd_req_accepted_s = '1') then
            adv_v := 1;
        end if;
        for r in 0 to DMA_MFB_REGIONS -1 loop
            if (gen_nvme_wr_accept(r) = '1') then
                adv_v := r + 2;
            end if;
        end loop;
        if (seq_en = '0') then
            adv_v := 0;
        end if;
        lfsr_adv <= adv_v;
    end process;

    -- Each slot moves on by the draws taken; advancing by whole draws keeps them a draw apart.
    lfsr_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1' or data_logger_rst = '1') then
                rand_slot_r <= LFSR_SLOTS_INIT;
            else
                for k in 0 to RAND_SLOTS -1 loop
                    rand_slot_r(k) <= lfsr_cand(k + lfsr_adv);
                end loop;
            end if;
        end if;
    end process;

    -- A write frame takes its LBA from tst_addr_q when mfb_wr_pipe_i latches gen_wr_meta_full, so
    -- the address must advance on THAT handshake: the pipe holds two beats, and advancing at its
    -- TX side would admit a later frame on the stale address.
    wr_accept_g : for r in 0 to DMA_MFB_REGIONS -1 generate
        gen_nvme_wr_accept(r) <= gen_nvme_wr_sof(r) and gen_nvme_wr_src_rdy and gen_nvme_wr_dst_rdy;
    end generate;

    -- MFB_GENERATOR_MI32 publishes frame length only via meta ([channel|length], same register
    -- every region), in bytes; software sets it to (lba_num+1)*512, so length/512 is a 1-based
    -- LBA count, rounded up so a sub-sector frame still claims one LBA.
    wr_frame_lba_cnt <= resize(shift_right(resize(unsigned(gen_mfb_meta(GEN_LENGTH_WIDTH -1 downto 0)), GEN_LENGTH_WIDTH + 1)
                                           + (SECT_SIZE_B -1), log2(SECT_SIZE_B)), WR_LBA_CNT_W);

    -- Next cycle's 0-based lba_num plus one, built from the MI writes that update both of its
    -- sources, so seq_ofs_r holds the advance of exactly the read it is offered with.
    rd_lba_inc_nxt_p : process (all)
        variable integ_en_v : std_logic;
        variable lba_num_v  : std_logic_vector(core_rd_req_lba_num'range);
    begin
        integ_en_v := integ_en;
        lba_num_v  := nvme_rd_req_lba_num_reg;
        if (mi_split_wr(0) = '1' and integ_ctrl_reg_sel = '1') then
            integ_en_v := mi_split_dwr(0)(1);
        end if;
        if (mi_split_wr(0) = '1' and nvme_rd_req_lba_num_reg_sel = '1') then
            lba_num_v := mi_split_dwr(0)(core_rd_req_lba_num'range);
        end if;
        if (core_rst = '1') then
            integ_en_v := '0';
            lba_num_v  := (others => '0');
        end if;
        -- The checker's request size is a constant, so its next value is its current one.
        if (integ_en_v = '1') then
            lba_num_v := chk_rd_req_lba_num;
        end if;
        rd_lba_inc_nxt <= resize(unsigned(lba_num_v), rd_lba_inc_nxt'length) + 1;
    end process;

    -- A write's length is the generator's length register, sampled while the accepted frame itself
    -- still sits in the reconfigurator's FIFO, so taking it a cycle later changes nothing.
    seq_ofs_p : process (DMA_CLK)
        variable ofs_v : unsigned(SEQ_DELTA_W -1 downto 0);
    begin
        if (rising_edge(DMA_CLK)) then
            for c in 0 to SEQ_CANDS -1 loop
                ofs_v := (others => '0');
                for k in 1 to c/2 loop
                    ofs_v := ofs_v + resize(wr_frame_lba_cnt, SEQ_DELTA_W);
                end loop;
                if (c mod 2 = 1) then
                    ofs_v := ofs_v + resize(rd_lba_inc_nxt, SEQ_DELTA_W);
                end if;
                seq_ofs_r(c)      <= ofs_v;
                seq_ofs_fold_r(c) <= resize(ofs_v, ADDR_CNTR_WIDTH + 1) - resize(TST_LBA_COUNT, ADDR_CNTR_WIDTH + 1);
            end loop;
        end if;
    end process;

    seq_load <= core_rst or data_logger_rst or tst_trigg;
    seq_en   <= (not tst_finished) or contig_test;

    -- Fold at the namespace end: a sum wrapping ADDR_CNTR_WIDTH is below TST_LBA_COUNT, otherwise
    -- the sign of the parallel sum with -TST_LBA_COUNT is the >= compare, so each is one carry chain.
    seq_cand_g : for q in 0 to NUM_QUEUES -1 generate
        seq_cand_c_g : for c in 0 to SEQ_CANDS -1 generate
            signal sum_s  : unsigned(ADDR_CNTR_WIDTH downto 0);
            signal fold_s : unsigned(ADDR_CNTR_WIDTH downto 0);
        begin
            sum_s  <= resize(seq_addr_cntr(q), ADDR_CNTR_WIDTH + 1) + resize(seq_ofs_r(c), ADDR_CNTR_WIDTH + 1);
            fold_s <= resize(seq_addr_cntr(q), ADDR_CNTR_WIDTH + 1) + seq_ofs_fold_r(c);

            seq_cand(q)(c) <= resize(unsigned(nvme_rd_req_lba_ptr_reg), ADDR_CNTR_WIDTH) when (seq_load = '1') else
                              seq_up(q) when (c = 0 and seq_align_pend(q) = '1') else
                              fold_s(ADDR_CNTR_WIDTH -1 downto 0) when (sum_s(ADDR_CNTR_WIDTH) = '0' and fold_s(ADDR_CNTR_WIDTH) = '0') else
                              sum_s(ADDR_CNTR_WIDTH -1 downto 0);
        end generate;
    end generate;

    -- The MI write raising contig_test; the read generator is only enabled a cycle later, so the flag
    -- lands on an idle queue. On a busy one it waits for an idle cycle rather than drop an advance.
    seq_align_set <= mi_split_wr(0) and tst_sel_reg_sel and mi_split_dwr(0)(3) and not contig_test;

    -- Rounding up adds one unit when a bit below it is set, which is a carry-in, so each of the two
    -- sums stays one carry chain and folds exactly like the candidates above.
    seq_up_g : for q in 0 to NUM_QUEUES -1 generate
        signal hi_s       : unsigned(SEQ_UP_W downto 0);
        signal inc_s      : unsigned(SEQ_UP_W downto 0);
        signal fold_ofs_s : unsigned(SEQ_UP_W downto 0);
        signal up_s       : unsigned(SEQ_UP_W downto 0);
        signal fold_s     : unsigned(SEQ_UP_W downto 0);
    begin
        hi_s       <= resize(seq_addr_cntr(q)(ADDR_CNTR_WIDTH -1 downto LBA_ALIGN_W), SEQ_UP_W + 1);
        inc_s      <= to_unsigned(1, SEQ_UP_W + 1) when ((or std_logic_vector(seq_addr_cntr(q)(LBA_ALIGN_W -1 downto 0))) = '1') else
                      to_unsigned(0, SEQ_UP_W + 1);
        fold_ofs_s <= SEQ_UP_FOLD1 when (inc_s(0) = '1') else SEQ_UP_FOLD0;
        up_s       <= hi_s + inc_s;
        fold_s     <= hi_s + fold_ofs_s;

        seq_up(q) <= shift_left(resize(fold_s, ADDR_CNTR_WIDTH), LBA_ALIGN_W) when (up_s(SEQ_UP_W) = '0' and fold_s(SEQ_UP_W) = '0') else
                     shift_left(resize(up_s, ADDR_CNTR_WIDTH), LBA_ALIGN_W);

        -- A load places the counter explicitly, so it cancels a rounding still waiting for its idle cycle.
        seq_align_pend_p : process (DMA_CLK)
        begin
            if (rising_edge(DMA_CLK)) then
                if (core_rst = '1') then
                    seq_align_pend(q) <= '0';
                elsif (seq_align_set = '1') then
                    seq_align_pend(q) <= '1';
                elsif (seq_load = '1' or (seq_en = '1' and seq_sel(q) = 0)) then
                    seq_align_pend(q) <= '0';
                end if;
            end if;
        end process;
    end generate;

    -- A read and a write accepted in the same cycle on one queue both advance it. Writes must: else
    -- every frame between two reads carries one LBA, and an SSD serialises write-after-write.
    seq_sel_p : process (all)
        variable wr_cnt_v : natural range 0 to DMA_MFB_REGIONS;
    begin
        for q in 0 to NUM_QUEUES -1 loop
            wr_cnt_v := 0;
            for r in 0 to DMA_MFB_REGIONS -1 loop
                if (gen_nvme_wr_accept(r) = '1'
                    and seq_idx_f(unsigned(gen_nvme_wr_qid_mskd((r+1)*QID_W -1 downto r*QID_W))) = q) then
                    wr_cnt_v := wr_cnt_v + 1;
                end if;
            end loop;

            if (rd_req_accepted_s = '1' and seq_idx_f(unsigned(nvme_rd_req_qid_s)) = q) then
                seq_sel(q) <= wr_cnt_v*2 + 1;
            else
                seq_sel(q) <= wr_cnt_v*2;
            end if;
        end loop;
    end process;

    -- Advance when accepted, not when it completes: waiting leaves the address undefined for the
    -- round trip, so requests issued meanwhile repeat the previous LBA, capping in-flight commands
    -- to one per queue.
    seq_addr_cntr_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (seq_load = '1' or seq_en = '1') then
                for q in 0 to NUM_QUEUES -1 loop
                    seq_addr_cntr(q) <= seq_cand(q)(seq_sel(q));
                end loop;
            end if;
        end if;
    end process;

    -- Shared across queues. Each slot's draw folds at the namespace like the counter (the folded
    -- span draws twice as often), dropping bits below a drive unit; the fold starts at the slot.
    rand_draw_g : for k in 0 to RAND_SLOTS -1 generate
        signal units_s : unsigned(ADDR_CNTR_WIDTH - LBA_ALIGN_W -1 downto 0);
    begin
        units_s <= unsigned(rand_slot_r(k)(ADDR_CNTR_WIDTH -1 downto LBA_ALIGN_W));

        rand_draw(k)(ADDR_CNTR_WIDTH -1 downto LBA_ALIGN_W) <=
            std_logic_vector(units_s - RAND_LBA_SPAN(ADDR_CNTR_WIDTH -1 downto LBA_ALIGN_W))
            when units_s >= RAND_LBA_SPAN(ADDR_CNTR_WIDTH -1 downto LBA_ALIGN_W) else
            std_logic_vector(units_s);

        rand_draw(k)(LBA_ALIGN_W -1 downto 0) <= (others => '0');
    end generate;

    -- dc_addr_mask confines a data-check run to the region software filled; all ones otherwise.
    tst_addr_q_g : for q in 0 to NUM_QUEUES -1 generate
        tst_addr_q(q) <= (std_logic_vector(seq_addr_cntr(q)) and dc_addr_mask) when tst_sel_reg(0) = '0' else
                         (rand_draw(0) and dc_addr_mask);
    end generate;

    tst_addr <= tst_addr_q(seq_idx_f(rd_qid_cand));

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
        RESET => core_rst,

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
    evcr_event_vld <= '1' when (core_op_stat_vld = '1' and core_op_stat_code = OP_STAT_SUCCESS) else '0';

    evcr_reg_p : process (DMA_CLK)
    begin
        if (rising_edge(DMA_CLK)) then
            if (core_rst = '1') then
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
    --      assert always ((core_rst or data_logger_rst) = '0' -> (lat_meas_mode = '0' or unsigned(lat_meas_fifo_items) <= 1))
    --      report "USER_CORE: more than one operation outstanding during a latency measurement -- the meter pairs positionally and would report a wrong latency";

    -- The gate must never be the reason a NON-measurement run stalls.
    -- psl LAT_MEAS_GATE_IDLE_WHEN_OFF :
    --      assert always (core_rst = '0' -> (lat_meas_mode = '1' or lat_meas_issue_ok = '1'))
    --      report "USER_CORE: the latency serialisation gate engaged outside latency mode";

    -- psl LAT_MEAS_COVER_GATED : cover {lat_meas_issue_ok = '0'};

    -- The write gate must never withhold mid-frame: that would stall a partially transferred frame.
    -- psl LAT_MEAS_WR_GATE_NOT_MIDFRAME :
    --      assert always (core_rst = '0' -> (lat_wr_in_frame_r = '0' or lat_wr_issue_ok = '1'))
    --      report "USER_CORE: the latency write gate withheld SRC_RDY mid-frame";

    -- psl LAT_MEAS_WR_GATE_IDLE_WHEN_OFF :
    --      assert always (core_rst = '0' -> (lat_meas_mode = '1' or lat_wr_issue_ok = '1'))
    --      report "USER_CORE: the latency write gate engaged outside latency mode";

    -- psl LAT_MEAS_COVER_WR_GATED : cover {lat_wr_issue_ok = '0'};

    -- =============================================================================================
    -- Line-rate read-data checker (DATA_CHECK)
    -- =============================================================================================
    no_data_check_g : if (not DATA_CHECK) generate
        dc_pat_wr_en   <= '0';
        dc_wr_pat_data <= (others => '0');
        dc_addr_mask   <= (others => '1');
        dc_mi_drd      <= X"CAFEBABE";
    end generate;

    -- Checks every read beat against the written pattern. Frames match in completion order, not by
    -- (qid, cid): the DMA frees a tag at the CQE, so a (qid, cid) can name a newer read by its frame.
    data_check_g : if DATA_CHECK generate
        constant DC_W          : natural := 512;
        -- Tags come from a QUEUE_DEPTH pool (64 here); a CID beyond this table is flagged, not tracked.
        constant DC_CID_W      : natural := 8;
        constant DC_LBA_W      : natural := 48;
        constant DC_TBL_AW     : natural := QID_W + DC_CID_W;
        constant DC_TBL_DW     : natural := DC_LBA_W + 8;
        constant DC_EXP_W      : natural := QID_W + DC_CID_W + DC_TBL_DW;
        -- Completed reads whose frame has not started: up to MANAGED_PAGES (2048) per endpoint, plus
        -- the frames already past the DMA in the endpoint-1 crossing and the interface pipe.
        constant DC_EXP_ITEMS  : natural := 4096;
        constant DC_MM_W       : natural := 12;
        -- A DATA_LOST report trails its frame by tens of cycles, so a mismatching frame unclaimed
        -- this long was not lost.
        constant DC_MM_TMO     : natural := 2048;
        -- A report can lead its frame by however long the read stream is held, so it ages only while
        -- that stream is ready; one this old matches no frame.
        constant DC_ORPHAN_AGE : natural := 2**20;
        -- Mismatching frames and DATA_LOST reports waiting for each other, per endpoint.
        constant DC_CAM_N      : natural := 4;
        constant DC_TAG_W      : natural := QID_W + DC_CID_W;
        constant DC_CNT_W      : natural := 48;
        constant DC_G_CNTS     : natural := 8;
        constant DC_EP_CNTS    : natural := 8;
        -- Per-queue start-LBA repeat counters, at a fixed index whatever the endpoint count.
        constant DC_Q_BASE     : natural := 32;
        constant DC_Q_CNTS     : natural := 3;
        constant DC_ALL_CNTS   : natural := DC_Q_BASE + DC_Q_CNTS*NUM_QUEUES;
        -- Start LBAs remembered per queue to spot a repeat.
        constant DC_HIST_N     : natural := 8;
        -- Events travel as many stages as the interface pipe, between the same two ends.
        constant DC_EV_STAGES  : natural := IF_PIPE_STAGES;

        -- Event layouts, LSB first. CID event: vld, cid, lba_num, lba, qid, paired. Status event:
        -- vld, cid, qid, code, type.
        constant EVC_CID_LO  : natural := 1;
        constant EVC_NUM_LO  : natural := EVC_CID_LO + CQ_ENTRY_CMD_ID_W;
        constant EVC_LBA_LO  : natural := EVC_NUM_LO + 8;
        constant EVC_QID_LO  : natural := EVC_LBA_LO + DC_LBA_W;
        constant EVC_OK      : natural := EVC_QID_LO + QID_W;
        constant EVC_W       : natural := EVC_OK + 1;
        constant EVS_CID_LO  : natural := 1;
        constant EVS_QID_LO  : natural := EVS_CID_LO + CQ_ENTRY_CMD_ID_W;
        constant EVS_CODE_LO : natural := EVS_QID_LO + QID_W;
        constant EVS_TYPE    : natural := EVS_CODE_LO + 2;
        constant EVS_W       : natural := EVS_TYPE + 1;
        -- First-mismatch record, LSB first: got, exp, word index, beat, lba, cid, qid.
        constant FM_EXP_LO   : natural := 64;
        constant FM_WIDX_LO  : natural := FM_EXP_LO + 64;
        constant FM_BEAT_LO  : natural := FM_WIDX_LO + 3;
        constant FM_LBA_LO   : natural := FM_BEAT_LO + DC_MM_W;
        constant FM_CID_LO   : natural := FM_LBA_LO + DC_LBA_W;
        constant FM_QID_LO   : natural := FM_CID_LO + DC_CID_W;
        constant FM_W        : natural := FM_QID_LO + QID_W;

        -- Global counters (completion accounting, counted whatever CHECK_EN says).
        constant CG_RD_OK    : natural := 0;
        constant CG_WR_OK    : natural := 1;
        constant CG_RD_FAIL  : natural := 2;
        constant CG_WR_FAIL  : natural := 3;
        constant CG_OOR      : natural := 4;
        constant CG_LOST_RPT : natural := 5;
        constant CG_ORPHAN   : natural := 6;
        constant CG_RD_CID   : natural := 7;
        -- Per-endpoint counters, counted only while CHECK_EN is set.
        constant CE_FRAMES   : natural := 0;
        constant CE_BEATS    : natural := 1;
        constant CE_MM_BEATS : natural := 2;
        constant CE_MM_FRMS  : natural := 3;
        constant CE_LEN_ERR  : natural := 4;
        constant CE_ID_ERR   : natural := 5;
        constant CE_LOST_FRM : natural := 6;
        constant CE_LOST_MMB : natural := 7;

        type dc_cnt_arr_t is array (natural range <>) of unsigned(DC_CNT_W -1 downto 0);
        type dc_ep_cnt_t is array (0 to PCIE_ENDPOINTS -1) of dc_cnt_arr_t(0 to DC_EP_CNTS -1);
        type dc_evc_t is array (1 to DC_EV_STAGES) of std_logic_vector(EVC_W -1 downto 0);
        type dc_evs_t is array (1 to DC_EV_STAGES) of std_logic_vector(EVS_W -1 downto 0);
        type dc_tbl_t is array (0 to 2**DC_TBL_AW -1) of std_logic_vector(DC_TBL_DW -1 downto 0);
        type dc_tag_arr_t is array (0 to DC_CAM_N -1) of std_logic_vector(DC_TAG_W -1 downto 0);
        type dc_mm_arr_t is array (0 to DC_CAM_N -1) of unsigned(DC_MM_W -1 downto 0);
        type dc_fm_arr_t is array (0 to DC_CAM_N -1) of std_logic_vector(FM_W -1 downto 0);
        type dc_mtmo_arr_t is array (0 to DC_CAM_N -1) of unsigned(log2(DC_MM_TMO) downto 0);
        type dc_ltmo_arr_t is array (0 to DC_CAM_N -1) of unsigned(log2(DC_ORPHAN_AGE) downto 0);
        type dc_hist_t is array (0 to DC_HIST_N -1) of std_logic_vector(DC_LBA_W -1 downto 0);
        type dc_hist_q_t is array (0 to NUM_QUEUES -1) of dc_hist_t;

        -- MI control
        signal dc_check_en  : std_logic;
        signal dc_clear     : std_logic;
        signal dc_rst       : std_logic;
        signal dc_span_reg  : std_logic_vector(31 downto 0);
        signal dc_sel_reg   : std_logic_vector(7 downto 0);
        signal dc_sel_wr_d  : std_logic_vector(1 downto 0);
        signal dc_cnt_mux_r : unsigned(DC_CNT_W -1 downto 0);
        signal dc_cnt_snap  : unsigned(DC_CNT_W -1 downto 0);
        signal dc_status    : std_logic_vector(31 downto 0);

        -- Pattern-mode write payload
        signal dc_wr_meta_qid : std_logic_vector(QID_W -1 downto 0);
        signal dc_wr_meta_lba : unsigned(DC_LBA_W -1 downto 0);
        signal dc_wr_qid_r    : std_logic_vector(QID_W -1 downto 0);
        signal dc_wr_sec_r    : unsigned(DC_LBA_W -1 downto 0);
        signal dc_wr_bis_r    : unsigned(2 downto 0);

        -- DMA end: the accepted read, held until the CID naming it, and both event chains
        signal dc_acc_r     : std_logic;
        signal dc_req_qid_r : std_logic_vector(QID_W -1 downto 0);
        signal dc_req_lba_r : std_logic_vector(DC_LBA_W -1 downto 0);
        signal dc_req_num_r : std_logic_vector(7 downto 0);
        -- Each queue's last DC_HIST_N accepted start LBAs, newest at index 0, and the repeat check.
        signal dc_hist      : dc_hist_q_t;
        signal dc_hist_vld  : slv_array_t(NUM_QUEUES -1 downto 0)(DC_HIST_N -1 downto 0);
        signal dc_dup_vld   : std_logic;
        signal dc_dup_q     : natural range 0 to NUM_QUEUES -1;
        signal dc_dup_eq    : std_logic_vector(DC_HIST_N -1 downto 0);
        signal dc_q_cnt     : dc_cnt_arr_t(0 to DC_Q_CNTS*NUM_QUEUES -1);
        signal dc_cap_vld   : std_logic;
        signal dc_cap_qid   : std_logic_vector(QID_W -1 downto 0);
        signal dc_cap_lba   : std_logic_vector(DC_LBA_W -1 downto 0);
        signal dc_cap_num   : std_logic_vector(7 downto 0);
        signal dc_evc       : dc_evc_t;
        signal dc_evs       : dc_evs_t;

        -- Engine end of the event chains
        signal e_cvld   : std_logic;
        signal e_ccid   : std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
        signal e_cnum   : std_logic_vector(7 downto 0);
        signal e_clba   : std_logic_vector(DC_LBA_W -1 downto 0);
        signal e_cqid   : std_logic_vector(QID_W -1 downto 0);
        signal e_cap_ok : std_logic;
        signal e_svld   : std_logic;
        signal e_scid   : std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
        signal e_sqid   : std_logic_vector(QID_W -1 downto 0);
        signal e_scode  : std_logic_vector(1 downto 0);
        signal e_stype  : std_logic;

        -- (qid, cid) -> start LBA and LBA count of the read that tag was last issued for
        signal dc_tbl          : dc_tbl_t := (others => (others => '0'));
        signal dc_tbl_we       : std_logic;
        signal dc_tbl_wa       : std_logic_vector(DC_TBL_AW -1 downto 0);
        signal dc_tbl_wd       : std_logic_vector(DC_TBL_DW -1 downto 0);
        signal dc_tbl_re       : std_logic;
        signal dc_tbl_ra       : std_logic_vector(DC_TBL_AW -1 downto 0);
        signal dc_tbl_q        : std_logic_vector(DC_TBL_DW -1 downto 0);
        signal dc_tbl_q2       : std_logic_vector(DC_TBL_DW -1 downto 0);
        signal dc_tbl_coll     : std_logic;
        signal dc_cid_unpaired : std_logic;
        attribute ram_style : string;
        attribute ram_style of dc_tbl : signal is "block";

        -- Lookup of a successful read completion, and its push into its endpoint's expectations
        signal dc_lk_vld  : std_logic_vector(1 downto 0);
        signal dc_lk1_qid : std_logic_vector(QID_W -1 downto 0);
        signal dc_lk1_cid : std_logic_vector(DC_CID_W -1 downto 0);
        signal dc_lk2_qid : std_logic_vector(QID_W -1 downto 0);
        signal dc_lk2_cid : std_logic_vector(DC_CID_W -1 downto 0);
        signal dc_lk_ep   : natural range 0 to PCIE_ENDPOINTS -1;
        signal dc_lost_ep : natural range 0 to PCIE_ENDPOINTS -1;
        signal dc_xf_di   : std_logic_vector(DC_EXP_W -1 downto 0);
        signal dc_xf_wr   : std_logic_vector(PCIE_ENDPOINTS -1 downto 0);
        signal dc_lf_di   : std_logic_vector(DC_TAG_W -1 downto 0);
        signal dc_lf_wr   : std_logic_vector(PCIE_ENDPOINTS -1 downto 0);

        -- Counters and flags
        signal dc_g_cnt   : dc_cnt_arr_t(0 to DC_G_CNTS -1);
        signal dc_ep_cnt  : dc_ep_cnt_t;
        signal dc_all_cnt : dc_cnt_arr_t(0 to DC_ALL_CNTS -1);
        signal dc_g_flg   : std_logic_vector(1 downto 0);
        -- Per endpoint: [4:0] sticky (expectation overflow, report CAM full, mismatch CAM full,
        -- framing error, frame with no expectation), [8:5] live (no expectation pending, no
        -- mismatching frame pending, no report pending, inside a frame).
        signal dc_ep_sts  : slv_array_t(PCIE_ENDPOINTS -1 downto 0)(8 downto 0);
        -- Reports resolved as orphans this cycle: no mismatching frame claimed them in time.
        signal dc_orph    : slv_array_t(PCIE_ENDPOINTS -1 downto 0)(2 downto 0);

        -- First mismatch: per endpoint the first beat of a frame judged a data error, one global latch
        signal dc_fmo_vld  : std_logic_vector(PCIE_ENDPOINTS -1 downto 0);
        signal dc_fmo      : slv_array_t(PCIE_ENDPOINTS -1 downto 0)(FM_W -1 downto 0);
        signal dc_fm_vld   : std_logic;
        signal dc_fm_ep    : natural range 0 to PCIE_ENDPOINTS -1;
        signal dc_fm       : std_logic_vector(FM_W -1 downto 0);
        signal dc_fm_qid   : std_logic_vector(QID_W -1 downto 0);
        signal dc_fm_cid   : std_logic_vector(DC_CID_W -1 downto 0);
        signal dc_fm_lba   : std_logic_vector(DC_LBA_W -1 downto 0);
        signal dc_fm_beat  : std_logic_vector(DC_MM_W -1 downto 0);
        signal dc_fm_widx  : std_logic_vector(2 downto 0);
        signal dc_fm_exp   : std_logic_vector(63 downto 0);
        signal dc_fm_got   : std_logic_vector(63 downto 0);
    begin
        assert (DMA_MFB_REGIONS = 1 and DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH = DC_W)
            report "USER_CORE: DATA_CHECK needs one 512 b MFB region, each beat an eighth of a sector"
            severity failure;
        assert (NUM_QUEUES <= 16)
            report "USER_CORE: DATA_CHECK carries the QID in 4 bits of the pattern"
            severity failure;
        assert (DC_G_CNTS + DC_EP_CNTS*PCIE_ENDPOINTS <= DC_Q_BASE)
            report "USER_CORE: DATA_CHECK's per-endpoint counters overlap the per-queue ones"
            severity failure;

        -- -----------------------------------------------------------------------------------------
        -- MI: 0x88 CTRL [0] pattern writes, [1] check enable, [2] clear (pulse); 0x8C span mask in
        -- LBAs (0 = whole drive); 0x90 counter select, its snapshot read at 0x94/0x98.
        -- -----------------------------------------------------------------------------------------
        dc_ctrl_p : process (DMA_CLK)
            variable addr_v : std_logic_vector(7 downto 0);
        begin
            if rising_edge(DMA_CLK) then
                addr_v                          := (others => '0');
                addr_v(ADDR_LENGTH -1 downto 0) := mi_split_addr(0)(ADDR_LENGTH -1 downto 0);
                dc_clear                        <= '0';
                dc_sel_wr_d                     <= dc_sel_wr_d(0) & '0';
                if (mi_split_wr(0) = '1') then
                    case addr_v is
                        when x"88" =>
                            dc_pat_wr_en <= mi_split_dwr(0)(0);
                            dc_check_en  <= mi_split_dwr(0)(1);
                            dc_clear     <= mi_split_dwr(0)(2);
                        when x"8C" =>
                            dc_span_reg <= mi_split_dwr(0);
                        when x"90" =>
                            dc_sel_reg     <= mi_split_dwr(0)(7 downto 0);
                            dc_sel_wr_d(0) <= '1';
                        when others => null;
                    end case;
                end if;
                if (core_rst = '1') then
                    dc_pat_wr_en <= '0';
                    dc_check_en  <= '0';
                    dc_clear     <= '0';
                    dc_span_reg  <= (others => '0');
                    dc_sel_reg   <= (others => '0');
                    dc_sel_wr_d  <= (others => '0');
                end if;
            end if;
        end process;

        -- Clear also empties the expectations and the lost-report matching, so it is for an idle core only.
        dc_rst <= core_rst or dc_clear;

        -- Registered so the mask adds one LUT level, not a compare, to the request address.
        dc_mask_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                if (unsigned(dc_span_reg) = 0) then
                    dc_addr_mask <= (others => '1');
                else
                    dc_addr_mask <= std_logic_vector(resize(unsigned(dc_span_reg), ADDR_CNTR_WIDTH));
                end if;
            end if;
        end process;

        -- -----------------------------------------------------------------------------------------
        -- Pattern-mode writes: a frame's first beat takes its sector from the meta it carries, every
        -- later beat from registers advanced on the write handshake.
        -- -----------------------------------------------------------------------------------------
        dc_wr_meta_qid <= pip_wr_meta(SQE_LBA_PTR_W + QID_W -1 downto SQE_LBA_PTR_W);
        dc_wr_meta_lba <= unsigned(pip_wr_meta(DC_LBA_W -1 downto 0));
        dc_wr_pat_data <= dc_pat_beat_f(dc_wr_meta_qid, dc_wr_meta_lba, "000") when (pip_nvme_wr_sof(0) = '1') else
                          dc_pat_beat_f(dc_wr_qid_r, dc_wr_sec_r, dc_wr_bis_r);

        dc_wr_pat_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                if (core_wr_mfb_src_rdy = '1' and core_wr_mfb_dst_rdy = '1' and integ_en = '0') then
                    if (pip_nvme_wr_sof(0) = '1') then
                        dc_wr_qid_r <= dc_wr_meta_qid;
                        dc_wr_sec_r <= dc_wr_meta_lba;
                        dc_wr_bis_r <= "001";
                    else
                        dc_wr_bis_r <= dc_wr_bis_r + 1;
                        if (dc_wr_bis_r = "111") then
                            dc_wr_sec_r <= dc_wr_sec_r + 1;
                        end if;
                    end if;
                end if;
            end if;
        end process;

        -- -----------------------------------------------------------------------------------------
        -- DMA end: the pipe reorders queues, so a CID pairs with the request the DMA accepted. It
        -- trails that accept by 3+ cycles and precedes the next one, so the held request is its own.
        -- -----------------------------------------------------------------------------------------
        dc_cap_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                dc_acc_r     <= or (NVME_RD_REQ_VLD and NVME_RD_REQ_RDY);
                dc_req_qid_r <= NVME_RD_REQ_QID;
                dc_req_lba_r <= NVME_RD_REQ_LBA_PTR(DC_LBA_W -1 downto 0);
                dc_req_num_r <= NVME_RD_REQ_LBA_NUM;

                if (dc_acc_r = '1') then
                    dc_cap_vld <= '1';
                    dc_cap_qid <= dc_req_qid_r;
                    dc_cap_lba <= dc_req_lba_r;
                    dc_cap_num <= dc_req_num_r;
                elsif (NVME_RD_REQ_CID_VLD = '1') then
                    dc_cap_vld <= '0';
                end if;

                -- Both chains start here, in one stage, so the engine sees them in port order.
                dc_evc(1) <= dc_cap_vld & dc_cap_qid & dc_cap_lba & dc_cap_num & NVME_RD_REQ_CID & NVME_RD_REQ_CID_VLD;
                dc_evs(1) <= NVME_OP_STAT_TYPE & NVME_OP_STAT_CODE & NVME_OP_STAT_QID & NVME_OP_STAT_CID & NVME_OP_STAT_VLD;

                if (DMA_RST = '1') then
                    dc_acc_r     <= '0';
                    dc_cap_vld   <= '0';
                    dc_evc(1)(0) <= '0';
                    dc_evs(1)(0) <= '0';
                end if;
            end if;
        end process;

        -- Repeat measurement: does an accepted read start where one of its queue's last reads did?
        -- Counted in every mode and whatever CHECK_EN says; the history is compared before the
        -- accept shifts in, and the DMA admits at most one read per three cycles.
        dc_dup_p : process (DMA_CLK)
            variable q_v : natural range 0 to NUM_QUEUES -1;
        begin
            if rising_edge(DMA_CLK) then
                q_v        := seq_idx_f(unsigned(dc_req_qid_r));
                dc_dup_vld <= dc_acc_r;
                dc_dup_q   <= q_v;
                for i in 0 to DC_HIST_N -1 loop
                    dc_dup_eq(i) <= '1' when (dc_hist_vld(q_v)(i) = '1' and dc_hist(q_v)(i) = dc_req_lba_r) else '0';
                end loop;
                for q in 0 to NUM_QUEUES -1 loop
                    if (dc_acc_r = '1' and q_v = q) then
                        dc_hist(q)     <= dc_req_lba_r & dc_hist(q)(0 to DC_HIST_N -2);
                        dc_hist_vld(q) <= dc_hist_vld(q)(DC_HIST_N -2 downto 0) & '1';
                    end if;
                end loop;

                if (dc_dup_vld = '1') then
                    dc_q_cnt(DC_Q_CNTS*dc_dup_q) <= dc_q_cnt(DC_Q_CNTS*dc_dup_q) + 1;
                    if (dc_dup_eq(0) = '1') then
                        dc_q_cnt(DC_Q_CNTS*dc_dup_q + 1) <= dc_q_cnt(DC_Q_CNTS*dc_dup_q + 1) + 1;
                    end if;
                    if ((or dc_dup_eq) = '1') then
                        dc_q_cnt(DC_Q_CNTS*dc_dup_q + 2) <= dc_q_cnt(DC_Q_CNTS*dc_dup_q + 2) + 1;
                    end if;
                end if;

                -- Clear forgets the history too, so a point counts repeats among its own reads.
                if (DMA_RST = '1' or dc_rst = '1') then
                    dc_dup_vld  <= '0';
                    dc_hist_vld <= (others => (others => '0'));
                    dc_q_cnt    <= (others => (others => '0'));
                end if;
            end if;
        end process;

        -- No reset past stage 1: DMA_RST is held longer than the chain, which flushes it.
        dc_ev_g : for s in 2 to DC_EV_STAGES generate
            dc_ev_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    dc_evc(s) <= dc_evc(s -1);
                    dc_evs(s) <= dc_evs(s -1);
                end if;
            end process;
        end generate;

        e_cvld   <= dc_evc(DC_EV_STAGES)(0);
        e_ccid   <= dc_evc(DC_EV_STAGES)(EVC_NUM_LO -1 downto EVC_CID_LO);
        e_cnum   <= dc_evc(DC_EV_STAGES)(EVC_LBA_LO -1 downto EVC_NUM_LO);
        e_clba   <= dc_evc(DC_EV_STAGES)(EVC_QID_LO -1 downto EVC_LBA_LO);
        e_cqid   <= dc_evc(DC_EV_STAGES)(EVC_OK -1 downto EVC_QID_LO);
        e_cap_ok <= dc_evc(DC_EV_STAGES)(EVC_OK);
        e_svld   <= dc_evs(DC_EV_STAGES)(0);
        e_scid   <= dc_evs(DC_EV_STAGES)(EVS_QID_LO -1 downto EVS_CID_LO);
        e_sqid   <= dc_evs(DC_EV_STAGES)(EVS_CODE_LO -1 downto EVS_QID_LO);
        e_scode  <= dc_evs(DC_EV_STAGES)(EVS_TYPE -1 downto EVS_CODE_LO);
        e_stype  <= dc_evs(DC_EV_STAGES)(EVS_TYPE);

        -- -----------------------------------------------------------------------------------------
        -- Engine end. A tag is reused one cycle after its completion's status at the earliest, so a
        -- completion's lookup reads its entry before the tag's next issue overwrites it.
        -- -----------------------------------------------------------------------------------------
        dc_tbl_we <= e_cvld when (unsigned(e_ccid(CQ_ENTRY_CMD_ID_W -1 downto DC_CID_W)) = 0) else '0';
        dc_tbl_wa <= e_cqid & e_ccid(DC_CID_W -1 downto 0);
        dc_tbl_wd <= e_clba & e_cnum;
        dc_tbl_re <= '1' when (e_svld = '1' and e_stype = '1' and e_scode = "00") else '0';
        dc_tbl_ra <= e_sqid & e_scid(DC_CID_W -1 downto 0);

        dc_tbl_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                if (dc_tbl_we = '1') then
                    dc_tbl(to_integer(unsigned(dc_tbl_wa))) <= dc_tbl_wd;
                end if;
                dc_tbl_q  <= dc_tbl(to_integer(unsigned(dc_tbl_ra)));
                dc_tbl_q2 <= dc_tbl_q;
            end if;
        end process;

        dc_lk_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                dc_lk_vld  <= dc_lk_vld(0) & dc_tbl_re;
                dc_lk1_qid <= e_sqid;
                dc_lk1_cid <= e_scid(DC_CID_W -1 downto 0);
                dc_lk2_qid <= dc_lk1_qid;
                dc_lk2_cid <= dc_lk1_cid;
                if (dc_rst = '1') then
                    dc_lk_vld <= (others => '0');
                end if;
            end if;
        end process;

        dc_lk_ep   <= queue_ep_f(seq_idx_f(unsigned(dc_lk2_qid)), NUM_QUEUES, PCIE_ENDPOINTS);
        dc_lost_ep <= queue_ep_f(seq_idx_f(unsigned(e_sqid)), NUM_QUEUES, PCIE_ENDPOINTS);
        dc_xf_di   <= dc_lk2_qid & dc_lk2_cid & dc_tbl_q2;
        dc_lf_di   <= e_sqid & e_scid(DC_CID_W -1 downto 0);

        dc_push_g : for ep in 0 to PCIE_ENDPOINTS -1 generate
            dc_xf_wr(ep) <= dc_lk_vld(1) when (dc_lk_ep = ep) else '0';
            dc_lf_wr(ep) <= '1' when (e_svld = '1' and e_scode = "11" and dc_lost_ep = ep) else '0';
        end generate;

        dc_tbl_coll     <= '1' when (dc_tbl_we = '1' and dc_tbl_re = '1' and dc_tbl_wa = dc_tbl_ra) else '0';
        dc_cid_unpaired <= e_cvld and not e_cap_ok;

        dc_g_cnt_p : process (DMA_CLK)
            variable orph_v : unsigned(DC_CNT_W -1 downto 0);
        begin
            if rising_edge(DMA_CLK) then
                if (e_svld = '1') then
                    case std_logic_vector'(e_stype & e_scode) is
                        when "100"  => dc_g_cnt(CG_RD_OK)   <= dc_g_cnt(CG_RD_OK) + 1;
                        when "000"  => dc_g_cnt(CG_WR_OK)   <= dc_g_cnt(CG_WR_OK) + 1;
                        when "101"  => dc_g_cnt(CG_RD_FAIL) <= dc_g_cnt(CG_RD_FAIL) + 1;
                        when "001"  => dc_g_cnt(CG_WR_FAIL) <= dc_g_cnt(CG_WR_FAIL) + 1;
                        when "010" | "110" => dc_g_cnt(CG_OOR) <= dc_g_cnt(CG_OOR) + 1;
                        when others => dc_g_cnt(CG_LOST_RPT) <= dc_g_cnt(CG_LOST_RPT) + 1;
                    end case;
                end if;
                if (e_cvld = '1') then
                    dc_g_cnt(CG_RD_CID) <= dc_g_cnt(CG_RD_CID) + 1;
                end if;
                orph_v := (others => '0');
                for ep in 0 to PCIE_ENDPOINTS -1 loop
                    orph_v := orph_v + unsigned(dc_orph(ep));
                end loop;
                dc_g_cnt(CG_ORPHAN) <= dc_g_cnt(CG_ORPHAN) + orph_v;

                if (dc_tbl_we = '0' and e_cvld = '1') then
                    dc_g_flg(0) <= '1';
                end if;
                if (dc_cid_unpaired = '1') then
                    dc_g_flg(1) <= '1';
                end if;

                if (dc_rst = '1') then
                    dc_g_cnt <= (others => (others => '0'));
                    dc_g_flg <= (others => '0');
                end if;
            end if;
        end process;

        -- -----------------------------------------------------------------------------------------
        -- One checker per read stream. It only observes the transfers, so it never back-pressures.
        -- S0 registers the beat, S1 compares 16 b chunks, S2 reduces them per word, S3 counts.
        -- -----------------------------------------------------------------------------------------
        dc_ep_g : for ep in 0 to PCIE_ENDPOINTS -1 generate
            -- Expectations in completion order, the head prefetched ahead of the frame it names.
            signal xf_rd    : std_logic;
            signal xf_full  : std_logic;
            signal xf_empty : std_logic;
            signal xf_do    : std_logic_vector(DC_EXP_W -1 downto 0);
            signal nxt_vld  : std_logic;
            signal nxt_qid  : std_logic_vector(QID_W -1 downto 0);
            signal nxt_cid  : std_logic_vector(DC_CID_W -1 downto 0);
            signal nxt_lba  : unsigned(DC_LBA_W -1 downto 0);
            signal nxt_num  : unsigned(7 downto 0);

            signal s0_vld       : std_logic;
            signal s0_sof       : std_logic;
            signal s0_eof       : std_logic;
            signal s0_sofpos_ok : std_logic;
            signal s0_eofpos_ok : std_logic;
            signal s0_take      : std_logic;
            signal s0_mqid      : std_logic_vector(QID_W -1 downto 0);
            signal s0_mcid      : std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
            signal s0_data      : std_logic_vector(DC_W -1 downto 0);

            -- The frame being received; cur_sec/cur_bis name its NEXT beat.
            signal cur_in_frame : std_logic;
            signal cur_xv       : std_logic;
            signal cur_qid      : std_logic_vector(QID_W -1 downto 0);
            signal cur_cid      : std_logic_vector(DC_CID_W -1 downto 0);
            signal cur_lba      : unsigned(DC_LBA_W -1 downto 0);
            signal cur_num      : unsigned(7 downto 0);
            signal cur_sec      : unsigned(DC_LBA_W -1 downto 0);
            signal cur_bis      : unsigned(2 downto 0);
            signal cur_beat     : unsigned(DC_MM_W -1 downto 0);

            signal e_qid : std_logic_vector(QID_W -1 downto 0);
            signal e_sec : unsigned(DC_LBA_W -1 downto 0);
            signal e_bis : unsigned(2 downto 0);
            signal exp_s : std_logic_vector(DC_W -1 downto 0);
            signal ceq_s : std_logic_vector(DC_W/16 -1 downto 0);

            signal s1_vld     : std_logic;
            signal s1_sof     : std_logic;
            signal s1_eof     : std_logic;
            signal s1_xv      : std_logic;
            signal s1_id_err  : std_logic;
            signal s1_unexp   : std_logic;
            signal s1_fmt_ok  : std_logic;
            signal s1_frm_err : std_logic;
            signal s1_ceq     : std_logic_vector(DC_W/16 -1 downto 0);
            signal s1_data    : std_logic_vector(DC_W -1 downto 0);
            signal s1_qid     : std_logic_vector(QID_W -1 downto 0);
            signal s1_cid     : std_logic_vector(DC_CID_W -1 downto 0);
            signal s1_lba     : unsigned(DC_LBA_W -1 downto 0);
            signal s1_sec     : unsigned(DC_LBA_W -1 downto 0);
            signal s1_num     : unsigned(7 downto 0);
            signal s1_bis     : unsigned(2 downto 0);
            signal s1_beat    : unsigned(DC_MM_W -1 downto 0);

            signal wmm_s      : std_logic_vector(7 downto 0);
            signal widx_s     : unsigned(2 downto 0);
            signal got_s      : std_logic_vector(63 downto 0);
            signal s2_vld     : std_logic;
            signal s2_sof     : std_logic;
            signal s2_eof     : std_logic;
            signal s2_xv      : std_logic;
            signal s2_mm      : std_logic;
            signal s2_id_err  : std_logic;
            signal s2_unexp   : std_logic;
            signal s2_fmt_ok  : std_logic;
            signal s2_frm_err : std_logic;
            signal s2_widx    : unsigned(2 downto 0);
            signal s2_got     : std_logic_vector(63 downto 0);
            signal s2_qid     : std_logic_vector(QID_W -1 downto 0);
            signal s2_cid     : std_logic_vector(DC_CID_W -1 downto 0);
            signal s2_lba     : unsigned(DC_LBA_W -1 downto 0);
            signal s2_sec     : unsigned(DC_LBA_W -1 downto 0);
            signal s2_num     : unsigned(7 downto 0);
            signal s2_bis     : unsigned(2 downto 0);
            signal s2_beat    : unsigned(DC_MM_W -1 downto 0);

            signal fr_mm      : unsigned(DC_MM_W -1 downto 0);
            signal fr_fmt     : std_logic;
            signal mm_base_s  : unsigned(DC_MM_W -1 downto 0);
            signal mm_tot_s   : unsigned(DC_MM_W -1 downto 0);
            signal fmt_err_s  : std_logic;
            signal len_ok_s   : std_logic;
            -- The S2 beat as a first-mismatch record, and the first mismatching beat of its frame so far.
            signal fm_beat_s  : std_logic_vector(FM_W -1 downto 0);
            signal fm_frm_s   : std_logic_vector(FM_W -1 downto 0);
            signal fr_fm      : std_logic_vector(FM_W -1 downto 0);
            -- A mismatching frame closed by S3, and a DATA_LOST report for this endpoint's queues.
            signal mn_vld     : std_logic;
            signal mn_tag     : std_logic_vector(DC_TAG_W -1 downto 0);
            signal mn_mm      : unsigned(DC_MM_W -1 downto 0);
            signal mn_fm      : std_logic_vector(FM_W -1 downto 0);
            signal rn_vld     : std_logic;
            signal rn_tag     : std_logic_vector(DC_TAG_W -1 downto 0);
            -- Each waits for the other: the DMA posts a report once its frame left the drain, which
            -- can be before or after the frame reaches this checker.
            signal mc_vld     : std_logic_vector(DC_CAM_N -1 downto 0);
            signal mc_tag     : dc_tag_arr_t;
            signal mc_mm      : dc_mm_arr_t;
            signal mc_fm      : dc_fm_arr_t;
            signal mc_tmo     : dc_mtmo_arr_t;
            signal lc_vld     : std_logic_vector(DC_CAM_N -1 downto 0);
            signal lc_tag     : dc_tag_arr_t;
            signal lc_tmo     : dc_ltmo_arr_t;
            signal a_lost_n   : unsigned(2 downto 0);
            signal a_lost_mm  : unsigned(DC_MM_W + 2 downto 0);
            signal a_data_n   : unsigned(2 downto 0);
            signal a_data_mm  : unsigned(DC_MM_W + 2 downto 0);
            signal a_mfull    : std_logic;
            signal a_lfull    : std_logic;
            signal a_fm_vld   : std_logic;
            signal a_fm       : std_logic_vector(FM_W -1 downto 0);

            signal cnt : dc_cnt_arr_t(0 to DC_EP_CNTS -1);
            signal flg : std_logic_vector(4 downto 0);

            signal sof_unexp_s : std_logic;
            signal xf_ovf_s    : std_logic;
        begin
            xf_i : entity work.FIFOX
            generic map (
                DATA_WIDTH          => DC_EXP_W,
                ITEMS               => DC_EXP_ITEMS,
                RAM_TYPE            => "URAM",
                DEVICE              => DEVICE,
                ALMOST_FULL_OFFSET  => 0,
                ALMOST_EMPTY_OFFSET => 0,
                FAKE_FIFO           => false
            )
            port map (
                CLK    => DMA_CLK,
                RESET  => dc_rst,
                DI     => dc_xf_di,
                WR     => dc_xf_wr(ep),
                FULL   => xf_full,
                AFULL  => open,
                STATUS => open,
                DO     => xf_do,
                RD     => xf_rd,
                EMPTY  => xf_empty,
                AEMPTY => open
            );

            s0_take <= s0_vld and s0_sof;
            xf_rd   <= (not xf_empty) and ((not nxt_vld) or s0_take);

            nxt_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    if (xf_rd = '1') then
                        nxt_vld <= '1';
                        nxt_qid <= xf_do(DC_EXP_W -1 downto DC_EXP_W - QID_W);
                        nxt_cid <= xf_do(DC_TBL_DW + DC_CID_W -1 downto DC_TBL_DW);
                        nxt_lba <= unsigned(xf_do(DC_TBL_DW -1 downto 8));
                        nxt_num <= unsigned(xf_do(7 downto 0));
                    elsif (s0_take = '1') then
                        nxt_vld <= '0';
                    end if;
                    if (dc_rst = '1') then
                        nxt_vld <= '0';
                    end if;
                end if;
            end process;

            s0_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    s0_vld       <= core_rd_mfb_src_rdy(ep) and core_rd_mfb_dst_rdy(ep);
                    s0_sof       <= core_rd_mfb_sof(ep)(0);
                    s0_eof       <= core_rd_mfb_eof(ep)(0);
                    s0_sofpos_ok <= '1' when (unsigned(core_rd_mfb_sof_pos(ep)) = 0) else '0';
                    s0_eofpos_ok <= and core_rd_mfb_eof_pos(ep);
                    s0_mqid      <= core_rd_mfb_meta(ep)(QID_W -1 downto 0);
                    s0_mcid      <= core_rd_mfb_meta(ep)(QID_W + CQ_ENTRY_CMD_ID_W -1 downto QID_W);
                    s0_data      <= core_rd_mfb_data(ep);
                    if (dc_rst = '1') then
                        s0_vld <= '0';
                    end if;
                end if;
            end process;

            -- Expectation of the S0 beat: shared by all eight words, so each muxed bit feeds eight
            -- comparators and the compare tree starts from registers on both sides.
            e_qid <= nxt_qid when (s0_sof = '1') else cur_qid;
            e_sec <= nxt_lba when (s0_sof = '1') else cur_sec;
            e_bis <= "000"   when (s0_sof = '1') else cur_bis;
            exp_s <= dc_pat_beat_f(e_qid, e_sec, e_bis);

            ceq_g : for c in 0 to DC_W/16 -1 generate
                ceq_s(c) <= '1' when (s0_data(16*c + 15 downto 16*c) = exp_s(16*c + 15 downto 16*c)) else '0';
            end generate;

            s1_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    s1_vld     <= s0_vld;
                    s1_sof     <= s0_sof;
                    s1_eof     <= s0_eof;
                    s1_ceq     <= ceq_s;
                    s1_data    <= s0_data;
                    s1_qid     <= e_qid;
                    s1_sec     <= e_sec;
                    s1_bis     <= e_bis;
                    s1_fmt_ok  <= ((not s0_sof) or s0_sofpos_ok) and ((not s0_eof) or s0_eofpos_ok);
                    s1_frm_err <= '1' when (s0_sof = cur_in_frame) else '0';
                    s1_unexp   <= s0_sof and not nxt_vld;
                    s1_id_err  <= '0';
                    if (s0_sof = '1') then
                        s1_cid  <= nxt_cid;
                        s1_lba  <= nxt_lba;
                        s1_num  <= nxt_num;
                        s1_xv   <= nxt_vld;
                        s1_beat <= (others => '0');
                        if (nxt_vld = '0' or s0_mqid /= nxt_qid
                            or unsigned(s0_mcid) /= resize(unsigned(nxt_cid), CQ_ENTRY_CMD_ID_W)) then
                            s1_id_err <= '1';
                        end if;
                    else
                        s1_cid  <= cur_cid;
                        s1_lba  <= cur_lba;
                        s1_num  <= cur_num;
                        s1_xv   <= cur_xv;
                        s1_beat <= cur_beat;
                    end if;

                    if (s0_vld = '1') then
                        if (s0_sof = '1') then
                            cur_qid  <= nxt_qid;
                            cur_cid  <= nxt_cid;
                            cur_lba  <= nxt_lba;
                            cur_num  <= nxt_num;
                            cur_xv   <= nxt_vld;
                            cur_sec  <= nxt_lba;
                            cur_bis  <= "001";
                            cur_beat <= to_unsigned(1, DC_MM_W);
                        else
                            cur_bis  <= cur_bis + 1;
                            cur_beat <= cur_beat + 1;
                            if (cur_bis = "111") then
                                cur_sec <= cur_sec + 1;
                            end if;
                        end if;
                        cur_in_frame <= not s0_eof;
                    end if;

                    if (dc_rst = '1') then
                        s1_vld       <= '0';
                        cur_in_frame <= '0';
                        cur_xv       <= '0';
                    end if;
                end if;
            end process;

            -- First mismatching word of the beat; its index selects the word reported as got.
            dc_wsel_p : process (all)
                variable wmm_v : std_logic_vector(7 downto 0);
                variable k_v   : natural range 0 to 7;
            begin
                k_v := 0;
                for w in 7 downto 0 loop
                    wmm_v(w) := not (s1_ceq(4*w) and s1_ceq(4*w + 1) and s1_ceq(4*w + 2) and s1_ceq(4*w + 3));
                    if (wmm_v(w) = '1') then
                        k_v := w;
                    end if;
                end loop;
                wmm_s  <= wmm_v;
                widx_s <= to_unsigned(k_v, 3);
                got_s  <= s1_data(64*k_v + 63 downto 64*k_v);
            end process;

            s2_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    s2_vld     <= s1_vld;
                    s2_sof     <= s1_sof;
                    s2_eof     <= s1_eof;
                    s2_xv      <= s1_xv;
                    s2_mm      <= (or wmm_s) and s1_xv;
                    s2_id_err  <= s1_id_err;
                    s2_unexp   <= s1_unexp;
                    s2_fmt_ok  <= s1_fmt_ok;
                    s2_frm_err <= s1_frm_err;
                    s2_widx    <= widx_s;
                    s2_got     <= got_s;
                    s2_qid     <= s1_qid;
                    s2_cid     <= s1_cid;
                    s2_lba     <= s1_lba;
                    s2_sec     <= s1_sec;
                    s2_num     <= s1_num;
                    s2_bis     <= s1_bis;
                    s2_beat    <= s1_beat;
                    if (dc_rst = '1') then
                        s2_vld <= '0';
                    end if;
                end if;
            end process;

            -- S3: per-frame totals, current beat included, so a frame's EOF beat closes it.
            mm_base_s <= (others => '0') when (s2_sof = '1') else fr_mm;
            mm_tot_s  <= mm_base_s + 1 when (s2_mm = '1') else mm_base_s;
            fmt_err_s <= ((not s2_sof) and fr_fmt) or (not s2_fmt_ok);
            len_ok_s  <= '1' when (s2_beat + 1 = shift_left(resize(s2_num, DC_MM_W) + 1, 3) and fmt_err_s = '0') else '0';
            fm_beat_s <= s2_qid & s2_cid & std_logic_vector(s2_lba) & std_logic_vector(s2_beat) & std_logic_vector(s2_widx)
                         & dc_pat_word_f(s2_qid, s2_sec, s2_bis, s2_widx) & s2_got;
            fm_frm_s  <= fm_beat_s when (s2_mm = '1' and mm_base_s = 0) else fr_fm;

            mn_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    mn_vld <= '1' when (s2_vld = '1' and s2_eof = '1' and mm_tot_s /= 0) else '0';
                    mn_tag <= s2_qid & s2_cid;
                    mn_mm  <= mm_tot_s;
                    mn_fm  <= fm_frm_s;
                    rn_vld <= dc_lf_wr(ep);
                    rn_tag <= dc_lf_di;
                    if (dc_rst = '1') then
                        mn_vld <= '0';
                        rn_vld <= '0';
                    end if;
                end if;
            end process;

            -- Only mismatching frames take part: a clean frame of the same tag, issued before the tag
            -- was reused, would otherwise claim a report meant for a later frame.
            rsv_p : process (DMA_CLK)
                variable mc_vld_v : std_logic_vector(DC_CAM_N -1 downto 0);
                variable lc_vld_v : std_logic_vector(DC_CAM_N -1 downto 0);
                variable hit_m    : integer range -1 to DC_CAM_N -1;
                variable hit_l    : integer range -1 to DC_CAM_N -1;
                variable free_m   : integer range -1 to DC_CAM_N -1;
                variable free_l   : integer range -1 to DC_CAM_N -1;
                variable direct_v : boolean;
                variable use_hm_v : boolean;
                variable use_hl_v : boolean;
                variable lost_n   : unsigned(2 downto 0);
                variable lost_mm  : unsigned(DC_MM_W + 2 downto 0);
                variable data_n   : unsigned(2 downto 0);
                variable data_mm  : unsigned(DC_MM_W + 2 downto 0);
                variable orph_n   : unsigned(2 downto 0);
                variable mfull_v  : std_logic;
                variable lfull_v  : std_logic;
                variable fm_vld_v : std_logic;
                variable fm_v     : std_logic_vector(FM_W -1 downto 0);
            begin
                if rising_edge(DMA_CLK) then
                    mc_vld_v := mc_vld;
                    lc_vld_v := lc_vld;
                    hit_m    := -1;
                    hit_l    := -1;
                    free_m   := -1;
                    free_l   := -1;
                    lost_n   := (others => '0');
                    lost_mm  := (others => '0');
                    data_n   := (others => '0');
                    data_mm  := (others => '0');
                    orph_n   := (others => '0');
                    mfull_v  := '0';
                    lfull_v  := '0';
                    fm_vld_v := '0';
                    fm_v     := mn_fm;

                    for i in DC_CAM_N -1 downto 0 loop
                        if (mc_vld(i) = '1' and mc_tag(i) = rn_tag) then
                            hit_m := i;
                        end if;
                        if (lc_vld(i) = '1' and lc_tag(i) = mn_tag) then
                            hit_l := i;
                        end if;
                        if (mc_vld(i) = '0') then
                            free_m := i;
                        end if;
                        if (lc_vld(i) = '0') then
                            free_l := i;
                        end if;
                    end loop;
                    direct_v := (mn_vld = '1' and rn_vld = '1' and mn_tag = rn_tag);
                    use_hm_v := (rn_vld = '1' and not direct_v and hit_m >= 0);
                    use_hl_v := (mn_vld = '1' and not direct_v and hit_l >= 0);

                    if (direct_v) then
                        lost_n  := lost_n + 1;
                        lost_mm := lost_mm + mn_mm;
                    end if;

                    if (use_hm_v) then
                        mc_vld_v(hit_m) := '0';
                        lost_n          := lost_n + 1;
                        lost_mm         := lost_mm + mc_mm(hit_m);
                    elsif (rn_vld = '1' and not direct_v) then
                        if (free_l >= 0) then
                            lc_vld_v(free_l) := '1';
                            lc_tag(free_l)   <= rn_tag;
                            lc_tmo(free_l)   <= to_unsigned(DC_ORPHAN_AGE, lc_tmo(0)'length);
                        else
                            orph_n  := orph_n + 1;
                            lfull_v := '1';
                        end if;
                    end if;

                    if (use_hl_v) then
                        lc_vld_v(hit_l) := '0';
                        lost_n          := lost_n + 1;
                        lost_mm         := lost_mm + mn_mm;
                    elsif (mn_vld = '1' and not direct_v) then
                        if (free_m >= 0) then
                            mc_vld_v(free_m) := '1';
                            mc_tag(free_m)   <= mn_tag;
                            mc_mm(free_m)    <= mn_mm;
                            mc_fm(free_m)    <= mn_fm;
                            mc_tmo(free_m)   <= to_unsigned(DC_MM_TMO, mc_tmo(0)'length);
                        else
                            data_n   := data_n + 1;
                            data_mm  := data_mm + mn_mm;
                            mfull_v  := '1';
                            fm_vld_v := '1';
                        end if;
                    end if;

                    -- A window closing unmatched: the frame was a real data error, the report an orphan.
                    -- The timed-out frame, older than one the full CAM refused, is the one offered as first mismatch.
                    for i in 0 to DC_CAM_N -1 loop
                        if (mc_vld(i) = '1') then
                            if (mc_tmo(i) = 0 and not (use_hm_v and hit_m = i)) then
                                mc_vld_v(i) := '0';
                                data_n      := data_n + 1;
                                data_mm     := data_mm + mc_mm(i);
                                fm_vld_v    := '1';
                                fm_v        := mc_fm(i);
                            end if;
                            mc_tmo(i) <= mc_tmo(i) - 1;
                        end if;
                        if (lc_vld(i) = '1' and core_rd_mfb_dst_rdy(ep) = '1') then
                            if (lc_tmo(i) = 0 and not (use_hl_v and hit_l = i)) then
                                lc_vld_v(i) := '0';
                                orph_n      := orph_n + 1;
                            end if;
                            lc_tmo(i) <= lc_tmo(i) - 1;
                        end if;
                    end loop;

                    mc_vld       <= mc_vld_v;
                    lc_vld       <= lc_vld_v;
                    a_lost_n     <= lost_n;
                    a_lost_mm    <= lost_mm;
                    a_data_n     <= data_n;
                    a_data_mm    <= data_mm;
                    a_mfull      <= mfull_v;
                    a_lfull      <= lfull_v;
                    dc_orph(ep)  <= std_logic_vector(orph_n);
                    a_fm_vld     <= fm_vld_v;
                    a_fm         <= fm_v;

                    if (dc_rst = '1') then
                        mc_vld       <= (others => '0');
                        lc_vld       <= (others => '0');
                        a_lost_n     <= (others => '0');
                        a_data_n     <= (others => '0');
                        a_lost_mm    <= (others => '0');
                        a_data_mm    <= (others => '0');
                        a_mfull      <= '0';
                        a_lfull      <= '0';
                        dc_orph(ep)  <= (others => '0');
                        a_fm_vld     <= '0';
                    end if;
                end if;
            end process;

            cnt_p : process (DMA_CLK)
            begin
                if rising_edge(DMA_CLK) then
                    if (s2_vld = '1') then
                        fr_mm  <= mm_tot_s;
                        fr_fmt <= fmt_err_s;
                        fr_fm  <= fm_frm_s;
                    end if;

                    if (dc_check_en = '1') then
                        if (s2_vld = '1') then
                            cnt(CE_BEATS) <= cnt(CE_BEATS) + 1;
                            if (s2_sof = '1' and s2_id_err = '1') then
                                cnt(CE_ID_ERR) <= cnt(CE_ID_ERR) + 1;
                            end if;
                            if (s2_eof = '1') then
                                cnt(CE_FRAMES) <= cnt(CE_FRAMES) + 1;
                                if (s2_xv = '1' and len_ok_s = '0') then
                                    cnt(CE_LEN_ERR) <= cnt(CE_LEN_ERR) + 1;
                                end if;
                            end if;
                        end if;
                        cnt(CE_LOST_FRM) <= cnt(CE_LOST_FRM) + a_lost_n;
                        cnt(CE_LOST_MMB) <= cnt(CE_LOST_MMB) + a_lost_mm;
                        cnt(CE_MM_FRMS)  <= cnt(CE_MM_FRMS) + a_data_n;
                        cnt(CE_MM_BEATS) <= cnt(CE_MM_BEATS) + a_data_mm;
                    end if;

                    if (dc_xf_wr(ep) = '1' and xf_full = '1') then
                        flg(0) <= '1';
                    end if;
                    if (a_lfull = '1') then
                        flg(1) <= '1';
                    end if;
                    if (a_mfull = '1') then
                        flg(2) <= '1';
                    end if;
                    if (s2_vld = '1' and s2_frm_err = '1') then
                        flg(3) <= '1';
                    end if;
                    if (s2_vld = '1' and s2_unexp = '1') then
                        flg(4) <= '1';
                    end if;

                    if (dc_rst = '1') then
                        cnt    <= (others => (others => '0'));
                        flg    <= (others => '0');
                        fr_mm  <= (others => '0');
                        fr_fmt <= '0';
                    end if;
                end if;
            end process;

            dc_ep_cnt(ep) <= cnt;
            dc_ep_sts(ep) <= cur_in_frame & (not (or lc_vld)) & (not ((or mc_vld) or mn_vld))
                             & (xf_empty and not nxt_vld) & flg;

            -- Gated like the data-error counters, which count the same frame in the same cycle.
            dc_fmo_vld(ep) <= a_fm_vld and dc_check_en;
            dc_fmo(ep)     <= a_fm;

            sof_unexp_s <= s0_take and not nxt_vld;
            xf_ovf_s    <= dc_xf_wr(ep) and xf_full;

            -- The expectation is pushed at the completion, the frame needs an HBM read after it.
            -- psl DC_FRAME_HAS_EXPECTATION : assert always ((dc_rst = '0') -> sof_unexp_s = '0')
            --     report "USER_CORE: a read frame started with no completed read waiting for it";

            -- psl DC_EXPECTATION_NO_OVERFLOW : assert always ((dc_rst = '0') -> xf_ovf_s = '0')
            --     report "USER_CORE: a completed read was dropped from a full expectation FIFO";
        end generate;

        -- Only frames already judged data errors reach it, so a frame reported lost never holds it.
        dc_fm_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                if (dc_rst = '1') then
                    dc_fm_vld <= '0';
                elsif (dc_fm_vld = '0') then
                    for ep in PCIE_ENDPOINTS -1 downto 0 loop
                        if (dc_fmo_vld(ep) = '1') then
                            dc_fm_vld <= '1';
                            dc_fm_ep  <= ep;
                            dc_fm     <= dc_fmo(ep);
                        end if;
                    end loop;
                end if;
            end if;
        end process;

        dc_fm_qid  <= dc_fm(FM_QID_LO + QID_W -1 downto FM_QID_LO);
        dc_fm_cid  <= dc_fm(FM_CID_LO + DC_CID_W -1 downto FM_CID_LO);
        dc_fm_lba  <= dc_fm(FM_LBA_LO + DC_LBA_W -1 downto FM_LBA_LO);
        dc_fm_beat <= dc_fm(FM_BEAT_LO + DC_MM_W -1 downto FM_BEAT_LO);
        dc_fm_widx <= dc_fm(FM_WIDX_LO + 2 downto FM_WIDX_LO);
        dc_fm_exp  <= dc_fm(FM_WIDX_LO -1 downto FM_EXP_LO);
        dc_fm_got  <= dc_fm(FM_EXP_LO -1 downto 0);

        -- -----------------------------------------------------------------------------------------
        -- Read-back: one counter at a time through a snapshot, so its two halves are one instant.
        -- -----------------------------------------------------------------------------------------
        dc_all_cnt(0 to DC_G_CNTS -1)                                     <= dc_g_cnt;
        dc_all_ep_g : for ep in 0 to PCIE_ENDPOINTS -1 generate
            dc_all_cnt(DC_G_CNTS + DC_EP_CNTS*ep to DC_G_CNTS + DC_EP_CNTS*(ep + 1) -1) <= dc_ep_cnt(ep);
        end generate;
        dc_all_cnt(DC_G_CNTS + DC_EP_CNTS*PCIE_ENDPOINTS to DC_Q_BASE -1)  <= (others => (others => '0'));
        dc_all_cnt(DC_Q_BASE to DC_ALL_CNTS -1)                            <= dc_q_cnt;

        dc_snap_p : process (DMA_CLK)
        begin
            if rising_edge(DMA_CLK) then
                if (unsigned(dc_sel_reg) < DC_ALL_CNTS) then
                    dc_cnt_mux_r <= dc_all_cnt(to_integer(unsigned(dc_sel_reg)));
                else
                    dc_cnt_mux_r <= (others => '0');
                end if;
                if (dc_sel_wr_d(1) = '1') then
                    dc_cnt_snap <= dc_cnt_mux_r;
                end if;
                if (core_rst = '1') then
                    dc_cnt_snap <= (others => '0');
                end if;
            end if;
        end process;

        -- STATUS: sticky [2*i + ep] for dc_ep_sts bit i (0..4), [10] CID beyond the table, [11] CID
        -- naming no accept; live [16 + 2*j + ep] for dc_ep_sts bit 5 + j (0..3); [31] mismatch latched.
        dc_status_p : process (all)
            variable sts_v : std_logic_vector(31 downto 0);
        begin
            sts_v := (others => '0');
            for ep in 0 to PCIE_ENDPOINTS -1 loop
                for i in 0 to 4 loop
                    sts_v(2*i + ep) := dc_ep_sts(ep)(i);
                end loop;
                for j in 0 to 3 loop
                    sts_v(16 + 2*j + ep) := dc_ep_sts(ep)(5 + j);
                end loop;
            end loop;
            sts_v(11 downto 10) := dc_g_flg;
            sts_v(31)           := dc_fm_vld;
            dc_status           <= sts_v;
        end process;

        dc_mi_rd_p : process (all)
            variable addr_v : std_logic_vector(7 downto 0);
        begin
            addr_v                          := (others => '0');
            addr_v(ADDR_LENGTH -1 downto 0) := mi_split_addr(0)(ADDR_LENGTH -1 downto 0);
            dc_mi_drd                       <= (others => '0');
            case addr_v is
                when x"88" =>
                    dc_mi_drd(31 downto 24) <= X"DC";
                    dc_mi_drd(1 downto 0)   <= dc_check_en & dc_pat_wr_en;
                when x"8C" => dc_mi_drd                         <= dc_span_reg;
                when x"90" => dc_mi_drd(7 downto 0)             <= dc_sel_reg;
                when x"94" => dc_mi_drd                         <= std_logic_vector(dc_cnt_snap(31 downto 0));
                when x"98" => dc_mi_drd(DC_CNT_W -33 downto 0)  <= std_logic_vector(dc_cnt_snap(DC_CNT_W -1 downto 32));
                when x"9C" => dc_mi_drd                         <= dc_status;
                when x"A0" =>
                    dc_mi_drd(DC_CID_W -1 downto 0)    <= dc_fm_cid;
                    dc_mi_drd(16 + QID_W -1 downto 16) <= dc_fm_qid;
                    dc_mi_drd(20)                      <= '1' when (dc_fm_ep = 1) else '0';
                    dc_mi_drd(31)                      <= dc_fm_vld;
                when x"A4" => dc_mi_drd                         <= dc_fm_lba(31 downto 0);
                when x"A8" => dc_mi_drd(DC_LBA_W -33 downto 0)  <= dc_fm_lba(DC_LBA_W -1 downto 32);
                when x"AC" =>
                    dc_mi_drd(DC_MM_W -1 downto 0) <= dc_fm_beat;
                    dc_mi_drd(18 downto 16)        <= dc_fm_widx;
                when x"B0" => dc_mi_drd                         <= dc_fm_exp(31 downto 0);
                when x"B4" => dc_mi_drd                         <= dc_fm_exp(63 downto 32);
                when x"B8" => dc_mi_drd                         <= dc_fm_got(31 downto 0);
                when x"BC" => dc_mi_drd                         <= dc_fm_got(63 downto 32);
                when others => null;
            end case;
        end process;

        -- psl DC_TBL_NO_COLLISION : assert always ((core_rst = '0') -> dc_tbl_coll = '0')
        --     report "USER_CORE: a table write and a completion lookup hit the same (qid, cid) in one cycle";

        -- psl DC_CID_NAMES_AN_ACCEPT : assert always ((core_rst = '0') -> dc_cid_unpaired = '0')
        --     report "USER_CORE: NVME_RD_REQ_CID_VLD named no accepted read, so its LBA is unknown";
    end generate;

    -- Interface pipeline: the architecture sits away from the DMA, so every interface is
    -- registered here. The request path is credit-based: it samples the per-queue ready
    -- combinationally when deciding to issue, which can't survive a registered ready.
    user_core_if_pipe_i : entity work.USER_CORE_IF_PIPE
    generic map (
        NUM_QUEUES      => NUM_QUEUES,
        PCIE_ENDPOINTS  => PCIE_ENDPOINTS,
        LBA_PTR_W       => SQE_LBA_PTR_W,
        MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,
        CID_W           => CQ_ENTRY_CMD_ID_W,
        STAGES          => IF_PIPE_STAGES,
        REQ_FIFO_ITEMS  => IF_PIPE_REQ_ITEMS,
        DEVICE          => DEVICE
    )
    port map (
        CLK       => DMA_CLK,
        RESET     => DMA_RST,
        ENG_RESET => core_rst,

        ENG_RD_REQ_LBA_PTR => core_rd_req_lba_ptr,
        ENG_RD_REQ_LBA_NUM => core_rd_req_lba_num,
        ENG_RD_REQ_QID     => nvme_rd_req_qid_s,
        ENG_RD_REQ_VLD     => rd_req_vld_s,
        ENG_RD_REQ_RDY     => core_rd_req_rdy,
        ENG_RD_REQ_CID     => core_rd_req_cid,
        ENG_RD_REQ_CID_VLD => core_rd_req_cid_vld,

        ENG_OP_STAT_TYPE => core_op_stat_type,
        ENG_OP_STAT_CODE => core_op_stat_code,
        ENG_OP_STAT_QID  => core_op_stat_qid,
        ENG_OP_STAT_CID  => core_op_stat_cid,
        ENG_OP_STAT_VLD  => core_op_stat_vld,

        ENG_RD_MFB_DATA    => core_rd_mfb_data,
        ENG_RD_MFB_META    => core_rd_mfb_meta,
        ENG_RD_MFB_SOF     => core_rd_mfb_sof,
        ENG_RD_MFB_EOF     => core_rd_mfb_eof,
        ENG_RD_MFB_SOF_POS => core_rd_mfb_sof_pos,
        ENG_RD_MFB_EOF_POS => core_rd_mfb_eof_pos,
        ENG_RD_MFB_SRC_RDY => core_rd_mfb_src_rdy,
        ENG_RD_MFB_DST_RDY => core_rd_mfb_dst_rdy,

        ENG_WR_MFB_DATA    => core_wr_mfb_data,
        ENG_WR_MFB_META    => core_wr_mfb_meta,
        ENG_WR_MFB_SOF     => core_wr_mfb_sof,
        ENG_WR_MFB_EOF     => core_wr_mfb_eof,
        ENG_WR_MFB_SOF_POS => core_wr_mfb_sof_pos,
        ENG_WR_MFB_EOF_POS => core_wr_mfb_eof_pos,
        ENG_WR_MFB_SRC_RDY => core_wr_mfb_src_rdy,
        ENG_WR_MFB_DST_RDY => core_wr_mfb_dst_rdy,

        DMA_RD_REQ_LBA_PTR => NVME_RD_REQ_LBA_PTR,
        DMA_RD_REQ_LBA_NUM => NVME_RD_REQ_LBA_NUM,
        DMA_RD_REQ_NPAGES_ALL => NVME_RD_REQ_NPAGES_ALL,
        DMA_RD_REQ_QID     => NVME_RD_REQ_QID,
        DMA_RD_REQ_VLD     => NVME_RD_REQ_VLD,
        DMA_RD_REQ_RDY     => NVME_RD_REQ_RDY,
        DMA_RD_REQ_CID     => NVME_RD_REQ_CID,
        DMA_RD_REQ_CID_VLD => NVME_RD_REQ_CID_VLD,

        DMA_OP_STAT_TYPE => NVME_OP_STAT_TYPE,
        DMA_OP_STAT_CODE => NVME_OP_STAT_CODE,
        DMA_OP_STAT_QID  => NVME_OP_STAT_QID,
        DMA_OP_STAT_CID  => NVME_OP_STAT_CID,
        DMA_OP_STAT_VLD  => NVME_OP_STAT_VLD,

        DMA_RD_MFB_DATA    => NVME_RD_MFB_DATA,
        DMA_RD_MFB_META    => NVME_RD_MFB_META,
        DMA_RD_MFB_SOF     => NVME_RD_MFB_SOF,
        DMA_RD_MFB_EOF     => NVME_RD_MFB_EOF,
        DMA_RD_MFB_SOF_POS => NVME_RD_MFB_SOF_POS,
        DMA_RD_MFB_EOF_POS => NVME_RD_MFB_EOF_POS,
        DMA_RD_MFB_SRC_RDY => NVME_RD_MFB_SRC_RDY,
        DMA_RD_MFB_DST_RDY => NVME_RD_MFB_DST_RDY,

        DMA_WR_MFB_DATA    => NVME_WR_MFB_DATA,
        DMA_WR_MFB_META    => NVME_WR_MFB_META,
        DMA_WR_MFB_SOF     => NVME_WR_MFB_SOF,
        DMA_WR_MFB_EOF     => NVME_WR_MFB_EOF,
        DMA_WR_MFB_SOF_POS => NVME_WR_MFB_SOF_POS,
        DMA_WR_MFB_EOF_POS => NVME_WR_MFB_EOF_POS,
        DMA_WR_MFB_SRC_RDY => NVME_WR_MFB_SRC_RDY,
        DMA_WR_MFB_DST_RDY => NVME_WR_MFB_DST_RDY
    );

end architecture;
