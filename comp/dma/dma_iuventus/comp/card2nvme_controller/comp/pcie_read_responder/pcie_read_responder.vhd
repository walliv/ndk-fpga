-- pcie_read_responder.vhd: this component dispatches responses to the PCIe read requests
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity PCIE_READ_RESPONDER is
    generic (
        DEVICE : string := "ULTRASCALE";

        PKT_SIZE_MAX : natural := 2**16 -1;

        MFB_REGIONS     : natural := 1;
        MFB_REGION_SIZE : natural := 4;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 8;

        BUFF_POINTER_WIDTH : natural := 16
        );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- MFB interface twards CC interface of the PCIE IP
        -- =========================================================================================
        TX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- MVB Interface for generated CC headers
        -- =========================================================================================
        CC_HDR_DATA    : out std_logic_vector(PCIE_META_CPL_HDR_W -1 downto 0);
        CC_HDR_SRC_RDY : out std_logic;
        CC_HDR_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Input interface from header buffer
        -- =========================================================================================
        -- This is not an address for reading interface of the buffer, but the addres to which the
        -- current header has been written.
        CQ_HDR_ADDR     : in  std_logic_vector(64 -1 downto 0);
        CQ_HDR_DATA     : in  std_logic_vector(PCIE_META_REQ_HDR_W -1 downto 0);
        CQ_HDR_BYTE_LNG : in  std_logic_vector(13 -1 downto 0);
        CQ_HDR_SRC_RDY  : in  std_logic;
        CQ_HDR_DST_RDY  : out std_logic;

        -- =========================================================================================
        -- Reading interface to the data buffer
        -- =========================================================================================
        DATA_BUFF_RD_CHAN     : out std_logic;
        DATA_BUFF_RD_DATA     : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        -- One bit wider than BUFF_POINTER_WIDTH: the buffer is flat-addressed (MEM_PARTITIONING
        -- => FALSE), so this address alone must reach the whole flat space (SQ at page 0,
        -- RDBUFF at pages 1+).
        DATA_BUFF_RD_ADDR     : out std_logic_vector(BUFF_POINTER_WIDTH downto 0);
        DATA_BUFF_RD_EN       : out std_logic;
        -- Multiple region support
        DATA_BUFF_RD_DATA_VLD : in  std_logic;

        -- =========================================================================================
        -- Interface to the C/S registers
        --
        -- For pointer update and incrementing of packet counter.
        -- =========================================================================================
        RDBUFF_DISP_RDS_CHAN      : out std_logic;
        RDBUFF_DISP_RDS_BYTES     : out std_logic_vector(log2(PKT_SIZE_MAX+1) -1 downto 0);
        RDBUFF_DISP_RDS_INCR       : out std_logic);
end entity;

