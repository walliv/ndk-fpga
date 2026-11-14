-- fs_in_planner.vhd: cuts one stream's input file list into stripe-aligned read chunks
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

entity FS_IN_PLANNER is
    generic (
        -- Index of this stream, carried in every chunk's context.
        STREAM_IDX  : natural := 0;
        NUM_QUEUES  : natural := 4;
        -- Chunk completions arrive on one lane per read endpoint.
        CDONE_LANES : natural := 1
    );
    port (
        CLK    : in std_logic;
        RESET  : in std_logic;
        -- Only while no chunk of this stream is in flight: completions name file slots.
        CLEAR  : in std_logic;
        START  : in std_logic;
        -- Low holds the list where it is: no entry is taken and no chunk offered.
        ENABLE : in std_logic;

        -- Sampled at START.
        STRIPE_LOG2_DRIVES : in std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
        STRIPE_LOG2_CHUNK  : in std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);

        -- =========================================================================================
        -- Input ring entries
        -- =========================================================================================
        ENT_VLD  : in  std_logic;
        ENT_DATA : in  std_logic_vector(FS_ENTRY_W-1 downto 0);
        ENT_RDY  : out std_logic;

        -- =========================================================================================
        -- Chunk requests; QID is the drive, LBA the drive's own LBA, NLBA 0-based
        -- =========================================================================================
        CREQ_VLD  : out std_logic;
        CREQ_RDY  : in  std_logic;
        CREQ_QID  : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        CREQ_LBA  : out std_logic_vector(FS_LBA_W-1 downto 0);
        CREQ_NLBA : out std_logic_vector(7 downto 0);
        CREQ_CTX  : out std_logic_vector(FS_CTX_W-1 downto 0);

        -- A chunk of this stream was delivered, per lane, naming its file slot.
        CDONE_VLD   : in std_logic_vector(CDONE_LANES-1 downto 0);
        CDONE_FSLOT : in slv_array_t(CDONE_LANES-1 downto 0)(FS_FSLOT_W-1 downto 0);

        -- =========================================================================================
        -- Progress and errors
        -- =========================================================================================
        -- Files, size-0 ones included, whose every chunk reached the kernel, in list order.
        IN_FILES   : out std_logic_vector(31 downto 0);
        -- The LAST entry is parsed and every file retired; IN_FILES is final.
        IN_DONE    : out std_logic;
        KERNEL_END : out std_logic;
        ERR        : out std_logic;
        -- FORMAT source; CID field = the 1-based index of the offending entry modulo 65536.
        ERR_INFO   : out std_logic_vector(31 downto 0)
    );
end entity;

