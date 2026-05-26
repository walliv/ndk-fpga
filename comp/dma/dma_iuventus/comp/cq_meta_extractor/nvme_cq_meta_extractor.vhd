-- nvme_cq_meta_extractor.vhd: performs initial processing of packets comming to the NVMe engine
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
use work.pcie_hdr_fields_pkg.all;
use work.iuventus_bar_map_pkg.all;

entity NVME_CQ_META_EXTRACTOR is
    generic (
        -- Only "ULTRASCALE is allowed for now"
        DEVICE          : string  := "ULTRASCALE";
        -- Configuration of the input and output MFB interface
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;

        -- The amount of bits from the PCIE address that are used to address the data in the
        -- transaction buffer
        POINTER_WIDTH : natural := 17
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- PCIe MFB interface
        -- =========================================================================================
        PCIE_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        -- More information about the content of this port can be found in *pcie_meta_pack*
        PCIE_MFB_META    : in  std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH -1 downto 0);
        PCIE_MFB_SOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_EOF     : in  std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        PCIE_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        PCIE_MFB_SRC_RDY : in  std_logic;
        PCIE_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- PCIe metadata for Reading from the buffers
        -- =========================================================================================
        MVB_DATA_BAR_ID   : out slv_array_t(MFB_REGIONS -1 downto 0)(2 downto 0);
        MVB_DATA_ADDR     : out slv_array_t(MFB_REGIONS -1 downto 0)(63 downto 0);
        MVB_DATA_CQ_HDR   : out slv_array_t(MFB_REGIONS -1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);
        MVB_DATA_BYTE_CNT : out slv_array_t(MFB_REGIONS -1 downto 0)(12 downto 0);
        MVB_VLD           : out std_logic_vector(MFB_REGIONS -1 downto 0);
        MVB_SRC_RDY       : out std_logic;
        MVB_DST_RDY       : in  std_logic;

        -- =========================================================================================
        -- PCIe requests counter (for every BAR)
        -- =========================================================================================
        PCIE_RD_REQ_INCRS : out slv_array_t(3 downto 0)(MFB_REGIONS -1 downto 0);
        PCIE_RD_REQ_BYTES : out slv_array_t(3 downto 0)(A_CQ_HDR_BYTE_CNT_W downto 0);
        PCIE_WR_REQ_INCRS : out slv_array_t(3 downto 0)(MFB_REGIONS -1 downto 0);
        PCIE_WR_REQ_BYTES : out slv_array_t(3 downto 0)(A_CQ_HDR_BYTE_CNT_W -1 downto 0);

        PCIE_RD_REQ_TOTAL_INCR  : out std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_RD_REQ_TOTAL_BYTES : out std_logic_vector(A_CQ_HDR_BYTE_CNT_W downto 0);
        PCIE_WR_REQ_TOTAL_INCR  : out std_logic_vector(MFB_REGIONS -1 downto 0);
        PCIE_WR_REQ_TOTAL_BYTES : out std_logic_vector(A_CQ_HDR_BYTE_CNT_W -1 downto 0);

        -- =========================================================================================
        -- User MFB signals

        -- Metadata are all valid with SOF except for USR_MFB_META_BYTE_EN.
        -- =========================================================================================
        USR_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        USR_MFB_META    : out slv_array_t(MFB_REGIONS -1 downto 0)(((MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH)/8 + 3 + 64) -1 downto 0);
        USR_MFB_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        USR_MFB_EOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        USR_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        USR_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        USR_MFB_SRC_RDY : out std_logic;
        USR_MFB_DST_RDY : in  std_logic);
end entity;

