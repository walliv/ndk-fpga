-- user_core_groupby_arch.vhd: USER_CORE architecture hosting the streaming GROUP BY engine
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.nvme_meta_pack.all;

-- Selected by USR_CORE_ARCH=GROUPBY. Everything DMA-facing runs in DMA_CLK, so the only clock
-- crossing is the MI slave. The CSR block decodes the window flat, not behind an MI splitter:
-- one addressable block needs no decode stage or device-tree node.
architecture GROUPBY of USER_CORE is

    constant QID_W             : natural := maximum(1, log2(NUM_QUEUES));
    constant MFB_DATA_W        : natural := DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH;
    -- Register stages on each engine/DMA interface, and the per-queue request buffer backing the
    -- credit scheme; the buffer must exceed the 2*STAGES credit round trip.
    constant IF_PIPE_STAGES    : natural := 6;
    constant IF_PIPE_REQ_ITEMS : natural := 16;

    -- Table geometry. 4 lanes x 4096 slots = 16384 groups, and a key at or above that is counted
    -- rather than aggregated.
    constant LANES : natural := 4;
    constant SLOTS : natural := 4096;

    -- Sectors per read command, 0-based. Doubles as the reset value of the CTL_LBA_NUM register,
    -- so what software reads back before configuring anything is what the engine would use.
    constant RD_LBA_NUM : natural := 255;

    -- Only the low 8 bits of the MI address are decoded: the fixed registers sit below 0x80, the
    -- per-queue block at and above it. The file is dense enough that a splitter buys nothing.
    constant ADDR_LEN : natural := 8;

    -- Per-queue block at 0x80, stride 0x10. Address bit 7 selects the block, bits 6:4 name the
    -- queue and bits 3:2 the register inside its block, so the window holds up to 8 queues.
    constant PQ_BASE_BIT : natural := 7;
    constant PQ_IDX_W    : natural := 3;

    -- Records carried by one accepted read beat. The engine reports whole beats, so this is the
    -- fixed weight of one event and is what makes the event counter count records, not beats.
    constant RECS_BEAT : natural := 4;

    -- Longest averaging window software can ask for, ~0.54 s at 250 MHz: math_pack's log2
    -- overflows INTEGER once (MAX_INTERVAL_CYCLES+1)*(RECS_BEAT+1) passes 2**30, and the event
    -- counter sizes its accumulator with exactly that expression.
    constant EVCR_MAX_INTERVAL_CYCLES : natural := 2**27;
    constant EVCR_INTERVAL_W          : natural := log2(EVCR_MAX_INTERVAL_CYCLES + 1);
    constant EVCR_EVENTS_W            : natural := log2((EVCR_MAX_INTERVAL_CYCLES + 1)*(RECS_BEAT + 1));

    signal mi_addr_sync : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_dwr_sync  : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_be_sync   : std_logic_vector(MI_WIDTH/8-1 downto 0);
    signal mi_rd_sync   : std_logic;
    signal mi_wr_sync   : std_logic;
    signal mi_ardy_sync : std_logic;
    signal mi_drdy_sync : std_logic;
    signal mi_drd_sync  : std_logic_vector(MI_WIDTH-1 downto 0);

    -- Word select, so the range covers the decoded address bits only: bit 1 downto 0 are the byte
    -- offset inside the word and are never decoded.
    signal reg_sel : natural range 0 to 2**(ADDR_LEN-2)-1;

    signal ctl_start    : std_logic;
    signal ctl_fill     : std_logic;
    signal ctl_abort    : std_logic;
    signal ctl_in_lba   : std_logic_vector(SQE_LBA_PTR_W-1 downto 0);
    signal ctl_in_count : std_logic_vector(31 downto 0);
    signal ctl_out_lba  : std_logic_vector(SQE_LBA_PTR_W-1 downto 0);
    signal ctl_out_qid  : std_logic_vector(QID_W-1 downto 0);
    signal ctl_qid_mask : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ctl_lba_num  : std_logic_vector(7 downto 0);

    signal sts_busy    : std_logic;
    signal sts_done    : std_logic;
    signal sts_err     : std_logic;
    signal sts_state   : std_logic_vector(3 downto 0);
    signal sts_rec_cnt : std_logic_vector(47 downto 0);
    signal sts_oor_cnt : std_logic_vector(31 downto 0);
    signal sts_res_sec : std_logic_vector(31 downto 0);

    signal sts_issued_cnt : std_logic_vector(31 downto 0);
    signal sts_compl_cnt  : std_logic_vector(31 downto 0);
    signal sts_wr_issued  : std_logic_vector(31 downto 0);
    signal sts_wr_compl   : std_logic_vector(31 downto 0);
    signal sts_err_code   : std_logic_vector(1 downto 0);
    signal sts_err_type   : std_logic;
    signal sts_err_qid    : std_logic_vector(QID_W-1 downto 0);
    signal sts_err_vld    : std_logic;
    signal sts_lane_drain : std_logic_vector(LANES-1 downto 0);
    signal sts_stall_noq  : std_logic_vector(31 downto 0);
    signal sts_stall_dma  : std_logic_vector(31 downto 0);
    signal sts_stall_wb   : std_logic_vector(31 downto 0);
    signal sts_rec_event  : std_logic;

    signal sts_pq_sect_left : std_logic_vector(32*NUM_QUEUES-1 downto 0);
    signal sts_pq_issued    : std_logic_vector(32*NUM_QUEUES-1 downto 0);
    signal sts_pq_ok        : std_logic_vector(32*NUM_QUEUES-1 downto 0);
    signal sts_pq_failed    : std_logic_vector(32*NUM_QUEUES-1 downto 0);

    -- High half of the record count, sampled when software reads the low half.
    signal rec_cnt_hi_shadow : std_logic_vector(15 downto 0);

    signal pq_sect_left_arr : slv_array_t(NUM_QUEUES-1 downto 0)(31 downto 0);
    signal pq_issued_arr    : slv_array_t(NUM_QUEUES-1 downto 0)(31 downto 0);
    signal pq_ok_arr        : slv_array_t(NUM_QUEUES-1 downto 0)(31 downto 0);
    signal pq_failed_arr    : slv_array_t(NUM_QUEUES-1 downto 0)(31 downto 0);

    signal pq_hit     : std_logic;
    signal pq_idx     : natural range 0 to 2**PQ_IDX_W-1;
    signal pq_idx_lim : natural range 0 to NUM_QUEUES-1;
    signal pq_reg     : natural range 0 to 3;
    signal pq_drd     : std_logic_vector(31 downto 0);

    signal evcr_interval_cycles_reg : std_logic_vector(EVCR_INTERVAL_W-1 downto 0);
    signal evcr_interval_set        : std_logic;
    signal evcr_total_events        : std_logic_vector(EVCR_EVENTS_W-1 downto 0);
    signal evcr_total_cycles        : std_logic_vector(EVCR_INTERVAL_W-1 downto 0);
    signal evcr_total_events_reg    : std_logic_vector(EVCR_EVENTS_W-1 downto 0);
    signal evcr_total_cycles_reg    : std_logic_vector(EVCR_INTERVAL_W-1 downto 0);
    signal evcr_update              : std_logic;

    signal eng_rd_req_qid : std_logic_vector(QID_W-1 downto 0);
    signal eng_rd_req_vld : std_logic;

    -- Engine-side halves of the DMA interfaces; the pipeline sits between these and the ports.
    signal eng_rd_req_lba_ptr : std_logic_vector(SQE_LBA_PTR_W-1 downto 0);
    signal eng_rd_req_lba_num : std_logic_vector(7 downto 0);
    signal eng_rd_req_rdy     : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal eng_rst            : std_logic;

    signal eng_op_stat_type : std_logic;
    signal eng_op_stat_code : std_logic_vector(1 downto 0);
    signal eng_op_stat_qid  : std_logic_vector(QID_W-1 downto 0);
    signal eng_op_stat_vld  : std_logic;

    signal eng_rd_mfb_data    : std_logic_vector(MFB_DATA_W-1 downto 0);
    signal eng_rd_mfb_sof     : std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
    signal eng_rd_mfb_eof     : std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
    signal eng_rd_mfb_sof_pos : std_logic_vector(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
    signal eng_rd_mfb_eof_pos : std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)-1 downto 0);
    signal eng_rd_mfb_src_rdy : std_logic;
    signal eng_rd_mfb_dst_rdy : std_logic;

    signal eng_wr_mfb_data    : std_logic_vector(MFB_DATA_W-1 downto 0);
    signal eng_wr_mfb_meta    : std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + QID_W)-1 downto 0);
    signal eng_wr_mfb_sof     : std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
    signal eng_wr_mfb_eof     : std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
    signal eng_wr_mfb_sof_pos : std_logic_vector(DMA_MFB_REGIONS*max(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
    signal eng_wr_mfb_eof_pos : std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)-1 downto 0);
    signal eng_wr_mfb_src_rdy : std_logic;
    signal eng_wr_mfb_dst_rdy : std_logic;

