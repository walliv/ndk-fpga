-- n2c_controller.vhd: The controller that contains components for NVME to Card communication (data
-- from read commands and CQ Entries)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.type_pack.all;
use work.math_pack.all;
use work.nvme_meta_pack.all;
use work.iuventus_bar_map_pkg.all;

entity N2C_CONTROLLER is
    generic (
        EXT_MFB_REGIONS     : natural  := 2;
        EXT_MFB_REGION_SIZE : natural  := 1;
        EXT_MFB_BLOCK_SIZE  : natural  := 8;
        EXT_MFB_ITEM_WIDTH  : natural  := 32;
        EXT_MFB_META_WIDTH  : natural  := 120;

        USR_MFB_REGIONS     : natural  := 1;
        USR_MFB_REGION_SIZE : natural  := 1;
        USR_MFB_BLOCK_SIZE  : natural  := 64;
        USR_MFB_ITEM_WIDTH  : natural  := 8;

        -- 32 as always
        MI_WIDTH        : positive := 32;
        -- The allowed is only "ULTRASCALE"
        DEVICE : string := "ULTRASCALE";
        -- The size of a pointer to a buffer of one channel in the buffer unit
        BUFF_PTR_WIDTH : positive := 17
    );

    port (
        CLK : in std_logic;
        RST : in std_logic;

        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_ARDY : out std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DRDY : out std_logic;

        -- =========================================================================================
        -- Control
        -- =========================================================================================
        CQP_START_REQ_VLD : in  std_logic;
        CQP_START_REQ_ACK : out std_logic;
        CQP_STOP_REQ_VLD  : in  std_logic;
        CQP_STOP_REQ_ACK  : out std_logic;
        DBL_MASK          : in std_logic_vector(15 downto 0);

        -- The requested data that should be read from the write buffer. One bit wider than
        -- BUFF_PTR_WIDTH: the buffer is flat-addressed (MEM_PARTITIONING => FALSE), so this
        -- address alone must reach the whole flat space (WRBUFF at pages 1+).
        BUFF_RD_REQ_ADDR : in std_logic_vector(BUFF_PTR_WIDTH downto 0);
        BUFF_RD_REQ_SIZE : in std_logic_vector(BUFF_PTR_WIDTH downto 0);
        BUFF_RD_REQ_LAST : in std_logic;
        BUFF_RD_REQ_EN   : in std_logic;
        BUFF_RD_REQ_ACK  : out std_logic;

        -- =========================================================================================
        -- Status signals
        -- =========================================================================================
        CQP_CQHDBL     : out std_logic_vector(15 downto 0);
        CQP_SQHDBL     : out std_logic_vector(15 downto 0);
        CQP_LAST_CQE   : out std_logic_vector(CQ_ENTRY_RANGE);
        CQP_STATUS_UPD : out std_logic;

        WRBUFF_USR_RDS_INCR      : out std_logic;
        WRBUFF_USR_RDS_BYTES     : out std_logic_vector(BUFF_PTR_WIDTH downto 0);

        -- =========================================================================================
        -- PCIe interface to receive data from Metadata Extractor that contain either CQ Entries or
        -- data that were requested by read command
        -- =========================================================================================
        EXT_MFB_DATA    : in  std_logic_vector(EXT_MFB_REGIONS*EXT_MFB_REGION_SIZE*EXT_MFB_BLOCK_SIZE*EXT_MFB_ITEM_WIDTH-1 downto 0);
        EXT_MFB_META    : in  slv_array_t(EXT_MFB_REGIONS -1 downto 0)(EXT_MFB_META_WIDTH-1 downto 0);
        EXT_MFB_SOF     : in  std_logic_vector(EXT_MFB_REGIONS-1 downto 0);
        EXT_MFB_EOF     : in  std_logic_vector(EXT_MFB_REGIONS-1 downto 0);
        EXT_MFB_SOF_POS : in  std_logic_vector(EXT_MFB_REGIONS*max(1, log2(EXT_MFB_REGION_SIZE))-1 downto 0);
        EXT_MFB_EOF_POS : in  std_logic_vector(EXT_MFB_REGIONS*log2(EXT_MFB_REGION_SIZE*EXT_MFB_BLOCK_SIZE)-1 downto 0);
        EXT_MFB_SRC_RDY : in  std_logic;
        EXT_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- Read interface
        -- =========================================================================================
        RD_RESP_MFB_DATA    : out std_logic_vector(USR_MFB_REGIONS*USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE*USR_MFB_ITEM_WIDTH-1 downto 0);
        RD_RESP_MFB_SOF     : out std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        RD_RESP_MFB_EOF     : out std_logic_vector(USR_MFB_REGIONS-1 downto 0);
        RD_RESP_MFB_SOF_POS : out std_logic_vector(USR_MFB_REGIONS*maximum(1, log2(USR_MFB_REGION_SIZE))-1 downto 0);
        RD_RESP_MFB_EOF_POS : out std_logic_vector(USR_MFB_REGIONS*log2(USR_MFB_REGION_SIZE*USR_MFB_BLOCK_SIZE)-1 downto 0);
        RD_RESP_MFB_SRC_RDY : out std_logic;
        RD_RESP_MFB_DST_RDY : in  std_logic);