architecture FULL of FS_IN_PLANNER is

    constant QID_W   : natural := max(1, log2(NUM_QUEUES));
    constant SLOTS   : natural := 2**FS_FSLOT_W;
    constant PTR_W   : natural := FS_FSLOT_W + 1;
    -- Chunk counts are compared modulo 2**CNT_W; chunks in flight of one file stay far below it.
    constant CNT_W   : natural := 16;
    constant FLBA_W  : natural := FS_FOFS_W - 9 + 1;
    constant STREAM  : std_logic_vector(FS_STREAM_W-1 downto 0) := std_logic_vector(to_unsigned(STREAM_IDX, FS_STREAM_W));


    type   state_t is (S_IDLE, S_ENT, S_DEC, S_CLOSE, S_OPEN, S_CALC, S_LOAD, S_FINISH, S_DONE, S_ERR);
    signal st     : state_t;
    signal st_nxt : state_t;

    -- Stripe geometry
    signal lc_r    : unsigned(FS_STRIPE_LOG2_W-1 downto 0);
    signal ld_r    : unsigned(FS_STRIPE_LOG2_W-1 downto 0);
    signal cs_r    : unsigned(9 downto 0);
    signal cmask_r : unsigned(FS_LBA_W-1 downto 0);
    signal dmask_r : unsigned(QID_W-1 downto 0);

    -- Entry decode
    signal ent_r     : std_logic_vector(FS_ENTRY_W-1 downto 0);
    signal ent_idx   : unsigned(31 downto 0);
    signal is_file   : std_logic;
    signal is_ext    : std_logic;
    signal ent_last  : std_logic;
    signal malformed : std_logic;

    -- Open file
    signal file_open  : std_logic;
    signal f_slot     : std_logic_vector(FS_FSLOT_W-1 downto 0);
    signal f_index    : std_logic_vector(FS_INDEX_W-1 downto 0);
    signal f_size     : unsigned(FS_FOFS_W-1 downto 0);
    signal f_pad      : unsigned(8 downto 0);
    signal fr_lbas    : unsigned(FLBA_W-1 downto 0);
    signal f_tgt      : unsigned(CNT_W-1 downto 0);
    signal cofs_base  : unsigned(FS_COFS_W-1 downto 0);
    signal nf_lbas    : unsigned(FLBA_W-1 downto 0);
    signal nf_pad     : unsigned(8 downto 0);
    -- After S_CLOSE: open the decoded FILE, else the list ended.
    signal close_open : std_logic;

    -- Current extent and chunk
    signal c_lba    : unsigned(FS_LBA_W-1 downto 0);
    signal ext_rem  : unsigned(FS_COUNT_W-1 downto 0);
    signal c_bnd    : unsigned(9 downto 0);
    signal c_fofs   : unsigned(FS_FOFS_W-1 downto 0);
    signal ext_last : std_logic;
    signal n_c      : unsigned(9 downto 0);
    signal n_r      : unsigned(9 downto 0);
    signal nl_c     : std_logic;
    signal nl_r     : std_logic;
    signal ne_c     : std_logic;
    signal ne_r     : std_logic;
    signal drv_r    : unsigned(QID_W-1 downto 0);
    signal dlba_r   : unsigned(FS_LBA_W-1 downto 0);

    signal creq_vld_r : std_logic;
    signal creq_hs    : std_logic;
    signal load       : std_logic;
    signal out_free   : std_logic;

    -- File slots: allocated in list order, retired in list order once all their chunks are back
    type   cnt_ram_t is array (0 to SLOTS-1) of unsigned(CNT_W-1 downto 0);
    signal done_ram : cnt_ram_t := (others => (others => '0'));
    signal tgt_ram  : cnt_ram_t := (others => (others => '0'));

    attribute ram_style             : string;
    attribute ram_style of done_ram : signal is "distributed";
    attribute ram_style of tgt_ram  : signal is "distributed";

    signal alloc_ptr  : unsigned(PTR_W-1 downto 0);
    signal head_ptr   : unsigned(PTR_W-1 downto 0);
    signal used       : unsigned(PTR_W-1 downto 0);
    signal retire     : std_logic;
    signal files_cnt  : unsigned(31 downto 0);

    signal pend_vld  : std_logic_vector(CDONE_LANES-1 downto 0);
    signal pend_slot : slv_array_t(CDONE_LANES-1 downto 0)(FS_FSLOT_W-1 downto 0);
    signal svc       : std_logic_vector(CDONE_LANES-1 downto 0);
    signal svc_vld   : std_logic;
    signal svc_slot  : std_logic_vector(FS_FSLOT_W-1 downto 0);
    signal svc_rr    : natural range 0 to CDONE_LANES-1;

    signal pend_ovf : std_logic;

