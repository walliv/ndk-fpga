-- nvme_cmd_dispatcher_mi32.vhd: dispatcher of NVMe commands triggered by MI
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:
--
use work.type_pack.all;
use work.math_pack.all;
use work.pcie_meta_pack.all;

entity NVME_CMD_DISPATCHER_MI32 is
    generic(
        -- number of regions in a data word
        MFB_REGIONS     : natural := 2;
        -- number of blocks in a region
        MFB_REGION_SIZE : natural := 1;
        -- number of items in a block
        MFB_BLOCK_SIZE  : natural := 8;
        -- number of bits in an item
        MFB_ITEM_WIDTH  : natural := 32;
        -- The MI is driven by the same clock as the MFB bus
        MI_SAME_CLK     : boolean := FALSE;
        -- Width of the MI bus
        MI_WIDTH        : natural := 32;
        -- FPGA device string
        DEVICE          : string  := "ULTRASCALE"
        );
    port(
        CLK : in std_logic;
        RST : in std_logic;

        -- MI32 interface
        MI_CLK : in std_logic;
        MI_RST : in std_logic;

        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_ARDY : out std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DRDY : out std_logic;

        SQHDBL_DATA : in std_logic_vector(15 downto 0);
        SQHDBL_VLD  : in std_logic;

        TX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        TX_MFB_META    : out std_logic_vector(MFB_REGIONS*PCIE_RQ_META_WIDTH-1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic);
end entity;

architecture FULL of NVME_CMD_DISPATCHER_MI32 is

    constant ADDR_LENGTH : positive := 7;
    constant CNTR_LENGTH : positive := 64;

    signal core_rst      : std_logic;
    signal iops_cntr_rst : std_logic;

    signal rd_en_reg        : std_logic;
    signal trigg_dispatch   : std_logic;
    signal rdy_for_dispatch : std_logic;
    signal iops_cntr_reg    : std_logic_vector(CNTR_LENGTH-1 downto 0);

    signal ctrl_reg_sel                  : std_logic;
    signal sqtdbl_init_val_reg_sel       : std_logic;
    signal sq_base_addr_low_reg_sel      : std_logic;
    signal sq_base_addr_high_reg_sel     : std_logic;
    signal sqtdbl_base_addr_low_reg_sel  : std_logic;
    signal sqtdbl_base_addr_high_reg_sel : std_logic;
    signal prp_entry1_low_reg_sel        : std_logic;
    signal prp_entry1_high_reg_sel       : std_logic;
    signal prp_entry2_low_reg_sel        : std_logic;
    signal prp_entry2_high_reg_sel       : std_logic;
    signal start_lba_ptr_reg_sel         : std_logic;
    signal lba_num_reg_sel               : std_logic;
    signal sqtdbl_mask_reg_sel           : std_logic;
    signal iops_cntr_sample_reg_sel      : std_logic;

    signal sqtdbl_init_val_reg       : std_logic_vector(15 downto 0);
    signal sq_base_addr_low_reg      : std_logic_vector(MI_DWR'range);
    signal sq_base_addr_high_reg     : std_logic_vector(MI_DWR'range);
    signal sqtdbl_base_addr_low_reg  : std_logic_vector(MI_DWR'range);
    signal sqtdbl_base_addr_high_reg : std_logic_vector(MI_DWR'range);
    signal prp_entry1_low_reg        : std_logic_vector(MI_DWR'range);
    signal prp_entry1_high_reg       : std_logic_vector(MI_DWR'range);
    signal prp_entry2_low_reg        : std_logic_vector(MI_DWR'range);
    signal prp_entry2_high_reg       : std_logic_vector(MI_DWR'range);
    signal start_lba_ptr_reg         : std_logic_vector(MI_DWR'range);
    signal lba_num_reg               : std_logic_vector(15 downto 0);
    signal sqtdbl_val_reg            : std_logic_vector(15 downto 0);
    signal sqtdbl_mask_reg           : std_logic_vector(15 downto 0);
    signal iops_cntr_sample_reg      : std_logic_vector(CNTR_LENGTH-1 downto 0);

    signal mi_sync_dwr  : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_sync_addr : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_sync_rd   : std_logic;
    signal mi_sync_wr   : std_logic;
    signal mi_sync_drd  : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_sync_ardy : std_logic;
    signal mi_sync_drdy : std_logic;
begin
    mi_async_g : if (not MI_SAME_CLK) generate
        mi_async_i : entity work.MI_ASYNC
            generic map(
                ADDR_WIDTH  => MI_WIDTH,
                DATA_WIDTH  => MI_WIDTH,
                META_WIDTH  => 0,
                RAM_TYPE    => "LUT",
                RESET_LOGIC => TRUE,
                DEVICE      => DEVICE
                )
            port map(
                CLK_M     => MI_CLK,
                RESET_M   => MI_RST,
                MI_M_ADDR => MI_ADDR,
                MI_M_DWR  => MI_DWR,
                MI_M_MWR  => (others => '0'),
                MI_M_BE   => (others => '1'),
                MI_M_RD   => MI_RD,
                MI_M_WR   => MI_WR,
                MI_M_ARDY => MI_ARDY,
                MI_M_DRDY => MI_DRDY,
                MI_M_DRD  => MI_DRD,

                CLK_S     => CLK,
                RESET_S   => RST,
                MI_S_ADDR => mi_sync_addr,
                MI_S_DWR  => mi_sync_dwr,
                MI_S_MWR  => open,
                MI_S_BE   => open,
                MI_S_RD   => mi_sync_rd,
                MI_S_WR   => mi_sync_wr,
                MI_S_ARDY => mi_sync_ardy,
                MI_S_DRDY => mi_sync_drdy,
                MI_S_DRD  => mi_sync_drd);
    else generate
        mi_sync_addr <= MI_ADDR;
        mi_sync_dwr  <= MI_DWR;
        mi_sync_rd   <= MI_RD;
        mi_sync_wr   <= MI_WR;
        MI_ARDY      <= mi_sync_ardy;
        MI_DRDY      <= mi_sync_drdy;
        MI_DRD       <= mi_sync_drd;
    end generate;

    nvme_cmd_dispatcher_i : entity work.NVME_CMD_DISPATCHER
        generic map (
            MFB_REGIONS     => MFB_REGIONS,
            MFB_REGION_SIZE => MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
            DEVICE          => DEVICE)
        port map (
            CLK      => CLK,
            RST      => RST or core_rst,
            CNTR_RST => iops_cntr_rst,

            SQ_BASE_ADDR       => sq_base_addr_high_reg & sq_base_addr_low_reg,
            SQTDBL_BASE_ADDR   => sqtdbl_base_addr_high_reg & sqtdbl_base_addr_low_reg,
            SQTDBL_INIT_VAL    => sqtdbl_init_val_reg,
            SQTDBL_VAL         => sqtdbl_val_reg,
            SQTDBL_MASK        => sqtdbl_mask_reg,
            -- Trigger only when there is no reset happening
            TRIGG_DISPATCH     => trigg_dispatch,
            READY_FOR_DISPATCH => rdy_for_dispatch,

            RD_EN         => rd_en_reg,
            NAMESPACE_ID  => x"00000001",
            METADATA_PTR  => (others => '0'),
            PRP_ENTRY_1   => prp_entry1_high_reg & prp_entry1_low_reg,
            PRP_ENTRY_2   => prp_entry2_high_reg & prp_entry2_low_reg,
            START_LBA_PTR => x"00000000" & start_lba_ptr_reg,
            LBA_NUM       => lba_num_reg,

            IOPS_CNTR_REG => iops_cntr_reg,
            SQHDBL_DATA   => SQHDBL_DATA,
            SQHDBL_VLD    => SQHDBL_VLD,

            TX_MFB_DATA    => TX_MFB_DATA,
            TX_MFB_META    => TX_MFB_META,
            TX_MFB_SOF     => TX_MFB_SOF,
            TX_MFB_EOF     => TX_MFB_EOF,
            TX_MFB_SOF_POS => TX_MFB_SOF_POS,
            TX_MFB_EOF_POS => TX_MFB_EOF_POS,
            TX_MFB_SRC_RDY => TX_MFB_SRC_RDY,
            TX_MFB_DST_RDY => TX_MFB_DST_RDY);

    mi_sync_ardy <= mi_sync_rd or mi_sync_wr;

    -- select a register for write
    ctrl_reg_sel                  <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0000000") else '0';
    sqtdbl_init_val_reg_sel       <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0001000") else '0';
    sq_base_addr_low_reg_sel      <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0001100") else '0';
    sq_base_addr_high_reg_sel     <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0010000") else '0';
    sqtdbl_base_addr_low_reg_sel  <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0010100") else '0';
    sqtdbl_base_addr_high_reg_sel <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0011000") else '0';
    prp_entry1_low_reg_sel        <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0011100") else '0';
    prp_entry1_high_reg_sel       <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0100000") else '0';
    prp_entry2_low_reg_sel        <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0100100") else '0';
    prp_entry2_high_reg_sel       <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0101000") else '0';
    start_lba_ptr_reg_sel         <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0101100") else '0';
    lba_num_reg_sel               <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0110000") else '0';
    sqtdbl_mask_reg_sel           <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0111000") else '0';

    iops_cntr_sample_reg_sel <= '1' when (mi_sync_addr(ADDR_LENGTH -1 downto 0) = "0111100" or mi_sync_addr(ADDR_LENGTH -1 downto 0) = "1000000") else '0';

    -- ==================================================================
    -- transfering data to/from registers according to the select signals
    -- ==================================================================
    ctrl_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                rd_en_reg      <= '0';
                core_rst       <= '1';
                trigg_dispatch <= '0';
            else
                core_rst       <= '0';
                trigg_dispatch <= '0';

                if ((ctrl_reg_sel = '1') and (mi_sync_wr = '1')) then
                    rd_en_reg      <= mi_sync_dwr(0);
                    -- Trigger only when there is no reset happening
                    core_rst       <= mi_sync_dwr(1);
                    trigg_dispatch <= not mi_sync_dwr(1);
                end if;
            end if;
        end if;
    end process;

    -- TODO:
    -- 1. Probably reset registers when the reset of a core is requested
    -- 2. Prohibit command trigger when the core is busy - SOLVED: Command trigger is ignored

    sqtdbl_init_val_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sqtdbl_init_val_reg <= (others => '0');
            elsif ((sqtdbl_init_val_reg_sel = '1') and (mi_sync_wr = '1')) then
                sqtdbl_init_val_reg <= mi_sync_dwr(sqtdbl_init_val_reg'range);
            end if;
        end if;
    end process;

    sq_base_addr_low_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sq_base_addr_low_reg <= (others => '0');
            elsif ((sq_base_addr_low_reg_sel = '1') and (mi_sync_wr = '1')) then
                sq_base_addr_low_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    sq_base_addr_high_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sq_base_addr_high_reg <= (others => '0');
            elsif ((sq_base_addr_high_reg_sel = '1') and (mi_sync_wr = '1')) then
                sq_base_addr_high_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    sqtdbl_base_addr_low_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sqtdbl_base_addr_low_reg <= (others => '0');
            elsif ((sqtdbl_base_addr_low_reg_sel = '1') and (mi_sync_wr = '1')) then
                sqtdbl_base_addr_low_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    sqtdbl_base_addr_high_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sqtdbl_base_addr_high_reg <= (others => '0');
            elsif ((sqtdbl_base_addr_high_reg_sel = '1') and (mi_sync_wr = '1')) then
                sqtdbl_base_addr_high_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    prp_entry1_low_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                prp_entry1_low_reg <= (others => '0');
            elsif ((prp_entry1_low_reg_sel = '1') and (mi_sync_wr = '1')) then
                prp_entry1_low_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    prp_entry1_high_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                prp_entry1_high_reg <= (others => '0');
            elsif ((prp_entry1_high_reg_sel = '1') and (mi_sync_wr = '1')) then
                prp_entry1_high_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    prp_entry2_low_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                prp_entry2_low_reg <= (others => '0');
            elsif ((prp_entry2_low_reg_sel = '1') and (mi_sync_wr = '1')) then
                prp_entry2_low_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    prp_entry2_high_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                prp_entry2_high_reg <= (others => '0');
            elsif ((prp_entry2_high_reg_sel = '1') and (mi_sync_wr = '1')) then
                prp_entry2_high_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    start_lba_ptr_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                start_lba_ptr_reg <= (others => '0');
            elsif ((start_lba_ptr_reg_sel = '1') and (mi_sync_wr = '1')) then
                start_lba_ptr_reg <= mi_sync_dwr;
            end if;
        end if;
    end process;

    lba_num_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                lba_num_reg <= (others => '0');
            elsif ((lba_num_reg_sel = '1') and (mi_sync_wr = '1')) then
                lba_num_reg <= mi_sync_dwr(15 downto 0);
            end if;
        end if;
    end process;

    sqtdbl_mask_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                sqtdbl_mask_reg <= (others => '0');
            elsif ((sqtdbl_mask_reg_sel = '1') and (mi_sync_wr = '1')) then
                sqtdbl_mask_reg <= mi_sync_dwr(15 downto 0);
            end if;
        end if;
    end process;

    -- The counter needs to be sampled in order to read the correct value of it. This is because of
    -- the MI bus that is able to read only 32 bits at once.
    iops_cntr_sample_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                iops_cntr_rst        <= '0';
                iops_cntr_sample_reg <= (others => '0');
            else
                iops_cntr_rst <= '0';

                if ((iops_cntr_sample_reg_sel = '1') and (mi_sync_wr = '1')) then
                    iops_cntr_rst <= not mi_sync_dwr(0);

                    if (mi_sync_dwr(0) = '1' or mi_sync_dwr(1) = '1') then
                        iops_cntr_sample_reg <= iops_cntr_reg;
                    elsif (mi_sync_dwr(0) = '0' and mi_sync_dwr(1) = '0') then
                        iops_cntr_sample_reg <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process;

    read_from_regs_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            mi_sync_drd <= (others => '0');

            case (mi_sync_addr(ADDR_LENGTH -1 downto 0)) is
                when "0000000" => mi_sync_drd(0)           <= rd_en_reg;
                when "0000100" => mi_sync_drd(0)           <= rdy_for_dispatch;
                when "0001000" => mi_sync_drd(15 downto 0) <= sqtdbl_init_val_reg;
                when "0001100" => mi_sync_drd              <= sq_base_addr_low_reg;
                when "0010000" => mi_sync_drd              <= sq_base_addr_high_reg;
                when "0010100" => mi_sync_drd              <= sqtdbl_base_addr_low_reg;
                when "0011000" => mi_sync_drd              <= sqtdbl_base_addr_high_reg;
                when "0011100" => mi_sync_drd              <= prp_entry1_low_reg;
                when "0100000" => mi_sync_drd              <= prp_entry1_high_reg;
                when "0100100" => mi_sync_drd              <= prp_entry2_low_reg;
                when "0101000" => mi_sync_drd              <= prp_entry2_high_reg;
                when "0101100" => mi_sync_drd              <= start_lba_ptr_reg;
                when "0110000" => mi_sync_drd(15 downto 0) <= lba_num_reg;
                when "0110100" => mi_sync_drd(15 downto 0) <= sqtdbl_val_reg;
                when "0111000" => mi_sync_drd(15 downto 0) <= sqtdbl_mask_reg;
                when "0111100" => mi_sync_drd              <= iops_cntr_sample_reg(31 downto 0);
                when "1000000" => mi_sync_drd              <= iops_cntr_sample_reg(63 downto 32);
                when others    => mi_sync_drd              <= x"CAFEBABE";
            end case;
        end if;
    end process;

    drdy_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                mi_sync_drdy <= '0';
            else
                mi_sync_drdy <= mi_sync_rd;
            end if;
        end if;
    end process;
end architecture;
