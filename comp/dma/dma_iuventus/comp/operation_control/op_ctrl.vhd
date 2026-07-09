-- op_ctrl.vhd: Processes the required read/write operations received from the user logic.and
-- handles completion of them
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.nvme_meta_pack.all;

entity OP_CTRL is
    generic (
        BUFF_PTR_WIDTH : positive := 17;
        -- Amount of tags/Command Identifiers available for outstanding NVMe commands
        QUEUE_DEPTH    : positive := 16;
        -- Number of pages a WRITE command reserves in the RDBUFF at frame start (its actual
        -- size is only known at EOF, once the frame length has been measured). The default
        -- reserves the whole buffer, so k is always 0 and writes stay one-at-a-time -- this
        -- matches the historical (pre-allocator) behavior. READs, whose size is known at
        -- admission, always allocate their exact page count and can be multiple-outstanding.
        MAX_WR_PAGES   : positive := 32;
        DEVICE         : string  := "ULTRASCALE"
    );
    port (
        CLK          : in std_logic;
        RST          : in std_logic;
        CMD_DISP_RST : out std_logic;

        -- =========================================================================================
        -- Start/stop interface
        -- =========================================================================================
        START_REQ_VLD : in  std_logic;
        START_REQ_ACK : out std_logic;
        STOP_REQ_VLD  : in  std_logic;
        STOP_REQ_ACK  : out std_logic;

        -- =========================================================================================
        -- Inputs from the software manager
        --
        -- Have to be all set to valid values when read requsts are sent
        -- =========================================================================================
        LBA_NUM_MASK        : in std_logic_vector(15 downto 0);
        LBA_SPACE_SIZE      : in std_logic_vector(63 downto 0);
        RDBUFF_BADDR        : in std_logic_vector(63 downto 0);
        RDBUFF_PRP_LIST_PTR : in std_logic_vector(63 downto 0);
        WRBUFF_BADDR        : in std_logic_vector(63 downto 0);
        WRBUFF_PRP_LIST_PTR : in std_logic_vector(63 downto 0);

        -- =========================================================================================
        -- Interface from user logic
        -- =========================================================================================
        -- 0-based number (i.e. 0 means 1 LBA will be read)
        NVME_RD_REQ_LBA_NUM : in  std_logic_vector(7 downto 0);
        NVME_RD_REQ_LBA_PTR : in  std_logic_vector(63 downto 0);
        NVME_RD_REQ_VLD     : in  std_logic;
        NVME_RD_REQ_RDY     : out std_logic;

        -- =========================================================================================
        -- Outputs to the operation status reporter
        -- =========================================================================================
        OP_STAT_TYPE : out std_logic; -- '0' for write, '1' for read
        OP_STAT_CODE : out std_logic_vector(1 downto 0);
        OP_STAT_VLD  : out std_logic;

        -- =========================================================================================
        -- Read interface to write buffer when NVMe read command is finished
        -- =========================================================================================
        WRBUFF_RD_REQ_ADDR : out std_logic_vector(BUFF_PTR_WIDTH -1 downto 0);
        WRBUFF_RD_REQ_SIZE : out std_logic_vector(BUFF_PTR_WIDTH downto 0);
        WRBUFF_RD_REQ_LAST : out std_logic;
        WRBUFF_RD_REQ_EN   : out std_logic;
        WRBUFF_RD_REQ_ACK  : in  std_logic;
        WRBUFF_RD_REQ_FNS  : in  std_logic;

        -- =========================================================================================
        -- Completion status from the CQE processor
        -- =========================================================================================
        CQP_CQE_SC_TYPE   : in std_logic_vector(CQ_ENTRY_SC_TYPE_W -1 downto 0);
        CQP_CQE_STAT_CODE : in std_logic_vector(CQ_ENTRY_STAT_CODE_W -1 downto 0);
        CQP_CQE_VLD       : in std_logic;
        -- Command Identifier of the command being completed
        CQP_CQE_CID       : in std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);

        -- =========================================================================================
        -- Command Identifier assigned by the Command Dispatcher's tag manager to the command being
        -- dispatched, valid when DISP_CMD_ID_VLD is asserted
        -- =========================================================================================
        DISP_CMD_ID     : in std_logic_vector(15 downto 0);
        DISP_CMD_ID_VLD : in std_logic;

        -- =========================================================================================
        -- Interface to the command dispatcher in the C2N controller
        -- =========================================================================================
        C2N_TRIGG_DISP    : out std_logic;
        C2N_RDY_FOR_DISP  : in  std_logic;
        C2N_CMD_OPCODE    : out std_logic_vector(CMD_OPCODE_W -1 downto 0);
        C2N_PRP_ENTRY_1   : out std_logic_vector(63 downto 0);
        C2N_PRP_ENTRY_2   : out std_logic_vector(63 downto 0);
        C2N_START_LBA_PTR : out std_logic_vector(63 downto 0);
        C2N_LBA_NUM       : out std_logic_vector(15 downto 0);

        -- =========================================================================================
        -- Frame to write parameters (i.e. data for NVMe write command)
        -- =========================================================================================
        -- Valid wwhen NVME_WR_REQ_START pulses high
        NVME_WR_REQ_LBA_PTR       : in std_logic_vector(63 downto 0);
        NVME_WR_REQ_START         : in std_logic;
        NVME_WR_REQ_END           : in std_logic;
        -- Valid when NVME_WR_REQ_END pulses high
        NVME_WR_REQ_FRAME_LNG     : in std_logic_vector(BUFF_PTR_WIDTH downto 0);
        NVME_WR_REQ_FRAME_LNG_VLD : in std_logic;
        -- Backpressure to ensure that only one write request is processed at a time
        WR_MFB_DST_RDY            : out std_logic;

        -- =========================================================================================
        -- Page (within RDBUFF) reserved for the write currently in flight, held constant for the
        -- whole frame; multiply by 4096 to get the byte offset. With the default MAX_WR_PAGES this
        -- is always 0.
        -- =========================================================================================
        WR_BUFF_PAGE_ADDR : out std_logic_vector(BUFF_PTR_WIDTH -1 downto 0)
    );
