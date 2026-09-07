-- iuventus_groupby_engine.vhd: streaming GROUP BY over SSD-resident fixed-width records
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- Reads 16 B {key, value} records from SSDs through DMA Iuventus, sums value per key on chip, and
-- writes the table back as records of the same shape. Keys index slots directly, so the result is
-- exact below LANES*SLOTS; anything above lands in OOR_CNT.
entity IUVENTUS_GROUPBY_ENGINE is
    generic (
        NUM_QUEUES      : natural := 4;
        -- Aggregation banks. Fixed at 4 because a 64 B beat holds exactly 4 records, so one bank
        -- per record is what makes single-cycle beat retirement possible.
        LANES           : natural := 4;
        SLOTS           : natural := 4096;
        SUM_W           : natural := 64;
        CNT_W           : natural := 32;
        LBA_PTR_W       : natural := 64;
        SECT_SIZE       : natural := 512;
        -- LBAs per read command, 0-based as the DMA expects. 255 is 128 KiB, where the measured
        -- throughput curve is flat.
        RD_LBA_NUM      : natural := 255;
        -- Only the position-port widths are taken from these; the datapath is fixed at one
        -- 512 b region, which the assertion below enforces.
        MFB_REGION_SIZE : natural := 8;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 8;
        DEVICE          : string  := "ULTRASCALE"
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- Control and status, driven from the architecture's CSR block
        -- =========================================================================================
        CTL_START     : in  std_logic;                       -- one-cycle pulse
        -- Level, sampled at start. Writes a deterministic record set over the input range first,
        -- so a card with the GROUPBY core built has a way to put records on an SSD at all.
        CTL_FILL      : in  std_logic;
        CTL_IN_LBA    : in  std_logic_vector(LBA_PTR_W-1 downto 0);
        CTL_IN_COUNT  : in  std_logic_vector(31 downto 0);   -- sectors to read
        CTL_OUT_LBA   : in  std_logic_vector(LBA_PTR_W-1 downto 0);
        CTL_OUT_QID   : in  std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        CTL_QID_MASK  : in  std_logic_vector(NUM_QUEUES-1 downto 0);
        -- Level. Forces the run to S_ERR from S_RUN or S_WB, the only way software can end a run
        -- that is waiting on a completion that will never arrive.
        CTL_ABORT     : in  std_logic := '0';
        -- Sectors per read command, 0-based. Software-settable so the command size can be swept
        -- without a rebuild; RD_LBA_NUM is the reset default.
        CTL_LBA_NUM   : in  std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(RD_LBA_NUM, 8));

        STS_BUSY        : out std_logic;
        STS_DONE        : out std_logic;
        STS_ERR         : out std_logic;
        STS_STATE       : out std_logic_vector(3 downto 0);
        STS_REC_CNT     : out std_logic_vector(47 downto 0);
        STS_OOR_CNT     : out std_logic_vector(31 downto 0);
        STS_RESULT_SECT : out std_logic_vector(31 downto 0);

        -- ==============================
        -- Observability. None of this affects the datapath; it exists so a run that misbehaves on
        -- hardware can be told apart from one that is merely slow.
        -- ==============================
        STS_ISSUED_CNT   : out std_logic_vector(31 downto 0);
        STS_COMPL_CNT    : out std_logic_vector(31 downto 0);
        STS_WR_ISSUED    : out std_logic_vector(31 downto 0);
        STS_WR_COMPL     : out std_logic_vector(31 downto 0);
        -- {valid, type, code} of the first failing completion, plus the queue it came from.
        STS_ERR_CODE     : out std_logic_vector(1 downto 0);
        STS_ERR_TYPE     : out std_logic;
        STS_ERR_QID      : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        STS_ERR_VLD      : out std_logic;
        STS_LANE_DRAIN   : out std_logic_vector(LANES-1 downto 0);
        -- Cycles spent unable to progress, split by cause: no queue offered work, the engine held
        -- the read bus off, the write-back was back-pressured.
        STS_STALL_NOQ    : out std_logic_vector(31 downto 0);
        STS_STALL_DMA    : out std_logic_vector(31 downto 0);
        STS_STALL_WB     : out std_logic_vector(31 downto 0);
        -- Per-queue progress, flattened. Queue q occupies bits [32*q+31 : 32*q].
        STS_PQ_SECT_LEFT : out std_logic_vector(32*NUM_QUEUES-1 downto 0);
        STS_PQ_ISSUED    : out std_logic_vector(32*NUM_QUEUES-1 downto 0);
        STS_PQ_OK        : out std_logic_vector(32*NUM_QUEUES-1 downto 0);
        STS_PQ_FAILED    : out std_logic_vector(32*NUM_QUEUES-1 downto 0);
        -- Records retired this cycle (0 or RECS_BEAT), for the entries-per-second counter. Driven
        -- from the same condition that advances STS_REC_CNT, so the two cannot disagree.
        STS_REC_EVENT    : out std_logic;

        -- =========================================================================================
        -- Read submit
        -- =========================================================================================
        RD_REQ_LBA_PTR : out std_logic_vector(LBA_PTR_W-1 downto 0);
        RD_REQ_LBA_NUM : out std_logic_vector(7 downto 0);
        RD_REQ_QID     : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        RD_REQ_VLD     : out std_logic;
        RD_REQ_RDY     : in  std_logic_vector(NUM_QUEUES-1 downto 0);

        -- ==============================
        -- Completions. A code other than success never drains a frame, so the run must abort.
        -- ==============================
        OP_STAT_TYPE : in std_logic;
        OP_STAT_CODE : in std_logic_vector(1 downto 0);
        -- Queue the completion belongs to. Only meaningful together with TYPE/CODE, and used here
        -- solely to attribute completions per queue: a 4-drive run needs to show which drive
        -- stopped answering.
        OP_STAT_QID  : in std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0) := (others => '0');
        OP_STAT_VLD  : in std_logic;

        -- Returned data, 64 B per beat. META is ignored (aggregation is commutative), so it
        -- doesn't matter which command produced a beat, only that it completed; this sidesteps
        -- the QID/CID bit-order disagreement between dma_iuventus.vhd and user_core_ent.vhd.
        RD_MFB_DATA    : in  std_logic_vector(511 downto 0);
        RD_MFB_SOF     : in  std_logic_vector(0 downto 0);
        RD_MFB_EOF     : in  std_logic_vector(0 downto 0);
        RD_MFB_SOF_POS : in  std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        RD_MFB_EOF_POS : in  std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        RD_MFB_SRC_RDY : in  std_logic;
        RD_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- Result write-back
        -- =========================================================================================
        WR_MFB_DATA    : out std_logic_vector(511 downto 0);
        WR_MFB_META    : out std_logic_vector(max(1, log2(NUM_QUEUES)) + LBA_PTR_W -1 downto 0);
        WR_MFB_SOF     : out std_logic_vector(0 downto 0);
        WR_MFB_EOF     : out std_logic_vector(0 downto 0);
        WR_MFB_SOF_POS : out std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        WR_MFB_EOF_POS : out std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        WR_MFB_SRC_RDY : out std_logic;
        WR_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of IUVENTUS_GROUPBY_ENGINE is

    constant QID_W     : natural := max(1, log2(NUM_QUEUES));
    constant SLOT_W    : natural := log2(SLOTS);
    constant LANE_W    : natural := log2(LANES);
    -- Keys at or above this are out of range and are not aggregated.
    constant GROUPS    : natural := LANES * SLOTS;
    constant KEY_IDX_W : natural := LANE_W + SLOT_W;
    -- Must equal IUVENTUS_GROUPBY_LANE's RD_LAT: the lane delays SWEEP_VLD by it, so the engine
    -- has to delay the pointer that names the result by the same amount.
    constant SWEEP_LAT : natural := 1;

    constant REC_W       : natural := 128;                               -- {value(64), key(64)}
    constant RECS_BEAT   : natural := 512 / REC_W;                       -- 4
    constant SECT_BEATS  : natural := SECT_SIZE / 64;                    -- 8
    constant RECS_SECT   : natural := (SECT_SIZE / 64) * (512 / REC_W);  -- 32
    -- Result records per 64 B beat, same shape as the input.
    constant RES_BEAT    : natural := RECS_BEAT;
    -- Beats a full result sweep produces, and the sectors that is.
    constant RES_SECT    : natural := GROUPS / (RES_BEAT * SECT_BEATS);

    type   state_t is (
        S_IDLE, S_FILL, S_FILL_WAIT, S_CLEAR, S_RUN, S_DRAIN, S_WB, S_DONE, S_ERR
    );
    signal state : state_t;

    -- issue side -- One cursor per queue: each drive has its own address space, so every queue
    -- sweeps [CTL_IN_LBA, +CTL_IN_COUNT) on its own drive, independently -- not striping one range
    -- across drives.
    type   lba_arr_t is array (0 to NUM_QUEUES-1) of unsigned(LBA_PTR_W-1 downto 0);
    type   sect_arr_t is array (0 to NUM_QUEUES-1) of unsigned(31 downto 0);
    type   cnt32_arr_t is array (0 to NUM_QUEUES-1) of unsigned(31 downto 0);
    signal sect_left  : sect_arr_t;
    signal next_lba   : lba_arr_t;
    -- '1' while any queue still owes requests; the run cannot finish before it clears.
    signal sect_any   : std_logic;
    signal beat_take  : std_logic;
    signal rr_qid     : unsigned(QID_W-1 downto 0);
    signal issued_cnt : unsigned(31 downto 0);
    signal compl_cnt  : unsigned(31 downto 0);
    signal this_num   : unsigned(7 downto 0);
    signal req_fire   : std_logic;
    signal q_ok       : std_logic;
    -- The cursor of the queue the round-robin is presenting this cycle, hoisted so the fit test
    -- and the request ports read one mux rather than three.
    signal rr_sect    : unsigned(31 downto 0);
    signal rr_lba     : unsigned(LBA_PTR_W-1 downto 0);
    signal rr_work    : std_logic;

    -- ---- per-queue observability ---------------------------------------------------------------
    -- A 4-SSD run is only diagnosable per queue: a single aggregate count cannot show that one
    -- drive stopped participating.
    signal pq_issued : cnt32_arr_t;
    signal pq_ok     : cnt32_arr_t;
    signal pq_failed : cnt32_arr_t;
    -- Latched identity of the first failing completion, sticky until the next start.
    signal err_code  : std_logic_vector(1 downto 0);
    signal err_type  : std_logic;
    signal err_qid   : std_logic_vector(QID_W-1 downto 0);
    signal err_vld   : std_logic;
    -- Stall classes, so a stalled run says which side is at fault.
    signal stall_noq : unsigned(31 downto 0);
    signal stall_dma : unsigned(31 downto 0);
    signal stall_wb  : unsigned(31 downto 0);

    -- ---- beat staging --------------------------------------------------------------------------
    -- A beat is held until every one of its records has been dispatched. Records that share a lane
    -- go one per cycle, so a beat retires in 1 to LANES cycles.
    signal beat_data : std_logic_vector(511 downto 0);
    signal beat_pend : std_logic_vector(RECS_BEAT-1 downto 0);
    signal beat_busy : std_logic;

    type   key_arr_t is array (0 to RECS_BEAT-1) of std_logic_vector(63 downto 0);
    type   value_arr_t is array (0 to RECS_BEAT-1) of std_logic_vector(63 downto 0);
    signal rec_key : key_arr_t;
    signal rec_val : value_arr_t;

    type   slot_arr_t is array (0 to LANES-1) of std_logic_vector(SLOT_W-1 downto 0);
    type   val_arr_t is array (0 to LANES-1) of std_logic_vector(63 downto 0);
    signal lane_slot : slot_arr_t;
    signal lane_val  : val_arr_t;
    signal lane_vld  : std_logic_vector(LANES-1 downto 0);
    signal lane_take : std_logic_vector(RECS_BEAT-1 downto 0);

    signal lane_drained : std_logic_vector(LANES-1 downto 0);
    signal rec_cnt      : unsigned(47 downto 0);
    -- Records every accepted request will eventually deliver. A read completion only says the data
    -- reached the DMA's buffer, so it is not proof the engine has seen it; this is.
    signal recs_exp     : unsigned(47 downto 0);
    signal oor_cnt      : unsigned(31 downto 0);

    -- ---- clear / sweep / write-back ------------------------------------------------------------
    signal clear_addr : unsigned(SLOT_W-1 downto 0);
    signal clear_en   : std_logic;
    signal sweep_addr : unsigned(SLOT_W-1 downto 0);
    signal sweep_lane : unsigned(LANE_W-1 downto 0);
    signal sweep_en   : std_logic;

    type   sum_arr_t is array (0 to LANES-1) of std_logic_vector(SUM_W-1 downto 0);
    type   cnt_arr_t is array (0 to LANES-1) of std_logic_vector(CNT_W-1 downto 0);
    signal lane_sum  : sum_arr_t;
    signal lane_cnt  : cnt_arr_t;
    signal lane_svld : std_logic_vector(LANES-1 downto 0);

    -- Sweep issue pointer, plus the copy delayed to match the lane's read latency. A result
    -- landing now belongs to the address issued SWEEP_LAT cycles ago, not to the pointer's
    -- current value.
    signal sweep_active : std_logic;
    signal sweep_stall  : std_logic;
    signal sw_addr_d    : unsigned(SLOT_W-1 downto 0);
    signal sw_lane_d    : unsigned(LANE_W-1 downto 0);
    signal sw_res_vld   : std_logic;

    signal wb_data   : std_logic_vector(511 downto 0);
    signal wb_fill   : unsigned(log2(RES_BEAT+1)-1 downto 0);
    signal wb_full   : std_logic;
    signal out_data  : std_logic_vector(511 downto 0);
    signal out_vld   : std_logic;
    signal wb_beat   : unsigned(31 downto 0);
    signal wb_lba    : unsigned(LBA_PTR_W-1 downto 0);
    signal wb_sof    : std_logic;
    signal err_r     : std_logic;
    -- START is only honoured from a settled state, so a stray pulse during a run cannot reload the
    -- issue pointers underneath it. Everything that arms on a start uses this, not CTL_START.
    signal start_ok  : std_logic;
    signal settled   : std_logic;

    -- ---- self-test fill --------------------------------------------------------------------
    signal fill_idx        : unsigned(31 downto 0);
    signal fill_beats_left : unsigned(31 downto 0);
    type   fill_key_arr_t is array (0 to RECS_BEAT-1) of unsigned(63 downto 0);
    signal fill_key        : fill_key_arr_t;
    signal fill_data       : std_logic_vector(511 downto 0);
    signal fill_push       : std_logic;
    signal fill_room       : std_logic;
    signal wr_issued       : unsigned(31 downto 0);
    signal wr_compl        : unsigned(31 downto 0);

