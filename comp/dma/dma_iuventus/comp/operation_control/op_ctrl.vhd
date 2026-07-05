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

use work.nvme_meta_pack.all;

entity OP_CTRL is
    generic (
        BUFF_PTR_WIDTH : positive := 17;
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
        WR_MFB_DST_RDY            : out std_logic
    );
end entity;

architecture FULL of OP_CTRL is
    -- Width of one-shot flush delay counter.
    -- Flush is dispatched after the counter wraps around (overflow).
    constant FLUSH_DELAY_CNTR_WIDTH : positive := 28;

    type   op_state_t is (
        S_IDLE, S_RD_REQ_PREPARE, S_WAIT_CQE, S_WRBUFF_READ,
        S_WR_REQ_FINISH_WAIT, S_WR_REQ_PREPARE, S_WR_REQ_SIZE_WAIT,
        S_OP_CHECK, S_WRBUFF_FINISH_WAIT, S_FLUSH_REQ_PREPARE
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

    signal wrbuff_rd_req_addr_piped : std_logic_vector(BUFF_PTR_WIDTH -1 downto 0);
    signal wrbuff_rd_req_size_piped : std_logic_vector(BUFF_PTR_WIDTH downto 0);
    signal wrbuff_rd_req_last_piped : std_logic;
    signal wrbuff_rd_req_en_piped   : std_logic;
    signal wrbuff_rd_req_ack_piped  : std_logic;
    signal pipe_out_data            : std_logic_vector(2*BUFF_PTR_WIDTH+2 -1 downto 0);
begin
    -- =============================================================================================
    -- Start/stop logic
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

                -- TODO: Prohibit stop when outstanding request extist. This implies that this component
                -- has to be turned off before CQE processror
                elsif (STOP_REQ_VLD = '1') then
                    comp_enabled  <= '0';
                    STOP_REQ_ACK  <= '1';
                end if;
            end if;
        end if;
    end process;

    -- ===============================================================================================
    -- Operation control state machine
    -- ===============================================================================================
    op_state_reg_p : process (CLK)
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                op_state_pst               <= S_IDLE;
                lba_num_reg                <= (others => '0');
                start_lba_ptr_reg          <= (others => '0');
                op_type_reg                <= (others => '0');
                flush_delay_cnt_reg        <= (others => '0');
                flush_delay_cnt_active_reg <= '0';
                flush_dispatch_reg         <= '0';
            else
                op_state_pst               <= op_state_nst;
                lba_num_reg                <= lba_num_next;
                start_lba_ptr_reg          <= start_lba_ptr_next;
                op_type_reg                <= op_type_next;
                flush_delay_cnt_reg        <= flush_delay_cnt_next;
                flush_delay_cnt_active_reg <= flush_delay_cnt_active_next;
                flush_dispatch_reg         <= flush_dispatch_next;
            end if;
        end if;
    end process;

    op_state_comb_p : process (all)
        variable lba_num_temp : unsigned(LBA_SPACE_SIZE'length -1 downto 0);
    begin
        op_state_nst                <= op_state_pst;
        lba_num_next                <= lba_num_reg;
        start_lba_ptr_next          <= start_lba_ptr_reg;
        op_type_next                <= op_type_reg;
        flush_delay_cnt_next        <= flush_delay_cnt_reg;
        flush_delay_cnt_active_next <= flush_delay_cnt_active_reg;
        flush_dispatch_next         <= flush_dispatch_reg;

        C2N_TRIGG_DISP     <= '0';
        C2N_CMD_OPCODE     <= RD_CMD_OPCODE; -- READ operation by default
        C2N_PRP_ENTRY_1    <= WRBUFF_BADDR;
        C2N_PRP_ENTRY_2    <= WRBUFF_PRP_LIST_PTR;
        C2N_START_LBA_PTR  <= start_lba_ptr_reg;
        C2N_LBA_NUM        <= "00000000" & lba_num_reg;

        wrbuff_rd_req_addr_piped <= (others => '0');
        wrbuff_rd_req_size_piped <= (others => '0');
        wrbuff_rd_req_last_piped <= '1';
        wrbuff_rd_req_en_piped   <= '0';

        OP_STAT_TYPE       <= '1'; -- READ operation by default;
        OP_STAT_CODE       <= "01"; -- FAILURE by default
        OP_STAT_VLD        <= '0';

        NVME_RD_REQ_RDY    <= '0';
        WR_MFB_DST_RDY     <= '0';

        if (flush_delay_cnt_active_reg = '1') then
            flush_delay_cnt_next <= flush_delay_cnt_reg + 1;

            if ((flush_delay_cnt_reg + 1) = to_unsigned(0, flush_delay_cnt_reg'length)) then
                flush_delay_cnt_active_next <= '0';
                flush_dispatch_next         <= '1';
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
                        WR_MFB_DST_RDY  <= '1';

                        -- Process write request with higher priority than read request
                        if (NVME_WR_REQ_START = '1' and (NVME_RD_REQ_VLD = '0' or (NVME_RD_REQ_VLD = '1' and op_type_reg = RD_CMD_OPCODE))) then
                            start_lba_ptr_next <= NVME_WR_REQ_LBA_PTR;
                            op_type_next       <= WR_CMD_OPCODE;
                            NVME_RD_REQ_RDY    <= '0';

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
                    else
                        lba_num_next       <= std_logic_vector(lba_num_temp(lba_num_next'length -1 downto 0));
                        op_state_nst       <= S_WR_REQ_PREPARE;
                    end if;
                end if;

            when S_WR_REQ_PREPARE =>
                C2N_TRIGG_DISP  <= '1';
                C2N_CMD_OPCODE  <= WR_CMD_OPCODE;
                C2N_PRP_ENTRY_1 <= RDBUFF_BADDR;
                C2N_PRP_ENTRY_2 <= RDBUFF_PRP_LIST_PTR;
                WR_MFB_DST_RDY  <= '0';

                -- If the the size of a request fits into 2 pages, then PRP_ENTRY_2 should point to
                -- a page and not to the PRP list
                -- WARNING: If this would not be adhered to, the transfer would overwrite the PRP list
                -- in the host memory.
                if (unsigned(lba_num_reg) > 7 and unsigned (lba_num_reg) < 16) then
                    C2N_PRP_ENTRY_2 <= std_logic_vector(unsigned(RDBUFF_BADDR) + 4096);
                elsif (unsigned(lba_num_reg) <= 7) then
                    C2N_PRP_ENTRY_2 <= (others => '0');
                end if;

                if (C2N_RDY_FOR_DISP = '1') then
                    op_state_nst <= S_WAIT_CQE;
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
                    op_state_nst <= S_WAIT_CQE;
                end if;

            when S_RD_REQ_PREPARE =>
                C2N_TRIGG_DISP <= '1';
                WR_MFB_DST_RDY <= '0';

                -- If the the size of a request fits into 2 pages, then PRP_ENTRY_2 should point to
                -- a page and not to the PRP list
                -- WARNING: If this would not be adhered to, the transfer would overwrite the PRP list
                -- in the host memory.
                if (unsigned(lba_num_reg) > 7 and unsigned (lba_num_reg) < 16) then
                    C2N_PRP_ENTRY_2 <= std_logic_vector(unsigned(WRBUFF_BADDR) + 4096);
                elsif (unsigned(lba_num_reg) <= 7) then
                    C2N_PRP_ENTRY_2 <= (others => '0');
                end if;

                if (C2N_RDY_FOR_DISP = '1') then
                    op_state_nst <= S_WAIT_CQE;
                end if;

            when S_WAIT_CQE =>
                WR_MFB_DST_RDY <= '0';

                if (CQP_CQE_VLD = '1') then
                    if (CQP_CQE_SC_TYPE = SCT_GENERIC_CMD and CQP_CQE_STAT_CODE = SC_SUCCESS) then
                        if (op_type_reg = RD_CMD_OPCODE) then
                            op_state_nst <= S_WRBUFF_READ;
                            OP_STAT_VLD  <= '1';
                        else
                            op_state_nst <= S_IDLE;

                            if (op_type_reg = WR_CMD_OPCODE) then
                                flush_delay_cnt_next        <= (others => '0');
                                flush_delay_cnt_active_next <= '1';
                                OP_STAT_VLD                 <= '1';
                            end if;
                        end if;

                        OP_STAT_TYPE <= '1' when op_type_reg = RD_CMD_OPCODE else '0';
                        OP_STAT_CODE <= "00"; -- SUCCESS
                    else
                        op_state_nst <= S_IDLE;
                        OP_STAT_TYPE <= '1' when op_type_reg = RD_CMD_OPCODE else '0';
                        OP_STAT_CODE <= "01"; -- FAILURE
                        OP_STAT_VLD  <= '1' when (op_type_reg = RD_CMD_OPCODE  or op_type_reg = WR_CMD_OPCODE) else '0';
                    end if;
                end if;

            when S_WRBUFF_READ =>
                wrbuff_rd_req_addr_piped <= WRBUFF_BADDR(BUFF_PTR_WIDTH -1 downto 0);
                wrbuff_rd_req_size_piped <= std_logic_vector(unsigned('0' & lba_num_reg) + 1) & "000000000"; -- multiply by 512
                wrbuff_rd_req_en_piped   <= '1';
                WR_MFB_DST_RDY           <= '0';

                if (wrbuff_rd_req_ack_piped = '1') then
                    op_state_nst <= S_WRBUFF_FINISH_WAIT;
                end if;

            when S_WRBUFF_FINISH_WAIT =>
                if (WRBUFF_RD_REQ_FNS = '1') then
                    op_state_nst <= S_IDLE;
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
