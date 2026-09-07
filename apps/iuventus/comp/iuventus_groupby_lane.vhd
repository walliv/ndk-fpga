-- iuventus_groupby_lane.vhd: one direct-indexed aggregation bank with read-modify-write bypass
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- One bank of the group table, private to a lane: one record arrives per cycle and accumulates
-- into the slot its key selects, so nothing arbitrates here. Three modes share the read/write
-- port, kept disjoint by the engine: CLEAR, accumulate, SWEEP.
entity IUVENTUS_GROUPBY_LANE is
    generic (
        -- Slots in this bank. The whole table is LANES*SLOTS groups.
        SLOTS   : natural := 4096;
        -- 64 bits cannot overflow at any record count this design can read from an SSD.
        SUM_W   : natural := 64;
        -- Per-slot record count, so an untouched slot is distinguishable from one whose values
        -- happened to sum to zero.
        CNT_W   : natural := 32;
        VALUE_W : natural := 64;
        DEVICE  : string  := "ULTRASCALE"
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- ==============================
        -- Record input. No back-pressure: the lane consumes on every cycle IN_VLD is high, which is
        -- what lets the crossbar upstream reason about capacity with FIFO occupancy alone.
        -- ==============================
        IN_SLOT  : in std_logic_vector(log2(SLOTS)-1 downto 0);
        IN_VALUE : in std_logic_vector(VALUE_W-1 downto 0);
        IN_VLD   : in std_logic;

        -- ==============================
        -- Table clear. Drive one address per cycle with CLEAR_EN high before a run.
        -- ==============================
        CLEAR_ADDR : in std_logic_vector(log2(SLOTS)-1 downto 0);
        CLEAR_EN   : in std_logic;

        -- ==============================
        -- Result sweep, valid once DRAINED. SWEEP_SUM/CNT follow SWEEP_ADDR by RD_LAT cycles, and
        -- SWEEP_VLD is delayed by the same amount rather than re-derived downstream.
        -- ==============================
        SWEEP_ADDR : in  std_logic_vector(log2(SLOTS)-1 downto 0);
        SWEEP_EN   : in  std_logic;
        SWEEP_SUM  : out std_logic_vector(SUM_W-1 downto 0);
        SWEEP_CNT  : out std_logic_vector(CNT_W-1 downto 0);
        SWEEP_VLD  : out std_logic;

        -- '1' when no accumulate is in flight, so a sweep may start without racing a write-back.
        DRAINED : out std_logic
    );
end entity;

architecture FULL of IUVENTUS_GROUPBY_LANE is

    constant ADDR_W : natural := log2(SLOTS);
    constant REC_W  : natural := SUM_W + CNT_W;

    -- Read latency of the backing memory with OUTPUT_REG off. The bypass depth and the sweep-valid
    -- delay are both derived from this, so adding a stage is a one-constant edit.
    constant RD_LAT : natural := 1;

    signal wr_en   : std_logic;
    signal wr_addr : std_logic_vector(ADDR_W-1 downto 0);
    signal wr_data : std_logic_vector(REC_W-1 downto 0);
    signal rd_addr : std_logic_vector(ADDR_W-1 downto 0);
    signal rd_data : std_logic_vector(REC_W-1 downto 0);
    signal rd_en   : std_logic;

    -- Stage 1: the record whose memory read is landing this cycle.
    signal s1_vld   : std_logic;
    signal s1_slot  : std_logic_vector(ADDR_W-1 downto 0);
    signal s1_value : std_logic_vector(VALUE_W-1 downto 0);

    -- Stage 2: what stage 1 just wrote. Held so a following record on the same slot reads the
    -- updated value rather than the copy still sitting in the memory.
    signal s2_vld  : std_logic;
    signal s2_slot : std_logic_vector(ADDR_W-1 downto 0);
    signal s2_data : std_logic_vector(REC_W-1 downto 0);

    signal cur_sum  : unsigned(SUM_W-1 downto 0);
    signal cur_cnt  : unsigned(CNT_W-1 downto 0);
    signal acc_data : std_logic_vector(REC_W-1 downto 0);

    signal sweep_vld_r : std_logic_vector(RD_LAT-1 downto 0);

