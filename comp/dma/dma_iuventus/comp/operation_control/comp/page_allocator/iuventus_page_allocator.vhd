-- iuventus_page_allocator.vhd: pipelined first-fit contiguous page allocator over a fixed
-- number of pages, used to hand out regions of a page-based FPGA-BAR buffer
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;

-- Note: the allocate path is pipelined over L=2 register stages (fits_q, then the registered
-- ALLOC_GRANT/ALLOC_PAGE outputs) to keep each stage's combinational logic shallow at PAGES=128.
-- ALLOC_GRANT/ALLOC_PAGE are therefore NOT valid the same cycle ALLOC_REQ_NPAGES/occupancy
-- settle -- callers must wait for ALLOC_DONE='1' before treating them as current and committing
-- (ALLOC_REQ_VLD='1' with ALLOC_GRANT='1' on a rising CLK edge, as before).

entity IUVENTUS_PAGE_ALLOCATOR is

    generic (
        PAGES           : positive := 32;
        -- The first RESERVED_PAGES pages (i.e. page indices 0 .. RESERVED_PAGES-1) are
        -- permanently treated as occupied: they are never granted by ALLOC and a FREE covering
        -- them is a no-op for them. Used to reserve the flat-addressed buffer's page 0 for the
        -- queue (SQ/CQ), so only pages RESERVED_PAGES..PAGES-1 are ever handed out as data pages.
        RESERVED_PAGES  : natural  := 0;
        -- Upper bound on a single ALLOC_REQ_NPAGES request. Bounds the per-k feasibility window
        -- (fits(k) only has to NOR occupancy over MAX_ALLOC_PAGES bits, not all of PAGES), which
        -- is what actually keeps stage 1 shallow at PAGES=128 -- a single allocation is never
        -- larger than this in practice (MAX_WR_PAGES=32 for writes; a read is <=256 LBAs = 32
        -- pages), so this only trades away headroom that was never used.
        MAX_ALLOC_PAGES : positive := 32
    );

    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- Allocation interface
        --
        -- ALLOC_GRANT/ALLOC_PAGE reflect the (pipelined, L=2-cycle-deep) feasibility and location
        -- of the request currently held on ALLOC_REQ_NPAGES, valid once ALLOC_DONE='1'. The
        -- allocation is only committed into the occupancy state when ALLOC_REQ_VLD = '1' and
        -- ALLOC_GRANT = '1' on a rising CLK edge -- callers must gate ALLOC_REQ_VLD on
        -- ALLOC_DONE='1' themselves (this component does not stall/backpressure the request).
        -- =========================================================================================
        ALLOC_REQ_NPAGES : in  std_logic_vector(log2(PAGES) downto 0);
        ALLOC_REQ_VLD    : in  std_logic;
        ALLOC_GRANT      : out std_logic;
        ALLOC_PAGE       : out std_logic_vector(log2(PAGES)-1 downto 0);
        -- '1' iff ALLOC_GRANT/ALLOC_PAGE currently correspond to the request held on
        -- ALLOC_REQ_NPAGES and to the current occupancy (i.e. the L-deep pipeline has settled
        -- since the last change of either). See done_cnt_p.
        ALLOC_DONE       : out std_logic;

        -- =========================================================================================
        -- Free interface (synchronous)
        -- =========================================================================================
        FREE_PAGE   : in std_logic_vector(log2(PAGES)-1 downto 0);
        FREE_NPAGES : in std_logic_vector(log2(PAGES) downto 0);
        FREE_VLD    : in std_logic;

        -- =========================================================================================
        -- Debug/observability
        -- =========================================================================================
        PAGES_FREE : out std_logic_vector(log2(PAGES) downto 0)
    );

end entity;