begin

    assert (LANES = 4 and RECS_BEAT = 4)
        report "IUVENTUS_GROUPBY_ENGINE: the beat splitter assumes 4 records of 16 B per 64 B beat."
        severity FAILURE;

    assert (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH = 512)
        report "IUVENTUS_GROUPBY_ENGINE: the datapath is fixed at one 512 b MFB region."
        severity FAILURE;

    -- psl default clock is rising_edge(CLK);
    -- The record splitter indexes a beat from bit 0, ignoring the position ports: sound only
    -- because the DMA returns whole sectors (eight full beats), so a frame never starts or ends
    -- mid-beat.
    -- psl assert_rd_beat_aligned : assert always
    --     ((RST = '0' and RD_MFB_SRC_RDY = '1') ->
    --      ((RD_MFB_SOF = "0" or unsigned(RD_MFB_SOF_POS) = 0) and
    --       (RD_MFB_EOF = "0" or RD_MFB_EOF_POS = (RD_MFB_EOF_POS'range => '1'))))
    --     report "IUVENTUS_GROUPBY_ENGINE: read frame is not beat-aligned!";

    -- ==============================
    -- Record extraction: records are 16 B and a 64 B beat holds exactly four, so nothing straddles
    -- a beat and no alignment state is needed.
    -- ==============================
    rec_split_g : for i in 0 to RECS_BEAT-1 generate
        rec_key(i) <= beat_data(i*REC_W + 63 downto i*REC_W);
        rec_val(i) <= beat_data(i*REC_W + 127 downto i*REC_W + 64);
    end generate;

    -- ==============================
    -- Self-test record generator: key = index mod GROUPS (GROUPS a power of two), value = key+1,
    -- so group g holds count(g)*(g+1) -- sensitive to a mis-routed lane or a sum/count swap.
    -- ==============================
    fill_g : for i in 0 to RECS_BEAT-1 generate
        fill_key(i) <= resize(fill_idx(KEY_IDX_W-1 downto 0) + i, 64);

        fill_data(i*REC_W + 63 downto i*REC_W)       <= std_logic_vector(fill_key(i));
        fill_data(i*REC_W + 127 downto i*REC_W + 64) <= std_logic_vector(fill_key(i) + 1);
    end generate;

    fill_room <= '1' when (out_vld = '0' or WR_MFB_DST_RDY = '1') else '0';
    fill_push <= '1' when (state = S_FILL and fill_beats_left /= 0 and fill_room = '1') else '0';

    -- ==============================
    -- Lane arbitration: each lane takes the lowest-indexed pending record that targets it. A
    -- record whose key is out of range is retired without being dispatched.
    -- ==============================
    arb_p : process (all) is
        variable v_taken : std_logic_vector(RECS_BEAT-1 downto 0);
        variable v_done  : std_logic;
    begin
        lane_vld  <= (others => '0');
        lane_slot <= (others => (others => '0'));
        lane_val  <= (others => (others => '0'));
        v_taken   := (others => '0');

        for l in 0 to LANES-1 loop
            v_done := '0';
            for i in 0 to RECS_BEAT-1 loop
                if (v_done = '0' and beat_pend(i) = '1'
                    and unsigned(rec_key(i)(LANE_W-1 downto 0)) = to_unsigned(l, LANE_W)
                    and unsigned(rec_key(i)(63 downto KEY_IDX_W)) = 0) then
                    lane_vld(l)  <= '1';
                    lane_slot(l) <= rec_key(i)(KEY_IDX_W-1 downto LANE_W);
                    lane_val(l)  <= rec_val(i);
                    v_taken(i)   := '1';
                    v_done       := '1';
                end if;
            end loop;
        end loop;

        -- Out-of-range records never reach a lane, so retire them here or the beat never empties.
        for i in 0 to RECS_BEAT-1 loop
            if (beat_pend(i) = '1' and unsigned(rec_key(i)(63 downto KEY_IDX_W)) /= 0) then
                v_taken(i) := '1';
            end if;
        end loop;

        lane_take <= v_taken;
    end process;

    -- ==============================
    -- Beat acceptance: a new beat is taken only when the previous one has fully retired, so input
    -- stalls for as many cycles as the beat's worst lane collision.
    -- ==============================
    beat_p : process (CLK) is
        variable v_pend : std_logic_vector(RECS_BEAT-1 downto 0);
        variable v_oor  : natural range 0 to RECS_BEAT;
    begin
        if (rising_edge(CLK)) then
            v_pend := beat_pend and not lane_take;

            if (beat_busy = '1') then
                beat_pend <= v_pend;
                if (v_pend = (v_pend'range => '0')) then
                    beat_busy <= '0';
                end if;
            end if;

            if (beat_take = '1') then
                beat_data <= RD_MFB_DATA;
                beat_pend <= (others => '1');
                beat_busy <= '1';
            end if;

            -- Counted at acceptance rather than at dispatch: every record in an accepted beat is
            -- either aggregated or out of range, and both are accounted for.
            if (beat_take = '1') then
                rec_cnt <= rec_cnt + RECS_BEAT;
                v_oor   := 0;
                for i in 0 to RECS_BEAT-1 loop
                    if (unsigned(RD_MFB_DATA(i*REC_W + 63 downto i*REC_W + KEY_IDX_W)) /= 0) then
                        v_oor := v_oor + 1;
                    end if;
                end loop;
                oor_cnt <= oor_cnt + v_oor;
            end if;

            if (RST = '1' or start_ok = '1') then
                beat_busy <= '0';
                beat_pend <= (others => '0');
                rec_cnt   <= (others => '0');
                oor_cnt   <= (others => '0');
            end if;
        end if;
    end process;

    -- Accept a beat when idle, or when the current beat's last records retire. S_ERR also accepts,
    -- as a pure sink: an aborted run leaves reads outstanding, and refusing them would back up
    -- into the DMA and jam the read path for every later run.
    RD_MFB_DST_RDY <= '1' when (state = S_ERR
                                or (state = S_RUN
                                    and (beat_busy = '0'
                                         or (beat_pend and not lane_take) = (beat_pend'range => '0')))) else
                      '0';

    beat_take <= RD_MFB_SRC_RDY and RD_MFB_DST_RDY when (state = S_RUN) else '0';

    -- =============================================================================================
    -- Aggregation banks
    -- =============================================================================================
    lane_g : for l in 0 to LANES-1 generate
        lane_i : entity work.IUVENTUS_GROUPBY_LANE
        generic map (
            SLOTS   => SLOTS,
            SUM_W   => SUM_W,
            CNT_W   => CNT_W,
            VALUE_W => 64,
            DEVICE  => DEVICE
        )
        port map (
            CLK        => CLK,
            RST        => RST,
            IN_SLOT    => lane_slot(l),
            IN_VALUE   => lane_val(l),
            IN_VLD     => lane_vld(l),
            CLEAR_ADDR => std_logic_vector(clear_addr),
            CLEAR_EN   => clear_en,
            SWEEP_ADDR => std_logic_vector(sweep_addr),
            SWEEP_EN   => sweep_en,
            SWEEP_SUM  => lane_sum(l),
            SWEEP_CNT  => lane_cnt(l),
            SWEEP_VLD  => lane_svld(l),
            DRAINED    => lane_drained(l)
        );
    end generate;

    -- ==============================
    -- Read issue. RDY is a per-queue credit from the interface pipeline, not back-pressure: one
    -- request is presented at a time, so a queue without credit is skipped, not waited on.
    -- ==============================
    rr_sect  <= sect_left(to_integer(rr_qid));
    rr_lba   <= next_lba(to_integer(rr_qid));
    rr_work  <= '1' when (rr_sect /= 0) else '0';

    q_ok     <= RD_REQ_RDY(to_integer(rr_qid)) and CTL_QID_MASK(to_integer(rr_qid)) and rr_work;
    req_fire <= '1' when (state = S_RUN and q_ok = '1') else '0';

    this_num <= unsigned(CTL_LBA_NUM) when (rr_sect > unsigned(CTL_LBA_NUM)) else
                resize(rr_sect - 1, 8);

    -- A run ends only when every queue has issued its whole range, not when one has.
    sect_any_p : process (all) is
        variable v : std_logic;
    begin
        v := '0';
        for q in 0 to NUM_QUEUES-1 loop
            if (sect_left(q) /= 0) then
                v := '1';
            end if;
        end loop;
        sect_any <= v;
    end process;

    RD_REQ_LBA_PTR <= std_logic_vector(rr_lba);
    RD_REQ_LBA_NUM <= std_logic_vector(this_num);
    RD_REQ_QID     <= std_logic_vector(rr_qid);
    RD_REQ_VLD     <= req_fire;

    issue_p : process (CLK) is
        -- The queue being presented this cycle, and the queue a completion belongs to. Hoisted to
        -- variables so each dynamic index is written once.
        variable rr : natural range 0 to NUM_QUEUES-1;
        variable cq : natural range 0 to NUM_QUEUES-1;
    begin
        if (rising_edge(CLK)) then
            rr := to_integer(rr_qid);
            -- Round-robin every cycle, so a queue that is not ready costs one cycle rather than
            -- blocking the sweep.
            if (state = S_RUN) then
                if (rr_qid = NUM_QUEUES-1) then
                    rr_qid <= (others => '0');
                else
                    rr_qid <= rr_qid + 1;
                end if;
            end if;

            if (req_fire = '1') then
                recs_exp       <= recs_exp + resize((resize(this_num, 9) + 1) * RECS_SECT, 48);
                next_lba(rr)   <= rr_lba + resize(this_num, LBA_PTR_W) + 1;
                sect_left(rr)  <= rr_sect - resize(this_num, 32) - 1;
                issued_cnt     <= issued_cnt + 1;
                pq_issued(rr)  <= pq_issued(rr) + 1;
            end if;

            -- Stall classes. Counted only while the run is actually trying to make progress, so a
            -- zero here means "not stalled", not "not running".
            if (state = S_RUN and sect_any = '1' and req_fire = '0') then
                stall_noq <= stall_noq + 1;
            end if;
            if (state = S_RUN and RD_MFB_SRC_RDY = '1' and RD_MFB_DST_RDY = '0') then
                stall_dma <= stall_dma + 1;
            end if;
            if (state = S_WB and sweep_stall = '1') then
                stall_wb <= stall_wb + 1;
            end if;

            if (OP_STAT_VLD = '1' and OP_STAT_TYPE = '0') then
                if (OP_STAT_CODE = "00") then
                    wr_compl <= wr_compl + 1;
                else
                    err_r <= '1';
                end if;
            end if;

            if (out_vld = '1' and WR_MFB_DST_RDY = '1' and wb_beat = SECT_BEATS-1) then
                wr_issued <= wr_issued + 1;
            end if;

            -- A read completion. Anything but success means no frame will ever drain for it.
            if (OP_STAT_VLD = '1' and OP_STAT_TYPE = '1') then
                cq := to_integer(unsigned(OP_STAT_QID)) mod NUM_QUEUES;
                if (OP_STAT_CODE = "00") then
                    compl_cnt    <= compl_cnt + 1;
                    pq_ok(cq)    <= pq_ok(cq) + 1;
                else
                    err_r         <= '1';
                    pq_failed(cq) <= pq_failed(cq) + 1;
                end if;
            end if;

            -- First failure wins: the identity that explains the run is the one that ended it, and
            -- later failures are consequences of the same abort.
            if (OP_STAT_VLD = '1' and OP_STAT_CODE /= "00" and err_vld = '0') then
                err_code <= OP_STAT_CODE;
                err_type <= OP_STAT_TYPE;
                err_qid  <= OP_STAT_QID;
                err_vld  <= '1';
            end if;

            if (start_ok = '1') then
                wr_issued  <= (others => '0');
                wr_compl   <= (others => '0');
                rr_qid     <= (others => '0');
                issued_cnt <= (others => '0');
                recs_exp   <= (others => '0');
                compl_cnt  <= (others => '0');
                err_r      <= '0';
                err_vld    <= '0';
                stall_noq  <= (others => '0');
                stall_dma  <= (others => '0');
                stall_wb   <= (others => '0');
                -- Every enabled queue gets the whole range on its own drive; a masked-out queue is
                -- seeded empty so it is exhausted from the start and never selected.
                for q in 0 to NUM_QUEUES-1 loop
                    next_lba(q)  <= unsigned(CTL_IN_LBA);
                    pq_issued(q) <= (others => '0');
                    pq_ok(q)     <= (others => '0');
                    pq_failed(q) <= (others => '0');
                    if (CTL_QID_MASK(q) = '1') then
                        sect_left(q) <= unsigned(CTL_IN_COUNT);
                    else
                        sect_left(q) <= (others => '0');
                    end if;
                end loop;
            end if;

            if (RST = '1') then
                wr_issued  <= (others => '0');
                wr_compl   <= (others => '0');
                issued_cnt <= (others => '0');
                recs_exp   <= (others => '0');
                compl_cnt  <= (others => '0');
                rr_qid     <= (others => '0');
                err_r      <= '0';
                err_vld    <= '0';
                stall_noq  <= (others => '0');
                stall_dma  <= (others => '0');
                stall_wb   <= (others => '0');
                for q in 0 to NUM_QUEUES-1 loop
                    sect_left(q) <= (others => '0');
                    pq_issued(q) <= (others => '0');
                    pq_ok(q)     <= (others => '0');
                    pq_failed(q) <= (others => '0');
                end loop;
            end if;
        end if;
    end process;

    -- Result write-back: slots sweep lane-major, so the emitted key order is monotonic and reads
    -- back as a dense array. Every lane shares SWEEP_EN, so lane 0's SWEEP_VLD speaks for all; the
    -- lane index only selects which sum to pack.
    sw_res_vld <= lane_svld(0);

    -- Stopping the sweep the moment an unaccepted beat is offered leaves the whole packing stage
    -- idle except for the one result already in flight, which lands in an empty beat.
    settled     <= '1' when (state = S_IDLE or state = S_DONE or state = S_ERR) else '0';
    start_ok    <= CTL_START and settled;

    -- Combinational, so it pairs with the address of the cycle it is asserted in. Registering it
    -- while clear_addr advances would leave slot 0 holding the previous run's total.
    clear_en    <= '1' when (state = S_CLEAR) else '0';

    sweep_stall <= out_vld and not WR_MFB_DST_RDY;
    sweep_en    <= '1' when (state = S_WB and sweep_active = '1' and sweep_stall = '0') else '0';

    sweep_ptr_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (sweep_en = '1') then
                if (sweep_lane = LANES-1) then
                    sweep_lane <= (others => '0');
                    if (sweep_addr = SLOTS-1) then
                        sweep_active <= '0';
                    else
                        sweep_addr <= sweep_addr + 1;
                    end if;
                else
                    sweep_lane <= sweep_lane + 1;
                end if;
            end if;

            sw_addr_d <= sweep_addr;
            sw_lane_d <= sweep_lane;

            -- Armed on the same condition the FSM uses to leave S_DRAIN, so the pointer is valid
            -- on the first S_WB cycle.
            if (state = S_DRAIN and lane_drained = (lane_drained'range => '1')) then
                sweep_addr   <= (others => '0');
                sweep_lane   <= (others => '0');
                sweep_active <= '1';
            end if;

            if (RST = '1' or start_ok = '1') then
                sweep_active <= '0';
                sweep_addr   <= (others => '0');
                sweep_lane   <= (others => '0');
            end if;
        end if;
    end process;

    wb_pack_p : process (CLK) is
        variable v_key : unsigned(63 downto 0);
        variable v_slv : std_logic_vector(KEY_IDX_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            if (sw_res_vld = '1') then
                -- slot*LANES + lane, but LANES is a power of two so the key is the two
                -- counters concatenated. numeric_std would return a double-width product here.
                v_slv(SLOT_W+LANE_W-1 downto LANE_W)    := std_logic_vector(sw_addr_d);
                v_slv(LANE_W-1 downto 0)                := std_logic_vector(sw_lane_d);
                v_key                                   := resize(unsigned(v_slv), 64);
                wb_data((to_integer(wb_fill)+1)*REC_W-1 downto to_integer(wb_fill)*REC_W)
                                                        <= lane_sum(to_integer(sw_lane_d)) & std_logic_vector(v_key);
                if (wb_fill = RES_BEAT-1) then
                    wb_fill <= (others => '0');
                    wb_full <= '1';
                else
                    wb_fill <= wb_fill + 1;
                end if;
            end if;

            -- One output register, two producers that never overlap: the fill runs before the
            -- table is even cleared, the sweep only after every read has drained.
            if (fill_push = '1') then
                out_data        <= fill_data;
                out_vld         <= '1';
                fill_idx        <= fill_idx + RECS_BEAT;
                fill_beats_left <= fill_beats_left - 1;
            elsif (wb_full = '1') then
                -- The sweep stalls on an unaccepted beat, so the register is always free by the
                -- time the next one completes and this transfer never has to wait.
                out_data <= wb_data;
                out_vld  <= '1';
                wb_full  <= '0';
            elsif (WR_MFB_DST_RDY = '1') then
                out_vld <= '0';
            end if;

            if (RST = '1' or start_ok = '1') then
                wb_fill         <= (others => '0');
                wb_full         <= '0';
                out_vld         <= '0';
                fill_idx        <= (others => '0');
                fill_beats_left <= (others => '0');
                if (start_ok = '1' and CTL_FILL = '1') then
                    -- SECT_BEATS is a power of two, so the beat count is a shift of the sector
                    -- count rather than a multiplier.
                    fill_beats_left <= shift_left(resize(unsigned(CTL_IN_COUNT), 32),
                                                  log2(SECT_BEATS));
                end if;
            end if;
        end if;
    end process;

    WR_MFB_DATA    <= out_data;
    WR_MFB_META    <= CTL_OUT_QID & std_logic_vector(wb_lba);
    WR_MFB_SOF     <= (others => wb_sof);
    WR_MFB_EOF     <= (others => '1') when (wb_beat = SECT_BEATS-1) else (others => '0');
    WR_MFB_SOF_POS <= (others => '0');
    WR_MFB_EOF_POS <= (others => '1');
    WR_MFB_SRC_RDY <= out_vld;

    -- =============================================================================================
    -- Control
    -- =============================================================================================
    fsm_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            case state is
                when S_IDLE =>
                    null;

                when S_FILL =>
                    if (fill_beats_left = 0 and out_vld = '0') then
                        state <= S_FILL_WAIT;
                    end if;

                when S_FILL_WAIT =>
                    -- The fill's own data must be on the drive before the read phase asks for it.
                    -- Abort is honoured here because waiting for a write completion that never
                    -- arrives is exactly the case it exists for.
                    if (err_r = '1' or CTL_ABORT = '1') then
                        state <= S_ERR;
                    elsif (wr_issued = wr_compl) then
                        clear_addr <= (others => '0');
                        state      <= S_CLEAR;
                    end if;

                when S_CLEAR =>
                    if (clear_addr = SLOTS-1) then
                        state <= S_RUN;
                    else
                        clear_addr <= clear_addr + 1;
                    end if;

                when S_RUN =>
                    if (err_r = '1' or CTL_ABORT = '1') then
                        state <= S_ERR;
                    elsif (sect_any = '0' and issued_cnt = compl_cnt and beat_busy = '0'
                           and rec_cnt = recs_exp) then
                        state <= S_DRAIN;
                    end if;

                when S_DRAIN =>
                    if (err_r = '1' or CTL_ABORT = '1') then
                        state <= S_ERR;
                    elsif (lane_drained = (lane_drained'range => '1')) then
                        wb_beat <= (others => '0');
                        wb_lba  <= unsigned(CTL_OUT_LBA);
                        wb_sof  <= '1';
                        state   <= S_WB;
                    end if;

                when S_WB =>
                    -- The packing pipeline still holds a beat when sweep_active drops, and a beat
                    -- leaving out_vld has only reached the bus. Without the completion test a run
                    -- whose write-back wholly failed would report DONE.
                    if (err_r = '1' or CTL_ABORT = '1') then
                        state <= S_ERR;
                    elsif (sweep_active = '0' and sw_res_vld = '0' and wb_full = '0'
                           and out_vld = '0' and wr_compl = wr_issued) then
                        state <= S_DONE;
                    end if;

                when S_DONE =>
                    null;

                -- An abort stops accepting read data, so the frame the DMA was part-way through
                -- never drains and its completion never arrives. Software must reset the DMA
                -- before re-arming, or that completion lands inside the next run.
                when S_ERR =>
                    null;
            end case;

            -- Frame bookkeeping, shared by the fill and the write-back: a frame is one sector, so
            -- SOF is asserted on the first beat of each and the LBA advances with it.
            if (out_vld = '1' and WR_MFB_DST_RDY = '1') then
                wb_sof <= '0';
                if (wb_beat = SECT_BEATS-1) then
                    wb_beat <= (others => '0');
                    wb_lba  <= wb_lba + 1;
                    wb_sof  <= '1';
                else
                    wb_beat <= wb_beat + 1;
                end if;
            end if;

            -- Re-arming from DONE or ERR goes straight in, so software needs one pulse to start a
            -- run rather than one to acknowledge and another to start.
            if (start_ok = '1') then
                clear_addr <= (others => '0');
                wb_beat    <= (others => '0');
                wb_sof     <= '1';
                if (CTL_FILL = '1') then
                    wb_lba <= unsigned(CTL_IN_LBA);
                    state  <= S_FILL;
                else
                    state <= S_CLEAR;
                end if;
            end if;

            if (RST = '1') then
                state <= S_IDLE;
            end if;
        end if;
    end process;

    STS_BUSY        <= '0' when (state = S_IDLE or state = S_DONE or state = S_ERR) else '1';
    STS_DONE        <= '1' when (state = S_DONE) else '0';
    STS_ERR         <= '1' when (state = S_ERR) else '0';
    STS_STATE       <= std_logic_vector(to_unsigned(state_t'pos(state), 4));
    STS_REC_CNT     <= std_logic_vector(rec_cnt);
    STS_OOR_CNT     <= std_logic_vector(oor_cnt);
    STS_RESULT_SECT <= std_logic_vector(to_unsigned(RES_SECT, 32));

    STS_ISSUED_CNT <= std_logic_vector(issued_cnt);
    STS_COMPL_CNT  <= std_logic_vector(compl_cnt);
    STS_WR_ISSUED  <= std_logic_vector(wr_issued);
    STS_WR_COMPL   <= std_logic_vector(wr_compl);
    STS_ERR_CODE   <= err_code;
    STS_ERR_TYPE   <= err_type;
    STS_ERR_QID    <= err_qid;
    STS_ERR_VLD    <= err_vld;
    STS_LANE_DRAIN <= lane_drained;
    STS_STALL_NOQ  <= std_logic_vector(stall_noq);
    STS_STALL_DMA  <= std_logic_vector(stall_dma);
    STS_STALL_WB   <= std_logic_vector(stall_wb);

    -- Same condition that advances rec_cnt, so the rate counter and the total cannot disagree.
    STS_REC_EVENT  <= beat_take;

    pq_flat_g : for q in 0 to NUM_QUEUES-1 generate
        STS_PQ_SECT_LEFT(32*q+31 downto 32*q) <= std_logic_vector(sect_left(q));
        STS_PQ_ISSUED(32*q+31 downto 32*q)    <= std_logic_vector(pq_issued(q));
        STS_PQ_OK(32*q+31 downto 32*q)        <= std_logic_vector(pq_ok(q));
        STS_PQ_FAILED(32*q+31 downto 32*q)    <= std_logic_vector(pq_failed(q));
    end generate;

end architecture;
