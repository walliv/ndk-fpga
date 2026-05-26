-- nvme_cc_hdr_insertor.vhd:
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;

entity NVME_CC_HDR_INSERTOR is
    generic (
        -- =========================================================================================
        -- RX MFB configuration
        --
        -- Number of regions is always 1
        -- =========================================================================================
        RX_REGION_SIZE : natural := 1;
        RX_BLOCK_SIZE  : natural := 128;
        RX_ITEM_WIDTH  : natural := 8;

        -- =========================================================================================
        -- TX MFB configuration
        -- =========================================================================================
        TX_REGIONS     : natural := 2;
        TX_REGION_SIZE : natural := 1;
        TX_BLOCK_SIZE  : natural := 8;
        TX_ITEM_WIDTH  : natural := 32;

        DEVICE : string := "ULTRASCALE"
        );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- =========================================================================================
        -- MFB input interface
        --
        -- EOF_POS is not used because. when the input word ends (signalized by EOF), whole word is
        -- valid. The SOF_POS is not used either because the input words are aligned to the
        -- beginning of the word.
        -- =========================================================================================
        RX_MFB_DATA    : in  std_logic_vector(RX_REGION_SIZE*RX_BLOCK_SIZE*RX_ITEM_WIDTH-1 downto 0);
        RX_MFB_SOF     : in  std_logic;
        RX_MFB_EOF     : in  std_logic;
        RX_MFB_EOF_POS : in  std_logic_vector(log2(RX_REGION_SIZE*RX_BLOCK_SIZE) -1 downto 0);
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- MFB output interface
        -- =========================================================================================
        TX_MFB_DATA    : out std_logic_vector(TX_REGIONS*TX_REGION_SIZE*TX_BLOCK_SIZE*TX_ITEM_WIDTH-1 downto 0);
        -- RQ PCIe header
        TX_MFB_META    : out std_logic_vector(TX_REGIONS*PCIE_CC_META_WIDTH - 1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(TX_REGIONS-1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(TX_REGIONS-1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(TX_REGIONS*max(1, log2(TX_REGION_SIZE))-1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(TX_REGIONS*max(1, log2(TX_REGION_SIZE*TX_BLOCK_SIZE))-1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Header manager MVB interface
        -- =========================================================================================
        -- log. 0 means header is 3 DW long
        -- log. 1 means header is 4 DW long
        PCIE_HDR         : in  std_logic_vector(95 downto 0);
        PCIE_HDR_SRC_RDY : in  std_logic;
        PCIE_HDR_DST_RDY : out std_logic);
end entity;

architecture FULL of NVME_CC_HDR_INSERTOR is
    -- On Intel devices, the PCIe header is sent in a TX_MFB_META bus separated from the data on the
    -- TX_MFB_DATA.
    constant IS_INTEL : boolean := (DEVICE = "STRATIX10") or (DEVICE = "AGILEX");

    signal bshifter_data_out  : std_logic_vector(RX_MFB_DATA'range);
    -- normally the lenght of these signals is set to address each group of 4 blocks on the bus but I made the
    -- signals one bit wider because I use them as a counter of output words in each transaction
    signal high_shift_val_pst : unsigned(log2(32)-4 downto 0);
    signal high_shift_val_nst : unsigned(log2(32)-4 downto 0);

    type tran_process_state_type is (IDLE, TRANSACTION_SEND);
    signal tprocess_pst : tran_process_state_type := IDLE;
    signal tprocess_nst : tran_process_state_type := IDLE;

    signal tx_mfb_meta_arr : slv_array_t(TX_REGIONS-1 downto 0)(PCIE_CC_META_WIDTH-1 downto 0);

    -- varies its value according to the generic parameters
    signal SHIFT_INC     : unsigned(1 downto 0);
    signal INIT_SHIFT    : unsigned(1 downto 0);
    signal LOW_SHIFT_VAL : std_logic_vector(2 downto 0);
begin
    assert (RX_REGION_SIZE = 1 and RX_BLOCK_SIZE = 128 and RX_ITEM_WIDTH = 8)
        report "NVME_CC_HDR_INSERTOR: The design is not prepared for such RX MFB configuration, the valid are: MFB#(_,1,128,8)"
        severity FAILURE;

    assert (TX_REGIONS = 2 and TX_REGION_SIZE = 1 and TX_BLOCK_SIZE = 8 and TX_ITEM_WIDTH = 32)
        report "NVME_CC_HDR_INSERTOR: The design is not prepared for such TX MFB configuration, the valid are: MFB#(2,1,8,32)."
        severity FAILURE;

    --=============================================================================================================
    -- FSM state register
    --=============================================================================================================
    -- We still need shift data even though it's intel
    tprocess_pst_reg_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                tprocess_pst <= IDLE;
                if (IS_INTEL = FALSE) then
                    high_shift_val_pst <= "11";
                else
                    high_shift_val_pst <= "00";
                end if;

            elsif (TX_MFB_DST_RDY = '1') then
                tprocess_pst       <= tprocess_nst;
                high_shift_val_pst <= high_shift_val_nst;
            end if;
        end if;
    end process;

    --=============================================================================================================
    -- FSM next state logic
    --=============================================================================================================
    tprocess_nst_logic_p : process (all) is
    begin
        tprocess_nst <= tprocess_pst;

        case tprocess_pst is
            when IDLE =>
                if (RX_MFB_SRC_RDY = '1') then
                    if (PCIE_HDR_SRC_RDY = '1'
                        -- All of the data on the input fit to one word on the output
                        and not (
                            (IS_INTEL and RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS) <= 63)
                            or (RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS)           <= 51)
                            )) then
                        tprocess_nst <= TRANSACTION_SEND;
                    end if;
                end if;

            when TRANSACTION_SEND =>
                if (IS_INTEL = FALSE) then
                    -- Go back to the initial state as long as either the data on the input has been
                    -- already dispatched or the data fit to two words based on the RX_MFB_EOF_POS
                    if (high_shift_val_pst = "11" or (RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS) <= 115)) then
                        tprocess_nst <= IDLE;
                    end if;
                else
                    -- Intel just transports 2 words since the PCIe header is send on a separate bus
                    tprocess_nst <= IDLE;
                end if;
        end case;
    end process;

    --=============================================================================================================
    -- FSM process which controls the input RX MFB and Header Manager signals
    --=============================================================================================================
    tshift_logic_p : process (all) is
    begin
        RX_MFB_DST_RDY   <= '0';
        PCIE_HDR_DST_RDY <= '0';

        case tprocess_pst is
            when IDLE =>
                -- when valid word arrives deassert the RX_DST_RDY signal because the FSM awaits the arrival of
                -- the PCIE header, no need to wait for the MFB_SOF signal the RX_DST_RDY signal is sufficient
                if (RX_MFB_SRC_RDY = '1') then
                    RX_MFB_DST_RDY <= '0';
                end if;

                -- if PCIE header has been captured, then deassert the PCIE_HDR_DST_RDY signal because we need to
                -- wait for a valid packet to arrive. This packet should also be the one which will not be
                -- dropped. (PCIE  headers on the input are always valid)
                if (PCIE_HDR_SRC_RDY = '1') then
                    PCIE_HDR_DST_RDY <= '0';
                end if;

                if (RX_MFB_SRC_RDY = '1'
                    and PCIE_HDR_SRC_RDY = '1'
                    -- All of the data on the input fit to one word on the output
                    and (
                        (IS_INTEL and RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS) <= 63)
                        or (RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS)           <= 51)
                        )) then

                    RX_MFB_DST_RDY   <= TX_MFB_DST_RDY;
                    PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;
                end if;

            when TRANSACTION_SEND =>

                if (IS_INTEL = FALSE) then
                    if (high_shift_val_pst = "11" or (RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS) <= 115)) then
                        RX_MFB_DST_RDY   <= TX_MFB_DST_RDY;
                        PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;
                    end if;
                else
                    PCIE_HDR_DST_RDY <= TX_MFB_DST_RDY;
                    RX_MFB_DST_RDY   <= TX_MFB_DST_RDY;
                end if;
        end case;
    end process;
    --=============================================================================================================

    --=============================================================================================================
    -- FSM process which controls the output MFB signals and their logic
    --=============================================================================================================
    tout_logic_p : process (all) is
        variable tx_mfb_eof_pos_per_reg : std_logic_vector(TX_MFB_EOF_POS'length/TX_REGIONS -1 downto 0);
    begin
        TX_MFB_DATA    <= bshifter_data_out(TX_MFB_DATA'high downto 0);
        TX_MFB_SOF     <= (others => '0');
        TX_MFB_EOF     <= (others => '0');
        TX_MFB_EOF_POS <= (others => '0');
        TX_MFB_SOF_POS <= (others => '0');
        TX_MFB_SRC_RDY <= '0';

        high_shift_val_nst <= high_shift_val_pst;

        -- Since the inptut RX_MFB_EOF_POS points to individual bytes, we need to
        -- choose these bits from it that point to DWords
        tx_mfb_eof_pos_per_reg := std_logic_vector(unsigned(RX_MFB_EOF_POS(log2(TX_BLOCK_SIZE) + log2(TX_ITEM_WIDTH/8) -1 downto log2(TX_ITEM_WIDTH/8))) + 3);

        case tprocess_pst is
            when IDLE =>
                -- valid data on the input
                if (RX_MFB_SRC_RDY = '1' and PCIE_HDR_SRC_RDY = '1') then

                    -- Place the PCIe header at the beginning of the data (AMD only)
                    -- For Intel, the header is placed in Meta signal and is valid with SOF
                    if (IS_INTEL = FALSE) then
                        TX_MFB_DATA        <= bshifter_data_out(TX_MFB_DATA'high downto 96) & PCIE_HDR(95 downto 0);

                        if (RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS) <= 51) then
                            -- THe word ends in the first region including the PCIe header
                            if (unsigned(RX_MFB_EOF_POS) <= 19) then
                                TX_MFB_EOF <= "01";
                            else
                                TX_MFB_EOF <= "10";
                            end if;

                            -- Since the inptut RX_MFB_EOF_POS points to individual bytes, we need to
                            -- choose these bits from it that point to DWords. Additionally, the end
                            -- is shifted by the size of the added PCIe header.
                            TX_MFB_EOF_POS <= tx_mfb_eof_pos_per_reg & tx_mfb_eof_pos_per_reg;
                        else
                            high_shift_val_nst <= INIT_SHIFT;
                        end if;
                    else
                        TX_MFB_DATA        <= bshifter_data_out(TX_MFB_DATA'high downto 0);

                        if (RX_MFB_EOF = '1' and unsigned(RX_MFB_EOF_POS) <= 63) then
                            -- THe word ends in the first region
                            if (unsigned(RX_MFB_EOF_POS) <= 31) then
                                TX_MFB_EOF <= "01";
                            else
                                TX_MFB_EOF <= "10";
                            end if;

                            tx_mfb_eof_pos_per_reg := std_logic_vector(unsigned(RX_MFB_EOF_POS(log2(TX_BLOCK_SIZE) + log2(TX_ITEM_WIDTH/8) -1 downto log2(TX_ITEM_WIDTH/8))));
                            TX_MFB_EOF_POS <= tx_mfb_eof_pos_per_reg & tx_mfb_eof_pos_per_reg;
                        else
                            high_shift_val_nst <= high_shift_val_pst + SHIFT_INC;
                        end if;
                    end if;

                    TX_MFB_SOF     <= "01";
                    TX_MFB_SRC_RDY <= '1';
                end if;

            when TRANSACTION_SEND =>
                high_shift_val_nst <= high_shift_val_pst + SHIFT_INC;

                if (IS_INTEL = FALSE) then
                    -- The incoming packet does not end yet but the full segment should be disptached.
                    if (RX_MFB_EOF = '0' and high_shift_val_pst = "11") then
                        high_shift_val_nst <= high_shift_val_pst;
                        -- Ends in the first region, DWord number 2
                        TX_MFB_EOF     <= "01";
                        TX_MFB_EOF_POS <= "000010";
                    elsif (RX_MFB_EOF = '1') then
                        TX_MFB_EOF_POS <= tx_mfb_eof_pos_per_reg & tx_mfb_eof_pos_per_reg;

                        -- The segment fits in just two output words, ends in the first region
                        if (unsigned(RX_MFB_EOF_POS) > 51 and unsigned(RX_MFB_EOF_POS) <= 83) then
                            TX_MFB_EOF     <= "01";
                        elsif (unsigned(RX_MFB_EOF_POS) > 83 and unsigned(RX_MFB_EOF_POS) <= 115) then
                            TX_MFB_EOF     <= "10";
                        elsif (unsigned(RX_MFB_EOF_POS) > 115 and high_shift_val_pst = "11") then
                            high_shift_val_nst <= high_shift_val_pst;
                            TX_MFB_EOF     <= "01";
                        end if;
                    end if;
                else
                    -- The incoming packet does not end yet but the full segment should be
                    -- disptached. The Intel devices do not need to observe the shift since the the
                    -- second word will already dispatch the rest of a segment.
                    if (RX_MFB_EOF = '0') then
                        -- Ends in the first region, DWord number 2
                        TX_MFB_EOF     <= "10";
                        TX_MFB_EOF_POS <= "111000";
                    elsif (RX_MFB_EOF = '1') then
                        tx_mfb_eof_pos_per_reg := std_logic_vector(unsigned(RX_MFB_EOF_POS(log2(TX_BLOCK_SIZE) + log2(TX_ITEM_WIDTH/8) -1 downto log2(TX_ITEM_WIDTH/8))));
                        TX_MFB_EOF_POS <= tx_mfb_eof_pos_per_reg & tx_mfb_eof_pos_per_reg;

                        -- The segment fits in just two output words, ends in the first region
                        if (unsigned(RX_MFB_EOF_POS) > 63 and unsigned(RX_MFB_EOF_POS) <= 95) then
                            TX_MFB_EOF     <= "01";
                        else
                            TX_MFB_EOF     <= "10";
                        end if;
                    end if;
                end if;

                TX_MFB_SRC_RDY <= '1';
        end case;
    end process;

    --=============================================================================================================
    -- Shifter of the output data
    --=============================================================================================================
    INIT_SHIFT <= "01";
    -- increment by two, the barrel shifter remains the same for both of the configurations so the
    -- shifting by two is needed
    SHIFT_INC  <= "10";

    input_data_shifter_i : entity work.BARREL_SHIFTER_GEN
        generic map (
            -- 32 DWs and each has 32b
            BLOCKS     => 32,
            BLOCK_SIZE => 32,
            SHIFT_LEFT => FALSE)
        port map (
            DATA_IN  => RX_MFB_DATA,
            DATA_OUT => bshifter_data_out,
            SEL      => std_logic_vector(high_shift_val_pst) & LOW_SHIFT_VAL);

    intel_lowbits : if (IS_INTEL = FALSE) generate
        LOW_SHIFT_VAL <= "101";
        -- The CC MFB Meta signal does not contain any metadata for AMD devices
        tx_mfb_meta_arr <= (others => (others => '0'));
    else generate
        LOW_SHIFT_VAL <= (others => '0');

        tx_mfb_meta_g : for i in 0 to TX_REGIONS-1 generate
            process (all) is
            begin
                -- In intel devices the PCIe header is sent in separate signal.
                tx_mfb_meta_arr(i)                      <= (others => '0');
                tx_mfb_meta_arr(i)(PCIE_CC_META_HEADER) <= PCIE_HDR;
            end process;
        end generate;
    end generate;

    TX_MFB_META <= slv_array_ser(tx_mfb_meta_arr);
end architecture;
