-- fs_hbm_port.vhd: the file shell's AXI3 master on its HBM port, shared by MI ring accesses and fetchers
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

-- ARID = client index keeps each client's bursts in order; clients reserve room before asking,
-- so responses have no ready. The AXI side resets with HBM_RESET only: after RESET it drains,
-- dropping the answers, before it takes a request.
entity FS_HBM_PORT is
    generic (
        FETCHERS : natural                       := 2*FS_MAX_STREAMS;
        HBM_BASE : std_logic_vector(33 downto 0) := (others => '0')
    );
    port (
        CLK       : in    std_logic;
        RESET     : in    std_logic;
        HBM_RESET : in    std_logic;
        CLEAR     : in    std_logic;
        HBM_READY : in    std_logic;

        -- ==============================
        -- MI ring client: one 32-bit access, a read waits for every earlier write's B
        -- ==============================
        RING_REQ_VLD    : in    std_logic;
        RING_REQ_WR     : in    std_logic;
        RING_REQ_ADDR   : in    std_logic_vector(FS_RING_HBM_ADDR_W-1 downto 0);
        RING_REQ_DATA   : in    std_logic_vector(31 downto 0);
        RING_REQ_BE     : in    std_logic_vector(3 downto 0);
        RING_REQ_RDY    : out   std_logic;
        RING_RSP_VLD    : out   std_logic;
        RING_RSP_DATA   : out   std_logic_vector(31 downto 0);
        -- Counts a write from the cycle after its RING_REQ handshake until its B response.
        RING_WR_PENDING : out   std_logic;

        -- ==============================
        -- Burst-read clients
        -- ==============================
        FREQ_VLD   : in    std_logic_vector(FETCHERS-1 downto 0);
        FREQ_ADDR  : in    slv_array_t(FETCHERS-1 downto 0)(FS_RING_HBM_ADDR_W-1 downto 0);
        FREQ_BEATS : in    slv_array_t(FETCHERS-1 downto 0)(4 downto 0);
        FREQ_RDY   : out   std_logic_vector(FETCHERS-1 downto 0);
        FRSP_VLD   : out   std_logic_vector(FETCHERS-1 downto 0);
        FRSP_DATA  : out   std_logic_vector(255 downto 0);
        FRSP_LAST  : out   std_logic;

        -- Sticky on any non-OKAY RRESP or BRESP.
        HBM_ERR : out   std_logic;

        -- ==============================
        -- AXI3 master, the signal set core_logic drives into hbm_ip per port
        -- ==============================
        M_AXI_ARADDR       : out   std_logic_vector(33 downto 0);
        M_AXI_ARBURST      : out   std_logic_vector(1 downto 0);
        M_AXI_ARID         : out   std_logic_vector(5 downto 0);
        M_AXI_ARLEN        : out   std_logic_vector(3 downto 0);
        M_AXI_ARSIZE       : out   std_logic_vector(2 downto 0);
        M_AXI_ARVALID      : out   std_logic;
        M_AXI_ARREADY      : in    std_logic;
        M_AXI_AWADDR       : out   std_logic_vector(33 downto 0);
        M_AXI_AWBURST      : out   std_logic_vector(1 downto 0);
        M_AXI_AWID         : out   std_logic_vector(5 downto 0);
        M_AXI_AWLEN        : out   std_logic_vector(3 downto 0);
        M_AXI_AWSIZE       : out   std_logic_vector(2 downto 0);
        M_AXI_AWVALID      : out   std_logic;
        M_AXI_AWREADY      : in    std_logic;
        M_AXI_WDATA        : out   std_logic_vector(255 downto 0);
        M_AXI_WDATA_PARITY : out   std_logic_vector(31 downto 0);
        M_AXI_WLAST        : out   std_logic;
        M_AXI_WSTRB        : out   std_logic_vector(31 downto 0);
        M_AXI_WVALID       : out   std_logic;
        M_AXI_WREADY       : in    std_logic;
        M_AXI_BID          : in    std_logic_vector(5 downto 0);
        M_AXI_BRESP        : in    std_logic_vector(1 downto 0);
        M_AXI_BVALID       : in    std_logic;
        M_AXI_BREADY       : out   std_logic;
        M_AXI_RDATA        : in    std_logic_vector(255 downto 0);
        M_AXI_RID          : in    std_logic_vector(5 downto 0);
        M_AXI_RLAST        : in    std_logic;
        M_AXI_RRESP        : in    std_logic_vector(1 downto 0);
        M_AXI_RVALID       : in    std_logic;
        M_AXI_RREADY       : out   std_logic
    );
