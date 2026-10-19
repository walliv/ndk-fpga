-- bar2axi_rd.vhd: Read engine of PCIE_BAR2AXI, fences MemRd behind earlier writes and issues AXI reads
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.bar2axi_pkg.all;

-- Keeps non-posted requests in order. A MemRd issues its AXI reads once all earlier writes got B
-- and its 128 B chunks are reserved in the buffer, so RREADY stays high. UR entries bypass AXI.
entity PCIE_BAR2AXI_RD is
    generic (
        DEVICE          : string  := "ULTRASCALE";
        AXI_DATA_WIDTH  : natural := 512;
        AXI_ADDR_WIDTH  : natural := 64;
        AXI_ID_WIDTH    : natural := 1;
        AXI_ID          : natural := 0;
        AXI_CACHE       : std_logic_vector(3 downto 0) := "0010";
        AXI_PROT        : std_logic_vector(2 downto 0) := "000";
        AXI_QOS         : std_logic_vector(3 downto 0) := "0000";
        -- Non-posted requests held at once, power of 2
        RD_OUTSTANDING  : natural := 8;
        -- Read data buffer size in bytes, power of 2
        RD_BUFFER_BYTES : natural := 16384;
        -- Width of the pending-write counters
        PEND_WIDTH      : natural := 6
    );
    port (
        CLK   : in  std_logic;
        RESET : in  std_logic;

        -- =========================================================================================
        -- Non-posted requests from the CQ intake
        -- =========================================================================================
        NP_PUSH     : in  std_logic;
        NP_DESC     : in  std_logic_vector(NPD_WIDTH-1 downto 0);
        -- Write TLPs accepted before this request and not yet answered by B
        NP_PEND     : in  std_logic_vector(PEND_WIDTH-1 downto 0);
        -- Value of the accepted-write counter at this request (assertion only)
        NP_FENCE    : in  std_logic_vector(32-1 downto 0);
        -- Pulse: the oldest outstanding write TLP got its last B response
        TLP_DONE    : in  std_logic;
        -- Running count of write TLPs answered by B (assertion only)
        WR_DONE_CNT : in  std_logic_vector(32-1 downto 0);

        -- =========================================================================================
        -- Requests released to the completion engine, in arrival order
        -- =========================================================================================
        CPL_DESC     : out std_logic_vector(NPD_WIDTH-1 downto 0);
        CPL_VLD      : out std_logic;
        CPL_POP      : in  std_logic;

        -- =========================================================================================
        -- Read buffer of 128 B chunks
        -- =========================================================================================
        -- Chunks completely filled with R data
        R_CHUNK_PTR  : out std_logic_vector(log2(RD_BUFFER_BYTES/CHUNK_BYTES) downto 0);
        -- Chunks released by the completion engine
        CC_CHUNK_PTR : in  std_logic_vector(log2(RD_BUFFER_BYTES/CHUNK_BYTES) downto 0);
        BUF_RD_ADDR  : in  std_logic_vector(log2(RD_BUFFER_BYTES/(AXI_DATA_WIDTH/8))-1 downto 0);
        BUF_RD_EN    : in  std_logic;
        BUF_RD_DATA  : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        BUF_RD_VLD   : out std_logic;

        -- R response other than OKAY
        ERR_INCR     : out std_logic;

        -- =========================================================================================
        -- AXI4 read channels
        -- =========================================================================================
        M_AXI_ARID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_ARADDR  : out std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        M_AXI_ARLEN   : out std_logic_vector(8-1 downto 0);
        M_AXI_ARSIZE  : out std_logic_vector(3-1 downto 0);
        M_AXI_ARBURST : out std_logic_vector(2-1 downto 0);
        M_AXI_ARLOCK  : out std_logic;
        M_AXI_ARCACHE : out std_logic_vector(4-1 downto 0);
        M_AXI_ARPROT  : out std_logic_vector(3-1 downto 0);
        M_AXI_ARQOS   : out std_logic_vector(4-1 downto 0);
        M_AXI_ARVALID : out std_logic;
        M_AXI_ARREADY : in  std_logic;

        M_AXI_RID     : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_RDATA   : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        M_AXI_RRESP   : in  std_logic_vector(2-1 downto 0);
        M_AXI_RLAST   : in  std_logic;
        M_AXI_RVALID  : in  std_logic;
        M_AXI_RREADY  : out std_logic
    );
end entity;

