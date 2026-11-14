-- fs_wr_arb.vhd: merges the output writers' frames onto the DMA write stream and attributes completions
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

entity FS_WR_ARB is
    generic (
        STREAMS        : natural := 8;
        NUM_QUEUES     : natural := 4;
        -- Per-queue completion FIFO: the DMA's 64 tags plus the frames still on their way to it.
        CPL_FIFO_ITEMS : natural := 72;
        DEVICE         : string  := "ULTRASCALE"
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;
        CLEAR : in std_logic;

        WREQ_VLD    : in    std_logic_vector(STREAMS-1 downto 0);
        WREQ_RDY    : out   std_logic_vector(STREAMS-1 downto 0);
        WREQ_QID    : in    slv_array_t(STREAMS-1 downto 0)(max(1, log2(NUM_QUEUES))-1 downto 0);
        WREQ_LBA    : in    slv_array_t(STREAMS-1 downto 0)(FS_LBA_W-1 downto 0);
        WREQ_NLBA   : in    slv_array_t(STREAMS-1 downto 0)(7 downto 0);
        WREQ_NBYTES : in    slv_array_t(STREAMS-1 downto 0)(FS_VBYTES_W-1 downto 0);

        WDAT_VLD  : in    std_logic_vector(STREAMS-1 downto 0);
        WDAT_RDY  : out   std_logic_vector(STREAMS-1 downto 0);
        WDAT_DATA : in    slv_array_t(STREAMS-1 downto 0)(FS_DATA_W-1 downto 0);

        -- Engine-side write MFB of USER_CORE_IF_PIPE: one 512 b region of 8 blocks of 8 bytes.
        WR_MFB_DATA    : out   std_logic_vector(FS_DATA_W-1 downto 0);
        WR_MFB_META    : out   std_logic_vector(max(1, log2(NUM_QUEUES)) + 64-1 downto 0);
        WR_MFB_SOF     : out   std_logic_vector(0 downto 0);
        WR_MFB_EOF     : out   std_logic_vector(0 downto 0);
        WR_MFB_SOF_POS : out   std_logic_vector(2 downto 0);
        WR_MFB_EOF_POS : out   std_logic_vector(5 downto 0);
        WR_MFB_SRC_RDY : out   std_logic;
        WR_MFB_DST_RDY : in    std_logic;

        OP_STAT_TYPE : in    std_logic;
        OP_STAT_CODE : in    std_logic_vector(1 downto 0);
        OP_STAT_QID  : in    std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        OP_STAT_CID  : in    std_logic_vector(15 downto 0);
        OP_STAT_VLD  : in    std_logic;

        OUT_BYTES      : out   slv_array_t(STREAMS-1 downto 0)(63 downto 0);
        WR_OUTSTANDING : out   std_logic_vector(STREAMS-1 downto 0);
        WERR_VLD       : out   std_logic;
        WERR_MASK      : out   std_logic_vector(STREAMS-1 downto 0);
        WERR_INFO      : out   std_logic_vector(31 downto 0)
    );
end entity;

