-- fs_regs.vhd: MI register file of the file shell, ring window and kernel argument forwarding
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.fs_pkg.all;

-- One MI access at a time: ARDY rises only when the access has completed (ring reads on their HBM
-- data, argument accesses on their AXI-Lite response), and DRDY follows a read's ARDY by one cycle.
entity FS_REGS is
    generic (
        STREAMS   : natural := FS_MAX_STREAMS;
        KERNEL_ID : natural := FS_KERNEL_DIGEST_FILL
    );
    port (
        CLK   : in    std_logic;
        RESET : in    std_logic;
        CLEAR : in    std_logic;

        -- ==============================
        -- MI slave, already on CLK
        -- ==============================
        MI_ADDR : in    std_logic_vector(31 downto 0);
        MI_DWR  : in    std_logic_vector(31 downto 0);
        MI_BE   : in    std_logic_vector(3 downto 0);
        MI_RD   : in    std_logic;
        MI_WR   : in    std_logic;
        MI_ARDY : out   std_logic;
        MI_DRD  : out   std_logic_vector(31 downto 0);
        MI_DRDY : out   std_logic;

        -- ==============================
        -- Control and configuration
        -- ==============================
        CTRL_START         : out   std_logic;
        CTRL_ABORT         : out   std_logic;
        CTRL_CLEAR         : out   std_logic;
        STREAM_MASK        : out   std_logic_vector(STREAMS-1 downto 0);
        STRIPE_LOG2_DRIVES : out   std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
        STRIPE_LOG2_CHUNK  : out   std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
        IN_TAIL            : out   slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        OUT_TAIL           : out   slv_array_t(STREAMS-1 downto 0)(31 downto 0);

        -- ==============================
        -- Status
        -- ==============================
        STATUS_BUSY   : in    std_logic;
        STATUS_DONE   : in    std_logic;
        STATUS_ERR    : in    std_logic;
        STATUS_STATE  : in    std_logic_vector(7 downto 0);
        IN_FILES      : in    slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        IN_HEAD       : in    slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        OUT_HEAD      : in    slv_array_t(STREAMS-1 downto 0)(31 downto 0);
        IN_BYTES      : in    slv_array_t(STREAMS-1 downto 0)(63 downto 0);
        OUT_BYTES     : in    slv_array_t(STREAMS-1 downto 0)(63 downto 0);
        STREAM_STATUS : in    slv_array_t(STREAMS-1 downto 0)(3 downto 0);
        ERR_INFO      : in    slv_array_t(STREAMS-1 downto 0)(31 downto 0);

        -- ==============================
        -- Ring window: single 32-bit accesses to FS_HBM_PORT
        -- ==============================
        RING_REQ_VLD    : out   std_logic;
        RING_REQ_WR     : out   std_logic;
        RING_REQ_ADDR   : out   std_logic_vector(FS_RING_HBM_ADDR_W-1 downto 0);
        RING_REQ_DATA   : out   std_logic_vector(31 downto 0);
        RING_REQ_BE     : out   std_logic_vector(3 downto 0);
        RING_REQ_RDY    : in    std_logic;
        RING_RSP_VLD    : in    std_logic;
        RING_RSP_DATA   : in    std_logic_vector(31 downto 0);
        RING_WR_PENDING : in    std_logic;

        -- ==============================
        -- Kernel arguments: AXI4-Lite master, address = MI offset - FS_ARGS_BASE
        -- ==============================
        ARG_AXIL_AWADDR  : out   std_logic_vector(FS_ARGS_WIN_W-1 downto 0);
        ARG_AXIL_AWVALID : out   std_logic;
        ARG_AXIL_AWREADY : in    std_logic;
        ARG_AXIL_WDATA   : out   std_logic_vector(31 downto 0);
        ARG_AXIL_WSTRB   : out   std_logic_vector(3 downto 0);
        ARG_AXIL_WVALID  : out   std_logic;
        ARG_AXIL_WREADY  : in    std_logic;
        ARG_AXIL_BRESP   : in    std_logic_vector(1 downto 0);
        ARG_AXIL_BVALID  : in    std_logic;
        ARG_AXIL_BREADY  : out   std_logic;
        ARG_AXIL_ARADDR  : out   std_logic_vector(FS_ARGS_WIN_W-1 downto 0);
        ARG_AXIL_ARVALID : out   std_logic;
        ARG_AXIL_ARREADY : in    std_logic;
        ARG_AXIL_RDATA   : in    std_logic_vector(31 downto 0);
        ARG_AXIL_RRESP   : in    std_logic_vector(1 downto 0);
        ARG_AXIL_RVALID  : in    std_logic;
        ARG_AXIL_RREADY  : out   std_logic
    );
