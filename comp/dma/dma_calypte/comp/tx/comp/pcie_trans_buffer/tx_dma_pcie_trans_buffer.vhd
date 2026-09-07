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

-- AMD XPM macros for the memory arrays (XPM_MEMORY_TDPRAM/XPM_MEMORY_SDPRAM), instantiated
-- directly rather than inferred -- see the DEVICE assertion and XPM_WRITE_MODE below for why
-- the write mode has to be stated explicitly here.
library xpm;
use xpm.vcomponents.all;

-- Rows alternate banks so a barrel-rotated write's two neighbouring rows land in different
-- banks, enabling URAM as well as BRAM (RAM_TYPE).

-- RD_EN/RD_ADDR/RD_CHAN assert RD_DATA_VLD READ_LATENCY cycles later, data on RD_DATA.
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
        -- If TRUE, the read data is shifted to the address low-bit offset; if FALSE, the port returns
        -- the plain MFB-word-aligned row, ignoring those bits.
        READ_BARREL_SHIFTER_EN : b_array_t(MFB_REGIONS -1 downto 0) := (others => TRUE);

        -- Memory primitive: AUTO resolves via RES_RAM_TYPE (URAM only on a 2-region AMD
        -- UltraScale+/Versal geometry, else BRAM), selecting XPM's block/ultra MEMORY_PRIMITIVE.
        -- URAM on an Intel DEVICE fails.
        RAM_TYPE : string := "AUTO";

        -- TRUE (default): each channel owns a 2**POINTER_WIDTH-byte region. FALSE: one flat
        -- CHANNELS*2**POINTER_WIDTH-byte space addressed only by the address field; RD_ADDR_*
        -- widens by log2(CHANNELS) bits.
        MEM_PARTITIONING : boolean := TRUE;

        -- XPM output-register latency for read ports. 1 (default): none, RD_DATA_VLD_* follows
        -- RD_EN_* one cycle later. 2: XPM's output register adds a BRAM cycle; rd_vld_p/rd_pipe_reg_p
        -- match it. TDP (2-region) read path only.
        READ_LATENCY : natural := 1;

        -- Number of input registers
        INP_REG_NUM   : natural := 1
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
    constant IS_INTEL_DEV       : boolean := (DEVICE = "STRATIX10" or DEVICE = "AGILEX");
    constant IS_XILINX_URAM_DEV : boolean := (DEVICE = "ULTRASCALE" or DEVICE = "VERSAL");
    -- Every AMD device this component can be built for (see the DEVICE assertion below). URAM is a
    -- subset of these (IS_XILINX_URAM_DEV above) -- 7SERIES has block RAM but no UltraRAM.
    constant IS_AMD_DEV         : boolean := (DEVICE = "7SERIES" or DEVICE = "ULTRASCALE" or DEVICE = "VERSAL");

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

    -- ==== XPM_MEMORY_TDPRAM configuration for the memory arrays below ====
    constant XPM_MEM_PRIMITIVE : string  := tsel(RES_RAM_TYPE = "URAM", "ultra", "block");

    -- Total array size IN BITS (XPM's MEMORY_SIZE unit), per bank.
    constant XPM_MEMORY_SIZE   : natural := BANK_ITEMS * MFB_LENGTH;

    -- Write mode: XPM_WRITE_MODE = "no_change" on both. BRAM same-address collision reads
    -- undetermined data (UG573 Table 3) -- unresolved, suspected corruption source. URAM has none
    -- by construction (port A before B, UG573 Table 38).
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
    signal rd_xrgn_collision   : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_en_bram_demux    : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_data_valid_arr   : std_logic_vector(MFB_REGIONS -1 downto 0);

    -- Memory array read data, indexed [bank][array][region]
    signal rd_data_bram_bank   : slv_array_3d_t(1 downto 0)(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);

    -- ==== Read path signals ====
    -- Effective RD_ADDR/RD_CHAN per region-slot: with SPLIT_READ_PORTS, slot P maps 1:1 to a port;
    -- else both broadcast from port A and race the same read (the unstalled one succeeds).
    signal rd_addr_eff : slv_array_t(MFB_REGIONS -1 downto 0)(POINTER_WIDTH -1 downto 0);
    signal rd_chan_eff : slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);

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

    -- =============================================================================================
    -- DEBUG signals (verification or ILA)
    -- =============================================================================================
    signal wr_addr_collision_detected : slv_array_t(MEM_ARRAYS -1 downto 0)(1 downto 0);
    signal rdwr_collision_detected    : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);

    -- Flat copy of wr_bank_addr(0)(0)'s chan_addr_v (see wr_bank_geom_a_p), for the PSL checks below:
    -- nvc's prev() rejects a slice taken directly from a nested array-of-array-of-vector signal.
    signal wr_chan_slot_r0     : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
    -- One-cycle-registered copy of the above, for the boundary-cross cover below: nvc's prev() also
    -- refuses a generic-width (log2(CHANS_PER_ARRAY)) signal directly, so this register stands in
    -- (PSL support only).
    signal wr_chan_slot_r0_reg : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);

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

    assert (READ_LATENCY = 1 or READ_LATENCY = 2)
        report "TX_DMA_PCIE_TRANS_BUFFER: READ_LATENCY must be 1 (no output register) or 2 (XPM output register)!"
        severity FAILURE;

    -- READ_LATENCY=2's extra stage only exists on the TDP (2-region) read-valid/pipe registers
    -- (rd_vld_p/rd_pipe_reg_p); the SDP path (MFB_REGIONS=1) keeps a fixed 1-cycle RD_DATA_VLD_A,
    -- so this combination is unsupported.
    assert (not (READ_LATENCY = 2 and MFB_REGIONS = 1))
        report "TX_DMA_PCIE_TRANS_BUFFER: READ_LATENCY => 2 is only implemented for the 2-region (TDP) read path!"
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

    -- ==== Assertions for verification ====

    -- psl default clock is rising_edge(CLK);

    -- Every known caller (TX_DMA_CALYPTE, N2C_CONTROLLER) permanently zeroes the write META's
    -- IS_DMA_HDR bit before this port; asserts are unrolled per-region because nvc 1.21.0's PSL
    -- simple subset cannot parse forall.

    -- psl assert_captured_dma_header_r0 : assert always
    -- ((PCIE_MFB_SRC_RDY = '1' or PCIE_MFB_META(0)(META_BE) /= (META_BE_W -1 downto 0 => '0')) ->
    -- PCIE_MFB_META(0)(META_IS_DMA_HDR) = "0") abort(RESET)
    -- report "region 0: an active write word carries a set IS_DMA_HDR bit";

    mfb_hdr_assert_r1_g : if (MFB_REGIONS = 2) generate
    begin
        -- psl assert_captured_dma_header_r1 : assert always
        -- ((PCIE_MFB_SRC_RDY = '1' or PCIE_MFB_META(1)(META_BE) /= (META_BE_W -1 downto 0 => '0')) ->
        -- PCIE_MFB_META(1)(META_IS_DMA_HDR) = "0") abort(RESET)
        -- report "region 1: an active write word carries a set IS_DMA_HDR bit";
    end generate;

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
                    -- First SOF: +16; second-SOF-present: address comes from the second region, +8; only-first-SOF:
                    -- +16, since the frame continues into the next word.
                    addr_cntr_nst   <= unsigned(pcie_mfb_meta_arr(i)(META_PCIE_ADDR)) + (MFB_REGIONS - i)*MFB_BLOCK_SIZE;
                    chan_num_next   <= pcie_mfb_meta_arr(i)(META_CHAN_NUM);
                end if;
            end loop;
        end if;
    end process;

    -- ==== META(BE) select ====
    -- Selects which bytes are enabled per shifter, based on SOF in the second region.
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

        -- Byte-enable ownership: region 1's BE may only merge into region 0's write (else branch
        -- above) when region 1 is NOT starting its own frame this cycle -- guards a real bug once
        -- fixed in N2C_CONTROLLER's cq_be_keep_p.

        -- psl assert_be_ownership : assert always
        -- (pcie_mfb_sof_inp_reg(INP_REG_NUM)(1) = '1' ->
        -- pcie_meta_be_per_port(0)(MFB_BYTES -1 downto META_BE_W) = (MFB_BYTES - META_BE_W -1 downto 0 => '0'))
        -- report "region 1 owns this SOF word, yet region 1's BE leaked into region 0's write enable";
    end generate;

    -- ==== Data shift - Port A ====
    -- Shift/BE come from the current address at SOF, else the running address counter, split in two
    -- for the dual-port BRAM configuration.
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

    -- ==== Data shift - Port B ====
    -- Starts at the second region, so the address is corrected by one region's DWords.

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

    -- ==== Write bank geometry - Port A (region 0) ====
    -- Even/odd bank per byte, plus the banks' shared row address.
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

    -- Verify each mode reads the write channel-slot bits (chan_addr_v, upper log2(CHANS_PER_ARRAY)
    -- bits of wr_bank_addr(0)) from its OWN field -- regression guard against the other mode's
    -- field leaking in, checked at SOF.
    wr_chan_slot_r0 <= wr_bank_addr(0)(0)(BANK_ADDR_W -1 downto BANK_ADDR_W - log2(CHANS_PER_ARRAY));

    wr_chan_slot_r0_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            wr_chan_slot_r0_reg <= wr_chan_slot_r0;
        end if;
    end process;

    -- PCIE_MFB_META(0)(META_PCIE_ADDR) keeps its ORIGINAL absolute bit numbering when sliced directly
    -- (unlike pcie_mfb_meta_addr_v, renumbered 0-based); add META_PCIE_ADDR_O to land on the same
    -- bit the FLAT branch reads.

    -- psl assert_flat_wr_chan_from_addr : assert always
    -- ((FLAT and pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1' and pcie_mfb_sof_inp_reg(INP_REG_NUM)(0) = '1') ->
    -- wr_chan_slot_r0 = pcie_mfb_meta_arr(0)(META_PCIE_ADDR)(FLAT_CHAN_LSB_DW + log2(CHANS_PER_ARRAY) -1 + META_PCIE_ADDR_O downto FLAT_CHAN_LSB_DW + META_PCIE_ADDR_O))
    -- report "flat mode: region 0's write channel-slot did not come from the address field";

    -- psl assert_part_wr_chan_from_field : assert always
    -- ((not FLAT and pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1' and pcie_mfb_sof_inp_reg(INP_REG_NUM)(0) = '1') ->
    -- wr_chan_slot_r0 = pcie_mfb_meta_arr(0)(log2(CHANS_PER_ARRAY) + META_CHAN_NUM_O -1 downto META_CHAN_NUM_O))
    -- report "partitioned mode: region 0's write channel-slot did not come from the channel field";

    -- A continuation word (no new SOF) whose tracked write channel-slot differs from the previous
    -- cycle's crosses a would-be channel boundary mid-frame (flat mode only).

    -- psl cover_flat_boundary_cross : cover
    -- {FLAT and pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1' and pcie_mfb_sof_inp_reg(INP_REG_NUM)(0) = '0' and
    -- wr_chan_slot_r0 /= wr_chan_slot_r0_reg};

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

    -- ==== Input-stream guard ====
    -- Quasi-BRAM-writing MFB variant: no EOF/DST_RDY, so EOF/SOF and DATA-META-stable checks don't
    -- apply; only checkable invariant: a deasserted (registered) SRC_RDY must never itself produce
    -- write byte-enables.

    -- psl assert_no_write_when_idle_r0 : assert always
    -- (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '0' ->
    -- (wr_bank_be(0)(0) = (MFB_BYTES -1 downto 0 => '0') and wr_bank_be(0)(1) = (MFB_BYTES -1 downto 0 => '0')))
    -- report "region 0 produced write byte-enables while its registered SRC_RDY was low";

    mfb_idle_assert_r1_g : if (MFB_REGIONS = 2) generate
    begin
        -- psl assert_no_write_when_idle_r1 : assert always
        -- (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '0' ->
        -- (wr_bank_be(1)(0) = (MFB_BYTES -1 downto 0 => '0') and wr_bank_be(1)(1) = (MFB_BYTES -1 downto 0 => '0')))
        -- report "region 1 produced write byte-enables while its registered SRC_RDY was low";
    end generate;

    -- ==== Channel index store / per-region target-array index ====
    -- Stores last SOF's channel, picks target array.
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

        -- Per-region target-array index (arr_idx_rgn); see its declaration above for why it is only
        -- ever compared, never indexed.
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
                    -- Fed from READ_LATENCY for consistency with the TDP array below; the elaboration
                    -- assert guarantees this is always 1 here (READ_LATENCY=2 + MFB_REGIONS=1 is
                    -- rejected), matching rd_data_vld_reg_p's fixed 1-cycle RD_DATA_VLD_A.
                    READ_LATENCY_B     => READ_LATENCY,
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

        -- Verify the gating above actually holds (a gated read never reaches rd_en_pch) and that a
        -- cross-region collision is genuinely exercised, not just structurally impossible to hit.
        rd_xrgn_gate_assert_g : for ch in 0 to (MEM_ARRAYS -1) generate
            rd_xrgn_gate_assert_rgn_g : for rgn in 0 to (MFB_REGIONS -1) generate
            begin
                -- psl assert_xrgn_gate : assert never
                -- (rd_en_pch(ch)(rgn) = '1' and rd_xrgn_collision(ch)(rgn) = '1')
                -- report "cross-region read/write collision reached rd_en_pch ungated";

                -- psl cover_xrgn_collision : cover {rd_xrgn_collision(ch)(rgn) = '1'};
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
                    -- Fed from the READ_LATENCY generic (1 = today's no-output-register behaviour,
                    -- 2 = XPM output register); rd_vld_p/rd_pipe_reg_p below gain a matching extra
                    -- pipeline stage when READ_LATENCY => 2 (see rd_vld_lat2_g/rd_pipe_lat2_g).
                    READ_LATENCY_A     => READ_LATENCY,
                    WRITE_MODE_A       => XPM_WRITE_MODE,

                    WRITE_DATA_WIDTH_B => MFB_LENGTH,
                    READ_DATA_WIDTH_B  => MFB_LENGTH,
                    BYTE_WRITE_WIDTH_B => 8,
                    ADDR_WIDTH_B       => BANK_ADDR_W,
                    READ_RESET_VALUE_B => "0",
                    READ_LATENCY_B     => READ_LATENCY,
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

        -- READ_LATENCY => 1: rd_data_valid_arr IS the cycle-1 result above (plain wire, no added
        -- register -- keeps this configuration's netlist identical to before READ_LATENCY existed).
        rd_vld_lat1_g : if (READ_LATENCY = 1) generate
            rd_data_valid_arr <= rd_data_valid_arr_stg1;
        end generate;

        -- READ_LATENCY => 2: one extra register re-aligns rd_data_valid_arr with the XPM output
        -- register's additional cycle of BRAM latency (READ_LATENCY_A/B fed from the generic above).
        rd_vld_lat2_g : if (READ_LATENCY = 2) generate
            rd_vld_extra_reg_p : process (CLK)
            begin
                if rising_edge(CLK) then
                    rd_data_valid_arr <= rd_data_valid_arr_stg1;
                end if;
            end process;
        end generate;
    end generate;

    -- ==== Read address / channel sources ====
    -- SPLIT_READ_PORTS maps P to a port; else broadcast from port A.
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

        -- Straddling path. A window at an arbitrary byte offset spans rows R and R+1, which live in
        -- opposite banks, so both must be fetched for assemble_bank_bytes/the barrel shifter to
        -- splice them. Costs a row+1 adder and a parity mux on BOTH bank addresses.
        rd_geom_shifted_g : if (READ_BARREL_SHIFTER_EN(p)) generate
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

        -- Aligned path: READ_BARREL_SHIFTER_EN(p)=FALSE returns the word-aligned row (no straddling,
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

    -- READ_LATENCY => 1: rd_chan_p_reg/rd_off_reg/rd_row_lsb_reg ARE the cycle-1 results above
    -- (plain wires, no added registers -- keeps this configuration's netlist identical to before
    -- READ_LATENCY existed).
    rd_pipe_lat1_g : if (READ_LATENCY = 1) generate
        rd_chan_p_reg  <= rd_chan_p_reg_stg1;
        rd_off_reg     <= rd_off_reg_stg1;
        rd_row_lsb_reg <= rd_row_lsb_reg_stg1;
    end generate;

    -- READ_LATENCY => 2: one extra register stage on each, re-aligning them with the XPM output
    -- register's additional cycle of BRAM latency (matching rd_vld_lat2_g above).
    rd_pipe_lat2_g : if (READ_LATENCY = 2) generate
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
                    RD_DATA_VLD_A <= RD_EN_A and (not (or rd_1rgn_collision));
                end if;
            end process;

            -- Verify the gating above holds: RD_DATA_VLD_A is registered one cycle behind
            -- rd_1rgn_collision, so a valid read must never trace back to a colliding sample.

            -- psl assert_1rgn_gate : assert always
            -- (RD_DATA_VLD_A = '1' -> (or prev(rd_1rgn_collision)) = '0')
            -- report "SDP-path (1-region) read validated despite a same-cycle write collision";

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