end entity;

architecture FULL of FS_HBM_PORT is

    constant ID_W     : natural := 6;
    constant MI_ID    : natural := FETCHERS;
    constant WCNT_W   : natural := 6;
    constant WCNT_MAX : unsigned(WCNT_W-1 downto 0) := (others => '1');
    -- Every fetcher's bursts in flight plus the MI read.
    constant RCNT_W   : natural := log2(FS_FETCH_MAX_OUT*FETCHERS + 2);
    constant RCNT_MAX : unsigned(RCNT_W-1 downto 0) := (others => '1');
    -- 32 B beats: SIZE = log2(32), INCR bursts.
    constant AXSIZE   : std_logic_vector(2 downto 0) := "101";
    constant AXBURST  : std_logic_vector(1 downto 0) := "01";

    function lowest_f (vec : std_logic_vector) return natural is
    begin
        for i in vec'low to vec'high loop
            if (vec(i) = '1') then
                return i;
            end if;
        end loop;
        return vec'low;
    end function;

    function hbm_addr_f (addr : std_logic_vector(FS_RING_HBM_ADDR_W-1 downto 0)) return std_logic_vector is
        variable a_v : unsigned(33 downto 0);
    begin
        a_v := shift_left(resize(unsigned(addr(FS_RING_HBM_ADDR_W-1 downto 5)), 34), 5);
        return std_logic_vector(unsigned(HBM_BASE) + a_v);
    end function;

    signal mi_rd_want : std_logic;
    signal mi_wr_acc  : std_logic;
    signal mi_rd_acc  : std_logic;
    signal mi_rd_out  : std_logic;
    signal mi_lane_r  : natural range 0 to 7;

    signal port_ok  : std_logic;
    signal ar_free  : std_logic;
    signal f_req    : std_logic_vector(FETCHERS-1 downto 0);
    signal f_masked : std_logic_vector(FETCHERS-1 downto 0);
    signal f_win    : natural range 0 to FETCHERS-1;
    signal f_grant  : std_logic_vector(FETCHERS-1 downto 0);
    -- Bit i set: fetcher i is at or after the round-robin pointer.
    signal rr_mask  : std_logic_vector(FETCHERS-1 downto 0);

    signal ar_vld_r  : std_logic;
    signal ar_addr_r : std_logic_vector(33 downto 0);
    signal ar_len_r  : std_logic_vector(3 downto 0);
    signal ar_id_r   : std_logic_vector(ID_W-1 downto 0);

    signal aw_vld_r  : std_logic;
    signal aw_addr_r : std_logic_vector(33 downto 0);
    signal w_vld_r   : std_logic;
    signal w_data_r  : std_logic_vector(255 downto 0);
    signal w_strb_r  : std_logic_vector(31 downto 0);

    signal wr_cnt  : unsigned(WCNT_W-1 downto 0);
    signal rd_cnt  : unsigned(RCNT_W-1 downto 0);
    signal flush_r : std_logic;

    signal frsp_vld_r : std_logic_vector(FETCHERS-1 downto 0);
    signal frsp_dat_r : std_logic_vector(255 downto 0);
    signal frsp_lst_r : std_logic;
    signal rsp_vld_r  : std_logic;
    signal rsp_dat_r  : std_logic_vector(31 downto 0);
    signal hbm_err_r  : std_logic;

    -- Assertion helpers.
    signal grant_bad   : std_logic;
    signal wr_cnt_zero : std_logic;
    signal rd_cnt_zero : std_logic;
    signal rd_cnt_full : std_logic;
    signal rid_bad     : std_logic;
    signal acc_flush   : std_logic;

