-- iuventus_integrity_checker.vhd: FPGA-driven SSD write/read-back data-integrity self-test
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- Writes an address-derived pattern via WRITE, reads it back via READ, comparing in fabric. QD1
-- (RD_MFB carries no LBA tag). The pattern embeds the LBA in each 64-bit word, catching bit and
-- wrong-block errors; ERR_CNT/first mismatch latch for SW.
entity IUVENTUS_INTEGRITY_CHECKER is
    generic (
        -- User MFB geometry (REGIONS is fixed to 1). DATA width = REGION_SIZE*BLOCK_SIZE*ITEM_WIDTH.
        MFB_REGION_SIZE : natural := 8;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 8;
        -- NVMe logical block (sector) size in bytes.
        SECT_SIZE       : natural := 512;
        -- Width of the LBA pointer (byte address of the sector on the namespace).
        LBA_PTR_W       : natural := 64
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- ---- Control (single-cycle START pulse; BASE/COUNT sampled at START) ----------------
        CTL_START     : in  std_logic;
        CTL_LBA_BASE  : in  std_logic_vector(LBA_PTR_W -1 downto 0);  -- byte address of first sector
        CTL_LBA_COUNT : in  std_logic_vector(31 downto 0);            -- number of sectors to test

        -- ---- Status --------------------------------------------------------------------------
        STS_BUSY          : out std_logic;
        STS_DONE          : out std_logic;
        STS_ERR_CNT       : out std_logic_vector(31 downto 0);
        STS_ERR_FIRST_LBA : out std_logic_vector(LBA_PTR_W -1 downto 0);
        STS_ERR_FIRST_EXP : out std_logic_vector(31 downto 0);
        STS_ERR_FIRST_GOT : out std_logic_vector(31 downto 0);

        -- ---- Debug (localise a hang: FSM state / write-stream progress / completion pulses) ----
        STS_STATE      : out std_logic_vector(2 downto 0);   -- state_t'pos: IDLE=0 WR=1 WR_WAIT=2 RD_REQ=3 RD_DATA=4 DONE=5
        STS_BEAT_IDX   : out std_logic_vector(7 downto 0);   -- current write/read beat within the sector
        STS_OPSTAT_CNT : out std_logic_vector(7 downto 0);   -- saturating count of OP_STAT_VLD (write/read CQE) pulses seen
        STS_OP_ERR     : out std_logic;                      -- '1' if the sweep aborted on a non-success completion (OOR/failure)

        -- ---- DMA-Iuventus WRITE data path (host -> SSD) --------------------------------------
        WR_MFB_DATA    : out std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH -1 downto 0);
        WR_MFB_META    : out std_logic_vector(LBA_PTR_W -1 downto 0);
        WR_MFB_SOF     : out std_logic_vector(0 downto 0);
        WR_MFB_EOF     : out std_logic_vector(0 downto 0);
        WR_MFB_SOF_POS : out std_logic_vector(max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        WR_MFB_EOF_POS : out std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE) -1 downto 0);
        WR_MFB_SRC_RDY : out std_logic;
        WR_MFB_DST_RDY : in  std_logic;

        -- ---- DMA-Iuventus READ request (host -> SSD) ----------------------------------------
        RD_REQ_LBA_PTR : out std_logic_vector(LBA_PTR_W -1 downto 0);
        RD_REQ_LBA_NUM : out std_logic_vector(7 downto 0);
        RD_REQ_VLD     : out std_logic;
        RD_REQ_RDY     : in  std_logic;

        -- ---- Operation completion (one pulse per finished NVMe command) ----------------------
        OP_STAT_VLD    : in  std_logic;
        -- DMA completion code: "00"=SUCCESS, "01"=failure, "10"=LBA out of range. Any non-"00"
        -- aborts the sweep (-> S_DONE, STS_OP_ERR set), so a failed command can never wedge the FSM
        -- waiting on a CQE/data that will never drain.
        OP_STAT_CODE   : in  std_logic_vector(1 downto 0);

        -- ---- DMA-Iuventus READ data path (SSD -> host) --------------------------------------
        RD_MFB_DATA    : in  std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH -1 downto 0);
        RD_MFB_SOF     : in  std_logic_vector(0 downto 0);
        RD_MFB_EOF     : in  std_logic_vector(0 downto 0);
        RD_MFB_SRC_RDY : in  std_logic;
        RD_MFB_DST_RDY : out std_logic
    );
