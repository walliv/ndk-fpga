-- fs_rd_issue.vhd: issues the file shell's read chunks to DMA Iuventus and pairs each with its CID
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

-- The DMA frees a read's tag at its CQE, long before the frame is drained, so a {qid, cid} table
-- cannot name a frame at SOF. Its context is looked up at the read's success status instead and
-- queued per endpoint, where frames arrive in success order.
entity FS_RD_ISSUE is
    generic (
        STREAMS        : natural := 8;
        NUM_QUEUES     : natural := 4;
        PCIE_ENDPOINTS : natural := 1;
        CID_W          : natural := 16;
        -- Per-queue contexts issued but not yet accepted by the DMA; the if_pipe's credits keep
        -- them at or below its REQ_FIFO_ITEMS.
        CTX_FIFO_ITEMS : natural := 64;
        -- Reads per endpoint between issue and the start of their frame: the depth of the frame
        -- context queue, and the issue window that keeps it from overflowing.
        XCTX_ITEMS     : natural := 512;
        DEVICE         : string  := "ULTRASCALE"
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;
        -- Only while RD_IDLE: contexts of reads in flight would be lost.
        CLEAR : in std_logic;

        -- =========================================================================================
        -- Chunk requests, one port per stream
        -- =========================================================================================
        CREQ_VLD  : in  std_logic_vector(STREAMS-1 downto 0);
        CREQ_RDY  : out std_logic_vector(STREAMS-1 downto 0);
        CREQ_QID  : in  slv_array_t(STREAMS-1 downto 0)(max(1, log2(NUM_QUEUES))-1 downto 0);
        CREQ_LBA  : in  slv_array_t(STREAMS-1 downto 0)(FS_LBA_W-1 downto 0);
        CREQ_NLBA : in  slv_array_t(STREAMS-1 downto 0)(7 downto 0);
        CREQ_CTX  : in  slv_array_t(STREAMS-1 downto 0)(FS_CTX_W-1 downto 0);

        -- =========================================================================================
        -- Engine side of USER_CORE_IF_PIPE
        -- =========================================================================================
        ENG_RD_REQ_LBA_PTR : out std_logic_vector(63 downto 0);
        ENG_RD_REQ_LBA_NUM : out std_logic_vector(7 downto 0);
        ENG_RD_REQ_QID     : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        ENG_RD_REQ_VLD     : out std_logic;
        ENG_RD_REQ_RDY     : in  std_logic_vector(NUM_QUEUES-1 downto 0);

        -- =========================================================================================
        -- DMA side: the USER_CORE entity ports, observed only
        -- =========================================================================================
        DMA_RD_REQ_VLD     : in std_logic_vector(NUM_QUEUES-1 downto 0);
        DMA_RD_REQ_RDY     : in std_logic_vector(NUM_QUEUES-1 downto 0);
        DMA_RD_REQ_QID     : in std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        DMA_RD_REQ_CID     : in std_logic_vector(CID_W-1 downto 0);
        DMA_RD_REQ_CID_VLD : in std_logic;

        -- Taken here, not from the if_pipe: the table write at CID_VLD must stay ordered with the
        -- status lookups, and a tag is reissued one cycle after its status at the earliest.
        DMA_OP_STAT_TYPE : in std_logic;
        DMA_OP_STAT_CODE : in std_logic_vector(1 downto 0);
        DMA_OP_STAT_QID  : in std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        DMA_OP_STAT_CID  : in std_logic_vector(CID_W-1 downto 0);
        DMA_OP_STAT_VLD  : in std_logic;

        -- =========================================================================================
        -- Frame contexts per endpoint, in frame order: {qid, cid(5:0), ctx}, ctx in the low bits
        -- =========================================================================================
        XCTX_VLD  : out std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
        XCTX_DATA : out slv_array_t(PCIE_ENDPOINTS-1 downto 0)(max(1, log2(NUM_QUEUES))+FS_TAG_W+FS_CTX_W-1 downto 0);
        XCTX_RD   : in  std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

        -- =========================================================================================
        -- Read failures
        -- =========================================================================================
        RERR_VLD  : out std_logic;
        RERR_MASK : out std_logic_vector(STREAMS-1 downto 0);
        RERR_INFO : out std_logic_vector(31 downto 0);

        -- No read issued here is still waiting for its status or the start of its frame.
        RD_IDLE : out std_logic
    );
end entity;

