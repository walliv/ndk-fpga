-- user_core_if_pipe.vhd: pipeline registers between a USER_CORE architecture and the DMA
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- Adds STAGES of registers between a USER_CORE architecture and the DMA, so the two sit far
-- apart. The read-request path is credit-based: the DMA's per-queue accept window mirrors into
-- credits at the core, so both spans carry only forward registers.
entity USER_CORE_IF_PIPE is
    generic (
        NUM_QUEUES      : natural := 4;
        LBA_PTR_W       : natural := 64;
        MFB_REGION_SIZE : natural := 8;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 8;
        -- Width of the completion's command identifier, carried with the operation status.
        CID_W           : natural := 16;
        -- Register stages per direction on each interface.
        STAGES          : natural := 6;
        -- Per-queue request buffer at the DMA end; must exceed the 2*STAGES credit round trip so a
        -- steadily accepting queue never stalls on credit.
        REQ_FIFO_ITEMS  : natural := 16;
        DEVICE          : string  := "ULTRASCALE"
    );
    port (
        CLK       : in std_logic;
        RESET     : in std_logic;
        -- RESET delayed by STAGES, for the logic at the engine end. A reset that has to cross the
        -- die in one cycle is a timing path like any other; this one travels with the data.
        ENG_RESET : out std_logic;

        -- =====================================================================
        -- Engine side
        -- =====================================================================
        ENG_RD_REQ_LBA_PTR : in  std_logic_vector(LBA_PTR_W-1 downto 0);
        ENG_RD_REQ_LBA_NUM : in  std_logic_vector(7 downto 0);
        ENG_RD_REQ_QID     : in  std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        ENG_RD_REQ_VLD     : in  std_logic;
        ENG_RD_REQ_RDY     : out std_logic_vector(NUM_QUEUES-1 downto 0);
        ENG_RD_REQ_CID     : out std_logic_vector(CID_W-1 downto 0);
        ENG_RD_REQ_CID_VLD : out std_logic;

        ENG_OP_STAT_TYPE : out std_logic;
        ENG_OP_STAT_CODE : out std_logic_vector(1 downto 0);
        ENG_OP_STAT_QID  : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        ENG_OP_STAT_CID  : out std_logic_vector(CID_W-1 downto 0);
        ENG_OP_STAT_VLD  : out std_logic;

        ENG_RD_MFB_DATA    : out std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        ENG_RD_MFB_META    : out std_logic_vector(max(1, log2(NUM_QUEUES)) + CID_W -1 downto 0);
        ENG_RD_MFB_SOF     : out std_logic_vector(0 downto 0);
        ENG_RD_MFB_EOF     : out std_logic_vector(0 downto 0);
        ENG_RD_MFB_SOF_POS : out std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        ENG_RD_MFB_EOF_POS : out std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        ENG_RD_MFB_SRC_RDY : out std_logic;
        ENG_RD_MFB_DST_RDY : in  std_logic;

        ENG_WR_MFB_DATA    : in  std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        ENG_WR_MFB_META    : in  std_logic_vector(max(1, log2(NUM_QUEUES)) + LBA_PTR_W -1 downto 0);
        ENG_WR_MFB_SOF     : in  std_logic_vector(0 downto 0);
        ENG_WR_MFB_EOF     : in  std_logic_vector(0 downto 0);
        ENG_WR_MFB_SOF_POS : in  std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        ENG_WR_MFB_EOF_POS : in  std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        ENG_WR_MFB_SRC_RDY : in  std_logic;
        ENG_WR_MFB_DST_RDY : out std_logic;

        -- =====================================================================
        -- DMA side
        -- =====================================================================
        DMA_RD_REQ_LBA_PTR     : out std_logic_vector(LBA_PTR_W-1 downto 0);
        DMA_RD_REQ_LBA_NUM     : out std_logic_vector(7 downto 0);
        DMA_RD_REQ_QID         : out std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        DMA_RD_REQ_VLD         : out std_logic_vector(NUM_QUEUES-1 downto 0);
        DMA_RD_REQ_RDY         : in  std_logic_vector(NUM_QUEUES-1 downto 0);
        -- Pages each queue's head request needs, so the DMA admits against what it asks for. NOT
        -- routed through mv_sel (selects on DMA_RD_REQ_RDY -- would loop). 6 bits: an 8b LBA
        -- count maxes at 32 pages, matching MAX_XFER_PAGES; a mismatch fails elaboration.
        DMA_RD_REQ_NPAGES_ALL  : out std_logic_vector(NUM_QUEUES*6-1 downto 0);
        DMA_RD_REQ_CID         : in  std_logic_vector(CID_W-1 downto 0);
        DMA_RD_REQ_CID_VLD     : in  std_logic;

        DMA_OP_STAT_TYPE : in std_logic;
        DMA_OP_STAT_CODE : in std_logic_vector(1 downto 0);
        DMA_OP_STAT_QID  : in std_logic_vector(max(1, log2(NUM_QUEUES))-1 downto 0);
        DMA_OP_STAT_CID  : in std_logic_vector(CID_W-1 downto 0);
        DMA_OP_STAT_VLD  : in std_logic;

        DMA_RD_MFB_DATA    : in  std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        DMA_RD_MFB_META    : in  std_logic_vector(max(1, log2(NUM_QUEUES)) + CID_W -1 downto 0);
        DMA_RD_MFB_SOF     : in  std_logic_vector(0 downto 0);
        DMA_RD_MFB_EOF     : in  std_logic_vector(0 downto 0);
        DMA_RD_MFB_SOF_POS : in  std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        DMA_RD_MFB_EOF_POS : in  std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        DMA_RD_MFB_SRC_RDY : in  std_logic;
        DMA_RD_MFB_DST_RDY : out std_logic;

        DMA_WR_MFB_DATA    : out std_logic_vector(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        DMA_WR_MFB_META    : out std_logic_vector(max(1, log2(NUM_QUEUES)) + LBA_PTR_W -1 downto 0);
        DMA_WR_MFB_SOF     : out std_logic_vector(0 downto 0);
        DMA_WR_MFB_EOF     : out std_logic_vector(0 downto 0);
        DMA_WR_MFB_SOF_POS : out std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        DMA_WR_MFB_EOF_POS : out std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        DMA_WR_MFB_SRC_RDY : out std_logic;
        DMA_WR_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of USER_CORE_IF_PIPE is

    constant QID_W      : natural := max(1, log2(NUM_QUEUES));
    constant WR_META_W  : natural := QID_W + LBA_PTR_W;
    constant RD_META_W  : natural := QID_W + CID_W;
    constant MFB_DATA_W : natural := MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    constant SOF_POS_W  : natural := max(1, log2(MFB_REGION_SIZE));
    constant EOF_POS_W  : natural := log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE);
    constant REQ_W      : natural := LBA_PTR_W + 8 + QID_W;
    constant NPAGES_W   : natural := 6;
    -- The request FIFO carries the page count alongside the request so read admission never has
    -- to derive it: that arithmetic in the DMA's ready cone cost 0.178 ns of setup slack.
    constant FIFO_W     : natural := LBA_PTR_W + 8 + NPAGES_W;
    constant CRED_W     : natural := log2(REQ_FIFO_ITEMS+1) + 1;
    constant STAT_W     : natural := 1 + 2 + QID_W + CID_W + 1;

    -- Forward request chain, engine to the per-queue buffers.
    type   req_pl_t is array (0 to STAGES) of std_logic_vector(REQ_W-1 downto 0);
    signal req_pl     : req_pl_t;
    signal req_vld_pl : std_logic_vector(STAGES downto 0);

    -- Credit-return chain, buffer pop back to the engine.
    type   ret_pl_t is array (0 to STAGES) of std_logic_vector(NUM_QUEUES-1 downto 0);
    signal ret_pl : ret_pl_t;

    type   cred_arr_t is array (0 to NUM_QUEUES-1) of unsigned(CRED_W-1 downto 0);
    signal credit : cred_arr_t;

    signal push_qid : natural range 0 to NUM_QUEUES-1;
    signal eng_qid  : natural range 0 to NUM_QUEUES-1;

    type   fifo_do_t is array (0 to NUM_QUEUES-1) of std_logic_vector(FIFO_W-1 downto 0);
    signal fifo_di     : std_logic_vector(FIFO_W-1 downto 0);
    signal fifo_npages : std_logic_vector(NPAGES_W-1 downto 0);
    signal fifo_do     : fifo_do_t;
    signal fifo_wr     : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal fifo_rd     : std_logic_vector(NUM_QUEUES-1 downto 0);
    signal fifo_empty  : std_logic_vector(NUM_QUEUES-1 downto 0);

    -- Graded reset: index 0 is the DMA end, index STAGES the engine end, and every stage takes the
    -- copy nearest to where it sits. SRL packing would collapse them into one site and put the
    -- whole crossing back on a single net.
    signal rst_pl : std_logic_vector(STAGES downto 0);

    attribute shreg_extract : string;
    attribute shreg_extract of rst_pl : signal is "NO";

    signal mv_ptr  : unsigned(QID_W-1 downto 0);
    signal mv_sel  : natural range 0 to NUM_QUEUES-1;
    signal mv_fire : std_logic;

    -- Operation-status chain; the interface has no backpressure, so plain registers suffice.
    type   stat_pl_t is array (0 to STAGES) of std_logic_vector(STAT_W-1 downto 0);
    signal stat_pl : stat_pl_t;

    type   cid_pl_t is array (0 to STAGES) of std_logic_vector(CID_W downto 0);
    signal cid_pl : cid_pl_t;

    type   rd_meta_t is array (0 to STAGES) of std_logic_vector(RD_META_W-1 downto 0);
    signal rd_meta : rd_meta_t;

    type mfb_data_t is array (0 to STAGES) of std_logic_vector(MFB_DATA_W-1 downto 0);
    type mfb_meta_t is array (0 to STAGES) of std_logic_vector(WR_META_W-1 downto 0);
    type mfb_pos_t is array (0 to STAGES) of std_logic_vector(SOF_POS_W-1 downto 0);
    type mfb_eos_t is array (0 to STAGES) of std_logic_vector(EOF_POS_W-1 downto 0);
    type mfb_bit_t is array (0 to STAGES) of std_logic_vector(0 downto 0);
    type mfb_rdy_t is array (0 to STAGES) of std_logic;

    signal rd_data    : mfb_data_t;
    signal rd_sof     : mfb_bit_t;
    signal rd_eof     : mfb_bit_t;
    signal rd_sof_pos : mfb_pos_t;
    signal rd_eof_pos : mfb_eos_t;
    signal rd_src_rdy : mfb_rdy_t;
    signal rd_dst_rdy : mfb_rdy_t;

    signal wr_data    : mfb_data_t;
    signal wr_meta    : mfb_meta_t;
    signal wr_sof     : mfb_bit_t;
    signal wr_eof     : mfb_bit_t;
    signal wr_sof_pos : mfb_pos_t;
    signal wr_eof_pos : mfb_eos_t;
    signal wr_src_rdy : mfb_rdy_t;
    signal wr_dst_rdy : mfb_rdy_t;

begin

    -- =========================================================================
    -- Reset distribution
    -- =========================================================================

    rst_pl(0) <= RESET;

    rst_chain_g : for s in 1 to STAGES generate
        rst_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                rst_pl(s) <= rst_pl(s-1);
            end if;
        end process;
    end generate;

    ENG_RESET <= rst_pl(STAGES);

    -- =========================================================================
    -- Read request: credits at the engine, buffers at the DMA
    -- =========================================================================

    eng_qid       <= to_integer(unsigned(ENG_RD_REQ_QID)) mod NUM_QUEUES;
    req_pl(0)     <= ENG_RD_REQ_QID & ENG_RD_REQ_LBA_NUM & ENG_RD_REQ_LBA_PTR;
    req_vld_pl(0) <= ENG_RD_REQ_VLD;

    req_chain_g : for s in 1 to STAGES generate
        req_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                req_pl(s) <= req_pl(s-1);
                if (rst_pl(STAGES-s) = '1') then
                    req_vld_pl(s) <= '0';
                else
                    req_vld_pl(s) <= req_vld_pl(s-1);
                end if;
            end if;
        end process;
    end generate;

    push_qid    <= to_integer(unsigned(req_pl(STAGES)(REQ_W-1 downto LBA_PTR_W+8))) mod NUM_QUEUES;
    -- ceil((lba_num+1)/8) at push time. Registered into the FIFO, so it leaves the ready cone.
    fifo_npages <= std_logic_vector(resize(
                       (resize(unsigned(req_pl(STAGES)(LBA_PTR_W+7 downto LBA_PTR_W)), 9) + 8) / 8,
                       NPAGES_W));
    fifo_di     <= fifo_npages & req_pl(STAGES)(LBA_PTR_W+7 downto 0);

    fifo_wr_p : process (all) is
    begin
        fifo_wr           <= (others => '0');
        fifo_wr(push_qid) <= req_vld_pl(STAGES);
    end process;

    req_fifo_g : for q in 0 to NUM_QUEUES-1 generate
        req_fifo_i : entity work.FIFOX
        generic map (
            DATA_WIDTH          => FIFO_W,
            ITEMS               => REQ_FIFO_ITEMS,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 0,
            ALMOST_EMPTY_OFFSET => 0
        )
        port map (
            CLK    => CLK,
            RESET  => rst_pl(0),
            DI     => fifo_di,
            WR     => fifo_wr(q),
            FULL   => open,
            AFULL  => open,
            STATUS => open,
            DO     => fifo_do(q),
            RD     => fifo_rd(q),
            EMPTY  => fifo_empty(q),
            AEMPTY => open
        );
    end generate;

    -- Round-robin over queues that hold a request and whose DMA accept window is open. The engine
    -- issues at most one request per command, so the pointer only prevents long-term starvation.
    mv_pick_p : process (all) is
        variable idx   : natural range 0 to NUM_QUEUES-1;
        variable taken : boolean;
    begin
        mv_sel  <= 0;
        mv_fire <= '0';
        taken   := false;
        for k in 0 to NUM_QUEUES-1 loop
            idx := (to_integer(mv_ptr) + k) mod NUM_QUEUES;
            if (not taken and fifo_empty(idx) = '0' and DMA_RD_REQ_RDY(idx) = '1') then
                mv_sel  <= idx;
                mv_fire <= '1';
                taken   := true;
            end if;
        end loop;
    end process;

    mv_ptr_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (rst_pl(0) = '1') then
                mv_ptr <= (others => '0');
            elsif (mv_fire = '1') then
                mv_ptr <= to_unsigned((mv_sel + 1) mod NUM_QUEUES, QID_W);
            end if;
        end if;
    end process;

    -- Every request the engine counts as issued reaches the DMA and completes, even one queued
    -- when a run aborts. Dropping them would leave the completion count short of the issue count;
    -- reconciling the two is how software knows the abort has quiesced.
    fifo_rd_p : process (all) is
    begin
        fifo_rd         <= (others => '0');
        fifo_rd(mv_sel) <= mv_fire;
    end process;

    -- An empty queue has no head request, so offer the largest read instead: that is the size
    -- admission applied to every queue before, so an idle queue cannot be admitted on a smaller
    -- footprint than the request that eventually arrives.
    head_num_g : for q in 0 to NUM_QUEUES-1 generate
        DMA_RD_REQ_NPAGES_ALL((q+1)*NPAGES_W-1 downto q*NPAGES_W) <=
            fifo_do(q)(FIFO_W-1 downto LBA_PTR_W+8) when (fifo_empty(q) = '0') else
            (others => '1');
    end generate;

    DMA_RD_REQ_LBA_PTR <= fifo_do(mv_sel)(LBA_PTR_W-1 downto 0);
    DMA_RD_REQ_LBA_NUM <= fifo_do(mv_sel)(LBA_PTR_W+7 downto LBA_PTR_W);
    DMA_RD_REQ_QID     <= std_logic_vector(to_unsigned(mv_sel, QID_W));

    dma_vld_p : process (all) is
    begin
        DMA_RD_REQ_VLD         <= (others => '0');
        DMA_RD_REQ_VLD(mv_sel) <= mv_fire;
    end process;

    ret_pl(0) <= fifo_rd;

    ret_chain_g : for s in 1 to STAGES generate
        ret_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (rst_pl(s-1) = '1') then
                    ret_pl(s) <= (others => '0');
                else
                    ret_pl(s) <= ret_pl(s-1);
                end if;
            end if;
        end process;
    end generate;

    -- A credit covers one buffer slot for the whole round trip, so the buffer cannot overflow and
    -- the engine never has to see the DMA's ready directly.
    credit_p : process (CLK) is
        variable push : std_logic;
    begin
        if (rising_edge(CLK)) then
            for q in 0 to NUM_QUEUES-1 loop
                push := '0';
                if (ENG_RD_REQ_VLD = '1' and eng_qid = q) then
                    push := '1';
                end if;
                if (rst_pl(STAGES) = '1') then
                    credit(q) <= to_unsigned(REQ_FIFO_ITEMS, CRED_W);
                elsif (push = '1' and ret_pl(STAGES)(q) = '0') then
                    credit(q) <= credit(q) - 1;
                elsif (push = '0' and ret_pl(STAGES)(q) = '1') then
                    credit(q) <= credit(q) + 1;
                end if;
            end loop;
        end if;
    end process;

    eng_rdy_g : for q in 0 to NUM_QUEUES-1 generate
        ENG_RD_REQ_RDY(q) <= '0' when (credit(q) = 0) else '1';
    end generate;

    -- =========================================================================
    -- Operation status
    -- =========================================================================

    stat_pl(0) <= DMA_OP_STAT_TYPE & DMA_OP_STAT_CODE & DMA_OP_STAT_QID & DMA_OP_STAT_CID & DMA_OP_STAT_VLD;

    stat_chain_g : for s in 1 to STAGES generate
        stat_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                stat_pl(s) <= stat_pl(s-1);
                if (rst_pl(s-1) = '1') then
                    stat_pl(s)(0) <= '0';
                end if;
            end if;
        end process;
    end generate;

    ENG_OP_STAT_TYPE <= stat_pl(STAGES)(STAT_W-1);
    ENG_OP_STAT_CODE <= stat_pl(STAGES)(STAT_W-2 downto STAT_W-3);
    ENG_OP_STAT_QID  <= stat_pl(STAGES)(QID_W + CID_W downto CID_W + 1);
    ENG_OP_STAT_CID  <= stat_pl(STAGES)(CID_W downto 1);
    ENG_OP_STAT_VLD  <= stat_pl(STAGES)(0);

    -- The accepted read's tag, which the DMA reports a few cycles behind the accept and which
    -- nothing back-pressures, so it travels as plain registers rather than through a handshake.
    cid_pl(0) <= DMA_RD_REQ_CID & DMA_RD_REQ_CID_VLD;

    cid_chain_g : for s in 1 to STAGES generate
        cid_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                cid_pl(s) <= cid_pl(s-1);
                if (rst_pl(s-1) = '1') then
                    cid_pl(s)(0) <= '0';
                end if;
            end if;
        end process;
    end generate;

    ENG_RD_REQ_CID     <= cid_pl(STAGES)(CID_W downto 1);
    ENG_RD_REQ_CID_VLD <= cid_pl(STAGES)(0);

    -- =========================================================================
    -- Read data, DMA to engine
    -- =========================================================================

    rd_data(0)         <= DMA_RD_MFB_DATA;
    rd_meta(0)         <= DMA_RD_MFB_META;
    rd_sof(0)          <= DMA_RD_MFB_SOF;
    rd_eof(0)          <= DMA_RD_MFB_EOF;
    rd_sof_pos(0)      <= DMA_RD_MFB_SOF_POS;
    rd_eof_pos(0)      <= DMA_RD_MFB_EOF_POS;
    rd_src_rdy(0)      <= DMA_RD_MFB_SRC_RDY;
    DMA_RD_MFB_DST_RDY <= rd_dst_rdy(0);

    rd_pipe_g : for s in 1 to STAGES generate
        rd_pipe_i : entity work.MFB_PIPE
        generic map (
            REGIONS     => 1,
            REGION_SIZE => MFB_REGION_SIZE,
            BLOCK_SIZE  => MFB_BLOCK_SIZE,
            ITEM_WIDTH  => MFB_ITEM_WIDTH,
            META_WIDTH  => RD_META_W,
            FAKE_PIPE   => false,
            USE_DST_RDY => true,
            PIPE_TYPE   => "SHREG",
            DEVICE      => DEVICE
        )
        port map (
            CLK        => CLK,
            RESET      => rst_pl(s-1),
            RX_DATA    => rd_data(s-1),
            RX_META    => rd_meta(s-1),
            RX_SOF_POS => rd_sof_pos(s-1),
            RX_EOF_POS => rd_eof_pos(s-1),
            RX_SOF     => rd_sof(s-1),
            RX_EOF     => rd_eof(s-1),
            RX_SRC_RDY => rd_src_rdy(s-1),
            RX_DST_RDY => rd_dst_rdy(s-1),
            TX_DATA    => rd_data(s),
            TX_META    => rd_meta(s),
            TX_SOF_POS => rd_sof_pos(s),
            TX_EOF_POS => rd_eof_pos(s),
            TX_SOF     => rd_sof(s),
            TX_EOF     => rd_eof(s),
            TX_SRC_RDY => rd_src_rdy(s),
            TX_DST_RDY => rd_dst_rdy(s)
        );
    end generate;

    ENG_RD_MFB_DATA    <= rd_data(STAGES);
    ENG_RD_MFB_META    <= rd_meta(STAGES);
    ENG_RD_MFB_SOF     <= rd_sof(STAGES);
    ENG_RD_MFB_EOF     <= rd_eof(STAGES);
    ENG_RD_MFB_SOF_POS <= rd_sof_pos(STAGES);
    ENG_RD_MFB_EOF_POS <= rd_eof_pos(STAGES);
    ENG_RD_MFB_SRC_RDY <= rd_src_rdy(STAGES);
    rd_dst_rdy(STAGES) <= ENG_RD_MFB_DST_RDY;

    -- =========================================================================
    -- Write data, engine to DMA
    -- =========================================================================

    wr_data(0)         <= ENG_WR_MFB_DATA;
    wr_meta(0)         <= ENG_WR_MFB_META;
    wr_sof(0)          <= ENG_WR_MFB_SOF;
    wr_eof(0)          <= ENG_WR_MFB_EOF;
    wr_sof_pos(0)      <= ENG_WR_MFB_SOF_POS;
    wr_eof_pos(0)      <= ENG_WR_MFB_EOF_POS;
    wr_src_rdy(0)      <= ENG_WR_MFB_SRC_RDY;
    ENG_WR_MFB_DST_RDY <= wr_dst_rdy(0);

    wr_pipe_g : for s in 1 to STAGES generate
        wr_pipe_i : entity work.MFB_PIPE
        generic map (
            REGIONS     => 1,
            REGION_SIZE => MFB_REGION_SIZE,
            BLOCK_SIZE  => MFB_BLOCK_SIZE,
            ITEM_WIDTH  => MFB_ITEM_WIDTH,
            META_WIDTH  => WR_META_W,
            FAKE_PIPE   => false,
            USE_DST_RDY => true,
            PIPE_TYPE   => "SHREG",
            DEVICE      => DEVICE
        )
        port map (
            CLK        => CLK,
            RESET      => rst_pl(STAGES-s+1),
            RX_DATA    => wr_data(s-1),
            RX_META    => wr_meta(s-1),
            RX_SOF_POS => wr_sof_pos(s-1),
            RX_EOF_POS => wr_eof_pos(s-1),
            RX_SOF     => wr_sof(s-1),
            RX_EOF     => wr_eof(s-1),
            RX_SRC_RDY => wr_src_rdy(s-1),
            RX_DST_RDY => wr_dst_rdy(s-1),
            TX_DATA    => wr_data(s),
            TX_META    => wr_meta(s),
            TX_SOF_POS => wr_sof_pos(s),
            TX_EOF_POS => wr_eof_pos(s),
            TX_SOF     => wr_sof(s),
            TX_EOF     => wr_eof(s),
            TX_SRC_RDY => wr_src_rdy(s),
            TX_DST_RDY => wr_dst_rdy(s)
        );
    end generate;

    DMA_WR_MFB_DATA    <= wr_data(STAGES);
    DMA_WR_MFB_META    <= wr_meta(STAGES);
    DMA_WR_MFB_SOF     <= wr_sof(STAGES);
    DMA_WR_MFB_EOF     <= wr_eof(STAGES);
    DMA_WR_MFB_SOF_POS <= wr_sof_pos(STAGES);
    DMA_WR_MFB_EOF_POS <= wr_eof_pos(STAGES);
    DMA_WR_MFB_SRC_RDY <= wr_src_rdy(STAGES);
    wr_dst_rdy(STAGES) <= DMA_WR_MFB_DST_RDY;

end architecture;