architecture FULL of NVME_CQ_META_EXTRACTOR is

    constant MFB_LENGTH         : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    constant BAR_APERTURE_INTEL : natural := 26;

    package iuventus_mfb_meta_pkg_i is new work.iuventus_mfb_meta_pkg
    generic map (
        MFB_REGION_SIZE => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH);

    use iuventus_mfb_meta_pkg_i.all;

    -- =============================================================================================
    -- Internal Signals
    -- =============================================================================================
    -- the extracted pcie header
    signal pcie_hdr_data_int : slv_array_t(MFB_REGIONS - 1 downto 0)(PCIE_META_REQ_HDR_W -1 downto 0);

    -- Input port arrays
    signal pcie_mfb_data_arr : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
    signal pcie_mfb_meta_arr : slv_array_t(MFB_REGIONS - 1 downto 0)(PCIE_CQ_META_WIDTH -1 downto 0);

    -- extracted fields from the PCIe header
    signal pcie_hdr_addr         : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
    signal pcie_hdr_bar_aperture : slv_array_t(MFB_REGIONS - 1 downto 0)(5 downto 0);
    signal pcie_hdr_dw_cnt       : slv_array_t(MFB_REGIONS - 1 downto 0)(10 downto 0);
    signal pcie_hdr_byte_cnt     : slv_array_t(MFB_REGIONS - 1 downto 0)(12 downto 0);
    signal pcie_hdr_bar_id       : slv_array_t(MFB_REGIONS - 1 downto 0)(2 downto 0);
    signal pcie_hdr_req_type     : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);
    signal pcie_is_read_req      : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal pcie_is_write_req     : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal pcie_hdr_fbe          : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);
    signal pcie_hdr_lbe          : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);

    signal pcie_addr_mask   : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
    signal pcie_addr_masked : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
    signal byte_shift       : slv_array_t(MFB_REGIONS - 1 downto 0)(1 downto 0);

    -- Store the value of BAR ID across muliple words of each transaction (normally, the BAR ID is
    -- only transported with the start of a transaction)
    signal bar_id_int    : slv_array_t(MFB_REGIONS -1 downto 0)(META_BAR_ID_W -1 downto 0);
    signal bar_id_stored : slv_array_t(MFB_REGIONS -1 downto 0)(META_BAR_ID_W -1 downto 0);

    -- decoded FBE and LBE signals with continuous rows of 1s
    signal fbe_decoded : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);
    signal lbe_decoded : slv_array_t(MFB_REGIONS - 1 downto 0)(3 downto 0);

    -- contains the last byte enable, first byte enable signals from the PCIE META input, the size
    -- of a current PCIE transaction in bytes and one bit indication if DMA header is included in a
    -- current transaction
    signal pcie_mfb_meta_int : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_META_WIDTH_INT -1 downto 0);

    signal drop_rx_src_rdy : std_logic;
    signal drop_rx_dst_rdy : std_logic;

    signal drop_enable       : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal drop_mfb_data    : std_logic_vector(MFB_LENGTH -1 downto 0);
    signal drop_mfb_meta    : std_logic_vector(MFB_REGIONS*MFB_META_WIDTH_INT -1 downto 0);
    signal drop_mfb_sof     : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal drop_mfb_eof     : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal drop_mfb_sof_pos : std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
    signal drop_mfb_eof_pos : std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
    signal drop_mfb_src_rdy : std_logic;
    signal drop_mfb_dst_rdy : std_logic;

    signal cutt_mfb_data    : std_logic_vector(MFB_LENGTH -1 downto 0);
    signal cutt_mfb_meta    : std_logic_vector(MFB_REGIONS*MFB_META_WIDTH_INT -1 downto 0);
    signal cutt_mfb_sof     : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal cutt_mfb_eof     : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal cutt_mfb_sof_pos : std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
    signal cutt_mfb_eof_pos : std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
    signal cutt_mfb_src_rdy : std_logic;
    signal cutt_mfb_dst_rdy : std_logic;

    signal aux_mfb_data        : std_logic_vector(MFB_LENGTH -1 downto 0);
    signal aux_mfb_meta        : std_logic_vector(MFB_REGIONS*MFB_META_WIDTH_INT - 1 downto 0);
    signal aux_mfb_meta_arr    : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_META_WIDTH_INT - 1 downto 0);
    signal aux_mfb_sof         : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal aux_mfb_eof         : std_logic_vector(MFB_REGIONS -1 downto 0);
    signal aux_mfb_sof_pos     : std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
    signal aux_mfb_eof_pos     : std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
    signal aux_mfb_eof_pos_arr : slv_array_t(MFB_REGIONS - 1 downto 0)(max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
    signal aux_mfb_src_rdy     : std_logic;
    signal aux_mfb_dst_rdy     : std_logic;

    -- reduced meta signal that does not contain FBE and LBE items
    signal aux_mfb_meta_arr_reduced : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_META_REDUCED_WIDTH_INT -1 downto 0);

    signal usr_mfb_lbe_reg : std_logic_vector(META_LBE_W -1 downto 0);
    signal usr_mfb_lbe_sel : std_logic_vector(META_LBE_W -1 downto 0);

    -- indicates which items in a current word are valid
    signal mfb_aux_item_vld_int     : std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE -1 downto 0);
    signal mfb_aux_item_vld_int_arr : slv_array_t(MFB_REGIONS - 1 downto 0)(MFB_REGION_SIZE*MFB_BLOCK_SIZE -1 downto 0);

    -- byte enable for a whole word
    signal mfb_aux_item_be : slv_array_2d_t(MFB_REGIONS - 1 downto 0)(MFB_REGION_SIZE*MFB_BLOCK_SIZE -1 downto 0)(MFB_ITEM_WIDTH/8 -1 downto 0);