architecture FULL of FS_RD_ISSUE is

    constant QID_W   : natural := max(1, log2(NUM_QUEUES));
    constant TBL_AW  : natural := QID_W + FS_TAG_W;
    constant XCTX_W  : natural := QID_W + FS_TAG_W + FS_CTX_W;
    constant WIN_W   : natural := log2(XCTX_ITEMS + 1) + 1;

    function ep_of_f (qid : std_logic_vector) return natural is
    begin
        return work.iuventus_sizing_pkg.queue_ep_f(to_integer(unsigned(qid)) mod NUM_QUEUES, NUM_QUEUES, PCIE_ENDPOINTS);
    end function;

    function onehot_f (stream : std_logic_vector(FS_STREAM_W-1 downto 0)) return std_logic_vector is
        variable mask : std_logic_vector(STREAMS-1 downto 0) := (others => '0');
    begin
        mask(to_integer(unsigned(stream)) mod STREAMS) := '1';
        return mask;
    end function;

    -- Engine-side issue
    signal q_ok     : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal elig     : std_logic_vector(STREAMS-1 downto 0);
    signal rr_ptr   : natural range 0 to STREAMS-1;
    signal sel_idx  : natural range 0 to STREAMS-1;
    signal sel_vld  : std_logic;
    signal sel_qid  : std_logic_vector(QID_W-1 downto 0);
    signal push_vld : std_logic;
    signal push_qid : std_logic_vector(QID_W-1 downto 0);
    signal push_ctx : std_logic_vector(FS_CTX_W-1 downto 0);

    signal ctx_wr    : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ctx_rd    : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ctx_full  : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ctx_afull : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ctx_empty : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ctx_do    : slv_array_t(NUM_QUEUES-1 downto 0)(FS_CTX_W-1 downto 0);
    signal fifo_rst  : std_logic;

    -- DMA-side events, all registered once so they keep their port order
    signal d_acc     : std_logic;
    signal d_qid     : std_logic_vector(QID_W-1 downto 0);
    signal d_cid_vld : std_logic;
    signal d_cid     : std_logic_vector(CID_W-1 downto 0);
    signal d_st_vld  : std_logic;
    signal d_st_code : std_logic_vector(1 downto 0);
    signal d_st_qid  : std_logic_vector(QID_W-1 downto 0);
    signal d_st_cid  : std_logic_vector(CID_W-1 downto 0);
    signal d_oor     : std_logic;

    -- The accepted read waiting for its CID (or its out-of-range rejection)
    signal hold_vld : std_logic;
    signal hold_qid : std_logic_vector(QID_W-1 downto 0);
    signal hold_ctx : std_logic_vector(FS_CTX_W-1 downto 0);

    type   tbl_t is array (0 to 2**TBL_AW-1) of std_logic_vector(FS_CTX_W-1 downto 0);
    signal tbl    : tbl_t;
    signal tbl_wa : natural range 0 to 2**TBL_AW-1;
    signal tbl_ra : natural range 0 to 2**TBL_AW-1;
    signal tbl_q1 : std_logic_vector(FS_CTX_W-1 downto 0);
    signal tbl_q2 : std_logic_vector(FS_CTX_W-1 downto 0);

    attribute ram_style        : string;
    attribute ram_style of tbl : signal is "block";

    -- Status pipeline, aligned with the two-cycle table read
    signal st1_vld   : std_logic;
    signal st1_code  : std_logic_vector(1 downto 0);
    signal st1_qid   : std_logic_vector(QID_W-1 downto 0);
    signal st1_cid   : std_logic_vector(CID_W-1 downto 0);
    signal st1_hvld  : std_logic;
    signal st1_hqid  : std_logic_vector(QID_W-1 downto 0);
    signal st1_hstrm : std_logic_vector(FS_STREAM_W-1 downto 0);
    signal st2_vld   : std_logic;
    signal st2_code  : std_logic_vector(1 downto 0);
    signal st2_qid   : std_logic_vector(QID_W-1 downto 0);
    signal st2_cid   : std_logic_vector(CID_W-1 downto 0);
    signal st2_hvld  : std_logic;
    signal st2_hqid  : std_logic_vector(QID_W-1 downto 0);
    signal st2_hstrm : std_logic_vector(FS_STREAM_W-1 downto 0);

    signal xf_wr    : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal xf_full  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal xf_empty : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal xf_di    : std_logic_vector(XCTX_W-1 downto 0);

    type   win_t is array (0 to PCIE_ENDPOINTS-1) of unsigned(WIN_W-1 downto 0);
    signal win_cnt : win_t;
    signal win_ok  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal win_inc : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal win_dec : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal win_udf : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    -- Invariant flags for the assertions
    signal cid_hi_err   : std_logic;
    signal cid_orphan   : std_logic;
    signal acc_held     : std_logic;
    signal oor_orphan   : std_logic;
    signal ctx_rd_empty : std_logic;
    signal ctx_wr_full  : std_logic;
    signal xf_wr_full   : std_logic;
    signal xf_rd_empty  : std_logic;
    signal win_under    : std_logic;