begin

    assert (SLOTS = 2**ADDR_W)
        report "IUVENTUS_GROUPBY_LANE: SLOTS must be a power of two."
        severity FAILURE;

    -- psl default clock is rising_edge(CLK);
    -- The engine must keep the three modes disjoint; if it did not, a clear would race an
    -- accumulate write and the table would hold a partially cleared mixture.
    -- psl assert_modes_disjoint : assert always
    --     (RST = '0' -> not (IN_VLD = '1' and (CLEAR_EN = '1' or SWEEP_EN = '1')))
    --     report "IUVENTUS_GROUPBY_LANE: record input overlapped a clear or a sweep!";

    rd_addr <= SWEEP_ADDR when (SWEEP_EN = '1') else IN_SLOT;
    rd_en   <= SWEEP_EN or IN_VLD;

    table_i : entity work.SDP_BRAM
    generic map (
        DATA_WIDTH     => REC_W,
        ITEMS          => SLOTS,
        BLOCK_ENABLE   => false,
        BLOCK_WIDTH    => 8,
        COMMON_CLOCK   => true,
        -- Off on purpose: an output register would lengthen the accumulate loop and demand a
        -- second bypass stage to match.
        OUTPUT_REG     => false,
        METADATA_WIDTH => 0,
        DEVICE         => DEVICE
    )
    port map (
        WR_CLK      => CLK,
        WR_RST      => RST,
        WR_EN       => wr_en,
        WR_BE       => (others => '1'),
        WR_ADDR     => wr_addr,
        WR_DATA     => wr_data,
        RD_CLK      => CLK,
        RD_RST      => RST,
        RD_EN       => rd_en,
        RD_PIPE_EN  => '1',
        RD_META_IN  => (others => '0'),
        RD_ADDR     => rd_addr,
        RD_DATA     => rd_data,
        RD_META_OUT => open,
        RD_DATA_VLD => open
    );

    stage1_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            s1_vld   <= IN_VLD;
            s1_slot  <= IN_SLOT;
            s1_value <= IN_VALUE;
            if (RST = '1') then
                s1_vld <= '0';
            end if;
        end if;
    end process;

    -- Without this a record one cycle behind another on the same slot would read the pre-update
    -- value, because its memory read was issued before the earlier record's write landed.
    bypass_p : process (all) is
        variable v_rec : std_logic_vector(REC_W-1 downto 0);
    begin
        if (s2_vld = '1' and s2_slot = s1_slot) then
            v_rec := s2_data;
        else
            v_rec := rd_data;
        end if;
        cur_sum <= unsigned(v_rec(SUM_W-1 downto 0));
        cur_cnt <= unsigned(v_rec(REC_W-1 downto SUM_W));
    end process;

    acc_data <= std_logic_vector(cur_cnt + 1) & std_logic_vector(cur_sum + unsigned(s1_value));

    stage2_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            s2_vld  <= s1_vld;
            s2_slot <= s1_slot;
            s2_data <= acc_data;
            if (RST = '1') then
                s2_vld <= '0';
            end if;
        end if;
    end process;

    wr_en   <= s1_vld or CLEAR_EN;
    wr_addr <= CLEAR_ADDR when (CLEAR_EN = '1') else s1_slot;
    wr_data <= (others => '0') when (CLEAR_EN = '1') else acc_data;

    DRAINED <= not (s1_vld or s2_vld);

    sweep_vld_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            sweep_vld_r <= sweep_vld_r(sweep_vld_r'high-1 downto 0) & SWEEP_EN;
            if (RST = '1') then
                sweep_vld_r <= (others => '0');
            end if;
        end if;
    end process;

    SWEEP_SUM <= rd_data(SUM_W-1 downto 0);
    SWEEP_CNT <= rd_data(REC_W-1 downto SUM_W);
    SWEEP_VLD <= sweep_vld_r(sweep_vld_r'high);

end architecture;
