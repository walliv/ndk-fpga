-- tx_dma_pcie_trans_buffer_wr_front.vhd: write front end shared by the implementations of the PCIe transaction buffer
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

-- Registers the input MFB word, tracks the address and the channel of the frame in progress and rotates the word
-- and its byte enables to their positions in the memory row for each write port (A for region 0, B for region 1).
entity TX_DMA_PCIE_TRANS_BUFFER_WR_FRONT is
    generic (
        CHANNELS : natural := 8;

        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;

        -- Geometry of the memory arrays of the implementation, which selects the bits of MEM_ARR_IDX
        CHANS_PER_ARRAY : natural := 8;
        MEM_ARRAYS      : natural := 1;

        -- Number of input registers
        INP_REG_NUM : natural := 1
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        PCIE_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        PCIE_MFB_META    : in  slv_array_t(MFB_REGIONS -1 downto 0)(trbuf_meta_width_f(CHANNELS, MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)-1 downto 0);
        PCIE_MFB_SOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_SRC_RDY : in  std_logic;

        -- The input word behind the input registers with the address and the channel fields of its META
        WR_SRC_RDY : out std_logic;
        WR_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        WR_ADDR    : out slv_array_t(MFB_REGIONS -1 downto 0)(TRBUF_META_PCIE_ADDR_W -1 downto 0);
        WR_CHAN    : out slv_array_t(MFB_REGIONS -1 downto 0)(log2(CHANNELS) -1 downto 0);

        -- Rotation of each write port and the word and the byte enables it rotates
        WR_SHIFT     : out slv_array_t(MFB_REGIONS -1 downto 0)(log2((MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/32) -1 downto 0);
        WR_DATA      : out slv_array_t(MFB_REGIONS -1 downto 0)(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH -1 downto 0);
        WR_BE        : out slv_array_t(MFB_REGIONS -1 downto 0)((MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 -1 downto 0);

        -- DWord address of the next word of the frame in progress, its channel and its memory array
        ADDR_CNTR   : out std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
        CHAN_NUM    : out std_logic_vector(log2(CHANNELS) -1 downto 0);
        MEM_ARR_IDX : out std_logic_vector(max(1, log2(MEM_ARRAYS)) -1 downto 0)
    );
end entity;

architecture FULL of TX_DMA_PCIE_TRANS_BUFFER_WR_FRONT is

    constant MFB_LENGTH : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    -- Number of Dwords in MFB word (equal as the nummber of items)
    constant MFB_DWORDS : natural := MFB_LENGTH/MFB_ITEM_WIDTH;

    -- =============================================================================================
    -- Defining ranges for meta signal
    -- =============================================================================================
    constant META_CHAN_NUM_W : natural := log2(CHANNELS);
    constant META_BE_W       : natural := (MFB_LENGTH/MFB_REGIONS)/8;
    constant META_BE_O       : natural := trbuf_meta_be_o_f(CHANNELS);

    subtype META_CHAN_NUM is natural range TRBUF_META_CHAN_NUM_O + META_CHAN_NUM_W -1 downto TRBUF_META_CHAN_NUM_O;
    subtype META_BE       is natural range META_BE_O + META_BE_W -1 downto META_BE_O;

    -- Input register
    signal pcie_mfb_data_inp_reg    : slv_array_t(INP_REG_NUM downto 0)(PCIE_MFB_DATA'range);
    signal pcie_mfb_meta_inp_reg    : slv_array_2d_t(INP_REG_NUM downto 0)(MFB_REGIONS -1 downto 0)(PCIE_MFB_META(0)'range);
    signal pcie_mfb_sof_inp_reg     : slv_array_t(INP_REG_NUM downto 0)(PCIE_MFB_SOF'range);
    signal pcie_mfb_src_rdy_inp_reg : std_logic_vector(INP_REG_NUM downto 0);

    -- counter of the address for each valid word following the beginning of the transaction
    signal addr_cntr_pst            : unsigned(TRBUF_META_PCIE_ADDR_W -1 downto 0);
    signal addr_cntr_nst            : unsigned(TRBUF_META_PCIE_ADDR_W -1 downto 0);

    -- Stores the index of the packet that get currently stored
    signal chan_num_reg             : std_logic_vector(META_CHAN_NUM_W -1 downto 0);
    signal chan_num_next            : std_logic_vector(META_CHAN_NUM_W -1 downto 0);

    -- control of the amount of shift on the writing barrel shifters
    signal wr_shift_sel             : slv_array_t(MFB_REGIONS - 1 downto 0)(log2(MFB_LENGTH/32) -1 downto 0);

    signal mem_arr_idx_reg          : std_logic_vector(MEM_ARR_IDX'range);
    signal mem_arr_idx_next         : std_logic_vector(MEM_ARR_IDX'range);

    -- Meta array
    signal pcie_mfb_meta_arr        : slv_array_t(MFB_REGIONS - 1 downto 0)(PCIE_MFB_META(0)'range);

    -- Meta signal for whole MFB word
    signal pcie_meta_be_per_port    : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_LENGTH/8 - 1 downto 0);

begin

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

    WR_SRC_RDY <= pcie_mfb_src_rdy_inp_reg(INP_REG_NUM);
    WR_SOF     <= pcie_mfb_sof_inp_reg(INP_REG_NUM);

    wr_fields_g : for i in 0 to (MFB_REGIONS -1) generate
        WR_ADDR(i) <= pcie_mfb_meta_arr(i)(TRBUF_META_PCIE_ADDR);
        WR_CHAN(i) <= pcie_mfb_meta_arr(i)(META_CHAN_NUM);
    end generate;

    WR_SHIFT     <= wr_shift_sel;
    ADDR_CNTR    <= std_logic_vector(addr_cntr_pst);
    CHAN_NUM     <= chan_num_reg;
    MEM_ARR_IDX  <= mem_arr_idx_reg;

    -- =============================================================================================
    -- Assertions for verification
    -- =============================================================================================

    -- psl default clock is rising_edge(CLK);

    captured_dma_hdr_assert_g : for it in 0 to (MFB_REGIONS -1) generate
    begin
        -- psl assert_captured_dma_header :
        --      assert always ((not (PCIE_MFB_SRC_RDY = '1' or PCIE_MFB_META(it)(META_BE) /= (META_BE_W -1 downto 0 => '0'))) or
        --              (PCIE_MFB_META(it)(TRBUF_META_IS_DMA_HDR) = "0")) abort(RESET)
        --      report "TX_DMA_PCIE_TRANS_BUFFER: captured DMA header on a region. Danger of data overwrite!";
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
                    -- First SOF does +16, the second makes +8
                    -- When second SOF is present, this automatically takes the address from the
                    -- second region and adds increment of 8 to that. If there is only one SOF and
                    -- particularly in the first region, then increment by 16 because the frame
                    -- continues in the next word.
                    addr_cntr_nst   <= unsigned(pcie_mfb_meta_arr(i)(TRBUF_META_PCIE_ADDR)) + (MFB_REGIONS - i)*MFB_BLOCK_SIZE;
                    chan_num_next   <= pcie_mfb_meta_arr(i)(META_CHAN_NUM);
                end if;
            end loop;
        end if;
    end process;

    -- =============================================================================================
    -- META(BE) select
    -- =============================================================================================
    -- This process selects which bytes are enabled in which BS based on the SOF status in the second region
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

    -- =============================================================================================
    -- Data shift - Port A
    -- =============================================================================================
    -- This process controls the shift of the input word and the corresponding byte enable signal to it.
    -- When beginning of a transaction is captured, the shift is taken directly from the current address,
    -- but when it continues, then select shift from the counter of addresses.

    -- The previous "2 downto 0" is specification of address - now generic for more regions
    -- The address system here is divided into two parts due to the dual-port BRAM configuration
    wr_bshifter_0_ctrl_p : process (all) is
        variable pcie_mfb_meta_addr_v : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
    begin
        wr_shift_sel(0) <= (others => '0');

        if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
            if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(0) = '1') then
                pcie_mfb_meta_addr_v    := pcie_mfb_meta_arr(0)(TRBUF_META_PCIE_ADDR);
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
        DATA_OUT => WR_DATA(0),
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
        DATA_OUT => WR_BE(0),
        SEL      => wr_shift_sel(0)
    );

    -- =============================================================================================
    -- Data shift - Port B
    -- =============================================================================================
    -- This packet starts at the beginning of the second region, so we need to correct the address
    -- by the number of DWords in region

    tworeg_bs_g: if (MFB_REGIONS = 2) generate
        wr_bshifter_1_ctrl_p : process (all) is
            variable pcie_mfb_meta_addr_v : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
        begin
            wr_shift_sel(1) <= (others => '0');

            if (pcie_mfb_src_rdy_inp_reg(INP_REG_NUM) = '1') then
                if (pcie_mfb_sof_inp_reg(INP_REG_NUM)(1) = '1') then
                    -- The '+8' is MFB_BLOCK_SIZE (same as length of a REGION in Dwords) and is
                    -- only used when the SOF is in the second region
                    -- NOTE: that -8 can be a source of error. Was +8 previously.
                    pcie_mfb_meta_addr_v    := std_logic_vector(unsigned(pcie_mfb_meta_arr(1)(TRBUF_META_PCIE_ADDR)) - 8);
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
            DATA_OUT => WR_DATA(1),
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
            DATA_OUT => WR_BE(1),
            SEL      => wr_shift_sel(1)
        );
    end generate;

    -- =============================================================================================
    -- Channel index store
    -- =============================================================================================
    -- Demultiplexer is based on value of META(Channel)
    -- Last value of the Channel is stored
    -- TODO: It should be taken into consideration that this storing process should be removed
    -- because the channel number is already extracted in METADATA_EXTRACTOR and the index of a
    -- channel is held through the duration of a whole packet.
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
    else generate
        mem_arr_idx_reg <= (others => '0');
    end generate;

end architecture;