begin

    -- =============================================================================================
    -- Entry decode (of the registered entry)
    -- =============================================================================================
    is_file  <= '1' when (fs_ent_type_f(ent_r) = FS_ENT_TYPE_FILE) else '0';
    is_ext   <= '1' when (fs_ent_type_f(ent_r) = FS_ENT_TYPE_EXTENT) else '0';
    ent_last <= fs_ent_last_f(ent_r);

    malformed <= '1' when (not fs_ent_rsvd_ok_f(ent_r)
                           or (is_file = '0' and is_ext = '0')
                           or (is_ext = '1' and (file_open = '0'
                                                 or unsigned(fs_ent_count_f(ent_r)) = 0
                                                 or unsigned(fs_ent_lba_hi_f(ent_r)) /= 0))
                           or (is_file = '1' and unsigned(ent_r(63 downto FS_FOFS_W)) /= 0)) else
                 '0';

    -- =============================================================================================
    -- Chunk size: the extent, the stripe chunk and the file's remaining LBAs bound it
    -- =============================================================================================
    calc_p : process (all) is
        variable ext_sat : unsigned(9 downto 0);
        variable fr_sat  : unsigned(9 downto 0);
        variable m1      : unsigned(9 downto 0);
    begin
        ext_sat := resize(ext_rem, 10);
        if (ext_rem(FS_COUNT_W-1 downto 9) /= 0) then
            ext_sat := to_unsigned(511, 10);
        end if;
        fr_sat := resize(fr_lbas, 10);
        if (fr_lbas(FLBA_W-1 downto 9) /= 0) then
            fr_sat := to_unsigned(511, 10);
        end if;
        m1 := c_bnd;
        if (ext_sat < c_bnd) then
            m1 := ext_sat;
        end if;
        n_c  <= m1;
        nl_c <= '0';
        if (fr_sat <= m1) then
            n_c  <= fr_sat;
            nl_c <= '1';
        end if;
        ne_c <= '0';
        if (ext_sat <= m1 and ext_sat <= fr_sat) then
            ne_c <= '1';
        end if;
    end process;

    creq_hs  <= creq_vld_r and ENABLE and CREQ_RDY;
    -- Not reloaded in the handshake's cycle: CREQ_RDY comes out of FS_RD_ISSUE's credit arbitration.
    out_free <= not creq_vld_r;
    load     <= '1' when (st = S_LOAD and ENABLE = '1' and out_free = '1') else '0';

    -- =============================================================================================
    -- FSM
    -- =============================================================================================
    fsm_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            st <= st_nxt;
            if (RESET = '1' or CLEAR = '1') then
                st <= S_IDLE;
            end if;
        end if;
    end process;

    fsm_nxt_p : process (all) is
    begin
        st_nxt <= st;
        case st is
            when S_IDLE =>
                if (START = '1') then
                    st_nxt <= S_ENT;
                end if;

            when S_ENT =>
                if (ENT_VLD = '1' and ENABLE = '1') then
                    st_nxt <= S_DEC;
                end if;

            when S_DEC =>
                if (malformed = '1') then
                    st_nxt <= S_ERR;
                elsif (is_file = '1') then
                    if (file_open = '0') then
                        st_nxt <= S_OPEN;
                    elsif (fr_lbas /= 0) then
                        st_nxt <= S_ERR;
                    else
                        st_nxt <= S_CLOSE;
                    end if;
                elsif (fr_lbas /= 0) then
                    st_nxt <= S_CALC;
                elsif (ent_last = '1') then
                    st_nxt <= S_CLOSE;
                else
                    st_nxt <= S_ENT;
                end if;

            when S_CLOSE =>
                st_nxt <= S_FINISH;
                if (close_open = '1') then
                    st_nxt <= S_OPEN;
                end if;

            when S_OPEN =>
                if (used < SLOTS) then
                    if (ent_last = '0') then
                        st_nxt <= S_ENT;
                    elsif (nf_lbas = 0) then
                        st_nxt <= S_CLOSE;
                    else
                        st_nxt <= S_ERR;
                    end if;
                end if;

            when S_CALC =>
                st_nxt <= S_LOAD;

            when S_LOAD =>
                if (load = '1') then
                    if (nl_r = '1') then
                        st_nxt <= S_ENT;
                        if (ext_last = '1') then
                            st_nxt <= S_CLOSE;
                        end if;
                    elsif (ne_r = '1') then
                        st_nxt <= S_ENT;
                        if (ext_last = '1') then
                            st_nxt <= S_ERR;
                        end if;
                    else
                        st_nxt <= S_CALC;
                    end if;
                end if;

            when S_FINISH =>
                if (used = 0 and creq_vld_r = '0') then
                    st_nxt <= S_DONE;
                end if;

            when others =>
                null;
        end case;
    end process;

    ENT_RDY <= '1' when (st = S_ENT and ENABLE = '1') else '0';

    -- =============================================================================================
    -- Datapath
    -- =============================================================================================
    dp_p : process (CLK) is
        variable vbytes : unsigned(FS_VBYTES_W-1 downto 0);
        variable cofs   : unsigned(FS_COFS_W-1 downto 0);
        variable lba_lo : unsigned(9 downto 0);
        variable pad    : unsigned(9 downto 0);
    begin
        if (rising_edge(CLK)) then
            KERNEL_END <= '0';
            ERR        <= '0';

            if (st = S_IDLE and START = '1') then
                lc_r       <= unsigned(STRIPE_LOG2_CHUNK);
                ld_r       <= unsigned(STRIPE_LOG2_DRIVES);
                cs_r       <= shift_left(to_unsigned(1, 10), to_integer(unsigned(STRIPE_LOG2_CHUNK(3 downto 0)) mod 16));
                cmask_r    <= shift_left(to_unsigned(1, FS_LBA_W), to_integer(unsigned(STRIPE_LOG2_CHUNK)) mod 16) - 1;
                dmask_r    <= resize(shift_left(to_unsigned(1, 4), to_integer(unsigned(STRIPE_LOG2_DRIVES)) mod 4) - 1, QID_W);
                ent_idx    <= (others => '0');
                file_open  <= '0';
                fr_lbas    <= (others => '0');
                cofs_base  <= (others => '0');
                files_cnt  <= (others => '0');
                IN_DONE    <= '0';
            end if;

            if (st = S_ENT and ENT_VLD = '1' and ENABLE = '1') then
                ent_r   <= ENT_DATA;
                ent_idx <= ent_idx + 1;
            end if;

            if (st = S_DEC) then
                close_open <= is_file;
                -- FILE: its LBA count and the zero bytes its last LBA carries past SIZE
                nf_lbas    <= resize(shift_right(resize(unsigned(ent_r(FS_FOFS_W-1 downto 0)), FS_FOFS_W+1) + 511, 9), FLBA_W);
                pad        := 512 - resize(unsigned(ent_r(8 downto 0)), 10);
                nf_pad     <= pad(8 downto 0);
                -- EXTENT
                ext_last   <= ent_last;
                c_lba      <= unsigned(fs_ent_lba_f(ent_r));
                ext_rem    <= unsigned(fs_ent_count_f(ent_r));
                lba_lo     := resize(unsigned(ent_r(8 downto 0)), 10) and (cs_r - 1);
                c_bnd      <= cs_r - lba_lo;
            end if;

            if (st = S_CLOSE) then
                tgt_ram(to_integer(unsigned(f_slot))) <= f_tgt;
                file_open                             <= '0';
                cofs_base                             <= cofs_base + resize(f_size, FS_COFS_W);
            end if;

            if (st = S_OPEN and used < SLOTS) then
                close_open <= '0';
                file_open  <= '1';
                f_slot     <= std_logic_vector(alloc_ptr(FS_FSLOT_W-1 downto 0));
                f_tgt      <= done_ram(to_integer(alloc_ptr(FS_FSLOT_W-1 downto 0)));
                f_index    <= fs_ent_index_f(ent_r);
                f_size     <= unsigned(ent_r(FS_FOFS_W-1 downto 0));
                f_pad      <= nf_pad;
                fr_lbas    <= nf_lbas;
                c_fofs     <= (others => '0');
            end if;

            -- Stripe mapping: drive = chunk number mod drives, drive LBA = the row's chunk + offset.
            if (st = S_CALC) then
                n_r    <= n_c;
                nl_r   <= nl_c;
                ne_r   <= ne_c;
                drv_r  <= resize(shift_right(c_lba, to_integer(lc_r) mod 16), QID_W) and dmask_r;
                dlba_r <= (shift_right(c_lba, to_integer(ld_r) mod 4) and not cmask_r) or (c_lba and cmask_r);
            end if;

            if (creq_hs = '1') then
                creq_vld_r <= '0';
            end if;
            if (load = '1') then
                vbytes := resize(shift_left(resize(n_r, FS_VBYTES_W), 9), FS_VBYTES_W);
                if (nl_r = '1') then
                    vbytes := vbytes - f_pad;
                end if;
                cofs       := cofs_base + resize(c_fofs, FS_COFS_W);
                creq_vld_r <= '1';
                CREQ_QID   <= std_logic_vector(drv_r);
                CREQ_LBA   <= std_logic_vector(dlba_r);
                CREQ_NLBA  <= std_logic_vector(resize(n_r - 1, 8));
                CREQ_CTX   <= fs_ctx_pack_f(STREAM, f_slot, f_index, std_logic_vector(c_fofs),
                                            std_logic_vector(cofs), std_logic_vector(vbytes));

                c_lba   <= c_lba + n_r;
                ext_rem <= ext_rem - n_r;
                fr_lbas <= fr_lbas - n_r;
                c_fofs  <= c_fofs + shift_left(resize(n_r, FS_FOFS_W), 9);
                c_bnd   <= c_bnd - n_r;
                if (n_r = c_bnd) then
                    c_bnd <= cs_r;
                end if;
                f_tgt <= f_tgt + 1;
            end if;

            if (st = S_FINISH and st_nxt = S_DONE) then
                IN_DONE    <= '1';
                KERNEL_END <= '1';
            end if;

            if (st /= S_ERR and st_nxt = S_ERR) then
                ERR      <= '1';
                ERR_INFO <= fs_err_info_f(FS_ERR_SRC_FORMAT, "00", '1', "0000", std_logic_vector(ent_idx(15 downto 0)));
            end if;

            if (retire = '1') then
                files_cnt <= files_cnt + 1;
            end if;

            if (RESET = '1' or CLEAR = '1') then
                creq_vld_r  <= '0';
                file_open   <= '0';
                fr_lbas     <= (others => '0');
                cofs_base   <= (others => '0');
                files_cnt   <= (others => '0');
                IN_DONE     <= '0';
                KERNEL_END  <= '0';
                ERR         <= '0';
                ERR_INFO    <= (others => '0');
            end if;
        end if;
    end process;

    -- An offered chunk is withdrawn when ENABLE drops: an aborted stream must stop issuing.
    CREQ_VLD <= creq_vld_r and ENABLE;
    IN_FILES <= std_logic_vector(files_cnt);

    -- =============================================================================================
    -- File slots
    -- =============================================================================================
    used   <= alloc_ptr - head_ptr;
    retire <= '1' when (used /= 0
                        and not (file_open = '1' and std_logic_vector(head_ptr(FS_FSLOT_W-1 downto 0)) = f_slot)
                        and done_ram(to_integer(head_ptr(FS_FSLOT_W-1 downto 0)))
                            = tgt_ram(to_integer(head_ptr(FS_FSLOT_W-1 downto 0)))) else
              '0';

    slot_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (st = S_OPEN and used < SLOTS) then
                alloc_ptr <= alloc_ptr + 1;
            end if;
            if (retire = '1') then
                head_ptr <= head_ptr + 1;
            end if;
            if (svc_vld = '1') then
                done_ram(to_integer(unsigned(svc_slot))) <= done_ram(to_integer(unsigned(svc_slot))) + 1;
            end if;
            if (RESET = '1' or CLEAR = '1') then
                alloc_ptr <= (others => '0');
                head_ptr  <= (others => '0');
            end if;
        end if;
    end process;

    -- Completions from several lanes are counted one per cycle; a lane completes at most every
    -- other cycle, so one waiting completion per lane suffices.
    svc_p : process (all) is
        variable idx : natural range 0 to CDONE_LANES-1;
    begin
        svc      <= (others => '0');
        svc_vld  <= '0';
        svc_slot <= pend_slot(svc_rr);
        for k in CDONE_LANES-1 downto 0 loop
            idx := (svc_rr + k) mod CDONE_LANES;
            if (pend_vld(idx) = '1') then
                svc      <= (others => '0');
                svc(idx) <= '1';
                svc_vld  <= '1';
                svc_slot <= pend_slot(idx);
            end if;
        end loop;
    end process;

    pend_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            for l in 0 to CDONE_LANES-1 loop
                if (svc(l) = '1') then
                    pend_vld(l) <= '0';
                    svc_rr      <= (l + 1) mod CDONE_LANES;
                end if;
                if (CDONE_VLD(l) = '1') then
                    pend_vld(l)  <= '1';
                    pend_slot(l) <= CDONE_FSLOT(l);
                end if;
            end loop;
            if (RESET = '1' or CLEAR = '1') then
                pend_vld <= (others => '0');
                svc_rr   <= 0;
            end if;
        end if;
    end process;

    pend_ovf <= or (CDONE_VLD and pend_vld and not svc);

    -- psl default clock is rising_edge(CLK);

    -- psl fs_in_planner_cdone_kept : assert always (RESET = '0' -> pend_ovf = '0')
    --     report "FS_IN_PLANNER: a chunk completion arrived while its lane's previous one waited";

end architecture;