begin

    assert (MFB_REGIONS = 2 and MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 8 and MFB_ITEM_WIDTH = 32)
        report "NVME_CQ_META_EXTRACTOR: Only configuration with MFB_REGIONS=2, MFB_REGION_SIZE=1, MFB_BLOCK_SIZE=8 and MFB_ITEM_WIDTH=32 is supported!"
        severity FAILURE;

    assert (MFB_META_REDUCED_WIDTH_INT = USR_MFB_META(0)'length)
        report "NVME_CQ_META_EXTRACTOR: MFB_META_REDUCED_WIDTH_INT does not match USR_MFB_META width!"
        severity FAILURE;

    -- =============================================================================================
    -- Deserialize input data
    --
    -- NOTE: pcie_hdr_addr_len is not used but it does not make sense anyway since the BAR aperture
    -- is never greater than 32 bits. The top 32 bits are always 0.
    -- =============================================================================================
    pcie_mfb_data_arr <= slv_array_deser(PCIE_MFB_DATA, MFB_REGIONS);
    pcie_mfb_meta_arr <= slv_array_deser(PCIE_MFB_META, MFB_REGIONS);

    pcie_hdr_deparser_g : for i in (MFB_REGIONS - 1) downto 0 generate
        device_sel_pcie_hdr_g : if (DEVICE = "ULTRASCALE") generate
            pcie_hdr_data_int(i) <= pcie_mfb_data_arr(i)(PCIE_CQ_META_HEADER);
        else generate
            pcie_hdr_data_int(i) <= pcie_mfb_meta_arr(i)(PCIE_CQ_META_HEADER);
        end generate;

        pcie_hdr_deparser_i : entity work.PCIE_CQ_HDR_DEPARSER
            generic map (
                DEVICE => DEVICE)
            port map (
                OUT_TAG          => open,
                OUT_ADDRESS      => pcie_hdr_addr(i),
                OUT_REQ_ID       => open,
                OUT_TC           => open,
                OUT_DW_CNT       => pcie_hdr_dw_cnt(i),
                OUT_ATTRIBUTES   => open,
                OUT_FBE          => pcie_hdr_fbe(i),
                OUT_LBE          => pcie_hdr_lbe(i),
                OUT_ADDRESS_TYPE => open,
                OUT_TARGET_FUNC  => open,
                -- NOTE: THe intel devices need to extract the BAR_ID and transport it separately
                -- since it is not present in the PCIe header.
                OUT_BAR_ID       => pcie_hdr_bar_id(i),
                OUT_BAR_APERTURE => pcie_hdr_bar_aperture(i),
                OUT_ADDR_LEN     => open,
                OUT_REQ_TYPE     => pcie_hdr_req_type(i),

                IN_HEADER => pcie_hdr_data_int(i),
                IN_FBE    => pcie_mfb_meta_arr(i)(PCIE_CQ_META_FBE),
                IN_LBE    => pcie_mfb_meta_arr(i)(PCIE_CQ_META_LBE),

                IN_INTEL_META => std_logic_vector(to_unsigned(BAR_APERTURE_INTEL, 6)) & pcie_mfb_meta_arr(i)(PCIE_CQ_META_BAR) & (8 - 1 downto 0 => '0'));

        -- =============================================================================================
        -- creates mask for pcie addr based on the BAR APERTURE value in the PCIE header
        -- =============================================================================================
        addr_mask_gen_p : process (all)
            variable mask_var : slv_array_t(MFB_REGIONS - 1 downto 0)(63 downto 0);
        begin
            mask_var(i) := (others => '0');
            for j in 0 to 63 loop
                if (j < unsigned(pcie_hdr_bar_aperture(i))) then
                    mask_var(i)(j) := '1';
                end if;
            end loop;
            pcie_addr_mask(i) <= mask_var(i);
        end process;

        -- Determins a byte shift that is going to be added to the address
        byte_shift_add_p : process (all) is
        begin
            byte_shift(i) <= "00";

            if (std_match(pcie_hdr_fbe(i), "---1")) then
                byte_shift(i) <= "00";
            elsif (std_match(pcie_hdr_fbe(i), "--10")) then
                byte_shift(i) <= "01";
            elsif (std_match(pcie_hdr_fbe(i), "-100")) then
                byte_shift(i) <= "10";
            elsif (std_match(pcie_hdr_fbe(i), "1000")) then
                byte_shift(i) <= "11";
            end if;
        end process;

        pcie_addr_masked(i) <= (pcie_hdr_addr(i)(63 downto 2) & byte_shift(i)) and pcie_addr_mask(i);

        byte_en_decoder_i : entity work.PCIE_BYTE_EN_DECODER
            port map (
                FBE_IN  => pcie_hdr_fbe(i),
                LBE_IN  => pcie_hdr_lbe(i),
                FBE_OUT => fbe_decoded(i),
                LBE_OUT => lbe_decoded(i));

        pcie_trans_byte_cnt_i : entity work.PCIE_BYTE_COUNT
            generic map (
                OUTPUT_REG => FALSE)
            port map (
                CLK   => CLK,
                RESET => RESET,

                IN_DW_COUNT => pcie_hdr_dw_cnt(i),
                IN_FIRST_BE => pcie_hdr_fbe(i),
                IN_LAST_BE  => pcie_hdr_lbe(i),

                OUT_FIRST_IB   => open,
                OUT_LAST_IB    => open,
                OUT_BYTE_COUNT => pcie_hdr_byte_cnt(i));

        -- =========================================================================================
        -- Assign to internal metadata signal
        -- =========================================================================================
        pcie_mfb_meta_int(i) <=
            lbe_decoded(i) &
            fbe_decoded(i) &
            bar_id_int(i) &
            pcie_addr_masked(i);

        pcie_is_write_req(i) <= '1' when pcie_hdr_req_type(i) = "0010" else '0';
        pcie_is_read_req(i)  <= '1' when pcie_hdr_req_type(i) = "0001" else '0';
        -- No need to cut out PCIe transactions containing Read Request PCIe header since this
        -- transaction only contains the header. Also drop every transaction that heads to BAR 0
        -- since for this, only a header is needed.
        drop_enable(i)  <= '1' when pcie_is_read_req(i) = '1'
                            or pcie_hdr_bar_id(i) = SQ_BAR_ID
                            or pcie_hdr_bar_id(i) = RDBUFF_BAR_ID 
                            else '0';

        MVB_DATA_BAR_ID(i)   <= pcie_hdr_bar_id(i);
        MVB_DATA_ADDR(i)     <= pcie_addr_masked(i);
        MVB_DATA_CQ_HDR(i)   <= pcie_hdr_data_int(i);
        MVB_DATA_BYTE_CNT(i) <= pcie_hdr_byte_cnt(i);
        MVB_VLD(i)           <= PCIE_MFB_SOF(i) and pcie_is_read_req(i);
    end generate;

    stat_cntr_total_logic_p: process (CLK) is
        variable v_sel0_rd, v_sel1_rd : boolean;
        variable v_sel0_wr, v_sel1_wr : boolean;
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                PCIE_RD_REQ_TOTAL_INCR  <= (others => '0');
                PCIE_WR_REQ_TOTAL_INCR  <= (others => '0');
            else
                PCIE_RD_REQ_TOTAL_INCR <= (others => '0');
                PCIE_WR_REQ_TOTAL_INCR <= (others => '0');

                if (PCIE_MFB_SRC_RDY = '1' and PCIE_MFB_DST_RDY = '1') then

                    v_sel0_rd := (PCIE_MFB_SOF(0) = '1' and  pcie_is_read_req(0)= '1');
                    v_sel1_rd := (PCIE_MFB_SOF(1) = '1' and  pcie_is_read_req(1)= '1');
                    
                    v_sel0_wr := (PCIE_MFB_SOF(0) = '1' and  pcie_is_write_req(0)= '1');
                    v_sel1_wr := (PCIE_MFB_SOF(1) = '1' and  pcie_is_write_req(1)= '1');

                    -- Handle Read Increments
                    if v_sel0_rd and v_sel1_rd then
                        PCIE_RD_REQ_TOTAL_BYTES <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W+1) + unsigned(pcie_hdr_byte_cnt(1)));
                        PCIE_RD_REQ_TOTAL_INCR <= "10";
                    elsif v_sel0_rd then
                        PCIE_RD_REQ_TOTAL_BYTES <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W+1));
                        PCIE_RD_REQ_TOTAL_INCR <= "01";
                    elsif v_sel1_rd then
                        PCIE_RD_REQ_TOTAL_BYTES <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(1)), A_CQ_HDR_BYTE_CNT_W+1));
                        PCIE_RD_REQ_TOTAL_INCR <= "01";
                    end if;

                    -- Handle Write Increments
                    if v_sel0_wr and v_sel1_wr then
                        PCIE_WR_REQ_TOTAL_BYTES <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W) + unsigned(pcie_hdr_byte_cnt(1)));
                        PCIE_WR_REQ_TOTAL_INCR <= "10";
                    elsif v_sel0_wr then
                        PCIE_WR_REQ_TOTAL_BYTES <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W));
                        PCIE_WR_REQ_TOTAL_INCR <= "01";
                    elsif v_sel1_wr then
                        PCIE_WR_REQ_TOTAL_BYTES <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(1)), A_CQ_HDR_BYTE_CNT_W));
                        PCIE_WR_REQ_TOTAL_INCR <= "01";
                    end if;
                end if;
            end if;
        end if;
    end process;

    stat_cntr_per_bar_logic_g: for bar_idx in 0 to 3 generate
        stat_cntr_logic_p: process (CLK) is
            variable v_sel0_rd, v_sel1_rd : boolean;
            variable v_sel0_wr, v_sel1_wr : boolean;
        begin
            if (rising_edge(CLK)) then
                if (RESET = '1') then
                    PCIE_RD_REQ_INCRS(bar_idx) <= (others => '0');
                    PCIE_WR_REQ_INCRS(bar_idx) <= (others => '0');
                else
                    PCIE_RD_REQ_INCRS(bar_idx) <= (others => '0');
                    PCIE_WR_REQ_INCRS(bar_idx) <= (others => '0');

                    if (PCIE_MFB_SRC_RDY = '1' and PCIE_MFB_DST_RDY = '1') then

                        v_sel0_rd := (PCIE_MFB_SOF(0) = '1' and unsigned(pcie_hdr_bar_id(0)) = bar_idx and  pcie_is_read_req(0)= '1');
                        v_sel1_rd := (PCIE_MFB_SOF(1) = '1' and unsigned(pcie_hdr_bar_id(1)) = bar_idx and  pcie_is_read_req(1)= '1');
                        
                        v_sel0_wr := (PCIE_MFB_SOF(0) = '1' and unsigned(pcie_hdr_bar_id(0)) = bar_idx and  pcie_is_write_req(0)= '1');
                        v_sel1_wr := (PCIE_MFB_SOF(1) = '1' and unsigned(pcie_hdr_bar_id(1)) = bar_idx and  pcie_is_write_req(1)= '1');

                        -- Handle Read Increments
                        if v_sel0_rd and v_sel1_rd then
                            PCIE_RD_REQ_BYTES(bar_idx) <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W+1) + unsigned(pcie_hdr_byte_cnt(1)));
                            PCIE_RD_REQ_INCRS(bar_idx) <= "10";
                        elsif v_sel0_rd then
                            PCIE_RD_REQ_BYTES(bar_idx) <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W+1));
                            PCIE_RD_REQ_INCRS(bar_idx) <= "01";
                        elsif v_sel1_rd then
                            PCIE_RD_REQ_BYTES(bar_idx) <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(1)), A_CQ_HDR_BYTE_CNT_W+1));
                            PCIE_RD_REQ_INCRS(bar_idx) <= "01";
                        end if;

                        -- Handle Write Increments
                        if v_sel0_wr and v_sel1_wr then
                            PCIE_WR_REQ_BYTES(bar_idx) <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W) + unsigned(pcie_hdr_byte_cnt(1)));
                            PCIE_WR_REQ_INCRS(bar_idx) <= "10";
                        elsif v_sel0_wr then
                            PCIE_WR_REQ_BYTES(bar_idx) <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(0)), A_CQ_HDR_BYTE_CNT_W));
                            PCIE_WR_REQ_INCRS(bar_idx) <= "01";
                        elsif v_sel1_wr then
                            PCIE_WR_REQ_BYTES(bar_idx) <= std_logic_vector(resize(unsigned(pcie_hdr_byte_cnt(1)), A_CQ_HDR_BYTE_CNT_W));
                            PCIE_WR_REQ_INCRS(bar_idx) <= "01";
                        end if;
                    end if;
                end if;
            end if;
        end process;
    end generate;

    MVB_SRC_RDY      <= (or MVB_VLD) and drop_rx_dst_rdy and PCIE_MFB_SRC_RDY;
    drop_rx_src_rdy  <= PCIE_MFB_SRC_RDY and MVB_DST_RDY;
    PCIE_MFB_DST_RDY <= drop_rx_dst_rdy and MVB_DST_RDY;

    -- select only the part of the address which indexes DMA channels
    bar_id_extract_p : process (all) is
    begin
        bar_id_int <= bar_id_stored;

        if (PCIE_MFB_SRC_RDY = '1') then
            if (PCIE_MFB_SOF = "11") then
                bar_id_int(0) <= pcie_hdr_bar_id(0);
                bar_id_int(1) <= pcie_hdr_bar_id(1);

            elsif (PCIE_MFB_SOF = "01") then
                bar_id_int(0) <= pcie_hdr_bar_id(0);
                bar_id_int(1) <= pcie_hdr_bar_id(0);

            elsif (PCIE_MFB_SOF = "10") then
                bar_id_int(1) <= pcie_hdr_bar_id(1);
            end if;
        end if;
    end process;

    -- purpose: store the number of channel for the duration of the whole packet
    channel_store_reg_p: process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (PCIE_MFB_SRC_RDY = '1') then
                if (PCIE_MFB_SOF = "11") then
                    bar_id_stored(0) <= pcie_hdr_bar_id(1);
                    bar_id_stored(1) <= pcie_hdr_bar_id(1);

                elsif (PCIE_MFB_SOF = "01") then
                    bar_id_stored(0) <= pcie_hdr_bar_id(0);
                    bar_id_stored(1) <= pcie_hdr_bar_id(0);

                elsif (PCIE_MFB_SOF = "10") then
                    bar_id_stored(0) <= pcie_hdr_bar_id(1);
                    bar_id_stored(1) <= pcie_hdr_bar_id(1);
                end if;
            end if;
        end if;
    end process;

    pcie_mfb_dropper_i : entity work.MFB_DROPPER
        generic map (
            REGIONS     => MFB_REGIONS,
            REGION_SIZE => MFB_REGION_SIZE,
            BLOCK_SIZE  => MFB_BLOCK_SIZE,
            ITEM_WIDTH  => MFB_ITEM_WIDTH,
            META_WIDTH  => MFB_META_WIDTH_INT)
        port map (
            CLK   => CLK,
            RESET => RESET,

            RX_DROP => drop_enable,

            RX_DATA    => PCIE_MFB_DATA,
            RX_META    => slv_array_ser(pcie_mfb_meta_int),
            RX_SOF_POS => PCIE_MFB_SOF_POS,
            RX_EOF_POS => PCIE_MFB_EOF_POS,
            RX_SOF     => PCIE_MFB_SOF,
            RX_EOF     => PCIE_MFB_EOF,
            RX_SRC_RDY => drop_rx_src_rdy,
            RX_DST_RDY => drop_rx_dst_rdy,

            TX_DATA    => drop_mfb_data,
            TX_META    => drop_mfb_meta,
            TX_SOF_POS => drop_mfb_sof_pos,
            TX_EOF_POS => drop_mfb_eof_pos,
            TX_SOF     => drop_mfb_sof,
            TX_EOF     => drop_mfb_eof,
            TX_SRC_RDY => drop_mfb_src_rdy,
            TX_DST_RDY => drop_mfb_dst_rdy);

    -- Cutter is used only for Xilinx devices
    pcie_hdr_cutter_g : if (DEVICE = "ULTRASCALE" or DEVICE = "7SERIES") generate
        pcie_hdr_cutter_i : entity work.MFB_CUTTER_SIMPLE
            generic map (
                REGIONS        => MFB_REGIONS,
                REGION_SIZE    => MFB_REGION_SIZE,
                BLOCK_SIZE     => MFB_BLOCK_SIZE,
                ITEM_WIDTH     => MFB_ITEM_WIDTH,
                META_WIDTH     => MFB_META_WIDTH_INT,
                META_ALIGNMENT => 0,
                -- 4 because the PCIe header is 4 DW long
                CUTTED_ITEMS   => 4
                )
            port map (
                CLK   => CLK,
                RESET => RESET,

                RX_CUT => drop_mfb_sof,

                RX_DATA    => drop_mfb_data,
                RX_META    => drop_mfb_meta,
                RX_SOF     => drop_mfb_sof,
                RX_EOF     => drop_mfb_eof,
                RX_SOF_POS => drop_mfb_sof_pos,
                RX_EOF_POS => drop_mfb_eof_pos,
                RX_SRC_RDY => drop_mfb_src_rdy,
                RX_DST_RDY => drop_mfb_dst_rdy,

                TX_DATA    => cutt_mfb_data,
                TX_META    => cutt_mfb_meta,
                TX_SOF     => cutt_mfb_sof,
                TX_EOF     => cutt_mfb_eof,
                TX_SOF_POS => cutt_mfb_sof_pos,
                TX_EOF_POS => cutt_mfb_eof_pos,
                TX_SRC_RDY => cutt_mfb_src_rdy,
                TX_DST_RDY => cutt_mfb_dst_rdy);
    else generate
        -- Just connecting the signals
        cutt_mfb_data       <= PCIE_MFB_DATA;
        cutt_mfb_meta       <= slv_array_ser(pcie_mfb_meta_int);
        cutt_mfb_sof        <= PCIE_MFB_SOF;
        cutt_mfb_eof        <= PCIE_MFB_EOF;
        cutt_mfb_sof_pos    <= PCIE_MFB_SOF_POS;
        cutt_mfb_eof_pos    <= PCIE_MFB_EOF_POS;
        cutt_mfb_src_rdy    <= PCIE_MFB_SRC_RDY;
        PCIE_MFB_DST_RDY    <= cutt_mfb_dst_rdy;
    end generate;

    mfb_auxiliary_signals_i : entity work.MFB_AUXILIARY_SIGNALS
        generic map (
            REGIONS       => MFB_REGIONS,
            REGION_SIZE   => MFB_REGION_SIZE,
            BLOCK_SIZE    => MFB_BLOCK_SIZE,
            ITEM_WIDTH    => MFB_ITEM_WIDTH,
            META_WIDTH    => MFB_META_WIDTH_INT,
            REGION_AUX_EN => FALSE,
            BLOCK_AUX_EN  => FALSE,
            ITEM_AUX_EN   => TRUE
        )
        port map (
            CLK   => CLK,
            RESET => RESET,

            RX_DATA    => cutt_mfb_data,
            RX_META    => cutt_mfb_meta,
            RX_SOF_POS => cutt_mfb_sof_pos,
            RX_EOF_POS => cutt_mfb_eof_pos,
            RX_SOF     => cutt_mfb_sof,
            RX_EOF     => cutt_mfb_eof,
            RX_SRC_RDY => cutt_mfb_src_rdy,
            RX_DST_RDY => cutt_mfb_dst_rdy,

            TX_DATA    => aux_mfb_data,
            TX_META    => aux_mfb_meta,
            TX_SOF_POS => aux_mfb_sof_pos,
            TX_EOF_POS => aux_mfb_eof_pos,
            TX_SOF     => aux_mfb_sof,
            TX_EOF     => aux_mfb_eof,
            TX_SRC_RDY => aux_mfb_src_rdy,
            TX_DST_RDY => aux_mfb_dst_rdy,

            TX_REGION_SHARED => open,
            TX_REGION_VLD    => open,
            TX_BLOCK_VLD     => open,
            TX_ITEM_VLD      => mfb_aux_item_vld_int);

    -- This quasi state machine stores the LBE value till the end of a packet
    aux_mfb_meta_arr    <= slv_array_deser(aux_mfb_meta, MFB_REGIONS);
    lbe_reg_p: process(CLK) is
    begin
        if rising_edge(CLK) then
            if (RESET = '1') then
                usr_mfb_lbe_reg <= (others => '0');
            else
                -- Higher takes
                for i in 0 to MFB_REGIONS - 1 loop
                    if (aux_mfb_src_rdy = '1' and aux_mfb_sof(i) = '1' and aux_mfb_eof(i) = '0') then
                        usr_mfb_lbe_reg <= aux_mfb_meta_arr(i)(META_LBE);
                    end if;
                end  loop;
            end if;
        end if;
    end process;

    -- Select process
    lbe_sel_p: process(all)
    begin
        if aux_mfb_sof(0) = '1' then
            usr_mfb_lbe_sel <= aux_mfb_meta_arr(0)(META_LBE);
        else
            usr_mfb_lbe_sel <= usr_mfb_lbe_reg;
        end if;
    end process;

    -- this process creates a byte enable for a whole MFB word
    mfb_aux_item_vld_int_arr    <= slv_array_deser(mfb_aux_item_vld_int, MFB_REGIONS);
    aux_mfb_eof_pos_arr         <= slv_array_deser(aux_mfb_eof_pos, MFB_REGIONS);
    be_fill_p : process (all) is
    begin
        -- default assignment is to simply copy the validity value of the current item
        mfb_aux_item_be <= (others => (others => (others => '0')));

        if (aux_mfb_src_rdy = '1') then
            for reg_idx in 0 to MFB_REGIONS - 1 loop
                for item_idx in 0 to (MFB_REGION_SIZE*MFB_BLOCK_SIZE -1) loop
                    mfb_aux_item_be(reg_idx)(item_idx) <= (others => mfb_aux_item_vld_int_arr(reg_idx)(item_idx));
                end loop;
            end loop;

            -- apply FBE to the BE vector
            for reg_idx in 0 to MFB_REGIONS - 1 loop
                if (aux_mfb_sof(reg_idx) = '1') then
                    mfb_aux_item_be(reg_idx)(0) <= aux_mfb_meta_arr(reg_idx)(META_FBE);
                end if;

                -- apply LBE to the BE vector
                if (aux_mfb_eof(reg_idx) = '1' and aux_mfb_sof(reg_idx) = '0') then
                    mfb_aux_item_be(reg_idx)(to_integer(unsigned(aux_mfb_eof_pos_arr(reg_idx)))) <= usr_mfb_lbe_sel;
                elsif (aux_mfb_eof(reg_idx) = '1' and aux_mfb_sof(reg_idx) = '1' and unsigned(aux_mfb_eof_pos_arr(reg_idx)) > 0) then
                    mfb_aux_item_be(reg_idx)(to_integer(unsigned(aux_mfb_eof_pos_arr(reg_idx)))) <= aux_mfb_meta_arr(reg_idx)(META_LBE);
                end if;
            end loop;
        end if;
    end process;

    ser_usr_mfb_meta_g: for i in MFB_REGIONS-1 downto 0 generate
        aux_mfb_meta_arr_reduced(i)(META_BAR_ID_O + META_BAR_ID_W -1 downto 0) <= aux_mfb_meta_arr(i)(META_BAR_ID_O + META_BAR_ID_W -1 downto 0);
        aux_mfb_meta_arr_reduced(i)(META_BE_O + META_BE_W -1 downto META_BE_O) <= slv_array_ser(mfb_aux_item_be(i));
    end generate;

    USR_MFB_DATA    <= aux_mfb_data;
    USR_MFB_META    <= aux_mfb_meta_arr_reduced;
    USR_MFB_SOF     <= aux_mfb_sof;
    USR_MFB_EOF     <= aux_mfb_eof;
    USR_MFB_SOF_POS <= aux_mfb_sof_pos;
    USR_MFB_EOF_POS <= aux_mfb_eof_pos;
    USR_MFB_SRC_RDY <= aux_mfb_src_rdy;
    aux_mfb_dst_rdy <= USR_MFB_DST_RDY;
end architecture;