architecture FULL of FS_WR_ARB is

    constant QID_W    : natural := max(1, log2(NUM_QUEUES));
    constant SID_W    : natural := max(1, log2(STREAMS));
    constant CPL_W    : natural := SID_W + FS_VBYTES_W;
    constant CNT_W    : natural := log2(CPL_FIFO_ITEMS + 1);
    constant LEFT_W   : natural := 11;

    type qcnt_arr_t is array (0 to NUM_QUEUES-1) of unsigned(CNT_W-1 downto 0);
    type mask_arr_t is array (0 to NUM_QUEUES-1) of std_logic_vector(STREAMS-1 downto 0);
    type bytes_arr_t is array (0 to STREAMS-1) of unsigned(63 downto 0);

    signal clr : std_logic;

    -- Arbitration and the frame in flight
    signal elig    : std_logic_vector(STREAMS-1 downto 0);
    signal gnt_vld : std_logic;
    signal gnt_idx : natural range 0 to STREAMS-1;
    signal gnt_qid : natural range 0 to NUM_QUEUES-1;
    signal rr_ptr  : natural range 0 to STREAMS-1;
    signal busy    : std_logic;
    signal sel     : natural range 0 to STREAMS-1;
    signal left    : unsigned(LEFT_W-1 downto 0);
    signal sof_r   : std_logic;
    signal meta_r  : std_logic_vector(QID_W+64-1 downto 0);
    signal mfb_vld : std_logic;
    signal mfb_go  : std_logic;

    -- Completion attribution
    signal fifo_di    : std_logic_vector(CPL_W-1 downto 0);
    signal fifo_wr    : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal fifo_rd    : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal fifo_full  : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal fifo_empty : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal fifo_do    : slv_array_t(NUM_QUEUES-1 downto 0)(CPL_W-1 downto 0);

    signal st_vld  : std_logic;
    signal st_code : std_logic_vector(1 downto 0);
    signal st_qid  : natural range 0 to NUM_QUEUES-1;
    signal st_cid  : std_logic_vector(15 downto 0);
    signal pop     : std_logic;
    signal head    : std_logic_vector(CPL_W-1 downto 0);
    signal head_s  : natural range 0 to STREAMS-1;

    signal qcnt    : qcnt_arr_t;
    signal drained : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal touched : mask_arr_t;
    signal out_nz  : std_logic_vector(STREAMS-1 downto 0);

    signal add_vld : std_logic;
    signal add_s   : natural range 0 to STREAMS-1;
    signal add_n   : unsigned(FS_VBYTES_W-1 downto 0);
    signal obytes  : bytes_arr_t;

    signal werr_vld_r  : std_logic;
    signal werr_mask_r : std_logic_vector(STREAMS-1 downto 0);
    signal werr_info_r : std_logic_vector(31 downto 0);

    -- Checker flags, read only by the PSL directives below
    signal chk_push_full : std_logic;
    signal chk_pop_empty : std_logic;
    signal chk_gap       : std_logic;
    signal chk_cnt_under : std_logic;
    signal chk_untouched : std_logic;

