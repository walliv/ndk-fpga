-- nvme_cmd_dispatcher.vhd: dispatcher of NVMe commands on the MFB bus
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;
use work.nvme_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity NVME_CMD_DISPATCHER is
    generic(
        -- The amount of sectors in the SQ/Read buffer of the C2N Controller
        CHANNELS        : natural := 2;
        -- number of regions in a data word
        MFB_REGIONS     : natural := 2;
        -- number of blocks in a region
        MFB_REGION_SIZE : natural := 1;
        -- number of items in a block
        MFB_BLOCK_SIZE  : natural := 8;
        -- number of bits in an item
        MFB_ITEM_WIDTH  : natural := 32;
        -- FPGA device string
        DEVICE          : string  := "ULTRASCALE";
        -- The size of a pointer to the transaction buffer with SQ/Read buffer
        BUFF_PTR_WIDTH : positive := 17;
        -- Amount of tags/Command Identifiers available for outstanding NVMe commands
        QUEUE_DEPTH    : positive := 2048
        );
    port(
        CLK     : in std_logic;
        RST     : in std_logic;
        RST_PTR : in std_logic;

        -- =========================================================================================
        -- Control signals
        --
        -- log. 0 only one transaction is generated and the generator stays in IDLE after its
        -- dispatch
        -- log. 1 genreate transactions continuously

        -- This signals work as handshaking mechanism and when TRIGG_DISP is asserted, the data
        -- in PCIe transaction attributes and SQ command attributes must not change until
        -- RDY_FOR_DISP is asserted too.
        -- =========================================================================================
        TRIGG_DISP      : in  std_logic;
        RDY_FOR_DISP    : out std_logic;
        DBL_MASK        : in  std_logic_vector(15 downto 0);

        -- =========================================================================================
        -- SQ command attributes
        -- =========================================================================================
        CMD_OPCODE     : in std_logic_vector(CMD_OPCODE_W -1 downto 0);
        NAMESPACE_ID   : in std_logic_vector(31 downto 0);
        METADATA_PTR   : in std_logic_vector(63 downto 0);
        PRP_ENTRY_1    : in std_logic_vector(63 downto 0);
        PRP_ENTRY_2    : in std_logic_vector(63 downto 0);
        -- Start pointer of the LBA required to be read/written to.
        START_LBA_PTR  : in std_logic_vector(63 downto 0);
        -- Mask of the LBA pointer (determines a size of the SSD)
        LBA_SPACE_SIZE : in std_logic_vector(63 downto 0);
        -- The amount of LBAs that will be read consecutively.
        LBA_NUM        : in std_logic_vector(15 downto 0);
        -- Top value of the maximum amount of LBAs that can be requested in one command
        LBA_NUM_MASK   : in std_logic_vector(15 downto 0);

        -- =========================================================================================
        -- Status IO
        -- =========================================================================================
        SQE_DISP_CNTR_TYPE : out std_logic_vector(CMD_OPCODE_W -1 downto 0);
        SQE_DISP_CNTR_SIZE : out std_logic_vector(24 downto 0);
        SQE_DISP_CNTR_INCR : out std_logic;

        TAG_FIFO_STATUS    : out std_logic_vector(11 downto 0);
        -- Set to 1 if tags used as Command Identifiers have been asserted
        TAG_INIT_DONE      : out std_logic;
        SQTDBL_VAL         : out std_logic_vector(15 downto 0);

        -- Command Identifier assigned to the command being dispatched, valid when DISP_CMD_ID_VLD
        -- is asserted
        DISP_CMD_ID        : out std_logic_vector(15 downto 0);
        DISP_CMD_ID_VLD    : out std_logic;

        -- =========================================================================================
        -- Update of the SQTBL pointer and return of a tag
        -- =========================================================================================
        CPL_STAT_TAG    : in std_logic_vector(15 downto 0);
        CPL_STAT_SQHDBL : in std_logic_vector(15 downto 0);
        CPL_STAT_VLD    : in std_logic;

        -- =========================================================================================
        -- Output MFB bus for Submission Commands
        -- =========================================================================================
        SQ_CMD_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        SQ_CMD_MFB_META    : out std_logic_vector(MFB_REGIONS*((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 + log2(CHANNELS) + BUFF_PTR_WIDTH)-1 downto 0);
        SQ_CMD_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        SQ_CMD_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        SQ_CMD_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        SQ_CMD_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        SQ_CMD_MFB_SRC_RDY : out std_logic;
        SQ_CMD_MFB_DST_RDY : in  std_logic);

end entity;

architecture FULL of NVME_CMD_DISPATCHER is
    constant IS_INTEL         : boolean                                := (DEVICE = "STRATIX10") or (DEVICE = "AGILEX");
    -- Size of the submission queue entry in bytes
    constant SQ_ENTRY_W       : positive                               := 64;
    constant SQ_ADDR_OFFS_VEC : unsigned(log2(SQ_ENTRY_W) -1 downto 0) := (others => '0');

    -- =============================================================================================
    -- Output metadata signal fields
    -- =============================================================================================
    constant META_PCIE_ADDR_W : natural := BUFF_PTR_WIDTH;
    constant META_CHAN_NUM_W   : natural := log2(CHANNELS);
    constant META_BE_W        : natural := (MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8;

    constant META_PCIE_ADDR_O : natural := 0;
    constant META_CHAN_NUM_O  : natural := META_PCIE_ADDR_O + META_PCIE_ADDR_W;
    constant META_BE_O        : natural := META_CHAN_NUM_O + META_CHAN_NUM_W;

    subtype META_PCIE_ADDR is natural range META_PCIE_ADDR_O + META_PCIE_ADDR_W -1 downto META_PCIE_ADDR_O;
    subtype META_CHAN_NUM  is natural range META_CHAN_NUM_O + META_CHAN_NUM_W -1 downto META_CHAN_NUM_O;
    subtype META_BE        is natural range META_BE_O + META_BE_W -1 downto META_BE_O;

    constant MFB_META_REDUCED_WIDTH_INT : natural := META_BE_O + META_BE_W;
    constant MFB_BE_VLD : std_logic_vector(META_BE_W -1 downto 0) := (others => '1');

    -- =============================================================================================
    -- Generated SQ command entry as well as PCI headers for it and for the doorbell update
    -- =============================================================================================
    signal tag_fifo_init_done : std_logic;
    signal cmd_id             : std_logic_vector(15 downto 0);
    signal cmd_id_src_rdy     : std_logic;
    signal cmd_id_dst_rdy     : std_logic;

    signal sq_cmd_entry                 : std_logic_vector(511 downto 0);
    signal sq_addr_w_offset             : unsigned(BUFF_PTR_WIDTH -1 downto 0);

    signal sqhdbl_reg      : unsigned(CPL_STAT_SQHDBL'range);
    signal sqtdbl_reg      : unsigned(15 downto 0);
    signal sqtdbl_next_val : unsigned(15 downto 0);
    signal sq_cmd_mfb_meta_arr : slv_array_t(MFB_REGIONS -1 downto 0)(MFB_META_REDUCED_WIDTH_INT -1 downto 0);

    signal lba_num_capped : std_logic_vector(15 downto 0);
begin
    -- I have absolutely no idea why I have put this assertion here initially...
    -- assert (16 + log2(SQ_ENTRY_W) <= BUFF_PTR_WIDTH)
    --     report "NVME_CMD_DISPATCHER: SQ pointer oversized"
    --     severity FAILURE;

    assert (MFB_REGIONS = 1 and MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 64 and MFB_ITEM_WIDTH = 8)
        report "NVME_CMD_DISPATCHER: Wrong MFB configuration, the only allowed is (1,1,64,8)"
        severity FAILURE;

    -- NOTE: The assumption that this component should always accept the incoming tag without a
    -- backpressure, can be a source of error.
    tag_manager_i : entity work.IUVENTUS_CMD_TAG_MANAGER
        generic map (
            DEVICE      => DEVICE,
            QUEUE_DEPTH => QUEUE_DEPTH
            )
        port map (
            CLK   => CLK,
            RESET => RST,

            INIT_DONE => tag_fifo_init_done,

            TAG_IN_DATA    => CPL_STAT_TAG,
            TAG_IN_SRC_RDY => CPL_STAT_VLD,

            TAG_OUT_DATA    => cmd_id,
            TAG_OUT_SRC_RDY => cmd_id_src_rdy,
            TAG_OUT_DST_RDY => cmd_id_dst_rdy,

            TAG_FIFO_STATUS => TAG_FIFO_STATUS
            );

    TAG_INIT_DONE <= tag_fifo_init_done;

    DISP_CMD_ID     <= cmd_id;
    DISP_CMD_ID_VLD <= cmd_id_dst_rdy;

    -- =============================================================================================
    -- Dispatching logic with command generation
    -- =============================================================================================
    sqhdbl_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or RST_PTR = '1') then
                sqhdbl_reg <= (others => '0');
            elsif (CPL_STAT_VLD = '1') then
                sqhdbl_reg <= unsigned(CPL_STAT_SQHDBL);
            end if;
        end if;
    end process;

    nvme_cmd_composer_i : entity work.NVME_CMD_COMPOSER
        port map (
            CMD_ID        => cmd_id,
            CMD_OPCODE    => CMD_OPCODE,
            NAMESPACE_ID  => NAMESPACE_ID,
            METADATA_PTR  => METADATA_PTR,
            PRP_ENTRY_1   => PRP_ENTRY_1,
            PRP_ENTRY_2   => PRP_ENTRY_2,
            START_LBA_PTR => START_LBA_PTR,
            LBA_NUM       => lba_num_capped,
            SQ_CMD_ENTRY  => sq_cmd_entry);

    -- In case of reaching the LBA space boundary, the amount of requested LBAs within a command is
    -- capped.
    -- NOTE: Maybe this is not an issue and the NVMe allows that where it sends the LBAs from the
    -- beginning of a space. However, this is not certain and errors can occur.
    lba_num_cap_p: process (all) is
        variable max_lba_num : unsigned(63 downto 0);
    begin
        lba_num_capped <= (others => '0');

        if (unsigned(START_LBA_PTR) < unsigned(LBA_SPACE_SIZE)) then
            max_lba_num := unsigned(LBA_SPACE_SIZE) - unsigned(START_LBA_PTR);

            if (unsigned(LBA_NUM) <= max_lba_num) then
                lba_num_capped <= LBA_NUM and LBA_NUM_MASK;
            else
                lba_num_capped <= std_logic_vector(resize(max_lba_num, LBA_NUM'length)) and LBA_NUM_MASK;
            end if;
        end if;
    end process;

    -- Add masked doorbell pointer to the the SQ base address
    sq_addr_w_offset <= resize(sqtdbl_reg & SQ_ADDR_OFFS_VEC, BUFF_PTR_WIDTH);

    sqtdbl_cntr_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1' or RST_PTR = '1') then
                sqtdbl_reg <= (others => '0');
            else
                sqtdbl_reg <= sqtdbl_next_val;
            end if;
        end if;
    end process;

    disp_fsm_out_logic_p : process (all) is
    begin
        SQ_CMD_MFB_SRC_RDY     <= '0';

        sqtdbl_next_val    <= sqtdbl_reg;
        SQE_DISP_CNTR_INCR <= '0';
        RDY_FOR_DISP <= '0';
        cmd_id_dst_rdy     <= '0';

        if (
            -- The Submission Queue has not be full
            (((sqtdbl_reg + 1) and unsigned(DBL_MASK)) /= sqhdbl_reg)
            -- All the tags in the TAG Manager have to be initialized
            and tag_fifo_init_done = '1'
            -- There have to be some tags present in the FIFO
            and cmd_id_src_rdy = '1'
            )then

            RDY_FOR_DISP <= SQ_CMD_MFB_DST_RDY;
            SQ_CMD_MFB_SRC_RDY <= TRIGG_DISP;

            -- The core is ready for dispatch if it is in the S_DISPATCH_WORD1 state and the Submisiison queue is not
            -- full (i.e. the SQTDBL is one position before SQHDBL)
            if (TRIGG_DISP = '1' and SQ_CMD_MFB_DST_RDY = '1') then
                SQE_DISP_CNTR_INCR <= '1';
                sqtdbl_next_val    <= (sqtdbl_reg + 1) and unsigned(DBL_MASK);
                cmd_id_dst_rdy     <= '1';
            end if;
        end if;
    end process;

    -- Size of the dispatched command in bytes
    SQE_DISP_CNTR_TYPE <= CMD_OPCODE;
    SQE_DISP_CNTR_SIZE <= std_logic_vector(unsigned(lba_num_capped)+1) & "000000000";

    sq_cmd_mfb_meta_arr_g: for rgn_idx in (MFB_REGIONS -1) downto 0 generate
        sq_cmd_mfb_meta_arr(rgn_idx)(META_PCIE_ADDR)   <= std_logic_vector(sq_addr_w_offset);
        -- The buffer is flat-addressed (MEM_PARTITIONING => FALSE): the channel bit is a
        -- don't-care, the address alone (SQ at flat page 0) locates the datum.
        sq_cmd_mfb_meta_arr(rgn_idx)(META_CHAN_NUM_O)  <= '0';
        sq_cmd_mfb_meta_arr(rgn_idx)(META_BE)          <= MFB_BE_VLD and SQ_CMD_MFB_SRC_RDY;
    end generate;

    SQ_CMD_MFB_DATA <= sq_cmd_entry;
    SQ_CMD_MFB_META <= slv_array_ser(sq_cmd_mfb_meta_arr);
    SQ_CMD_MFB_SOF <= "1";
    SQ_CMD_MFB_EOF <= "1";
    SQ_CMD_MFB_SOF_POS <= (others => '0');
    SQ_CMD_MFB_EOF_POS <= "111111";

    SQTDBL_VAL  <= std_logic_vector(sqtdbl_reg + 1 and unsigned(DBL_MASK));
end architecture;