end entity;

architecture FULL of N2C_CONTROLLER is
    package iuventus_mfb_meta_pkg_i is new work.iuventus_mfb_meta_pkg
    generic map (
        MFB_REGION_SIZE => EXT_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => EXT_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => EXT_MFB_ITEM_WIDTH);

    use iuventus_mfb_meta_pkg_i.all;

    -- nvc 1.21.0 workaround: driving variable-bounded signal slices from a process loop body
    -- crashes in sub-component context. Compute the entire concatenation inside a function
    -- (local variables, upref 0) and drive the whole output signal at once.
    function build_pcie_mfb_meta(
        ext_mfb_meta     : slv_array_t;
        i_meta_be_o       : natural;
        i_meta_be_w       : natural;
        i_meta_pcie_addr_o : natural;
        i_meta_pcie_addr_w : natural
    ) return std_logic_vector is
        constant N      : natural := ext_mfb_meta'length;
        constant ELEM_W : natural := i_meta_be_w + i_meta_pcie_addr_w;
        variable result : std_logic_vector(N*ELEM_W - 1 downto 0);
    begin
        for i in 0 to N-1 loop
            result((i+1)*ELEM_W-1 downto i*ELEM_W) :=
                ext_mfb_meta(i)(i_meta_be_o + i_meta_be_w - 1 downto i_meta_be_o) &
                -- The buffer is flat-addressed (MEM_PARTITIONING => FALSE): the write META
                -- channel bit is a don't-care, the address alone (CQ at flat page 0, WRBUFF at
                -- flat pages 1+) locates the datum.
                '0' &
                ext_mfb_meta(i)(i_meta_pcie_addr_o + i_meta_pcie_addr_w - 1 downto i_meta_pcie_addr_o + 2) &
                '0';
        end loop;
        return result;
    end function;

    constant USR_MFB_LENGTH : natural := USR_MFB_REGIONS * USR_MFB_REGION_SIZE * USR_MFB_BLOCK_SIZE * USR_MFB_ITEM_WIDTH;

    -- Stats-only classification (speed meter): distinguishes Completion Queue (set to 1) traffic
    -- from Write Buffer (set to 0) traffic. Independent of the buffer's own (now don't-care, see
    -- build_pcie_mfb_meta) write-meta channel bit.
    signal chan_sel : std_logic_vector(EXT_MFB_REGIONS -1 downto 0);
    -- nvc workaround: flat std_logic_vector avoids slv_array_t element access bug in nvc 1.21.0
    signal pcie_mfb_meta_parsed : std_logic_vector(EXT_MFB_REGIONS*(META_BE_W+META_PCIE_ADDR_W) -1 downto 0);

    -- =============================================================================================
    -- Interface for the CQE_PROCESSOR to the transaction buffer
    -- =============================================================================================
    signal cqp_buff_chan_b     : std_logic_vector(0 downto 0);
    signal cqp_buff_data_b     : std_logic_vector(USR_MFB_LENGTH -1 downto 0);
    signal cqp_buff_addr_b     : std_logic_vector(BUFF_PTR_WIDTH downto 0);
    signal cqp_buff_en_b       : std_logic;
    signal cqp_buff_data_vld_b : std_logic;

    -- =============================================================================================
    -- Interface for the PKT_DISPATCHER to the transaction buffer
    -- =============================================================================================
    signal rdr_buff_chan_a     : std_logic_vector(0 downto 0);
    signal rdr_buff_data_a     : std_logic_vector(USR_MFB_LENGTH -1 downto 0);
    signal rdr_buff_addr_a     : std_logic_vector(BUFF_PTR_WIDTH downto 0);
    signal rdr_buff_en_a       : std_logic;
    signal rdr_buff_data_vld_a : std_logic;

    -- =============================================================================================
    -- Speed meter signals
    -- =============================================================================================
    signal sm_mfb_sof : std_logic_vector(EXT_MFB_REGIONS -1 downto 0);
    signal sm_mfb_eof : std_logic_vector(EXT_MFB_REGIONS -1 downto 0);

    -- =============================================================================================
    -- CQ Processor status register signals
    -- =============================================================================================
    signal cqp_cqhdbl_int   : std_logic_vector(15 downto 0);
    signal cqp_sqhdbl_int   : std_logic_vector(15 downto 0);
    signal cqp_last_cqe_int : std_logic_vector(CQ_ENTRY_RANGE);
    signal cqp_status_upd_int : std_logic;
