-- fs_ctrl.vhd: job state machine and error collection of the file shell
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

-- CLEAR and START reach the planes only while nothing is in flight, so a write frame is never cut
-- and no completion of an old job is attributed to a new one.
entity FS_CTRL is
    generic (
        STREAMS        : natural := FS_MAX_STREAMS;
        NUM_QUEUES     : natural := 4;
        PCIE_ENDPOINTS : natural := 1;
        -- Cycles without a read frame ending before DONE or ERR: a DATA_LOST comes after its frame.
        DONE_QUIET     : natural := 1024
    );
    port (
        CLK   : in    std_logic;
        RESET : in    std_logic;

        -- =========================================================================================
        -- Commands and configuration from FS_REGS
        -- =========================================================================================
        CTRL_START         : in    std_logic;
        CTRL_ABORT         : in    std_logic;
        CTRL_CLEAR         : in    std_logic;
        STREAM_MASK        : in    std_logic_vector(STREAMS-1 downto 0);
        STRIPE_LOG2_DRIVES : in    std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
        STRIPE_LOG2_CHUNK  : in    std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);

        -- =========================================================================================
        -- Plane control
        -- =========================================================================================
        PLANE_CLEAR : out   std_logic;
        -- One bit per stream, only the enabled ones.
        PLANE_START : out   std_logic_vector(STREAMS-1 downto 0);
        PLANE_ABORT : out   std_logic;
        -- Stream enabled and the job running.
        ENABLE      : out   std_logic_vector(STREAMS-1 downto 0);
        SINK        : out   std_logic;

        -- =========================================================================================
        -- Status for FS_REGS
        -- =========================================================================================
        STATUS_BUSY   : out   std_logic;
        STATUS_DONE   : out   std_logic;
        STATUS_ERR    : out   std_logic;
        STATUS_STATE  : out   std_logic_vector(7 downto 0);
        STREAM_STATUS : out   slv_array_t(STREAMS-1 downto 0)(3 downto 0);
        ERR_INFO      : out   slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        IN_BYTES      : out   slv_array_t(STREAMS-1 downto 0)(63 downto 0);

        -- =========================================================================================
        -- Stream progress
        -- =========================================================================================
        IN_DONE    : in    std_logic_vector(STREAMS-1 downto 0);
        OUT_DONE   : in    std_logic_vector(STREAMS-1 downto 0);
        NEED_SPACE : in    std_logic_vector(STREAMS-1 downto 0);

        -- =========================================================================================
        -- Error sources
        -- =========================================================================================
        PLAN_ERR        : in    std_logic_vector(STREAMS-1 downto 0);
        PLAN_ERR_INFO   : in    slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        WRITER_ERR      : in    std_logic_vector(STREAMS-1 downto 0);
        WRITER_ERR_INFO : in    slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        ARG_ERR         : in    std_logic_vector(STREAMS-1 downto 0);
        RERR_VLD        : in    std_logic;
        RERR_MASK       : in    std_logic_vector(STREAMS-1 downto 0);
        RERR_INFO       : in    std_logic_vector(31 downto 0);
        WERR_VLD        : in    std_logic;
        WERR_MASK       : in    std_logic_vector(STREAMS-1 downto 0);
        WERR_INFO       : in    std_logic_vector(31 downto 0);
        HBM_ERR         : in    std_logic;

        -- =========================================================================================
        -- Datapath activity
        -- =========================================================================================
        RD_IDLE        : in    std_logic;
        RD_DATA_IDLE   : in    std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        -- A read frame's last beat was taken from the endpoint's engine-side stream.
        RD_EOF         : in    std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        WR_BUSY        : in    std_logic_vector(STREAMS-1 downto 0);
        WR_OUTSTANDING : in    std_logic_vector(STREAMS-1 downto 0);
        -- A write frame's first beat left for the DMA, and a write status came back (any code).
        WR_FRAME       : in    std_logic;
        WR_STATUS      : in    std_logic;
        BYTES_VLD      : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(STREAMS-1 downto 0);
        BYTES_N        : in    slv_array_t(PCIE_ENDPOINTS-1 downto 0)(FS_BYTES_W-1 downto 0)
    );
end entity;