end entity;

architecture FULL of FS_REGS is

    type region_t is (R_GLOBAL, R_STREAM, R_ARGS, R_RING, R_NONE);

    type state_t is (S_IDLE, S_DEC, S_EXEC, S_RING, S_RING_RSP, S_AXW, S_AXB, S_AXR, S_AXRD, S_ACK);

    constant STRIPE_RST_DRIVES : natural := 2;
    constant STRIPE_RST_CHUNK  : natural := 8;

    constant RING_DEPTHS_WORD : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(FS_OUT_RING_LOG2 * 256 + FS_IN_RING_LOG2, 32));

    signal state : state_t;

    signal req_addr : std_logic_vector(FS_MI_DECODE_W-1 downto 0);
    signal req_dwr  : std_logic_vector(31 downto 0);
    signal req_be   : std_logic_vector(3 downto 0);
    signal req_wr   : std_logic;

    signal dec_region : region_t;
    -- Word index inside the global block or inside one stream's block.
    signal dec_reg    : natural range 0 to 63;
    signal dec_stream : natural range 0 to FS_MAX_STREAMS-1;

    signal aw_done : std_logic;
    signal w_done  : std_logic;

    signal rd_data_r : std_logic_vector(31 downto 0);
    signal drdy_r    : std_logic;

    signal start_r       : std_logic;
    signal abort_r       : std_logic;
    signal clear_r       : std_logic;
    signal stream_mask_r : std_logic_vector(STREAMS-1 downto 0);
    signal drives_r      : std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
    signal chunk_r       : std_logic_vector(FS_STRIPE_LOG2_W-1 downto 0);
    signal in_tail_r     : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal out_tail_r    : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    -- High words latched by a read of the matching low word, so both halves come from one instant.
    signal in_bytes_hi_r  : slv_array_t(STREAMS-1 downto 0)(31 downto 0);
    signal out_bytes_hi_r : slv_array_t(STREAMS-1 downto 0)(31 downto 0);

    signal need_space : std_logic;
    signal glob_rd    : std_logic_vector(31 downto 0);
    signal strm_rd    : std_logic_vector(31 downto 0);
    signal is_tail_wr : std_logic;

    -- Stream index clipped into the arrays; dec_region already excludes the unbuilt streams.
    signal sidx : natural range 0 to STREAMS-1;

