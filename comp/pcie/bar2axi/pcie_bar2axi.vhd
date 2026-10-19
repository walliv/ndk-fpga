-- pcie_bar2axi.vhd: PCIe completer mapping a BAR window onto an AXI4 memory-mapped master
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.bar2axi_pkg.all;

-- PCIe completer mapping one BAR onto an AXI4 master: MemWr becomes write bursts, MemRd becomes
-- reads answered by CplDs cut on 128 B boundaries. Xilinx CQ/CC MFB format; readme.rst describes
-- ordering and UR rules.
entity PCIE_BAR2AXI is
    generic (
        -- "ULTRASCALE" or "VERSAL", both use the same CQ/CC descriptor format
        DEVICE          : string  := "ULTRASCALE";
        -- MFB geometry of the CQ and CC ports
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;
        -- BAR served by this component
        BAR_ID          : natural := 0;
        -- Accept only requests that target function FUNC_ID
        FUNC_FILTER_EN  : boolean := true;
        FUNC_ID         : natural := 1;
        -- log2 of the window size in bytes, at least 12
        BAR_APERTURE    : natural := 30;
        -- AXI address of the window's first byte, 4 KB aligned
        AXI_BASE_ADDR   : std_logic_vector(63 downto 0) := X"0000004000000000";
        -- AXI4 master: 256 or 512 data bits
        AXI_DATA_WIDTH  : natural := 512;
        AXI_ADDR_WIDTH  : natural := 64;
        AXI_ID_WIDTH    : natural := 1;
        -- AWID and ARID of every burst
        AXI_ID          : natural := 0;
        -- Normal non-cacheable non-bufferable: modifiable (as HBM needs for narrow bursts), and B
        -- comes from the end point, which is what the read-after-write fence relies on.
        AXI_CACHE       : std_logic_vector(3 downto 0) := "0010";
        AXI_PROT        : std_logic_vector(2 downto 0) := "000";
        AXI_QOS         : std_logic_vector(3 downto 0) := "0000";
        -- Largest accepted MemWr payload; longer writes are dropped
        MAX_WR_BYTES    : natural := 1024;
        -- Largest accepted MemRd; longer reads are answered UR
        MAX_RD_BYTES    : natural := 4096;
        -- Non-posted requests in flight (accepted, not completed), power of 2
        RD_OUTSTANDING  : natural := 8;
        -- Read data buffer in bytes, power of 2, at least 33 chunks of 128 B
        RD_BUFFER_BYTES : natural := 16384;
        -- Write bursts waiting for their B response, power of 2
        WR_OUTSTANDING  : natural := 16;
        -- Width of the status counters
        CNT_WIDTH       : natural := 32
    );
    port (
        CLK   : in  std_logic;
        RESET : in  std_logic;

        -- =========================================================================================
        -- MFB Completer Request (CQ) interface
        -- =========================================================================================
        CQ_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CQ_MFB_META    : in  std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        CQ_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_EOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        CQ_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CQ_MFB_SRC_RDY : in  std_logic;
        CQ_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- MFB Completer Completion (CC) interface
        -- =========================================================================================
        CC_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CC_MFB_META    : out std_logic_vector(MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
        CC_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        CC_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CC_MFB_SRC_RDY : out std_logic;
        CC_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- AXI4 master, clocked by CLK
        -- =========================================================================================
        M_AXI_AWID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_AWADDR  : out std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        M_AXI_AWLEN   : out std_logic_vector(8-1 downto 0);
        M_AXI_AWSIZE  : out std_logic_vector(3-1 downto 0);
        M_AXI_AWBURST : out std_logic_vector(2-1 downto 0);
        M_AXI_AWLOCK  : out std_logic;
        M_AXI_AWCACHE : out std_logic_vector(4-1 downto 0);
        M_AXI_AWPROT  : out std_logic_vector(3-1 downto 0);
        M_AXI_AWQOS   : out std_logic_vector(4-1 downto 0);
        M_AXI_AWVALID : out std_logic;
        M_AXI_AWREADY : in  std_logic;

        M_AXI_WDATA   : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        M_AXI_WSTRB   : out std_logic_vector(AXI_DATA_WIDTH/8-1 downto 0);
        M_AXI_WLAST   : out std_logic;
        M_AXI_WVALID  : out std_logic;
        M_AXI_WREADY  : in  std_logic;

        M_AXI_BID     : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_BRESP   : in  std_logic_vector(2-1 downto 0);
        M_AXI_BVALID  : in  std_logic;
        M_AXI_BREADY  : out std_logic;

        M_AXI_ARID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_ARADDR  : out std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        M_AXI_ARLEN   : out std_logic_vector(8-1 downto 0);
        M_AXI_ARSIZE  : out std_logic_vector(3-1 downto 0);
        M_AXI_ARBURST : out std_logic_vector(2-1 downto 0);
        M_AXI_ARLOCK  : out std_logic;
        M_AXI_ARCACHE : out std_logic_vector(4-1 downto 0);
        M_AXI_ARPROT  : out std_logic_vector(3-1 downto 0);
        M_AXI_ARQOS   : out std_logic_vector(4-1 downto 0);
        M_AXI_ARVALID : out std_logic;
        M_AXI_ARREADY : in  std_logic;

        M_AXI_RID     : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_RDATA   : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        M_AXI_RRESP   : in  std_logic_vector(2-1 downto 0);
        M_AXI_RLAST   : in  std_logic;
        M_AXI_RVALID  : in  std_logic;
        M_AXI_RREADY  : out std_logic;

        -- =========================================================================================
        -- Status counters, wrapping
        -- =========================================================================================
        -- Accepted MemWr TLPs
        CNT_WR   : out std_logic_vector(CNT_WIDTH-1 downto 0);
        -- Accepted MemRd TLPs
        CNT_RD   : out std_logic_vector(CNT_WIDTH-1 downto 0);
        -- Non-posted requests answered with UR
        CNT_UR   : out std_logic_vector(CNT_WIDTH-1 downto 0);
        -- Dropped posted requests
        CNT_DROP : out std_logic_vector(CNT_WIDTH-1 downto 0);
        -- AXI responses other than OKAY
        CNT_ERR  : out std_logic_vector(CNT_WIDTH-1 downto 0)
    );
end entity;

architecture FULL of PCIE_BAR2AXI is

    constant RGN_W     : natural := MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    constant SOFP_W    : natural := max(1, log2(MFB_REGION_SIZE));
    constant EOFP_W    : natural := max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE));
    constant MAX_WR_DW : natural := MAX_WR_BYTES/4;
    constant MAX_RD_DW : natural := MAX_RD_BYTES/4;
    -- write TLPs not yet answered: both staging halves plus one per outstanding burst
    constant PEND_W    : natural := log2(WR_OUTSTANDING + 3) + 1;
    constant NP_CNT_W  : natural := log2(RD_OUTSTANDING) + 1;
    constant CPW       : natural := log2(RD_BUFFER_BYTES/CHUNK_BYTES) + 1;
    constant BWW       : natural := log2(RD_BUFFER_BYTES/(AXI_DATA_WIDTH/8));

    type intake_fsm_t is (IS_HDR, IS_WR, IS_DROP);

    -- CQ input pipe and reduction to one region
    signal pi_data         : std_logic_vector(MFB_REGIONS*RGN_W-1 downto 0);
    signal pi_meta         : std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
    signal pi_sof          : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal pi_eof          : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal pi_sof_pos      : std_logic_vector(MFB_REGIONS*SOFP_W-1 downto 0);
    signal pi_eof_pos      : std_logic_vector(MFB_REGIONS*EOFP_W-1 downto 0);
    signal pi_src_rdy      : std_logic;
    signal pi_dst_rdy      : std_logic;

    signal tr_data         : std_logic_vector(RGN_W-1 downto 0);
    signal tr_meta         : std_logic_vector(PCIE_CQ_META_WIDTH-1 downto 0);
    signal tr_sof          : std_logic_vector(0 downto 0);
    signal tr_eof          : std_logic_vector(0 downto 0);
    signal tr_eof_pos      : std_logic_vector(EOFP_W-1 downto 0);
    signal tr_src_rdy      : std_logic;
    signal tr_dst_rdy      : std_logic;

    signal in_data         : std_logic_vector(RGN_W-1 downto 0);
    signal in_meta         : std_logic_vector(PCIE_CQ_META_WIDTH-1 downto 0);
    signal in_sof_v        : std_logic_vector(0 downto 0);
    signal in_eof_v        : std_logic_vector(0 downto 0);
    signal in_sof          : std_logic;
    signal in_eof          : std_logic;
    signal in_src_rdy      : std_logic;
    signal in_dst_rdy      : std_logic;

    -- descriptor decode
    signal dp_addr         : std_logic_vector(64-1 downto 0);
    signal dp_dw           : std_logic_vector(11-1 downto 0);
    signal dp_req_id       : std_logic_vector(16-1 downto 0);
    signal dp_tag          : std_logic_vector(10-1 downto 0);
    signal dp_tc           : std_logic_vector(3-1 downto 0);
    signal dp_attr         : std_logic_vector(3-1 downto 0);
    signal dp_fbe          : std_logic_vector(4-1 downto 0);
    signal dp_lbe          : std_logic_vector(4-1 downto 0);
    signal dp_at           : std_logic_vector(2-1 downto 0);
    signal dp_func         : std_logic_vector(8-1 downto 0);
    signal dp_bar          : std_logic_vector(3-1 downto 0);
    signal d_type          : std_logic_vector(4-1 downto 0);
    signal d_bar_ok        : std_logic;
    signal d_posted        : std_logic;
    signal d_rd_type       : std_logic;
    signal d_wr_ok         : std_logic;
    signal d_rd_ok         : std_logic;
    signal d_bc            : std_logic_vector(13-1 downto 0);
    signal d_la_low        : std_logic_vector(2-1 downto 0);
    signal d_la            : std_logic_vector(7-1 downto 0);
    signal d_end           : unsigned(13-1 downto 0);
    signal d_nch           : unsigned(12-1 downto 0);
    signal d_axi_addr      : std_logic_vector(64-1 downto 0);
    signal d_npd           : std_logic_vector(NPD_WIDTH-1 downto 0);

    -- intake control
    signal ist             : intake_fsm_t;
    signal ist_nxt         : intake_fsm_t;
    signal st_vld          : std_logic;
    signal st_sof          : std_logic;
    signal st_rdy          : std_logic;
    signal np_push         : std_logic;
    signal np_room         : std_logic;
    signal wr_eof_acc      : std_logic;
    signal drop_acc        : std_logic;
    signal rd_acc          : std_logic;
    signal ur_acc          : std_logic;

    -- ordering bookkeeping
    signal tlp_done        : std_logic;
    signal np_done         : std_logic;
    signal wr_out_cnt      : unsigned(PEND_W-1 downto 0);
    signal np_out_cnt      : unsigned(NP_CNT_W-1 downto 0);
    -- a read never shares a word with a write's EOF, so only tlp_done changes wr_out_cnt in its cycle
    signal pend_init       : unsigned(PEND_W-1 downto 0);
    signal wr_acc_cnt      : unsigned(32-1 downto 0);
    signal wr_done_cnt     : unsigned(32-1 downto 0);

    -- read engine <-> completion engine
    signal cpl_desc        : std_logic_vector(NPD_WIDTH-1 downto 0);
    signal cpl_vld         : std_logic;
    signal cpl_pop         : std_logic;
    signal r_chunk_ptr     : std_logic_vector(CPW-1 downto 0);
    signal cc_chunk_ptr    : std_logic_vector(CPW-1 downto 0);
    signal buf_rd_addr     : std_logic_vector(BWW-1 downto 0);
    signal buf_rd_en       : std_logic;
    signal buf_rd_data     : std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
    signal buf_rd_vld      : std_logic;

    signal wr_err          : std_logic;
    signal rd_err          : std_logic;

    signal cnt_wr_r        : unsigned(CNT_WIDTH-1 downto 0);
    signal cnt_rd_r        : unsigned(CNT_WIDTH-1 downto 0);
    signal cnt_ur_r        : unsigned(CNT_WIDTH-1 downto 0);
    signal cnt_drop_r      : unsigned(CNT_WIDTH-1 downto 0);
    signal cnt_err_r       : unsigned(CNT_WIDTH-1 downto 0);

    signal wr_out_overflow : std_logic;
    signal np_out_overflow : std_logic;