architecture FULL of IUVENTUS_PAGE_ALLOCATOR is

    constant PAGE_IDX_W  : natural := log2(PAGES);
    constant CNT_W       : natural := log2(PAGES) + 1;

    -- Pipeline depth (number of register stages between an ALLOC_REQ_NPAGES/occupancy change and
    -- ALLOC_GRANT/ALLOC_PAGE reflecting it): fits_q (stage 1) + the registered ALLOC_GRANT/
    -- ALLOC_PAGE outputs (stage 2). ALLOC_DONE's stability counter uses this same constant, so
    -- correctness does not depend on its exact value -- see done_cnt_p.
    constant L           : natural := 2;
    constant DONE_CNT_W  : natural := log2(L + 1);

    -- Hierarchical priority-encoder geometry: PAGES is split into NUM_GROUPS groups of GROUP_SIZE
    -- pages each (16 groups of 8 for PAGES=128). Both stages of the select (which group, then
    -- which page within it) are plain OR-reduce / priority-mux logic over <=16 elements -- no
    -- arithmetic (no carry-chain inference), unlike the previous x&-x + GEN_ENC encoder.
    constant GROUP_SIZE    : natural := 8;
    constant GROUP_SIZE_W  : natural := log2(GROUP_SIZE);
    constant NUM_GROUPS    : natural := PAGES / GROUP_SIZE;
    constant GROUP_IDX_W   : natural := log2(NUM_GROUPS);

    -- Bit i is '1' for i < RESERVED_PAGES, '0' otherwise. OR-ed into the occupancy state on
    -- every update so the reserved pages can never be granted or freed.
    function reserved_mask_f (pages : natural; reserved : natural) return std_logic_vector is
        variable result : std_logic_vector(pages-1 downto 0) := (others => '0');
    begin
        for i in 0 to pages-1 loop
            if (i < reserved) then
                result(i) := '1';
            end if;
        end loop;
        return result;
    end function;

    -- Priority-encodes the lowest-index '1' bit of vec (vec'low = index 0). Returns
    -- valid & index packed as (idx_w downto 0): bit(idx_w) is the valid flag, bits(idx_w-1
    -- downto 0) are the index (0 when invalid). Used for both the 16-way group select and the
    -- 8-way within-group select below; at these small widths this is a shallow LUT/mux network,
    -- not a carry chain (no arithmetic operators are involved).
    function priority_encode_f (vec : std_logic_vector; idx_w : natural) return std_logic_vector is
        variable result_v : std_logic_vector(idx_w downto 0) := (others => '0');
        variable found_v  : boolean := false;
    begin
        for i in 0 to vec'length-1 loop
            if (not found_v and vec(vec'low + i) = '1') then
                result_v(idx_w-1 downto 0) := std_logic_vector(to_unsigned(i, idx_w));
                result_v(idx_w)            := '1';
                found_v                    := true;
            end if;
        end loop;
        return result_v;
    end function;

    -- Thermometer-decodes len into a width-bit mask: bit i = '1' iff i < len. Each bit is an
    -- independent, order-independent compare of a constant i against len -- no ripple, no
    -- dependency on any other output bit -- used below (with shift_left, a barrel shift, not an
    -- adder) to turn a contiguous [start, start+len) page range into a bitmask without ever
    -- computing "start + len" or a per-bit range compare against it.
    function ones_len_f (len : unsigned; width : natural) return unsigned is
        variable result_v : unsigned(width-1 downto 0);
    begin
        for i in 0 to width-1 loop
            result_v(i) := tsel(to_unsigned(i, len'length) < len, '1', '0');
        end loop;
        return result_v;
    end function;

    constant RESERVED_MASK : std_logic_vector(PAGES-1 downto 0) := reserved_mask_f(PAGES, RESERVED_PAGES);

    signal occupancy    : std_logic_vector(PAGES-1 downto 0);
    -- active_mask(i) = '1' iff i < ALLOC_REQ_NPAGES, i.e. the low ALLOC_REQ_NPAGES bits are set.
    -- Only MAX_ALLOC_PAGES bits wide (not PAGES): a single request is never larger than that, so
    -- bits beyond it would always be '0'.
    signal active_mask  : std_logic_vector(MAX_ALLOC_PAGES-1 downto 0);
    -- fits(k) = '1' iff a run of ALLOC_REQ_NPAGES free pages starts at page k (stage 1 combinational
    -- result) and fits_q its registered (stage 1 output / stage 2 input) counterpart.
    signal fits         : std_logic_vector(PAGES-1 downto 0);
    signal fits_q       : std_logic_vector(PAGES-1 downto 0);

    -- Stage 2: hierarchical (NUM_GROUPS x GROUP_SIZE) priority encoder over fits_q.
    signal group_or      : std_logic_vector(NUM_GROUPS-1 downto 0);
    signal group_result  : std_logic_vector(GROUP_IDX_W downto 0);
    signal group_sel     : unsigned(GROUP_IDX_W-1 downto 0);
    signal group_vld     : std_logic;
    signal grp_bits      : std_logic_vector(GROUP_SIZE-1 downto 0);
    signal offset_result : std_logic_vector(GROUP_SIZE_W downto 0);
    signal offset_sel    : unsigned(GROUP_SIZE_W-1 downto 0);

    -- ALLOC_DONE stability counter (see done_cnt_p) and the previous-cycle ALLOC_REQ_NPAGES it's
    -- compared against to detect a new request.
    signal done_cnt      : unsigned(DONE_CNT_W-1 downto 0);
    signal npages_prev   : std_logic_vector(ALLOC_REQ_NPAGES'range);

    -- Registered ("_q") copies of the occupancy-mutation control inputs, fed to
    -- occupancy_update_p/done_cnt_p instead of the live FREE_*/ALLOC_* signals -- a structural cut
    -- so occupancy_reg's D input starts from a register instead of directly from the caller's
    -- (deep, e.g. op_ctrl's FSM) combinational logic. This adds exactly one cycle of latency to
    -- when a FREE/committed-ALLOC actually mutates occupancy; done_cnt_p is adjusted (below) to
    -- key off these same "_q" events, so ALLOC_DONE still only asserts once the (now
    -- correspondingly later) occupancy mutation has propagated through fits/fits_q/the encoder.
    -- commit_page_q/commit_npages_q snapshot ALLOC_PAGE/ALLOC_REQ_NPAGES on the very same edge as
    -- commit_q, so the delayed update still reserves exactly the page/size the caller saw granted
    -- (both are already the settled, ALLOC_DONE-gated pipelined values at the moment of commit).
    signal free_vld_q      : std_logic;
    signal free_page_q     : std_logic_vector(FREE_PAGE'range);
    signal free_npages_q   : std_logic_vector(FREE_NPAGES'range);
    signal commit_q        : std_logic;
    signal commit_page_q   : std_logic_vector(ALLOC_PAGE'range);
    signal commit_npages_q : std_logic_vector(ALLOC_REQ_NPAGES'range);

begin

    assert (RESERVED_PAGES < PAGES)
        report "IUVENTUS_PAGE_ALLOCATOR: RESERVED_PAGES must leave at least one allocatable page"
        severity FAILURE;

    assert (MAX_ALLOC_PAGES <= PAGES)
        report "IUVENTUS_PAGE_ALLOCATOR: MAX_ALLOC_PAGES cannot exceed PAGES"
        severity FAILURE;

    assert (PAGES mod GROUP_SIZE = 0)
        report "IUVENTUS_PAGE_ALLOCATOR: PAGES must be a multiple of the encoder's GROUP_SIZE (8)"
        severity FAILURE;

    -- =============================================================================================
    -- Window active-mask: bit i is '1' iff a run starting at page 0 of ALLOC_REQ_NPAGES pages
    -- would cover page i. Independent of k (only computed once) and each bit is an independent,
    -- order-independent unsigned compare -- no serial dependency across i. Only MAX_ALLOC_PAGES
    -- bits wide, per the MAX_ALLOC_PAGES generic above.
    -- =============================================================================================
    alloc_active_comb_p : process (all) is
        variable npages_v : unsigned(CNT_W-1 downto 0);
        variable active_v : std_logic_vector(MAX_ALLOC_PAGES-1 downto 0);
    begin
        npages_v := unsigned(ALLOC_REQ_NPAGES);

        for i in 0 to MAX_ALLOC_PAGES-1 loop
            active_v(i) := tsel(to_unsigned(i, CNT_W) < npages_v, '1', '0');
        end loop;

        active_mask <= active_v;
    end process;

    -- =============================================================================================
    -- Stage 1 (combinational): parallel feasibility check, registered into fits_q below.
    --
    -- fits(k) = '1' iff a run of ALLOC_REQ_NPAGES free pages starts at page k. For every k,
    -- active_mask (only MAX_ALLOC_PAGES bits wide) is re-aligned to start at k into a PAGES-wide
    -- window_v that is '0' everywhere outside [k, k+MAX_ALLOC_PAGES) -- so at most MAX_ALLOC_PAGES
    -- of window_v's bits can ever be '1' for a given k, letting synthesis constant-fold the
    -- occupancy AND/"=0" compare down to that width instead of all PAGES bits. Both the AND and
    -- the "=0" compare are flattened, order-independent reductions (no per-bit serial ripple, no
    -- arithmetic), so every k is a small, independent, shallow comparator, and all PAGES of them
    -- evaluate in parallel.
    -- =============================================================================================
    alloc_fits_comb_p : process (all) is
        variable npages_v : unsigned(CNT_W-1 downto 0);
        variable fits_v   : std_logic_vector(PAGES-1 downto 0);
        variable window_v : std_logic_vector(PAGES-1 downto 0);
    begin
        npages_v := unsigned(ALLOC_REQ_NPAGES);

        for k in 0 to PAGES-1 loop
            if (npages_v /= 0 and (k + to_integer(npages_v) <= PAGES)) then
                -- Re-align active_mask (MAX_ALLOC_PAGES bits) to start at k. Both branches'
                -- slice bounds depend only on the loop-constant k and the generics PAGES/
                -- MAX_ALLOC_PAGES (never on a runtime-computed variable), matching the
                -- elaboration-time-constant slicing style used throughout this process: the
                -- "far from the buffer's end" case copies the whole MAX_ALLOC_PAGES window, the
                -- "near the end" case clips it to what's left of the buffer (that clipped tail of
                -- window_v, if any, is never read below anyway -- npages_v <= PAGES-k is already
                -- enforced above, i.e. the request never overruns it).
                window_v := (others => '0');

                if (PAGES - k >= MAX_ALLOC_PAGES) then
                    window_v(k+MAX_ALLOC_PAGES-1 downto k) := active_mask;
                else
                    window_v(PAGES-1 downto k) := active_mask(PAGES-1-k downto 0);
                end if;

                fits_v(k) := tsel(unsigned(occupancy and window_v) = 0, '1', '0');
            else
                fits_v(k) := '0';
            end if;
        end loop;

        fits <= fits_v;
    end process;

    -- =============================================================================================
    -- Pipeline register between stage 1 (fits reduction) and stage 2 (priority encode). This is
    -- the register that actually splits the critical path -- registering only ALLOC_GRANT/
    -- ALLOC_PAGE (stage 2's own output register, below) without this one would leave the whole
    -- fits-reduction-then-encode path combinational and just as deep as before.
    -- =============================================================================================
    fits_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                fits_q <= (others => '0');
            else
                fits_q <= fits;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Stage 2 (combinational): hierarchical NUM_GROUPS x GROUP_SIZE priority encoder over fits_q,
    -- registered into ALLOC_GRANT/ALLOC_PAGE below. Selects the lowest-address feasible run,
    -- functionally identical to a flat "first k with fits_q(k)='1', else no grant" encoder, but
    -- built from two small (<=16-wide) priority selects instead of one 128-wide one:
    --   1. group_or(g) = OR of fits_q's 8 bits in group g -- which groups have >=1 feasible k.
    --   2. group_result/group_sel/group_vld = lowest-index group with group_or(g)='1'.
    --   3. grp_bits = that group's 8 fits_q bits (a NUM_GROUPS-way mux, not a shift/add).
    --   4. offset_result/offset_sel = lowest-index set bit within grp_bits.
    -- ALLOC_PAGE = group_sel & offset_sel is a plain concatenation (GROUP_SIZE=8 is a power of 2
    -- aligned to the group boundary), not an add -- no arithmetic anywhere in this stage either.
    -- =============================================================================================
    group_or_g : for g in 0 to NUM_GROUPS-1 generate
        group_or(g) <= or fits_q(g*GROUP_SIZE + GROUP_SIZE-1 downto g*GROUP_SIZE);
    end generate;

    group_result <= priority_encode_f(group_or, GROUP_IDX_W);
    group_vld    <= group_result(GROUP_IDX_W);
    group_sel    <= unsigned(group_result(GROUP_IDX_W-1 downto 0));

    grp_bits_comb_p : process (all) is
        variable grp_bits_v : std_logic_vector(GROUP_SIZE-1 downto 0);
    begin
        grp_bits_v := (others => '0');

        for g in 0 to NUM_GROUPS-1 loop
            if (g = to_integer(group_sel)) then
                grp_bits_v := fits_q(g*GROUP_SIZE + GROUP_SIZE-1 downto g*GROUP_SIZE);
            end if;
        end loop;

        grp_bits <= grp_bits_v;
    end process;

    offset_result <= priority_encode_f(grp_bits, GROUP_SIZE_W);
    offset_sel    <= unsigned(offset_result(GROUP_SIZE_W-1 downto 0));

    -- =============================================================================================
    -- Stage 2 output register: the final, pipelined ALLOC_GRANT/ALLOC_PAGE. Reading them back
    -- below (occupancy_update_p, alloc_grant_check_p, done_cnt_p) is legal: VHDL-2008 (this
    -- project's std) allows an "out" port to be read from within its own entity.
    -- =============================================================================================
    alloc_out_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                ALLOC_GRANT <= '0';
                ALLOC_PAGE  <= (others => '0');
            else
                ALLOC_GRANT <= group_vld;
                ALLOC_PAGE  <= std_logic_vector(group_sel) & std_logic_vector(offset_sel);
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Occupancy-mutation control input register: a structural cut between the (potentially deep,
    -- e.g. op_ctrl's FSM) combinational logic driving FREE_*/ALLOC_* and occupancy_reg's D input.
    -- occupancy_update_p and done_cnt_p key off these registered "_q" signals instead of the live
    -- ports (see their own comments) -- this adds exactly one cycle of latency between a FREE/
    -- committed-ALLOC and its effect on occupancy, but keeps both halves of that path
    -- (caller-logic -> this register, and this register -> barrel-shift-mask -> occupancy_reg)
    -- much shallower than the previously-fused single-cycle path.
    -- =============================================================================================
    occ_ctrl_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                free_vld_q      <= '0';
                free_page_q     <= (others => '0');
                free_npages_q   <= (others => '0');
                commit_q        <= '0';
                commit_page_q   <= (others => '0');
                commit_npages_q <= (others => '0');
            else
                free_vld_q      <= FREE_VLD;
                free_page_q     <= FREE_PAGE;
                free_npages_q   <= FREE_NPAGES;
                -- Snapshot ALLOC_PAGE/ALLOC_REQ_NPAGES on the same edge as the commit flag: both
                -- are already the settled, ALLOC_DONE-gated pipelined values at the moment
                -- ALLOC_REQ_VLD/ALLOC_GRANT commit (op_ctrl only asserts ALLOC_REQ_VLD once
                -- ALLOC_DONE='1'), so this is exactly the page/size the caller saw granted.
                commit_q        <= ALLOC_REQ_VLD and ALLOC_GRANT;
                commit_page_q   <= ALLOC_PAGE;
                commit_npages_q <= ALLOC_REQ_NPAGES;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- ALLOC_DONE stability counter: '1' iff ALLOC_GRANT/ALLOC_PAGE correspond to the request
    -- currently held on ALLOC_REQ_NPAGES and to the current occupancy, i.e. the L-deep pipeline
    -- has settled since the last change of either. Resets to 0 on RST, on any change of
    -- ALLOC_REQ_NPAGES, and on any occupancy change -- a committed ALLOC or a FREE, keyed off the
    -- registered commit_q/free_vld_q (occ_ctrl_reg_p above), i.e. the cycle occupancy_update_p
    -- actually mutates occupancy, not the (one cycle earlier) live ALLOC_REQ_VLD/ALLOC_GRANT/
    -- FREE_VLD -- otherwise saturates at L. Resetting on every free_vld_q is conservative-safe (a
    -- free only adds free pages, never invalidates an already-valid positive grant) but keeps
    -- correctness independent of the exact value of L -- callers only ever need to know DONE
    -- eventually reasserts.
    -- =============================================================================================
    done_cnt_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                done_cnt    <= (others => '0');
                npages_prev <= (others => '0');
            else
                npages_prev <= ALLOC_REQ_NPAGES;

                if ((ALLOC_REQ_NPAGES /= npages_prev)
                    or (commit_q = '1')
                    or (free_vld_q = '1')) then
                    done_cnt <= (others => '0');
                elsif (done_cnt < L) then
                    done_cnt <= done_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ALLOC_DONE <= '1' when done_cnt >= L else '0';

    -- =============================================================================================
    -- Synchronous occupancy update
    --
    -- Keys off the registered free_vld_q/free_page_q/free_npages_q and commit_q/commit_page_q/
    -- commit_npages_q (occ_ctrl_reg_p above), not the live FREE_*/ALLOC_* ports -- occupancy_reg's
    -- D input is now driven from a register instead of directly from the caller's (potentially
    -- deep) combinational logic, one cycle later than before.
    --
    -- A contiguous page range [start, start+len) is exactly ones(len) << start: instead of the
    -- per-bit "i >= start and i < start+len" range compare (which needs a "start+len" adder and
    -- then two per-bit comparators against it -- a wide carry-chain-ripple tail), build a
    -- width-PAGES thermometer mask of len (ones_len_f, a parallel per-bit compare against a
    -- constant, no ripple) and barrel-shift it by start (shift_left with a variable COUNT infers
    -- a log2(PAGES)-deep mux tree, not an adder/carry chain). The update then becomes plain
    -- bitwise ops: free clears its mask, alloc (applied after free, so it wins any overlap) sets
    -- its mask, RESERVED_MASK is always re-OR'd in. Semantics are bit-identical to the old
    -- per-bit range compare -- this is a pure logic restructuring for depth, not a behavior change.
    -- =============================================================================================
    occupancy_update_p : process (CLK) is
        variable occupancy_next_v   : std_logic_vector(PAGES-1 downto 0);
        variable free_ones_v        : unsigned(PAGES-1 downto 0);
        variable free_block_mask_v  : std_logic_vector(PAGES-1 downto 0);
        variable alloc_ones_v       : unsigned(PAGES-1 downto 0);
        variable alloc_block_mask_v : std_logic_vector(PAGES-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                occupancy <= RESERVED_MASK;
            else
                occupancy_next_v := occupancy;

                if (free_vld_q = '1') then
                    free_ones_v       := ones_len_f(unsigned(free_npages_q), PAGES);
                    free_block_mask_v := std_logic_vector(shift_left(free_ones_v, to_integer(unsigned(free_page_q))));

                    occupancy_next_v := occupancy_next_v and not free_block_mask_v;
                end if;

                if (commit_q = '1') then
                    alloc_ones_v       := ones_len_f(unsigned(commit_npages_q), PAGES);
                    alloc_block_mask_v := std_logic_vector(shift_left(alloc_ones_v, to_integer(unsigned(commit_page_q))));

                    occupancy_next_v := occupancy_next_v or alloc_block_mask_v;
                end if;

                -- Re-assert the reserved pages regardless of the FREE/ALLOC activity above: they
                -- must never be granted (ALLOC_PAGE/fits already skip them via occupancy='1') and
                -- a stray FREE covering them (should never legitimately happen) must not clear them.
                occupancy <= occupancy_next_v or RESERVED_MASK;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Caller must always check ALLOC_GRANT before committing an allocation, and a single request
    -- must never exceed MAX_ALLOC_PAGES (see the generic's own comment: this is what keeps stage
    -- 1's per-k feasibility window shallow).
    -- =============================================================================================
    alloc_grant_check_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '0') then
                assert (not (ALLOC_REQ_VLD = '1' and ALLOC_GRANT = '0'))
                    report "IUVENTUS_PAGE_ALLOCATOR: Allocation request committed without a GRANT!"
                    severity FAILURE;

                assert (to_integer(unsigned(ALLOC_REQ_NPAGES)) <= MAX_ALLOC_PAGES)
                    report "IUVENTUS_PAGE_ALLOCATOR: ALLOC_REQ_NPAGES exceeds MAX_ALLOC_PAGES"
                    severity FAILURE;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Free-page count (debug/observability)
    -- =============================================================================================
    pages_free_comb_p : process (all) is
        variable used_cnt_v : natural range 0 to PAGES;
    begin
        used_cnt_v := 0;

        for i in 0 to PAGES-1 loop
            if (occupancy(i) = '1') then
                used_cnt_v := used_cnt_v + 1;
            end if;
        end loop;

        PAGES_FREE <= std_logic_vector(to_unsigned(PAGES - used_cnt_v, CNT_W));
    end process;

end architecture;
