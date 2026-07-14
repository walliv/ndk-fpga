-- dbl_updater.vhd: Component that dispatches doorbell udpates over the PCIe bus
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;

-- The doorbell is written to the NVMe controller only when its value actually changes
-- (an on-change update). Re-writing an unchanged doorbell value is prohibited by the NVMe
-- specification ("Invalid Doorbell Write Value", Asynchronous Event Information 01h) and is
-- rejected by strict controllers, so no repeat/keep-alive re-write is performed.
entity DBL_UPDATER is

    generic (
        DEVICE : string := "ULTRASCALE";

        MFB_REGIONS     : positive := 2;
        MFB_REGION_SIZE : positive := 1;
        MFB_BLOCK_SIZE  : positive := 8;
        MFB_ITEM_WIDTH  : positive := 32;

        -- The maximum delay in clock cycles between the dispatch of two updates of DBL to the
        -- NVMe controller
        UPDATE_DELAY : positive := 10;

        -- Number of independent SQ/CQ queues (one per SSD). Each queue needs one SQ-tail and one
        -- CQ-head doorbell (see DBL_NUM below). At NUM_QUEUES=1 (the default) this design is
        -- bit-identical to the original 2-doorbell (CQHDBL, SQTDBL) implementation.
        NUM_QUEUES : positive := 1);

    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- Control interface
        -- =========================================================================================
        -- Per-queue PCIe destination address of the CQ-head/SQ-tail doorbell (all NUM_QUEUES
        -- addresses live simultaneously -- each queue's update-state machine below needs its own
        -- at all times, unlike *_DATA/_VLD/_QID which only ever describe one queue's event at a
        -- time). At NUM_QUEUES=1 these are 1-element arrays, identical to the original scalar
        -- ports.
        CQHDBL_BASE_ADDR : in slv_array_t(NUM_QUEUES -1 downto 0)(63 downto 0);
        CQHDBL_DATA      : in std_logic_vector(15 downto 0);
        CQHDBL_VLD       : in std_logic;
        -- Queue Identifier the CQHDBL_DATA/VLD pulse belongs to. Always "0" at NUM_QUEUES=1.
        CQHDBL_QID       : in std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);

        SQTDBL_BASE_ADDR : in slv_array_t(NUM_QUEUES -1 downto 0)(63 downto 0);
        SQTDBL_DATA      : in std_logic_vector(15 downto 0);
        SQTDBL_VLD       : in std_logic;
        -- Queue Identifier the SQTDBL_DATA/VLD pulse belongs to. Always "0" at NUM_QUEUES=1.
        SQTDBL_QID       : in std_logic_vector(maximum(1, log2(NUM_QUEUES)) -1 downto 0);

        -- =========================================================================================
        -- Status interface
        -- =========================================================================================
        CQHDBL_REG_UPD_DISP : out std_logic;
        SQTDBL_REG_UPD_DISP : out std_logic;

        -- =========================================================================================
        -- MFB for update dispatch
        -- =========================================================================================
        PCIE_RQ_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_RQ_MFB_META    : out std_logic_vector(MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
        PCIE_RQ_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        PCIE_RQ_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        PCIE_RQ_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        PCIE_RQ_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        PCIE_RQ_MFB_SRC_RDY : out std_logic;
        PCIE_RQ_MFB_DST_RDY : in  std_logic);

end entity;