end entity;

architecture FULL of OP_CTRL is
    -- Width of one-shot flush delay counter.
    -- Flush is dispatched after the counter wraps around (overflow).
    constant FLUSH_DELAY_CNTR_WIDTH : positive := 28;

    -- =============================================================================================
    -- Buffer/page geometry
    --
    -- Both RDBUFF and WRBUFF are 2**BUFF_PTR_WIDTH bytes large, split into 4096B pages.
    -- =============================================================================================
    constant BUFF_PAGES    : positive := 2**(BUFF_PTR_WIDTH -12);
    constant PAGE_IDX_W    : natural  := log2(BUFF_PAGES);
    -- Width of a page-count value (0 to BUFF_PAGES, inclusive)
    constant NPAGES_W      : natural  := PAGE_IDX_W + 1;
    -- Bits of byte-address within one page (log2(4096) = 12, always, by construction above)
    constant PAGE_OFFSET_W : natural  := BUFF_PTR_WIDTH - PAGE_IDX_W;
    constant CTX_IDX_W     : natural  := log2(QUEUE_DEPTH);

    -- =============================================================================================
    -- Per-CID context, written when a command is dispatched (DISP_CMD_ID_VLD) and consumed when it
    -- completes (CQP_CQE_VLD), so that completion processing does not depend on the issue FSM's
    -- current state (multiple reads can be outstanding at once).
    -- =============================================================================================
    type ctx_entry_t is record
        op_type    : std_logic_vector(CMD_OPCODE_W -1 downto 0);
        lba_num    : std_logic_vector(7 downto 0);
        first_page : std_logic_vector(PAGE_IDX_W -1 downto 0);
        npages     : std_logic_vector(NPAGES_W -1 downto 0);
    end record;

    type ctx_array_t is array (0 to QUEUE_DEPTH -1) of ctx_entry_t;

    constant CTX_ENTRY_ZERO : ctx_entry_t := (
        op_type    => (others => '0'),
        lba_num    => (others => '0'),
        first_page => (others => '0'),
        npages     => (others => '0'));

    signal ctx_reg : ctx_array_t := (others => CTX_ENTRY_ZERO);

    -- nvc workaround-friendly helpers: whole-signal-in, whole-signal-out functions (kept as plain
    -- functions -- not generic packages -- so none of the known nvc 1.21.0 generic-package bugs
    -- apply here).
    function page_addr(base : std_logic_vector(63 downto 0); page_idx : std_logic_vector) return std_logic_vector is
    begin
        return std_logic_vector(unsigned(base) + shift_left(resize(unsigned(page_idx), 64), PAGE_OFFSET_W));
    end function;

    function prpl_entry_addr(base : std_logic_vector(63 downto 0); page_idx : std_logic_vector) return std_logic_vector is
    begin
        -- One PRP list entry is 8 bytes wide
        return std_logic_vector(unsigned(base) + shift_left(resize(unsigned(page_idx), 64), 3));
    end function;

    type   op_state_t is (
        S_IDLE, S_RD_REQ_PREPARE,
        S_WR_REQ_FINISH_WAIT, S_WR_REQ_PREPARE, S_WR_REQ_SIZE_WAIT,
        S_OP_CHECK, S_FLUSH_REQ_PREPARE
    );
    signal op_state_pst : op_state_t := S_IDLE;
    signal op_state_nst : op_state_t := S_IDLE;

    signal lba_num_reg        : std_logic_vector(7 downto 0);
    signal lba_num_next       : std_logic_vector(7 downto 0);
    signal start_lba_ptr_reg  : std_logic_vector(63 downto 0);
    signal start_lba_ptr_next : std_logic_vector(63 downto 0);
    signal op_type_reg        : std_logic_vector(CMD_OPCODE_W -1 downto 0);
    signal op_type_next       : std_logic_vector(CMD_OPCODE_W -1 downto 0);
    signal comp_enabled       : std_logic;

    -- Page reserved for the write currently being admitted/in flight, captured at SOF acceptance
    -- and held for the whole frame (PRP computation happens later, at EOF).
    signal k_wr_reg  : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal k_wr_next : std_logic_vector(PAGE_IDX_W -1 downto 0);

    signal flush_delay_cnt_reg         : unsigned(FLUSH_DELAY_CNTR_WIDTH -1 downto 0);
    signal flush_delay_cnt_next        : unsigned(FLUSH_DELAY_CNTR_WIDTH -1 downto 0);
    -- Counter enable/arm flag: when '1' counter increments every cycle;
    -- after overflow it is cleared to stop counting until next write arms it again.
    signal flush_delay_cnt_active_reg  : std_logic;
    signal flush_delay_cnt_active_next : std_logic;
    -- Pending FLUSH request flag set by counter overflow.
    -- Consumed in S_IDLE to enter S_FLUSH_REQ_PREPARE and then cleared.
    signal flush_dispatch_reg          : std_logic;
    signal flush_dispatch_next         : std_logic;

    -- =============================================================================================
    -- Page allocators: rd_alloc hands out WRBUFF pages to READ commands (exact size, so reads can
    -- be multiple-outstanding); wr_alloc hands out RDBUFF pages to WRITE commands (always
    -- MAX_WR_PAGES, so k is constant and writes stay serialized by construction).
    -- =============================================================================================
    signal rd_alloc_req_npages : std_logic_vector(NPAGES_W -1 downto 0);
    signal rd_alloc_req_vld    : std_logic;
    signal rd_alloc_grant      : std_logic;
    signal rd_alloc_page       : std_logic_vector(PAGE_IDX_W -1 downto 0);
    -- Final FREE_* driven into rd_alloc_i, merged (below, near its instantiation) from the two
    -- independent sources that can free a READ's pages -- see cqe_rd_free_* and drain_rd_free_*.
    signal rd_free_page        : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal rd_free_npages      : std_logic_vector(NPAGES_W -1 downto 0);
    signal rd_free_vld         : std_logic;
    signal rd_pages_free       : std_logic_vector(NPAGES_W -1 downto 0);

    -- Source 1: an unsuccessful READ completion never drains (no WRBUFF read is issued for it),
    -- so its pages are freed immediately at CQE time (driven in op_state_comb_p).
    signal cqe_rd_free_page    : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal cqe_rd_free_npages  : std_logic_vector(NPAGES_W -1 downto 0);
    signal cqe_rd_free_vld     : std_logic;

    -- Source 2: a successful READ's pages are freed once its WRBUFF-read drain has finished
    -- (driven in wrbuff_drain_comb_p) -- see the HAZARD note near the completion process below.
    signal drain_rd_free_page   : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal drain_rd_free_npages : std_logic_vector(NPAGES_W -1 downto 0);
    signal drain_rd_free_vld    : std_logic;

    signal wr_alloc_req_npages : std_logic_vector(NPAGES_W -1 downto 0);
    signal wr_alloc_req_vld    : std_logic;
    signal wr_alloc_grant      : std_logic;
    signal wr_alloc_page       : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal wr_free_page        : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal wr_free_npages      : std_logic_vector(NPAGES_W -1 downto 0);
    signal wr_free_vld         : std_logic;
    signal wr_pages_free       : std_logic_vector(NPAGES_W -1 downto 0);

    -- Combinational context to be committed into ctx_reg on the next DISP_CMD_ID_VLD pulse.
    signal ctx_in_op_type    : std_logic_vector(CMD_OPCODE_W -1 downto 0);
    signal ctx_in_lba_num    : std_logic_vector(7 downto 0);
    signal ctx_in_first_page : std_logic_vector(PAGE_IDX_W -1 downto 0);
    signal ctx_in_npages     : std_logic_vector(NPAGES_W -1 downto 0);

    -- =============================================================================================
    -- Queue of finished READs waiting to have their data drained out of WRBUFF. Decoupled from the
    -- completion process so that completions themselves never have to block.
    -- =============================================================================================
    constant RD_CPL_FIFO_DW : natural := PAGE_IDX_W + 8;
    signal rd_cpl_fifo_din   : std_logic_vector(RD_CPL_FIFO_DW -1 downto 0);
    signal rd_cpl_fifo_wr    : std_logic;
    signal rd_cpl_fifo_full  : std_logic;
    signal rd_cpl_fifo_do    : std_logic_vector(RD_CPL_FIFO_DW -1 downto 0);
    signal rd_cpl_fifo_rd    : std_logic;
    signal rd_cpl_fifo_empty : std_logic;

    type wrbuff_drain_state_t is (S_DRAIN_REQ, S_DRAIN_WAIT);
    signal wrbuff_drain_state_pst : wrbuff_drain_state_t := S_DRAIN_REQ;
    signal wrbuff_drain_state_nst : wrbuff_drain_state_t;

    signal wrbuff_rd_req_addr_piped : std_logic_vector(BUFF_PTR_WIDTH -1 downto 0);
    signal wrbuff_rd_req_size_piped : std_logic_vector(BUFF_PTR_WIDTH downto 0);
    signal wrbuff_rd_req_last_piped : std_logic;
    signal wrbuff_rd_req_en_piped   : std_logic;
    signal wrbuff_rd_req_ack_piped  : std_logic;
    signal pipe_out_data            : std_logic_vector(2*BUFF_PTR_WIDTH+2 -1 downto 0);
