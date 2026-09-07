-- tx_dma_pcie_trans_buffer.vhd: this is a specially made component to buffer PCIe transactions
-- Copyright (C) 2023 CESNET z.s.p.o.
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--            David Benes      <xbenes52@vutbr.cz>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:
use work.math_pack.all;
use work.type_pack.all;

-- Each channel's buffer is an even/odd row-banked array: a barrel-rotated write only touches
-- two neighbouring rows, always in different banks, so one shared address plus per-byte
-- enables suffice. See RAM_TYPE.
entity TX_DMA_PCIE_TRANS_BUFFER is
    generic (
        DEVICE : string := "ULTRASCALE";

        -- Total number of DMA Channels within this DMA Endpoint
        CHANNELS : natural := 8;

        -- Input MFB interface
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;

        -- Determines the number of bytes that can be stored in the buffer.
        -- The amount of bytes equals 2\*\*POINTER_WIDTH
        POINTER_WIDTH          : natural := 16;
        -- If true, each port of the TDPs (used by the 2,1,8,32 MFB configuration) is controlled by
        -- separate interfaces
        SPLIT_READ_PORTS       : boolean := FALSE;
        -- If true, the read data are aligned according to the lower bits of the RD_ADDR input
        READ_BARREL_SHIFTER_EN : b_array_t(1 downto 0) := (TRUE, TRUE);

        -- Buffer array primitive: "AUTO" selects URAM on UltraScale+/Versal when the banked
        -- geometry fills URAMs reasonably, else BRAM. "BRAM"/"URAM" force the choice; RAM_TYPE=>
        -- "URAM" with an Intel DEVICE fails elaboration.
        RAM_TYPE : string := "AUTO";

        -- TRUE (default): partitioned per channel, each owning a 2**POINTER_WIDTH-byte
        -- region. FALSE: channel index ignored, whole array is one flat address space by
        -- the address field; RD_ADDR_* then widens by log2(CHANNELS) bits.
        MEM_PARTITIONING : boolean := TRUE
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- Input MFB bus (quasi BRAM writing interface)
        -- =========================================================================================
        PCIE_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_MFB_META    : in  slv_array_t(MFB_REGIONS -1 downto 0)(((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8+log2(CHANNELS)+62+1)-1 downto 0);
        PCIE_MFB_SOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_SRC_RDY : in  std_logic;

        -- Output reading interface for port A of the TDP or the single read port of the SDP
        RD_CHAN_A     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_A     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RD_ADDR_A     : in  std_logic_vector(POINTER_WIDTH + tsel(MEM_PARTITIONING, 0, log2(CHANNELS)) -1 downto 0);
        RD_EN_A       : in  std_logic;
        RD_DATA_VLD_A : out std_logic;

        -- Output reading interface for port B. Unused if SPLIT_READ_PORTS=FALSE or MFB configuration is (1,1,8,32).
        RD_CHAN_B     : in  std_logic_vector(log2(CHANNELS) -1 downto 0);
        RD_DATA_B     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0) := (others => '0');
        RD_ADDR_B     : in  std_logic_vector(POINTER_WIDTH + tsel(MEM_PARTITIONING, 0, log2(CHANNELS)) -1 downto 0);
        RD_EN_B       : in  std_logic;
        RD_DATA_VLD_B : out std_logic := '0'
    );
end entity;