begin

    assert (2**QID_W = NUM_QUEUES)
        report "FS_WR_ARB: NUM_QUEUES must be a power of two, the QID indexes the completion FIFOs."
        severity FAILURE;

    clr <= RESET or CLEAR;

    -- =============================================================================================
    -- Round-robin over the writers at frame granularity; a writer whose queue cannot take another
    -- completion entry is skipped, not waited on.
    -- =============================================================================================
    elig_g : for s in 0 to STREAMS-1 generate
        elig(s) <= WREQ_VLD(s) and not fifo_full(to_integer(unsigned(WREQ_QID(s))));
    end generate;

    gnt_idx <= fs_rr_pick_f(elig, rr_ptr);
    gnt_vld <= (or elig) and not busy and not clr;

    gnt_qid <= to_integer(unsigned(WREQ_QID(gnt_idx)));

    wreq_rdy_g : for s in 0 to STREAMS-1 generate
        WREQ_RDY(s) <= gnt_vld when (gnt_idx = s) else '0';
        WDAT_RDY(s) <= busy and WR_MFB_DST_RDY when (sel = s) else '0';
    end generate;

    mfb_vld <= busy and WDAT_VLD(sel);
    mfb_go  <= mfb_vld and WR_MFB_DST_RDY;

    frame_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (gnt_vld = '1') then
                busy   <= '1';
                sel    <= gnt_idx;
                -- (NLBA+1)*8 - 1 beats follow the first one.
                left   <= unsigned(WREQ_NLBA(gnt_idx)) & "111";
                sof_r  <= '1';
                meta_r <= WREQ_QID(gnt_idx) & std_logic_vector(resize(unsigned(WREQ_LBA(gnt_idx)), 64));
                rr_ptr <= (gnt_idx + 1) mod STREAMS;
            elsif (mfb_go = '1') then
                sof_r <= '0';
                if (left = 0) then
                    busy <= '0';
                else
                    left <= left - 1;
                end if;
            end if;

            if (clr = '1') then
                busy   <= '0';
                sof_r  <= '0';
                rr_ptr <= 0;
            end if;
        end if;
    end process;

    WR_MFB_DATA    <= WDAT_DATA(sel);
    WR_MFB_META    <= meta_r;
    WR_MFB_SOF(0)  <= sof_r;
    WR_MFB_EOF(0)  <= '1' when (left = 0) else '0';
    WR_MFB_SOF_POS <= (others => '0');
    WR_MFB_EOF_POS <= (others => '1');
    WR_MFB_SRC_RDY <= mfb_vld;

    -- =============================================================================================
    -- Completion attribution: drives complete a queue's writes in any order, so the FIFO head only
    -- accounts bytes (exact once all popped); outstanding writes and an error name every stream that
    -- wrote to a queue since it last drained.
    -- =============================================================================================
    fifo_di <= std_logic_vector(to_unsigned(gnt_idx, SID_W)) & WREQ_NBYTES(gnt_idx);

    cpl_fifo_g : for q in 0 to NUM_QUEUES-1 generate
        fifo_wr(q) <= gnt_vld when (gnt_qid = q) else '0';
        fifo_rd(q) <= pop when (st_qid = q) else '0';

        cpl_fifo_i : entity work.FIFOX
        generic map (
            DATA_WIDTH          => CPL_W,
            ITEMS               => CPL_FIFO_ITEMS,
            RAM_TYPE            => "LUT",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 0,
            ALMOST_EMPTY_OFFSET => 0,
            FAKE_FIFO           => false
        )
        port map (
            CLK    => CLK,
            RESET  => clr,
            DI     => fifo_di,
            WR     => fifo_wr(q),
            FULL   => fifo_full(q),
            AFULL  => open,
            STATUS => open,
            DO     => fifo_do(q),
            RD     => fifo_rd(q),
            EMPTY  => fifo_empty(q),
            AEMPTY => open
        );
    end generate;

    stat_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            st_vld  <= OP_STAT_VLD and not OP_STAT_TYPE;
            st_code <= OP_STAT_CODE;
            st_qid  <= to_integer(unsigned(OP_STAT_QID));
            st_cid  <= OP_STAT_CID;
            if (clr = '1') then
                st_vld <= '0';
            end if;
        end if;
    end process;

    -- Code 10 carries no queue identity, so it pops nothing.
    pop    <= '1' when (st_vld = '1' and st_code /= FS_OP_CODE_OOR and fifo_empty(st_qid) = '0') else '0';
    head   <= fifo_do(st_qid);
    head_s <= to_integer(unsigned(head(CPL_W-1 downto FS_VBYTES_W)));

    touched_g : for q in 0 to NUM_QUEUES-1 generate
        -- A grant in the same cycle sets its own bit after the clear.
        drained(q) <= fifo_rd(q) when (qcnt(q) = 1) else '0';

        touched_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (fifo_wr(q) = '1' and fifo_rd(q) = '0') then
                    qcnt(q) <= qcnt(q) + 1;
                elsif (fifo_wr(q) = '0' and fifo_rd(q) = '1') then
                    qcnt(q) <= qcnt(q) - 1;
                end if;
                if (drained(q) = '1') then
                    touched(q) <= (others => '0');
                end if;
                if (fifo_wr(q) = '1') then
                    touched(q)(gnt_idx) <= '1';
                end if;
                if (clr = '1') then
                    qcnt(q)    <= (others => '0');
                    touched(q) <= (others => '0');
                end if;
            end if;
        end process;
    end generate;

    -- A stream is outstanding while any queue it wrote to has not drained: a completion pops the
    -- queue's head, not necessarily the stream whose write finished.
    out_nz_p : process (all) is
        variable v_or : std_logic_vector(STREAMS-1 downto 0);
    begin
        v_or := (others => '0');
        for q in 0 to NUM_QUEUES-1 loop
            v_or := v_or or touched(q);
        end loop;
        out_nz <= v_or;
    end process;

    WR_OUTSTANDING <= out_nz;

    obytes_g : for s in 0 to STREAMS-1 generate
        OUT_BYTES(s) <= std_logic_vector(obytes(s));
    end generate;

    attr_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            add_vld    <= '0';
            werr_vld_r <= '0';

            if (pop = '1') then
                add_s <= head_s;
                add_n <= unsigned(head(FS_VBYTES_W-1 downto 0));
                if (st_code = FS_OP_CODE_OK) then
                    add_vld <= '1';
                end if;
            end if;

            if (st_vld = '1' and st_code /= FS_OP_CODE_OK) then
                werr_vld_r <= '1';
                if (st_code = FS_OP_CODE_OOR) then
                    werr_mask_r <= out_nz;
                    werr_info_r <= fs_err_info_f(FS_ERR_SRC_NVME, st_code, '0', "0000", X"0000");
                else
                    werr_mask_r <= touched(st_qid);
                    werr_info_r <= fs_err_info_f(FS_ERR_SRC_NVME, st_code, '0',
                                                 std_logic_vector(to_unsigned(st_qid, 4)), st_cid);
                end if;
            end if;

            if (clr = '1') then
                add_vld    <= '0';
                werr_vld_r <= '0';
            end if;
        end if;
    end process;

    -- One adder shared by all streams: completions arrive at most one per cycle.
    acc_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (add_vld = '1') then
                obytes(add_s) <= obytes(add_s) + add_n;
            end if;
            if (clr = '1') then
                obytes <= (others => (others => '0'));
            end if;
        end if;
    end process;

    WERR_VLD  <= werr_vld_r;
    WERR_MASK <= werr_mask_r;
    WERR_INFO <= werr_info_r;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    chk_push_full <= '1' when (gnt_vld = '1' and fifo_full(gnt_qid) = '1') else '0';
    chk_pop_empty <= '1' when (st_vld = '1' and st_code /= FS_OP_CODE_OOR and fifo_empty(st_qid) = '1') else '0';
    chk_gap       <= '1' when (busy = '1' and sof_r = '0' and WDAT_VLD(sel) = '0') else '0';

    under_p : process (all) is
        variable v_bad : std_logic;
    begin
        v_bad := '0';
        if (pop = '1' and qcnt(st_qid) = 0) then
            v_bad := '1';
        end if;
        chk_cnt_under <= v_bad;
    end process;

    chk_untouched <= pop and not touched(st_qid)(head_s);

    -- psl default clock is rising_edge(CLK);
    -- psl assert_no_push_full : assert always ((RESET = '0') -> (chk_push_full = '0'))
    --     report "FS_WR_ARB: grant pushed into a full completion FIFO";
    -- psl assert_no_pop_empty : assert always ((RESET = '0') -> (chk_pop_empty = '0'))
    --     report "FS_WR_ARB: a write completion arrived on a queue with no write outstanding";
    -- psl assert_frame_no_gap : assert always ((RESET = '0') -> (chk_gap = '0'))
    --     report "FS_WR_ARB: the granted writer paused inside its frame";
    -- psl assert_cnt_no_underflow : assert always ((RESET = '0') -> (chk_cnt_under = '0'))
    --     report "FS_WR_ARB: outstanding counter underflow";
    -- psl assert_owner_touched : assert always ((RESET = '0') -> (chk_untouched = '0'))
    --     report "FS_WR_ARB: a queue's error mask lacks the stream of an entry still in its FIFO";

end architecture;
