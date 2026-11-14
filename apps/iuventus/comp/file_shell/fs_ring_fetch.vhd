-- fs_ring_fetch.vhd: prefetches the entries of one HBM ring into a FIFO
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.fs_pkg.all;

-- A 32 B beat carries two entries, so the FIFO is split by entry parity: each beat writes at most
-- one entry into each half, and pops alternate between the halves with HEAD.
entity FS_RING_FETCH is
    generic (
        LOG2_DEPTH   : natural := FS_IN_RING_LOG2;
        -- HBM byte offset of entry 0; 4 KiB aligned.
        RING_BASE    : natural := 0;
        FIFO_ENTRIES : natural := 64;
        DEVICE       : string  := "ULTRASCALE"
    );
    port (
        CLK    : in    std_logic;
        RESET  : in    std_logic;
        CLEAR  : in    std_logic;
        ENABLE : in    std_logic;
        TAIL   : in    std_logic_vector(31 downto 0);
        HEAD   : out   std_logic_vector(31 downto 0);

        -- ==============================
        -- FS_HBM_PORT client
        -- ==============================
        FREQ_VLD   : out   std_logic;
        FREQ_ADDR  : out   std_logic_vector(FS_RING_HBM_ADDR_W-1 downto 0);
        FREQ_BEATS : out   std_logic_vector(4 downto 0);
        FREQ_RDY   : in    std_logic;
        FRSP_VLD   : in    std_logic;
        FRSP_DATA  : in    std_logic_vector(255 downto 0);
        FRSP_LAST  : in    std_logic;

        -- ==============================
        -- Entries in ring order
        -- ==============================
        ENT_VLD  : out   std_logic;
        ENT_DATA : out   std_logic_vector(FS_ENTRY_W-1 downto 0);
        ENT_RDY  : in    std_logic
    );
end entity;

architecture FULL of FS_RING_FETCH is

    -- Entries per 4 KiB page and per 16-beat burst.
    constant PAGE_ENTS  : natural := 256;
    constant BURST_ENTS : natural := 32;
    constant HALF_ITEMS : natural := FIFO_ENTRIES / 2;
    constant CNT_W      : natural := log2(FIFO_ENTRIES) + 1;
    -- Entry count of one burst: 1 .. BURST_ENTS.
    constant N_W        : natural := 6;
    -- Bursts in flight; enough to cover the HBM read latency with short bursts.
    constant MAX_OUT    : natural := FS_FETCH_MAX_OUT;
    constant OUT_W      : natural := log2(MAX_OUT) + 1;

    type fetch_state_t is (F_IDLE, F_CALC, F_CHK, F_REQ);

    signal fstate : fetch_state_t;

    signal fetched  : unsigned(31 downto 0);
    signal head_r   : unsigned(31 downto 0);
    -- Entries requested and not yet popped: in flight or in the FIFO.
    signal reserved : unsigned(CNT_W-1 downto 0);

    signal avail_r : unsigned(CNT_W-1 downto 0);
    signal room_r  : unsigned(CNT_W-1 downto 0);
    signal ent_r   : unsigned(7 downto 0);
    signal lim_r   : unsigned(N_W-1 downto 0);
    signal n_r     : unsigned(N_W-1 downto 0);

    signal req_addr_r  : std_logic_vector(FS_RING_HBM_ADDR_W-1 downto 0);
    signal req_beats_r : unsigned(4 downto 0);
    signal req_n_r     : unsigned(N_W-1 downto 0);
    signal req_skip_r  : std_logic;
    signal req_hs      : std_logic;

    signal out_cnt     : unsigned(OUT_W-1 downto 0);
    signal discard_cnt : unsigned(OUT_W-1 downto 0);
    signal dropping    : std_logic;

    signal desc_di    : std_logic_vector(N_W downto 0);
    signal desc_do    : std_logic_vector(N_W downto 0);
    signal desc_rd    : std_logic;
    signal desc_full  : std_logic;
    signal desc_empty : std_logic;

    signal rsp_first : std_logic;
    signal rsp_n_r   : unsigned(N_W-1 downto 0);
    signal cur_skip  : std_logic;
    signal cur_n     : unsigned(N_W-1 downto 0);
    signal lo_take   : std_logic;
    signal hi_take   : std_logic;

    signal fifo_rst  : std_logic;
    signal wr_even   : std_logic;
    signal wr_odd    : std_logic;
    signal rd_even   : std_logic;
    signal rd_odd    : std_logic;
    signal do_even   : std_logic_vector(FS_ENTRY_W-1 downto 0);
    signal do_odd    : std_logic_vector(FS_ENTRY_W-1 downto 0);
    signal full_e    : std_logic;
    signal full_o    : std_logic;
    signal empty_e   : std_logic;
    signal empty_o   : std_logic;
    signal ent_vld_i : std_logic;
    signal pop       : std_logic;

    -- Assertion helpers.
    signal ovf_e      : std_logic;
    signal ovf_o      : std_logic;
    signal rsp_orphan : std_logic;
    signal burst_bad  : std_logic;
    signal res_ovf    : std_logic;

