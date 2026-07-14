-- cqe_processor.vhd: processing of Completion Queue Entries
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
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
use work.nvme_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity CQE_PROCESSOR is
    generic (
        DEVICE : string := "ULTRASCALE";

        -- THe width of data read from the DATA_BUFF
        DATA_WIDTH : positive := 512;
        -- The size of a pointer to a sector in the internal buffer
        BUFF_POINTER_WIDTH : natural := 16;
        -- Number of independent SQ/CQ queues (one per SSD). Flat page q holds CQ[q] (see
        -- nvme_cq_meta_extractor.vhd); CQ[q] entry i lives at buffer byte address
        -- q*4096 + i*16. A single round-robin arbiter (see poll_qid_pst below) polls the N
        -- queues over the one physical read port, one queue per cycle. At NUM_QUEUES=1 this
        -- degenerates to continuous polling of queue 0, identical to the original design.
        NUM_QUEUES : positive := 1
        );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- Start/stop interface
        -- =========================================================================================
        START_REQ_VLD : in  std_logic;
        START_REQ_ACK : out std_logic;
        STOP_REQ_VLD  : in  std_logic;
        STOP_REQ_ACK  : out std_logic;

        -- =========================================================================================
        -- Reading interface to the data buffer
        -- =========================================================================================
        DATA_BUFF_RD_CHAN     : out std_logic_vector(0 downto 0);
        DATA_BUFF_RD_DATA     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        -- One bit wider than BUFF_POINTER_WIDTH: the buffer is flat-addressed (MEM_PARTITIONING
        -- => FALSE), so this address alone must reach the whole flat space (the CQ stays at page 0).
        DATA_BUFF_RD_ADDR     : out std_logic_vector(BUFF_POINTER_WIDTH downto 0);
        DATA_BUFF_RD_EN       : out std_logic;
        -- Multiple region support
        DATA_BUFF_RD_DATA_VLD : in  std_logic;

        -- =========================================================================================
        -- Interface to the C/S registers
        --
        -- For pointer update and incrementing of packet counter.
        -- =========================================================================================
        DBL_MASK        : in  std_logic_vector(15 downto 0);
        SQHDBL_UPD_DATA : out std_logic_vector(15 downto 0);
        CQHDBL_UPD_DATA : out std_logic_vector(15 downto 0);
        LAST_CQ_ENTRY   : out std_logic_vector(CQ_ENTRY_RANGE);
        STATUS_UPD_EN   : out std_logic;
        -- Queue Identifier of the completion currently being reported (STATUS_UPD_EN), i.e. the
        -- queue the round-robin arbiter (poll_qid_pst) is polling this cycle. Always "0" at
        -- NUM_QUEUES=1.
        CQP_CQE_QID     : out std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0)
        );
end entity;