begin

    assert (FETCHERS >= 1 and FETCHERS < 2**ID_W)
        report "FS_HBM_PORT: FETCHERS must be 1 to " & integer'image(2**ID_W - 1) & "."
        severity FAILURE;

    -- =============================================================================================
    -- MI client
    -- =============================================================================================
    port_ok <= HBM_READY and not flush_r;

    -- Reads wait for the B of every write: AXI does not order a read behind a write to the same word.
    mi_rd_want <= RING_REQ_VLD and not RING_REQ_WR and port_ok and not mi_rd_out when (wr_cnt = 0) else '0';
    mi_rd_acc  <= mi_rd_want and ar_free;
    mi_wr_acc  <= RING_REQ_VLD and RING_REQ_WR and port_ok and not aw_vld_r and not w_vld_r when (wr_cnt /= WCNT_MAX) else
                  '0';

    RING_REQ_RDY <= mi_rd_acc or mi_wr_acc;

    -- =============================================================================================
    -- AR arbitration: MI first, then round-robin over the fetchers
    -- =============================================================================================
    ar_free  <= port_ok and not ar_vld_r;
    f_req    <= FREQ_VLD when (ar_free = '1' and mi_rd_want = '0') else (others => '0');
    f_masked <= f_req and rr_mask;
    f_win    <= lowest_f(f_masked) when (unsigned(f_masked) /= 0) else lowest_f(f_req);

    grant_p : process (all) is
    begin
        f_grant <= (others => '0');
        if (unsigned(f_req) /= 0) then
            f_grant(f_win) <= '1';
        end if;
    end process;

    FREQ_RDY <= f_grant;

    ar_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (ar_vld_r = '1' and M_AXI_ARREADY = '1') then
                ar_vld_r <= '0';
            end if;

            if (mi_rd_acc = '1') then
                ar_vld_r  <= '1';
                ar_addr_r <= hbm_addr_f(RING_REQ_ADDR);
                ar_len_r  <= (others => '0');
                ar_id_r   <= std_logic_vector(to_unsigned(MI_ID, ID_W));
                mi_lane_r <= to_integer(unsigned(RING_REQ_ADDR(4 downto 2)));
            elsif (unsigned(f_grant) /= 0) then
                ar_vld_r  <= '1';
                ar_addr_r <= hbm_addr_f(FREQ_ADDR(f_win));
                ar_len_r  <= std_logic_vector(resize(unsigned(FREQ_BEATS(f_win)) - 1, 4));
                ar_id_r   <= std_logic_vector(to_unsigned(f_win, ID_W));
                for i in 0 to FETCHERS-1 loop
                    if (i > f_win) then
                        rr_mask(i) <= '1';
                    else
                        rr_mask(i) <= '0';
                    end if;
                end loop;
            end if;

            if (RESET = '1') then
                rr_mask <= (others => '1');
            end if;
            if (HBM_RESET = '1') then
                ar_vld_r <= '0';
            end if;
        end if;
    end process;

    -- Counted at the AR handshake, so a held AR keeps the port out of idle on its own; RLAST ends a burst.
    rd_cnt_p : process (CLK) is
        variable cnt_v : unsigned(RCNT_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            cnt_v := rd_cnt;
            if (ar_vld_r = '1' and M_AXI_ARREADY = '1') then
                cnt_v := cnt_v + 1;
            end if;
            if (M_AXI_RVALID = '1' and M_AXI_RLAST = '1') then
                cnt_v := cnt_v - 1;
            end if;
            rd_cnt <= cnt_v;

            if (HBM_RESET = '1') then
                rd_cnt <= (others => '0');
            end if;
        end if;
    end process;

    M_AXI_ARADDR  <= ar_addr_r;
    M_AXI_ARBURST <= AXBURST;
    M_AXI_ARID    <= ar_id_r;
    M_AXI_ARLEN   <= ar_len_r;
    M_AXI_ARSIZE  <= AXSIZE;
    M_AXI_ARVALID <= ar_vld_r;

    -- =============================================================================================
    -- AW/W: MI writes only, one beat each. A beat held when RESET hits stays held until its handshake,
    -- so no AW or W is withdrawn or left owed.
    -- =============================================================================================
    wr_p : process (CLK) is
        variable lane_v : natural range 0 to 7;
        variable cnt_v  : unsigned(WCNT_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            if (aw_vld_r = '1' and M_AXI_AWREADY = '1') then
                aw_vld_r <= '0';
            end if;
            if (w_vld_r = '1' and M_AXI_WREADY = '1') then
                w_vld_r <= '0';
            end if;

            if (mi_wr_acc = '1') then
                lane_v    := to_integer(unsigned(RING_REQ_ADDR(4 downto 2)));
                aw_vld_r  <= '1';
                aw_addr_r <= hbm_addr_f(RING_REQ_ADDR);
                w_vld_r   <= '1';
                for l in 0 to 7 loop
                    w_data_r(32*l+31 downto 32*l) <= RING_REQ_DATA;
                end loop;
                w_strb_r                              <= (others => '0');
                w_strb_r(4*lane_v+3 downto 4*lane_v)  <= RING_REQ_BE;
            end if;

            cnt_v := wr_cnt;
            if (mi_wr_acc = '1') then
                cnt_v := cnt_v + 1;
            end if;
            if (M_AXI_BVALID = '1') then
                cnt_v := cnt_v - 1;
            end if;
            wr_cnt <= cnt_v;

            if (HBM_RESET = '1') then
                aw_vld_r <= '0';
                w_vld_r  <= '0';
                wr_cnt   <= (others => '0');
            end if;
        end if;
    end process;

    M_AXI_AWADDR       <= aw_addr_r;
    M_AXI_AWBURST      <= AXBURST;
    M_AXI_AWID         <= std_logic_vector(to_unsigned(MI_ID, ID_W));
    M_AXI_AWLEN        <= (others => '0');
    M_AXI_AWSIZE       <= AXSIZE;
    M_AXI_AWVALID      <= aw_vld_r;
    M_AXI_WDATA        <= w_data_r;
    M_AXI_WDATA_PARITY <= (others => '0');
    M_AXI_WLAST        <= '1';
    M_AXI_WSTRB        <= w_strb_r;
    M_AXI_WVALID       <= w_vld_r;
    M_AXI_BREADY       <= '1';

    RING_WR_PENDING <= '1' when (wr_cnt /= 0) else '0';

    -- =============================================================================================
    -- R routing by ID, B and R error tracking; answers of transactions from before a RESET are dropped
    -- =============================================================================================
    M_AXI_RREADY <= '1';

    rsp_p : process (CLK) is
        variable rid_v : natural range 0 to 2**ID_W-1;
    begin
        if (rising_edge(CLK)) then
            rid_v := to_integer(unsigned(M_AXI_RID));

            for f in 0 to FETCHERS-1 loop
                if (M_AXI_RVALID = '1' and rid_v = f and flush_r = '0') then
                    frsp_vld_r(f) <= '1';
                else
                    frsp_vld_r(f) <= '0';
                end if;
            end loop;
            frsp_dat_r <= M_AXI_RDATA;
            frsp_lst_r <= M_AXI_RLAST;

            rsp_vld_r <= '0';
            if (M_AXI_RVALID = '1' and rid_v = MI_ID and flush_r = '0') then
                rsp_vld_r <= '1';
                mi_rd_out <= '0';
            end if;
            rsp_dat_r <= M_AXI_RDATA(32*mi_lane_r+31 downto 32*mi_lane_r);

            if (mi_rd_acc = '1') then
                mi_rd_out <= '1';
            end if;

            if (flush_r = '0' and
                ((M_AXI_RVALID = '1' and M_AXI_RRESP /= "00") or (M_AXI_BVALID = '1' and M_AXI_BRESP /= "00"))) then
                hbm_err_r <= '1';
            elsif (CLEAR = '1') then
                hbm_err_r <= '0';
            end if;

            if (RESET = '1') then
                frsp_vld_r <= (others => '0');
                rsp_vld_r  <= '0';
                mi_rd_out  <= '0';
                hbm_err_r  <= '0';
            end if;
        end if;
    end process;

    -- Idle: nothing issued is left to answer. Everything in flight at RESET answers by then, so the
    -- port takes requests again with no stale response possible.
    flush_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (wr_cnt = 0 and rd_cnt = 0 and ar_vld_r = '0') then
                flush_r <= '0';
            end if;
            if (RESET = '1') then
                flush_r <= '1';
            end if;
            if (HBM_RESET = '1') then
                flush_r <= '0';
            end if;
        end if;
    end process;

    FRSP_VLD      <= frsp_vld_r;
    FRSP_DATA     <= frsp_dat_r;
    FRSP_LAST     <= frsp_lst_r;
    RING_RSP_VLD  <= rsp_vld_r;
    RING_RSP_DATA <= rsp_dat_r;
    HBM_ERR       <= hbm_err_r;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    grant_bad_p : process (all) is
        variable beats_v : natural range 0 to 31;
        variable bad_v   : std_logic;
    begin
        bad_v := '0';
        if (unsigned(f_grant) /= 0) then
            beats_v := to_integer(unsigned(FREQ_BEATS(f_win)));
            if (beats_v = 0 or beats_v > 16 or unsigned(FREQ_ADDR(f_win)(4 downto 0)) /= 0 or
                to_integer(unsigned(FREQ_ADDR(f_win)(11 downto 5))) + beats_v > 128) then
                bad_v := '1';
            end if;
        end if;
        grant_bad <= bad_v;
    end process;

    wr_cnt_zero <= '1' when (wr_cnt = 0) else '0';
    rd_cnt_zero <= '1' when (rd_cnt = 0) else '0';
    rd_cnt_full <= '1' when (rd_cnt = RCNT_MAX) else '0';
    rid_bad     <= '1' when (M_AXI_RVALID = '1' and flush_r = '0' and
                             (to_integer(unsigned(M_AXI_RID)) > MI_ID or
                              (to_integer(unsigned(M_AXI_RID)) = MI_ID and mi_rd_out = '0'))) else
                   '0';
    acc_flush   <= '1' when (flush_r = '1' and (mi_rd_acc = '1' or mi_wr_acc = '1' or unsigned(f_grant) /= 0)) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl fs_hbm_burst_ok : assert always
    --     ((RESET = '0') -> (grant_bad = '0'))
    --     report "FS_HBM_PORT: fetcher burst has 0 or >16 beats, is unaligned or crosses 4 KiB!";

    -- psl fs_hbm_b_expected : assert always
    --     ((HBM_RESET = '0' and M_AXI_BVALID = '1') -> (wr_cnt_zero = '0'))
    --     report "FS_HBM_PORT: B response without an outstanding write!";

    -- psl fs_hbm_r_expected : assert always
    --     ((HBM_RESET = '0' and M_AXI_RVALID = '1' and M_AXI_RLAST = '1') -> (rd_cnt_zero = '0'))
    --     report "FS_HBM_PORT: last R beat without an outstanding read burst!";

    -- psl fs_hbm_rd_cnt_wide : assert always
    --     ((HBM_RESET = '0' and ar_vld_r = '1' and M_AXI_ARREADY = '1') -> (rd_cnt_full = '0'))
    --     report "FS_HBM_PORT: more read bursts in flight than FS_FETCH_MAX_OUT per fetcher!";

    -- psl fs_hbm_flush_refuses : assert always
    --     ((HBM_RESET = '0') -> (acc_flush = '0'))
    --     report "FS_HBM_PORT: request accepted while draining after RESET!";

    -- psl fs_hbm_rid_known : assert always
    --     ((RESET = '0') -> (rid_bad = '0'))
    --     report "FS_HBM_PORT: R beat with an ID nobody has outstanding!";

    -- psl fs_hbm_ready_first : assert always
    --     ((HBM_RESET = '0' and HBM_READY = '0') -> (ar_vld_r = '0' and aw_vld_r = '0' and w_vld_r = '0'))
    --     report "FS_HBM_PORT: AXI request issued before HBM_READY!";

end architecture;