end entity;

architecture FULL of IUVENTUS_INTEGRITY_CHECKER is

    constant DATA_W     : natural := MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;  -- bits per beat
    constant BEAT_BYTES : natural := DATA_W/8;
    constant SECT_BEATS : natural := SECT_SIZE/BEAT_BYTES;                           -- beats per sector (512/64 = 8)
    constant WORDS_BEAT : natural := DATA_W/64;                                      -- 64-bit words per beat
    constant BEAT_IDX_W : natural := max(1, log2(SECT_BEATS));

    -- Address-derived reference pattern per 512-bit beat: 64-bit word j carries the LBA (address >> 9)
    -- in its high half and the sector-global word index in its low half, catching bit flips and wrong-block reads.
    function ref_beat (lba : unsigned; beat : unsigned) return std_logic_vector is
        variable res     : std_logic_vector(DATA_W -1 downto 0) := (others => '0');
        variable widx    : unsigned(31 downto 0);
        variable lba_tag : unsigned(31 downto 0);
    begin
        lba_tag := resize(lba(lba'high downto 9), 32);          -- sector number (address / 512)
        for j in 0 to WORDS_BEAT -1 loop
            widx                         := resize(beat*WORDS_BEAT + j, 32);
            res((j+1)*64 -1 downto j*64) := std_logic_vector(lba_tag) & std_logic_vector(widx);
        end loop;
        return res;
    end function;

    -- S_RD_END is appended, not inserted, so STS_STATE keeps the encoding software already
    -- decodes. It is the pipeline stage on the sector advance: see the read-back branch.
    type   state_t is (S_IDLE, S_WR, S_WR_WAIT, S_RD_REQ, S_RD_DATA, S_DONE, S_RD_END);
    signal state : state_t := S_IDLE;

    -- Sweep addressing is 48 bits, not the port's 64: 2**48 B is 281 TB against 4 TB drives, and
    -- 48 is a DSP48E2 P register's width, so the accumulator fits in one. Ports stay LBA_PTR_W
    -- wide -- only the counter narrows.
    constant LBA_ACC_W : natural := 48;

    -- One accumulator per sweep, loaded at arm and only ever incremented. A single counter would
    -- need a mid-sweep rewind -- a second next-value the DSP's P register can't express. Selecting
    -- on the output keeps each counter a plain load-then-accumulate.
    signal wr_lba  : unsigned(LBA_ACC_W -1 downto 0);
    signal rd_lba  : unsigned(LBA_ACC_W -1 downto 0);
    -- The active sweep's position, read by the datapath and by last_lba.
    signal cur_lba : unsigned(LBA_ACC_W -1 downto 0);

    attribute use_dsp : string;
    attribute use_dsp of wr_lba : signal is "yes";
    attribute use_dsp of rd_lba : signal is "yes";
    -- Last sector of the sweep, precomputed at CTL_START. Keeps an adder out of last_lba: see
    -- its assignment below.
    signal last_lba_tgt : unsigned(LBA_ACC_W -1 downto 0);
    signal beat_idx     : unsigned(BEAT_IDX_W -1 downto 0);

    signal err_cnt   : unsigned(31 downto 0);
    signal err_first : std_logic;
    signal err_lba   : std_logic_vector(LBA_PTR_W -1 downto 0);
    signal err_exp   : std_logic_vector(31 downto 0);
    signal err_got   : std_logic_vector(31 downto 0);

    signal last_lba : std_logic;   -- cur_lba is the final sector of the sweep

    signal opstat_cnt : unsigned(7 downto 0);   -- debug: saturating count of OP_STAT_VLD pulses
    signal op_err     : std_logic;              -- sweep aborted on a non-success completion (OOR/failure)

    constant OP_STAT_SUCCESS : std_logic_vector(1 downto 0) := "00";

begin

    cur_lba <= rd_lba when (state = S_RD_REQ or state = S_RD_DATA or state = S_RD_END) else wr_lba;

    -- Comparing against the precomputed final sector, rather than testing cur_lba + SECT against
    -- the end, keeps an adder off this path: an equality compare is an XOR/AND reduction.
    last_lba <= '1' when (cur_lba = last_lba_tgt) else '0';

    -- ---- Datapath outputs (combinational on state) -------------------------------------------
    WR_MFB_DATA    <= ref_beat(cur_lba, resize(beat_idx, cur_lba'length));
    WR_MFB_META    <= std_logic_vector(resize(cur_lba, LBA_PTR_W));
    WR_MFB_SOF     <= "1" when (state = S_WR and beat_idx = 0) else "0";
    WR_MFB_EOF     <= "1" when (state = S_WR and beat_idx = SECT_BEATS -1) else "0";
    WR_MFB_SOF_POS <= (others => '0');
    WR_MFB_EOF_POS <= (others => '1');   -- frame always ends on the last item of the beat
    WR_MFB_SRC_RDY <= '1' when (state = S_WR) else '0';

    RD_REQ_LBA_PTR <= std_logic_vector(resize(cur_lba, LBA_PTR_W));
    RD_REQ_LBA_NUM <= (others => '0');   -- one sector per request
    RD_REQ_VLD     <= '1' when (state = S_RD_REQ) else '0';

    RD_MFB_DST_RDY <= '1' when (state = S_RD_DATA) else '0';

    STS_BUSY          <= '0' when (state = S_IDLE or state = S_DONE) else '1';
    STS_DONE          <= '1' when (state = S_DONE) else '0';
    STS_ERR_CNT       <= std_logic_vector(err_cnt);
    STS_ERR_FIRST_LBA <= err_lba;
    STS_ERR_FIRST_EXP <= err_exp;
    STS_ERR_FIRST_GOT <= err_got;

    STS_STATE      <= std_logic_vector(to_unsigned(state_t'pos(state), 3));
    STS_BEAT_IDX   <= std_logic_vector(resize(beat_idx, 8));
    STS_OPSTAT_CNT <= std_logic_vector(opstat_cnt);
    STS_OP_ERR     <= op_err;

    fsm_p : process (CLK)
        variable exp_beat : std_logic_vector(DATA_W -1 downto 0);
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                state      <= S_IDLE;
                err_cnt    <= (others => '0');
                err_first  <= '0';
                err_lba    <= (others => '0');
                err_exp    <= (others => '0');
                err_got    <= (others => '0');
                opstat_cnt <= (others => '0');
                op_err     <= '0';
            else
                -- Debug: count every completion pulse (write/read CQE) regardless of FSM state, so
                -- a hang in S_WR_WAIT with opstat_cnt=0 proves the write CQE never arrived.
                if (OP_STAT_VLD = '1' and opstat_cnt /= X"FF") then
                    opstat_cnt <= opstat_cnt + 1;
                end if;

                case state is

                    when S_IDLE =>
                        if (CTL_START = '1') then
                            wr_lba       <= resize(unsigned(CTL_LBA_BASE), LBA_ACC_W);
                            rd_lba       <= resize(unsigned(CTL_LBA_BASE), LBA_ACC_W);
                            -- Same value less one sector. Config-time path with huge slack, unlike
                            -- last_lba's. CTL_LBA_COUNT=0 underflows here, but a zero-length sweep
                            -- is degenerate either way.
                            last_lba_tgt <= resize(unsigned(CTL_LBA_BASE), LBA_ACC_W)
                                            + resize(unsigned(CTL_LBA_COUNT) * to_unsigned(SECT_SIZE, 32), LBA_ACC_W)
                                            - to_unsigned(SECT_SIZE, LBA_ACC_W);
                            beat_idx     <= (others => '0');
                            err_cnt      <= (others => '0');
                            err_first    <= '0';
                            op_err       <= '0';
                            -- A zero-length request completes immediately.
                            if (unsigned(CTL_LBA_COUNT) = 0) then
                                state <= S_DONE;
                            else
                                state <= S_WR;
                            end if;
                        end if;

                    -- Stream one sector of reference data on the write MFB.
                    when S_WR =>
                        if (WR_MFB_DST_RDY = '1') then
                            if (beat_idx = SECT_BEATS -1) then
                                beat_idx <= (others => '0');
                                state    <= S_WR_WAIT;
                            else
                                beat_idx <= beat_idx + 1;
                            end if;
                        end if;

                    -- QD1: wait for the write command to complete before issuing the next.
                    when S_WR_WAIT =>
                        if (OP_STAT_VLD = '1') then
                            if (OP_STAT_CODE /= OP_STAT_SUCCESS) then
                                -- OOR / device error: the write never committed -- abort the sweep
                                -- (do NOT proceed to read back data that was never written).
                                op_err <= '1';
                                state  <= S_DONE;
                            elsif (last_lba = '1') then
                                -- No rewind: rd_lba has held base since the arm.
                                state <= S_RD_REQ;
                            else
                                wr_lba <= wr_lba + to_unsigned(SECT_SIZE, LBA_ACC_W);
                                state  <= S_WR;
                            end if;
                        end if;

                    when S_RD_REQ =>
                        if (RD_REQ_RDY = '1') then
                            beat_idx <= (others => '0');
                            state    <= S_RD_DATA;
                        end if;

                    -- Consume the returned sector and compare beat-by-beat against the pattern.
                    when S_RD_DATA =>
                        if (RD_MFB_SRC_RDY = '1') then
                            exp_beat := ref_beat(cur_lba, resize(beat_idx, cur_lba'length));
                            if (RD_MFB_DATA /= exp_beat) then
                                err_cnt <= err_cnt + 1;
                                if (err_first = '0') then
                                    err_first <= '1';
                                    err_lba   <= std_logic_vector(resize(cur_lba, LBA_PTR_W));
                                    err_exp   <= exp_beat(31 downto 0);
                                    err_got   <= RD_MFB_DATA(31 downto 0);
                                end if;
                            end if;

                            if (RD_MFB_EOF = "1") then
                                -- Advance in S_RD_END, not here. RD_MFB_EOF comes off the DMA's
                                -- frame-length accumulator, and driving the counter enable from it
                                -- directly puts that carry chain in this block's clock-enable cone.
                                state <= S_RD_END;
                            else
                                beat_idx <= beat_idx + 1;
                            end if;
                        elsif (OP_STAT_VLD = '1' and OP_STAT_CODE /= OP_STAT_SUCCESS) then
                            -- OOR / device error read: the DMA completes it without moving data, so
                            -- RD_MFB will NEVER arrive -- abort instead of hanging in S_RD_DATA (a
                            -- successful read's OP_STAT carries "00" and is ignored here; its data
                            -- is consumed by the branch above).
                            op_err <= '1';
                            state  <= S_DONE;
                        end if;

                    -- One bubble between sectors, which costs nothing: DST_RDY is low here and the
                    -- next request is not issued until S_RD_REQ anyway.
                    when S_RD_END =>
                        if (last_lba = '1') then
                            state <= S_DONE;
                        else
                            rd_lba <= rd_lba + to_unsigned(SECT_SIZE, LBA_ACC_W);
                            state  <= S_RD_REQ;
                        end if;

                    when S_DONE =>
                        if (CTL_START = '1') then
                            state <= S_IDLE;   -- allow re-arming; software sees DONE first
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;
