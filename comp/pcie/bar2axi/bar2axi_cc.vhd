-- bar2axi_cc.vhd: Completion engine of PCIE_BAR2AXI, turns buffered read data into CplD TLPs
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

-- Answers non-posted requests in order: one CplD per 128 B chunk of a MemRd, a 3-DW Cpl for UR.
-- Each TLP starts in region 0 of its own MFB words, which any CC converter accepts.
entity PCIE_BAR2AXI_CC is
    generic (
        DEVICE          : string  := "ULTRASCALE";
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;
        AXI_DATA_WIDTH  : natural := 512;
        RD_BUFFER_BYTES : natural := 16384
    );
    port (
        CLK   : in  std_logic;
        RESET : in  std_logic;

        -- =========================================================================================
        -- Requests from the read engine
        -- =========================================================================================
        CPL_DESC     : in  std_logic_vector(NPD_WIDTH-1 downto 0);
        CPL_VLD      : in  std_logic;
        CPL_POP      : out std_logic;
        -- Pulse: the last TLP of a request was handed to the CC interface
        NP_DONE      : out std_logic;

        -- =========================================================================================
        -- Read buffer
        -- =========================================================================================
        R_CHUNK_PTR  : in  std_logic_vector(log2(RD_BUFFER_BYTES/CHUNK_BYTES) downto 0);
        CC_CHUNK_PTR : out std_logic_vector(log2(RD_BUFFER_BYTES/CHUNK_BYTES) downto 0);
        BUF_RD_ADDR  : out std_logic_vector(log2(RD_BUFFER_BYTES/(AXI_DATA_WIDTH/8))-1 downto 0);
        BUF_RD_EN    : out std_logic;
        BUF_RD_DATA  : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        BUF_RD_VLD   : in  std_logic;

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
        CC_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of PCIE_BAR2AXI_CC is

    -- DWs per MFB region and per MFB word
    constant RI       : natural := MFB_REGION_SIZE*MFB_BLOCK_SIZE;
    constant RIB      : natural := log2(RI);
    constant ODW      : natural := MFB_REGIONS*RI;
    constant ODWB     : natural := log2(ODW);
    constant EOFP_W   : natural := max(1, log2(RI));
    -- 3-DW header plus one full chunk
    constant TLP_DWS  : natural := 3 + CHUNK_DWS;
    constant NWMAX    : natural := div_roundup(TLP_DWS, ODW);
    constant WIDX_W   : natural := max(1, log2(NWMAX));
    constant WB       : natural := AXI_DATA_WIDTH/8;
    constant LW       : natural := WB/4;
    constant WPC      : natural := CHUNK_BYTES/WB;
    constant WPCB     : natural := log2(WPC);
    constant CPW      : natural := log2(RD_BUFFER_BYTES/CHUNK_BYTES) + 1;

    type cc_fsm_t is (CS_IDLE, CS_SEG, CS_WAIT, CS_LOAD, CS_BUILD, CS_SEND);

    signal cst         : cc_fsm_t;
    signal c_desc      : std_logic_vector(NPD_WIDTH-1 downto 0);
    signal c_ur        : std_logic;
    signal c_seg       : unsigned(NPD_NCH_W-1 downto 0);
    signal c_ptr       : unsigned(CPW-1 downto 0);

    signal s_lo        : unsigned(5-1 downto 0);
    signal s_dw        : unsigned(6-1 downto 0);
    signal s_bc        : unsigned(NPD_BC_W-1 downto 0);
    signal s_la        : std_logic_vector(NPD_LA_W-1 downto 0);
    signal s_last      : std_logic;

    signal ld_iss      : unsigned(WPCB downto 0);
    signal ld_cap      : unsigned(WPCB downto 0);
    signal chunk_r     : slv_array_t(0 to WPC-1)(AXI_DATA_WIDTH-1 downto 0);
    signal chunk_dw    : slv_array_t(0 to CHUNK_DWS-1)(32-1 downto 0);

    signal cc_status   : std_logic_vector(3-1 downto 0);
    signal hdr         : std_logic_vector(96-1 downto 0);
    signal tlp_dw      : slv_array_t(0 to NWMAX*ODW-1)(32-1 downto 0);
    signal tlp_words   : slv_array_t(0 to NWMAX-1)(ODW*32-1 downto 0);
    signal tlp_r       : slv_array_t(0 to NWMAX-1)(ODW*32-1 downto 0);
    signal w_idx       : unsigned(WIDX_W-1 downto 0);
    signal eof_word    : unsigned(WIDX_W-1 downto 0);
    signal eof_rgn     : unsigned(max(1, log2(MFB_REGIONS))-1 downto 0);
    signal eof_pos     : unsigned(EOFP_W-1 downto 0);

    signal out_data    : std_logic_vector(ODW*32-1 downto 0);
    signal out_meta    : slv_array_t(MFB_REGIONS-1 downto 0)(PCIE_CC_META_WIDTH-1 downto 0);
    signal out_sof     : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal out_eof     : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal out_eof_pos : slv_array_t(MFB_REGIONS-1 downto 0)(EOFP_W-1 downto 0);
    signal out_src_rdy : std_logic;
    signal out_dst_rdy : std_logic;
    signal out_last    : std_logic;

    -- s_lo selects every DW of the 1024-bit rotation; replicate it so routing stays local
    attribute max_fanout         : integer;
    attribute max_fanout of s_lo : signal is 32;

    signal chunk_early : std_logic;
    signal seg_bad     : std_logic;
    signal seg_len_bad : std_logic;

begin

    assert (MFB_REGION_SIZE = 1 and MFB_BLOCK_SIZE = 8 and MFB_ITEM_WIDTH = 32)
        report "PCIE_BAR2AXI_CC: only MFB regions of 1 block of 8 DWs are supported!"
        severity failure;

    c_ur <= c_desc(NPD_UR_O);

    -- =============================================================================================
    -- Segment control
    -- =============================================================================================

    BUF_RD_EN    <= '1' when (cst = CS_LOAD and ld_iss < WPC) else '0';
    BUF_RD_ADDR  <= std_logic_vector(c_ptr(CPW-2 downto 0)) & std_logic_vector(ld_iss(WPCB-1 downto 0));
    CC_CHUNK_PTR <= std_logic_vector(c_ptr);

    CPL_POP <= '1' when (cst = CS_IDLE and CPL_VLD = '1') else '0';

    out_last <= '1' when (w_idx = eof_word) else '0';

    cc_fsm_p : process (CLK)
        variable a0_v   : unsigned(5-1 downto 0);
        variable end_v  : unsigned(12-1 downto 0);
        variable hi_v   : unsigned(6-1 downto 0);
        variable last_v : unsigned(6-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            NP_DONE <= '0';

            case cst is
                when CS_IDLE =>
                    if (CPL_VLD = '1') then
                        c_desc <= CPL_DESC;
                        c_seg  <= (others => '0');
                        s_bc   <= unsigned(CPL_DESC(NPD_BC));
                        s_la   <= CPL_DESC(NPD_LA);
                        s_dw   <= (others => '0');
                        if (CPL_DESC(NPD_UR_O) = '1') then
                            cst <= CS_BUILD;
                        else
                            cst <= CS_SEG;
                        end if;
                    end if;

                when CS_SEG =>
                    a0_v  := unsigned(c_desc(NPD_ADDR_O+7-1 downto NPD_ADDR_O+2));
                    end_v := resize(a0_v, 12) + resize(unsigned(c_desc(NPD_DW)), 12) - 1;
                    if (c_seg = unsigned(c_desc(NPD_NCH)) - 1) then
                        hi_v   := resize(end_v(5-1 downto 0), 6) + 1;
                        s_last <= '1';
                    else
                        hi_v   := to_unsigned(CHUNK_DWS, 6);
                        s_last <= '0';
                    end if;
                    if (c_seg = 0) then
                        s_lo   <= a0_v;
                        s_dw   <= hi_v - resize(a0_v, 6);
                        s_bc   <= unsigned(c_desc(NPD_BC));
                        s_la   <= c_desc(NPD_LA);
                    else
                        s_lo   <= (others => '0');
                        s_dw   <= hi_v;
                        s_bc   <= unsigned(c_desc(NPD_ENDO)) - shift_left(resize(c_seg, NPD_BC_W), 7);
                        s_la   <= (others => '0');
                    end if;
                    cst <= CS_WAIT;

                when CS_WAIT =>
                    ld_iss <= (others => '0');
                    ld_cap <= (others => '0');
                    if (unsigned(R_CHUNK_PTR) /= c_ptr) then
                        cst <= CS_LOAD;
                    end if;

                when CS_LOAD =>
                    if (ld_iss < WPC) then
                        ld_iss <= ld_iss + 1;
                    end if;
                    if (BUF_RD_VLD = '1') then
                        chunk_r(to_integer(ld_cap(WPCB-1 downto 0))) <= BUF_RD_DATA;
                        ld_cap                                       <= ld_cap + 1;
                        if (ld_cap = WPC-1) then
                            cst <= CS_BUILD;
                        end if;
                    end if;

                when CS_BUILD =>
                    last_v   := s_dw + 2;
                    tlp_r    <= tlp_words;
                    eof_word <= resize(last_v(6-1 downto ODWB), WIDX_W);
                    eof_rgn  <= resize(last_v(ODWB-1 downto RIB), eof_rgn'length);
                    eof_pos  <= resize(last_v(RIB-1 downto 0), EOFP_W);
                    w_idx    <= (others => '0');
                    cst      <= CS_SEND;

                when CS_SEND =>
                    if (out_dst_rdy = '1') then
                        if (out_last = '1') then
                            if (c_ur = '0') then
                                c_ptr <= c_ptr + 1;
                            end if;
                            if (c_ur = '1' or s_last = '1') then
                                NP_DONE <= '1';
                                cst     <= CS_IDLE;
                            else
                                c_seg <= c_seg + 1;
                                cst   <= CS_SEG;
                            end if;
                        else
                            w_idx <= w_idx + 1;
                        end if;
                    end if;
            end case;

            if (RESET = '1') then
                cst     <= CS_IDLE;
                c_ptr   <= (others => '0');
                NP_DONE <= '0';
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- TLP assembly: header DW0-2, segment DWs rotated down to DW3
    -- =============================================================================================

    chunk_dw_g : for d in 0 to CHUNK_DWS-1 generate
        chunk_dw(d) <= chunk_r(d / LW)((d mod LW)*32+31 downto (d mod LW)*32);
    end generate;

    cc_status <= "001" when (c_ur = '1') else "000";

    cc_hdr_gen_i : entity work.PCIE_CC_HDR_GEN
    generic map (
        DEVICE => DEVICE
    )
    port map (
        IN_LOWER_ADDR   => s_la,
        IN_BYTE_CNT     => std_logic_vector(s_bc),
        IN_DW_CNT       => std_logic_vector(resize(s_dw, 11)),
        IN_COMP_ST      => cc_status,
        IN_REQ_ID       => c_desc(NPD_RID),
        IN_TAG          => "00" & c_desc(NPD_TAG),
        IN_TC           => c_desc(NPD_TC),
        IN_ATTRIBUTES   => c_desc(NPD_ATTR),
        IN_ADDRESS_TYPE => c_desc(NPD_AT),
        IN_META_FUNC_ID => c_desc(NPD_FUNC),
        IN_BUS_NUM      => (others => '0'),
        COMP_WITH_DATA  => not c_ur,
        OUT_HEADER      => hdr
    );

    tlp_dw_g : for p in 0 to NWMAX*ODW-1 generate
        tlp_hdr_g : if (p < 3) generate
            tlp_dw(p) <= hdr(p*32+31 downto p*32);
        elsif (p < TLP_DWS) generate
            tlp_dw(p) <= chunk_dw(to_integer(s_lo + to_unsigned(p-3, 5)));
        else generate
            tlp_dw(p) <= (others => '0');
        end generate;
    end generate;

    tlp_words_g : for k in 0 to NWMAX-1 generate
        tlp_pack_g : for i in 0 to ODW-1 generate
            tlp_words(k)(i*32+31 downto i*32) <= tlp_dw(k*ODW+i);
        end generate;
    end generate;

    -- =============================================================================================
    -- CC MFB output
    -- =============================================================================================

    out_data    <= tlp_r(to_integer(w_idx));
    out_src_rdy <= '1' when (cst = CS_SEND) else '0';

    out_rgn_g : for r in 0 to MFB_REGIONS-1 generate
        out_sof(r)     <= '1' when (r = 0 and w_idx = 0) else '0';
        out_eof(r)     <= '1' when (out_last = '1' and eof_rgn = r) else '0';
        out_eof_pos(r) <= std_logic_vector(eof_pos);

        out_meta_hdr_g : if (r = 0) generate
            out_meta(r) <= (PCIE_CC_META_WIDTH-1 downto PCIE_CC_META_HEADER_O+PCIE_META_CPL_HDR_W => '0') & hdr;
        else generate
            out_meta(r) <= (others => '0');
        end generate;
    end generate;

    cc_pipe_i : entity work.MFB_PIPE
    generic map (
        REGIONS     => MFB_REGIONS,
        REGION_SIZE => MFB_REGION_SIZE,
        BLOCK_SIZE  => MFB_BLOCK_SIZE,
        ITEM_WIDTH  => MFB_ITEM_WIDTH,
        META_WIDTH  => PCIE_CC_META_WIDTH,
        FAKE_PIPE   => false,
        USE_DST_RDY => true,
        PIPE_TYPE   => "REG",
        DEVICE      => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RESET,

        RX_DATA    => out_data,
        RX_META    => slv_array_ser(out_meta),
        RX_SOF_POS => (others => '0'),
        RX_EOF_POS => slv_array_ser(out_eof_pos),
        RX_SOF     => out_sof,
        RX_EOF     => out_eof,
        RX_SRC_RDY => out_src_rdy,
        RX_DST_RDY => out_dst_rdy,

        TX_DATA    => CC_MFB_DATA,
        TX_META    => CC_MFB_META,
        TX_SOF_POS => CC_MFB_SOF_POS,
        TX_EOF_POS => CC_MFB_EOF_POS,
        TX_SOF     => CC_MFB_SOF,
        TX_EOF     => CC_MFB_EOF,
        TX_SRC_RDY => CC_MFB_SRC_RDY,
        TX_DST_RDY => CC_MFB_DST_RDY
    );

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================

    chunk_early <= '1' when (cst = CS_LOAD and unsigned(R_CHUNK_PTR) = c_ptr) else '0';

    seg_len_bad <= '1' when (s_dw = 0 or resize(s_lo, 7) + s_dw > CHUNK_DWS) else '0';
    seg_bad     <= '1' when (cst = CS_SEND and c_ur = '0' and seg_len_bad = '1') else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl assert_chunk_filled_before_load : assert always
    --     (RESET = '0' -> chunk_early = '0')
    --     report "PCIE_BAR2AXI_CC: chunk read from the buffer before all its R data arrived";

    -- psl assert_seg_in_chunk : assert always
    --     (RESET = '0' -> seg_bad = '0')
    --     report "PCIE_BAR2AXI_CC: completion segment empty or crossing a 128 B boundary";

end architecture;