begin

    assert (DEVICE = "ULTRASCALE" or DEVICE = "VERSAL")
        report "PCIE_BAR2AXI: DEVICE must be ULTRASCALE or VERSAL!"
        severity failure;
    assert (MFB_REGIONS = 1 or MFB_REGIONS = 2 or MFB_REGIONS = 4)
        report "PCIE_BAR2AXI: MFB_REGIONS must be 1, 2 or 4!"
        severity failure;
    assert (MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 8 and MFB_ITEM_WIDTH = 32)
        report "PCIE_BAR2AXI: MFB regions must be 1 block of 8 DWs!"
        severity failure;
    assert (BAR_APERTURE >= 12 and BAR_APERTURE <= 63)
        report "PCIE_BAR2AXI: BAR_APERTURE must be within 12..63!"
        severity failure;
    assert (AXI_BASE_ADDR(12-1 downto 0) = X"000")
        report "PCIE_BAR2AXI: AXI_BASE_ADDR must be 4 KB aligned!"
        severity failure;
    assert (MAX_WR_BYTES mod 4 = 0 and MAX_WR_BYTES >= 4 and MAX_WR_BYTES <= 4096)
        report "PCIE_BAR2AXI: MAX_WR_BYTES must be a DW multiple within 4..4096!"
        severity failure;
    assert (MAX_RD_BYTES mod 4 = 0 and MAX_RD_BYTES >= 4 and MAX_RD_BYTES <= 4096)
        report "PCIE_BAR2AXI: MAX_RD_BYTES must be a DW multiple within 4..4096!"
        severity failure;

    -- =============================================================================================
    -- CQ input: pipe, reduction to one 8-DW region per word, pipe
    -- =============================================================================================

    cq_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => MFB_REGIONS,
        REGION_SIZE => MFB_REGION_SIZE,
        BLOCK_SIZE  => MFB_BLOCK_SIZE,
        ITEM_WIDTH  => MFB_ITEM_WIDTH,
        META_WIDTH  => PCIE_CQ_META_WIDTH,
        FAKE_PIPE   => false,
        USE_DST_RDY => true,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RESET,

        RX_DATA    => CQ_MFB_DATA,
        RX_META    => CQ_MFB_META,
        RX_SOF_POS => CQ_MFB_SOF_POS,
        RX_EOF_POS => CQ_MFB_EOF_POS,
        RX_SOF     => CQ_MFB_SOF,
        RX_EOF     => CQ_MFB_EOF,
        RX_SRC_RDY => CQ_MFB_SRC_RDY,
        RX_DST_RDY => CQ_MFB_DST_RDY,

        TX_DATA    => pi_data,
        TX_META    => pi_meta,
        TX_SOF_POS => pi_sof_pos,
        TX_EOF_POS => pi_eof_pos,
        TX_SOF     => pi_sof,
        TX_EOF     => pi_eof,
        TX_SRC_RDY => pi_src_rdy,
        TX_DST_RDY => pi_dst_rdy
    );

    cq_transformer_i : entity work.MFB_TRANSFORMER
    generic map (
        RX_REGIONS  => MFB_REGIONS,
        TX_REGIONS  => 1,
        REGION_SIZE => MFB_REGION_SIZE,
        BLOCK_SIZE  => MFB_BLOCK_SIZE,
        ITEM_WIDTH  => MFB_ITEM_WIDTH,
        META_WIDTH  => PCIE_CQ_META_WIDTH
    )
    port map (
        CLK        => CLK,
        RESET      => RESET,

        RX_DATA    => pi_data,
        RX_META    => pi_meta,
        RX_SOP     => pi_sof,
        RX_EOP     => pi_eof,
        RX_SOP_POS => pi_sof_pos,
        RX_EOP_POS => pi_eof_pos,
        RX_SRC_RDY => pi_src_rdy,
        RX_DST_RDY => pi_dst_rdy,

        TX_DATA    => tr_data,
        TX_META    => tr_meta,
        TX_SOP     => tr_sof,
        TX_EOP     => tr_eof,
        TX_SOP_POS => open,
        TX_EOP_POS => tr_eof_pos,
        TX_SRC_RDY => tr_src_rdy,
        TX_DST_RDY => tr_dst_rdy
    );

    cq_rgn_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => 1,
        REGION_SIZE => MFB_REGION_SIZE,
        BLOCK_SIZE  => MFB_BLOCK_SIZE,
        ITEM_WIDTH  => MFB_ITEM_WIDTH,
        META_WIDTH  => PCIE_CQ_META_WIDTH,
        FAKE_PIPE   => false,
        USE_DST_RDY => true,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RESET,

        RX_DATA    => tr_data,
        RX_META    => tr_meta,
        RX_SOF_POS => (others => '0'),
        RX_EOF_POS => tr_eof_pos,
        RX_SOF     => tr_sof,
        RX_EOF     => tr_eof,
        RX_SRC_RDY => tr_src_rdy,
        RX_DST_RDY => tr_dst_rdy,

        TX_DATA    => in_data,
        TX_META    => in_meta,
        TX_SOF_POS => open,
        TX_EOF_POS => open,
        TX_SOF     => in_sof_v,
        TX_EOF     => in_eof_v,
        TX_SRC_RDY => in_src_rdy,
        TX_DST_RDY => in_dst_rdy
    );

    in_sof <= in_sof_v(0);
    in_eof <= in_eof_v(0);

    -- =============================================================================================
    -- Descriptor decode, valid with in_sof
    -- =============================================================================================

    cq_hdr_deparser_i : entity work.PCIE_CQ_HDR_DEPARSER
    generic map (
        DEVICE       => DEVICE,
        CQUSER_WIDTH => 183
    )
    port map (
        OUT_TAG          => dp_tag,
        OUT_ADDRESS      => dp_addr,
        OUT_REQ_ID       => dp_req_id,
        OUT_TC           => dp_tc,
        OUT_DW_CNT       => dp_dw,
        OUT_ATTRIBUTES   => dp_attr,
        OUT_FBE          => dp_fbe,
        OUT_LBE          => dp_lbe,
        OUT_ADDRESS_TYPE => dp_at,
        OUT_TARGET_FUNC  => dp_func,
        OUT_BAR_ID       => dp_bar,
        OUT_BAR_APERTURE => open,
        OUT_ADDR_LEN     => open,
        OUT_REQ_TYPE     => open,

        IN_HEADER        => in_data(128-1 downto 0),
        IN_FBE           => in_meta(PCIE_CQ_META_FBE),
        IN_LBE           => in_meta(PCIE_CQ_META_LBE),
        IN_INTEL_META    => (others => '0')
    );

    byte_count_i : entity work.PCIE_BYTE_COUNT
    generic map (
        OUTPUT_REG => false
    )
    port map (
        CLK            => CLK,
        RESET          => RESET,
        IN_DW_COUNT    => dp_dw,
        IN_FIRST_BE    => dp_fbe,
        IN_LAST_BE     => dp_lbe,
        OUT_FIRST_IB   => open,
        OUT_LAST_IB    => open,
        OUT_BYTE_COUNT => d_bc
    );

    -- Xilinx request type: 0000 MemRd, 0001 MemWr, 0111 MRdLk, 11xx messages (posted)
    d_type    <= in_data(78 downto 75);
    d_bar_ok  <= '1' when (unsigned(dp_bar) = BAR_ID and (not FUNC_FILTER_EN or unsigned(dp_func) = FUNC_ID)) else '0';
    d_posted  <= '1' when (d_type = "0001" or d_type(3 downto 2) = "11") else '0';
    d_rd_type <= '1' when (d_type = "0000" or d_type = "0111") else '0';
    d_wr_ok   <= '1' when (d_bar_ok = '1' and d_type = "0001" and unsigned(dp_dw) /= 0 and unsigned(dp_dw) <= MAX_WR_DW) else '0';
    d_rd_ok   <= '1' when (d_bar_ok = '1' and d_type = "0000" and unsigned(dp_dw) /= 0 and unsigned(dp_dw) <= MAX_RD_DW) else '0';

    -- offset of the first enabled byte; 00 for a zero-length read
    d_la_low <= "00" when (dp_fbe(0) = '1') else
                "01" when (dp_fbe(1) = '1') else
                "10" when (dp_fbe(2) = '1') else
                "11" when (dp_fbe(3) = '1') else
                "00";
    d_la     <= dp_addr(7-1 downto 2) & d_la_low;
    d_end    <= resize(unsigned(d_la), 13) + unsigned(d_bc);
    d_nch    <= shift_right(resize(unsigned(dp_addr(7-1 downto 2)), 12) + resize(unsigned(dp_dw), 12) - 1, 5) + 1;

    d_axi_addr <= std_logic_vector(unsigned(AXI_BASE_ADDR) + resize(unsigned(dp_addr(BAR_APERTURE-1 downto 0)), 64));

    npd_p : process (all)
    begin
        d_npd             <= (others => '0');
        d_npd(NPD_UR_O)   <= not d_rd_ok;
        d_npd(NPD_ADDR)   <= d_axi_addr;
        d_npd(NPD_DW)     <= dp_dw;
        d_npd(NPD_ENDO)   <= std_logic_vector(d_end);
        d_npd(NPD_TAG)    <= dp_tag(8-1 downto 0);
        d_npd(NPD_RID)    <= dp_req_id;
        d_npd(NPD_TC)     <= dp_tc;
        d_npd(NPD_ATTR)   <= dp_attr;
        d_npd(NPD_AT)     <= dp_at;
        d_npd(NPD_FUNC)   <= dp_func;
        if (d_rd_ok = '1') then
            d_npd(NPD_NCH) <= std_logic_vector(d_nch(NPD_NCH_W-1 downto 0));
        end if;
        -- memory-read completion fields for read types, the PCIe defaults for every other UR
        if (d_rd_type = '1') then
            d_npd(NPD_BC) <= d_bc;
            d_npd(NPD_LA) <= d_la;
        else
            d_npd(NPD_BC) <= std_logic_vector(to_unsigned(4, NPD_BC_W));
            d_npd(NPD_LA) <= (others => '0');
        end if;
    end process;

    -- =============================================================================================
    -- Intake FSM
    -- =============================================================================================

    np_room <= '1' when (np_out_cnt < RD_OUTSTANDING) else '0';
    st_sof  <= '1' when (ist = IS_HDR) else '0';

    intake_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            ist <= ist_nxt;
            if (RESET = '1') then
                ist <= IS_HDR;
            end if;
        end if;
    end process;

    intake_nst_p : process (all)
    begin
        ist_nxt    <= ist;
        in_dst_rdy <= '0';
        st_vld     <= '0';
        np_push    <= '0';
        wr_eof_acc <= '0';
        drop_acc   <= '0';

        case ist is
            when IS_HDR =>
                if (in_src_rdy = '1') then
                    if (in_sof = '0') then
                        -- word outside any frame
                        in_dst_rdy <= '1';
                    elsif (d_wr_ok = '1') then
                        in_dst_rdy <= st_rdy;
                        if (st_rdy = '1') then
                            st_vld <= '1';
                            if (in_eof = '1') then
                                wr_eof_acc <= '1';
                            else
                                ist_nxt <= IS_WR;
                            end if;
                        end if;
                    elsif (d_posted = '0') then
                        in_dst_rdy <= np_room;
                        if (np_room = '1') then
                            np_push <= '1';
                            if (in_eof = '0') then
                                ist_nxt <= IS_DROP;
                            end if;
                        end if;
                    else
                        in_dst_rdy <= '1';
                        drop_acc   <= '1';
                        if (in_eof = '0') then
                            ist_nxt <= IS_DROP;
                        end if;
                    end if;
                end if;

            when IS_WR =>
                in_dst_rdy <= '1';
                if (in_src_rdy = '1') then
                    st_vld <= '1';
                    if (in_eof = '1') then
                        wr_eof_acc <= '1';
                        ist_nxt    <= IS_HDR;
                    end if;
                end if;

            when IS_DROP =>
                in_dst_rdy <= '1';
                if (in_src_rdy = '1' and in_eof = '1') then
                    ist_nxt <= IS_HDR;
                end if;
        end case;
    end process;

    rd_acc <= np_push and d_rd_ok;
    ur_acc <= np_push and not d_rd_ok;

    -- =============================================================================================
    -- Ordering bookkeeping
    -- =============================================================================================

    pend_init <= wr_out_cnt - 1 when (tlp_done = '1') else wr_out_cnt;

    order_cnt_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (wr_eof_acc = '1' and tlp_done = '0') then
                wr_out_cnt <= wr_out_cnt + 1;
            elsif (wr_eof_acc = '0' and tlp_done = '1') then
                wr_out_cnt <= wr_out_cnt - 1;
            end if;
            if (np_push = '1' and np_done = '0') then
                np_out_cnt <= np_out_cnt + 1;
            elsif (np_push = '0' and np_done = '1') then
                np_out_cnt <= np_out_cnt - 1;
            end if;
            if (wr_eof_acc = '1') then
                wr_acc_cnt <= wr_acc_cnt + 1;
            end if;
            if (tlp_done = '1') then
                wr_done_cnt <= wr_done_cnt + 1;
            end if;
            if (RESET = '1') then
                wr_out_cnt  <= (others => '0');
                np_out_cnt  <= (others => '0');
                wr_acc_cnt  <= (others => '0');
                wr_done_cnt <= (others => '0');
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Engines
    -- =============================================================================================

    wr_i : entity work.PCIE_BAR2AXI_WR
    generic map (
        AXI_DATA_WIDTH => AXI_DATA_WIDTH,
        AXI_ADDR_WIDTH => AXI_ADDR_WIDTH,
        AXI_ID_WIDTH   => AXI_ID_WIDTH,
        AXI_ID         => AXI_ID,
        AXI_CACHE      => AXI_CACHE,
        AXI_PROT       => AXI_PROT,
        AXI_QOS        => AXI_QOS,
        MAX_WR_BYTES   => MAX_WR_BYTES,
        WR_OUTSTANDING => WR_OUTSTANDING
    )
    port map (
        CLK           => CLK,
        RESET         => RESET,

        ST_VLD        => st_vld,
        ST_SOF        => st_sof,
        ST_EOF        => in_eof,
        ST_DATA       => in_data,
        ST_ADDR       => d_axi_addr,
        ST_DW         => dp_dw,
        ST_FBE        => dp_fbe,
        ST_LBE        => dp_lbe,
        ST_RDY        => st_rdy,

        TLP_DONE      => tlp_done,
        ERR_INCR      => wr_err,

        M_AXI_AWID    => M_AXI_AWID,
        M_AXI_AWADDR  => M_AXI_AWADDR,
        M_AXI_AWLEN   => M_AXI_AWLEN,
        M_AXI_AWSIZE  => M_AXI_AWSIZE,
        M_AXI_AWBURST => M_AXI_AWBURST,
        M_AXI_AWLOCK  => M_AXI_AWLOCK,
        M_AXI_AWCACHE => M_AXI_AWCACHE,
        M_AXI_AWPROT  => M_AXI_AWPROT,
        M_AXI_AWQOS   => M_AXI_AWQOS,
        M_AXI_AWVALID => M_AXI_AWVALID,
        M_AXI_AWREADY => M_AXI_AWREADY,

        M_AXI_WDATA   => M_AXI_WDATA,
        M_AXI_WSTRB   => M_AXI_WSTRB,
        M_AXI_WLAST   => M_AXI_WLAST,
        M_AXI_WVALID  => M_AXI_WVALID,
        M_AXI_WREADY  => M_AXI_WREADY,

        M_AXI_BID     => M_AXI_BID,
        M_AXI_BRESP   => M_AXI_BRESP,
        M_AXI_BVALID  => M_AXI_BVALID,
        M_AXI_BREADY  => M_AXI_BREADY
    );

    rd_i : entity work.PCIE_BAR2AXI_RD
    generic map (
        DEVICE          => DEVICE,
        AXI_DATA_WIDTH  => AXI_DATA_WIDTH,
        AXI_ADDR_WIDTH  => AXI_ADDR_WIDTH,
        AXI_ID_WIDTH    => AXI_ID_WIDTH,
        AXI_ID          => AXI_ID,
        AXI_CACHE       => AXI_CACHE,
        AXI_PROT        => AXI_PROT,
        AXI_QOS         => AXI_QOS,
        RD_OUTSTANDING  => RD_OUTSTANDING,
        RD_BUFFER_BYTES => RD_BUFFER_BYTES,
        PEND_WIDTH      => PEND_W
    )
    port map (
        CLK           => CLK,
        RESET         => RESET,

        NP_PUSH       => np_push,
        NP_DESC       => d_npd,
        NP_PEND       => std_logic_vector(pend_init),
        NP_FENCE      => std_logic_vector(wr_acc_cnt),
        TLP_DONE      => tlp_done,
        WR_DONE_CNT   => std_logic_vector(wr_done_cnt),

        CPL_DESC      => cpl_desc,
        CPL_VLD       => cpl_vld,
        CPL_POP       => cpl_pop,

        R_CHUNK_PTR   => r_chunk_ptr,
        CC_CHUNK_PTR  => cc_chunk_ptr,
        BUF_RD_ADDR   => buf_rd_addr,
        BUF_RD_EN     => buf_rd_en,
        BUF_RD_DATA   => buf_rd_data,
        BUF_RD_VLD    => buf_rd_vld,

        ERR_INCR      => rd_err,

        M_AXI_ARID    => M_AXI_ARID,
        M_AXI_ARADDR  => M_AXI_ARADDR,
        M_AXI_ARLEN   => M_AXI_ARLEN,
        M_AXI_ARSIZE  => M_AXI_ARSIZE,
        M_AXI_ARBURST => M_AXI_ARBURST,
        M_AXI_ARLOCK  => M_AXI_ARLOCK,
        M_AXI_ARCACHE => M_AXI_ARCACHE,
        M_AXI_ARPROT  => M_AXI_ARPROT,
        M_AXI_ARQOS   => M_AXI_ARQOS,
        M_AXI_ARVALID => M_AXI_ARVALID,
        M_AXI_ARREADY => M_AXI_ARREADY,

        M_AXI_RID     => M_AXI_RID,
        M_AXI_RDATA   => M_AXI_RDATA,
        M_AXI_RRESP   => M_AXI_RRESP,
        M_AXI_RLAST   => M_AXI_RLAST,
        M_AXI_RVALID  => M_AXI_RVALID,
        M_AXI_RREADY  => M_AXI_RREADY
    );

    cc_i : entity work.PCIE_BAR2AXI_CC
    generic map (
        DEVICE          => DEVICE,
        MFB_REGIONS     => MFB_REGIONS,
        MFB_REGION_SIZE => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        AXI_DATA_WIDTH  => AXI_DATA_WIDTH,
        RD_BUFFER_BYTES => RD_BUFFER_BYTES
    )
    port map (
        CLK            => CLK,
        RESET          => RESET,

        CPL_DESC       => cpl_desc,
        CPL_VLD        => cpl_vld,
        CPL_POP        => cpl_pop,
        NP_DONE        => np_done,

        R_CHUNK_PTR    => r_chunk_ptr,
        CC_CHUNK_PTR   => cc_chunk_ptr,
        BUF_RD_ADDR    => buf_rd_addr,
        BUF_RD_EN      => buf_rd_en,
        BUF_RD_DATA    => buf_rd_data,
        BUF_RD_VLD     => buf_rd_vld,

        CC_MFB_DATA    => CC_MFB_DATA,
        CC_MFB_META    => CC_MFB_META,
        CC_MFB_SOF     => CC_MFB_SOF,
        CC_MFB_EOF     => CC_MFB_EOF,
        CC_MFB_SOF_POS => CC_MFB_SOF_POS,
        CC_MFB_EOF_POS => CC_MFB_EOF_POS,
        CC_MFB_SRC_RDY => CC_MFB_SRC_RDY,
        CC_MFB_DST_RDY => CC_MFB_DST_RDY
    );

    -- =============================================================================================
    -- Status counters
    -- =============================================================================================

    cnt_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (wr_eof_acc = '1') then
                cnt_wr_r <= cnt_wr_r + 1;
            end if;
            if (rd_acc = '1') then
                cnt_rd_r <= cnt_rd_r + 1;
            end if;
            if (ur_acc = '1') then
                cnt_ur_r <= cnt_ur_r + 1;
            end if;
            if (drop_acc = '1') then
                cnt_drop_r <= cnt_drop_r + 1;
            end if;
            if (wr_err = '1' and rd_err = '1') then
                cnt_err_r <= cnt_err_r + 2;
            elsif (wr_err = '1' or rd_err = '1') then
                cnt_err_r <= cnt_err_r + 1;
            end if;
            if (RESET = '1') then
                cnt_wr_r   <= (others => '0');
                cnt_rd_r   <= (others => '0');
                cnt_ur_r   <= (others => '0');
                cnt_drop_r <= (others => '0');
                cnt_err_r  <= (others => '0');
            end if;
        end if;
    end process;

    CNT_WR   <= std_logic_vector(cnt_wr_r);
    CNT_RD   <= std_logic_vector(cnt_rd_r);
    CNT_UR   <= std_logic_vector(cnt_ur_r);
    CNT_DROP <= std_logic_vector(cnt_drop_r);
    CNT_ERR  <= std_logic_vector(cnt_err_r);

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================

    wr_out_overflow <= '1' when (wr_out_cnt > WR_OUTSTANDING + 2) else '0';
    np_out_overflow <= '1' when (np_out_cnt > RD_OUTSTANDING) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl assert_wr_out_bound : assert always
    --     (RESET = '0' -> wr_out_overflow = '0')
    --     report "PCIE_BAR2AXI: more write TLPs pending than staging plus outstanding bursts allow";

    -- psl assert_np_out_bound : assert always
    --     (RESET = '0' -> np_out_overflow = '0')
    --     report "PCIE_BAR2AXI: more non-posted requests in flight than RD_OUTSTANDING";

    -- psl assert_tlp_done_has_write : assert always
    --     ((RESET = '0' and tlp_done = '1') -> wr_out_cnt /= 0)
    --     report "PCIE_BAR2AXI: write completion without an outstanding write TLP";

end architecture;
