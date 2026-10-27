-- tx_dma_pcie_trans_buffer_banked.vhd: row-banked PCIe transaction buffer built from XPM memories
-- Copyright (C) 2023 CESNET z.s.p.o.
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--            David Benes      <xbenes52@vutbr.cz>
--            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.tx_dma_pcie_trans_buffer_pkg.all;

-- XPM memory macros are instantiated directly rather than inferred, so the write mode is stated
-- explicitly (see the DEVICE assertion and XPM_WRITE_MODE below).
library xpm;
use xpm.vcomponents.all;

architecture BANKED of TX_DMA_PCIE_TRANS_BUFFER_IMPL is

    constant MFB_LENGTH         : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    -- Number of Dwords in MFB word (equal as the nummber of items)
    constant MFB_DWORDS         : natural := MFB_LENGTH/MFB_ITEM_WIDTH;
    -- Number of bytes in MFB word
    constant MFB_BYTES          : natural := MFB_LENGTH/8;
    -- The Address is restricted by BAR_APERTURE (IP_core setting)
    constant BUFFER_DEPTH       : natural := trbuf_buffer_depth_f(POINTER_WIDTH, MFB_LENGTH);
    -- Number of registers between BARREL_SHIFTERs and memory arrays
    constant BRAM_REG_NUM       : natural := 2;
    -- Every AMD device this component can be built for (see the DEVICE assertion below).
    constant IS_AMD_DEV         : boolean := (DEVICE = "7SERIES" or DEVICE = "ULTRASCALE" or DEVICE = "VERSAL");

    -- a maximum depth of a memory block (in 1B items) depends on the memory primitive
    constant MAX_MEM_DEPTH   : natural := tsel(RAM_TYPE = "URAM", TRBUF_DEPTH_URAM, TRBUF_DEPTH_BRAM);
    -- The amount of channels that fits into one array
    constant CHANS_PER_ARRAY : natural := trbuf_chans_per_array_f(CHANNELS, BUFFER_DEPTH, MAX_MEM_DEPTH);
    -- Number of memory arrays since one array can contain multiple channels
    constant MEM_ARRAYS      : natural := CHANNELS/CHANS_PER_ARRAY;
    -- Total rows (of one whole MFB word) per array
    constant ARRAY_ROWS      : natural := CHANS_PER_ARRAY * BUFFER_DEPTH;
    -- Depth of each of the two even/odd row banks
    constant BANK_ITEMS      : natural := ARRAY_ROWS / 2;
    constant BANK_ADDR_W     : natural := log2(BANK_ITEMS);

    -- ==== XPM_MEMORY_TDPRAM configuration for the memory arrays below ====
    constant XPM_MEM_PRIMITIVE : string  := tsel(RAM_TYPE = "URAM", "ultra", "block");

    -- Total array size IN BITS (XPM's MEMORY_SIZE unit), per bank.
    constant XPM_MEMORY_SIZE   : natural := BANK_ITEMS * MFB_LENGTH;

    -- Write mode "no_change" on both primitives. A BRAM read colliding with a same-address write is
    -- undefined (UG573 Table 3), so rd_xrgn_collision (2 regions) and rd_1rgn_collision (1 region)
    -- withhold RD_DATA_VLD for it and the reader retries.
    constant XPM_WRITE_MODE    : string  := "no_change";

    -- Width of the (registered) target-array index; at least 1 bit even when MEM_ARRAYS = 1
    constant ARR_IDX_W       : natural := max(1, log2(MEM_ARRAYS));

    -- ==== Flat (unpartitioned) addressing -- see the MEM_PARTITIONING generic ====
    constant FLAT             : boolean := (not MEM_PARTITIONING) and (CHANNELS > 1);
    -- LSB, within the write META DWord-address, of the flat channel-select field (the read byte
    -- address carries it starting at bit POINTER_WIDTH). It sits directly above the intra-channel row.
    constant FLAT_CHAN_LSB_DW : natural := log2(BUFFER_DEPTH) + log2(MFB_DWORDS);
    -- LSB of the memory-array-select sub-field within the flat channel-select field
    constant FLAT_ARR_LSB_DW  : natural := FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY);

    -- The input word behind the input registers of the write front end and the fields of its META
    signal wr_src_rdy               : std_logic;
    signal wr_sof                   : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal wr_addr                  : slv_array_t(MFB_REGIONS -1 downto 0)(TRBUF_META_PCIE_ADDR_W -1 downto 0);
    signal wr_chan                  : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);

    -- counter of the address for each valid word following the beginning of the transaction
    signal wr_addr_cntr             : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
    signal addr_cntr_pst            : unsigned(TRBUF_META_PCIE_ADDR_W -1 downto 0);

    -- Stores the index of the packet that get currently stored
    signal chan_num_reg             : std_logic_vector(log2(CHANNELS) -1 downto 0);

    -- control of the amount of shift on the writing barrel shifters
    signal wr_shift_sel             : slv_array_t(MFB_REGIONS - 1 downto 0)(log2(MFB_LENGTH/32) -1 downto 0);

    signal wr_be_bram_bshifter      : slv_array_t(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0);
    signal wr_data_bram_bshifter    : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_LENGTH -1 downto 0);

    signal mem_arr_idx_reg          : std_logic_vector(ARR_IDX_W -1 downto 0);

    -- Write path: per-region even/odd bank write-enable and bank address (combinational)
    signal wr_bank_be   : slv_array_2d_t(MFB_REGIONS -1 downto 0)(1 downto 0)(MFB_BYTES -1 downto 0);
    signal wr_bank_addr : slv_array_2d_t(MFB_REGIONS -1 downto 0)(1 downto 0)(BANK_ADDR_W -1 downto 0);

    -- The registered per-region target memory-array index (only meaningful when MEM_ARRAYS > 1)
    signal arr_idx_rgn     : slv_array_t(MFB_REGIONS -1 downto 0)(ARR_IDX_W -1 downto 0);

    -- Registers between the barrel shifters and the memory arrays
    signal wr_bank_be_reg           : slv_array_3d_t(BRAM_REG_NUM downto 0)(MFB_REGIONS -1 downto 0)(1 downto 0)(MFB_BYTES -1 downto 0);
    signal wr_bank_addr_reg         : slv_array_3d_t(BRAM_REG_NUM downto 0)(MFB_REGIONS -1 downto 0)(1 downto 0)(BANK_ADDR_W -1 downto 0);
    signal wr_data_bram_shifter_reg : slv_array_2d_t(BRAM_REG_NUM downto 0)(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal arr_idx_rgn_reg          : slv_array_2d_t(BRAM_REG_NUM downto 0)(MFB_REGIONS -1 downto 0)(ARR_IDX_W -1 downto 0);

    -- Per-array, per-region, per-bank write enable (i.e. after the target-array demux) and a
    -- per-array/per-region write-activity flag (used for write-priority read stalls and, on the
    -- 2-region/TDP path, for read/write address muxing)
    signal we        : slv_array_3d_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0)(1 downto 0)(MFB_BYTES -1 downto 0);
    signal wr_active : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);

    -- Read/Write address mux (TDP/2-region path only) and the memory enable/write-priority read
    -- enable derived from it
    signal rw_addr_bram_by_mux : slv_array_3d_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0)(1 downto 0)(BANK_ADDR_W -1 downto 0);
    signal tdp_ena             : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_en_pch           : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_xrgn_collision   : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_en_bram_demux    : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_data_valid_arr   : std_logic_vector(MFB_REGIONS -1 downto 0);

    -- Memory array read data, indexed [bank][array][region]
    signal rd_data_bram_bank   : slv_array_3d_t(1 downto 0)(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);

    -- ==== Read path signals ====
    -- READ_LATENCY's third cycle, when asked for, is spent HERE and not in the memory: the XPM
    -- output register stays at 2 (XPM_RD_LATENCY) and rd_req_reg_g adds the request stage.
    constant RD_REQ_REG     : boolean := (READ_LATENCY = 3);
    constant XPM_RD_LATENCY : natural := tsel(READ_LATENCY >= 2, 2, 1);

    -- The read request as the rest of this architecture sees it: the ports themselves, or their
    -- registered copies at READ_LATENCY => 3 (see rd_req_reg_g). Every downstream stage is fed
    -- from these, so the internal pipeline alignment is the same at 2 and 3.
    signal rd_addr_a_q : std_logic_vector(RD_ADDR_A'range);
    signal rd_addr_b_q : std_logic_vector(RD_ADDR_B'range);
    signal rd_chan_a_q : std_logic_vector(RD_CHAN_A'range);
    signal rd_chan_b_q : std_logic_vector(RD_CHAN_B'range);
    signal rd_en_a_q   : std_logic;
    signal rd_en_b_q   : std_logic;

    -- Effective RD_ADDR/RD_CHAN per region-slot: with SPLIT_READ_PORTS, slot P maps 1:1 to a port;
    -- else both broadcast from port A and race the same read (the unstalled one succeeds).
    signal rd_addr_eff : slv_array_t(MFB_REGIONS -1 downto 0)(POINTER_WIDTH -1 downto 0);
    signal rd_chan_eff : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);

    -- A broadcast port A read may be served by either region slot and is assembled with port A's
    -- shifter, so only split read ports give a slot its own READ_BARREL_SHIFTER_EN entry.
    function slot_shifter_en_f (p : natural) return boolean is
    begin
        if (SPLIT_READ_PORTS and MFB_REGIONS = 2) then
            return READ_BARREL_SHIFTER_EN(p);
        end if;
        return READ_BARREL_SHIFTER_EN(0);
    end function;

    signal rd_bank_addr : slv_array_2d_t(MFB_REGIONS -1 downto 0)(1 downto 0)(BANK_ADDR_W -1 downto 0);

    signal rd_chan_p_reg  : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);
    signal rd_off_reg     : slv_array_t(MFB_REGIONS -1 downto 0)(log2(MFB_BYTES) -1 downto 0);
    signal rd_row_lsb_reg : std_logic_vector(MFB_REGIONS -1 downto 0);

    -- Cycle-1 copies of the above; at READ_LATENCY=1 these ARE rd_chan_p_reg/rd_off_reg/rd_row_lsb_reg
    -- (rd_pipe_lat1_g); at =2 one more register (rd_pipe_lat2_g) re-aligns with the XPM output
    -- register's extra BRAM cycle.
    signal rd_chan_p_reg_stg1  : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);
    signal rd_off_reg_stg1     : slv_array_t(MFB_REGIONS -1 downto 0)(log2(MFB_BYTES) -1 downto 0);
    signal rd_row_lsb_reg_stg1 : std_logic_vector(MFB_REGIONS -1 downto 0);

    signal rd_data_bank0_mux : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_data_bank1_mux : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_data_assembled : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);

    -- Read ports with an output stage: one per region slot with split read ports, else port A only, fed with the slot
    -- that serves the read.
    constant RD_PORTS : natural := tsel(SPLIT_READ_PORTS and MFB_REGIONS = 2, 2, 1);

    signal rd_out_bank0      : slv_array_t(RD_PORTS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_out_bank1      : slv_array_t(RD_PORTS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_out_assembled  : slv_array_t(RD_PORTS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_data_out       : slv_array_t(RD_PORTS -1 downto 0)(MFB_LENGTH -1 downto 0);

    -- =============================================================================================
    -- DEBUG signals (verification or ILA)
    -- =============================================================================================
    signal wr_addr_collision_detected : slv_array_t(MEM_ARRAYS -1 downto 0)(1 downto 0);
    signal rdwr_collision_detected    : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);

    -- Flat copy of wr_bank_addr(0)(0)'s chan_addr_v (see wr_bank_geom_p), for the PSL checks below:
    -- nvc's prev() rejects a slice taken directly from a nested array-of-array-of-vector signal.
    signal wr_chan_slot_r0     : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);

    -- ==== Bank addressing ====
    -- The bank whose index equals the row's parity gets the row, the other bank the next row; the two always lie in
    -- different banks (see readme.rst).
    function bank_addr_f (chan : std_logic_vector; row : std_logic_vector) return slv_array_t is
        variable row_v    : std_logic_vector(row'length -1 downto 0);
        variable row_p1_v : std_logic_vector(row'length -1 downto 0);
        variable res      : slv_array_t(1 downto 0)(chan'length + row'length -2 downto 0);
    begin
        row_v    := row;
        row_p1_v := std_logic_vector(unsigned(row_v) + 1);
        if (row_v(0) = '0') then
            res(0) := chan & row_v   (row_v'high downto 1);
            res(1) := chan & row_p1_v(row_v'high downto 1);
        else
            res(0) := chan & row_p1_v(row_v'high downto 1);
            res(1) := chan & row_v   (row_v'high downto 1);
        end if;
        return res;
    end function;

    -- ==== Bank assembly ====
    -- Byte i comes from bank 0 unless its row wraps into the next via the intra-word shift.
    function assemble_bank_bytes (
        row_lsb : std_logic;
        off     : std_logic_vector;
        bank0   : std_logic_vector;
        bank1   : std_logic_vector
    ) return std_logic_vector is
        variable res   : std_logic_vector(bank0'length -1 downto 0);
        variable carry : std_logic;
    begin
        for i in 0 to (bank0'length/8 -1) loop
            if (i < unsigned(off)) then
                carry := '1';
            else
                carry := '0';
            end if;

            if ((row_lsb xor carry) = '0') then
                res(i*8 +7 downto i*8) := bank0(bank0'low + i*8 +7 downto bank0'low + i*8);
            else
                res(i*8 +7 downto i*8) := bank1(bank1'low + i*8 +7 downto bank1'low + i*8);
            end if;
        end loop;
        return res;
    end function;

    -- The two detection signals reduced to one bit each, so that a PSL assertion can check them.
    signal wr_addr_collision : std_logic;
    signal rdwr_collision    : std_logic;

begin

    assert (
        (MFB_REGIONS = 2 and SPLIT_READ_PORTS)
        or (MFB_REGIONS = 1 and (not SPLIT_READ_PORTS))
        or (MFB_REGIONS = 2 and (not SPLIT_READ_PORTS))
        )
        report "TX_DMA_PCIE_TRANS_BUFFER: The configuration with split ports is only allowed for a 2-region setting!"
        severity FAILURE;

    assert (BUFFER_DEPTH >= 2)
        report "TX_DMA_PCIE_TRANS_BUFFER: POINTER_WIDTH is too small, BUFFER_DEPTH must be at least 2 rows for the even/odd row banking scheme to apply!"
        severity FAILURE;

    assert (RAM_TYPE = "URAM" or RAM_TYPE = "BRAM")
        report "TX_DMA_PCIE_TRANS_BUFFER_BANKED: RAM_TYPE must be the resolved primitive, URAM or BRAM!"
        severity FAILURE;

    -- AMD-only: the memory arrays are AMD XPM (XPM_MEMORY_TDPRAM) macros with no Intel/Altera
    -- equivalent, hence this explicit check; the write mode is also stated here rather than
    -- inferred (see XPM_WRITE_MODE).
    assert (IS_AMD_DEV)
        report "TX_DMA_PCIE_TRANS_BUFFER: DEVICE => " & DEVICE & " is not supported -- the memory "
               & "arrays are AMD XPM macros, so DEVICE must be one of 7SERIES/ULTRASCALE/VERSAL!"
        severity FAILURE;

    -- Elaboration-time, not PSL: READ_BARREL_SHIFTER_EN's subtype (b_array_t(MFB_REGIONS-1 downto 0))
    -- already forces exactly MFB_REGIONS elements; this just guards that contract explicitly.
    assert (READ_BARREL_SHIFTER_EN'length = MFB_REGIONS)
        report "TX_DMA_PCIE_TRANS_BUFFER: READ_BARREL_SHIFTER_EN must have exactly MFB_REGIONS elements!"
        severity FAILURE;

    assert (READ_LATENCY >= 1 and READ_LATENCY <= 3)
        report "TX_DMA_PCIE_TRANS_BUFFER: READ_LATENCY must be 1 (no output register), 2 (XPM output register) or 3 (plus a request register)!"
        severity FAILURE;

    -- The extra stage of READ_LATENCY >= 2 only exists on the TDP (2-region) read-valid/pipe registers
    -- (rd_vld_p/rd_pipe_reg_p); the SDP path (MFB_REGIONS=1) keeps a fixed 1-cycle RD_DATA_VLD_A,
    -- so this combination is unsupported.
    assert (not (READ_LATENCY >= 2 and MFB_REGIONS = 1))
        report "TX_DMA_PCIE_TRANS_BUFFER: READ_LATENCY => 2 or 3 is only implemented for the 2-region (TDP) read path!"
        severity FAILURE;

    wr_front_i : entity work.TX_DMA_PCIE_TRANS_BUFFER_WR_FRONT
    generic map (
        CHANNELS => CHANNELS,

        MFB_REGIONS     => MFB_REGIONS,
        MFB_REGION_SIZE => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,

        CHANS_PER_ARRAY => CHANS_PER_ARRAY,
        MEM_ARRAYS      => MEM_ARRAYS,

        INP_REG_NUM => INP_REG_NUM
    )
    port map (
        CLK   => CLK,
        RESET => RESET,

        PCIE_MFB_DATA    => PCIE_MFB_DATA,
        PCIE_MFB_META    => PCIE_MFB_META,
        PCIE_MFB_SOF     => PCIE_MFB_SOF,
        PCIE_MFB_SRC_RDY => PCIE_MFB_SRC_RDY,

        WR_SRC_RDY => wr_src_rdy,
        WR_SOF     => wr_sof,
        WR_ADDR    => wr_addr,
        WR_CHAN    => wr_chan,

        WR_SHIFT     => wr_shift_sel,
        WR_DATA      => wr_data_bram_bshifter,
        WR_BE        => wr_be_bram_bshifter,

        ADDR_CNTR   => wr_addr_cntr,
        CHAN_NUM    => chan_num_reg,
        MEM_ARR_IDX => mem_arr_idx_reg
    );

    addr_cntr_pst <= unsigned(wr_addr_cntr);

    -- psl default clock is rising_edge(CLK);

    -- ==== Write bank geometry ====
    -- Even/odd bank per byte, plus the banks' shared row address. Only region 0 continues a frame of an earlier word, a
    -- later region writes from its own SOF only.
    wr_bank_geom_g : for rgn in 0 to (MFB_REGIONS -1) generate
        wr_bank_geom_p : process (all) is
            variable pcie_mfb_meta_addr_v : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
            variable buff_addr_v          : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
            variable chan_addr_v          : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            variable carry_sel_v          : std_logic_vector(log2(MFB_DWORDS) -1 downto 0);
            variable carry_v              : std_logic;
        begin
            wr_bank_be(rgn)   <= (others => (others => '0'));
            wr_bank_addr(rgn) <= (others => (others => '0'));

            if (wr_src_rdy = '1' and (wr_sof(rgn) = '1' or rgn = 0)) then
                if (wr_sof(rgn) = '1') then
                    pcie_mfb_meta_addr_v := wr_addr(rgn);
                    chan_addr_v          := wr_chan(rgn)(log2(CHANS_PER_ARRAY) -1 downto 0);
                else
                    pcie_mfb_meta_addr_v := std_logic_vector(addr_cntr_pst);
                    chan_addr_v          := chan_num_reg(log2(CHANS_PER_ARRAY) -1 downto 0);
                end if;
                buff_addr_v := pcie_mfb_meta_addr_v(log2(BUFFER_DEPTH)+log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS));

                -- FLAT: the intra-array channel slot comes from the address just above the row, which also lets a frame
                -- cross a channel boundary; else from the channel field. buff_addr_v (the intra-channel row) is
                -- unchanged either way.
                if (FLAT) then
                    chan_addr_v := pcie_mfb_meta_addr_v(FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY) -1 downto FLAT_CHAN_LSB_DW);
                end if;

                wr_bank_addr(rgn) <= bank_addr_f(chan_addr_v, buff_addr_v);

                -- The row a byte's DWord belongs to follows the raw address: region 1's shift has the "-8" correction
                -- of the barrel shifter control, region 0's equals its raw address.
                if (rgn = 0) then
                    carry_sel_v := wr_shift_sel(0);
                else
                    carry_sel_v := pcie_mfb_meta_addr_v(log2(MFB_DWORDS) -1 downto 0);
                end if;

                -- Distribute the (already rotated) byte-enable bits to the bank each byte's row lives in
                for i in 0 to (MFB_BYTES -1) loop
                    if ((i/4) < unsigned(carry_sel_v)) then
                        carry_v := '1';
                    else
                        carry_v := '0';
                    end if;

                    if ((buff_addr_v(0) xor carry_v) = '0') then
                        wr_bank_be(rgn)(0)(i) <= wr_be_bram_bshifter(rgn)(i);
                    else
                        wr_bank_be(rgn)(1)(i) <= wr_be_bram_bshifter(rgn)(i);
                    end if;
                end loop;
            end if;
        end process;
    end generate;

    -- Verify each mode reads the write channel-slot bits (chan_addr_v, upper log2(CHANS_PER_ARRAY)
    -- bits of wr_bank_addr(0)) from its OWN field -- regression guard against the other mode's
    -- field leaking in, checked at SOF.
    wr_chan_slot_r0 <= wr_bank_addr(0)(0)(BANK_ADDR_W -1 downto BANK_ADDR_W - log2(CHANS_PER_ARRAY));

    -- psl assert_flat_wr_chan_from_addr : assert always
    -- ((FLAT and wr_src_rdy = '1' and wr_sof(0) = '1') ->
    -- wr_chan_slot_r0 = wr_addr(0)(FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY) -1 downto FLAT_CHAN_LSB_DW))
    -- report "flat mode: region 0's write channel-slot did not come from the address field";

    -- psl assert_part_wr_chan_from_field : assert always
    -- ((not FLAT and wr_src_rdy = '1' and wr_sof(0) = '1') ->
    -- wr_chan_slot_r0 = wr_chan(0)(log2(CHANS_PER_ARRAY) -1 downto 0))
    -- report "partitioned mode: region 0's write channel-slot did not come from the channel field";

    -- ==== Input-stream guard ====
    -- Quasi-BRAM-writing MFB variant: no EOF/DST_RDY, so EOF/SOF and DATA-META-stable checks don't
    -- apply; only checkable invariant: a deasserted (registered) SRC_RDY must never itself produce
    -- write byte-enables.

    mfb_idle_assert_g : for rgn in 0 to (MFB_REGIONS -1) generate
    begin
        -- psl assert_no_write_when_idle : assert always
        -- (wr_src_rdy = '0' ->
        -- (wr_bank_be(rgn)(0) = (MFB_BYTES -1 downto 0 => '0') and wr_bank_be(rgn)(1) = (MFB_BYTES -1 downto 0 => '0')))
        -- report "a region produced write byte-enables while its registered SRC_RDY was low";
    end generate;

    -- ==== Per-region target-array index ====
    mem_arr_indx_hold_g: if (MEM_ARRAYS > 1) generate
        -- Per-region target-array index (arr_idx_rgn); see its declaration above for why it is only
        -- ever compared, never indexed.
        arr_idx_rgn_logic_p : process (all) is
            variable chan_v      : std_logic_vector(log2(CHANNELS) -1 downto 0);
            variable pcie_addr_v : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
        begin
            arr_idx_rgn <= (others => (others => '0'));

            for i in 0 to (MFB_REGIONS - 1) loop
                if (wr_src_rdy = '1') then
                    if (wr_sof(i) = '1') then
                        -- FLAT: memory-array select from the address; else from the channel field
                        if (FLAT) then
                            pcie_addr_v    := wr_addr(i);
                            arr_idx_rgn(i) <= pcie_addr_v(FLAT_ARR_LSB_DW + log2(MEM_ARRAYS) -1 downto FLAT_ARR_LSB_DW);
                        else
                            chan_v         := wr_chan(i);
                            arr_idx_rgn(i) <= chan_v(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY));
                        end if;
                    else
                        -- FLAT: track the running address so a frame may cross array boundaries
                        if (FLAT) then
                            arr_idx_rgn(i) <= std_logic_vector(addr_cntr_pst(FLAT_ARR_LSB_DW + log2(MEM_ARRAYS) -1 downto FLAT_ARR_LSB_DW));
                        else
                            arr_idx_rgn(i) <= mem_arr_idx_reg;
                        end if;
                    end if;
                end if;
            end loop;
        end process;
    end generate;

    -- =============================================================================================
    -- Registers between BARREL_SHIFTERs and memory arrays
    -- =============================================================================================
    wr_bank_be_reg          (0) <= wr_bank_be;
    wr_bank_addr_reg        (0) <= wr_bank_addr;
    wr_data_bram_shifter_reg(0) <= wr_data_bram_bshifter;
    arr_idx_rgn_reg         (0) <= arr_idx_rgn;

    bram_input_reg_mult_g: if (BRAM_REG_NUM > 0) generate
        bram_input_reg_g : for i in 0 to BRAM_REG_NUM - 1 generate
            bram_input_reg_p : process (CLK) is
            begin
                if rising_edge(CLK) then
                    wr_bank_be_reg          (i + 1) <= wr_bank_be_reg          (i);
                    wr_bank_addr_reg        (i + 1) <= wr_bank_addr_reg        (i);
                    wr_data_bram_shifter_reg(i + 1) <= wr_data_bram_shifter_reg(i);
                    arr_idx_rgn_reg         (i + 1) <= arr_idx_rgn_reg         (i);
                end if;
            end process;
        end generate;
    end generate;

    -- =============================================================================================
    -- Per-array write-enable demux (post register stage)
    -- =============================================================================================
    we_demux_multi_g : if (MEM_ARRAYS > 1) generate
        we_demux_arr_g : for a in 0 to (MEM_ARRAYS -1) generate
            we_demux_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
                we_demux_bank_g : for b in 0 to 1 generate
                    we(a)(rgn)(b) <= wr_bank_be_reg(BRAM_REG_NUM)(rgn)(b) when (arr_idx_rgn_reg(BRAM_REG_NUM)(rgn) = std_logic_vector(to_unsigned(a, ARR_IDX_W))) else (others => '0');
                end generate;
            end generate;
        end generate;
    else generate
        we_demux_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
            we_demux_bank_g : for b in 0 to 1 generate
                we(0)(rgn)(b) <= wr_bank_be_reg(BRAM_REG_NUM)(rgn)(b);
            end generate;
        end generate;
    end generate;

    wr_active_g : for a in 0 to (MEM_ARRAYS -1) generate
        wr_active_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
            wr_active(a)(rgn) <= (or we(a)(rgn)(0)) or (or we(a)(rgn)(1));
        end generate;
    end generate;

    -- ==== Memory array, one region (SDP, no stall) ====
    -- One write-only + one read-only port; half the RAMB36s of the 2-region TDP below for the same
    -- row width. One-cycle RD_DATA_VLD latency (no output register), matching RD_EN -> RD_DATA_VLD.
    sdp_ram_g: if (MFB_REGIONS = 1) generate
        brams_for_channels_g : for mem_arr_idx in 0 to (MEM_ARRAYS -1) generate
            banks_g : for bnk in 0 to 1 generate
                xpm_mem_i : component xpm_memory_sdpram
                generic map (
                    MEMORY_SIZE             => XPM_MEMORY_SIZE,
                    MEMORY_PRIMITIVE        => XPM_MEM_PRIMITIVE,
                    CLOCKING_MODE           => "common_clock",
                    MEMORY_INIT_FILE        => "none",
                    MEMORY_INIT_PARAM       => "0",
                    USE_MEM_INIT            => 0,
                    WAKEUP_TIME             => "disable_sleep",
                    MESSAGE_CONTROL         => 0,
                    ECC_MODE                => "no_ecc",
                    AUTO_SLEEP_TIME         => 0,
                    USE_EMBEDDED_CONSTRAINT => 0,
                    MEMORY_OPTIMIZATION     => "true",

                    -- BYTE_WRITE_WIDTH_A = 8 is what makes this a byte-enabled array (WEA is then
                    -- MFB_LENGTH/8 wide), which the even/odd row banking relies on.
                    WRITE_DATA_WIDTH_A => MFB_LENGTH,
                    BYTE_WRITE_WIDTH_A => 8,
                    ADDR_WIDTH_A       => BANK_ADDR_W,

                    READ_DATA_WIDTH_B  => MFB_LENGTH,
                    ADDR_WIDTH_B       => BANK_ADDR_W,
                    READ_RESET_VALUE_B => "0",
                    -- Fed from XPM_RD_LATENCY for consistency with the TDP array below; the
                    -- elaboration assert guarantees this is always 1 here (READ_LATENCY >= 2 +
                    -- MFB_REGIONS=1 is rejected), matching rd_data_vld_reg_p's fixed 1 cycle.
                    READ_LATENCY_B     => XPM_RD_LATENCY,
                    WRITE_MODE_B       => XPM_WRITE_MODE
                )
                port map (
                    SLEEP => '0',

                    -- Port A: write only
                    CLKA           => CLK,
                    ENA            => (or we(mem_arr_idx)(0)(bnk)),
                    WEA            => we(mem_arr_idx)(0)(bnk),
                    ADDRA          => wr_bank_addr_reg(BRAM_REG_NUM)(0)(bnk),
                    DINA           => wr_data_bram_shifter_reg(BRAM_REG_NUM)(0),
                    INJECTSBITERRA => '0',
                    INJECTDBITERRA => '0',

                    -- Port B: read only
                    CLKB           => CLK,
                    RSTB           => '0',
                    ENB            => rd_en_bram_demux(mem_arr_idx)(0),
                    REGCEB         => '1',
                    ADDRB          => rd_bank_addr(0)(bnk),
                    DOUTB          => rd_data_bram_bank(bnk)(mem_arr_idx)(0),
                    SBITERRB       => open,
                    DBITERRB       => open
                );
            end generate;
        end generate;
    end generate;

    -- =============================================================================================
    -- Memory array - Two regions (TDP, write priority stalls reads)
    -- =============================================================================================
    tdp_bram_g: if (MFB_REGIONS = 2) generate

        -- Cycle-1 (pre-extra-stage) rd_data_valid_arr; see rd_vld_p/rd_vld_lat1_g/rd_vld_lat2_g
        -- below for how READ_LATENCY selects between a plain wire and one extra register stage.
        signal rd_data_valid_arr_stg1 : std_logic_vector(MFB_REGIONS -1 downto 0);

    begin

        -- Region-r write stalls same-region reads (SDP ports are independent). Cross-region matters
        -- too: UG573 Table 3 NO_CHANGE leaves a port's read undefined when the OTHER port writes the
        -- same address. Compared PRE-mux, off addr_mux_g's critical path.
        rd_xrgn_collision_g : for ch in 0 to (MEM_ARRAYS -1) generate
            rd_xrgn_collision_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
                rd_xrgn_collision(ch)(rgn) <= '1' when (
                        ((or we(ch)(1 - rgn)(0)) = '1' and wr_bank_addr_reg(BRAM_REG_NUM)(1 - rgn)(0) = rd_bank_addr(rgn)(0)) or
                        ((or we(ch)(1 - rgn)(1)) = '1' and wr_bank_addr_reg(BRAM_REG_NUM)(1 - rgn)(1) = rd_bank_addr(rgn)(1))
                    ) else
 '0';
            end generate;
        end generate;

        rd_en_pch_g : for ch in 0 to (MEM_ARRAYS -1) generate
            rd_en_pch_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
                rd_en_pch(ch)(rgn) <= rd_en_bram_demux(ch)(rgn)
                                      and (not wr_active(ch)(rgn))
                                      and (not rd_xrgn_collision(ch)(rgn));
            end generate;
        end generate;

        -- A gated read never reaches rd_en_pch.
        rd_xrgn_gate_assert_g : for ch in 0 to (MEM_ARRAYS -1) generate
            rd_xrgn_gate_assert_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
            begin
                -- psl assert_xrgn_gate : assert never
                -- (rd_en_pch(ch)(rgn) = '1' and rd_xrgn_collision(ch)(rgn) = '1')
                -- report "cross-region read/write collision reached rd_en_pch ungated";
            end generate;
        end generate;

        -- Read/Write address mux (a single shared address bus per TDP port), one OR per
        -- array/region.
        addr_mux_g : for ch in 0 to (MEM_ARRAYS -1) generate
            addr_mux_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
                addr_mux_bank_g : for b in 0 to 1 generate
                    rw_addr_bram_by_mux(ch)(rgn)(b) <= wr_bank_addr_reg(BRAM_REG_NUM)(rgn)(b) when (wr_active(ch)(rgn) = '1') else rd_bank_addr(rgn)(b);
                end generate;
            end generate;
        end generate;

        tdp_ena_g : for ch in 0 to (MEM_ARRAYS -1) generate
            tdp_ena_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
                tdp_ena(ch)(rgn) <= wr_active(ch)(rgn) or rd_en_pch(ch)(rgn);
            end generate;
        end generate;

        brams_for_channels_g : for mem_arr_idx in 0 to (MEM_ARRAYS -1) generate
            banks_g : for bnk in 0 to 1 generate
                xpm_mem_i : component xpm_memory_tdpram
                generic map (
                    MEMORY_SIZE             => XPM_MEMORY_SIZE,
                    MEMORY_PRIMITIVE        => XPM_MEM_PRIMITIVE,
                    CLOCKING_MODE           => "common_clock",
                    MEMORY_INIT_FILE        => "none",
                    MEMORY_INIT_PARAM       => "0",
                    USE_MEM_INIT            => 0,
                    WAKEUP_TIME             => "disable_sleep",
                    MESSAGE_CONTROL         => 0,
                    ECC_MODE                => "no_ecc",
                    AUTO_SLEEP_TIME         => 0,
                    USE_EMBEDDED_CONSTRAINT => 0,
                    MEMORY_OPTIMIZATION     => "true",

                    -- Both ports genuinely read AND write here (one per MFB region, address-muxed
                    -- upstream), so XPM_WRITE_MODE's collision behaviour applies to both -- see the
                    -- XPM_WRITE_MODE declaration.
                    WRITE_DATA_WIDTH_A => MFB_LENGTH,
                    READ_DATA_WIDTH_A  => MFB_LENGTH,
                    BYTE_WRITE_WIDTH_A => 8,
                    ADDR_WIDTH_A       => BANK_ADDR_W,
                    READ_RESET_VALUE_A => "0",
                    -- 1 = no output register, 2 = XPM output register; rd_vld_p/rd_pipe_reg_p
                    -- below gain a matching extra pipeline stage from READ_LATENCY >= 2 (see
                    -- rd_vld_lat2_g/rd_pipe_lat2_g).
                    READ_LATENCY_A     => XPM_RD_LATENCY,
                    WRITE_MODE_A       => XPM_WRITE_MODE,

                    WRITE_DATA_WIDTH_B => MFB_LENGTH,
                    READ_DATA_WIDTH_B  => MFB_LENGTH,
                    BYTE_WRITE_WIDTH_B => 8,
                    ADDR_WIDTH_B       => BANK_ADDR_W,
                    READ_RESET_VALUE_B => "0",
                    READ_LATENCY_B     => XPM_RD_LATENCY,
                    WRITE_MODE_B       => XPM_WRITE_MODE
                )
                port map (
                    SLEEP => '0',

                    CLKA           => CLK,
                    RSTA           => '0',
                    ENA            => tdp_ena(mem_arr_idx)(0),
                    REGCEA         => '1',
                    WEA            => we(mem_arr_idx)(0)(bnk),
                    ADDRA          => rw_addr_bram_by_mux(mem_arr_idx)(0)(bnk),
                    DINA           => wr_data_bram_shifter_reg(BRAM_REG_NUM)(0),
                    INJECTSBITERRA => '0',
                    INJECTDBITERRA => '0',
                    DOUTA          => rd_data_bram_bank(bnk)(mem_arr_idx)(0),
                    SBITERRA       => open,
                    DBITERRA       => open,

                    CLKB           => CLK,
                    RSTB           => '0',
                    ENB            => tdp_ena(mem_arr_idx)(1),
                    REGCEB         => '1',
                    WEB            => we(mem_arr_idx)(1)(bnk),
                    ADDRB          => rw_addr_bram_by_mux(mem_arr_idx)(1)(bnk),
                    DINB           => wr_data_bram_shifter_reg(BRAM_REG_NUM)(1),
                    INJECTSBITERRB => '0',
                    INJECTDBITERRB => '0',
                    DOUTB          => rd_data_bram_bank(bnk)(mem_arr_idx)(1),
                    SBITERRB       => open,
                    DBITERRB       => open
                );
            end generate;
        end generate;

        -- DEBUG process for simulation
        debug_collision_g : for mem_arr_idx in 0 to (MEM_ARRAYS -1) generate
            -- dual concurrent write of both regions to the same row of the same bank
            debug_wr_collision_g : for bnk in 0 to 1 generate
                wr_addr_collision_detected(mem_arr_idx)(bnk) <= '1' when (
                        (or we(mem_arr_idx)(0)(bnk)) = '1' and (or we(mem_arr_idx)(1)(bnk)) = '1' and
                        rw_addr_bram_by_mux(mem_arr_idx)(0)(bnk) = rw_addr_bram_by_mux(mem_arr_idx)(1)(bnk)
                    ) else
 '0';
            end generate;

            -- concurrent read and write on the same region port
            rdwr_collision_detected(mem_arr_idx)(0) <= wr_active(mem_arr_idx)(0) and rd_en_bram_demux(mem_arr_idx)(0);
            rdwr_collision_detected(mem_arr_idx)(1) <= wr_active(mem_arr_idx)(1) and rd_en_bram_demux(mem_arr_idx)(1);
        end generate;

        rd_vld_p : process (CLK)
        begin
            if rising_edge(CLK) then

                rd_data_valid_arr_stg1   <= (others => '0');

                for ch in 0 to (MEM_ARRAYS -1) loop
                    for rgn in 0 to (MFB_REGIONS - 1) loop
                        if (rd_en_pch(ch)(rgn) = '1') then
                            rd_data_valid_arr_stg1(rgn) <= '1';
                        end if;
                    end loop;
                end loop;
            end if;
        end process;

        collision_reduce_p : process (all) is
            variable wr_addr_collision_v : std_logic;
            variable rdwr_collision_v    : std_logic;
        begin
            wr_addr_collision_v := '0';
            rdwr_collision_v    := '0';

            for mem_arr_idx in 0 to (MEM_ARRAYS -1) loop
                for bnk in 0 to 1 loop
                    if (rw_addr_bram_by_mux(mem_arr_idx)(0)(bnk) = rw_addr_bram_by_mux(mem_arr_idx)(1)(bnk)) then
                        wr_addr_collision_v := wr_addr_collision_v or (or (we(mem_arr_idx)(0)(bnk) and we(mem_arr_idx)(1)(bnk)));
                    end if;
                end loop;

                for rgn in 0 to (MFB_REGIONS -1) loop
                    rdwr_collision_v := rdwr_collision_v or (wr_active(mem_arr_idx)(rgn) and rd_en_pch(mem_arr_idx)(rgn));
                end loop;
            end loop;

            wr_addr_collision <= wr_addr_collision_v;
            rdwr_collision    <= rdwr_collision_v;
        end process;

        -- Both regions write one byte of one row in the same cycle, so one of the two values is lost.
        -- Disjoint bytes of one row are legal: the byte enables keep them apart.
        -- psl assert_wr_addr_collision :
        --      assert always (wr_addr_collision = '0') abort (RESET)
        --      report "TX_DMA_PCIE_TRANS_BUFFER: Two regions write to one address, data are lost!";

        -- A read and a write use one memory port in the same cycle. The write masks the read in
        -- rd_en_pch and the read is retried, so this only appears if that priority changes.
        -- psl assert_rdwr_collision :
        --      assert always (rdwr_collision = '0') abort (RESET)
        --      report "TX_DMA_PCIE_TRANS_BUFFER: A read and a write use one BRAM port at once!";
        -- READ_LATENCY => 1: rd_data_valid_arr IS the cycle-1 result above, a plain wire with no
        -- added register, so RD_DATA_VLD_* follows RD_EN_* by one cycle.
        rd_vld_lat1_g : if (READ_LATENCY = 1) generate
            rd_data_valid_arr <= rd_data_valid_arr_stg1;
        end generate;

        -- READ_LATENCY >= 2: one register re-aligns rd_data_valid_arr with the XPM output
        -- register's extra cycle. READ_LATENCY => 3's third cycle is on the request side, so it
        -- reaches this point already applied.
        rd_vld_lat2_g : if (READ_LATENCY >= 2) generate
            rd_vld_extra_reg_p : process (CLK)
            begin
                if rising_edge(CLK) then
                    rd_data_valid_arr <= rd_data_valid_arr_stg1;
                end if;
            end process;
        end generate;
    end generate;

    -- ==== Read request register (READ_LATENCY => 3 only) ====
    -- Everything from here to ENA/ADDRA is address decode (bank geometry, channel demux,
    -- write-collision compare); registering the REQUEST splits it from whatever built the address.
    rd_req_reg_g : if (RD_REQ_REG) generate
        rd_req_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                rd_addr_a_q <= RD_ADDR_A;
                rd_addr_b_q <= RD_ADDR_B;
                rd_chan_a_q <= RD_CHAN_A;
                rd_chan_b_q <= RD_CHAN_B;
                rd_en_a_q   <= RD_EN_A;
                rd_en_b_q   <= RD_EN_B;
                if (RESET = '1') then
                    rd_en_a_q <= '0';
                    rd_en_b_q <= '0';
                end if;
            end if;
        end process;

    -- Plain wires otherwise, so READ_LATENCY 1 and 2 keep the netlist they had before this stage
    -- existed.
    else generate
        rd_addr_a_q <= RD_ADDR_A;
        rd_addr_b_q <= RD_ADDR_B;
        rd_chan_a_q <= RD_CHAN_A;
        rd_chan_b_q <= RD_CHAN_B;
        rd_en_a_q   <= RD_EN_A;
        rd_en_b_q   <= RD_EN_B;
    end generate;

    -- ==== Read address / channel sources ====
    -- SPLIT_READ_PORTS maps P to a port; else broadcast from port A.
    rd_eff_split_g : if (SPLIT_READ_PORTS and MFB_REGIONS = 2) generate
        rd_addr_eff(0) <= rd_addr_a_q(POINTER_WIDTH -1 downto 0);
        rd_addr_eff(1) <= rd_addr_b_q(POINTER_WIDTH -1 downto 0);

        rd_chan_split_flat_g : if (FLAT) generate
            rd_chan_eff(0) <= rd_addr_a_q(POINTER_WIDTH + log2(CHANNELS) -1 downto POINTER_WIDTH);
            rd_chan_eff(1) <= rd_addr_b_q(POINTER_WIDTH + log2(CHANNELS) -1 downto POINTER_WIDTH);
        else generate
            rd_chan_eff(0) <= rd_chan_a_q;
            rd_chan_eff(1) <= rd_chan_b_q;
        end generate;
    else generate
        rd_addr_bcast_g : for p in 0 to (MFB_REGIONS -1) generate
            rd_addr_eff(p) <= rd_addr_a_q(POINTER_WIDTH -1 downto 0);
        end generate;

        rd_chan_bcast_flat_g : if (FLAT) generate
            rd_chan_bcast_flat_p_g : for p in 0 to (MFB_REGIONS -1) generate
                rd_chan_eff(p) <= rd_addr_a_q(POINTER_WIDTH + log2(CHANNELS) -1 downto POINTER_WIDTH);
            end generate;
        else generate
            rd_chan_bcast_part_p_g : for p in 0 to (MFB_REGIONS -1) generate
                rd_chan_eff(p) <= rd_chan_a_q;
            end generate;
        end generate;
    end generate;

    -- =============================================================================================
    -- Read bank addressing (cycle 0, combinational)
    -- =============================================================================================
    rd_bank_geom_g : for p in 0 to (MFB_REGIONS -1) generate
        constant SLOT_SHIFTER_EN : boolean := slot_shifter_en_f(p);
    begin

        -- Straddling path. A window at an arbitrary byte offset spans rows R and R+1, which live in
        -- opposite banks, so both must be fetched for assemble_bank_bytes/the barrel shifter to
        -- splice them. Costs a row+1 adder and a parity mux on BOTH bank addresses.
        rd_geom_shifted_g : if (SLOT_SHIFTER_EN) generate
            rd_bank_addr(p) <= bank_addr_f(rd_chan_eff(p)(log2(CHANS_PER_ARRAY) -1 downto 0),
                                           rd_addr_eff(p)(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES)));

        -- Aligned path: SLOT_SHIFTER_EN=FALSE returns the word-aligned row (no straddling,
        -- row R only); both banks share index R>>1, rd_row_lsb_reg (R's LSB) picks later. Drops the
        -- row+1 adder/parity mux from the critical path.
        else generate
            rd_bank_geom_aligned_p : process (all) is
                variable row_v  : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
                variable chan_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            begin
                row_v  := rd_addr_eff(p)(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES));
                chan_v := rd_chan_eff(p)(log2(CHANS_PER_ARRAY) -1 downto 0);

                rd_bank_addr(p)(0) <= chan_v & row_v(log2(BUFFER_DEPTH) -1 downto 1);
                rd_bank_addr(p)(1) <= chan_v & row_v(log2(BUFFER_DEPTH) -1 downto 1);
            end process;
        end generate;

    end generate;

    -- Cycle 1 registers: per-region-slot channel and intra-row offset/parity
    rd_pipe_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            for p in 0 to (MFB_REGIONS -1) loop
                rd_chan_p_reg_stg1(p)  <= rd_chan_eff(p);
                rd_off_reg_stg1(p)     <= rd_addr_eff(p)(log2(MFB_BYTES) -1 downto 0);
                rd_row_lsb_reg_stg1(p) <= rd_addr_eff(p)(log2(MFB_BYTES));
            end loop;
        end if;
    end process;

    -- READ_LATENCY => 1: rd_chan_p_reg/rd_off_reg/rd_row_lsb_reg ARE the cycle-1 results above,
    -- plain wires with no added register.
    rd_pipe_lat1_g : if (READ_LATENCY = 1) generate
        rd_chan_p_reg  <= rd_chan_p_reg_stg1;
        rd_off_reg     <= rd_off_reg_stg1;
        rd_row_lsb_reg <= rd_row_lsb_reg_stg1;
    end generate;

    -- READ_LATENCY >= 2: one extra register stage on each, re-aligning them with the XPM output
    -- register's additional cycle of BRAM latency (matching rd_vld_lat2_g above).
    rd_pipe_lat2_g : if (READ_LATENCY >= 2) generate
        rd_pipe_reg2_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                rd_chan_p_reg  <= rd_chan_p_reg_stg1;
                rd_off_reg     <= rd_off_reg_stg1;
                rd_row_lsb_reg <= rd_row_lsb_reg_stg1;
            end if;
        end process;
    end generate;

    -- ==== Cycle 1: select array by channel, assemble word from even/odd banks ====
    rd_arr_mux_g : for p in 0 to (MFB_REGIONS -1) generate
        rd_data_bank0_mux(p) <= rd_data_bram_bank(0)(to_integer(unsigned(rd_chan_p_reg(p)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(p);
        rd_data_bank1_mux(p) <= rd_data_bram_bank(1)(to_integer(unsigned(rd_chan_p_reg(p)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(p);
        rd_data_assembled(p) <= assemble_bank_bytes(rd_row_lsb_reg(p), rd_off_reg(p), rd_data_bank0_mux(p), rd_data_bank1_mux(p));
    end generate;

    -- ==== Demultiplexers / output stage ====
    -- Split ports need 2 regions (dual write ports); 1 region uses SDP.
    split_port_logic_g : if (SPLIT_READ_PORTS and MFB_REGIONS = 2) generate

        bram_demux_p : process (all) is
        begin
            rd_en_bram_demux                                                                                                                    <= (others => (others => '0'));
            rd_en_bram_demux(to_integer(unsigned(rd_chan_eff(0)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(0) <= rd_en_a_q;
            rd_en_bram_demux(to_integer(unsigned(rd_chan_eff(1)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(1) <= rd_en_b_q;
        end process;

        RD_DATA_VLD_A <= rd_data_valid_arr(0);
        RD_DATA_VLD_B <= rd_data_valid_arr(1);

        RD_DATA_B <= rd_data_out(1);

        rd_out_bank0     <= rd_data_bank0_mux;
        rd_out_bank1     <= rd_data_bank1_mux;
        rd_out_assembled <= rd_data_assembled;

    else generate
        bram_demux_p : process (all) is
        begin
            rd_en_bram_demux                                                                                                                 <= (others => (others => '0'));
            rd_en_bram_demux(to_integer(unsigned(rd_chan_eff(0)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY))))) <= (others => rd_en_a_q);
        end process;

        rd_data_sel_g : if (MFB_REGIONS = 1) generate
            -- Same-address read/write collision (mirrors the 2-region path): a read landing this
            -- cycle races a write to the same bank address, compared at ADDRA/ADDRB's own final
            -- registered stage -- exactly what the memory sees.
            signal rd_1rgn_collision : std_logic_vector(1 downto 0);
        begin
            rd_1rgn_collision_p : process (all) is
            begin
                rd_1rgn_collision <= (others => '0');
                for a in 0 to (MEM_ARRAYS -1) loop
                    for bnk in 0 to 1 loop
                        if (rd_en_bram_demux(a)(0) = '1' and (or we(a)(0)(bnk)) = '1'
                            and wr_bank_addr_reg(BRAM_REG_NUM)(0)(bnk) = rd_bank_addr(0)(bnk)) then
                            rd_1rgn_collision(bnk) <= '1';
                        end if;
                    end loop;
                end loop;
            end process;

            -- Read invalidated on a same-address write collision; the consumer must retry, just
            -- like the 2-region path above.
            rd_data_vld_reg_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    RD_DATA_VLD_A <= rd_en_a_q and (not (or rd_1rgn_collision));
                end if;
            end process;

            -- Verify the gating above holds: RD_DATA_VLD_A is registered one cycle behind
            -- rd_1rgn_collision, so a valid read must never trace back to a colliding sample.

            -- psl assert_1rgn_gate : assert always
            -- (RD_DATA_VLD_A = '1' -> (or prev(rd_1rgn_collision)) = '0')
            -- report "SDP-path (1-region) read validated despite a same-cycle write collision";

            rd_out_bank0(0) <= rd_data_bank0_mux(0);
            rd_out_bank1(0) <= rd_data_bank1_mux(0);
        else generate
            -- The read is attempted on both region-slots simultaneously (see rd_addr_bcast_g above);
            -- whichever one succeeds (was not stalled by a concurrent write) provides the data.
            rd_data_demux_p : process (all)
            begin
                RD_DATA_VLD_A     <= '0';
                rd_out_bank0(0)   <= rd_data_bank0_mux(0);
                rd_out_bank1(0)   <= rd_data_bank1_mux(0);

                for i in 0 to (MFB_REGIONS -1) loop
                    if (rd_data_valid_arr(i) = '1') then
                        RD_DATA_VLD_A     <= '1';
                        rd_out_bank0(0)   <= rd_data_bank0_mux(i);
                        rd_out_bank1(0)   <= rd_data_bank1_mux(i);
                    end if;
                end loop;
            end process;
        end generate;

        rd_out_assembled(0) <= assemble_bank_bytes(rd_row_lsb_reg(0), rd_off_reg(0), rd_out_bank0(0), rd_out_bank1(0));

    end generate;

    rd_out_g : for p in 0 to (RD_PORTS -1) generate
        rd_out_shifter_g : if (slot_shifter_en_f(p)) generate
            rd_data_barrel_shifter_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                BLOCKS     => MFB_BYTES,
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- writing side
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_out_assembled(p),
                DATA_OUT => rd_data_out(p),
                SEL      => rd_off_reg(p)
            );
        else generate
            rd_data_out(p) <= rd_out_bank1(p) when (rd_row_lsb_reg(p) = '1') else rd_out_bank0(p);
        end generate;
    end generate;

    RD_DATA_A <= rd_data_out(0);
end architecture;