architecture FULL of PCIE_READ_RESPONDER is
    constant MFB_LENGTH : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;

    -- =============================================================================================
    -- CC Header generation
    -- =============================================================================================
    -- Parsed CQ header metadata
    signal cq_hdr_tag      : std_logic_vector(9 downto 0);
    signal cq_hdr_req_id   : std_logic_vector(15 downto 0);
    signal cq_hdr_tc       : std_logic_vector(2 downto 0);
    signal cq_hdr_attr     : std_logic_vector(2 downto 0);
    signal cq_hdr_at       : std_logic_vector(1 downto 0);
    signal cq_hdr_bar_id   : std_logic_vector(2 downto 0);
    signal cq_hdr_req_type : std_logic_vector(3 downto 0);

    -- CC Header metadata
    signal cc_hdr_lower_addr : std_logic_vector(6 downto 0);
    signal cc_hdr_byte_cnt   : std_logic_vector(12 downto 0);
    signal cc_hdr_dw_cnt     : std_logic_vector(10 downto 0);

    -- State machine control and state signals
    type cc_hdr_gen_state_t is (S_IDLE, S_HDRS_GEN, S_HDR_GEN_DONE);
    signal cc_hdr_gen_pst       : cc_hdr_gen_state_t := S_IDLE;
    signal cc_hdr_gen_nst       : cc_hdr_gen_state_t := S_IDLE;
    signal cc_hdr_byte_cntr_pst : unsigned(CQ_HDR_BYTE_LNG'range);
    signal cc_hdr_byte_cntr_nst : unsigned(CQ_HDR_BYTE_LNG'range);
    signal hdr_gen_done         : std_logic;

    -- =============================================================================================
    -- Dispatch FSM signals
    -- =============================================================================================
    type pkt_dispatch_state_t is (S_IDLE, S_PKT_BEGIN, S_PKT_MIDDLE, S_UPDATE_STATUS);
    signal pkt_dispatch_pst : pkt_dispatch_state_t := S_IDLE;
    signal pkt_dispatch_nst : pkt_dispatch_state_t := S_IDLE;
    signal addr_cntr_pst    : unsigned(DATA_BUFF_RD_ADDR'range);
    signal addr_cntr_nst    : unsigned(DATA_BUFF_RD_ADDR'range);
    signal byte_cntr_pst    : unsigned(log2(PKT_SIZE_MAX+1) -1 downto 0);
    signal byte_cntr_nst    : unsigned(log2(PKT_SIZE_MAX+1) -1 downto 0);

    -- Tracks the amount of bytes remaining until the end of the current RCB-aligned completion
    -- (as opposed to byte_cntr_pst/nst, which tracks the whole read request). Used to insert an
    -- intermediate SOF/EOF pair into the TX_MFB data stream at each completion boundary so that
    -- it stays in sync with the (possibly split) headers generated by the CC header generating FSM.
    signal seg_byte_cntr_pst : unsigned(byte_cntr_pst'range);
    signal seg_byte_cntr_nst : unsigned(byte_cntr_pst'range);
    -- Set for one cycle after an intermediate completion boundary has been dispatched so that the
    -- following valid word is marked with SOF.
    signal need_sof_pst      : std_logic;
    signal need_sof_nst      : std_logic;

    signal data_read_done : std_logic;

    signal disp_fsm_mfb_sof     : std_logic_vector(TX_MFB_SOF'range);
    signal disp_fsm_mfb_eof     : std_logic_vector(TX_MFB_EOF'range);
    signal disp_fsm_mfb_eof_pos : std_logic_vector(TX_MFB_EOF_POS'range);
    signal disp_fsm_mfb_src_rdy : std_logic;
begin
    -- TODO:
    --      1. Check with assertion that only read requests arrive
    --      2. Check if the CC header contains non zero DW count
    --      3. Check if the CC header contains a non zero byte count
    --      4. Check if the CC header DW count contains all of the byte count

    -- =============================================================================================
    -- CC Header generating FSM
    -- =============================================================================================
    pcie_cq_hdr_deparser_i : entity work.PCIE_CQ_HDR_DEPARSER
        generic map (
            DEVICE => DEVICE)
        port map (
            OUT_TAG          => cq_hdr_tag,
            OUT_ADDRESS      => open,
            OUT_REQ_ID       => cq_hdr_req_id,
            OUT_TC           => cq_hdr_tc,
            OUT_DW_CNT       => open,
            OUT_ATTRIBUTES   => cq_hdr_attr,
            OUT_FBE          => open,
            OUT_LBE          => open,
            OUT_ADDRESS_TYPE => cq_hdr_at,
            OUT_TARGET_FUNC  => open,
            OUT_BAR_ID       => cq_hdr_bar_id,
            OUT_BAR_APERTURE => open,
            OUT_ADDR_LEN     => open,
            OUT_REQ_TYPE     => cq_hdr_req_type,

            IN_HEADER     => CQ_HDR_DATA,
            IN_FBE        => (others => '0'),
            IN_LBE        => (others => '0'),
            IN_INTEL_META => (others => '0'));

    pcie_cc_hdr_gen_i : entity work.PCIE_CC_HDR_GEN
        generic map (
            DEVICE => DEVICE)
        port map (
            IN_LOWER_ADDR   => cc_hdr_lower_addr,
            IN_BYTE_CNT     => cc_hdr_byte_cnt,
            IN_DW_CNT       => cc_hdr_dw_cnt,
            IN_COMP_ST      => (others => '0'),  -- Successfull completion status
            IN_REQ_ID       => cq_hdr_req_id,
            IN_TAG          => cq_hdr_tag,
            IN_TC           => cq_hdr_tc,
            IN_ATTRIBUTES   => cq_hdr_attr,
            IN_ADDRESS_TYPE => cq_hdr_at,
            IN_META_FUNC_ID => x"01",
            IN_BUS_NUM      => (others => '0'),
            COMP_WITH_DATA  => '1',
            OUT_HEADER      => CC_HDR_DATA);

    cc_hdr_gen_fsm_state_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                cc_hdr_gen_pst       <= S_IDLE;
                cc_hdr_byte_cntr_pst <= (others => '0');
            elsif (CC_HDR_DST_RDY = '1') then
                cc_hdr_gen_pst       <= cc_hdr_gen_nst;
                cc_hdr_byte_cntr_pst <= cc_hdr_byte_cntr_nst;
            end if;
        end if;
    end process;

    cc_hdr_gen_fsm_nst_logic_p : process (all) is
        variable tr_byte_lng : std_logic_vector(CQ_HDR_BYTE_LNG'range);
    begin
        cc_hdr_gen_nst       <= cc_hdr_gen_pst;
        cc_hdr_byte_cntr_nst <= cc_hdr_byte_cntr_pst;

        -- Lower Addr is non-zero only for the first completion. The rest is set to 0
        cc_hdr_lower_addr <= (others => '0');
        cc_hdr_byte_cnt   <= std_logic_vector(cc_hdr_byte_cntr_pst);
        -- A common completion has 32 DWs (128 Bytes)
        cc_hdr_dw_cnt     <= "00000100000";

        hdr_gen_done   <= '0';
        CC_HDR_SRC_RDY <= '0';
        CQ_HDR_DST_RDY <= '0';

        case cc_hdr_gen_pst is
            when S_IDLE =>
                if (CQ_HDR_SRC_RDY = '1') then
                    if ((unsigned(CQ_HDR_ADDR(6 downto 0)) + unsigned(CQ_HDR_BYTE_LNG)) > 128) then
                        cc_hdr_gen_nst       <= S_HDRS_GEN;
                        -- The next value is subtracted with the size of a segment but also by the
                        -- padding caused by the DW-aligned accesses
                        cc_hdr_byte_cntr_nst <= unsigned(CQ_HDR_BYTE_LNG) - (128 - resize(unsigned(CQ_HDR_ADDR(6 downto 0)), cc_hdr_byte_cntr_pst'length));

                        -- Round the first (RCB-boundary-limited) completion's length to whole
                        -- DWords
                        tr_byte_lng   := std_logic_vector((128 - resize(unsigned(CQ_HDR_ADDR(6 downto 0)), tr_byte_lng'length)) + 3);
                        cc_hdr_dw_cnt <= tr_byte_lng(12 downto 2);

                    -- If the current completion fits into one transaction, switch to another
                    -- header and do not transition
                    else
                        cc_hdr_gen_nst <= S_HDR_GEN_DONE;

                        -- Round the length to whole Dwords
                        tr_byte_lng   := std_logic_vector(unsigned(CQ_HDR_ADDR(1 downto 0)) + unsigned(CQ_HDR_BYTE_LNG) + 3);
                        cc_hdr_dw_cnt <= tr_byte_lng(12 downto 2);
                    end if;

                    cc_hdr_lower_addr <= CQ_HDR_ADDR(cc_hdr_lower_addr'range);
                    cc_hdr_byte_cnt   <= CQ_HDR_BYTE_LNG;
                    CC_HDR_SRC_RDY    <= '1';
                end if;

            when S_HDRS_GEN =>
                cc_hdr_byte_cntr_nst <= cc_hdr_byte_cntr_pst - 128;
                CC_HDR_SRC_RDY       <= '1';

                if (cc_hdr_byte_cntr_pst <= 128) then
                    cc_hdr_gen_nst <= S_HDR_GEN_DONE;

                    -- Round the length to whole Dwords
                    tr_byte_lng   := std_logic_vector(cc_hdr_byte_cntr_pst + 3);
                    cc_hdr_dw_cnt <= std_logic_vector(tr_byte_lng(12 downto 2));
                end if;

            when S_HDR_GEN_DONE =>
                hdr_gen_done   <= CC_HDR_DST_RDY;
                CQ_HDR_DST_RDY <= CC_HDR_DST_RDY and data_read_done;

                if (data_read_done = '1') then
                    cc_hdr_gen_nst <= S_IDLE;
                end if;
        end case;
    end process;

    -- =============================================================================================
    -- FSM Controlling read from the data buffer and from the Completion Queue
    -- =============================================================================================
    pkt_dispatch_fsm_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                pkt_dispatch_pst  <= S_IDLE;
                byte_cntr_pst     <= (others => '0');
                addr_cntr_pst     <= (others => '0');
                seg_byte_cntr_pst <= (others => '0');
                need_sof_pst      <= '0';

            elsif (TX_MFB_DST_RDY = '1') then
                pkt_dispatch_pst  <= pkt_dispatch_nst;
                byte_cntr_pst     <= byte_cntr_nst;
                addr_cntr_pst     <= addr_cntr_nst;
                seg_byte_cntr_pst <= seg_byte_cntr_nst;
                need_sof_pst      <= need_sof_nst;

            end if;
        end if;
    end process;

    pkt_dispatch_fsm_nst_logic_p : process (all) is
    begin
        pkt_dispatch_nst <= pkt_dispatch_pst;
        case pkt_dispatch_pst is
            when S_IDLE =>
                if (CQ_HDR_SRC_RDY = '1') then
                    pkt_dispatch_nst <= S_PKT_BEGIN;
                end if;

            when S_PKT_BEGIN =>
                if (DATA_BUFF_RD_DATA_VLD = '1') then
                    if (byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        pkt_dispatch_nst <= S_UPDATE_STATUS;
                    else
                        pkt_dispatch_nst <= S_PKT_MIDDLE;
                    end if;
                end if;

            when S_PKT_MIDDLE =>
                if (byte_cntr_pst <= (TX_MFB_DATA'length /8) and DATA_BUFF_RD_DATA_VLD = '1') then
                    pkt_dispatch_nst <= S_UPDATE_STATUS;
                end if;

            when S_UPDATE_STATUS =>
                -- If a generation of CC PCIe headers for this read completion has finished,
                -- transition back
                if (hdr_gen_done = '1') then
                    pkt_dispatch_nst <= S_IDLE;
                end if;
        end case;
    end process;

    -- This machine expects data next clock
    pkt_dispatch_fsm_output_logic_p : process (all) is
        variable dma_hdr_frame_ptr_v    : unsigned(BUFF_POINTER_WIDTH downto 0);
        variable dma_hdr_frame_length_v : unsigned(CQ_HDR_BYTE_LNG'range);
        -- True when this read completion needs to be split at a 128B RCB boundary (mirrors the
        -- split decision taken in cc_hdr_gen_fsm_nst_logic_p).
        variable need_split_v           : boolean;
        -- Length of the first (RCB-limited) completion segment.
        variable first_seg_len_v        : unsigned(seg_byte_cntr_pst'range);
    begin
        addr_cntr_nst     <= addr_cntr_pst;
        byte_cntr_nst     <= byte_cntr_pst;
        seg_byte_cntr_nst <= seg_byte_cntr_pst;
        -- Carried over by default (in case TX_MFB_DST_RDY/DATA_BUFF_RD_DATA_VLD stalls); explicitly
        -- resolved (consumed or re-armed) whenever a valid word is dispatched, see below.
        need_sof_nst      <= need_sof_pst;

        disp_fsm_mfb_sof     <= (others => '0');
        disp_fsm_mfb_eof     <= (others => '0');
        disp_fsm_mfb_eof_pos <= (others => '0');
        disp_fsm_mfb_src_rdy <= '0';

        -- The buffer is flat-addressed (MEM_PARTITIONING => FALSE): the channel bit is a
        -- don't-care, the masked address alone locates the datum (SQ page 0 vs RDBUFF pages 1+).
        DATA_BUFF_RD_CHAN <= '0';

        DATA_BUFF_RD_ADDR <= std_logic_vector(addr_cntr_pst);
        DATA_BUFF_RD_EN   <= '0';

        RDBUFF_DISP_RDS_INCR <= '0';
        data_read_done   <= '0';

        dma_hdr_frame_ptr_v    := unsigned(CQ_HDR_ADDR(BUFF_POINTER_WIDTH downto 2)) & "00";
        -- The length of a Read response with a padding added to the beginning of the first
        -- transaction in order to be DW-aligned
        dma_hdr_frame_length_v := unsigned(CQ_HDR_BYTE_LNG) + unsigned(CQ_HDR_ADDR(1 downto 0));

        -- Mirrors the split decision and first-segment length computed in
        -- cc_hdr_gen_fsm_nst_logic_p so that the TX_MFB data stream can be broken into one
        -- SOF/EOF-delimited segment per generated CC header.
        need_split_v    := (unsigned(CQ_HDR_ADDR(6 downto 0)) + unsigned(CQ_HDR_BYTE_LNG)) > 128;
        first_seg_len_v := 128 - resize(unsigned(CQ_HDR_ADDR(6 downto 0)), first_seg_len_v'length);

        case pkt_dispatch_pst is
            when S_IDLE =>

                -- A valid PCIE header results in the start of a Read Completion
                if (CQ_HDR_SRC_RDY = '1') then
                    -- We are interested only in a Dword aligned address
                    addr_cntr_nst <= dma_hdr_frame_ptr_v + (TX_MFB_DATA'length /8);
                    byte_cntr_nst <= resize(dma_hdr_frame_length_v, byte_cntr_nst'length);

                    if (need_split_v) then
                        seg_byte_cntr_nst <= first_seg_len_v;
                    else
                        seg_byte_cntr_nst <= resize(dma_hdr_frame_length_v, seg_byte_cntr_nst'length);
                    end if;

                    DATA_BUFF_RD_ADDR <= std_logic_vector(dma_hdr_frame_ptr_v);
                    DATA_BUFF_RD_EN   <= '1';
                end if;

            when S_PKT_BEGIN =>

                DATA_BUFF_RD_EN <= TX_MFB_DST_RDY;

                if (DATA_BUFF_RD_DATA_VLD = '1') then
                    addr_cntr_nst     <= addr_cntr_pst + (TX_MFB_DATA'length /8);
                    byte_cntr_nst     <= byte_cntr_pst - (TX_MFB_DATA'length /8);
                    seg_byte_cntr_nst <= seg_byte_cntr_pst - (TX_MFB_DATA'length /8);
                    need_sof_nst      <= '0';

                    disp_fsm_mfb_sof     <= "1";
                    disp_fsm_mfb_src_rdy <= '1';

                    -- When the packet, according to its length, fits in the output word, then
                    -- assign EOF and do not count next address for the reading.
                    if (byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        disp_fsm_mfb_eof     <= "1";
                        -- take only the lower bits from the frame length
                        disp_fsm_mfb_eof_pos <= std_logic_vector(dma_hdr_frame_length_v(TX_MFB_EOF_POS'range) - 1);

                    -- The completion is split at a 128B RCB boundary: close the current segment
                    -- here (with a full-word EOF, i.e. the boundary is always word-aligned for the
                    -- supported traffic patterns) and re-arm SOF for the next segment's first word.
                    elsif (seg_byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        disp_fsm_mfb_eof     <= "1";
                        disp_fsm_mfb_eof_pos <= (others => '1');
                        need_sof_nst         <= '1';

                        if ((byte_cntr_pst - (TX_MFB_DATA'length /8)) > 128) then
                            seg_byte_cntr_nst <= to_unsigned(128, seg_byte_cntr_nst'length);
                        else
                            seg_byte_cntr_nst <= byte_cntr_pst - (TX_MFB_DATA'length /8);
                        end if;
                    end if;
                else
                    DATA_BUFF_RD_ADDR <= std_logic_vector(addr_cntr_pst - (TX_MFB_DATA'length /8));
                end if;

            when S_PKT_MIDDLE =>

                DATA_BUFF_RD_EN <= TX_MFB_DST_RDY;

                if (DATA_BUFF_RD_DATA_VLD = '1') then
                    addr_cntr_nst     <= addr_cntr_pst + (TX_MFB_DATA'length /8);
                    byte_cntr_nst     <= byte_cntr_pst - (TX_MFB_DATA'length /8);
                    seg_byte_cntr_nst <= seg_byte_cntr_pst - (TX_MFB_DATA'length /8);
                    need_sof_nst      <= '0';

                    disp_fsm_mfb_src_rdy <= '1';

                    -- A pending split boundary from the previous word means this word starts a new
                    -- completion segment.
                    if (need_sof_pst = '1') then
                        disp_fsm_mfb_sof <= "1";
                    end if;

                    if (byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        disp_fsm_mfb_eof     <= "1";
                        disp_fsm_mfb_eof_pos <= std_logic_vector(dma_hdr_frame_length_v(TX_MFB_EOF_POS'range) - 1);

                    elsif (seg_byte_cntr_pst <= (TX_MFB_DATA'length /8)) then
                        disp_fsm_mfb_eof     <= "1";
                        disp_fsm_mfb_eof_pos <= (others => '1');
                        need_sof_nst         <= '1';

                        if ((byte_cntr_pst - (TX_MFB_DATA'length /8)) > 128) then
                            seg_byte_cntr_nst <= to_unsigned(128, seg_byte_cntr_nst'length);
                        else
                            seg_byte_cntr_nst <= byte_cntr_pst - (TX_MFB_DATA'length /8);
                        end if;
                    end if;
                else
                    DATA_BUFF_RD_ADDR <= std_logic_vector(addr_cntr_pst - (TX_MFB_DATA'length /8));
                end if;

            when S_UPDATE_STATUS =>
                data_read_done   <= TX_MFB_DST_RDY;
                RDBUFF_DISP_RDS_INCR <= TX_MFB_DST_RDY and hdr_gen_done;
        end case;
    end process;

    -- Stats-only classification bit (independent of the buffer's own, now don't-care, channel
    -- port): '0' => RDBUFF read dispatched, '1' => SQ read dispatched. With the 2-BAR flat layout
    -- the SQ and RDBUFF share one BAR_ID, so they are told apart by the (flat) address instead: the
    -- SQ lives in page 0 (address < 4096), the RDBUFF in pages 1..127 (address >= 4096).
    RDBUFF_DISP_RDS_CHAN      <= '1' when unsigned(cq_hdr_addr(BUFF_POINTER_WIDTH downto 12)) = 0 else '0';
    RDBUFF_DISP_RDS_BYTES     <= CQ_HDR_BYTE_LNG;

    -- This process delays the set of all output MFB signals because the data come from the data
    -- buffer one clock cycle after the address and enable signal have been set.
    out_delay_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                TX_MFB_SRC_RDY <= '0';
            elsif (TX_MFB_DST_RDY = '1') then
                TX_MFB_DATA    <= DATA_BUFF_RD_DATA;
                TX_MFB_SOF     <= disp_fsm_mfb_sof;
                TX_MFB_EOF     <= disp_fsm_mfb_eof;
                TX_MFB_EOF_POS <= disp_fsm_mfb_eof_pos;
                TX_MFB_SRC_RDY <= disp_fsm_mfb_src_rdy;
            end if;
        end if;
    end process;

    TX_MFB_SOF_POS <= (others => '0');
end architecture;