begin

    assert (STREAMS >= 1 and STREAMS <= FS_MAX_STREAMS)
        report "FS_REGS: STREAMS must be 1 to " & integer'image(FS_MAX_STREAMS) & "."
        severity FAILURE;

    -- =============================================================================================
    -- Access FSM
    -- =============================================================================================
    sidx <= dec_stream when (dec_stream < STREAMS) else 0;

    is_tail_wr <= '1' when (dec_region = R_STREAM and (dec_reg = FS_SREG_IN_TAIL / 4 or dec_reg = FS_SREG_OUT_TAIL / 4)) else
                  '0';

    fsm_p : process (CLK) is
        variable off_v : unsigned(9 downto 0);
    begin
        if (rising_edge(CLK)) then
            start_r <= '0';
            abort_r <= '0';
            clear_r <= '0';
            drdy_r  <= '0';

            case state is

                when S_IDLE =>
                    aw_done <= '0';
                    w_done  <= '0';
                    if (MI_RD = '1' or MI_WR = '1') then
                        req_addr <= MI_ADDR(FS_MI_DECODE_W-1 downto 0);
                        req_dwr  <= MI_DWR;
                        req_be   <= MI_BE;
                        req_wr   <= MI_WR;
                        state    <= S_DEC;
                    end if;

                when S_DEC =>
                    off_v      := unsigned(req_addr(9 downto 0)) - FS_STREAM_REGS_BASE;
                    dec_stream <= to_integer(off_v(8 downto 6));
                    dec_region <= R_NONE;
                    if (unsigned(req_addr(FS_MI_DECODE_W-1 downto 8)) = 0) then
                        dec_region <= R_GLOBAL;
                        dec_reg    <= to_integer(unsigned(req_addr(7 downto 2)));
                    elsif (unsigned(req_addr(FS_MI_DECODE_W-1 downto 10)) = 0) then
                        dec_reg <= to_integer(unsigned(req_addr(5 downto 2)));
                        if (to_integer(off_v(9 downto 6)) < STREAMS) then
                            dec_region <= R_STREAM;
                        end if;
                    elsif (unsigned(req_addr(FS_MI_DECODE_W-1 downto FS_ARGS_WIN_W)) = FS_ARGS_BASE / 2**FS_ARGS_WIN_W) then
                        dec_region <= R_ARGS;
                    elsif ((req_addr(24) xor req_addr(23)) = '1') then
                        dec_region <= R_RING;
                    end if;
                    state <= S_EXEC;

                when S_EXEC =>
                    state <= S_ACK;
                    case dec_region is

                        when R_RING =>
                            state <= S_RING;

                        when R_ARGS =>
                            if (req_wr = '1') then
                                state <= S_AXW;
                            else
                                state <= S_AXR;
                            end if;

                        when R_GLOBAL =>
                            rd_data_r <= glob_rd;
                            if (req_wr = '1') then
                                if (dec_reg = FS_REG_CTRL / 4) then
                                    start_r <= req_dwr(FS_CTRL_START_BIT);
                                    abort_r <= req_dwr(FS_CTRL_ABORT_BIT);
                                    clear_r <= req_dwr(FS_CTRL_CLEAR_BIT);
                                elsif (dec_reg = FS_REG_STREAM_MASK / 4 and STATUS_BUSY = '0') then
                                    stream_mask_r <= req_dwr(STREAMS-1 downto 0);
                                elsif (dec_reg = FS_REG_STRIPE / 4 and STATUS_BUSY = '0') then
                                    drives_r <= req_dwr(FS_STRIPE_LOG2_W-1 downto 0);
                                    chunk_r  <= req_dwr(8+FS_STRIPE_LOG2_W-1 downto 8);
                                end if;
                            end if;

                        when R_STREAM =>
                            rd_data_r <= strm_rd;
                            if (req_wr = '1') then
                                -- A tail may only advance once the entries written before it are in HBM.
                                if (is_tail_wr = '1' and RING_WR_PENDING = '1') then
                                    state <= S_EXEC;
                                elsif (dec_reg = FS_SREG_IN_TAIL / 4) then
                                    in_tail_r(sidx) <= req_dwr;
                                elsif (dec_reg = FS_SREG_OUT_TAIL / 4) then
                                    out_tail_r(sidx) <= req_dwr;
                                end if;
                            else
                                if (dec_reg = FS_SREG_IN_BYTES_LO / 4) then
                                    in_bytes_hi_r(sidx) <= IN_BYTES(sidx)(63 downto 32);
                                elsif (dec_reg = FS_SREG_OUT_BYTES_LO / 4) then
                                    out_bytes_hi_r(sidx) <= OUT_BYTES(sidx)(63 downto 32);
                                end if;
                            end if;

                        when R_NONE =>
                            rd_data_r <= (others => '0');

                    end case;

                when S_RING =>
                    if (RING_REQ_RDY = '1') then
                        if (req_wr = '1') then
                            state <= S_ACK;
                        else
                            state <= S_RING_RSP;
                        end if;
                    end if;

                when S_RING_RSP =>
                    if (RING_RSP_VLD = '1') then
                        rd_data_r <= RING_RSP_DATA;
                        state     <= S_ACK;
                    end if;

                when S_AXW =>
                    if (ARG_AXIL_AWREADY = '1') then
                        aw_done <= '1';
                    end if;
                    if (ARG_AXIL_WREADY = '1') then
                        w_done <= '1';
                    end if;
                    if ((aw_done = '1' or ARG_AXIL_AWREADY = '1') and (w_done = '1' or ARG_AXIL_WREADY = '1')) then
                        state <= S_AXB;
                    end if;

                when S_AXB =>
                    if (ARG_AXIL_BVALID = '1') then
                        state <= S_ACK;
                    end if;

                when S_AXR =>
                    if (ARG_AXIL_ARREADY = '1') then
                        state <= S_AXRD;
                    end if;

                when S_AXRD =>
                    if (ARG_AXIL_RVALID = '1') then
                        rd_data_r <= ARG_AXIL_RDATA;
                        state     <= S_ACK;
                    end if;

                when S_ACK =>
                    drdy_r <= not req_wr;
                    state  <= S_IDLE;

            end case;

            if (CLEAR = '1' or clear_r = '1') then
                in_tail_r      <= (others => (others => '0'));
                out_tail_r     <= (others => (others => '0'));
                in_bytes_hi_r  <= (others => (others => '0'));
                out_bytes_hi_r <= (others => (others => '0'));
            end if;

            if (RESET = '1') then
                state          <= S_IDLE;
                req_wr         <= '0';
                dec_region     <= R_NONE;
                dec_reg        <= 0;
                dec_stream     <= 0;
                aw_done        <= '0';
                w_done         <= '0';
                rd_data_r      <= (others => '0');
                stream_mask_r  <= (others => '0');
                drives_r       <= std_logic_vector(to_unsigned(STRIPE_RST_DRIVES, FS_STRIPE_LOG2_W));
                chunk_r        <= std_logic_vector(to_unsigned(STRIPE_RST_CHUNK, FS_STRIPE_LOG2_W));
                in_tail_r      <= (others => (others => '0'));
                out_tail_r     <= (others => (others => '0'));
                in_bytes_hi_r  <= (others => (others => '0'));
                out_bytes_hi_r <= (others => (others => '0'));
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Read multiplexers, from the registered decode
    -- =============================================================================================
    need_space_p : process (all) is
        variable ns_v : std_logic;
    begin
        ns_v := '0';
        for s in 0 to STREAMS-1 loop
            ns_v := ns_v or STREAM_STATUS(s)(FS_SSTAT_NEED_SPACE_BIT);
        end loop;
        need_space <= ns_v;
    end process;

    glob_rd_p : process (all) is
    begin
        glob_rd <= (others => '0');
        case dec_reg is
            when FS_REG_STATUS / 4 =>
                glob_rd(FS_STATUS_BUSY_BIT)       <= STATUS_BUSY;
                glob_rd(FS_STATUS_DONE_BIT)       <= STATUS_DONE;
                glob_rd(FS_STATUS_ERR_BIT)        <= STATUS_ERR;
                glob_rd(FS_STATUS_NEED_SPACE_BIT) <= need_space;
                glob_rd(15 downto 8)              <= STATUS_STATE;
            when FS_REG_STREAM_MASK / 4 =>
                glob_rd(STREAMS-1 downto 0) <= stream_mask_r;
            when FS_REG_VERSION / 4 =>
                glob_rd <= std_logic_vector(to_unsigned(FS_LAYOUT_VERSION, 32));
            when FS_REG_RING_DEPTHS / 4 =>
                glob_rd <= RING_DEPTHS_WORD;
            when FS_REG_KERNEL_ID / 4 =>
                glob_rd <= std_logic_vector(to_unsigned(KERNEL_ID, 32));
            when FS_REG_STRIPE / 4 =>
                glob_rd(FS_STRIPE_LOG2_W-1 downto 0)   <= drives_r;
                glob_rd(8+FS_STRIPE_LOG2_W-1 downto 8) <= chunk_r;
            when others =>
                null;
        end case;
    end process;

    strm_rd_p : process (all) is
    begin
        strm_rd <= (others => '0');
        case dec_reg is
            when FS_SREG_IN_FILES / 4 =>
                strm_rd <= IN_FILES(sidx);
            when FS_SREG_IN_TAIL / 4 =>
                strm_rd <= in_tail_r(sidx);
            when FS_SREG_IN_HEAD / 4 =>
                strm_rd <= IN_HEAD(sidx);
            when FS_SREG_OUT_TAIL / 4 =>
                strm_rd <= out_tail_r(sidx);
            when FS_SREG_OUT_HEAD / 4 =>
                strm_rd <= OUT_HEAD(sidx);
            when FS_SREG_OUT_BYTES_LO / 4 =>
                strm_rd <= OUT_BYTES(sidx)(31 downto 0);
            when FS_SREG_OUT_BYTES_HI / 4 =>
                strm_rd <= out_bytes_hi_r(sidx);
            when FS_SREG_STREAM_STATUS / 4 =>
                strm_rd(3 downto 0) <= STREAM_STATUS(sidx);
            when FS_SREG_ERR_INFO / 4 =>
                strm_rd <= ERR_INFO(sidx);
            when FS_SREG_IN_BYTES_LO / 4 =>
                strm_rd <= IN_BYTES(sidx)(31 downto 0);
            when FS_SREG_IN_BYTES_HI / 4 =>
                strm_rd <= in_bytes_hi_r(sidx);
            when others =>
                null;
        end case;
    end process;

    -- =============================================================================================
    -- Outputs
    -- =============================================================================================
    MI_ARDY <= '1' when (state = S_ACK) else '0';
    MI_DRD  <= rd_data_r;
    MI_DRDY <= drdy_r;

    CTRL_START         <= start_r;
    CTRL_ABORT         <= abort_r;
    CTRL_CLEAR         <= clear_r;
    STREAM_MASK        <= stream_mask_r;
    STRIPE_LOG2_DRIVES <= drives_r;
    STRIPE_LOG2_CHUNK  <= chunk_r;
    IN_TAIL            <= in_tail_r;
    OUT_TAIL           <= out_tail_r;

    RING_REQ_VLD  <= '1' when (state = S_RING) else '0';
    RING_REQ_WR   <= req_wr;
    RING_REQ_ADDR <= req_addr(24) & req_addr(FS_RING_HBM_ADDR_W-2 downto 0);
    RING_REQ_DATA <= req_dwr;
    RING_REQ_BE   <= req_be;

    ARG_AXIL_AWADDR  <= req_addr(FS_ARGS_WIN_W-1 downto 0);
    ARG_AXIL_AWVALID <= '1' when (state = S_AXW and aw_done = '0') else '0';
    ARG_AXIL_WDATA   <= req_dwr;
    ARG_AXIL_WSTRB   <= req_be;
    ARG_AXIL_WVALID  <= '1' when (state = S_AXW and w_done = '0') else '0';
    ARG_AXIL_BREADY  <= '1' when (state = S_AXB) else '0';
    ARG_AXIL_ARADDR  <= req_addr(FS_ARGS_WIN_W-1 downto 0);
    ARG_AXIL_ARVALID <= '1' when (state = S_AXR) else '0';
    ARG_AXIL_RREADY  <= '1' when (state = S_AXRD) else '0';

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    -- psl default clock is rising_edge(CLK);

    -- psl fs_regs_ring_hold : assert always
    --     ((RESET = '0' and RING_REQ_VLD = '1' and RING_REQ_RDY = '0') -> next (RING_REQ_VLD = '1'))
    --     report "FS_REGS: ring request withdrawn before RDY!";

    -- psl fs_regs_ring_rsp_expected : assert always
    --     ((RESET = '0' and RING_RSP_VLD = '1') -> (state = S_RING_RSP))
    --     report "FS_REGS: ring read data without an outstanding ring read!";

end architecture;