begin

    assert (NUM_QUEUES mod PCIE_ENDPOINTS = 0)
        report "FS_RD_ISSUE: NUM_QUEUES must be a multiple of PCIE_ENDPOINTS"
        severity failure;

    fifo_rst <= RESET or CLEAR;

    -- =============================================================================================
    -- Engine side: round robin over the streams whose queue has credit, context room and window
    -- =============================================================================================
    q_ok_g : for q in 0 to NUM_QUEUES-1 generate
        q_ok(q) <= ENG_RD_REQ_RDY(q) and not ctx_afull(q) and win_ok(work.iuventus_sizing_pkg.queue_ep_f(q, NUM_QUEUES, PCIE_ENDPOINTS));
    end generate;

    elig_g : for s in 0 to STREAMS-1 generate
        elig(s) <= CREQ_VLD(s) and q_ok(to_integer(unsigned(CREQ_QID(s))) mod NUM_QUEUES);
    end generate;

    sel_idx <= fs_rr_pick_f(elig, rr_ptr);
    sel_vld <= or elig;

    sel_qid <= CREQ_QID(sel_idx);

    creq_rdy_g : for s in 0 to STREAMS-1 generate
        CREQ_RDY(s) <= sel_vld when (sel_idx = s) else '0';
    end generate;

    ENG_RD_REQ_VLD     <= sel_vld;
    ENG_RD_REQ_QID     <= sel_qid;
    ENG_RD_REQ_LBA_PTR <= std_logic_vector(resize(unsigned(CREQ_LBA(sel_idx)), 64));
    ENG_RD_REQ_LBA_NUM <= CREQ_NLBA(sel_idx);

    issue_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            push_vld <= sel_vld;
            push_qid <= sel_qid;
            push_ctx <= CREQ_CTX(sel_idx);
            if (sel_vld = '1') then
                rr_ptr <= (sel_idx + 1) mod STREAMS;
            end if;
            if (RESET = '1' or CLEAR = '1') then
                push_vld <= '0';
                rr_ptr   <= 0;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Per-queue context FIFOs: pushed at the engine-side issue, popped at the DMA-side accept
    -- =============================================================================================
    ctx_fifo_g : for q in 0 to NUM_QUEUES-1 generate
        ctx_wr(q) <= push_vld when (to_integer(unsigned(push_qid)) mod NUM_QUEUES = q) else '0';
        ctx_rd(q) <= d_acc when (to_integer(unsigned(d_qid)) mod NUM_QUEUES = q) else '0';

        ctx_fifo_i : entity work.FIFOX
        generic map (
            DATA_WIDTH          => FS_CTX_W,
            ITEMS               => CTX_FIFO_ITEMS,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            -- One push may already be registered behind the AFULL the issue looked at.
            ALMOST_FULL_OFFSET  => 2,
            ALMOST_EMPTY_OFFSET => 0,
            FAKE_FIFO           => false
        )
        port map (
            CLK    => CLK,
            RESET  => fifo_rst,
            DI     => push_ctx,
            WR     => ctx_wr(q),
            FULL   => ctx_full(q),
            AFULL  => ctx_afull(q),
            STATUS => open,
            DO     => ctx_do(q),
            RD     => ctx_rd(q),
            EMPTY  => ctx_empty(q),
            AEMPTY => open
        );
    end generate;

    -- =============================================================================================
    -- DMA side: accept -> hold -> CID -> table
    -- =============================================================================================
    dma_in_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            d_acc     <= or (DMA_RD_REQ_VLD and DMA_RD_REQ_RDY);
            d_qid     <= DMA_RD_REQ_QID;
            d_cid_vld <= DMA_RD_REQ_CID_VLD;
            d_cid     <= DMA_RD_REQ_CID;
            d_st_vld  <= DMA_OP_STAT_VLD and DMA_OP_STAT_TYPE;
            d_st_code <= DMA_OP_STAT_CODE;
            d_st_qid  <= DMA_OP_STAT_QID;
            d_st_cid  <= DMA_OP_STAT_CID;
            if (RESET = '1') then
                d_acc     <= '0';
                d_cid_vld <= '0';
                d_st_vld  <= '0';
            end if;
        end if;
    end process;

    d_oor <= d_st_vld when (d_st_code = FS_OP_CODE_OOR) else '0';

    -- An out-of-range read gets no CID; its rejection names the held accept, which precedes the
    -- next one. A CID or rejection and the next accept may share a cycle: both see the old hold.
    hold_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (d_acc = '1') then
                hold_vld <= '1';
                hold_qid <= d_qid;
                hold_ctx <= ctx_do(to_integer(unsigned(d_qid)) mod NUM_QUEUES);
            elsif (d_cid_vld = '1' or d_oor = '1') then
                hold_vld <= '0';
            end if;
            if (RESET = '1' or CLEAR = '1') then
                hold_vld <= '0';
            end if;
        end if;
    end process;

    tbl_wa <= to_integer(unsigned(hold_qid) & unsigned(d_cid(FS_TAG_W-1 downto 0)));
    tbl_ra <= to_integer(unsigned(d_st_qid) & unsigned(d_st_cid(FS_TAG_W-1 downto 0)));

    tbl_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (d_cid_vld = '1') then
                tbl(tbl_wa) <= hold_ctx;
            end if;
            tbl_q1 <= tbl(tbl_ra);
            tbl_q2 <= tbl_q1;
        end if;
    end process;

    -- =============================================================================================
    -- Read status: success queues the frame context, failures name their stream
    -- =============================================================================================
    st_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            st1_vld   <= d_st_vld;
            st1_code  <= d_st_code;
            st1_qid   <= d_st_qid;
            st1_cid   <= d_st_cid;
            st1_hvld  <= hold_vld;
            st1_hqid  <= hold_qid;
            st1_hstrm <= fs_ctx_stream_f(hold_ctx);
            st2_vld   <= st1_vld;
            st2_code  <= st1_code;
            st2_qid   <= st1_qid;
            st2_cid   <= st1_cid;
            st2_hvld  <= st1_hvld;
            st2_hqid  <= st1_hqid;
            st2_hstrm <= st1_hstrm;
            if (RESET = '1' or CLEAR = '1') then
                st1_vld <= '0';
                st2_vld <= '0';
            end if;
        end if;
    end process;

    -- DATA_LOST arrives after its frame left the DMA, by when the tag may serve a newer read whose
    -- status already overwrote any per-tag record, so its stream is unknown: every stream fails.
    rerr_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            RERR_VLD  <= '0';
            RERR_MASK <= (others => '1');
            RERR_INFO <= fs_err_info_f(FS_ERR_SRC_NVME, st2_code, '1',
                                       std_logic_vector(resize(unsigned(st2_qid), 4)), st2_cid);
            if (st2_vld = '1' and st2_code /= FS_OP_CODE_OK) then
                RERR_VLD <= '1';
            end if;
            if (st2_code = FS_OP_CODE_FAIL) then
                RERR_MASK <= onehot_f(fs_ctx_stream_f(tbl_q2));
            elsif (st2_code = FS_OP_CODE_OOR) then
                RERR_INFO <= fs_err_info_f(FS_ERR_SRC_NVME, st2_code, '1', (others => '0'), (others => '0'));
                if (st2_hvld = '1') then
                    RERR_MASK <= onehot_f(st2_hstrm);
                end if;
            end if;
            if (RESET = '1' or CLEAR = '1') then
                RERR_VLD <= '0';
            end if;
        end if;
    end process;

    xf_di <= st2_qid & st2_cid(FS_TAG_W-1 downto 0) & tbl_q2;

    xf_g : for e in 0 to PCIE_ENDPOINTS-1 generate
        xf_wr(e) <= '1' when (st2_vld = '1' and st2_code = FS_OP_CODE_OK and ep_of_f(st2_qid) = e) else '0';

        xf_i : entity work.FIFOX
        generic map (
            DATA_WIDTH          => XCTX_W,
            ITEMS               => XCTX_ITEMS,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 0,
            ALMOST_EMPTY_OFFSET => 0,
            FAKE_FIFO           => false
        )
        port map (
            CLK    => CLK,
            RESET  => fifo_rst,
            DI     => xf_di,
            WR     => xf_wr(e),
            FULL   => xf_full(e),
            AFULL  => open,
            STATUS => open,
            DO     => XCTX_DATA(e),
            RD     => XCTX_RD(e),
            EMPTY  => xf_empty(e),
            AEMPTY => open
        );

        XCTX_VLD(e) <= not xf_empty(e);
    end generate;

    -- =============================================================================================
    -- Issue window per endpoint: a read counts from its issue until its frame context is taken or
    -- it fails, so the frame context queue can always take a success
    -- =============================================================================================
    win_ev_g : for e in 0 to PCIE_ENDPOINTS-1 generate
        win_inc(e) <= '1' when (sel_vld = '1' and ep_of_f(sel_qid) = e) else '0';
        win_dec(e) <= '1' when (st2_vld = '1'
                                and ((st2_code = FS_OP_CODE_FAIL and ep_of_f(st2_qid) = e)
                                     or (st2_code = FS_OP_CODE_OOR and st2_hvld = '1' and ep_of_f(st2_hqid) = e))) else
                      '0';
        win_ok(e)  <= '1' when (win_cnt(e) < XCTX_ITEMS) else '0';
        win_udf(e) <= '1' when (win_cnt(e) + unsigned'('0' & win_inc(e)) < unsigned'('0' & XCTX_RD(e)) + unsigned'('0' & win_dec(e))) else '0';
    end generate;

    win_p : process (CLK) is
        variable v : unsigned(WIN_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            for e in 0 to PCIE_ENDPOINTS-1 loop
                v := win_cnt(e);
                if (win_inc(e) = '1') then
                    v := v + 1;
                end if;
                if (XCTX_RD(e) = '1') then
                    v := v - 1;
                end if;
                if (win_dec(e) = '1') then
                    v := v - 1;
                end if;
                win_cnt(e) <= v;
            end loop;
            if (RESET = '1' or CLEAR = '1') then
                win_cnt <= (others => (others => '0'));
            end if;
        end if;
    end process;

    rd_idle_p : process (all) is
    begin
        RD_IDLE <= '1';
        for e in 0 to PCIE_ENDPOINTS-1 loop
            if (win_cnt(e) /= 0) then
                RD_IDLE <= '0';
            end if;
        end loop;
    end process;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    cid_hi_err   <= d_cid_vld when (unsigned(d_cid(CID_W-1 downto FS_TAG_W)) /= 0) else '0';
    cid_orphan   <= d_cid_vld and not hold_vld;
    acc_held     <= d_acc and hold_vld and not (d_cid_vld or d_oor);
    oor_orphan   <= d_oor and not hold_vld;
    ctx_rd_empty <= or (ctx_rd and ctx_empty);
    ctx_wr_full  <= or (ctx_wr and ctx_full);
    xf_wr_full   <= or (xf_wr and xf_full);
    xf_rd_empty  <= or (XCTX_RD and xf_empty);
    win_under    <= or win_udf;

    -- psl default clock is rising_edge(CLK);

    -- psl fs_rd_issue_cid_in_pool : assert always (RESET = '0' -> cid_hi_err = '0')
    --     report "FS_RD_ISSUE: a read CID lies outside the 64-tag pool";
    -- psl fs_rd_issue_cid_follows_accept : assert always (RESET = '0' -> cid_orphan = '0')
    --     report "FS_RD_ISSUE: a read CID arrived with no accepted read waiting for it";
    -- psl fs_rd_issue_accept_resolved : assert always (RESET = '0' -> acc_held = '0')
    --     report "FS_RD_ISSUE: a read was accepted before the previous one got its CID";
    -- psl fs_rd_issue_oor_follows_accept : assert always (RESET = '0' -> oor_orphan = '0')
    --     report "FS_RD_ISSUE: an out-of-range read status with no accepted read waiting";
    -- psl fs_rd_issue_ctx_pop_nonempty : assert always (RESET = '0' -> ctx_rd_empty = '0')
    --     report "FS_RD_ISSUE: the DMA accepted a read whose context FIFO is empty";
    -- psl fs_rd_issue_ctx_push_room : assert always (RESET = '0' -> ctx_wr_full = '0')
    --     report "FS_RD_ISSUE: a context was pushed into a full context FIFO";
    -- psl fs_rd_issue_xctx_push_room : assert always (RESET = '0' -> xf_wr_full = '0')
    --     report "FS_RD_ISSUE: a frame context was pushed into a full frame context queue";
    -- psl fs_rd_issue_xctx_pop_nonempty : assert always (RESET = '0' -> xf_rd_empty = '0')
    --     report "FS_RD_ISSUE: a frame context was taken from an empty queue";
    -- psl fs_rd_issue_window_no_underflow : assert always (RESET = '0' -> win_under = '0')
    --     report "FS_RD_ISSUE: more reads retired than were issued on an endpoint";

end architecture;
