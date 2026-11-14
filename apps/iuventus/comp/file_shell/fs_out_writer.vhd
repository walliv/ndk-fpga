-- fs_out_writer.vhd: stages one stream's kernel output and writes it into the stream's output extents
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.fs_pkg.all;

entity FS_OUT_WRITER is
    generic (
        NUM_QUEUES       : natural := 4;
        -- Staging capacity in 64 B beats; it must hold at least one stripe chunk (8 beats per LBA).
        STAGE_LOG2_BEATS : natural := 12
    );
    port (
        CLK    : in std_logic;
        RESET  : in std_logic;
        CLEAR  : in std_logic;
        START  : in std_logic;
        ABORT  : in std_logic;
        ENABLE : in std_logic;

        STRIPE_LOG2_DRIVES : in std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
        STRIPE_LOG2_CHUNK  : in std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);

        KOUT_VLD   : in    std_logic;
        KOUT_RDY   : out   std_logic;
        KOUT_DATA  : in    std_logic_vector(FS_DATA_W-1 downto 0);
        KOUT_BYTES : in    std_logic_vector(FS_BYTES_W-1 downto 0);
        KOUT_LAST  : in    std_logic;

        ENT_VLD    : in    std_logic;
        ENT_DATA   : in    std_logic_vector(FS_ENTRY_W-1 downto 0);
        ENT_RDY    : out   std_logic;
        OUT_HEAD   : in    std_logic_vector(31 downto 0);
        OUT_TAIL   : in    std_logic_vector(31 downto 0);
        NEED_SPACE : out   std_logic;

        WREQ_VLD    : out   std_logic;
        WREQ_RDY    : in    std_logic;
        WREQ_QID    : out   std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        WREQ_LBA    : out   std_logic_vector(FS_LBA_W-1 downto 0);
        WREQ_NLBA   : out   std_logic_vector(7 downto 0);
        WREQ_NBYTES : out   std_logic_vector(FS_VBYTES_W-1 downto 0);

        WDAT_VLD  : out   std_logic;
        WDAT_RDY  : in    std_logic;
        WDAT_DATA : out   std_logic_vector(FS_DATA_W-1 downto 0);

        WR_OUTSTANDING : in    std_logic;
        OUT_DONE       : out   std_logic;
        -- A write request is pending or its beats are still leaving the staging buffer.
        BUSY           : out   std_logic;
        -- Pulse on a malformed output ring entry; the writer then halts until CLEAR or START.
        ERR            : out   std_logic;
        ERR_INFO       : out   std_logic_vector(31 downto 0)
    );
end entity;