architecture FULL of DBL_UPDATER is

    -- One SQ-tail and one CQ-head doorbell per queue: dbl_reg/dbl_base_addr indices 0..NUM_QUEUES-1
    -- are the N queues' CQHDBL, indices NUM_QUEUES..2*NUM_QUEUES-1 are the N queues' SQTDBL. At
    -- NUM_QUEUES=1 this is exactly the original 2-entry (CQHDBL=0, SQTDBL=1) layout.
    constant DBL_NUM : positive := 2*NUM_QUEUES;
    constant MFB_LENGTH : positive := MFB_REGIONS * MFB_REGION_SIZE * MFB_BLOCK_SIZE * MFB_ITEM_WIDTH;

    signal dbl_reg : slv_array_t(DBL_NUM -1 downto 0)(CQHDBL_DATA'range);
    signal dbl_base_addr : slv_array_t(DBL_NUM -1 downto 0)(63 downto 0);

    type update_state_t is (S_WAIT_FOR_UPDATE, S_RUN_COUNTER, S_DISPATCH_UPDATE);
    type all_update_states_t is array (DBL_NUM -1 downto 0) of update_state_t;
    signal update_pst : all_update_states_t := (others => S_WAIT_FOR_UPDATE);
    signal update_nst : all_update_states_t := (others => S_WAIT_FOR_UPDATE);

    signal last_updated_value_reg  : slv_array_t(DBL_NUM -1 downto 0)(CQHDBL_DATA'range);
    signal last_updated_value_next : slv_array_t(DBL_NUM -1 downto 0)(CQHDBL_DATA'range);
    signal delay_cntr_reg          : u_array_t(DBL_NUM -1 downto 0)(log2(UPDATE_DELAY) downto 0);
    signal delay_cntr_next         : u_array_t(DBL_NUM -1 downto 0)(log2(UPDATE_DELAY) downto 0);

    signal dbl_reg_upd_disp      : std_logic_vector(DBL_NUM -1 downto 0);

    -- Size of a PCIE RQ header and 2 pointers (HHP and HDP, that are aligned to 4 byte boundary)
    constant FIFO_DATA_W   : positive := 16 + 64;
    constant FIFO_WR_PORTS : positive := DBL_NUM;
    constant FIFO_RD_PORTS : positive := MFB_REGIONS;
    constant FIFO_SIZE     : positive := 16;

    signal fifo_din     : std_logic_vector(FIFO_WR_PORTS*FIFO_DATA_W -1 downto 0);
    signal fifo_din_arr : slv_array_t(FIFO_WR_PORTS-1 downto 0)(FIFO_DATA_W -1 downto 0);
    signal fifo_wr      : std_logic_vector(FIFO_WR_PORTS-1 downto 0);
    signal fifo_do      : std_logic_vector(FIFO_RD_PORTS*FIFO_DATA_W -1 downto 0);
    signal fifo_do_arr  : slv_array_t(FIFO_RD_PORTS-1 downto 0)(FIFO_DATA_W -1 downto 0);
    signal fifo_full    : std_logic;
    signal fifo_rd      : std_logic_vector(FIFO_RD_PORTS-1 downto 0);
    signal fifo_empty   : std_logic_vector(FIFO_RD_PORTS-1 downto 0);

    signal tx_mfb_data_arr    : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH -1 downto 0);
    signal tx_mfb_meta_arr    : slv_array_t(MFB_REGIONS -1 downto 0)(PCIE_RQ_META_WIDTH -1 downto 0);
    signal tx_mfb_eof_pos_arr : slv_array_t(MFB_REGIONS -1 downto 0)(maximum(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
begin

    -- One process per queue (q is a generate-time constant, so each instance's dbl_reg(q)/
    -- dbl_reg(NUM_QUEUES+q) target is a static name -- a single, unambiguous driver per element).
    -- Splitting this across two SEPARATE processes that each dynamically indexed the SAME
    -- dbl_reg signal (by CQHDBL_QID/SQTDBL_QID) would make VHDL treat the whole dbl_reg array as
    -- driven by both processes (the longest *static* prefix of a variable-indexed target is the
    -- whole signal), corrupting every element to 'X' via driver contention -- hence the
    -- generate-per-queue structure instead. At NUM_QUEUES=1 this is exactly the original
    -- dbl_reg(0)<=CQHDBL_DATA/dbl_reg(1)<=SQTDBL_DATA behavior (the qid compare is always true).
    dbl_reg_wr_g : for q in 0 to NUM_QUEUES -1 generate
        cqhdbl_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (RST = '1') then
                    dbl_reg(q) <= (others => '0');
                elsif (CQHDBL_VLD = '1' and to_integer(unsigned(CQHDBL_QID)) = q) then
                    dbl_reg(q) <= CQHDBL_DATA;
                end if;
            end if;
        end process;

        sqtdbl_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (RST = '1') then
                    dbl_reg(NUM_QUEUES + q) <= (others => '0');
                elsif (SQTDBL_VLD = '1' and to_integer(unsigned(SQTDBL_QID)) = q) then
                    dbl_reg(NUM_QUEUES + q) <= SQTDBL_DATA;
                end if;
            end if;
        end process;
    end generate;

    dbl_update_logic_g : for idx in (DBL_NUM -1) downto 0 generate
        update_state_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (RST = '1') then
                    update_pst(idx)             <= S_WAIT_FOR_UPDATE;
                    last_updated_value_reg(idx) <= (others => '0');
                    delay_cntr_reg(idx)         <= (others => '0');
                else
                    update_pst(idx)             <= update_nst(idx);
                    last_updated_value_reg(idx) <= last_updated_value_next(idx);
                    delay_cntr_reg(idx)         <= delay_cntr_next(idx);
                end if;
            end if;
        end process;

        update_state_nst_logic_p : process (all) is
        begin
            update_nst(idx)              <= update_pst(idx);
            last_updated_value_next(idx) <= last_updated_value_reg(idx);
            delay_cntr_next(idx)         <= delay_cntr_reg(idx);
            fifo_wr(idx)                 <= '0';
            dbl_reg_upd_disp(idx)        <= '0';

            case update_pst(idx) is
                when S_WAIT_FOR_UPDATE =>

                    -- The dispatch can take place if the PCIe address is not zero and the doorbell
                    -- value has changed since the last update. An unchanged value is never
                    -- re-written (that would be a prohibited "Invalid Doorbell Write Value").
                    if (dbl_base_addr(idx) /= x"0000000000000000") then
                        if (dbl_reg(idx) /= last_updated_value_reg(idx)) then
                            update_nst(idx)      <= S_DISPATCH_UPDATE;
                            delay_cntr_next(idx) <= delay_cntr_reg(idx) + 1;
                        end if;
                    end if;

                when S_RUN_COUNTER =>
                    delay_cntr_next(idx) <= delay_cntr_reg(idx) + 1;

                    if (delay_cntr_reg(idx) >= UPDATE_DELAY) then
                        if (dbl_reg(idx) /= last_updated_value_reg(idx)) then
                            fifo_wr(idx)         <= '1';
                            delay_cntr_next(idx) <= (others => '0');

                            if (fifo_full = '0') then
                                update_nst(idx)              <= S_WAIT_FOR_UPDATE;
                                last_updated_value_next(idx) <= dbl_reg(idx);
                                dbl_reg_upd_disp(idx)        <= '1';
                            else
                                update_nst(idx) <= S_DISPATCH_UPDATE;
                            end if;
                        else
                            update_nst(idx) <= S_WAIT_FOR_UPDATE;
                            delay_cntr_next(idx) <= (others => '0');
                        end if;
                    end if;

                when S_DISPATCH_UPDATE =>
                    fifo_wr(idx) <= '1';

                    if (fifo_full = '0') then
                        update_nst(idx)              <= S_RUN_COUNTER;
                        last_updated_value_next(idx) <= dbl_reg(idx);
                        dbl_reg_upd_disp(idx)        <= '1';
                    end if;
            end case;
        end process;
    end generate;

    -- Per-queue base addresses/dbl_reg mapping: indices 0..NUM_QUEUES-1 = CQHDBL[q], indices
    -- NUM_QUEUES..2*NUM_QUEUES-1 = SQTDBL[q]. At NUM_QUEUES=1 this is exactly the original
    -- fifo_din_arr(0)<=CQHDBL, fifo_din_arr(1)<=SQTDBL assignment.
    dbl_din_arr_g : for q in 0 to NUM_QUEUES -1 generate
        fifo_din_arr(q)              <= dbl_reg(q) & CQHDBL_BASE_ADDR(q);
        fifo_din_arr(NUM_QUEUES + q)  <= dbl_reg(NUM_QUEUES + q) & SQTDBL_BASE_ADDR(q);
        dbl_base_addr(q)             <= CQHDBL_BASE_ADDR(q);
        dbl_base_addr(NUM_QUEUES + q) <= SQTDBL_BASE_ADDR(q);
    end generate;

    -- Status pulses stay system-wide (any queue's update dispatching), not per-queue -- the
    -- original scalar semantics generalized via reduction; at NUM_QUEUES=1 each reduction is over
    -- a single bit, exactly the original dbl_reg_upd_disp(0)/(1).
    CQHDBL_REG_UPD_DISP <= or (dbl_reg_upd_disp(NUM_QUEUES -1 downto 0));
    SQTDBL_REG_UPD_DISP <= or (dbl_reg_upd_disp(2*NUM_QUEUES -1 downto NUM_QUEUES));

    -- =============================================================================================
    -- Dispatch FIFO where all of the update requests get collected
    -- =============================================================================================
    fifo_din <= slv_array_ser(fifo_din_arr);

    fifo_i : entity work.FIFOX_MULTI(FULL)
        generic map (
            DATA_WIDTH          => FIFO_DATA_W,
            ITEMS               => FIFO_SIZE,
            WRITE_PORTS         => FIFO_WR_PORTS,
            READ_PORTS          => FIFO_RD_PORTS,
            RAM_TYPE            => "AUTO",
            DEVICE              => DEVICE,
            ALMOST_FULL_OFFSET  => 2,
            ALMOST_EMPTY_OFFSET => 2,
            ALLOW_SINGLE_FIFO   => FALSE,
            SAFE_READ_MODE      => FALSE
            )
        port map (
            CLK   => CLK,
            RESET => RST,

            DI    => fifo_din,
            WR    => fifo_wr,
            FULL  => fifo_full,
            AFULL => open,

            DO     => fifo_do,
            RD     => fifo_rd,
            EMPTY  => fifo_empty,
            AEMPTY => open
            );

    fifo_do_arr <= slv_array_deser(fifo_do, MFB_REGIONS);

    pcie_rq_meta_assign_g : for rgn in 0 to (FIFO_RD_PORTS -1) generate
        signal dbl_upd_pcie_hdr : std_logic_vector(PCIE_META_REQ_HDR_W -1 downto 0);
    begin
        dbl_upd_pcie_hdr_gen_i : entity work.PCIE_RQ_HDR_GEN
            generic map (
                DEVICE => DEVICE
                )
            port map (
                IN_ADDRESS    => fifo_do_arr(rgn)(63 downto 2),
                IN_VFID       => std_logic_vector(to_unsigned(1, 8)),
                IN_TAG        => (others => '0'),
                IN_DW_CNT     => std_logic_vector(to_unsigned(1, 11)),
                IN_ATTRIBUTES => "001",
                IN_FBE        => "1111",
                IN_LBE        => "0000",
                IN_ADDR_LEN   => '1',   -- NOTE: needs to be dynamic for Intel devices
                IN_REQ_TYPE   => '1',   -- always write
                OUT_HEADER    => dbl_upd_pcie_hdr
                );
        tx_mfb_data_arr(rgn) <= (MFB_LENGTH/MFB_REGIONS -1 downto PCIE_META_REQ_HDR_W + 16 => '0')
                                & fifo_do_arr(rgn)(16+64 -1 downto 64) & dbl_upd_pcie_hdr;
        tx_mfb_eof_pos_arr(rgn) <= std_logic_vector(to_unsigned(4, PCIE_RQ_MFB_EOF_POS'length/MFB_REGIONS));
        tx_mfb_meta_arr(rgn)    <= (PCIE_RQ_META_FBE => "1111", PCIE_RQ_META_LBE => "0000", others => '0');
    end generate;

    PCIE_RQ_MFB_DATA    <= slv_array_ser(tx_mfb_data_arr);
    PCIE_RQ_MFB_META    <= slv_array_ser(tx_mfb_meta_arr);
    PCIE_RQ_MFB_SOF     <= not fifo_empty;
    PCIE_RQ_MFB_EOF     <= not fifo_empty;
    PCIE_RQ_MFB_SOF_POS <= (others => '0');
    PCIE_RQ_MFB_EOF_POS <= slv_array_ser(tx_mfb_eof_pos_arr);
    PCIE_RQ_MFB_SRC_RDY <= or (not fifo_empty);
    fifo_rd             <= (not fifo_empty) and PCIE_RQ_MFB_DST_RDY;
end architecture;