begin

    assert (LOG2_DEPTH >= 8 and LOG2_DEPTH <= 20)
        report "FS_RING_FETCH: LOG2_DEPTH must be 8 to 20 (a ring holds whole 4 KiB pages)."
        severity FAILURE;
    assert (RING_BASE mod 4096 = 0)
        report "FS_RING_FETCH: RING_BASE must be 4 KiB aligned."
        severity FAILURE;
    assert (FIFO_ENTRIES >= 2 and FIFO_ENTRIES = 2**log2(FIFO_ENTRIES))
        report "FS_RING_FETCH: FIFO_ENTRIES must be a power of two, at least 2."
        severity FAILURE;

    -- =============================================================================================
    -- Request generation
    -- =============================================================================================
    -- Bursts end at 4 KiB pages; the ring end is a page boundary, so it needs no check of its own.
    -- The burst size takes two stages (limits, then room) to fit the clock; room only grows meanwhile.
    fetch_p : process (CLK) is
        variable avail_v : unsigned(31 downto 0);
        variable lim_v   : unsigned(8 downto 0);
        variable n_v     : unsigned(N_W-1 downto 0);
        variable idx_v   : unsigned(LOG2_DEPTH-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            case fstate is

                when F_IDLE =>
                    avail_v := unsigned(TAIL) - fetched;
                    -- A tail behind the fetch pointer (a CLEAR racing a stale tail) fetches nothing.
                    if (avail_v(31) = '1') then
                        avail_r <= (others => '0');
                    elsif (avail_v > FIFO_ENTRIES) then
                        avail_r <= to_unsigned(FIFO_ENTRIES, CNT_W);
                    else
                        avail_r <= avail_v(CNT_W-1 downto 0);
                    end if;
                    room_r <= FIFO_ENTRIES - reserved;
                    ent_r  <= fetched(7 downto 0);
                    lim_v  := to_unsigned(PAGE_ENTS, 9) - fetched(7 downto 0);
                    if (lim_v > BURST_ENTS) then
                        lim_v := to_unsigned(BURST_ENTS, 9) - fetched(0 downto 0);
                    end if;
                    lim_r <= lim_v(N_W-1 downto 0);
                    if (ENABLE = '1') then
                        fstate <= F_CALC;
                    end if;

                when F_CALC =>
                    n_r <= lim_r;
                    if (avail_r < lim_r) then
                        n_r <= resize(avail_r, N_W);
                    end if;
                    fstate <= F_CHK;

                when F_CHK =>
                    -- Wait for room for the whole burst unless half the FIFO is free anyway.
                    n_v := n_r;
                    if (room_r < n_r) then
                        n_v := resize(room_r, N_W);
                    end if;
                    fstate <= F_IDLE;
                    if (n_r /= 0 and (room_r >= n_r or room_r >= HALF_ITEMS) and out_cnt < MAX_OUT
                        and desc_full = '0') then
                        idx_v       := fetched(LOG2_DEPTH-1 downto 1) & '0';
                        req_addr_r  <= std_logic_vector(to_unsigned(RING_BASE, FS_RING_HBM_ADDR_W) +
                                                        shift_left(resize(idx_v, FS_RING_HBM_ADDR_W), 4));
                        req_beats_r <= resize(shift_right(resize(n_v, 7) + ent_r(0 downto 0) + 1, 1), 5);
                        req_n_r     <= n_v;
                        req_skip_r  <= ent_r(0);
                        fstate      <= F_REQ;
                    end if;

                when F_REQ =>
                    if (FREQ_RDY = '1') then
                        fetched <= fetched + req_n_r;
                        fstate  <= F_IDLE;
                    end if;

            end case;

            if (RESET = '1' or CLEAR = '1') then
                fstate  <= F_IDLE;
                fetched <= (others => '0');
            end if;
        end if;
    end process;

    req_hs <= '1' when (fstate = F_REQ and FREQ_RDY = '1') else '0';

    FREQ_VLD   <= '1' when (fstate = F_REQ) else '0';
    FREQ_ADDR  <= req_addr_r;
    FREQ_BEATS <= std_logic_vector(req_beats_r);

    -- =============================================================================================
    -- Bursts in flight; those issued before a CLEAR are drained and discarded
    -- =============================================================================================
    desc_di <= req_skip_r & std_logic_vector(req_n_r);

    desc_fifo_i : entity work.FIFOX
    generic map (
        DATA_WIDTH          => N_W + 1,
        ITEMS               => MAX_OUT,
        RAM_TYPE            => "LUT",
        DEVICE              => DEVICE,
        ALMOST_FULL_OFFSET  => 0,
        ALMOST_EMPTY_OFFSET => 0,
        FAKE_FIFO           => false
    )
    port map (
        CLK    => CLK,
        RESET  => RESET,
        DI     => desc_di,
        WR     => req_hs,
        FULL   => desc_full,
        AFULL  => open,
        STATUS => open,
        DO     => desc_do,
        RD     => desc_rd,
        EMPTY  => desc_empty,
        AEMPTY => open
    );

    dropping <= '1' when (discard_cnt /= 0 or CLEAR = '1') else '0';
    desc_rd  <= FRSP_VLD and FRSP_LAST;

    cur_skip <= desc_do(N_W) when (rsp_first = '1') else '0';
    cur_n    <= unsigned(desc_do(N_W-1 downto 0)) when (rsp_first = '1') else rsp_n_r;
    lo_take  <= '1' when (cur_skip = '0' and cur_n /= 0) else '0';
    hi_take  <= '1' when ((cur_skip = '1' and cur_n /= 0) or cur_n > 1) else '0';

    wr_even <= FRSP_VLD and lo_take and not dropping;
    wr_odd  <= FRSP_VLD and hi_take and not dropping;

    rsp_p : process (CLK) is
        variable out_v : unsigned(OUT_W-1 downto 0);
        variable n_v   : unsigned(N_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            if (FRSP_VLD = '1') then
                n_v := cur_n;
                if (lo_take = '1') then
                    n_v := n_v - 1;
                end if;
                if (hi_take = '1') then
                    n_v := n_v - 1;
                end if;
                rsp_n_r   <= n_v;
                rsp_first <= FRSP_LAST;
            end if;

            out_v := out_cnt;
            if (req_hs = '1') then
                out_v := out_v + 1;
            end if;
            if (desc_rd = '1') then
                out_v := out_v - 1;
            end if;
            out_cnt <= out_v;

            if (CLEAR = '1') then
                discard_cnt <= out_v;
            elsif (desc_rd = '1' and discard_cnt /= 0) then
                discard_cnt <= discard_cnt - 1;
            end if;

            if (RESET = '1') then
                rsp_first   <= '1';
                rsp_n_r     <= (others => '0');
                out_cnt     <= (others => '0');
                discard_cnt <= (others => '0');
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Entry FIFO, split by entry parity
    -- =============================================================================================
    fifo_rst <= RESET or CLEAR;

    even_fifo_i : entity work.FIFOX
    generic map (
        DATA_WIDTH          => FS_ENTRY_W,
        ITEMS               => HALF_ITEMS,
        RAM_TYPE            => "LUT",
        DEVICE              => DEVICE,
        ALMOST_FULL_OFFSET  => 0,
        ALMOST_EMPTY_OFFSET => 0,
        FAKE_FIFO           => false
    )
    port map (
        CLK    => CLK,
        RESET  => fifo_rst,
        DI     => FRSP_DATA(FS_ENTRY_W-1 downto 0),
        WR     => wr_even,
        FULL   => full_e,
        AFULL  => open,
        STATUS => open,
        DO     => do_even,
        RD     => rd_even,
        EMPTY  => empty_e,
        AEMPTY => open
    );

    odd_fifo_i : entity work.FIFOX
    generic map (
        DATA_WIDTH          => FS_ENTRY_W,
        ITEMS               => HALF_ITEMS,
        RAM_TYPE            => "LUT",
        DEVICE              => DEVICE,
        ALMOST_FULL_OFFSET  => 0,
        ALMOST_EMPTY_OFFSET => 0,
        FAKE_FIFO           => false
    )
    port map (
        CLK    => CLK,
        RESET  => fifo_rst,
        DI     => FRSP_DATA(2*FS_ENTRY_W-1 downto FS_ENTRY_W),
        WR     => wr_odd,
        FULL   => full_o,
        AFULL  => open,
        STATUS => open,
        DO     => do_odd,
        RD     => rd_odd,
        EMPTY  => empty_o,
        AEMPTY => open
    );

    ent_vld_i <= not empty_o when (head_r(0) = '1') else not empty_e;
    pop       <= ent_vld_i and ENT_RDY;
    rd_even   <= pop and not head_r(0);
    rd_odd    <= pop and head_r(0);

    ENT_VLD  <= ent_vld_i;
    ENT_DATA <= do_odd when (head_r(0) = '1') else do_even;
    HEAD     <= std_logic_vector(head_r);

    cnt_p : process (CLK) is
        variable res_v : unsigned(CNT_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            if (pop = '1') then
                head_r <= head_r + 1;
            end if;

            res_v := reserved;
            if (req_hs = '1') then
                res_v := res_v + req_n_r;
            end if;
            if (pop = '1') then
                res_v := res_v - 1;
            end if;
            reserved <= res_v;

            if (RESET = '1' or CLEAR = '1') then
                head_r   <= (others => '0');
                reserved <= (others => '0');
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    ovf_e      <= wr_even and full_e;
    ovf_o      <= wr_odd and full_o;
    rsp_orphan <= FRSP_VLD and desc_empty;
    burst_bad  <= '1' when (fstate = F_REQ and (req_beats_r = 0 or req_beats_r > 16 or
                            to_integer(unsigned(req_addr_r(11 downto 5))) + to_integer(req_beats_r) > 128)) else
                  '0';

    res_ovf    <= '1' when (reserved > FIFO_ENTRIES) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl fs_fetch_no_overflow : assert always
    --     ((RESET = '0') -> (ovf_e = '0' and ovf_o = '0'))
    --     report "FS_RING_FETCH: entry pushed into a full FIFO half!";

    -- psl fs_fetch_rsp_expected : assert always
    --     ((RESET = '0') -> (rsp_orphan = '0'))
    --     report "FS_RING_FETCH: response beat with no burst in flight!";

    -- psl fs_fetch_burst_ok : assert always
    --     ((RESET = '0') -> (burst_bad = '0'))
    --     report "FS_RING_FETCH: burst has 0 or >16 beats or crosses 4 KiB!";

    -- psl fs_fetch_reserved_bound : assert always
    --     ((RESET = '0') -> (res_ovf = '0'))
    --     report "FS_RING_FETCH: more entries reserved than the FIFO holds!";

end architecture;