architecture FULL of FS_OUT_WRITER is

    constant SL        : natural := STAGE_LOG2_BEATS;
    constant PTR_W     : natural := SL + 1;
    constant QID_W     : natural := max(1, log2(NUM_QUEUES));
    constant BEAT_B    : natural := FS_DATA_W / 8;
    -- Beats of one write: up to 256 LBAs of 8 beats.
    constant BEATS_W   : natural := 12;
    constant CMP_W     : natural := max(PTR_W, BEATS_W);
    constant FIN_AV_W  : natural := BEATS_W - 1;
    constant LEN_W     : natural := FS_MAX_LOG2_CHUNK + 1;

    type state_t is (
        S_IDLE, S_EXT, S_PLAN_A, S_PLAN_B, S_PLAN_C, S_PLAN_D, S_WAIT, S_FIN_A, S_FIN_B,
        S_FIN_C, S_DONE, S_HALT
    );

    signal state     : state_t;
    signal state_nxt : state_t;

    type stage_t is array (0 to 2**SL-1) of std_logic_vector(FS_DATA_W-1 downto 0);

    signal stage   : stage_t;
    signal stage_q : std_logic_vector(FS_DATA_W-1 downto 0);
    signal wdat_q  : std_logic_vector(FS_DATA_W-1 downto 0);

    attribute ram_style : string;
    attribute ram_style of stage : signal is "ultra";

    signal job_rst : std_logic;
    signal halt    : std_logic;
    signal active  : std_logic;

    -- Kernel input stage
    signal kout_rdy_i : std_logic;
    signal kout_take  : std_logic;
    signal kout_acc   : std_logic;
    signal kout_keep  : std_logic_vector(BEAT_B-1 downto 0);
    signal kout_nz    : std_logic;
    signal kout_done  : std_logic;
    signal last_tail  : unsigned(5 downto 0);
    signal pad_go     : std_logic;
    signal acc_inc    : std_logic;
    signal kin_data   : std_logic_vector(FS_DATA_W-1 downto 0);
    signal kin_vld    : std_logic;
    signal kin_full   : std_logic;

    -- Staging pointers, all in beats: accepted, written, written as whole beats, given to writes,
    -- read out of the memory.
    signal acc_ptr  : unsigned(PTR_W-1 downto 0);
    signal wr_ptr   : unsigned(PTR_W-1 downto 0);
    signal full_ptr : unsigned(PTR_W-1 downto 0);
    signal iss_ptr  : unsigned(PTR_W-1 downto 0);
    signal rd_ptr   : unsigned(PTR_W-1 downto 0);
    signal used     : unsigned(PTR_W-1 downto 0);
    signal used_nxt : unsigned(PTR_W-1 downto 0);
    signal space    : std_logic;
    signal avail    : unsigned(CMP_W-1 downto 0);
    signal pend     : std_logic;
    signal fin_rdy  : std_logic;

    -- Read-out pipeline: the memory register and the output register advance together, so a stall
    -- holds both and a granted frame never waits for data.
    signal rd_left   : unsigned(BEATS_W-1 downto 0);
    signal rd_adv    : std_logic;
    signal rd_issue  : std_logic;
    signal a_vld     : std_logic;
    signal b_vld     : std_logic;
    signal wdat_take : std_logic;

    -- Extent and chunk planning
    signal lc        : natural range 0 to FS_MAX_LOG2_CHUNK;
    signal ld        : natural range 0 to FS_MAX_LOG2_DRIVES;
    signal ent_rdy_i : std_logic;
    signal ent_pop   : std_logic;
    signal ent_ok    : std_logic;
    signal ext_lba   : unsigned(FS_LBA_W-1 downto 0);
    signal ext_rem   : unsigned(FS_COUNT_W-1 downto 0);
    signal ext_last  : std_logic;
    signal pa_cidx   : unsigned(FS_LBA_W-1 downto 0);
    signal pa_off    : unsigned(LEN_W-1 downto 0);
    signal pb_room   : unsigned(LEN_W-1 downto 0);
    signal pb_row    : unsigned(FS_LBA_W-1 downto 0);
    signal pb_qid    : unsigned(QID_W-1 downto 0);
    signal ch_len    : unsigned(LEN_W-1 downto 0);
    signal ch_dlba   : unsigned(FS_LBA_W-1 downto 0);
    signal ch_qid    : unsigned(QID_W-1 downto 0);
    signal ch_nlba0  : unsigned(7 downto 0);
    signal ch_beats  : unsigned(BEATS_W-1 downto 0);

    signal fin_rb     : unsigned(BEATS_W-1 downto 0);
    signal fin_nbytes : unsigned(FS_VBYTES_W-1 downto 0);
    signal fin_nlba0  : unsigned(7 downto 0);
    signal fin_beats  : unsigned(BEATS_W-1 downto 0);

    signal slot_free : std_logic;
    signal arm_full  : std_logic;
    signal arm_fin   : std_logic;
    signal err_det   : std_logic;

    signal wreq_vld_r  : std_logic;
    signal wreq_qid_r  : unsigned(QID_W-1 downto 0);
    signal wreq_lba_r  : unsigned(FS_LBA_W-1 downto 0);
    signal wreq_nlba_r : unsigned(7 downto 0);
    signal wreq_nb_r   : unsigned(FS_VBYTES_W-1 downto 0);

    signal need_space_r : std_logic;
    signal out_done_r   : std_logic;
    signal err_r        : std_logic;
    -- Output ring entries taken this job; names the offending one in ERR_INFO.
    signal ent_cnt      : unsigned(15 downto 0);
    signal err_info_r   : std_logic_vector(31 downto 0);

    -- Checker flags, read only by the PSL directives below
    signal chk_kout_bad    : std_logic;
    signal chk_overflow    : std_logic;
    signal chk_chunk_big   : std_logic;
    signal chk_unstaged    : std_logic;
    signal chk_fin_align   : std_logic;
    signal chk_stripe_math : std_logic;

    function clamp_f (v : std_logic_vector; mx : natural) return natural is
    begin
        if (to_integer(unsigned(v)) > mx) then
            return mx;
        end if;
        return to_integer(unsigned(v));
    end function;

    function byte_keep_f (bytes : std_logic_vector(FS_BYTES_W-1 downto 0)) return std_logic_vector is
        variable keep : std_logic_vector(BEAT_B-1 downto 0);
    begin
        for b in keep'range loop
            if (b < to_integer(unsigned(bytes))) then
                keep(b) := '1';
            else
                keep(b) := '0';
            end if;
        end loop;
        return keep;
    end function;

    function ent_ok_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic is
    begin
        if (fs_ent_type_f(ent) = FS_ENT_TYPE_EXTENT and fs_ent_last_f(ent) = '0' and fs_ent_rsvd_ok_f(ent) and
            unsigned(fs_ent_lba_hi_f(ent)) = 0 and unsigned(fs_ent_count_f(ent)) /= 0) then
            return '1';
        end if;
        return '0';
    end function;