begin

    -- =============================================================================================
    -- MI slave: cross into DMA_CLK, then a flat register file
    -- =============================================================================================
    mi_async_i : entity work.MI_ASYNC
    generic map (
        ADDR_WIDTH => MI_WIDTH,
        DATA_WIDTH => MI_WIDTH,
        DEVICE     => DEVICE
    )
    port map (
        CLK_M     => MI_CLK,
        RESET_M   => MI_RST,
        MI_M_ADDR => MI_ADDR,
        MI_M_DWR  => MI_DWR,
        MI_M_BE   => MI_BE,
        MI_M_RD   => MI_RD,
        MI_M_WR   => MI_WR,
        MI_M_ARDY => MI_ARDY,
        MI_M_DRDY => MI_DRDY,
        MI_M_DRD  => MI_DRD,
        CLK_S     => DMA_CLK,
        RESET_S   => eng_rst,
        MI_S_ADDR => mi_addr_sync,
        MI_S_DWR  => mi_dwr_sync,
        MI_S_BE   => mi_be_sync,
        MI_S_RD   => mi_rd_sync,
        MI_S_WR   => mi_wr_sync,
        MI_S_ARDY => mi_ardy_sync,
        MI_S_DRDY => mi_drdy_sync,
        MI_S_DRD  => mi_drd_sync
    );

    mi_ardy_sync <= mi_rd_sync or mi_wr_sync;
    reg_sel      <= to_integer(unsigned(mi_addr_sync(ADDR_LEN-1 downto 2)));

    mi_write_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            -- Start is a pulse, not a level: the engine re-arms on it from DONE or ERR. The
            -- interval load is a pulse for the same reason: it restarts the counting window.
            ctl_start         <= '0';
            evcr_interval_set <= '0';

            if (mi_wr_sync = '1') then
                case reg_sel is
                    when 0 =>                                       -- 0x00 CTRL
                        ctl_start <= mi_dwr_sync(0);
                        ctl_fill  <= mi_dwr_sync(1);
                        ctl_abort <= mi_dwr_sync(2);
                    when 1  => ctl_in_lba(31 downto 0)   <= mi_dwr_sync;                    -- 0x04
                    when 2  => ctl_in_lba(63 downto 32)  <= mi_dwr_sync;                    -- 0x08
                    when 3  => ctl_in_count              <= mi_dwr_sync;                    -- 0x0C
                    when 4  => ctl_out_lba(31 downto 0)  <= mi_dwr_sync;                    -- 0x10
                    when 5  => ctl_out_lba(63 downto 32) <= mi_dwr_sync;                    -- 0x14
                    when 6  => ctl_out_qid  <= mi_dwr_sync(QID_W-1 downto 0);               -- 0x18
                    when 7  => ctl_qid_mask <= mi_dwr_sync(NUM_QUEUES-1 downto 0);          -- 0x1C
                    when 14 => ctl_lba_num  <= mi_dwr_sync(7 downto 0);                     -- 0x38
                    when 24 =>                                      -- 0x60 EVCR_INTERVAL
                        evcr_interval_cycles_reg <= mi_dwr_sync(EVCR_INTERVAL_W-1 downto 0);
                        evcr_interval_set        <= '1';
                    when others => null;
                end case;
            end if;

            if (eng_rst = '1') then
                ctl_start    <= '0';
                ctl_fill     <= '0';
                ctl_abort    <= '0';
                ctl_in_lba   <= (others => '0');
                ctl_in_count <= (others => '0');
                ctl_out_lba  <= (others => '0');
                ctl_out_qid  <= (others => '0');
                -- Every queue enabled by default, so a run works without configuring the mask.
                ctl_qid_mask <= (others => '1');
                ctl_lba_num  <= std_logic_vector(to_unsigned(RD_LBA_NUM, ctl_lba_num'length));

                evcr_interval_cycles_reg <= (others => '1');
                evcr_interval_set        <= '0';
            end if;
        end if;
    end process;

    mi_read_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            mi_drdy_sync <= mi_rd_sync;

            case reg_sel is
                when 0  => mi_drd_sync <= (31 downto 3 => '0') & ctl_abort & ctl_fill & ctl_start;
                when 1  => mi_drd_sync <= ctl_in_lba(31 downto 0);
                when 2  => mi_drd_sync <= ctl_in_lba(63 downto 32);
                when 3  => mi_drd_sync <= ctl_in_count;
                when 4  => mi_drd_sync <= ctl_out_lba(31 downto 0);
                when 5  => mi_drd_sync <= ctl_out_lba(63 downto 32);
                when 6  => mi_drd_sync <= std_logic_vector(resize(unsigned(ctl_out_qid), 32));
                when 7  => mi_drd_sync <= std_logic_vector(resize(unsigned(ctl_qid_mask), 32));
                when 8  => mi_drd_sync <= (31 downto 8 => '0') & sts_state
                                          & '0' & sts_err & sts_done & sts_busy;
                when 9  => mi_drd_sync <= sts_rec_cnt(31 downto 0);
                when 10 => mi_drd_sync <= std_logic_vector(resize(unsigned(rec_cnt_hi_shadow), 32));
                when 11 => mi_drd_sync <= sts_oor_cnt;
                when 12 => mi_drd_sync <= sts_res_sec;
                when 13 => mi_drd_sync <= std_logic_vector(to_unsigned(LANES*SLOTS, 32));
                when 14 => mi_drd_sync <= std_logic_vector(resize(unsigned(ctl_lba_num), 32));
                when 15 => mi_drd_sync <= sts_issued_cnt;                                   -- 0x3C
                when 16 => mi_drd_sync <= sts_compl_cnt;                                    -- 0x40
                when 17 => mi_drd_sync <= sts_wr_issued;                                    -- 0x44
                when 18 => mi_drd_sync <= sts_wr_compl;                                     -- 0x48
                when 19 => mi_drd_sync <= (31 downto 8 => '0')                              -- 0x4C
                                          & std_logic_vector(resize(unsigned(sts_err_qid), 4))
                                          & sts_err_vld & sts_err_type & sts_err_code;
                when 20 => mi_drd_sync <= std_logic_vector(resize(unsigned(sts_lane_drain), 32));
                when 21 => mi_drd_sync <= sts_stall_noq;                                    -- 0x54
                when 22 => mi_drd_sync <= sts_stall_dma;                                    -- 0x58
                when 23 => mi_drd_sync <= sts_stall_wb;                                     -- 0x5C
                when 24 => mi_drd_sync <= std_logic_vector(resize(unsigned(evcr_interval_cycles_reg), 32));
                when 25 => mi_drd_sync <= std_logic_vector(resize(unsigned(evcr_total_events_reg), 32));
                when 26 => mi_drd_sync <= std_logic_vector(resize(unsigned(evcr_total_cycles_reg), 32));
                when others =>
                    -- The per-queue block lives up here; everything else is unmapped, and a
                    -- recognisable pattern beats zeros when software reads the wrong offset.
                    if (pq_hit = '1') then
                        mi_drd_sync <= pq_drd;
                    else
                        mi_drd_sync <= X"CAFEBABE";
                    end if;
            end case;

            -- Reading REC_CNT_L latches the high half so the two words software holds come from
            -- one instant: a 4 TiB sweep retires more than 2**32 records, so the low word wraps
            -- mid-run and two reads could pair mismatched halves, off by 2**32.
            if (mi_rd_sync = '1' and reg_sel = 9) then
                rec_cnt_hi_shadow <= sts_rec_cnt(47 downto 32);
            end if;

            if (eng_rst = '1') then
                mi_drdy_sync      <= '0';
                rec_cnt_hi_shadow <= (others => '0');
            end if;
        end if;
    end process;

    -- The engine flattens its per-queue counters; split them back so one mux can serve the whole
    -- block indexed by the queue the address names.
    pq_sect_left_arr <= slv_array_deser(sts_pq_sect_left, NUM_QUEUES, 32);
    pq_issued_arr    <= slv_array_deser(sts_pq_issued, NUM_QUEUES, 32);
    pq_ok_arr        <= slv_array_deser(sts_pq_ok, NUM_QUEUES, 32);
    pq_failed_arr    <= slv_array_deser(sts_pq_failed, NUM_QUEUES, 32);

    pq_idx     <= to_integer(unsigned(mi_addr_sync(PQ_BASE_BIT-1 downto PQ_BASE_BIT-PQ_IDX_W)));
    pq_reg     <= to_integer(unsigned(mi_addr_sync(3 downto 2)));
    pq_hit     <= '1' when (mi_addr_sync(PQ_BASE_BIT) = '1' and pq_idx < NUM_QUEUES) else '0';
    -- The mux reads the arrays every cycle, so its index must stay inside them even for a queue
    -- the design was not built with; pq_hit is what turns those addresses into the unmapped word.
    pq_idx_lim <= pq_idx when (pq_idx < NUM_QUEUES) else 0;

    pq_rd_p : process (all) is
    begin
        case pq_reg is
            when 0      => pq_drd <= pq_sect_left_arr(pq_idx_lim);
            when 1      => pq_drd <= pq_issued_arr(pq_idx_lim);
            when 2      => pq_drd <= pq_ok_arr(pq_idx_lim);
            when others => pq_drd <= pq_failed_arr(pq_idx_lim);
        end case;
    end process;

    -- =============================================================================================
    -- Entries per second
    -- =============================================================================================
    eps_cntr_i : entity work.EVENT_COUNTER
    generic map (
        MAX_INTERVAL_CYCLES   => EVCR_MAX_INTERVAL_CYCLES,
        MAX_CONCURRENT_EVENTS => RECS_BEAT,
        -- ~30-bit accumulator: one DSP48E2 instead of a carry chain on the 250 MHz DMA_CLK.
        DSP_ACCUM             => TRUE
    )
    port map (
        CLK   => DMA_CLK,
        RESET => eng_rst,

        INTERVAL_CYCLES => evcr_interval_cycles_reg,
        INTERVAL_SET    => evcr_interval_set,

        -- Constant weight: the event already means a whole beat was accepted, and a beat always
        -- carries RECS_BEAT records. TOTAL_EVENTS therefore counts records, not beats, and cannot
        -- disagree with the record count the engine reports.
        EVENT_CNT => std_logic_vector(to_unsigned(RECS_BEAT, log2(RECS_BEAT + 1))),
        EVENT_VLD => sts_rec_event,

        TOTAL_EVENTS => evcr_total_events,
        TOTAL_CYCLES => evcr_total_cycles,
        TOTAL_UPDATE => evcr_update
    );

    -- Both totals are snapshotted on the same update, so the pair software divides describes one
    -- interval; reading the live outputs could let a boundary fall between the two MI reads and
    -- mix a numerator from one window with a denominator from the next.
    evcr_reg_p : process (DMA_CLK) is
    begin
        if (rising_edge(DMA_CLK)) then
            if (eng_rst = '1') then
                evcr_total_events_reg <= (others => '0');
                evcr_total_cycles_reg <= (others => '0');
            elsif (evcr_update = '1') then
                evcr_total_events_reg <= evcr_total_events;
                evcr_total_cycles_reg <= evcr_total_cycles;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- The engine
    -- =============================================================================================
    groupby_i : entity work.IUVENTUS_GROUPBY_ENGINE
    generic map (
        NUM_QUEUES      => NUM_QUEUES,
        LANES           => LANES,
        SLOTS           => SLOTS,
        SUM_W           => 64,
        CNT_W           => 32,
        LBA_PTR_W       => SQE_LBA_PTR_W,
        SECT_SIZE       => 512,
        RD_LBA_NUM      => RD_LBA_NUM,
        MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,
        DEVICE          => DEVICE
    )
    port map (
        CLK => DMA_CLK,
        RST => eng_rst,

        CTL_START       => ctl_start,
        CTL_FILL        => ctl_fill,
        CTL_IN_LBA      => ctl_in_lba,
        CTL_IN_COUNT    => ctl_in_count,
        CTL_OUT_LBA     => ctl_out_lba,
        CTL_OUT_QID     => ctl_out_qid,
        CTL_QID_MASK    => ctl_qid_mask,
        CTL_ABORT       => ctl_abort,
        CTL_LBA_NUM     => ctl_lba_num,

        STS_BUSY        => sts_busy,
        STS_DONE        => sts_done,
        STS_ERR         => sts_err,
        STS_STATE       => sts_state,
        STS_REC_CNT     => sts_rec_cnt,
        STS_OOR_CNT     => sts_oor_cnt,
        STS_RESULT_SECT => sts_res_sec,

        STS_ISSUED_CNT  => sts_issued_cnt,
        STS_COMPL_CNT   => sts_compl_cnt,
        STS_WR_ISSUED   => sts_wr_issued,
        STS_WR_COMPL    => sts_wr_compl,
        STS_ERR_CODE    => sts_err_code,
        STS_ERR_TYPE    => sts_err_type,
        STS_ERR_QID     => sts_err_qid,
        STS_ERR_VLD     => sts_err_vld,
        STS_LANE_DRAIN  => sts_lane_drain,
        STS_STALL_NOQ   => sts_stall_noq,
        STS_STALL_DMA   => sts_stall_dma,
        STS_STALL_WB    => sts_stall_wb,

        STS_PQ_SECT_LEFT => sts_pq_sect_left,
        STS_PQ_ISSUED    => sts_pq_issued,
        STS_PQ_OK        => sts_pq_ok,
        STS_PQ_FAILED    => sts_pq_failed,
        STS_REC_EVENT    => sts_rec_event,

        RD_REQ_LBA_PTR  => eng_rd_req_lba_ptr,
        RD_REQ_LBA_NUM  => eng_rd_req_lba_num,
        RD_REQ_QID      => eng_rd_req_qid,
        RD_REQ_VLD      => eng_rd_req_vld,
        RD_REQ_RDY      => eng_rd_req_rdy,

        OP_STAT_TYPE    => eng_op_stat_type,
        OP_STAT_CODE    => eng_op_stat_code,
        OP_STAT_QID     => eng_op_stat_qid,
        OP_STAT_VLD     => eng_op_stat_vld,

        RD_MFB_DATA     => eng_rd_mfb_data,
        RD_MFB_SOF      => eng_rd_mfb_sof,
        RD_MFB_EOF      => eng_rd_mfb_eof,
        RD_MFB_SOF_POS  => eng_rd_mfb_sof_pos,
        RD_MFB_EOF_POS  => eng_rd_mfb_eof_pos,
        RD_MFB_SRC_RDY  => eng_rd_mfb_src_rdy,
        RD_MFB_DST_RDY  => eng_rd_mfb_dst_rdy,

        WR_MFB_DATA     => eng_wr_mfb_data,
        WR_MFB_META     => eng_wr_mfb_meta,
        WR_MFB_SOF      => eng_wr_mfb_sof,
        WR_MFB_EOF      => eng_wr_mfb_eof,
        WR_MFB_SOF_POS  => eng_wr_mfb_sof_pos,
        WR_MFB_EOF_POS  => eng_wr_mfb_eof_pos,
        WR_MFB_SRC_RDY  => eng_wr_mfb_src_rdy,
        WR_MFB_DST_RDY  => eng_wr_mfb_dst_rdy
    );

    -- Interface pipeline: the engine sits in its own corner of the die, far from the DMA. Every
    -- interface between them is registered here; the request path also expands the engine's
    -- scalar valid into the per-queue vector the entity carries.
    if_pipe_i : entity work.USER_CORE_IF_PIPE
    generic map (
        NUM_QUEUES      => NUM_QUEUES,
        LBA_PTR_W       => SQE_LBA_PTR_W,
        MFB_REGION_SIZE => DMA_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => DMA_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => DMA_MFB_ITEM_WIDTH,
        STAGES          => IF_PIPE_STAGES,
        REQ_FIFO_ITEMS  => IF_PIPE_REQ_ITEMS,
        DEVICE          => DEVICE
    )
    port map (
        CLK       => DMA_CLK,
        RESET     => DMA_RST,
        ENG_RESET => eng_rst,

        ENG_RD_REQ_LBA_PTR => eng_rd_req_lba_ptr,
        ENG_RD_REQ_LBA_NUM => eng_rd_req_lba_num,
        ENG_RD_REQ_QID     => eng_rd_req_qid,
        ENG_RD_REQ_VLD     => eng_rd_req_vld,
        ENG_RD_REQ_RDY     => eng_rd_req_rdy,
        ENG_RD_REQ_CID     => open,
        ENG_RD_REQ_CID_VLD => open,

        ENG_OP_STAT_TYPE => eng_op_stat_type,
        ENG_OP_STAT_CODE => eng_op_stat_code,
        ENG_OP_STAT_QID  => eng_op_stat_qid,
        ENG_OP_STAT_CID  => open,
        ENG_OP_STAT_VLD  => eng_op_stat_vld,

        ENG_RD_MFB_DATA    => eng_rd_mfb_data,
        ENG_RD_MFB_META    => open,
        ENG_RD_MFB_SOF     => eng_rd_mfb_sof,
        ENG_RD_MFB_EOF     => eng_rd_mfb_eof,
        ENG_RD_MFB_SOF_POS => eng_rd_mfb_sof_pos,
        ENG_RD_MFB_EOF_POS => eng_rd_mfb_eof_pos,
        ENG_RD_MFB_SRC_RDY => eng_rd_mfb_src_rdy,
        ENG_RD_MFB_DST_RDY => eng_rd_mfb_dst_rdy,

        ENG_WR_MFB_DATA    => eng_wr_mfb_data,
        ENG_WR_MFB_META    => eng_wr_mfb_meta,
        ENG_WR_MFB_SOF     => eng_wr_mfb_sof,
        ENG_WR_MFB_EOF     => eng_wr_mfb_eof,
        ENG_WR_MFB_SOF_POS => eng_wr_mfb_sof_pos,
        ENG_WR_MFB_EOF_POS => eng_wr_mfb_eof_pos,
        ENG_WR_MFB_SRC_RDY => eng_wr_mfb_src_rdy,
        ENG_WR_MFB_DST_RDY => eng_wr_mfb_dst_rdy,

        DMA_RD_REQ_LBA_PTR => NVME_RD_REQ_LBA_PTR,
        DMA_RD_REQ_LBA_NUM => NVME_RD_REQ_LBA_NUM,
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