begin
    -- The speed meter measures the data rate of the stream to the data buffer
    cq_mfb_speed_meter_i : entity work.MFB_SPEED_METER_MI
        generic map (
            REGIONS     => EXT_MFB_REGIONS,
            REGION_SIZE => EXT_MFB_REGION_SIZE,
            BLOCK_SIZE  => EXT_MFB_BLOCK_SIZE,
            ITEM_WIDTH  => EXT_MFB_ITEM_WIDTH,

            CNT_TICKS_WIDTH  => 24,
            CNT_BYTES_WIDTH  => 32,
            CNT_PKTS_WIDTH   => 32,
            DISABLE_ON_CLR   => TRUE,
            COUNT_PACKETS    => FALSE,
            ADD_ARR_PKTS     => FALSE,
            FREQUENCY        => 250,
            MI_DATA_WIDTH    => 32,
            MI_ADDRESS_WIDTH => 32)
        port map (
            CLK => CLK,
            RST => RST,

            MI_DWR  => MI_DWR,
            MI_ADDR => MI_ADDR,
            MI_BE   => MI_BE,
            MI_RD   => MI_RD,
            MI_WR   => MI_WR,
            MI_ARDY => MI_ARDY,
            MI_DRD  => MI_DRD,
            MI_DRDY => MI_DRDY,

            RX_SOF     => sm_mfb_sof,
            RX_EOF     => sm_mfb_eof,
            RX_SOF_POS => EXT_MFB_SOF_POS,
            RX_EOF_POS => EXT_MFB_EOF_POS,
            RX_SRC_RDY => or (not chan_sel),
            RX_DST_RDY => EXT_MFB_DST_RDY);

    EXT_MFB_DST_RDY <= '1';

    sm_mfb_g : for reg_idx in (EXT_MFB_REGIONS - 1) downto 0 generate
        -- Measure only data stream that comes to the copy buffer
        sm_mfb_sof(reg_idx) <= EXT_MFB_SOF(reg_idx) and (not chan_sel(reg_idx));
        sm_mfb_eof(reg_idx) <= EXT_MFB_EOF(reg_idx) and (not chan_sel(reg_idx));
    end generate;

    -- Parsing of the metadata signal from the metadata extractor since it has a different layout
    -- than the input signal to the PCIE_TRANS_BUFFER
    meta_ext_mfb_meta_g : for rgn_idx in (EXT_MFB_REGIONS -1) downto 0 generate
        chan_sel(rgn_idx) <= '0' when EXT_MFB_META(rgn_idx)(META_BAR_ID) = WRBUFF_BAR_ID else '1';
    end generate;

    pcie_mfb_meta_parsed <= build_pcie_mfb_meta(
        EXT_MFB_META,
        META_BE_O, META_BE_W, META_PCIE_ADDR_O, META_PCIE_ADDR_W);

    cq_wr_buffer_i : entity work.TX_DMA_PCIE_TRANS_BUFFER
        generic map (
            DEVICE          => DEVICE,
            CHANNELS        => 2,

            MFB_REGIONS     => EXT_MFB_REGIONS,
            MFB_REGION_SIZE => EXT_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => EXT_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => EXT_MFB_ITEM_WIDTH,

            POINTER_WIDTH   => BUFF_PTR_WIDTH,
            -- Flat addressing: the CQ lives at page 0, WRBUFF at pages 1+, of one flat space.
            MEM_PARTITIONING => FALSE,

            SPLIT_READ_PORTS       => TRUE,
            READ_BARREL_SHIFTER_EN => (FALSE, TRUE))
        port map (
            CLK   => CLK,
            RESET => RST,

            PCIE_MFB_DATA    => EXT_MFB_DATA,
            PCIE_MFB_META    => slv_array_deser(pcie_mfb_meta_parsed, EXT_MFB_REGIONS, META_BE_W+META_PCIE_ADDR_W),
            PCIE_MFB_SOF     => EXT_MFB_SOF,
            PCIE_MFB_SRC_RDY => EXT_MFB_SRC_RDY,

            RD_CHAN_A     => rdr_buff_chan_a,
            RD_DATA_A     => rdr_buff_data_a,
            RD_ADDR_A     => rdr_buff_addr_a,
            RD_EN_A       => rdr_buff_en_a,
            RD_DATA_VLD_A => rdr_buff_data_vld_a,

            RD_CHAN_B     => cqp_buff_chan_b,
            RD_DATA_B     => cqp_buff_data_b,
            RD_ADDR_B     => cqp_buff_addr_b,
            RD_EN_B       => cqp_buff_en_b,
            RD_DATA_VLD_B => cqp_buff_data_vld_b);

    cqe_processor_i : entity work.CQE_PROCESSOR
        generic map (
            DEVICE => DEVICE,
            DATA_WIDTH => EXT_MFB_DATA'length,

            BUFF_POINTER_WIDTH => BUFF_PTR_WIDTH)
        port map (
            CLK   => CLK,
            RESET => RST,

            START_REQ_VLD => CQP_START_REQ_VLD,
            START_REQ_ACK => CQP_START_REQ_ACK,
            STOP_REQ_VLD  => CQP_STOP_REQ_VLD,
            STOP_REQ_ACK  => CQP_STOP_REQ_ACK,

            -- The CQE processor has been connected to the B port of the transaction buffer since
            -- this port is assumed to have less load on the write side and therefore be able to
            -- perform more reads (the writes block the read ports since they have higher priority).
            DATA_BUFF_RD_CHAN     => cqp_buff_chan_b,
            DATA_BUFF_RD_DATA     => cqp_buff_data_b,
            DATA_BUFF_RD_ADDR     => cqp_buff_addr_b,
            DATA_BUFF_RD_EN       => cqp_buff_en_b,
            DATA_BUFF_RD_DATA_VLD => cqp_buff_data_vld_b,

            DBL_MASK        => DBL_MASK,
            CQHDBL_UPD_DATA => cqp_cqhdbl_int,
            SQHDBL_UPD_DATA => cqp_sqhdbl_int,
            LAST_CQ_ENTRY   => cqp_last_cqe_int,
            STATUS_UPD_EN   => cqp_status_upd_int);

    cqp_status_reg_p : process (CLK)
    begin
        if rising_edge(CLK) then
            CQP_CQHDBL     <= cqp_cqhdbl_int;
            CQP_SQHDBL     <= cqp_sqhdbl_int;
            CQP_LAST_CQE   <= cqp_last_cqe_int;
            CQP_STATUS_UPD <= cqp_status_upd_int;
        end if;
    end process;

    pkt_dispatcher_i : entity work.PKT_DISPATCHER
        generic map (
            DEVICE       => DEVICE,
            PKT_SIZE_MAX => 2**BUFF_PTR_WIDTH,

            MFB_REGIONS     => USR_MFB_REGIONS,
            MFB_REGION_SIZE => USR_MFB_REGION_SIZE,
            MFB_BLOCK_SIZE  => USR_MFB_BLOCK_SIZE,
            MFB_ITEM_WIDTH  => USR_MFB_ITEM_WIDTH,

            BUFF_PTR_WIDTH => BUFF_PTR_WIDTH)
        port map (
            CLK   => CLK,
            RESET => RST,

            BUFF_RD_REQ_ADDR => BUFF_RD_REQ_ADDR,
            BUFF_RD_REQ_SIZE => BUFF_RD_REQ_SIZE,
            BUFF_RD_REQ_LAST => BUFF_RD_REQ_LAST,
            BUFF_RD_REQ_EN   => BUFF_RD_REQ_EN,
            BUFF_RD_REQ_ACK  => BUFF_RD_REQ_ACK,

            DATA_BUFF_RD_CHAN     => rdr_buff_chan_a,
            DATA_BUFF_RD_DATA     => rdr_buff_data_a,
            DATA_BUFF_RD_ADDR     => rdr_buff_addr_a,
            DATA_BUFF_RD_EN       => rdr_buff_en_a,
            DATA_BUFF_RD_DATA_VLD => rdr_buff_data_vld_a,

            WRBUFF_USR_RDS_INCR      => WRBUFF_USR_RDS_INCR,
            WRBUFF_USR_RDS_BYTES     => WRBUFF_USR_RDS_BYTES,

            TX_MFB_DATA    => RD_RESP_MFB_DATA,
            TX_MFB_SOF     => RD_RESP_MFB_SOF,
            TX_MFB_EOF     => RD_RESP_MFB_EOF,
            TX_MFB_SOF_POS => RD_RESP_MFB_SOF_POS,
            TX_MFB_EOF_POS => RD_RESP_MFB_EOF_POS,
            TX_MFB_SRC_RDY => RD_RESP_MFB_SRC_RDY,
            TX_MFB_DST_RDY => RD_RESP_MFB_DST_RDY);
end architecture;