architecture FULL of CQE_PROCESSOR is
    -- The amount of CQ Entries that fit to one output word of the data buffer
    constant DATA_SEGMENTS : natural := DATA_WIDTH/CQ_ENTRY_WIDTH;
    -- Bits of the flat buffer address occupied by one 4096 B page (see nvme_cq_meta_extractor.vhd
    -- / op_ctrl.vhd's FIRST_DATA_PAGE geometry).
    constant PAGE_OFFSET_W : natural := 12;

    -- Per-queue CQ head doorbell/phase state. At NUM_QUEUES=1 only index 0 is ever used,
    -- identical to the original scalar cqhdbl_pst/cqhdbl_nst/observed_phase_value_reg/_nst.
    signal cqhdbl_pst : u_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);
    signal cqhdbl_nst : u_array_t(NUM_QUEUES -1 downto 0)(15 downto 0);

    signal buff_data_segm           : slv_array_t(DATA_SEGMENTS -1 downto 0)(CQ_ENTRY_WIDTH -1 downto 0);
    -- It is a vector of size 1 since I compare it with a single-bit value returned by a range
    signal observed_phase_value_reg : slv_array_t(NUM_QUEUES -1 downto 0)(0 downto 0);
    signal observed_phase_value_nst : slv_array_t(NUM_QUEUES -1 downto 0)(0 downto 0);
    signal comp_enabled             : std_logic;

    -- Round-robin pointer selecting which queue's CQ is READ REQUESTED this cycle over the single
    -- physical read port (drives DATA_BUFF_RD_ADDR). At NUM_QUEUES=1 this stays 0 forever
    -- (0+1 mod 1 = 0), so requesting is continuous on queue 0, exactly as in the original
    -- single-queue design.
    signal poll_qid_pst : natural range 0 to NUM_QUEUES -1;
    signal poll_qid_nst : natural range 0 to NUM_QUEUES -1;

    -- Queue whose CQ read RESPONSE (DATA_BUFF_RD_DATA/DATA_BUFF_RD_DATA_VLD) is arriving this
    -- cycle: TX_DMA_PCIE_TRANS_BUFFER's read port (DATA_BUFF_RD_EN -> DATA_BUFF_RD_DATA_VLD) has a
    -- fixed 1-cycle latency, so the data arriving THIS cycle was requested LAST cycle -- i.e. it
    -- belongs to whichever queue the read request actually targeted last cycle, which is NOT
    -- necessarily this cycle's poll_qid_pst (poll_qid_pst free-runs one step per cycle,
    -- independent of the response). resp_qid_pst tracks that "requested last cycle" queue exactly
    -- (see pkt_dispatch_fsm_output_logic_p's req_qidx/resp_qidx). At NUM_QUEUES=1 both poll_qid_pst
    -- and resp_qid_pst are always 0, so this degenerates to the original single-queue design
    -- exactly (no distinction between "requesting" and "responding" queue is ever observable).
    signal resp_qid_pst : natural range 0 to NUM_QUEUES -1;
    signal resp_qid_nst : natural range 0 to NUM_QUEUES -1;
begin

    assert (DATA_WIDTH = 512)
        report "CQE_PROCESSOR: Design has only been tested with data width of 512 bits!"
        severity FAILURE;

    -- =============================================================================================
    -- Start/stop logic
    -- =============================================================================================
    start_stop_fsm_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                comp_enabled  <= '0';
                START_REQ_ACK <= '0';
                STOP_REQ_ACK  <= '0';
            else
                START_REQ_ACK <= '0';
                STOP_REQ_ACK  <= '0';

                if (START_REQ_VLD = '1') then
                    comp_enabled  <= '1';
                    START_REQ_ACK <= '1';
                    
                elsif (STOP_REQ_VLD = '1') then
                    comp_enabled  <= '0';
                    STOP_REQ_ACK  <= '1';
                end if;
            end if;
        end if;
    end process;

    buff_data_segm_g : for segm_idx in 0 to (DATA_SEGMENTS-1) generate
        buff_data_segm(segm_idx) <= DATA_BUFF_RD_DATA(CQ_ENTRY_WIDTH + segm_idx*CQ_ENTRY_WIDTH -1 downto segm_idx*CQ_ENTRY_WIDTH);
    end generate;

    -- The buffer is flat-addressed (MEM_PARTITIONING => FALSE): the channel bit is a don't-care,
    -- the address alone (CQ at flat page 0) locates the datum.
    DATA_BUFF_RD_CHAN(0) <= '0';
    DATA_BUFF_RD_EN      <= '1';

    -- =============================================================================================
    -- FSM controlling read from the data buffer and from the Completion Queue
    --
    -- Only one physical read port exists (DATA_BUFF_RD_*), so the N queues' CQs cannot be polled
    -- in parallel: poll_qid_pst round-robins across them, one queue serviced per cycle. At
    -- NUM_QUEUES=1 poll_qid_pst is always 0, so this is exactly the original continuous
    -- single-queue poll (no arbitration).
    -- =============================================================================================
    cq_poll_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            -- The running parametrs get reset when a new start request comes on a disabled
            -- component
            if (RESET = '1' or (START_REQ_VLD = '1' and comp_enabled = '0')) then
                cqhdbl_pst               <= (others => (others => '0'));
                observed_phase_value_reg <= (others => "1");
                poll_qid_pst             <= 0;
                resp_qid_pst             <= 0;
            else
                cqhdbl_pst               <= cqhdbl_nst;
                observed_phase_value_reg <= observed_phase_value_nst;
                poll_qid_pst             <= poll_qid_nst;
                resp_qid_pst             <= resp_qid_nst;
            end if;
        end if;
    end process;

    -- This machine expects data next clock
    pkt_dispatch_fsm_output_logic_p : process (all) is
        variable segm_idx     : natural range 0 to 3;
        variable cqhdbl_tmp   : unsigned(15 downto 0);
        -- Queue whose CQ read RESPONSE is arriving this cycle (see resp_qid_pst above) --
        -- interprets DATA_BUFF_RD_DATA/DATA_BUFF_RD_DATA_VLD, cqhdbl_pst/observed_phase_value_reg
        -- and drives CQP_CQE_QID/STATUS_UPD_EN.
        variable resp_qidx    : natural range 0 to NUM_QUEUES -1;
        -- Queue THIS cycle's read REQUEST (DATA_BUFF_RD_ADDR) targets. Normally the round-robin's
        -- poll_qid_pst; overridden below to resp_qidx (continue reading the SAME queue's next CQ
        -- word) when this cycle's response was the word's last (4th) CQE and a completion was
        -- recognized, so a queue with back-to-back completions need not wait a full
        -- NUM_QUEUES-cycle round-robin sweep between them.
        variable req_qidx     : natural range 0 to NUM_QUEUES -1;
        variable cq_page_base : unsigned(DATA_BUFF_RD_ADDR'length -1 downto 0);
        variable cq_word_addr : unsigned(DATA_BUFF_RD_ADDR'length -1 downto 0);
    begin
        resp_qidx := resp_qid_pst;
        req_qidx  := poll_qid_pst;

        cqhdbl_tmp                  := (cqhdbl_pst(resp_qidx) + 1) and unsigned(DBL_MASK);
        cqhdbl_nst                  <= cqhdbl_pst;
        observed_phase_value_nst    <= observed_phase_value_reg;

        SQHDBL_UPD_DATA <= (others => '0');
        CQHDBL_UPD_DATA <= (others => '0');
        LAST_CQ_ENTRY   <= (others => '0');
        STATUS_UPD_EN   <= '0';
        CQP_CQE_QID     <= std_logic_vector(to_unsigned(resp_qidx, CQP_CQE_QID'length));

        -- Round-robin advance every cycle (single physical read port polls one queue at a time);
        -- runs independently of the request-address override below (poll_qid_pst just free-runs
        -- as the round-robin's own schedule; req_qidx -- and hence the address actually sent this
        -- cycle -- is what resp_qid_nst below records for next cycle's response interpretation).
        if (poll_qid_pst = NUM_QUEUES -1) then
            poll_qid_nst <= 0;
        else
            poll_qid_nst <= poll_qid_pst + 1;
        end if;

        -- CQ[req_qidx] entry i lives at buffer byte address req_qidx*4096 + i*16 -- add the
        -- queue's page offset to the original intra-page word address. shift_left(resize(X, LEN),
        -- 6) is numerically identical to the original "resize(X, LEN-6) & "000000"" pattern (both
        -- drop the same MSB when the *64 product overflows LEN bits), but avoids an ambiguous "&"
        -- between IEEE.STD_LOGIC_1164 and TYPE_PACK's implicit array-of-array concatenation.
        cq_page_base := shift_left(to_unsigned(req_qidx, cq_page_base'length), PAGE_OFFSET_W);
        cq_word_addr := shift_left(resize(cqhdbl_pst(req_qidx)(15 downto 2), DATA_BUFF_RD_ADDR'length), 6);
        DATA_BUFF_RD_ADDR <= std_logic_vector(cq_page_base + cq_word_addr);

        -- WARNING: There can be a problem when RD_DATA_VLD = '0'
        if (comp_enabled = '1' and DATA_BUFF_RD_DATA_VLD = '1' and DBL_MASK /= x"0000") then
            segm_idx := to_integer(cqhdbl_pst(resp_qidx)(1 downto 0));
            -- If a valid CQ entry is found then update status information
            if (buff_data_segm(segm_idx)(CQ_ENTRY_PHASE_TAG) = observed_phase_value_reg(resp_qidx)) then
                SQHDBL_UPD_DATA <= buff_data_segm(segm_idx)(CQ_ENTRY_SQHD) and DBL_MASK;
                CQHDBL_UPD_DATA <= std_logic_vector(cqhdbl_tmp);
                LAST_CQ_ENTRY   <= buff_data_segm(segm_idx);
                STATUS_UPD_EN   <= '1';

                cqhdbl_nst(resp_qidx) <= cqhdbl_tmp;

                -- If the doorbell is going to roll over to the beginning, the NVME controller
                -- starts to send CQ Entries with inverted Phase Tags.
                if (cqhdbl_tmp = x"0000") then
                    observed_phase_value_nst(resp_qidx) <= not observed_phase_value_reg(resp_qidx);
                end if;

                -- If valid data arrived and we are on the last segment of a word, set the next
                -- address to the transaction buffer -- targeting resp_qidx (the queue that just
                -- completed), overriding req_qidx/poll_qid_pst's round-robin choice for this cycle.
                if (segm_idx = 3) then
                    req_qidx := resp_qidx;
                    cq_page_base := shift_left(to_unsigned(req_qidx, cq_page_base'length), PAGE_OFFSET_W);
                    cq_word_addr := shift_left(resize(cqhdbl_tmp(15 downto 2), DATA_BUFF_RD_ADDR'length), 6);
                    DATA_BUFF_RD_ADDR <= std_logic_vector(cq_page_base + cq_word_addr);
                end if;
            end if;
        end if;

        -- Register the queue THIS cycle's actual read request targeted (req_qidx, including the
        -- segm_idx=3 override above) so next cycle's response -- arriving with the transaction
        -- buffer's fixed 1-cycle read latency -- is interpreted against the correct queue.
        resp_qid_nst <= req_qidx;
    end process;
end architecture;
