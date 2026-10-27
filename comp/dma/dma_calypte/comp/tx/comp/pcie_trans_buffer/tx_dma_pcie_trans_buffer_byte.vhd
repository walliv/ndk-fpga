-- tx_dma_pcie_trans_buffer_byte.vhd: this is a specially made component to buffer PCIe transactions
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
use work.tx_dma_pcie_trans_buffer_pkg.all;

-- This component instantiaties data buffer for every channel.Each buffer consists from an array of
-- BRAMs which total to the size of the input MFB bus in bytes, i.e. 32 \* *MFB_REGIONS*. This buffer
-- architecture has been chosen because of the address alignment to individual bytes for the
-- incoming PCIe transactions. This also causes the largest resource footprint this entity has in
-- the TX DMA Calypte controller. Since one array of BRAMs can contain much more data than the
-- largest packet able to be transmitted on a channel, the BRAM array is shared between multiple
-- channels. The amount  of channels sharing one array depends on :vhdl:genconstant:`POINTER_WIDTH`
-- and :vhdl:genconstant:`MFB_REGIONS` generic parameters. The extent of buffer sharing is shown
-- in the following table:
--
-- +--------------------+---------------------------+---------------------+
-- | BRAM Size          |           2048 B          |        4096 B       |
-- +--------------------+---------------------------+---------------------+
-- | BRAM Type          | RAMB16 (AMD)/M20K (Intel) |     RAMB36 (AMD)    |
-- +====================+=============+=============+==========+==========+
-- | MFB_REGIONS        | 1           | 2           | 1        | 2        |
-- +--------------------+-------------+-------------+----------+----------+
-- | BRAMs per array    | 32          | 64          | 32       | 64       |
-- +--------------------+-------------+-------------+----------+----------+
-- | Channels per array | up to 8     | up to 16    | up to 16 | up to 32 |
-- +--------------------+-------------+-------------+----------+----------+
--
-- .. NOTE:: Requiring more channels than the maximum amount per array results in an instantiation
--           of multiple BRAM arrays.
--
-- On the output, there is a standard RAM reading interface for multiple channels. Upon setting the
-- address on the :vhdl:portsignal:`RD_ADDR`, an index of a channel on :vhdl:portsignal:`RD_CHAN` and
-- asserting :vhdl:portsignal:`RD_EN`, the
-- core asserts :vhdl:portsignal:`RD_DATA_VLD` 1 or more clock periods later when valid data are
-- available on the :vhdl:portsignal:`RD_DATA` output port.
--
architecture BYTE of TX_DMA_PCIE_TRANS_BUFFER_IMPL is

    constant MFB_LENGTH      : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    -- Number of Dwords in MFB word (equal as the nummber of items)
    constant MFB_DWORDS      : natural := MFB_LENGTH/MFB_ITEM_WIDTH;
    -- Number of bytes in MFB word
    constant MFB_BYTES       : natural := MFB_LENGTH/8;
    -- The Address is restricted by BAR_APERTURE (IP_core setting)
    constant BUFFER_DEPTH    : natural := trbuf_buffer_depth_f(POINTER_WIDTH, MFB_LENGTH);
    -- Number of registers between the barrel shifters and the BRAMs
    constant BRAM_REG_NUM    : natural := 2;
    constant IS_INTEL_DEV    : boolean := (DEVICE = "STRATIX10" or DEVICE = "AGILEX");
    -- a maximum depth of a BRAM block (in 1B items) depends on a vendor
    constant MAX_BRAM_DEPTH  : natural := tsel(IS_INTEL_DEV, TRBUF_DEPTH_M20K, TRBUF_DEPTH_BRAM);
    -- The amount of channels that fits to one array
    constant CHANS_PER_ARRAY : natural := trbuf_chans_per_array_f(CHANNELS, BUFFER_DEPTH, MAX_BRAM_DEPTH);
    -- Number of memory arrays since one array can contain multiple channels
    constant MEM_ARRAYS      : natural := CHANNELS/CHANS_PER_ARRAY;

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

    signal wr_be_bram_bshifter      : slv_array_t(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0);
    signal wr_be_bram_demux         : slv_array_2d_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0);
    signal wr_addr_bram_by_shift    : slv_array_2d_t(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/32) -1 downto 0)(log2(BUFFER_DEPTH*CHANS_PER_ARRAY) -1 downto 0);
    signal wr_data_bram_bshifter    : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_LENGTH -1 downto 0);

    signal mem_arr_idx_reg          : std_logic_vector(max(1, log2(MEM_ARRAYS)) -1 downto 0);

    signal rd_en_bram_demux         : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0);
    signal rd_data_bram_mux         : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_data_bram             : slv_array_2d_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS - 1 downto 0)(MFB_LENGTH -1 downto 0);
    signal rd_addr_bram_by_shift    : slv_array_2d_t(MFB_REGIONS -1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0)(log2(BUFFER_DEPTH*CHANS_PER_ARRAY) -1 downto 0);

    -- ================= --
    -- 2 regions support --
    -- ================= --
    -- Converter signal: PCIE_MFB_DATA'length/32 => PCIE_MFB_DATA'length/ 8
    -- Address the item in a BRAM for each byte for each region
    signal wr_addr_bram_by_multi    : slv_array_2d_t(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0)(log2(BUFFER_DEPTH*CHANS_PER_ARRAY) -1 downto 0);

    -- Read/Write Address - TDP
    signal rw_addr_bram_by_mux      : slv_array_3d_t(MEM_ARRAYS - 1 downto 0)(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0)(log2(BUFFER_DEPTH*CHANS_PER_ARRAY) -1 downto 0);

    -- Read data valid - TDP
    signal rd_data_valid_arr        : std_logic_vector(MFB_REGIONS - 1 downto 0);

    -- Read enable per memory array per BRAM port
    signal rd_en_pch                : slv_array_t(MEM_ARRAYS - 1 downto 0)(MFB_REGIONS - 1 downto 0);

    -- BRAM registers
    signal wr_be_bram_demux_reg      : slv_array_3d_t(BRAM_REG_NUM downto 0)(MEM_ARRAYS -1 downto 0)(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/8) -1 downto 0);
    signal wr_addr_bram_by_shift_reg : slv_array_3d_t(BRAM_REG_NUM downto 0)(MFB_REGIONS - 1 downto 0)((PCIE_MFB_DATA'length/32) -1 downto 0)(log2(BUFFER_DEPTH*CHANS_PER_ARRAY) -1 downto 0);
    signal wr_data_bram_shifter_reg  : slv_array_2d_t(BRAM_REG_NUM downto 0)(MFB_REGIONS - 1 downto 0)(MFB_LENGTH -1 downto 0);

    signal addr_sel                 : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS - 1 downto 0);

    signal rd_chan_a_reg : std_logic_vector(RD_CHAN_A'range);
    signal rd_chan_b_reg : std_logic_vector(RD_CHAN_B'range);
    signal rd_addr_a_reg : std_logic_vector(RD_ADDR_A'range);
    signal rd_addr_b_reg : std_logic_vector(RD_ADDR_B'range);

    -- Shifter enable of read port B, which needs split read ports and so 2 regions
    constant READ_BARREL_SHIFTER_EN_B : boolean := READ_BARREL_SHIFTER_EN(MFB_REGIONS -1);

    -- =============================================================================================
    -- DEBUG signals (verification or ILA)
    -- =============================================================================================
    signal wr_addr_collision_detected : slv_array_t(MEM_ARRAYS -1 downto 0)(MFB_BYTES -1 downto 0);
    signal rdwr_collision_detected    : slv_array_2d_t(MEM_ARRAYS -1 downto 0)(MFB_REGIONS -1 downto 0)(MFB_BYTES -1 downto 0);

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

        WR_SHIFT     => open,
        WR_DATA      => wr_data_bram_bshifter,
        WR_BE        => wr_be_bram_bshifter,

        ADDR_CNTR   => wr_addr_cntr,
        CHAN_NUM    => chan_num_reg,
        MEM_ARR_IDX => mem_arr_idx_reg
    );

    addr_cntr_pst <= unsigned(wr_addr_cntr);

    -- psl default clock is rising_edge(CLK);

    -- =============================================================================================
    -- Address correction
    -- =============================================================================================
    -- This process increments the address on the lowest DWords when shift occurs.
    -- That means that when data are shifted on the input, the rotation causes higher DWs to appear
    -- on the lower positions.
    -- Writing on the same address could cause the overwrite of data already stored in lower BRAMs.

    -- Possibilites:
    --     SOF(0) SOF(1)   PORTS
    -- 1)    0      0       A A
    -- 2)    0      1       A B  -- Illegal combination in this case
    -- 3)    1      0       A A
    -- 4)    1      1       A B

    -- Port A
    wr_addr_correction_a_p : process (all) is
        variable pcie_mfb_meta_addr_v : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
        variable buff_addr_v          : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
        variable chan_addr_v          : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
    begin
        wr_addr_bram_by_shift(0) <= (others => (others => '0'));

        if (wr_src_rdy = '1') then
            if (wr_sof(0) = '1') then
                -- Pass address to variable
                pcie_mfb_meta_addr_v := wr_addr(0);
                buff_addr_v          := pcie_mfb_meta_addr_v(log2(BUFFER_DEPTH)+log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS));
                chan_addr_v          := wr_chan(0)(log2(CHANS_PER_ARRAY) -1 downto 0);

                wr_addr_bram_by_shift(0) <= (others => (chan_addr_v & buff_addr_v));

                -- Increment address in bytes that have been rotated
                for i in 0 to ((MFB_LENGTH/32) -1) loop
                    if (i < unsigned(pcie_mfb_meta_addr_v(log2(MFB_DWORDS) - 1 downto 0))) then
                        wr_addr_bram_by_shift(0)(i) <= chan_addr_v & std_logic_vector(unsigned(buff_addr_v) + 1);
                    end if;
                end loop;
            else
                buff_addr_v := std_logic_vector(addr_cntr_pst(log2(BUFFER_DEPTH) + log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS)));
                chan_addr_v := chan_num_reg(log2(CHANS_PER_ARRAY) -1 downto 0);

                wr_addr_bram_by_shift(0) <= (others => (chan_addr_v & buff_addr_v));

                -- Increment address in bytes that have been rotated
                for i in 0 to ((MFB_LENGTH/32) -1) loop
                    if (i < addr_cntr_pst(log2(MFB_DWORDS) - 1 downto 0)) then
                        wr_addr_bram_by_shift(0)(i) <= chan_addr_v & std_logic_vector(unsigned(buff_addr_v) + 1);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- Port B
    wr_addr_correction_b_g: if (MFB_REGIONS = 2) generate
        wr_addr_correction_b_p : process (all) is
            variable pcie_mfb_meta_addr_v : std_logic_vector(TRBUF_META_PCIE_ADDR_W -1 downto 0);
            variable buff_addr_v          : std_logic_vector(log2(BUFFER_DEPTH) -1 downto 0);
            variable chan_addr_v          : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
        begin
            wr_addr_bram_by_shift(1) <= (others => (others => '0'));

            if (wr_src_rdy = '1') then
                if (wr_sof(1) = '1') then
                    -- Pass address to variable
                    pcie_mfb_meta_addr_v := wr_addr(1);
                    buff_addr_v          := pcie_mfb_meta_addr_v(log2(BUFFER_DEPTH)+log2(MFB_DWORDS) -1 downto log2(MFB_DWORDS));
                    chan_addr_v          := wr_chan(1)(log2(CHANS_PER_ARRAY) -1 downto 0);

                    wr_addr_bram_by_shift(1) <= (others => (chan_addr_v & buff_addr_v));

                    -- Increment address in bytes that has been overflowed
                    for i in 0 to ((MFB_LENGTH/32) -1) loop
                        if (i < unsigned(pcie_mfb_meta_addr_v(log2(MFB_DWORDS) - 1 downto 0))) then
                            wr_addr_bram_by_shift(1)(i) <= chan_addr_v & std_logic_vector(unsigned(buff_addr_v) + 1);
                        end if;
                    end loop;
                    -- else is not the case - the first port will handle it
                end if;
            end if;
        end process;
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
        -- =============================================================================================
        -- Demultiplexers - Byte enable
        -- =============================================================================================
        -- Possibilites:
        --     SOF(0) SOF(1)
        -- 1)    0      0   - Port A handles whole MFB word = Last valid channel is used
        -- 2)    0      1   - Port A handles first region, Second region is dispatched by port B (illegal for incoming data)
        -- 3)    1      0   - Port A handles whole MFB word = Current channel is used
        -- 4)    1      1   - Port A handles first region, Second region is dispatched by port B
        wr_bram_data_demux_p : process (all) is
        begin
            wr_be_bram_demux <= (others => (others => (others => '0')));

            for i in 0 to (MFB_REGIONS - 1) loop
                if (wr_src_rdy = '1') then
                    if (wr_sof(i) = '1') then
                        wr_be_bram_demux(to_integer(unsigned(wr_chan(i)(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(i) <= wr_be_bram_bshifter(i);
                    else
                        wr_be_bram_demux(to_integer(unsigned(mem_arr_idx_reg)))(i)                        <= wr_be_bram_bshifter(i);
                    end if;
                end if;
            end loop;
        end process;
    else generate

        wr_bram_data_demux_p : process (all) is
        begin
            wr_be_bram_demux <= (others => (others => (others => '0')));

            for i in 0 to (MFB_REGIONS - 1) loop
                if (wr_src_rdy = '1') then
                    wr_be_bram_demux(0)(i) <= wr_be_bram_bshifter(i);
                end if;
            end loop;
        end process;
    end generate;

    -- =============================================================================================
    -- Registers between BARREL_SHIFTERs and BRAMs
    -- =============================================================================================
    wr_be_bram_demux_reg(0)      <= wr_be_bram_demux;
    wr_addr_bram_by_shift_reg(0) <= wr_addr_bram_by_shift;
    wr_data_bram_shifter_reg (0) <= wr_data_bram_bshifter;

    bram_input_reg_mult_g: if (BRAM_REG_NUM > 0) generate
        bram_input_reg_g : for i in 0 to BRAM_REG_NUM - 1 generate
            bram_input_reg_p : process (CLK) is
            begin
                if rising_edge(CLK) then
                    wr_be_bram_demux_reg     (i + 1) <= wr_be_bram_demux_reg     (i);
                    wr_addr_bram_by_shift_reg(i + 1) <= wr_addr_bram_by_shift_reg(i);
                    wr_data_bram_shifter_reg (i + 1) <= wr_data_bram_shifter_reg (i);
                end if;
            end process;
        end generate;
    end generate;

    -- =============================================================================================
    -- BRAM - One region
    -- =============================================================================================
    -- One region
    sdp_bram_g: if (MFB_REGIONS = 1) generate
        brams_for_channels_g : for mem_arr_idx in 0 to (MEM_ARRAYS -1) generate
            brams_per_byte : for wbyte in 0 to ((MFB_LENGTH/8) -1) generate
                sdp_bram_be_i : entity work.SDP_BRAM_BE
                generic map (
                    BLOCK_ENABLE   => false,
                    -- allow individual bytes to be assigned
                    BLOCK_WIDTH    => 8,
                    -- each BRAM allows to write a single DW
                    DATA_WIDTH     => 8,
                    -- the depth of the buffer
                    ITEMS          => BUFFER_DEPTH*CHANS_PER_ARRAY,
                    COMMON_CLOCK   => TRUE,
                    OUTPUT_REG     => FALSE,
                    METADATA_WIDTH => 0,
                    DEVICE         => DEVICE
                )
                port map (
                    WR_CLK      => CLK,
                    WR_RST      => RESET,
                    WR_EN       => wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(0)(wbyte),
                    WR_BE       => (others => '1'),
                    WR_ADDR     => wr_addr_bram_by_shift_reg(BRAM_REG_NUM)(0)(wbyte/4),
                    WR_DATA     => wr_data_bram_shifter_reg(BRAM_REG_NUM)(0)(wbyte*8 +7 downto wbyte*8),

                    RD_CLK      => CLK,
                    RD_RST      => RESET,
                    RD_EN       => '1',
                    RD_PIPE_EN  => rd_en_bram_demux(mem_arr_idx)(0),
                    RD_META_IN  => (others => '0'),
                    RD_ADDR     => rd_addr_bram_by_shift(0)(wbyte),
                    RD_DATA     => rd_data_bram(mem_arr_idx)(0)(wbyte*8 +7 downto wbyte*8),
                    RD_META_OUT => open,
                    RD_DATA_VLD => open
                );
            end generate;
        end generate;
    end generate;

    -- =============================================================================================
    -- BRAM - Two regions
    -- =============================================================================================
    tdp_bram_g: if (MFB_REGIONS = 2) generate

        -- Convert address of a DWORD to an address of each individual byte
        -- This is used for address multiplexing
        addr_multi_regions_g : for rgn in 0 to MFB_REGIONS - 1 generate
            -- Iterate over bytes of a region
            addr_multi_bytes_g : for wbyte in 0 to ((MFB_LENGTH/8) -1) generate
                wr_addr_bram_by_multi(rgn)(wbyte) <= wr_addr_bram_by_shift_reg(BRAM_REG_NUM)(rgn)(wbyte/4);
            end generate;
        end generate;

        -- Address Select
        -- First port controlled by Byte Enable
        -- Second port is controlled by the second region's SOF
        -- The first bit in Byte Enable is enough to decide whether read to write
        -- OPT: ORing the whole signal can be logically intensive. This could be done.
        -- in the beginning by oring only 4 first bits because there is a FBE portion which
        -- always has to have at least 1 bit set to 1.
        addr_sel_g: for ch in 0 to (MEM_ARRAYS -1) generate
            addr_sel(ch)(0) <= or wr_be_bram_demux_reg(BRAM_REG_NUM)(ch)(0);
            addr_sel(ch)(1) <= or wr_be_bram_demux_reg(BRAM_REG_NUM)(ch)(1);
        end generate;

        -- The Address Multiplexer - Choose between Write and Read Port
        addr_mux_chans_g : for ch in 0 to (MEM_ARRAYS -1) generate
            addr_mux_regions_g : for rgn in 0 to (MFB_REGIONS -1) generate
                addr_mux_p : process (all)
                begin
                    -- Default assignment
                    rw_addr_bram_by_mux(ch)(rgn)  <= (others => (others => '0'));

                    if (addr_sel(ch)(rgn) = '1') then
                        rw_addr_bram_by_mux(ch)(rgn) <= wr_addr_bram_by_multi(rgn);
                    else
                        rw_addr_bram_by_mux(ch)(rgn) <= rd_addr_bram_by_shift(rgn);
                    end if;
                end process;
            end generate;
        end generate;

        -- Read enable - Write port priority
        rd_en_ch_g : for ch in 0 to (MEM_ARRAYS -1) generate
            rd_en_reg_g : for rgn in 0 to (MFB_REGIONS -1) generate
                -- Read enable per channel
                rd_en_pch(ch)(rgn) <= rd_en_bram_demux(ch)(rgn) and (not addr_sel(ch)(rgn));
            end generate;
        end generate;

        brams_for_channels_g : for mem_arr_idx in 0 to (MEM_ARRAYS -1) generate
            tdp_bram_be_g : for wbyte in 0 to ((MFB_LENGTH/8) -1) generate

                tdp_bram_be_i : entity work.DP_BRAM_BEHAV
                generic map (
                    DATA_WIDTH => 8,
                    ITEMS      => CHANS_PER_ARRAY*BUFFER_DEPTH,
                    OUTPUT_REG => FALSE,
                    RDW_MODE_A => "WRITE_FIRST",
                    RDW_MODE_B => "WRITE_FIRST"
                )
                port map (
                    CLK => CLK,
                    RST => RESET,

                    -- =======================================================================
                    -- Port A
                    -- =======================================================================
                    PIPE_ENA => '1',
                    REA      => rd_en_pch(mem_arr_idx)(0),
                    WEA      => wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(0)(wbyte),
                    ADDRA    => rw_addr_bram_by_mux(mem_arr_idx)(0)(wbyte),
                    DIA      => wr_data_bram_shifter_reg(BRAM_REG_NUM)(0)(wbyte*8 +7 downto wbyte*8),
                    DOA      => rd_data_bram(mem_arr_idx)(0)(wbyte*8 +7 downto wbyte*8),
                    DOA_DV   => open,

                    -- =======================================================================
                    -- Port B
                    -- =======================================================================
                    PIPE_ENB => '1',
                    REB      => rd_en_pch(mem_arr_idx)(1),
                    WEB      => wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(1)(wbyte),
                    ADDRB    => rw_addr_bram_by_mux(mem_arr_idx)(1)(wbyte),
                    DIB      => wr_data_bram_shifter_reg(BRAM_REG_NUM)(1)(wbyte*8 +7 downto wbyte*8),
                    DOB      => rd_data_bram(mem_arr_idx)(1)(wbyte*8 +7 downto wbyte*8),
                    DOB_DV   => open
                );

                -- DEBUG process for simulation
                wr_addr_collision_detection_p : process (all) is
                begin

                    wr_addr_collision_detected(mem_arr_idx)(wbyte) <= '0';
                    rdwr_collision_detected(mem_arr_idx)(0)(wbyte) <= '0';
                    rdwr_collision_detected(mem_arr_idx)(1)(wbyte) <= '0';

                    -- dual concurrent write on the same address
                    if (wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(0)(wbyte) = '1' and
                        wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(1)(wbyte) = '1' and
                        rw_addr_bram_by_mux(mem_arr_idx)(0)(wbyte) = rw_addr_bram_by_mux(mem_arr_idx)(1)(wbyte)
                    ) then
                        wr_addr_collision_detected(mem_arr_idx)(wbyte) <= '1';
                    end if;

                    -- concurrent read and write on port A
                    if (wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(0)(wbyte) = '1' and
                        rd_en_pch(mem_arr_idx)(0) = '1'
                    ) then
                        rdwr_collision_detected(mem_arr_idx)(0)(wbyte) <= '1';
                    end if;

                    -- concurrent read and write on port B
                    if (wr_be_bram_demux_reg(BRAM_REG_NUM)(mem_arr_idx)(1)(wbyte) = '1' and
                        rd_en_pch(mem_arr_idx)(1) = '1'
                    ) then
                        rdwr_collision_detected(mem_arr_idx)(1)(wbyte) <= '1';
                    end if;
                end process;
            end generate;
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

        collision_reduce_p : process (all) is
            variable wr_addr_collision_v : std_logic;
            variable rdwr_collision_v    : std_logic;
        begin
            wr_addr_collision_v := '0';
            rdwr_collision_v    := '0';

            for mem_arr_idx in 0 to (MEM_ARRAYS -1) loop
                wr_addr_collision_v := wr_addr_collision_v or (or wr_addr_collision_detected(mem_arr_idx));

                for rgn in 0 to (MFB_REGIONS -1) loop
                    rdwr_collision_v := rdwr_collision_v or (or rdwr_collision_detected(mem_arr_idx)(rgn));
                end loop;
            end loop;

            wr_addr_collision <= wr_addr_collision_v;
            rdwr_collision    <= rdwr_collision_v;
        end process;

        -- Both regions of one word address the same byte of the same memory array. The BRAM keeps
        -- only one of the two values and the data of the other write are lost.
        -- psl assert_wr_addr_collision :
        --      assert always (wr_addr_collision = '0') abort (RESET)
        --      report "TX_DMA_PCIE_TRANS_BUFFER: Two regions write to one address, data are lost!";

        -- A read and a write use one BRAM port in the same clock cycle. The read enable is masked
        -- by the write in rd_en_ch_g, so this can only appear when that priority changes.
        -- psl assert_rdwr_collision :
        --      assert always (rdwr_collision = '0') abort (RESET)
        --      report "TX_DMA_PCIE_TRANS_BUFFER: A read and a write use one BRAM port at once!";
    end generate;

    -- =============================================================================================
    -- Demulitplexors
    -- =============================================================================================
    -- This register provides a one clock cycle delay which is needed since the data appear on the
    -- output one clock cycle after the address and a channel number has been set and, after that,
    -- multiplexed based on the channel index between memory arrays and shifted based on RD_ADDR_*.
    rd_data_vld_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            rd_chan_a_reg <= RD_CHAN_A;
            rd_chan_b_reg <= RD_CHAN_B;
            rd_addr_a_reg <= RD_ADDR_A;
            rd_addr_b_reg <= RD_ADDR_B;
        end if;
    end process;

    -- The split port configuration is only possible of 2-region variant since this uses dual-port
    -- BRAMs for write (the 1-region variant uses SDP configuration of a BRAM)
    split_port_logic_g : if (SPLIT_READ_PORTS and MFB_REGIONS = 2) generate

        bram_demux_p : process (all) is
        begin
            rd_en_bram_demux                                                                                                               <= (others => (others => '0'));
            rd_en_bram_demux(to_integer(unsigned(RD_CHAN_A(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(0) <= RD_EN_A;
            rd_en_bram_demux(to_integer(unsigned(RD_CHAN_B(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(1) <= RD_EN_B;

            rd_data_bram_mux    <= (others => (others => '0'));
            rd_data_bram_mux(0) <= rd_data_bram(to_integer(unsigned(rd_chan_a_reg(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(0);
            rd_data_bram_mux(1) <= rd_data_bram(to_integer(unsigned(rd_chan_b_reg(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(1);
        end process;

        RD_DATA_VLD_A <= rd_data_valid_arr(0);
        RD_DATA_VLD_B <= rd_data_valid_arr(1);

        rd_barrel_shifter_a_g : if (READ_BARREL_SHIFTER_EN(0)) generate
            rd_data_barrel_shifter_a_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- reading side
                BLOCKS     => MFB_BYTES,
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_data_bram_mux(0),
                DATA_OUT => RD_DATA_A,
                SEL      => rd_addr_a_reg(log2(MFB_BYTES) - 1 downto 0)
            );

            rd_addr_recalc_p : process (all) is
                variable chan_addr_a_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            begin
                chan_addr_a_v            := RD_CHAN_A(log2(CHANS_PER_ARRAY) -1 downto 0);
                rd_addr_bram_by_shift(0) <= (others => chan_addr_a_v & RD_ADDR_A(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES)));

                for i in 0 to ((MFB_LENGTH/8) -1) loop
                    if (i < unsigned(RD_ADDR_A(log2(MFB_BYTES) - 1 downto 0))) then
                        rd_addr_bram_by_shift(0)(i) <= chan_addr_a_v & std_logic_vector(unsigned(RD_ADDR_A(log2(BUFFER_DEPTH) + log2(MFB_BYTES) -1 downto log2(MFB_BYTES))) + 1);
                    end if;
                end loop;
            end process;
        else generate
            RD_DATA_A <= rd_data_bram_mux(0);

            rd_addr_recalc_p : process (all) is
                variable chan_addr_a_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            begin
                chan_addr_a_v            := RD_CHAN_A(log2(CHANS_PER_ARRAY) -1 downto 0);
                rd_addr_bram_by_shift(0) <= (others => chan_addr_a_v & RD_ADDR_A(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES)));
            end process;
        end generate;

        rd_barrel_shifter_b_g : if (READ_BARREL_SHIFTER_EN_B) generate
            rd_data_barrel_shifter_b_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- reading side
                BLOCKS     => MFB_BYTES,
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_data_bram_mux(1),
                DATA_OUT => RD_DATA_B,
                SEL      => rd_addr_b_reg(log2(MFB_BYTES) - 1 downto 0)
            );

            rd_addr_recalc_p : process (all) is
                variable chan_addr_b_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            begin
                chan_addr_b_v            := RD_CHAN_B(log2(CHANS_PER_ARRAY) -1 downto 0);
                rd_addr_bram_by_shift(1) <= (others => chan_addr_b_v & RD_ADDR_B(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES)));

                for i in 0 to ((MFB_LENGTH/8) -1) loop
                    if (i < unsigned(RD_ADDR_B(log2(MFB_BYTES) - 1 downto 0))) then
                        rd_addr_bram_by_shift(1)(i) <= chan_addr_b_v & std_logic_vector(unsigned(RD_ADDR_B(log2(BUFFER_DEPTH) + log2(MFB_BYTES) -1 downto log2(MFB_BYTES))) + 1);
                    end if;
                end loop;
            end process;
        else generate
            RD_DATA_B <= rd_data_bram_mux(1);

            rd_addr_recalc_p : process (all) is
                variable chan_addr_b_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            begin
                chan_addr_b_v            := RD_CHAN_B(log2(CHANS_PER_ARRAY) -1 downto 0);
                rd_addr_bram_by_shift(1) <= (others => chan_addr_b_v & RD_ADDR_B(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES)));
            end process;
        end generate;
    else generate
        bram_demux_p : process (all) is
        begin
            rd_en_bram_demux                                                                                                            <= (others => (others => '0'));
            rd_en_bram_demux(to_integer(unsigned(RD_CHAN_A(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY))))) <= (others => RD_EN_A);
        end process;

        rd_data_demux_g : if (MFB_REGIONS = 1) generate

            rd_data_vld_reg_p : process (CLK) is
            begin
                if (rising_edge(CLK)) then
                    RD_DATA_VLD_A <= RD_EN_A;
                end if;
            end process;

            rd_data_bram_mux(0) <= rd_data_bram(to_integer(unsigned(rd_chan_a_reg(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(0);
        else generate

            rd_data_demux_p : process (all)
            begin
                rd_data_bram_mux <= (others => (others => '0'));
                RD_DATA_VLD_A    <= '0';

                for i in 0 to MFB_REGIONS - 1 loop
                    if (rd_data_valid_arr(i) = '1') then
                        rd_data_bram_mux(0) <= rd_data_bram(to_integer(unsigned(rd_chan_a_reg(log2(MEM_ARRAYS) + log2(CHANS_PER_ARRAY) -1 downto log2(CHANS_PER_ARRAY)))))(i);
                        RD_DATA_VLD_A       <= '1';
                    end if;
                end loop;
            end process;
        end generate;

        rd_barrel_shifter_g : if (READ_BARREL_SHIFTER_EN(0)) generate
            rd_data_barrel_shifter_i : entity work.BARREL_SHIFTER_GEN
            generic map (
                BLOCKS     => MFB_BYTES,
                -- The Reading side is addressable by bytes so the number of blocks is 4 times more than on the
                -- reading side
                BLOCK_SIZE => 8,
                SHIFT_LEFT => FALSE
            )
            port map (
                DATA_IN  => rd_data_bram_mux(0),
                DATA_OUT => RD_DATA_A,
                SEL      => rd_addr_a_reg(log2(MFB_BYTES) - 1 downto 0)
            );

            rd_addr_recalc_g : for rgn in 0 to (MFB_REGIONS -1) generate
                rd_addr_recalc_p : process (all) is
                    variable chan_addr_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
                begin
                    chan_addr_v                := RD_CHAN_A(log2(CHANS_PER_ARRAY) -1 downto 0);
                    rd_addr_bram_by_shift(rgn) <= (others => (chan_addr_v & RD_ADDR_A(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES))));

                    for i in 0 to ((MFB_LENGTH/8) -1) loop
                        if (i < unsigned(RD_ADDR_A(log2(MFB_BYTES) - 1 downto 0))) then
                            rd_addr_bram_by_shift(rgn)(i) <= chan_addr_v & std_logic_vector(unsigned(RD_ADDR_A(log2(BUFFER_DEPTH) + log2(MFB_BYTES) -1 downto log2(MFB_BYTES))) + 1);
                        end if;
                    end loop;
                end process;
            end generate;
        else generate
            RD_DATA_A <= rd_data_bram_mux(0);

            rd_addr_recalc_p : process (all) is
                variable chan_addr_v : std_logic_vector(log2(CHANS_PER_ARRAY) -1 downto 0);
            begin
                chan_addr_v           := RD_CHAN_A(log2(CHANS_PER_ARRAY) -1 downto 0);
                rd_addr_bram_by_shift <= (others => (others => (chan_addr_v & RD_ADDR_A(log2(BUFFER_DEPTH)+log2(MFB_BYTES) -1 downto log2(MFB_BYTES)))));
            end process;
        end generate;
    end generate;
end architecture;