architecture FULL of FS_CTRL is

    type state_t is (S_IDLE, S_RUN, S_DRAIN, S_DONE, S_ERR);

    constant MAX_LD   : natural := fs_max_log2_drives_f(NUM_QUEUES);
    constant QUIET_W  : natural := log2(DONE_QUIET + 1) + 1;
    -- Consecutive idle samples taken inside a state: the first one may predate the state change.
    constant SETTLE   : natural := 3;
    constant INC_W    : natural := FS_BYTES_W + log2(PCIE_ENDPOINTS) + 1;
    -- Writes between their frame and their status: the DMA's 64 tags per queue plus the pipelines.
    constant WFL_W    : natural := log2(NUM_QUEUES*128) + 1;

    constant INFO_ABORT : std_logic_vector(31 downto 0) := fs_err_info_f(FS_ERR_SRC_ABORT, "00", '0', "0000", X"0000");
    constant INFO_HBM   : std_logic_vector(31 downto 0) := fs_err_info_f(FS_ERR_SRC_HBM, "00", '0', "0000", X"0000");
    -- A bad STRIPE and a kernel's ARG_ERR name no ring entry, so neither carries the input bit.
    constant INFO_ARG   : std_logic_vector(31 downto 0) := fs_err_info_f(FS_ERR_SRC_FORMAT, "00", '0', "0000", X"0000");

    signal state     : state_t;
    signal state_nxt : state_t;

    signal start_pend : std_logic;
    signal clear_pend : std_logic;
    signal mask_r     : std_logic_vector(STREAMS-1 downto 0);

    signal geom_ok    : std_logic;
    signal start_exec : std_logic;
    signal clear_exec : std_logic;

    signal dp_idle   : std_logic;
    signal dp_idle_r : std_logic;
    signal idle_cnt  : unsigned(1 downto 0);
    signal idle_ok   : std_logic;
    signal quiet_cnt : unsigned(QUIET_W-1 downto 0);
    signal quiet_ok  : std_logic;
    signal all_done  : std_logic;
    -- FS_WR_ARB cannot retire a write rejected with code 10 (no queue named), so its per-stream
    -- counts stay up after one; every write still gets exactly one status, which this counts.
    signal wr_flight : unsigned(WFL_W-1 downto 0);

    signal err_s    : std_logic_vector(STREAMS-1 downto 0);
    signal err_any  : std_logic;
    signal err_live : std_logic;
    signal info_s   : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal stream_err : std_logic_vector(STREAMS-1 downto 0);
    signal err_info_r : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal plane_clear_r : std_logic;
    signal plane_start_r : std_logic_vector(STREAMS-1 downto 0);
    signal plane_abort_r : std_logic;

    type   inc_arr_t is array (0 to STREAMS-1) of unsigned(INC_W-1 downto 0);
    type   acc_arr_t is array (0 to STREAMS-1) of unsigned(63 downto 0);
    signal inc_r : inc_arr_t;
    signal acc_r : acc_arr_t;

    -- Assertion helpers.
    signal chk_start_busy : std_logic;
    signal chk_clear_busy : std_logic;
    signal chk_done_wr    : std_logic;
    signal chk_wr_under   : std_logic;