begin
    assert (MAX_WR_PAGES <= BUFF_PAGES)
        report "OP_CTRL: MAX_WR_PAGES cannot exceed the number of pages in the buffer"
        severity FAILURE;

    -- =============================================================================================
    -- Start/stop logic
    --
    -- STOP is only acknowledged once both allocators report every page free, i.e. no command is
    -- outstanding.
    -- =============================================================================================
    start_stop_fsm_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                comp_enabled   <= '0';
                START_REQ_ACK  <= '0';
                STOP_REQ_ACK   <= '0';
                CMD_DISP_RST   <= '0';
            else
                START_REQ_ACK <= '0';
                STOP_REQ_ACK  <= '0';
                CMD_DISP_RST  <= '0';

                if (START_REQ_VLD = '1') then
                    comp_enabled  <= '1';
                    START_REQ_ACK <= '1';
                    CMD_DISP_RST  <= '1';

                elsif (STOP_REQ_VLD = '1'
                       and rd_pages_free = std_logic_vector(to_unsigned(BUFF_PAGES, NPAGES_W))
                       and wr_pages_free = std_logic_vector(to_unsigned(BUFF_PAGES, NPAGES_W))) then
                    comp_enabled  <= '0';
                    STOP_REQ_ACK  <= '1';
                end if;
            end if;
        end if;
    end process;

    -- ===============================================================================================
    -- Operation issue state machine
    --
    -- Issue and completion are decoupled: a READ is admitted, allocated a page and dispatched, and
    -- the FSM returns straight to S_IDLE without waiting for its CQE, so multiple READs can be
    -- outstanding at once. WRITEs still reserve MAX_WR_PAGES (the whole buffer by default) at SOF,
    -- so they remain one-at-a-time by construction.
    -- ===============================================================================================
    op_state_reg_p : process (CLK)
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                op_state_pst               <= S_IDLE;
                lba_num_reg                <= (others => '0');
                start_lba_ptr_reg          <= (others => '0');
                op_type_reg                <= (others => '0');
                k_wr_reg                   <= (others => '0');
                flush_delay_cnt_reg        <= (others => '0');
                flush_delay_cnt_active_reg <= '0';
                flush_dispatch_reg         <= '0';
            else
                op_state_pst               <= op_state_nst;
                lba_num_reg                <= lba_num_next;
                start_lba_ptr_reg          <= start_lba_ptr_next;
                op_type_reg                <= op_type_next;
                k_wr_reg                   <= k_wr_next;
                flush_delay_cnt_reg        <= flush_delay_cnt_next;
                flush_delay_cnt_active_reg <= flush_delay_cnt_active_next;
                flush_dispatch_reg         <= flush_dispatch_next;
            end if;
        end if;
    end process;

    op_state_comb_p : process (all)
        variable lba_num_temp : unsigned(LBA_SPACE_SIZE'length -1 downto 0);
        -- Number of pages needed by the read currently registered: ceil((lba_num_reg+1)/8)
        variable lba_cnt_v    : unsigned(8 downto 0);
        variable npages_v     : unsigned(NPAGES_W -1 downto 0);
        -- Context of the command completing this cycle (looked up from CQP_CQE_CID)
        variable cqe_idx_v    : natural range 0 to QUEUE_DEPTH -1;
        variable cqe_ctx_v    : ctx_entry_t;
    begin
        op_state_nst                <= op_state_pst;
        lba_num_next                <= lba_num_reg;
        start_lba_ptr_next          <= start_lba_ptr_reg;
        op_type_next                <= op_type_reg;
        k_wr_next                   <= k_wr_reg;
        flush_delay_cnt_next        <= flush_delay_cnt_reg;
        flush_delay_cnt_active_next <= flush_delay_cnt_active_reg;
        flush_dispatch_next         <= flush_dispatch_reg;

        C2N_TRIGG_DISP     <= '0';
        C2N_CMD_OPCODE     <= RD_CMD_OPCODE; -- READ operation by default
        C2N_PRP_ENTRY_1    <= WRBUFF_BADDR;
        C2N_PRP_ENTRY_2    <= WRBUFF_PRP_LIST_PTR;
        C2N_START_LBA_PTR  <= start_lba_ptr_reg;
        C2N_LBA_NUM        <= "00000000" & lba_num_reg;

        OP_STAT_TYPE       <= '1'; -- READ operation by default;
        OP_STAT_CODE       <= "01"; -- FAILURE by default
        OP_STAT_VLD        <= '0';

        NVME_RD_REQ_RDY    <= '0';
        WR_MFB_DST_RDY     <= '0';

        rd_alloc_req_npages <= (others => '0');
        rd_alloc_req_vld    <= '0';
        wr_alloc_req_vld    <= '0';

        cqe_rd_free_page   <= (others => '0');
        cqe_rd_free_npages <= (others => '0');
        cqe_rd_free_vld    <= '0';
        wr_free_page       <= (others => '0');
        wr_free_npages     <= (others => '0');
        wr_free_vld        <= '0';

        rd_cpl_fifo_din <= (others => '0');
        rd_cpl_fifo_wr  <= '0';

        ctx_in_op_type    <= (others => '0');
        ctx_in_lba_num    <= (others => '0');
        ctx_in_first_page <= (others => '0');
        ctx_in_npages     <= (others => '0');

        lba_cnt_v := resize(unsigned(lba_num_reg), lba_cnt_v'length) + 1;
        npages_v  := resize((lba_cnt_v + 7) / 8, NPAGES_W);

        if (flush_delay_cnt_active_reg = '1') then
            flush_delay_cnt_next <= flush_delay_cnt_reg + 1;

            if ((flush_delay_cnt_reg + 1) = to_unsigned(0, flush_delay_cnt_reg'length)) then
                flush_delay_cnt_active_next <= '0';
                flush_dispatch_next         <= '1';
            end if;
        end if;

        -- =========================================================================================
        -- Completion processing: always active (independent of the issue FSM's state) so that
        -- completions of outstanding reads never have to wait for the issue side to be idle.
        -- =========================================================================================
        if (CQP_CQE_VLD = '1') then
            cqe_idx_v := to_integer(unsigned(CQP_CQE_CID(CTX_IDX_W -1 downto 0)));
            cqe_ctx_v := ctx_reg(cqe_idx_v);

            OP_STAT_TYPE <= '1' when cqe_ctx_v.op_type = RD_CMD_OPCODE else '0';

            -- WRITE pages (RDBUFF) are always freed here at CQE time, regardless of
            -- success/failure -- there is no further consumer to wait for (unlike READ, a WRITE's
            -- data was already sent to the SSD before its CQE arrives), so freeing immediately
            -- does not risk any reuse-before-drain hazard.
            if (cqe_ctx_v.op_type = WR_CMD_OPCODE) then
                wr_free_page   <= cqe_ctx_v.first_page;
                wr_free_npages <= cqe_ctx_v.npages;
                wr_free_vld    <= '1';
            end if;

            if (CQP_CQE_SC_TYPE = SCT_GENERIC_CMD and CQP_CQE_STAT_CODE = SC_SUCCESS) then
                OP_STAT_CODE <= "00"; -- SUCCESS

                if (cqe_ctx_v.op_type = RD_CMD_OPCODE) then
                    OP_STAT_VLD <= '1';
                    -- HAZARD (resolved): a successful READ's WRBUFF pages must stay reserved in
                    -- rd_alloc until its data has actually been drained out over RD_MFB --
                    -- freeing them here (at CQE time) would let a later READ reuse a page whose
                    -- SSD peer-write could then clobber this read's not-yet-drained data under
                    -- RD_MFB backpressure. So rd_alloc is *not* freed here; the entry is only
                    -- pushed into rd_cpl_fifo, and the free happens once wrbuff_drain_comb_p
                    -- below observes WRBUFF_RD_REQ_FNS for this entry (see drain_rd_free_*).
                    rd_cpl_fifo_din <= cqe_ctx_v.first_page & cqe_ctx_v.lba_num;
                    rd_cpl_fifo_wr  <= '1';
                elsif (cqe_ctx_v.op_type = WR_CMD_OPCODE) then
                    OP_STAT_VLD                 <= '1';
                    flush_delay_cnt_next        <= (others => '0');
                    flush_delay_cnt_active_next <= '1';
                end if;
            else
                OP_STAT_CODE <= "01"; -- FAILURE
                OP_STAT_VLD  <= '1' when (cqe_ctx_v.op_type = RD_CMD_OPCODE or cqe_ctx_v.op_type = WR_CMD_OPCODE) else '0';

                -- An unsuccessful READ is never pushed into rd_cpl_fifo (no WRBUFF read will be
                -- issued for it, since there is no valid data to drain), so there is no drain to
                -- wait for -- free its pages immediately here instead.
                if (cqe_ctx_v.op_type = RD_CMD_OPCODE) then
                    cqe_rd_free_page   <= cqe_ctx_v.first_page;
                    cqe_rd_free_npages <= cqe_ctx_v.npages;
                    cqe_rd_free_vld    <= '1';
                end if;
            end if;
        end if;

        case op_state_pst is
            when S_IDLE =>
                -- TODO: Block read when write gets accepted and vice versa.
                if (comp_enabled = '1' and STOP_REQ_VLD = '0') then
                    if (flush_dispatch_reg = '1') then
                        op_state_nst        <= S_FLUSH_REQ_PREPARE;
                        flush_dispatch_next <= '0';
                        op_type_next        <= FLUSH_CMD_OPCODE;
                    else
                        NVME_RD_REQ_RDY <= '1';
                        -- Only accept a new write frame if its whole reservation fits; the read
                        -- side is gated later (in S_RD_REQ_PREPARE) since its size (and hence page
                        -- count) is not known until S_OP_CHECK/lba_num_reg are settled.
                        WR_MFB_DST_RDY  <= wr_alloc_grant;

                        -- Process write request with higher priority than read request
                        if (NVME_WR_REQ_START = '1' and wr_alloc_grant = '1'
                            and (NVME_RD_REQ_VLD = '0' or (NVME_RD_REQ_VLD = '1' and op_type_reg = RD_CMD_OPCODE))) then
                            start_lba_ptr_next <= NVME_WR_REQ_LBA_PTR;
                            op_type_next       <= WR_CMD_OPCODE;
                            NVME_RD_REQ_RDY    <= '0';
                            wr_alloc_req_vld   <= '1';
                            k_wr_next          <= wr_alloc_page;

                            if (NVME_WR_REQ_END = '1') then
                                op_state_nst <= S_WR_REQ_SIZE_WAIT;
                            else
                                op_state_nst <= S_WR_REQ_FINISH_WAIT;
                            end if;

                        elsif (NVME_RD_REQ_VLD = '1') then
                            op_state_nst       <= S_OP_CHECK;
                            lba_num_next       <= NVME_RD_REQ_LBA_NUM;
                            start_lba_ptr_next <= NVME_RD_REQ_LBA_PTR;
                            op_type_next       <= RD_CMD_OPCODE;
                            WR_MFB_DST_RDY     <= '0';
                        end if;
                    end if;
                end if;

            when S_OP_CHECK =>
                op_state_nst   <= S_RD_REQ_PREPARE;
                WR_MFB_DST_RDY <= '0';

                -- Check if the request does not exeed the LBA space size
                if ((resize(unsigned(start_lba_ptr_reg), LBA_SPACE_SIZE'length) + resize(unsigned(lba_num_reg), LBA_SPACE_SIZE'length) + 1) > unsigned(LBA_SPACE_SIZE)) then
                    op_state_nst <= S_IDLE;
                    OP_STAT_VLD  <= '1';
                    OP_STAT_TYPE <= '1';
                    OP_STAT_CODE <= "10"; -- LBA Out of Range
                end if;

            -- WARNING: The situation where a longer packet than the core is able to dispatch in a single command,
            -- arrives, the information of the length of the packet falls throuhg and the FSM stays in S_WR_REQ_SIZE_WAIT
            -- indefinitely. This is because the length is calculated earlier than the EOF of the packet.
            when S_WR_REQ_FINISH_WAIT =>
                WR_MFB_DST_RDY <= '1';

                if (NVME_WR_REQ_END = '1') then
                    op_state_nst <= S_WR_REQ_SIZE_WAIT;
                end if;

            when S_WR_REQ_SIZE_WAIT =>

                if (NVME_WR_REQ_FRAME_LNG_VLD = '1') then
                    -- Round the amount of LBAs up to include all of the packet's data
                    lba_num_temp       := resize(((unsigned(NVME_WR_REQ_FRAME_LNG) + 511) / 512) -1, LBA_SPACE_SIZE'length);

                    -- Check if the request does not exeed the LBA space size.
                    -- Use start_lba_ptr_reg (captured from NVME_WR_REQ_LBA_PTR in S_IDLE)
                    -- rather than the raw NVME_WR_REQ_LBA_PTR input, which is no longer
                    -- valid once WR_MFB_DST_RDY is deasserted after the SOF cycle.
                    if ((resize(unsigned(start_lba_ptr_reg), LBA_SPACE_SIZE'length) + lba_num_temp + 1) > unsigned(LBA_SPACE_SIZE)) then
                        op_state_nst <= S_IDLE;
                        OP_STAT_VLD  <= '1';
                        OP_STAT_TYPE <= '0';
                        OP_STAT_CODE <= "10"; -- LBA Out of Range

                        -- LEAK FIX: this write's MAX_WR_PAGES were already reserved from wr_alloc
                        -- back in S_IDLE (wr_alloc_req_vld, on SOF admission), before the frame
                        -- length -- and hence this OOR check -- could be evaluated. Since this
                        -- abort returns straight to S_IDLE without ever reaching S_WR_REQ_PREPARE,
                        -- no CID/ctx_reg entry is assigned and no SQE is dispatched, so no CQE will
                        -- ever arrive to free these pages via the completion process below. Without
                        -- this explicit free, the reservation is permanently lost: with the default
                        -- MAX_WR_PAGES = BUFF_PAGES, wr_pages_free sticks at 0 forever, wr_alloc_grant
                        -- never asserts again, and WR_MFB_DST_RDY (gated on wr_alloc_grant in S_IDLE)
                        -- stays low forever -- a permanent write-side wedge after exactly one
                        -- out-of-range write.
                        wr_free_page   <= k_wr_reg;
                        wr_free_npages <= std_logic_vector(to_unsigned(MAX_WR_PAGES, NPAGES_W));
                        wr_free_vld    <= '1';
                    else
                        lba_num_next       <= std_logic_vector(lba_num_temp(lba_num_next'length -1 downto 0));
                        op_state_nst       <= S_WR_REQ_PREPARE;
                    end if;
                end if;

            when S_WR_REQ_PREPARE =>
                C2N_TRIGG_DISP  <= '1';
                C2N_CMD_OPCODE  <= WR_CMD_OPCODE;
                C2N_PRP_ENTRY_1 <= page_addr(RDBUFF_BADDR, k_wr_reg);
                WR_MFB_DST_RDY  <= '0';

                -- If the the size of a request fits into 2 pages, then PRP_ENTRY_2 should point to
                -- a page and not to the PRP list
                -- WARNING: If this would not be adhered to, the transfer would overwrite the PRP list
                -- in the host memory.
                if (unsigned(lba_num_reg) > 7 and unsigned (lba_num_reg) < 16) then
                    C2N_PRP_ENTRY_2 <= page_addr(RDBUFF_BADDR, std_logic_vector(unsigned(k_wr_reg) + 1));
                elsif (unsigned(lba_num_reg) <= 7) then
                    C2N_PRP_ENTRY_2 <= (others => '0');
                else
                    C2N_PRP_ENTRY_2 <= prpl_entry_addr(RDBUFF_PRP_LIST_PTR, k_wr_reg);
                end if;

                if (C2N_RDY_FOR_DISP = '1') then
                    op_state_nst <= S_IDLE;

                    ctx_in_op_type    <= WR_CMD_OPCODE;
                    ctx_in_lba_num    <= lba_num_reg;
                    ctx_in_first_page <= k_wr_reg;
                    ctx_in_npages     <= std_logic_vector(to_unsigned(MAX_WR_PAGES, NPAGES_W));
                end if;

            when S_FLUSH_REQ_PREPARE =>
                C2N_TRIGG_DISP      <= '1';
                C2N_CMD_OPCODE      <= FLUSH_CMD_OPCODE;
                C2N_PRP_ENTRY_1     <= (others => '0');
                C2N_PRP_ENTRY_2     <= (others => '0');
                C2N_START_LBA_PTR   <= (others => '0');
                C2N_LBA_NUM         <= (others => '0');
                WR_MFB_DST_RDY      <= '0';

                if (C2N_RDY_FOR_DISP = '1') then
                    op_state_nst <= S_IDLE;

                    -- FLUSH holds no buffer pages; keep the ctx entry harmless (its op_type never
                    -- matches RD/WR so completion processing skips it).
                    ctx_in_op_type    <= FLUSH_CMD_OPCODE;
                    ctx_in_lba_num    <= (others => '0');
                    ctx_in_first_page <= (others => '0');
                    ctx_in_npages     <= (others => '0');
                end if;

            when S_RD_REQ_PREPARE =>
                WR_MFB_DST_RDY <= '0';

                rd_alloc_req_npages <= std_logic_vector(npages_v);
                -- Only actually trigger the dispatch once the allocator can grant the needed pages
                C2N_TRIGG_DISP <= rd_alloc_grant;

                C2N_PRP_ENTRY_1 <= page_addr(WRBUFF_BADDR, rd_alloc_page);

                -- If the the size of a request fits into 2 pages, then PRP_ENTRY_2 should point to
                -- a page and not to the PRP list
                -- WARNING: If this would not be adhered to, the transfer would overwrite the PRP list
                -- in the host memory.
                if (unsigned(lba_num_reg) > 7 and unsigned (lba_num_reg) < 16) then
                    C2N_PRP_ENTRY_2 <= page_addr(WRBUFF_BADDR, std_logic_vector(unsigned(rd_alloc_page) + 1));
                elsif (unsigned(lba_num_reg) <= 7) then
                    C2N_PRP_ENTRY_2 <= (others => '0');
                else
                    C2N_PRP_ENTRY_2 <= prpl_entry_addr(WRBUFF_PRP_LIST_PTR, rd_alloc_page);
                end if;

                if (rd_alloc_grant = '1' and C2N_RDY_FOR_DISP = '1') then
                    op_state_nst <= S_IDLE;

                    rd_alloc_req_vld <= '1';

                    ctx_in_op_type    <= RD_CMD_OPCODE;
                    ctx_in_lba_num    <= lba_num_reg;
                    ctx_in_first_page <= rd_alloc_page;
                    ctx_in_npages     <= std_logic_vector(npages_v);
                end if;
        end case;
    end process;

    -- =============================================================================================
    -- Per-CID context table: written once per dispatched command (whatever ctx_in_* holds at the
    -- dispatch pulse), read back at completion time.
    -- =============================================================================================
    ctx_table_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (DISP_CMD_ID_VLD = '1') then
                ctx_reg(to_integer(unsigned(DISP_CMD_ID(CTX_IDX_W -1 downto 0)))) <= (
                    op_type    => ctx_in_op_type,
                    lba_num    => ctx_in_lba_num,
                    first_page => ctx_in_first_page,
                    npages     => ctx_in_npages);
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Page allocators
    -- =============================================================================================
    wr_alloc_req_npages <= std_logic_vector(to_unsigned(MAX_WR_PAGES, NPAGES_W));

    WR_BUFF_PAGE_ADDR <= k_wr_reg & (PAGE_OFFSET_W -1 downto 0 => '0');

    -- Merge the two independent sources that can free rd_alloc pages: an unsuccessful READ,
    -- freed immediately at CQE time (cqe_rd_free_*, no drain will ever happen for it), and a
    -- successful READ, freed once its WRBUFF-read drain completes (drain_rd_free_*, see
    -- wrbuff_drain_comb_p below). The allocator only accepts one FREE_* per cycle; since only
    -- successful READs are ever pushed into rd_cpl_fifo (drained pages are disjoint from ones a
    -- failed CQE can free), a collision between the two would need an unsuccessful CQE and a
    -- drain completion on the very same cycle -- not exercised by this CQE model (always
    -- success), so drain-time free is simply given priority if this were ever to occur.
    rd_free_vld    <= drain_rd_free_vld or cqe_rd_free_vld;
    rd_free_page   <= drain_rd_free_page   when drain_rd_free_vld = '1' else cqe_rd_free_page;
    rd_free_npages <= drain_rd_free_npages when drain_rd_free_vld = '1' else cqe_rd_free_npages;

    rd_alloc_i : entity work.IUVENTUS_PAGE_ALLOCATOR
        generic map (
            PAGES => BUFF_PAGES)
        port map (
            CLK => CLK,
            RST => RST,

            ALLOC_REQ_NPAGES => rd_alloc_req_npages,
            ALLOC_REQ_VLD    => rd_alloc_req_vld,
            ALLOC_GRANT      => rd_alloc_grant,
            ALLOC_PAGE       => rd_alloc_page,

            FREE_PAGE   => rd_free_page,
            FREE_NPAGES => rd_free_npages,
            FREE_VLD    => rd_free_vld,

            PAGES_FREE  => rd_pages_free);

    wr_alloc_i : entity work.IUVENTUS_PAGE_ALLOCATOR
        generic map (
            PAGES => BUFF_PAGES)
        port map (
            CLK => CLK,
            RST => RST,

            ALLOC_REQ_NPAGES => wr_alloc_req_npages,
            ALLOC_REQ_VLD    => wr_alloc_req_vld,
            ALLOC_GRANT      => wr_alloc_grant,
            ALLOC_PAGE       => wr_alloc_page,

            FREE_PAGE   => wr_free_page,
            FREE_NPAGES => wr_free_npages,
            FREE_VLD    => wr_free_vld,

            PAGES_FREE  => wr_pages_free);

    -- =============================================================================================
    -- Finished-read queue and WRBUFF drain machinery: independent of the issue/completion logic
    -- above, so a slow/backpressured drain never blocks new completions from being processed.
    -- =============================================================================================
    -- Depth must cover the worst case of reads that are completed (CQE arrived, CID already
    -- recycled) but not yet drained -- each still holds >=1 WRBUFF page, so at most BUFF_PAGES
    -- such reads can coexist. Sizing this to QUEUE_DEPTH (16) instead of BUFF_PAGES (32) let small
    -- 1-page reads overflow it under load: a dropped entry leaks its pages, rd_alloc eventually
    -- can never grant, and the issue FSM parks in S_RD_REQ_PREPARE forever (the wrap_collision
    -- stall). BUFF_PAGES makes overflow impossible by construction.
    rd_cpl_fifo_i : entity work.FIFOX
        generic map (
            DATA_WIDTH => RD_CPL_FIFO_DW,
            ITEMS      => BUFF_PAGES,
            RAM_TYPE   => "AUTO",
            DEVICE     => DEVICE)
        port map (
            CLK   => CLK,
            RESET => RST,

            DI     => rd_cpl_fifo_din,
            WR     => rd_cpl_fifo_wr,
            FULL   => rd_cpl_fifo_full,
            AFULL  => open,
            STATUS => open,

            DO     => rd_cpl_fifo_do,
            RD     => rd_cpl_fifo_rd,
            EMPTY  => rd_cpl_fifo_empty,
            AEMPTY => open);

    wrbuff_drain_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                wrbuff_drain_state_pst <= S_DRAIN_REQ;
            else
                wrbuff_drain_state_pst <= wrbuff_drain_state_nst;
            end if;
        end if;
    end process;

    wrbuff_drain_comb_p : process (all) is
        -- Number of pages held by the entry currently draining: ceil((lba_num+1)/8), computed
        -- from the lba_num carried alongside first_page in rd_cpl_fifo (same formula as
        -- op_state_comb_p's npages_v).
        variable lba_cnt_v : unsigned(8 downto 0);
        variable npages_v  : unsigned(NPAGES_W -1 downto 0);
    begin
        wrbuff_drain_state_nst <= wrbuff_drain_state_pst;

        rd_cpl_fifo_rd <= '0';

        wrbuff_rd_req_addr_piped <= (others => '0');
        wrbuff_rd_req_size_piped <= (others => '0');
        wrbuff_rd_req_last_piped <= '1';
        wrbuff_rd_req_en_piped   <= '0';

        drain_rd_free_page   <= (others => '0');
        drain_rd_free_npages <= (others => '0');
        drain_rd_free_vld    <= '0';

        lba_cnt_v := resize(unsigned(rd_cpl_fifo_do(7 downto 0)), lba_cnt_v'length) + 1;
        npages_v  := resize((lba_cnt_v + 7) / 8, NPAGES_W);

        case wrbuff_drain_state_pst is
            when S_DRAIN_REQ =>
                if (rd_cpl_fifo_empty = '0') then
                    wrbuff_rd_req_addr_piped <= std_logic_vector(
                        unsigned(WRBUFF_BADDR(BUFF_PTR_WIDTH -1 downto 0)) +
                        shift_left(resize(unsigned(rd_cpl_fifo_do(RD_CPL_FIFO_DW -1 downto 8)), BUFF_PTR_WIDTH), PAGE_OFFSET_W));
                    wrbuff_rd_req_size_piped <= std_logic_vector(unsigned('0' & rd_cpl_fifo_do(7 downto 0)) + 1) & "000000000"; -- multiply by 512
                    wrbuff_rd_req_en_piped   <= '1';

                    if (wrbuff_rd_req_ack_piped = '1') then
                        wrbuff_drain_state_nst <= S_DRAIN_WAIT;
                    end if;
                end if;

            when S_DRAIN_WAIT =>
                if (WRBUFF_RD_REQ_FNS = '1') then
                    -- Advance the FIFO to the next completed read only once this one has been
                    -- fully delivered on the (single, shared) RD_MFB bus.
                    rd_cpl_fifo_rd         <= '1';
                    wrbuff_drain_state_nst <= S_DRAIN_REQ;

                    -- Only now -- once the drain has actually delivered this read's data -- is it
                    -- safe to return its WRBUFF pages to rd_alloc; see the HAZARD note in
                    -- op_state_comb_p's completion process.
                    drain_rd_free_page   <= rd_cpl_fifo_do(RD_CPL_FIFO_DW -1 downto 8);
                    drain_rd_free_npages <= std_logic_vector(npages_v);
                    drain_rd_free_vld    <= '1';
                end if;
        end case;
    end process;

    wrbuff_rd_req_pipe_i : entity work.MVB_PIPE
    generic map (
        ITEMS       => 1,
        ITEM_WIDTH  => pipe_out_data'length,
        OPT         => "REG",
        USE_DST_RDY => TRUE,
        FAKE_PIPE   => FALSE,
        DEVICE      => DEVICE
    )
    port map (
        CLK   => CLK,
        RESET => RST,

        RX_DATA    => wrbuff_rd_req_addr_piped & wrbuff_rd_req_size_piped & wrbuff_rd_req_last_piped,
        RX_VLD     => (others => '1'),
        RX_SRC_RDY => wrbuff_rd_req_en_piped,
        RX_DST_RDY => wrbuff_rd_req_ack_piped,

        TX_DATA    => pipe_out_data,
        TX_VLD     => open,
        TX_SRC_RDY => WRBUFF_RD_REQ_EN,
        TX_DST_RDY => WRBUFF_RD_REQ_ACK
    );

    (WRBUFF_RD_REQ_ADDR, WRBUFF_RD_REQ_SIZE, WRBUFF_RD_REQ_LAST) <= pipe_out_data;
end architecture;