architecture FULL of PCIE_BAR2AXI_RD is

    constant WB         : natural := AXI_DATA_WIDTH/8;
    constant AXSIZE     : natural := log2(WB);
    -- AXI words per chunk
    constant WPC        : natural := CHUNK_BYTES/WB;
    constant WPCB       : natural := log2(WPC);
    constant NCH        : natural := RD_BUFFER_BYTES/CHUNK_BYTES;
    constant CPW        : natural := log2(NCH) + 1;
    constant BUF_WORDS  : natural := RD_BUFFER_BYTES/WB;
    constant BWW        : natural := log2(BUF_WORDS);
    constant PAGE_BEATS : natural := 4096/WB;
    constant BEAT_W     : natural := log2(PAGE_BEATS) + 1;
    -- words of the largest request: 33 chunks
    constant WORDS_W    : natural := NPD_NCH_W + WPCB;
    constant RQ_W       : natural := log2(RD_OUTSTANDING);
    constant RQ_DW      : natural := NPD_WIDTH + 32;

    type rq_mem_t is array (0 to RD_OUTSTANDING-1) of std_logic_vector(RQ_DW-1 downto 0);
    type rd_fsm_t is (RS_IDLE, RS_CALC, RS_AR);

    signal rq_mem        : rq_mem_t;
    signal rq_wptr       : unsigned(RQ_W-1 downto 0);
    signal rq_rptr       : unsigned(RQ_W-1 downto 0);
    signal rq_cnt        : unsigned(RQ_W downto 0);
    signal rq_pop        : std_logic;
    signal pend          : u_array_t(0 to RD_OUTSTANDING-1)(PEND_WIDTH-1 downto 0);

    signal head          : std_logic_vector(RQ_DW-1 downto 0);
    signal head_vld      : std_logic;
    signal head_pend     : unsigned(PEND_WIDTH-1 downto 0);
    signal head_ur       : std_logic;
    signal head_nch      : unsigned(NPD_NCH_W-1 downto 0);
    signal head_addr     : std_logic_vector(64-1 downto 0);
    signal head_fence    : std_logic_vector(32-1 downto 0);

    signal alloc_ptr     : unsigned(CPW-1 downto 0);
    signal buf_used      : unsigned(CPW-1 downto 0);
    signal can_alloc     : std_logic;

    signal rst           : rd_fsm_t;
    signal take_ur       : std_logic;
    signal take_rd       : std_logic;
    signal rd_go         : std_logic;
    signal cpl_full      : std_logic;
    signal cpl_empty     : std_logic;

    signal ar_addr       : unsigned(64-1 downto 0);
    signal ar_words_left : unsigned(WORDS_W-1 downto 0);
    signal ar_beats      : unsigned(BEAT_W-1 downto 0);
    signal ar_first      : std_logic;
    signal ar_fence      : unsigned(32-1 downto 0);
    signal page_left     : unsigned(BEAT_W-1 downto 0);
    signal burst_beats   : unsigned(BEAT_W-1 downto 0);
    signal arvalid_r     : std_logic;
    signal araddr_r      : unsigned(64-1 downto 0);
    signal arlen_r       : unsigned(8-1 downto 0);

    signal r_hs          : std_logic;
    signal r_word_cnt    : unsigned(BWW+1-1 downto 0);
    signal r_chunk_cnt   : unsigned(CPW-1 downto 0);

    signal ar_cross_4k   : std_logic;
    signal ar_fence_viol : std_logic;
    signal r_unalloc     : std_logic;