begin

    assert (STREAMS >= 1 and STREAMS <= FS_MAX_STREAMS)
        report "FS_CTRL: STREAMS must be 1 to " & integer'image(FS_MAX_STREAMS) & "."
        severity FAILURE;
    assert (DONE_QUIET >= 1)
        report "FS_CTRL: DONE_QUIET must be at least 1."
        severity FAILURE;

    -- =============================================================================================
    -- Conditions
    -- =============================================================================================
    geom_ok <= '1' when (unsigned(STRIPE_LOG2_CHUNK) >= 1 and unsigned(STRIPE_LOG2_CHUNK) <= FS_MAX_LOG2_CHUNK
                         and unsigned(STRIPE_LOG2_DRIVES) <= MAX_LD) else
               '0';

    dp_idle <= '1' when (RD_IDLE = '1' and (and RD_DATA_IDLE) = '1' and unsigned(WR_BUSY) = 0
                         and wr_flight = 0) else
               '0';

    idle_ok  <= '1' when (idle_cnt = SETTLE) else '0';
    quiet_ok <= '1' when (quiet_cnt = DONE_QUIET) else '0';
    all_done <= '1' when ((mask_r and not (IN_DONE and OUT_DONE)) = (STREAMS-1 downto 0 => '0')) else '0';

    start_exec <= '1' when (state = S_IDLE and start_pend = '1' and clear_pend = '0' and idle_ok = '1') else '0';
    clear_exec <= '1' when (clear_pend = '1' and idle_ok = '1'
                            and (state = S_IDLE or state = S_DONE or state = S_ERR
                                 or (state = S_DRAIN and quiet_ok = '1'))) else
                  '0';

    -- =============================================================================================
    -- Errors: per stream the first one that names it, in a fixed order when several share a cycle
    -- =============================================================================================

    err_live <= '1' when (state = S_RUN or state = S_DRAIN) else '0';

    err_g : for s in 0 to STREAMS-1 generate
        err_p : process (all) is
        begin
            err_s(s)  <= '0';
            info_s(s) <= INFO_ABORT;
            if (CTRL_ABORT = '1') then
                err_s(s) <= '1';
            end if;
            if (HBM_ERR = '1') then
                err_s(s)  <= '1';
                info_s(s) <= INFO_HBM;
            end if;
            if (WERR_VLD = '1' and WERR_MASK(s) = '1') then
                err_s(s)  <= '1';
                info_s(s) <= WERR_INFO;
            end if;
            if (RERR_VLD = '1' and RERR_MASK(s) = '1') then
                err_s(s)  <= '1';
                info_s(s) <= RERR_INFO;
            end if;
            if (ARG_ERR(s) = '1') then
                err_s(s)  <= '1';
                info_s(s) <= INFO_ARG;
            end if;
            if (WRITER_ERR(s) = '1') then
                err_s(s)  <= '1';
                info_s(s) <= WRITER_ERR_INFO(s);
            end if;
            if (PLAN_ERR(s) = '1') then
                err_s(s)  <= '1';
                info_s(s) <= PLAN_ERR_INFO(s);
            end if;
            if (err_live = '0' or mask_r(s) = '0') then
                err_s(s) <= '0';
            end if;
        end process;
    end generate;

    -- ABORT fails the job even with no stream enabled.
    err_any <= (or err_s) or (err_live and (CTRL_ABORT or HBM_ERR));

    -- =============================================================================================
    -- FSM
    -- =============================================================================================
    fsm_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            state <= state_nxt;
            if (RESET = '1') then
                state <= S_IDLE;
            end if;
        end if;
    end process;

    fsm_nxt_p : process (all) is
    begin
        state_nxt <= state;
        case state is
            when S_IDLE =>
                if (start_exec = '1') then
                    if (geom_ok = '1') then
                        state_nxt <= S_RUN;
                    else
                        state_nxt <= S_ERR;
                    end if;
                end if;

            when S_RUN =>
                if (err_any = '1' or clear_pend = '1') then
                    state_nxt <= S_DRAIN;
                elsif (all_done = '1' and idle_ok = '1' and quiet_ok = '1') then
                    state_nxt <= S_DONE;
                end if;

            when S_DRAIN =>
                if (idle_ok = '1' and quiet_ok = '1') then
                    if (clear_pend = '1') then
                        state_nxt <= S_IDLE;
                    else
                        state_nxt <= S_ERR;
                    end if;
                end if;

            when S_DONE | S_ERR =>
                if (clear_exec = '1') then
                    state_nxt <= S_IDLE;
                end if;
        end case;
    end process;

    -- =============================================================================================
    -- Datapath
    -- =============================================================================================
    ctrl_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            plane_clear_r <= clear_exec;
            plane_start_r <= (others => '0');
            plane_abort_r <= '0';

            if (CTRL_START = '1' and state = S_IDLE) then
                start_pend <= '1';
            end if;
            if (CTRL_CLEAR = '1') then
                clear_pend <= '1';
            end if;
            if (clear_exec = '1') then
                clear_pend <= '0';
                start_pend <= '0';
            end if;

            if (start_exec = '1') then
                start_pend <= '0';
                mask_r     <= STREAM_MASK;
                if (geom_ok = '1') then
                    plane_start_r <= STREAM_MASK;
                else
                    stream_err <= STREAM_MASK;
                    for s in 0 to STREAMS-1 loop
                        if (STREAM_MASK(s) = '1') then
                            err_info_r(s) <= INFO_ARG;
                        end if;
                    end loop;
                end if;
            end if;

            if (state = S_RUN and state_nxt = S_DRAIN) then
                plane_abort_r <= '1';
            end if;

            for s in 0 to STREAMS-1 loop
                if (err_s(s) = '1' and stream_err(s) = '0') then
                    stream_err(s) <= '1';
                    err_info_r(s) <= info_s(s);
                end if;
            end loop;

            dp_idle_r <= dp_idle;
            if (state_nxt /= state or dp_idle_r = '0') then
                idle_cnt <= (others => '0');
            elsif (idle_cnt /= SETTLE) then
                idle_cnt <= idle_cnt + 1;
            end if;

            if (WR_FRAME = '1' and WR_STATUS = '0') then
                wr_flight <= wr_flight + 1;
            elsif (WR_FRAME = '0' and WR_STATUS = '1') then
                wr_flight <= wr_flight - 1;
            end if;

            if ((or RD_EOF) = '1' or start_exec = '1') then
                quiet_cnt <= (others => '0');
            elsif (quiet_cnt /= DONE_QUIET) then
                quiet_cnt <= quiet_cnt + 1;
            end if;

            if (clear_exec = '1') then
                stream_err <= (others => '0');
                err_info_r <= (others => (others => '0'));
            end if;

            if (RESET = '1') then
                start_pend    <= '0';
                clear_pend    <= '0';
                mask_r        <= (others => '0');
                plane_clear_r <= '0';
                plane_start_r <= (others => '0');
                plane_abort_r <= '0';
                stream_err    <= (others => '0');
                err_info_r    <= (others => (others => '0'));
                dp_idle_r     <= '0';
                idle_cnt      <= (others => '0');
                quiet_cnt     <= (others => '0');
                wr_flight     <= (others => '0');
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- IN_BYTES: the endpoints' increments summed in one stage, accumulated in the next
    -- =============================================================================================
    bytes_p : process (CLK) is
        variable inc_v : unsigned(INC_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            for s in 0 to STREAMS-1 loop
                inc_v := (others => '0');
                for e in 0 to PCIE_ENDPOINTS-1 loop
                    if (BYTES_VLD(e)(s) = '1') then
                        inc_v := inc_v + unsigned(BYTES_N(e));
                    end if;
                end loop;
                inc_r(s) <= inc_v;
                acc_r(s) <= acc_r(s) + inc_r(s);
            end loop;

            if (RESET = '1' or plane_clear_r = '1') then
                inc_r <= (others => (others => '0'));
                acc_r <= (others => (others => '0'));
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Outputs
    -- =============================================================================================
    PLANE_CLEAR <= plane_clear_r;
    PLANE_START <= plane_start_r;
    PLANE_ABORT <= plane_abort_r;
    ENABLE      <= mask_r when (state = S_RUN) else (others => '0');
    SINK        <= '1' when (state = S_DRAIN or state = S_ERR) else '0';

    STATUS_BUSY  <= '1' when (state = S_RUN or state = S_DRAIN or start_pend = '1') else '0';
    STATUS_DONE  <= '1' when (state = S_DONE) else '0';
    STATUS_ERR   <= '1' when (state = S_ERR) else '0';
    STATUS_STATE <= std_logic_vector(to_unsigned(state_t'pos(state), 8));

    status_g : for s in 0 to STREAMS-1 generate
        STREAM_STATUS(s)(FS_SSTAT_IN_DONE_BIT)    <= IN_DONE(s);
        STREAM_STATUS(s)(FS_SSTAT_OUT_DONE_BIT)   <= OUT_DONE(s);
        STREAM_STATUS(s)(FS_SSTAT_NEED_SPACE_BIT) <= NEED_SPACE(s);
        STREAM_STATUS(s)(FS_SSTAT_ERR_BIT)        <= stream_err(s);
        IN_BYTES(s)                               <= std_logic_vector(acc_r(s));
    end generate;

    ERR_INFO <= err_info_r;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    chk_start_busy <= '1' when ((or plane_start_r) = '1' and dp_idle_r = '0') else '0';
    chk_clear_busy <= '1' when (plane_clear_r = '1' and dp_idle_r = '0') else '0';
    chk_done_wr    <= '1' when (state = S_DONE and unsigned(WR_OUTSTANDING) /= 0) else '0';
    chk_wr_under   <= '1' when (WR_STATUS = '1' and WR_FRAME = '0' and wr_flight = 0) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl fs_ctrl_start_quiet : assert always
    --     ((RESET = '0') -> (chk_start_busy = '0'))
    --     report "FS_CTRL: START reached the planes with the datapath busy!";

    -- psl fs_ctrl_clear_quiet : assert always
    --     ((RESET = '0') -> (chk_clear_busy = '0'))
    --     report "FS_CTRL: CLEAR reached the planes with the datapath busy!";

    -- psl fs_ctrl_done_written : assert always
    --     ((RESET = '0') -> (chk_done_wr = '0'))
    --     report "FS_CTRL: DONE with a write still outstanding!";

    -- psl fs_ctrl_wr_status_expected : assert always
    --     ((RESET = '0') -> (chk_wr_under = '0'))
    --     report "FS_CTRL: a write status with no write frame in flight!";

    -- psl fs_ctrl_enable_in_run : assert always
    --     ((RESET = '0' and state /= S_RUN) -> (unsigned(ENABLE) = 0))
    --     report "FS_CTRL: a stream is enabled outside RUN!";

end architecture;
