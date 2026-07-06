-- iuventus_page_allocator.vhd: synchronous first-fit contiguous page allocator over a fixed
-- number of pages, used to hand out regions of a page-based FPGA-BAR buffer
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;

-- Note:

entity IUVENTUS_PAGE_ALLOCATOR is

    generic (
        PAGES : positive := 32
        );

    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- Allocation interface
        --
        -- ALLOC_GRANT/ALLOC_PAGE reflect the combinational feasibility (and location) of the
        -- requested run, regardless of ALLOC_REQ_VLD. The allocation is only committed into the
        -- occupancy state when ALLOC_REQ_VLD = '1' and ALLOC_GRANT = '1' on a rising CLK edge.
        -- =========================================================================================
        ALLOC_REQ_NPAGES : in  std_logic_vector(log2(PAGES) downto 0);
        ALLOC_REQ_VLD    : in  std_logic;
        ALLOC_GRANT      : out std_logic;
        ALLOC_PAGE       : out std_logic_vector(log2(PAGES)-1 downto 0);

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

    constant PAGE_IDX_W : natural := log2(PAGES);
    constant CNT_W       : natural := log2(PAGES) + 1;

    signal occupancy : std_logic_vector(PAGES-1 downto 0);
    signal fits      : std_logic_vector(PAGES-1 downto 0);

begin

    -- =============================================================================================
    -- Parallel feasibility check
    --
    -- fits(k) = '1' iff a run of ALLOC_REQ_NPAGES free pages starts at page k. Each fits(k) is
    -- computed independently of every other k (no cross-k serial dependency), so the tool is free
    -- to evaluate all PAGES window-AND-reductions in parallel.
    -- =============================================================================================
    alloc_fits_comb_p : process (all) is
        variable npages_v : unsigned(CNT_W-1 downto 0);
        variable fits_v   : std_logic_vector(PAGES-1 downto 0);
        variable run_ok_v : boolean;
    begin
        npages_v := unsigned(ALLOC_REQ_NPAGES);

        for k in 0 to PAGES-1 loop
            if (npages_v /= 0 and (k + to_integer(npages_v) <= PAGES)) then
                run_ok_v := true;

                for i in 0 to PAGES-1 loop
                    if (i >= k and i < k + to_integer(npages_v)) then
                        if (occupancy(i) = '1') then
                            run_ok_v := false;
                        end if;
                    end if;
                end loop;

                fits_v(k) := tsel(run_ok_v, '1', '0');
            else
                fits_v(k) := '0';
            end if;
        end loop;

        fits <= fits_v;
    end process;

    -- =============================================================================================
    -- Priority encoder: select the lowest-address feasible run
    -- =============================================================================================
    alloc_select_comb_p : process (all) is
        variable found_v : boolean;
        variable grant_v : std_logic;
        variable page_v  : unsigned(PAGE_IDX_W-1 downto 0);
    begin
        grant_v := '0';
        page_v  := (others => '0');
        found_v := false;

        for k in 0 to PAGES-1 loop
            if (not found_v and fits(k) = '1') then
                found_v := true;
                grant_v := '1';
                page_v  := to_unsigned(k, PAGE_IDX_W);
            end if;
        end loop;

        ALLOC_GRANT <= grant_v;
        ALLOC_PAGE  <= std_logic_vector(page_v);
    end process;

    -- =============================================================================================
    -- Synchronous occupancy update
    -- =============================================================================================
    occupancy_update_p : process (CLK) is
        variable occupancy_next_v : std_logic_vector(PAGES-1 downto 0);
        variable free_start_v     : integer;
        variable free_len_v       : integer;
        variable alloc_start_v    : integer;
        variable alloc_len_v      : integer;
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                occupancy <= (others => '0');
            else
                occupancy_next_v := occupancy;

                if (FREE_VLD = '1') then
                    free_start_v := to_integer(unsigned(FREE_PAGE));
                    free_len_v   := to_integer(unsigned(FREE_NPAGES));

                    for i in 0 to PAGES-1 loop
                        if (i >= free_start_v and i < free_start_v + free_len_v) then
                            occupancy_next_v(i) := '0';
                        end if;
                    end loop;
                end if;

                if (ALLOC_REQ_VLD = '1' and ALLOC_GRANT = '1') then
                    alloc_start_v := to_integer(unsigned(ALLOC_PAGE));
                    alloc_len_v   := to_integer(unsigned(ALLOC_REQ_NPAGES));

                    for i in 0 to PAGES-1 loop
                        if (i >= alloc_start_v and i < alloc_start_v + alloc_len_v) then
                            occupancy_next_v(i) := '1';
                        end if;
                    end loop;
                end if;

                occupancy <= occupancy_next_v;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Caller must always check ALLOC_GRANT before committing an allocation
    -- =============================================================================================
    alloc_grant_check_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '0') then
                assert (not (ALLOC_REQ_VLD = '1' and ALLOC_GRANT = '0'))
                    report "IUVENTUS_PAGE_ALLOCATOR: Allocation request committed without a GRANT!"
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