architecture FULL of TX_DMA_PCIE_TRANS_BUFFER is

    constant MFB_LENGTH         : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    -- Number of Dwords in MFB word (equal as the nummber of items)
    constant MFB_DWORDS         : natural := MFB_LENGTH/MFB_ITEM_WIDTH;
    -- Number of bytes in MFB word
    constant MFB_BYTES          : natural := MFB_LENGTH/8;
    -- The Address is restricted by BAR_APERTURE (IP_core setting)
    constant BUFFER_DEPTH       : natural := (2**POINTER_WIDTH)/(MFB_LENGTH/8);
    -- Number of registers between BARREL_SHIFTERs and memory arrays
    constant BRAM_REG_NUM       : natural := 2;
    -- Number of input registers
    constant INP_REG_NUM        : natural := 1;
    constant IS_INTEL_DEV       : boolean := (DEVICE = "STRATIX10" or DEVICE = "AGILEX");
    constant IS_XILINX_URAM_DEV : boolean := (DEVICE = "ULTRASCALE" or DEVICE = "VERSAL");

    -- Candidate geometry assuming a URAM-sized array (used only to evaluate the AUTO->URAM guard
    -- below; this avoids a circular dependency between RES_RAM_TYPE and the real geometry).
    constant MAX_MEM_DEPTH_URAM_C   : natural := 16384;
    constant MAX_MEM_DEPTH_BRAM_C   : natural := tsel(IS_INTEL_DEV, 2048, 4096);
    constant CHANS_PER_ARRAY_URAM_C : natural := minimum(CHANNELS, MAX_MEM_DEPTH_URAM_C/BUFFER_DEPTH);
    constant BANK_ITEMS_URAM_C      : natural := (CHANS_PER_ARRAY_URAM_C * BUFFER_DEPTH) / 2;

    -- Resolved memory primitive: URAM is only picked for RAM_TYPE=>AUTO on an AMD UltraScale+/Versal
    -- device, a 2-region geometry and a reasonably filled bank (>= 2048 rows); BRAM otherwise.
    constant RES_RAM_TYPE : string := tsel(
                                           (RAM_TYPE = "URAM") or
                                           (RAM_TYPE = "AUTO" and IS_XILINX_URAM_DEV and MFB_REGIONS = 2 and BANK_ITEMS_URAM_C >= 2048),
                                           "URAM", "BRAM");

    -- a maximum depth of a memory block (in 1B items) depends on the resolved memory primitive
    constant MAX_MEM_DEPTH   : natural := tsel(RES_RAM_TYPE = "URAM", MAX_MEM_DEPTH_URAM_C, MAX_MEM_DEPTH_BRAM_C);
    -- The amount of channels that fits into one array
    constant CHANS_PER_ARRAY : natural := minimum(CHANNELS, MAX_MEM_DEPTH/BUFFER_DEPTH);
    -- Number of memory arrays since one array can contain multiple channels
    constant MEM_ARRAYS      : natural := CHANNELS/CHANS_PER_ARRAY;
    -- Total rows (of one whole MFB word) per array
    constant ARRAY_ROWS      : natural := CHANS_PER_ARRAY * BUFFER_DEPTH;
    -- Depth of each of the two even/odd row banks
    constant BANK_ITEMS      : natural := ARRAY_ROWS / 2;
    constant BANK_ADDR_W     : natural := log2(BANK_ITEMS);
    -- Width of the (registered) target-array index; at least 1 bit even when MEM_ARRAYS = 1
    constant ARR_IDX_W       : natural := max(1, log2(MEM_ARRAYS));

    -- Flat addressing (MEM_PARTITIONING=FALSE): channel index ignored, array addressed by the
    -- address field alone, taking channel-select bits from above the intra-channel row address.
    -- Only meaningful for CHANNELS > 1.
    constant FLAT             : boolean := (not MEM_PARTITIONING) and (CHANNELS > 1);
    -- LSB, within the write META DWord-address, of the flat channel-select field (the read byte
    -- address carries it starting at bit POINTER_WIDTH). It sits directly above the intra-channel row.
    constant FLAT_CHAN_LSB_DW : natural := log2(BUFFER_DEPTH) + log2(MFB_DWORDS);
    -- LSB of the memory-array-select sub-field within the flat channel-select field
    constant FLAT_ARR_LSB_DW  : natural := FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY);

    -- =============================================================================================
    -- Defining ranges for meta signal
    -- =============================================================================================
    constant META_IS_DMA_HDR_W : natural := 1;
    constant META_PCIE_ADDR_W  : natural := 62;
    constant META_CHAN_NUM_W   : natural := log2(CHANNELS);
    constant META_BE_W         : natural := (MFB_LENGTH/MFB_REGIONS)/8;

    constant META_IS_DMA_HDR_O : natural := 0;
    constant META_PCIE_ADDR_O  : natural := META_IS_DMA_HDR_O + META_IS_DMA_HDR_W;
    constant META_CHAN_NUM_O   : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    constant META_BE_O         : natural := META_CHAN_NUM_O + META_CHAN_NUM_W;

    subtype META_IS_DMA_HDR is natural range META_IS_DMA_HDR_O + META_IS_DMA_HDR_W -1 downto META_IS_DMA_HDR_O;
    subtype META_PCIE_ADDR  is natural range   META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O;
    subtype META_CHAN_NUM   is natural range     META_CHAN_NUM_O + META_CHAN_NUM_W -1 downto META_CHAN_NUM_O;
    subtype META_BE         is natural range                 META_BE_O + META_BE_W -1 downto META_BE_O;

    -- Input register
    signal pcie_mfb_data_inp_reg    : slv_array_t(INP_REG_NUM downto 0)(PCIE_MFB_DATA'range);
    signal pcie_mfb_meta_inp_reg    : slv_array_2d_t(INP_REG_NUM downto 0)(MFB_REGIONS -1 downto 0)(((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8+log2(CHANNELS)+62+1)-1 downto 0);
    signal pcie_mfb_sof_inp_reg     : slv_array_t(INP_REG_NUM downto 0)(PCIE_MFB_SOF'range);
    signal pcie_mfb_src_rdy_inp_reg : std_logic_vector(INP_REG_NUM downto 0);

    -- counter of the address for each valid word following the beginning of the transaction
    signal addr_cntr_pst            : unsigned(META_PCIE_ADDR_W -1 downto 0);
    signal addr_cntr_nst            : unsigned(META_PCIE_ADDR_W -1 downto 0);

    -- Stores the index of the packet that get currently stored
    signal chan_num_reg             : std_logic_vector(META_CHAN_NUM_W -1 downto 0);
    signal chan_num_next            : std_logic_vector(META_CHAN_NUM_W -1 downto 0);

    -- control of the amount of shift on the writing barrel shifters
    signal wr_shift_sel             : slv_array_t(MFB_REGIONS - 1 downto 0)(log2(MFB_LENGTH/32) -1 downto 0);

    signal wr_be_bram_bshifter      : slv_array_t(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0);
    signal wr_data_bram_bshifter    : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_LENGTH -1 downto 0);

    signal mem_arr_idx_reg          : std_logic_vector(ARR_IDX_W -1 downto 0);
    signal mem_arr_idx_next         : std_logic_vector(ARR_IDX_W -1 downto 0);

    -- Meta array
    signal pcie_mfb_meta_arr        : slv_array_t(MFB_REGIONS - 1 downto 0)((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8+log2(CHANNELS)+62+1-1 downto 0);

    -- Meta signal for whole MFB word
    signal pcie_meta_be_per_port    : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_LENGTH/8 - 1 downto 0);

    -- Write path: per-region even/odd bank write-enable and bank address (combinational)
    signal wr_bank_be   : slv_array_2d_t(MFB_REGIONS -1 downto 0)(1 downto 0)(MFB_BYTES -1 downto 0);
    signal wr_bank_addr : slv_array_2d_t(MFB_REGIONS -1 downto 0)(1 downto 0)(BANK_ADDR_W -1 downto 0);

    -- The registered per-region target memory-array index (only meaningful when MEM_ARRAYS > 1); see
    -- the NVC_ARRAY_DEMUX_ARTIFACT note in cocotb/cocotb_test.py for why this is registered and
    -- resolved with a plain equality compare instead of an array index.
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
    signal rd_en_bram_demux    : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_data_valid_arr   : std_logic_vector(MFB_REGIONS -1 downto 0);

    -- Memory array read data, indexed [bank][array][region]
    signal rd_data_bram_bank   : slv_array_3d_t(1 downto 0)(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);

    -- Read path: effective RD_ADDR/RD_CHAN source per region-slot. With SPLIT_READ_PORTS,
    -- slot P maps 1:1 to port A/B; without it, both slots broadcast from port A (whichever
    -- isn't stalled by a concurrent write succeeds).
    signal rd_addr_eff : slv_array_t(MFB_REGIONS -1 downto 0)(POINTER_WIDTH -1 downto 0);
    signal rd_chan_eff : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);

    signal rd_bank_addr : slv_array_2d_t(MFB_REGIONS -1 downto 0)(1 downto 0)(BANK_ADDR_W -1 downto 0);

    signal rd_chan_p_reg  : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);
    signal rd_off_reg     : slv_array_t(MFB_REGIONS -1 downto 0)(log2(MFB_BYTES) -1 downto 0);
    signal rd_row_lsb_reg : std_logic_vector(MFB_REGIONS -1 downto 0);

    signal rd_data_bank0_mux : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_data_bank1_mux : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_data_assembled : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);

    -- =============================================================================================
    -- DEBUG signals (verification or ILA)
    -- =============================================================================================
    signal wr_addr_collision_detected : slv_array_t(MEM_ARRAYS -1 downto 0)(1 downto 0);
    signal rdwr_collision_detected    : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);

    -- Byte-wise even/odd bank assembly: byte i comes from bank 0 unless its row wrapped from the
    -- intra-word rotation/shift (i.e. sits before the write/read rotation point) -- see readme.rst.
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

    assert (not (RAM_TYPE = "URAM" and IS_INTEL_DEV))
        report "TX_DMA_PCIE_TRANS_BUFFER: RAM_TYPE => URAM is only supported on AMD devices!"
        severity FAILURE;

    -- =============================================================================================
    -- Input shift registers
    -- =============================================================================================
    pcie_mfb_data_inp_reg   (0) <= PCIE_MFB_DATA;
    pcie_mfb_meta_inp_reg   (0) <= PCIE_MFB_META;
    pcie_mfb_sof_inp_reg    (0) <= PCIE_MFB_SOF;
    pcie_mfb_src_rdy_inp_reg(0) <= PCIE_MFB_SRC_RDY;

    inp_shift_reg_mult_g: if (INP_REG_NUM > 0) generate
        input_shift_reg_g: for i in 0 to (INP_REG_NUM - 1) generate
            input_shift_reg_p : process (CLK) is
            begin
                if rising_edge(CLK) then
                    if (RESET = '1') then
                        pcie_mfb_src_rdy_inp_reg(i + 1) <= '0';
                    else
                        pcie_mfb_data_inp_reg   (i + 1) <= pcie_mfb_data_inp_reg   (i);
                        pcie_mfb_meta_inp_reg   (i + 1) <= pcie_mfb_meta_inp_reg   (i);
                        pcie_mfb_sof_inp_reg    (i + 1) <= pcie_mfb_sof_inp_reg    (i);
                        pcie_mfb_src_rdy_inp_reg(i + 1) <= pcie_mfb_src_rdy_inp_reg(i);
                    end if;
                end if;
            end process;
        end generate;
    end generate;

    -- Meta array
    pcie_mfb_meta_arr   <= pcie_mfb_meta_inp_reg(INP_REG_NUM);

    -- =============================================================================================
    -- Assertions for verification
    -- =============================================================================================

    -- psl assert_captured_dma_header :
    --      assert forall it in {0 to (MFB_REGIONS -1)} :
    --      always ((not (PCIE_MFB_SRC_RDY = '1' or PCIE_MFB_META(it)(META_BE) /= (META_BE_W -1 downto 0 => '0'))) or
    --              (PCIE_MFB_META(it)(META_IS_DMA_HDR) = "0")) abort(RESET) @rising_edge(CLK)
    --      report "TX_DMA_PCIE_TRANS_BUFFER: captured DMA header on region  to_string(it) Danger of data overwrite!";

    -- =============================================================================================
    -- Address storage
    -- =============================================================================================
    addr_cntr_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                addr_cntr_pst <= (others => '0');
                chan_num_reg  <= (others => '0');
            else
                addr_cntr_pst <= addr_cntr_nst;
                chan_num_reg  <= chan_num_next;
            end if;
        end if;
    end process;

    addr_cntr_nst_logic_p : process (all) is
    begin
        addr_cntr_nst <= addr_cntr_pst;
        chan_num_next <= chan_num_reg;

        -- Increment the address for a next word by 8 (the number of DWs in the
        -- word) to be written to the BRAMs.  When the new packet arrives, its
        -- address is stored and incremented by one region size

        -- Be careful! The number '8' is only correct for one region
        if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
            -- Address Increment
            -- +16 (amount of DWs for two regions)
            addr_cntr_nst <= addr_cntr_pst + MFB_REGIONS*MFB_BLOCK_SIZE;

            -- Last SOF - Higher takes
            for i in 0 to (MFB_REGIONS - 1) loop
                if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(i) = '1') then
                    -- First SOF adds 16 to the address; a second SOF instead takes the address
                    -- from the second region and adds 8, since with only one SOF (in the first
                    -- region) the frame continues into the next word.
                    addr_cntr_nst   <= unsigned(pcie_mfb_meta_arr(i)(META_PCIE_ADDR)) + (MFB_REGIONS - i)*MFB_BLOCK_SIZE;
                    chan_num_next   <= pcie_mfb_meta_arr(i)(META_CHAN_NUM);
                end if;
            end loop;
        end if;
    end process;

    -- META(BE) select: chooses which bytes are enabled in which BS, based on the SOF status in
    -- the second region.
    meta_be_g: if (MFB_REGIONS = 1) generate
        pcie_meta_be_per_port(0) <= pcie_mfb_meta_arr(0)(META_BE);
    else generate
        meta_sel_p : process (all)
        begin
            if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(1) = '1') then
                pcie_meta_be_per_port(0) <= (META_BE_W -1 downto 0 => '0') & pcie_mfb_meta_arr(0)(META_BE);
                pcie_meta_be_per_port(1) <= pcie_mfb_meta_arr(1)(META_BE) & (META_BE_W -1 downto 0 => '0');
            else
                -- The problem is that we only get half the information in metadata for each region
                pcie_meta_be_per_port(0) <= pcie_mfb_meta_arr(1)(META_BE) & pcie_mfb_meta_arr(0)(META_BE);
                pcie_meta_be_per_port(1) <= (others => '0');
            end if;
        end process;
    end generate;

    -- Data shift - Port A: controls the input word's shift/byte-enable. At a transaction's
    -- start the shift comes from the current address; once it continues, from the address
    -- counter. Address is split in two (dual-port BRAM).
    wr_bshifter_0_ctrl_p : process (all) is
        variable pcie_mfb_meta_addr_v : std_logic_vector(META_PCIE_ADDR_W -1 downto 0);
    begin
        wr_shift_sel(0) <= (others => '0');

        if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
            if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(0) = '1') then
                pcie_mfb_meta_addr_v    := pcie_mfb_meta_arr(0)(META_PCIE_ADDR);
                wr_shift_sel(0)         <= pcie_mfb_meta_addr_v(log2(MFB_DWORDS) - 1  downto 0);
            else
                -- Shared address when the processing is in the middle of a frame - last saved address
                wr_shift_sel(0)         <= std_logic_vector(addr_cntr_pst(log2(MFB_DWORDS) - 1 downto 0));
            end if;
        end if;
    end process;

    -- Data - Port A
    wr_data_barrel_shifter_0_i: entity work.BARREL_SHIFTER_GEN
    generic map (
        BLOCKS     => MFB_REGIONS*MFB_BLOCK_SIZE,
        BLOCK_SIZE => MFB_ITEM_WIDTH,
        SHIFT_LEFT => TRUE
    )
    port map (
        DATA_IN  => pcie_mfb_data_inp_reg(INP_REG_NUM),
        DATA_OUT => wr_data_bram_bshifter(0),
        SEL      => wr_shift_sel(0)
    );

    -- Byte enable - port A
    wr_be_barrel_shifter_0_i: entity work.BARREL_SHIFTER_GEN
    generic map (
        BLOCKS     => MFB_REGIONS*MFB_BLOCK_SIZE,
        BLOCK_SIZE => 4,
        SHIFT_LEFT => TRUE
    )
    port map (
        DATA_IN  => pcie_meta_be_per_port(0),
        DATA_OUT => wr_be_bram_bshifter(0),
        SEL      => wr_shift_sel(0)
    );

    -- Data shift - Port B: this packet starts at the second region's beginning, so correct the
    -- address by the number of DWords in the region.
    tworeg_bs_g: if (MFB_REGIONS = 2) generate
        wr_bshifter_1_ctrl_p : process (all) is
            variable pcie_mfb_meta_addr_v : std_logic_vector(META_PCIE_ADDR_W -1 downto 0);
        begin
            wr_shift_sel(1) <= (others => '0');

            if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
                if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(1) = '1') then
                    -- The '+8' is MFB_BLOCK_SIZE (same as length of a REGION in Dwords) and is
                    -- only used when the SOF is in the second region
                    -- NOTE: that -8 can be a source of error. Was +8 previously.
                    pcie_mfb_meta_addr_v    := std_logic_vector(unsigned(pcie_mfb_meta_arr(1)(META_PCIE_ADDR)) - 8);
                    wr_shift_sel(1)         <= pcie_mfb_meta_addr_v(log2(MFB_DWORDS) - 1  downto 0);
                end if;
            end if;
        end process;

        -- Data - Port B
        wr_data_barrel_shifter_1_i: entity work.BARREL_SHIFTER_GEN
        generic map (
            BLOCKS     => MFB_REGIONS*MFB_BLOCK_SIZE,
            BLOCK_SIZE => MFB_ITEM_WIDTH,
            SHIFT_LEFT => TRUE
        )
        port map (
            DATA_IN  => pcie_mfb_data_inp_reg(INP_REG_NUM),
            DATA_OUT => wr_data_bram_bshifter(1),
            SEL      => wr_shift_sel(1)
        );

        -- Byte enable - port B
        wr_be_barrel_shifter_1_i: entity work.BARREL_SHIFTER_GEN
        generic map (
            BLOCKS     => MFB_REGIONS*MFB_BLOCK_SIZE,
            BLOCK_SIZE => 4,
            SHIFT_LEFT => TRUE
        )
        port map (
            DATA_IN  => pcie_meta_be_per_port(1),
            DATA_OUT => wr_be_bram_bshifter(1),
            SEL      => wr_shift_sel(1)
        );
    end generate;

    -- Write bank geometry - Port A: which even/odd bank each byte lands in (it carries into
    -- the next row/opposite bank when its DWord index is below the rotation amount) and the
    -- banks' shared row addresses.
    wr_bank_geom_a_p : process (all) is
        variable pcie_mfb_meta_addr_v : std_logic_vector(META_PCIE_ADDR_W -1 downto 0);
        variable buff_addr_v          : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
        variable buff_addr_p1_v       : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
        variable chan_addr_v          : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
        variable carry_v              : std_logic;
    begin
        wr_bank_be(0)   <= (others => (others => '0'));
        wr_bank_addr(0) <= (others => (others => '0'));

        if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
            if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(0) = '1') then
                pcie_mfb_meta_addr_v := pcie_mfb_meta_arr(0)(META_PCIE_ADDR);
                buff_addr_v          := pcie_mfb_meta_addr_v(log2(BUFFER_DEPTH)+log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS));
                -- FLAT: the intra-array channel slot comes from the address just above the row; else
                -- from the channel field. buff_addr_v (the intra-channel row) is unchanged either way.
                if (FLAT) then
                    chan_addr_v := pcie_mfb_meta_addr_v(FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY) -1 downto FLAT_CHAN_LSB_DW);
                else
                    chan_addr_v := pcie_mfb_meta_arr(0)(log2(CHANS_PER_ARRAY) + META_CHAN_NUM_O -1 downto META_CHAN_NUM_O);
                end if;
            else
                buff_addr_v := std_logic_vector(addr_cntr_pst(log2(BUFFER_DEPTH) + log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS)));
                -- FLAT: track the running address' channel-slot bits so a frame that crosses a
                -- channel boundary keeps addressing correctly; else hold the frame's channel.
                if (FLAT) then
                    chan_addr_v := std_logic_vector(addr_cntr_pst(FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY) -1 downto FLAT_CHAN_LSB_DW));
                else
                    chan_addr_v := chan_num_reg(log2(CHANS_PER_ARRAY) -1 downto 0);
                end if;
            end if;

            buff_addr_p1_v := std_logic_vector(unsigned(buff_addr_v) + 1);

            -- The bank whose index equals the row's parity gets the "row" address, the other bank
            -- gets the "row + 1" address (the two are always in different banks, see readme.rst)
            if (buff_addr_v(0) = '0') then
                wr_bank_addr(0)(0) <= chan_addr_v & buff_addr_v   (log2(BUFFER_DEPTH) -1 downto 1);
                wr_bank_addr(0)(1) <= chan_addr_v & buff_addr_p1_v(log2(BUFFER_DEPTH) -1 downto 1);
            else
                wr_bank_addr(0)(0) <= chan_addr_v & buff_addr_p1_v(log2(BUFFER_DEPTH) -1 downto 1);
                wr_bank_addr(0)(1) <= chan_addr_v & buff_addr_v   (log2(BUFFER_DEPTH) -1 downto 1);
            end if;

            -- Distribute the (already rotated) byte-enable bits to the bank each byte's row lives in
            for i in 0 to (MFB_BYTES -1) loop
                if ((i/4) < unsigned(wr_shift_sel(0))) then
                    carry_v := '1';
                else
                    carry_v := '0';
                end if;

                if ((buff_addr_v(0) xor carry_v) = '0') then
                    wr_bank_be(0)(0)(i) <= wr_be_bram_bshifter(0)(i);
                else
                    wr_bank_be(0)(1)(i) <= wr_be_bram_bshifter(0)(i);
                end if;
            end loop;
        end if;
    end process;

    -- =============================================================================================
    -- Write bank geometry - Port B (region 1)
    -- =============================================================================================
    wr_bank_geom_b_g: if (MFB_REGIONS = 2) generate
        wr_bank_geom_b_p : process (all) is
            variable pcie_mfb_meta_addr_v : std_logic_vector(META_PCIE_ADDR_W -1 downto 0);
            variable buff_addr_v          : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
            variable buff_addr_p1_v       : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
            variable chan_addr_v          : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            variable carry_v              : std_logic;
        begin
            wr_bank_be(1)   <= (others => (others => '0'));
            wr_bank_addr(1) <= (others => (others => '0'));

            if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
                if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(1) = '1') then
                    -- Pass address to variable
                    pcie_mfb_meta_addr_v := pcie_mfb_meta_arr(1)(META_PCIE_ADDR);
                    buff_addr_v          := pcie_mfb_meta_addr_v(log2(BUFFER_DEPTH)+log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS));
                    -- FLAT: intra-array channel slot from the address; else from the channel field
                    if (FLAT) then
                        chan_addr_v := pcie_mfb_meta_addr_v(FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY) -1 downto FLAT_CHAN_LSB_DW);
                    else
                        chan_addr_v := pcie_mfb_meta_arr(1)(log2(CHANS_PER_ARRAY) + META_CHAN_NUM_O -1 downto META_CHAN_NUM_O);
                    end if;

                    buff_addr_p1_v := std_logic_vector(unsigned(buff_addr_v) + 1);

                    if (buff_addr_v(0) = '0') then
                        wr_bank_addr(1)(0) <= chan_addr_v & buff_addr_v   (log2(BUFFER_DEPTH) -1 downto 1);
                        wr_bank_addr(1)(1) <= chan_addr_v & buff_addr_p1_v(log2(BUFFER_DEPTH) -1 downto 1);
                    else
                        wr_bank_addr(1)(0) <= chan_addr_v & buff_addr_p1_v(log2(BUFFER_DEPTH) -1 downto 1);
                        wr_bank_addr(1)(1) <= chan_addr_v & buff_addr_v   (log2(BUFFER_DEPTH) -1 downto 1);
                    end if;

                    -- The carry/wrap threshold uses the raw (uncorrected) META(1).PCIE_ADDR low bits: the "-8"
                    -- correction in wr_bshifter_1_ctrl_p only affects the barrel-shifter rotation (wr_shift_sel(1)),
                    -- not which row a byte's DWord belongs to.
                    for i in 0 to (MFB_BYTES -1) loop
                        if ((i/4) < unsigned(pcie_mfb_meta_addr_v(log2(MFB_DWORDS) -1 downto 0))) then
                            carry_v := '1';
                        else
                            carry_v := '0';
                        end if;

                        if ((buff_addr_v(0) xor carry_v) = '0') then
                            wr_bank_be(1)(0)(i) <= wr_be_bram_bshifter(1)(i);
                        else
                            wr_bank_be(1)(1)(i) <= wr_be_bram_bshifter(1)(i);
                        end if;
                    end loop;
                    -- else is not the case - the first port will handle it
                end if;
            end if;
        end process;
    end generate;

    -- Channel index store: demux is based on META(Channel), last value stored. TODO: may be
    -- removable, since METADATA_EXTRACTOR already holds the channel for the packet's duration.
    mem_arr_indx_hold_g: if (MEM_ARRAYS > 1) generate
        mem_arr_idx_hold_reg_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (RESET = '1') then
                    mem_arr_idx_reg <= (others => '0');
                else
                    mem_arr_idx_reg <= mem_arr_idx_next;
                end if;
            end if;
        end process;

        -- This FSM stores a part of a channel number to determine the memory array
        -- to which the data ought to be send. It stores channel number for the last
        -- valid SOF in the word.
        mem_arr_idx_hold_nst_logic_p : process (all) is
            variable mem_arr_idx_v : std_logic_vector(log2(CHANNELS) -1 downto 0);
        begin
            mem_arr_idx_next <= mem_arr_idx_reg;

            -- Higher takes
            if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
                for i in 0 to (MFB_REGIONS - 1) loop
                    if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(i) = '1') then

                        mem_arr_idx_v    := pcie_mfb_meta_arr(i)(META_CHAN_NUM);
                        mem_arr_idx_next <= mem_arr_idx_v(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY));

                    end if;
                end loop;
            end if;
        end process;

        -- Per-region target-array index: compared only for equality (never indexed) after being
        -- registered, to avoid a documented nvc 1.21.0 array-indexing artifact -- see
        -- NVC_ARRAY_DEMUX_ARTIFACT.
        arr_idx_rgn_logic_p : process (all) is
            variable chan_v      : std_logic_vector(META_CHAN_NUM_W -1 downto 0);
            variable pcie_addr_v : std_logic_vector(META_PCIE_ADDR_W -1 downto 0);
        begin
            arr_idx_rgn <= (others => (others => '0'));

            for i in 0 to (MFB_REGIONS - 1) loop
                if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
                    if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(i) = '1') then
                        -- FLAT: memory-array select from the address; else from the channel field
                        if (FLAT) then
                            pcie_addr_v    := pcie_mfb_meta_arr(i)(META_PCIE_ADDR);
                            arr_idx_rgn(i) <= pcie_addr_v(FLAT_ARR_LSB_DW + log2(MEM_ARRAYS) -1 downto FLAT_ARR_LSB_DW);
                        else
                            chan_v         := pcie_mfb_meta_arr(i)(META_CHAN_NUM);
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

    -- =============================================================================================
    -- Memory array - One region (SDP, reads never stall)
    -- =============================================================================================
    sdp_bram_g: if (MFB_REGIONS = 1) generate
        brams_for_channels_g : for mem_arr_idx in 0 to (MEM_ARRAYS -1) generate
            banks_g : for bnk in 0 to 1 generate
                sdp_bram_be_i : entity work.SDP_BRAM_BE
                generic map (
                    BLOCK_ENABLE   => TRUE,
                    BLOCK_WIDTH    => 8,
                    DATA_WIDTH     => MFB_LENGTH,
                    ITEMS          => BANK_ITEMS,
                    COMMON_CLOCK   => TRUE,
                    OUTPUT_REG     => FALSE,
                    METADATA_WIDTH => 0,
                    DEVICE         => DEVICE
                )
                port map (
                    WR_CLK      => CLK,
                    WR_RST      => RESET,
                    WR_EN       => (or we(mem_arr_idx)(0)(bnk)),
                    WR_BE       => we(mem_arr_idx)(0)(bnk),
                    WR_ADDR     => wr_bank_addr_reg(BRAM_REG_NUM)(0)(bnk),
                    WR_DATA     => wr_data_bram_shifter_reg(BRAM_REG_NUM)(0),

                    RD_CLK      => CLK,
                    RD_RST      => RESET,
                    RD_EN       => '1',
                    RD_PIPE_EN  => rd_en_bram_demux(mem_arr_idx)(0),
                    RD_META_IN  => (others => '0'),
                    RD_ADDR     => rd_bank_addr(0)(bnk),
                    RD_DATA     => rd_data_bram_bank(bnk)(mem_arr_idx)(0),
                    RD_META_OUT => open,
                    RD_DATA_VLD => open
                );
            end generate;
        end generate;
    end generate;

    -- =============================================================================================
    -- Memory array - Two regions (TDP, write priority stalls reads)
    -- =============================================================================================
    tdp_bram_g: if (MFB_REGIONS = 2) generate

        -- Write-priority read gating: a region-r write in array a stalls reads on port r of that
        -- array (SDP above has no such stall, its read/write ports are independent).
        rd_en_pch_g : for ch in 0 to (MEM_ARRAYS -1) generate
            rd_en_pch_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
                rd_en_pch(ch)(rgn) <= rd_en_bram_demux(ch)(rgn) and (not wr_active(ch)(rgn));
            end generate;
        end generate;

        -- Read/Write address mux (a single shared address bus per TDP port), one OR per
        -- array/region instead of the former per-byte OR.
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
                tdp_bram_be_i : entity work.TDP_BRAM_BE
                generic map (
                    DATA_WIDTH => MFB_LENGTH,
                    ITEMS      => BANK_ITEMS,
                    RAM_TYPE   => RES_RAM_TYPE,
                    DEVICE     => DEVICE
                )
                port map (
                    CLK => CLK,

                    ENA   => tdp_ena(mem_arr_idx)(0),
                    WEA   => we(mem_arr_idx)(0)(bnk),
                    ADDRA => rw_addr_bram_by_mux(mem_arr_idx)(0)(bnk),
                    DIA   => wr_data_bram_shifter_reg(BRAM_REG_NUM)(0),
                    DOA   => rd_data_bram_bank(bnk)(mem_arr_idx)(0),

                    ENB   => tdp_ena(mem_arr_idx)(1),
                    WEB   => we(mem_arr_idx)(1)(bnk),
                    ADDRB => rw_addr_bram_by_mux(mem_arr_idx)(1)(bnk),
                    DIB   => wr_data_bram_shifter_reg(BRAM_REG_NUM)(1),
                    DOB   => rd_data_bram_bank(bnk)(mem_arr_idx)(1)
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

                rd_data_valid_arr   <= (others => '0');

                for ch in 0 to (MEM_ARRAYS -1) loop
                    for rgn in 0 to (MFB_REGIONS - 1) loop
                        if (rd_en_pch(ch)(rgn) = '1') then
                            rd_data_valid_arr(rgn) <= '1';
                        end if;
                    end loop;
                end loop;
            end if;
        end process;
    end generate;

    -- Read address/channel sources: SPLIT_READ_PORTS maps slot P to port A/B; else both
    -- broadcast from port A. FLAT: RD_ADDR_*'s top bits select the channel, RD_CHAN_* ignored.
    -- Partitioned: RD_ADDR_* is the intra-channel address.
    rd_eff_split_g : if (SPLIT_READ_PORTS and MFB_REGIONS = 2) generate
        rd_addr_eff(0) <= RD_ADDR_A(POINTER_WIDTH -1 downto 0);
        rd_addr_eff(1) <= RD_ADDR_B(POINTER_WIDTH -1 downto 0);

        rd_chan_split_flat_g : if (FLAT) generate
            rd_chan_eff(0) <= RD_ADDR_A(POINTER_WIDTH + log2(CHANNELS) -1 downto POINTER_WIDTH);
            rd_chan_eff(1) <= RD_ADDR_B(POINTER_WIDTH + log2(CHANNELS) -1 downto POINTER_WIDTH);
        else generate
            rd_chan_eff(0) <= RD_CHAN_A;
            rd_chan_eff(1) <= RD_CHAN_B;
        end generate;
    else generate
        rd_addr_bcast_g : for p in 0 to (MFB_REGIONS -1) generate
            rd_addr_eff(p) <= RD_ADDR_A(POINTER_WIDTH -1 downto 0);
        end generate;

        rd_chan_bcast_flat_g : if (FLAT) generate
            rd_chan_bcast_flat_p_g : for p in 0 to (MFB_REGIONS -1) generate
                rd_chan_eff(p) <= RD_ADDR_A(POINTER_WIDTH + log2(CHANNELS) -1 downto POINTER_WIDTH);
            end generate;
        else generate
            rd_chan_bcast_part_p_g : for p in 0 to (MFB_REGIONS -1) generate
                rd_chan_eff(p) <= RD_CHAN_A;
            end generate;
        end generate;
    end generate;

    -- =============================================================================================
    -- Read bank addressing (cycle 0, combinational)
    -- =============================================================================================
    rd_bank_geom_g : for p in 0 to (MFB_REGIONS -1) generate
        rd_bank_geom_p : process (all) is
            variable row_v    : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
            variable row_p1_v : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
            variable chan_v   : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
        begin
            row_v    := rd_addr_eff(p)(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES));
            row_p1_v := std_logic_vector(unsigned(row_v) + 1);
            chan_v   := rd_chan_eff(p)(log2(CHANS_PER_ARRAY) -1 downto 0);

            if (row_v(0) = '0') then
                rd_bank_addr(p)(0) <= chan_v & row_v   (log2(BUFFER_DEPTH) -1 downto 1);
                rd_bank_addr(p)(1) <= chan_v & row_p1_v(log2(BUFFER_DEPTH) -1 downto 1);
            else
                rd_bank_addr(p)(0) <= chan_v & row_p1_v(log2(BUFFER_DEPTH) -1 downto 1);
                rd_bank_addr(p)(1) <= chan_v & row_v   (log2(BUFFER_DEPTH) -1 downto 1);
            end if;
        end process;
    end generate;

    -- Cycle 1 registers: per-region-slot channel and intra-row offset/parity
    rd_pipe_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            for p in 0 to (MFB_REGIONS -1) loop
                rd_chan_p_reg(p)  <= rd_chan_eff(p);
                rd_off_reg(p)     <= rd_addr_eff(p)(log2(MFB_BYTES) -1 downto 0);
                rd_row_lsb_reg(p) <= rd_addr_eff(p)(log2(MFB_BYTES));
            end loop;
        end if;
    end process;

    -- Cycle 1: select the memory array by the registered channel, then assemble the requested
    -- word from the even/odd banks of that array
    rd_arr_mux_g : for p in 0 to (MFB_REGIONS -1) generate
        rd_data_bank0_mux(p) <= rd_data_bram_bank(0)(to_integer(unsigned(rd_chan_p_reg(p)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(p);
        rd_data_bank1_mux(p) <= rd_data_bram_bank(1)(to_integer(unsigned(rd_chan_p_reg(p)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(p);
        rd_data_assembled(p) <= assemble_bank_bytes(rd_row_lsb_reg(p), rd_off_reg(p), rd_data_bank0_mux(p), rd_data_bank1_mux(p));
    end generate;

    -- Demultiplexers / output stage
    -- The split port configuration is only possible for the 2-region variant, which uses
    -- dual-port memory arrays for write (the 1-region variant uses an SDP configuration).
    split_port_logic_g : if (SPLIT_READ_PORTS and MFB_REGIONS = 2) generate

        bram_demux_p : process (all) is
        begin
            rd_en_bram_demux                                                                                                                   <= (others => (others => '0'));
            rd_en_bram_demux(to_integer(unsigned(rd_chan_eff(0)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(0) <= RD_EN_A;
            rd_en_bram_demux(to_integer(unsigned(rd_chan_eff(1)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(1) <= RD_EN_B;
        end process;

        RD_DATA_VLD_A <= rd_data_valid_arr(0);
        RD_DATA_VLD_B <= rd_data_valid_arr(1);

        rd_out_a_g : if (READ_BARREL_SHIFTER_EN(0)) generate
            rd_data_barrel_shifter_a_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- writing side
                BLOCKS     => MFB_BYTES,
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_data_assembled(0),
                DATA_OUT => RD_DATA_A,
                SEL      => rd_off_reg(0)
            );
        else generate
            RD_DATA_A <= rd_data_bank1_mux(0) when (rd_row_lsb_reg(0) = '1') else rd_data_bank0_mux(0);
        end generate;

        rd_out_b_g : if (READ_BARREL_SHIFTER_EN(1)) generate
            rd_data_barrel_shifter_b_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- writing side
                BLOCKS     => MFB_BYTES,
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_data_assembled(1),
                DATA_OUT => RD_DATA_B,
                SEL      => rd_off_reg(1)
            );
        else generate
            RD_DATA_B <= rd_data_bank1_mux(1) when (rd_row_lsb_reg(1) = '1') else rd_data_bank0_mux(1);
        end generate;

    else generate
        signal rd_data_bank0_sel     : std_logic_vector(MFB_LENGTH -1 downto 0);
        signal rd_data_bank1_sel     : std_logic_vector(MFB_LENGTH -1 downto 0);
        signal rd_data_assembled_sel : std_logic_vector(MFB_LENGTH -1 downto 0);
    begin
        bram_demux_p : process (all) is
        begin
            rd_en_bram_demux                                                                                                                <= (others => (others => '0'));
            rd_en_bram_demux(to_integer(unsigned(rd_chan_eff(0)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY))))) <= (others => RD_EN_A);
        end process;

        rd_data_sel_g : if (MFB_REGIONS = 1) generate
            rd_data_vld_reg_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    RD_DATA_VLD_A <= RD_EN_A;
                end if;
            end process;

            rd_data_bank0_sel <= rd_data_bank0_mux(0);
            rd_data_bank1_sel <= rd_data_bank1_mux(0);
        else generate
            -- The read is attempted on both region-slots simultaneously (see rd_eff_bcast_g above);
            -- whichever one succeeds (was not stalled by a concurrent write) provides the data.
            rd_data_demux_p : process (all)
            begin
                RD_DATA_VLD_A     <= '0';
                rd_data_bank0_sel <= rd_data_bank0_mux(0);
                rd_data_bank1_sel <= rd_data_bank1_mux(0);

                for i in 0 to (MFB_REGIONS -1) loop
                    if (rd_data_valid_arr(i) = '1') then
                        RD_DATA_VLD_A     <= '1';
                        rd_data_bank0_sel <= rd_data_bank0_mux(i);
                        rd_data_bank1_sel <= rd_data_bank1_mux(i);
                    end if;
                end loop;
            end process;
        end generate;

        rd_data_assembled_sel <= assemble_bank_bytes(rd_row_lsb_reg(0), rd_off_reg(0), rd_data_bank0_sel, rd_data_bank1_sel);

        rd_out_a_g : if (READ_BARREL_SHIFTER_EN(0)) generate
            rd_data_barrel_shifter_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                BLOCKS     => MFB_BYTES,
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- writing side
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_data_assembled_sel,
                DATA_OUT => RD_DATA_A,
                SEL      => rd_off_reg(0)
            );
        else generate
            RD_DATA_A <= rd_data_bank1_sel when (rd_row_lsb_reg(0) = '1') else rd_data_bank0_sel;
        end generate;
    end generate;
end architecture;