begin

    assert (RD_OUTSTANDING >= 2 and 2**RQ_W = RD_OUTSTANDING)
        report "PCIE_BAR2AXI_RD: RD_OUTSTANDING must be a power of 2 >= 2!"
        severity failure;
    assert (2**log2(NCH) = NCH and NCH >= 4096/CHUNK_BYTES + 1)
        report "PCIE_BAR2AXI_RD: RD_BUFFER_BYTES must be a power of 2 holding at least 33 chunks of 128 B!"
        severity failure;

    -- =============================================================================================
    -- Request ring with per-entry write fences
    -- =============================================================================================

    rq_wr_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (NP_PUSH = '1') then
                rq_mem(to_integer(rq_wptr)) <= NP_FENCE & NP_DESC;
            end if;
        end if;
    end process;

    rq_ptr_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (NP_PUSH = '1') then
                rq_wptr <= rq_wptr + 1;
            end if;
            if (rq_pop = '1') then
                rq_rptr <= rq_rptr + 1;
            end if;
            if (NP_PUSH = '1' and rq_pop = '0') then
                rq_cnt <= rq_cnt + 1;
            elsif (NP_PUSH = '0' and rq_pop = '1') then
                rq_cnt <= rq_cnt - 1;
            end if;
            if (RESET = '1') then
                rq_wptr <= (others => '0');
                rq_rptr <= (others => '0');
                rq_cnt  <= (others => '0');
            end if;
        end if;
    end process;

    -- B responses come back in write order, so every entry still waiting loses one pending write.
    pend_g : for i in 0 to RD_OUTSTANDING-1 generate
        pend_p : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (NP_PUSH = '1' and rq_wptr = i) then
                    pend(i) <= unsigned(NP_PEND);
                elsif (TLP_DONE = '1' and pend(i) /= 0) then
                    pend(i) <= pend(i) - 1;
                end if;
            end if;
        end process;
    end generate;

    head       <= rq_mem(to_integer(rq_rptr));
    head_vld   <= '1' when (rq_cnt /= 0) else '0';
    head_pend  <= pend(to_integer(rq_rptr));
    head_ur    <= head(NPD_UR_O);
    head_nch   <= unsigned(head(NPD_NCH));
    head_addr  <= head(NPD_ADDR);
    head_fence <= head(NPD_WIDTH+32-1 downto NPD_WIDTH);

    -- =============================================================================================
    -- Chunk allocation and AR issue
    -- =============================================================================================

    buf_used  <= alloc_ptr - unsigned(CC_CHUNK_PTR);
    can_alloc <= '1' when (resize(buf_used, CPW+1) + resize(head_nch, CPW+1) <= NCH) else '0';

    take_ur <= '1' when (rst = RS_IDLE and head_vld = '1' and head_ur = '1' and cpl_full = '0') else '0';
    -- fenced behind every earlier write and room reserved for all its chunks
    rd_go   <= '1' when (head_pend = 0 and can_alloc = '1') else '0';
    take_rd <= '1' when (rst = RS_IDLE and head_vld = '1' and head_ur = '0' and cpl_full = '0' and rd_go = '1') else '0';
    rq_pop  <= take_ur or take_rd;

    page_left   <= to_unsigned(PAGE_BEATS, BEAT_W) - resize(ar_addr(12-1 downto AXSIZE), BEAT_W);
    burst_beats <= resize(ar_words_left, BEAT_W) when (resize(ar_words_left, BEAT_W+WORDS_W) < page_left) else page_left;

    rd_fsm_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (M_AXI_ARREADY = '1') then
                arvalid_r <= '0';
            end if;

            case rst is
                when RS_IDLE =>
                    if (take_rd = '1') then
                        alloc_ptr     <= alloc_ptr + head_nch;
                        ar_addr       <= unsigned(head_addr(64-1 downto 7)) & to_unsigned(0, 7);
                        ar_words_left <= shift_left(resize(head_nch, WORDS_W), WPCB);
                        ar_first      <= '1';
                        ar_fence      <= unsigned(head_fence);
                        rst           <= RS_CALC;
                    end if;

                when RS_CALC =>
                    if (arvalid_r = '0') then
                        araddr_r  <= ar_addr;
                        arlen_r   <= resize(burst_beats - 1, 8);
                        arvalid_r <= '1';
                        ar_beats  <= burst_beats;
                        rst       <= RS_AR;
                    end if;

                when RS_AR =>
                    if (M_AXI_ARREADY = '1') then
                        ar_first      <= '0';
                        ar_addr       <= ar_addr + shift_left(resize(ar_beats, 64), AXSIZE);
                        ar_words_left <= ar_words_left - ar_beats;
                        if (resize(ar_words_left, BEAT_W+WORDS_W) = ar_beats) then
                            rst <= RS_IDLE;
                        else
                            rst <= RS_CALC;
                        end if;
                    end if;
            end case;

            if (RESET = '1') then
                rst       <= RS_IDLE;
                arvalid_r <= '0';
                alloc_ptr <= (others => '0');
                ar_first  <= '0';
            end if;
        end if;
    end process;

    cpl_fifo_i : entity work.FIFOX
    generic map (
        DATA_WIDTH          => NPD_WIDTH,
        ITEMS               => RD_OUTSTANDING,
        RAM_TYPE            => "LUT",
        DEVICE              => DEVICE,
        ALMOST_FULL_OFFSET  => 0,
        ALMOST_EMPTY_OFFSET => 0,
        FAKE_FIFO           => false
    )
    port map (
        CLK    => CLK,
        RESET  => RESET,

        DI     => head(NPD_WIDTH-1 downto 0),
        WR     => rq_pop,
        FULL   => cpl_full,
        AFULL  => open,
        STATUS => open,

        DO     => CPL_DESC,
        RD     => CPL_POP,
        EMPTY  => cpl_empty,
        AEMPTY => open
    );

    CPL_VLD <= not cpl_empty;

    -- =============================================================================================
    -- R data into the read buffer
    -- =============================================================================================

    r_hs <= M_AXI_RVALID;

    r_cnt_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            ERR_INCR <= '0';
            if (r_hs = '1') then
                r_word_cnt <= r_word_cnt + 1;
                ERR_INCR   <= '1' when (M_AXI_RRESP /= "00") else '0';
            end if;
            if (RESET = '1') then
                r_word_cnt <= (others => '0');
                ERR_INCR   <= '0';
            end if;
        end if;
    end process;

    -- requests always span whole chunks, so the completed-chunk count is the word count's top bits
    r_chunk_cnt <= r_word_cnt(BWW downto WPCB);
    R_CHUNK_PTR <= std_logic_vector(r_chunk_cnt);

    rd_buf_i : entity work.SDP_BRAM_BEHAV
    generic map (
        DATA_WIDTH => AXI_DATA_WIDTH,
        ITEMS      => BUF_WORDS,
        OUTPUT_REG => true
    )
    port map (
        WR_CLK      => CLK,
        WR_EN       => r_hs,
        WR_ADDR     => std_logic_vector(r_word_cnt(BWW-1 downto 0)),
        WR_DIN      => M_AXI_RDATA,

        RD_CLK      => CLK,
        RD_RST      => RESET,
        RD_CE       => '1',
        RD_REG_CE   => '1',
        RD_EN       => BUF_RD_EN,
        RD_ADDR     => BUF_RD_ADDR,
        RD_DOUT     => BUF_RD_DATA,
        RD_DOUT_VLD => BUF_RD_VLD
    );

    -- =============================================================================================
    -- AXI outputs
    -- =============================================================================================

    M_AXI_ARID    <= std_logic_vector(to_unsigned(AXI_ID, AXI_ID_WIDTH));
    M_AXI_ARADDR  <= std_logic_vector(araddr_r(AXI_ADDR_WIDTH-1 downto 0));
    M_AXI_ARLEN   <= std_logic_vector(arlen_r);
    M_AXI_ARSIZE  <= std_logic_vector(to_unsigned(AXSIZE, 3));
    M_AXI_ARBURST <= "01";
    M_AXI_ARLOCK  <= '0';
    M_AXI_ARCACHE <= AXI_CACHE;
    M_AXI_ARPROT  <= AXI_PROT;
    M_AXI_ARQOS   <= AXI_QOS;
    M_AXI_ARVALID <= arvalid_r;
    M_AXI_RREADY  <= '1';

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================

    ar_cross_4k <= '1' when ((resize(araddr_r(12-1 downto 0), 16) + shift_left(resize(arlen_r, 16) + 1, AXSIZE)) > 4096) else '0';

    -- independent of the pend counters: the accepted-write count seen by the request must be done
    ar_fence_viol <= '1' when (arvalid_r = '1' and ar_first = '1' and signed(unsigned(WR_DONE_CNT) - ar_fence) < 0) else '0';

    r_unalloc <= '1' when (M_AXI_RVALID = '1' and r_chunk_cnt = alloc_ptr) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl assert_ar_no_4k_cross : assert always
    --     ((RESET = '0' and arvalid_r = '1') -> ar_cross_4k = '0')
    --     report "PCIE_BAR2AXI_RD: AXI read burst crosses a 4 KB boundary";

    -- psl assert_ar_after_earlier_writes : assert always
    --     (RESET = '0' -> ar_fence_viol = '0')
    --     report "PCIE_BAR2AXI_RD: AXI read issued before every earlier write got its B response";

    -- psl assert_ar_stable : assert always
    --     ((RESET = '0' and arvalid_r = '1' and M_AXI_ARREADY = '0') -> next (arvalid_r = '1'))
    --     report "PCIE_BAR2AXI_RD: ARVALID dropped before ARREADY";

    -- psl assert_r_into_allocated : assert always
    --     (RESET = '0' -> r_unalloc = '0')
    --     report "PCIE_BAR2AXI_RD: R data beyond the reserved read buffer space";

    -- psl assert_rq_bound : assert always
    --     (RESET = '0' -> rq_cnt <= RD_OUTSTANDING)
    --     report "PCIE_BAR2AXI_RD: request ring overflow";

    -- psl assert_cpl_no_overflow : assert always
    --     ((RESET = '0' and rq_pop = '1') -> cpl_full = '0')
    --     report "PCIE_BAR2AXI_RD: completion queue overflow";

end architecture;