begin

    assert (SL >= 3)
        report "FS_OUT_WRITER: STAGE_LOG2_BEATS is too small for a single LBA."
        severity FAILURE;

    job_rst <= RESET or CLEAR or START;
    halt    <= '1' when (state = S_HALT) else '0';

    -- =============================================================================================
    -- Kernel input: the bytes past KOUT_BYTES and the pad beats go in as zeros, so every write reads
    -- whole staged beats and the sector padding needs no masking on the way out.
    -- =============================================================================================
    kout_keep  <= byte_keep_f(KOUT_BYTES);
    kout_nz    <= '1' when (unsigned(KOUT_BYTES) /= 0) else '0';
    kout_rdy_i <= halt or (active and ENABLE and space and not kout_done);
    kout_take  <= KOUT_VLD and kout_rdy_i;
    kout_acc   <= kout_take and not halt;
    pad_go     <= '1' when (kout_done = '1' and halt = '0' and space = '1' and acc_ptr(2 downto 0) /= 0) else '0';
    acc_inc    <= pad_go or (kout_acc and kout_nz);

    KOUT_RDY <= kout_rdy_i;

    kin_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            -- Zeroing through the flops' synchronous reset costs no data-path LUTs.
            for b in 0 to BEAT_B-1 loop
                if (pad_go = '1' or (kout_acc = '1' and kout_keep(b) = '0')) then
                    kin_data(8*b+7 downto 8*b) <= (others => '0');
                elsif (kout_acc = '1') then
                    kin_data(8*b+7 downto 8*b) <= KOUT_DATA(8*b+7 downto 8*b);
                end if;
            end loop;

            kin_vld  <= acc_inc;
            kin_full <= kout_acc and KOUT_BYTES(FS_BYTES_W-1);

            if (job_rst = '1') then
                kin_vld  <= '0';
                kin_full <= '0';
            end if;
        end if;
    end process;

    stage_wr_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (kin_vld = '1') then
                stage(to_integer(wr_ptr(SL-1 downto 0))) <= kin_data;
            end if;
        end if;
    end process;

    stage_rd_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (rd_adv = '1') then
                stage_q <= stage(to_integer(rd_ptr(SL-1 downto 0)));
                wdat_q  <= stage_q;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Staging bookkeeping
    -- =============================================================================================
    wdat_take <= b_vld and WDAT_RDY;
    rd_adv    <= not b_vld or WDAT_RDY;
    rd_issue  <= '1' when (rd_adv = '1' and rd_left /= 0) else '0';
    used_nxt  <= used + unsigned'(0 => acc_inc) - unsigned'(0 => wdat_take);
    pend      <= '1' when (acc_ptr /= iss_ptr) else '0';
    slot_free <= '1' when (wreq_vld_r = '0' and rd_left = 0) else '0';

    ptr_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (acc_inc = '1') then
                acc_ptr <= acc_ptr + 1;
            end if;
            if (kin_vld = '1') then
                wr_ptr <= wr_ptr + 1;
            end if;
            if (kin_full = '1') then
                full_ptr <= full_ptr + 1;
            end if;
            if (arm_full = '1') then
                iss_ptr <= iss_ptr + resize(ch_beats, PTR_W);
            elsif (arm_fin = '1') then
                iss_ptr <= iss_ptr + resize(fin_beats, PTR_W);
            end if;

            -- Registered from the next value, so SPACE is exact in the cycle it is used.
            used  <= used_nxt;
            space <= not used_nxt(SL);
            avail <= resize(full_ptr - iss_ptr, CMP_W);

            if (kout_acc = '1' and KOUT_LAST = '1') then
                kout_done <= '1';
                last_tail <= unsigned(KOUT_BYTES(5 downto 0));
            end if;
            -- Taken one cycle late, so AVAIL already counts the last beat written.
            if (kout_done = '1' and acc_ptr(2 downto 0) = 0 and kin_vld = '0') then
                fin_rdy <= '1';
            else
                fin_rdy <= '0';
            end if;

            if (job_rst = '1') then
                acc_ptr   <= (others => '0');
                wr_ptr    <= (others => '0');
                full_ptr  <= (others => '0');
                iss_ptr   <= (others => '0');
                used      <= (others => '0');
                space     <= '1';
                kout_done <= '0';
                last_tail <= (others => '0');
                fin_rdy   <= '0';
            end if;
        end if;
    end process;

    rd_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (arm_full = '1') then
                rd_left <= ch_beats;
            elsif (arm_fin = '1') then
                rd_left <= fin_beats;
            elsif (rd_issue = '1') then
                rd_left <= rd_left - 1;
            end if;
            if (rd_issue = '1') then
                rd_ptr <= rd_ptr + 1;
            end if;
            if (rd_adv = '1') then
                a_vld <= rd_issue;
                b_vld <= a_vld;
            end if;

            if (job_rst = '1') then
                rd_left <= (others => '0');
                rd_ptr  <= (others => '0');
                a_vld   <= '0';
                b_vld   <= '0';
            end if;
        end if;
    end process;

    WDAT_VLD  <= b_vld;
    WDAT_DATA <= wdat_q;

    -- =============================================================================================
    -- Extents and chunks
    -- =============================================================================================
    ent_ok    <= ent_ok_f(ENT_DATA);
    ent_rdy_i <= '1' when (state = S_EXT and pend = '1' and ENABLE = '1') else '0';
    ent_pop   <= ent_rdy_i and ENT_VLD;

    ENT_RDY <= ent_rdy_i;

    fsm_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1' or CLEAR = '1') then
                state <= S_IDLE;
            elsif (START = '1') then
                state <= S_EXT;
            else
                state <= state_nxt;
            end if;
        end if;
    end process;

    fsm_nxt_p : process (all) is
    begin
        state_nxt <= state;
        arm_full  <= '0';
        arm_fin   <= '0';
        err_det   <= '0';

        case state is
            when S_IDLE =>
                null;

            when S_EXT =>
                if (fin_rdy = '1' and pend = '0') then
                    state_nxt <= S_DONE;
                elsif (ent_pop = '1') then
                    if (ent_ok = '1') then
                        state_nxt <= S_PLAN_A;
                    else
                        err_det   <= '1';
                        state_nxt <= S_HALT;
                    end if;
                end if;

            when S_PLAN_A =>
                state_nxt <= S_PLAN_B;

            when S_PLAN_B =>
                state_nxt <= S_PLAN_C;

            when S_PLAN_C =>
                state_nxt <= S_PLAN_D;

            when S_PLAN_D =>
                state_nxt <= S_WAIT;

            -- AVAIL lags ISS_PTR by a cycle; the four planning cycles after every arm keep that lag
            -- from ever reading as data.
            when S_WAIT =>
                if (avail >= ch_beats) then
                    if (slot_free = '1') then
                        arm_full <= '1';
                        if (ext_last = '1') then
                            state_nxt <= S_EXT;
                        else
                            state_nxt <= S_PLAN_A;
                        end if;
                    end if;
                elsif (fin_rdy = '1') then
                    if (avail = 0 and last_tail = 0) then
                        state_nxt <= S_DONE;
                    else
                        state_nxt <= S_FIN_A;
                    end if;
                end if;

            when S_FIN_A =>
                state_nxt <= S_FIN_B;

            when S_FIN_B =>
                state_nxt <= S_FIN_C;

            when S_FIN_C =>
                if (slot_free = '1') then
                    arm_fin   <= '1';
                    state_nxt <= S_DONE;
                end if;

            when S_DONE =>
                null;

            when S_HALT =>
                null;
        end case;

        if (ABORT = '1' and state /= S_IDLE) then
            arm_full  <= '0';
            arm_fin   <= '0';
            state_nxt <= S_HALT;
        end if;
    end process;

    active_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1' or CLEAR = '1') then
                active <= '0';
            elsif (START = '1') then
                active <= '1';
            elsif (ABORT = '1' or err_det = '1') then
                active <= '0';
            end if;
        end if;
    end process;

    -- Stripe math in four registered steps, each one shifter or one short adder deep.
    plan_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            lc <= clamp_f(STRIPE_LOG2_CHUNK, FS_MAX_LOG2_CHUNK);
            ld <= clamp_f(STRIPE_LOG2_DRIVES, FS_MAX_LOG2_DRIVES);

            if (ent_pop = '1') then
                ext_lba <= unsigned(fs_ent_lba_f(ENT_DATA));
                ext_rem <= unsigned(fs_ent_count_f(ENT_DATA));
            elsif (arm_full = '1') then
                ext_lba <= ext_lba + ch_len;
                ext_rem <= ext_rem - ch_len;
            end if;

            case state is
                when S_PLAN_A =>
                    pa_cidx <= shift_right(ext_lba, lc);
                    pa_off  <= resize(ext_lba(LEN_W-2 downto 0), LEN_W) and
                               not shift_left(to_unsigned(2**LEN_W-1, LEN_W), lc);

                when S_PLAN_B =>
                    pb_room <= shift_left(to_unsigned(1, LEN_W), lc) - pa_off;
                    pb_qid  <= pa_cidx(QID_W-1 downto 0) and not shift_left(to_unsigned(2**QID_W-1, QID_W), ld);
                    pb_row  <= shift_right(pa_cidx, ld);

                when S_PLAN_C =>
                    if (ext_rem <= pb_room) then
                        ext_last <= '1';
                        ch_len   <= ext_rem(LEN_W-1 downto 0);
                    else
                        ext_last <= '0';
                        ch_len   <= pb_room;
                    end if;
                    ch_dlba <= shift_left(pb_row, lc) or resize(pa_off, FS_LBA_W);
                    ch_qid  <= pb_qid;

                when S_PLAN_D =>
                    ch_nlba0 <= resize(ch_len - 1, 8);
                    ch_beats <= shift_left(resize(ch_len, BEATS_W), 3);

                when S_FIN_A =>
                    fin_rb     <= resize(avail, BEATS_W) + unsigned'(0 => or last_tail);
                    fin_nbytes <= resize(resize(avail, FIN_AV_W) & last_tail, FS_VBYTES_W);

                when S_FIN_B =>
                    fin_nlba0 <= resize(shift_right(fin_rb - 1, 3), 8);
                    fin_beats <= (fin_rb + 7) and not to_unsigned(7, BEATS_W);

                when others =>
                    null;
            end case;
        end if;
    end process;

    wreq_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (arm_full = '1') then
                wreq_vld_r  <= '1';
                wreq_qid_r  <= ch_qid;
                wreq_lba_r  <= ch_dlba;
                wreq_nlba_r <= ch_nlba0;
                wreq_nb_r   <= shift_left(resize(ch_len, FS_VBYTES_W), 9);
            elsif (arm_fin = '1') then
                wreq_vld_r  <= '1';
                wreq_qid_r  <= ch_qid;
                wreq_lba_r  <= ch_dlba;
                wreq_nlba_r <= fin_nlba0;
                wreq_nb_r   <= fin_nbytes;
            elsif (WREQ_RDY = '1') then
                wreq_vld_r <= '0';
            end if;

            if (job_rst = '1') then
                wreq_vld_r <= '0';
            end if;
        end if;
    end process;

    WREQ_VLD    <= wreq_vld_r;
    WREQ_QID    <= std_logic_vector(wreq_qid_r);
    WREQ_LBA    <= std_logic_vector(wreq_lba_r);
    WREQ_NLBA   <= std_logic_vector(wreq_nlba_r);
    WREQ_NBYTES <= std_logic_vector(wreq_nb_r);

    -- =============================================================================================
    -- Status
    -- =============================================================================================
    status_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            need_space_r <= '0';
            if (state = S_EXT and pend = '1' and ENT_VLD = '0' and OUT_HEAD = OUT_TAIL) then
                need_space_r <= '1';
            end if;

            out_done_r <= '0';
            if (state = S_DONE and slot_free = '1' and a_vld = '0' and b_vld = '0' and WR_OUTSTANDING = '0') then
                out_done_r <= '1';
            end if;

            err_r <= err_det;

            if (ent_pop = '1') then
                ent_cnt <= ent_cnt + 1;
            end if;
            if (err_det = '1') then
                err_info_r <= fs_err_info_f(FS_ERR_SRC_FORMAT, "00", '0', "0000", std_logic_vector(ent_cnt + 1));
            end if;

            if (job_rst = '1') then
                need_space_r <= '0';
                out_done_r   <= '0';
                err_r        <= '0';
                ent_cnt      <= (others => '0');
                err_info_r   <= (others => '0');
            end if;
        end if;
    end process;

    NEED_SPACE <= need_space_r;
    OUT_DONE   <= out_done_r;
    BUSY       <= wreq_vld_r or a_vld or b_vld or (or rd_left);
    ERR        <= err_r;
    ERR_INFO   <= err_info_r;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    chk_overflow  <= '1' when (used > 2**SL) else '0';
    chk_chunk_big <= '1' when (state = S_WAIT and ch_beats > 2**SL) else '0';
    chk_unstaged  <= '1' when (rd_issue = '1' and rd_ptr = wr_ptr) else '0';
    chk_fin_align <= '1' when (arm_fin = '1' and iss_ptr + resize(fin_beats, PTR_W) /= acc_ptr) else '0';

    chk_p : process (all) is
        variable v_lba : std_logic_vector(FS_LBA_W-1 downto 0);
    begin
        chk_kout_bad <= '0';
        if (kout_take = '1') then
            if (unsigned(KOUT_BYTES) > BEAT_B or (KOUT_BYTES(FS_BYTES_W-1) = '0' and KOUT_LAST = '0')) then
                chk_kout_bad <= '1';
            end if;
        end if;

        v_lba           := std_logic_vector(ext_lba);
        chk_stripe_math <= '0';
        if (state = S_PLAN_D) then
            if (std_logic_vector(ch_dlba) /= fs_stripe_drive_lba_f(v_lba, ld, lc) or
                to_integer(ch_qid) /= fs_stripe_drive_f(v_lba, ld, lc)) then
                chk_stripe_math <= '1';
            end if;
        end if;
    end process;

    -- psl default clock is rising_edge(CLK);
    -- psl assert_kout_partial_only_last : assert always ((RESET = '0') -> (chk_kout_bad = '0'))
    --     report "FS_OUT_WRITER: a kernel beat other than the last is partial, or KOUT_BYTES > 64";
    -- psl assert_stage_no_overflow : assert always ((RESET = '0') -> (chk_overflow = '0'))
    --     report "FS_OUT_WRITER: staging buffer overflow";
    -- psl assert_chunk_fits : assert always ((RESET = '0') -> (chk_chunk_big = '0'))
    --     report "FS_OUT_WRITER: a stripe chunk exceeds the staging buffer and can never be issued";
    -- psl assert_read_staged : assert always ((RESET = '0') -> (chk_unstaged = '0'))
    --     report "FS_OUT_WRITER: a write reads a beat that is not staged yet";
    -- psl assert_fin_padded : assert always ((RESET = '0') -> (chk_fin_align = '0'))
    --     report "FS_OUT_WRITER: the final write does not end on the padded end of the output";
    -- psl assert_stripe_math : assert always ((RESET = '0') -> (chk_stripe_math = '0'))
    --     report "FS_OUT_WRITER: pipelined stripe mapping differs from fs_pkg";

end architecture;
