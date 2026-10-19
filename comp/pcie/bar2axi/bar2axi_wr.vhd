-- bar2axi_wr.vhd: Write engine of PCIE_BAR2AXI, turns staged MemWr payloads into AXI4 write bursts
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- Stages each MemWr payload rotated onto the AXI lanes and issues it as full-width INCR bursts
-- within 4 KB pages. One AWID keeps B in order; TLP_DONE marks the B of a TLP's last burst.
entity PCIE_BAR2AXI_WR is
    generic (
        AXI_DATA_WIDTH : natural := 512;
        AXI_ADDR_WIDTH : natural := 64;
        AXI_ID_WIDTH   : natural := 1;
        AXI_ID         : natural := 0;
        AXI_CACHE      : std_logic_vector(3 downto 0) := "0010";
        AXI_PROT       : std_logic_vector(2 downto 0) := "000";
        AXI_QOS        : std_logic_vector(3 downto 0) := "0000";
        MAX_WR_BYTES   : natural := 1024;
        -- Maximum of write bursts waiting for their B response, power of 2
        WR_OUTSTANDING : natural := 16
    );
    port (
        CLK   : in  std_logic;
        RESET : in  std_logic;

        -- =========================================================================================
        -- Staging input: 8-DW CQ words, payload from DW4 of the SOF word
        -- =========================================================================================
        ST_VLD   : in  std_logic;
        ST_SOF   : in  std_logic;
        ST_EOF   : in  std_logic;
        ST_DATA  : in  std_logic_vector(256-1 downto 0);
        -- AXI byte address of the first payload DW, valid with ST_SOF
        ST_ADDR  : in  std_logic_vector(64-1 downto 0);
        -- Payload length in DWs, valid with ST_SOF
        ST_DW    : in  std_logic_vector(11-1 downto 0);
        ST_FBE   : in  std_logic_vector(4-1 downto 0);
        ST_LBE   : in  std_logic_vector(4-1 downto 0);
        -- A staging half is free to take a new TLP
        ST_RDY   : out std_logic;

        -- All bursts of the oldest outstanding TLP got their B response
        TLP_DONE : out std_logic;
        -- B response other than OKAY
        ERR_INCR : out std_logic;

        -- =========================================================================================
        -- AXI4 write channels
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
        M_AXI_BREADY  : out std_logic
    );
end entity;

architecture FULL of PCIE_BAR2AXI_WR is

    constant WB         : natural := AXI_DATA_WIDTH/8;
    -- DW lanes of one AXI beat
    constant LW         : natural := WB/4;
    constant LWB        : natural := log2(LW);
    constant AXSIZE     : natural := log2(WB);
    -- Staging rows per half: lane offset + payload + up to 7 DWs written past the payload's end
    constant SROWS      : natural := 2**log2(div_roundup(LW - 1 + MAX_WR_BYTES/4 + 8, LW));
    constant SRW        : natural := log2(SROWS);
    -- DW position inside a staging half
    constant QPOS_W     : natural := SRW + LWB + 1;
    constant PAGE_BEATS : natural := 4096/WB;
    constant BEAT_W     : natural := log2(PAGE_BEATS) + 1;
    constant ROWS_W     : natural := SRW + 1;
    constant BF_W       : natural := log2(WR_OUTSTANDING);

    -- CQ payload DW j lands at position s + j of a half, s being the AXI lane of the TLP's first DW,
    -- so a staging row is directly one AXI beat
    type stg_mem_t is array (0 to 2*SROWS-1) of std_logic_vector(32-1 downto 0);
    type eng_fsm_t is (ES_IDLE, ES_CALC, ES_DATA);

    function bit2nat_f (b : std_logic) return natural is
    begin
        if (b = '1') then
            return 1;
        end if;
        return 0;
    end function;

    -- staging write side
    signal fill_sel     : std_logic;
    signal fill_idx     : natural range 0 to 1;
    signal h_fill       : std_logic_vector(1 downto 0);
    signal h_rdy        : std_logic_vector(1 downto 0);
    signal qpos_r       : unsigned(QPOS_W-1 downto 0);
    signal st_qpos      : unsigned(QPOS_W-1 downto 0);
    signal st_qlane     : unsigned(LWB-1 downto 0);
    signal st_qrow      : unsigned(SRW-1 downto 0);
    signal st_nvld      : unsigned(LWB downto 0);
    signal src_dw       : slv_array_t(0 to 8-1)(32-1 downto 0);

    -- per-half TLP descriptors
    signal d_addr       : slv_array_t(0 to 1)(64-1 downto 0);
    signal d_s          : u_array_t(0 to 1)(LWB-1 downto 0);
    signal d_dw         : u_array_t(0 to 1)(11-1 downto 0);
    signal d_fbe        : slv_array_t(0 to 1)(4-1 downto 0);
    signal d_lbe        : slv_array_t(0 to 1)(4-1 downto 0);

    -- staging read side
    signal bk_dout      : slv_array_t(0 to LW-1)(32-1 downto 0);
    signal eng_raddr    : unsigned(SRW downto 0);
    signal row_data     : std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
    signal row_strb     : std_logic_vector(WB-1 downto 0);

    -- engine
    signal est          : eng_fsm_t;
    signal eng_sel      : std_logic;
    signal eng_idx      : natural range 0 to 1;
    signal eng_release  : std_logic;
    signal e_addr       : unsigned(64-1 downto 0);
    signal e_s          : unsigned(QPOS_W-1 downto 0);
    signal e_sn         : unsigned(QPOS_W-1 downto 0);
    signal e_fbe        : std_logic_vector(4-1 downto 0);
    signal e_lbe        : std_logic_vector(4-1 downto 0);
    signal e_rows_left  : unsigned(ROWS_W-1 downto 0);
    signal e_row        : unsigned(SRW-1 downto 0);
    signal e_beats_left : unsigned(BEAT_W-1 downto 0);
    signal page_left    : unsigned(BEAT_W-1 downto 0);
    signal burst_beats  : unsigned(BEAT_W-1 downto 0);

    signal awvalid_r    : std_logic;
    signal awaddr_r     : unsigned(64-1 downto 0);
    signal awlen_r      : unsigned(8-1 downto 0);
    signal wvalid_r     : std_logic;
    signal wdata_r      : std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
    signal wstrb_r      : std_logic_vector(WB-1 downto 0);
    signal wlast_r      : std_logic;

    -- one flag per issued burst: '1' marks the last burst of its TLP
    signal bf_mem       : std_logic_vector(WR_OUTSTANDING-1 downto 0);
    signal bf_wptr      : unsigned(BF_W-1 downto 0);
    signal bf_rptr      : unsigned(BF_W-1 downto 0);
    signal bf_cnt       : unsigned(BF_W downto 0);
    signal bf_push      : std_logic;
    signal bf_last      : std_logic;
    signal b_hs         : std_logic;

    signal aw_cross_4k  : std_logic;
    signal b_unexpected : std_logic;
    signal stg_overrun  : std_logic;

begin

    assert (AXI_DATA_WIDTH = 256 or AXI_DATA_WIDTH = 512)
        report "PCIE_BAR2AXI_WR: AXI_DATA_WIDTH must be 256 or 512!"
        severity failure;
    assert (WR_OUTSTANDING >= 2 and 2**BF_W = WR_OUTSTANDING)
        report "PCIE_BAR2AXI_WR: WR_OUTSTANDING must be a power of 2 >= 2!"
        severity failure;

    -- =============================================================================================
    -- Staging buffer
    -- =============================================================================================

    fill_idx <= bit2nat_f(fill_sel);
    eng_idx  <= bit2nat_f(eng_sel);

    ST_RDY <= '1' when (h_fill(fill_idx) = '0' and h_rdy(fill_idx) = '0') else '0';

    st_qpos  <= resize(unsigned(ST_ADDR(AXSIZE-1 downto 2)), QPOS_W) when (ST_SOF = '1') else qpos_r;
    st_qlane <= st_qpos(LWB-1 downto 0);
    st_qrow  <= st_qpos(SRW+LWB-1 downto LWB);
    st_nvld  <= to_unsigned(4, LWB+1) when (ST_SOF = '1') else to_unsigned(8, LWB+1);

    src_dw_g : for i in 0 to 8-1 generate
        src_hi_g : if (i < 4) generate
            src_dw(i) <= ST_DATA((i+4)*32+31 downto (i+4)*32) when (ST_SOF = '1') else ST_DATA(i*32+31 downto i*32);
        else generate
            src_dw(i) <= ST_DATA(i*32+31 downto i*32);
        end generate;
    end generate;

    eng_raddr <= eng_sel & e_row;

    stg_bank_g : for b in 0 to LW-1 generate
        signal bank_mem : stg_mem_t;
        signal bk_idx   : unsigned(LWB-1 downto 0);
        signal bk_we    : std_logic;
        signal bk_row   : unsigned(SRW-1 downto 0);
        signal bk_waddr : unsigned(SRW downto 0);
        signal bk_din   : std_logic_vector(32-1 downto 0);
    begin
        -- input DW that falls onto this lane in the current word, modulo LW
        bk_idx   <= to_unsigned(b, LWB) - st_qlane;
        bk_we    <= ST_VLD when (resize(bk_idx, LWB+1) < st_nvld) else '0';
        bk_row   <= st_qrow + 1 when (to_unsigned(b, LWB) < st_qlane) else st_qrow;
        bk_waddr <= fill_sel & bk_row;
        bk_din   <= src_dw(to_integer(bk_idx(3-1 downto 0)));

        bank_wr_p : process (CLK)
        begin
            if (rising_edge(CLK)) then
                if (bk_we = '1') then
                    bank_mem(to_integer(bk_waddr)) <= bk_din;
                end if;
            end if;
        end process;

        bk_dout(b) <= bank_mem(to_integer(eng_raddr));

        row_data(b*32+31 downto b*32) <= bk_dout(b);
    end generate;

    stg_ctrl_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (ST_VLD = '1') then
                qpos_r <= st_qpos + st_nvld;
                if (ST_SOF = '1') then
                    d_addr(fill_idx) <= ST_ADDR;
                    d_s(fill_idx)    <= unsigned(ST_ADDR(AXSIZE-1 downto 2));
                    d_dw(fill_idx)   <= unsigned(ST_DW);
                    d_fbe(fill_idx)  <= ST_FBE;
                    d_lbe(fill_idx)  <= ST_LBE;
                    h_fill(fill_idx) <= '1';
                end if;
                if (ST_EOF = '1') then
                    h_fill(fill_idx) <= '0';
                    h_rdy(fill_idx)  <= '1';
                    fill_sel         <= not fill_sel;
                end if;
            end if;
            -- eng_sel toggled together with eng_release, so the released half is the other one
            if (eng_release = '1') then
                h_rdy(bit2nat_f(not eng_sel)) <= '0';
            end if;
            if (RESET = '1') then
                h_fill   <= (others => '0');
                h_rdy    <= (others => '0');
                fill_sel <= '0';
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Burst generation
    -- =============================================================================================

    -- beats left until the 4 KB page ends
    page_left   <= to_unsigned(PAGE_BEATS, BEAT_W) - resize(e_addr(12-1 downto AXSIZE), BEAT_W);
    burst_beats <= resize(e_rows_left, BEAT_W) when (resize(e_rows_left, BEAT_W) < page_left) else page_left;

    strb_g : for l in 0 to LW-1 generate
        signal pos      : unsigned(QPOS_W-1 downto 0);
        signal in_range : std_logic;
    begin
        pos      <= resize(e_row & to_unsigned(l, LWB), QPOS_W);
        in_range <= '1' when (pos >= e_s and pos < e_sn) else '0';

        row_strb(l*4+3 downto l*4) <= "0000" when (in_range = '0') else
                                      e_fbe  when (pos = e_s) else
                                      e_lbe  when (pos = e_sn - 1) else
                                      "1111";
    end generate;

    eng_p : process (CLK)
        variable rows_v : unsigned(QPOS_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            eng_release <= '0';
            bf_push     <= '0';
            if (M_AXI_AWREADY = '1') then
                awvalid_r <= '0';
            end if;
            if (M_AXI_WREADY = '1') then
                wvalid_r <= '0';
            end if;

            case est is
                when ES_IDLE =>
                    if (h_rdy(eng_idx) = '1' and eng_release = '0') then
                        rows_v      := resize(d_s(eng_idx), QPOS_W) + resize(d_dw(eng_idx), QPOS_W) - 1;
                        e_addr      <= unsigned(d_addr(eng_idx)(64-1 downto AXSIZE)) & to_unsigned(0, AXSIZE);
                        e_s         <= resize(d_s(eng_idx), QPOS_W);
                        e_sn        <= resize(d_s(eng_idx), QPOS_W) + resize(d_dw(eng_idx), QPOS_W);
                        e_fbe       <= d_fbe(eng_idx);
                        e_lbe       <= d_lbe(eng_idx);
                        e_rows_left <= resize(rows_v(QPOS_W-1 downto LWB), ROWS_W) + 1;
                        e_row       <= (others => '0');
                        est         <= ES_CALC;
                    end if;

                when ES_CALC =>
                    if (awvalid_r = '0' and bf_cnt < WR_OUTSTANDING) then
                        awaddr_r     <= e_addr;
                        awlen_r      <= resize(burst_beats - 1, 8);
                        awvalid_r    <= '1';
                        bf_push      <= '1';
                        bf_last      <= '1' when (resize(e_rows_left, BEAT_W) = burst_beats) else '0';
                        e_beats_left <= burst_beats;
                        est          <= ES_DATA;
                    end if;

                when ES_DATA =>
                    if (wvalid_r = '0' or M_AXI_WREADY = '1') then
                        wdata_r      <= row_data;
                        wstrb_r      <= row_strb;
                        wlast_r      <= '1' when (e_beats_left = 1) else '0';
                        wvalid_r     <= '1';
                        e_row        <= e_row + 1;
                        e_addr       <= e_addr + WB;
                        e_rows_left  <= e_rows_left - 1;
                        e_beats_left <= e_beats_left - 1;
                        if (e_beats_left = 1) then
                            if (e_rows_left = 1) then
                                -- last beat sits in the W register, the staging half is free again
                                eng_release <= '1';
                                eng_sel     <= not eng_sel;
                                est         <= ES_IDLE;
                            else
                                est <= ES_CALC;
                            end if;
                        end if;
                    end if;
            end case;

            if (RESET = '1') then
                est         <= ES_IDLE;
                eng_sel     <= '0';
                eng_release <= '0';
                awvalid_r   <= '0';
                wvalid_r    <= '0';
                bf_push     <= '0';
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- B response tracking
    -- =============================================================================================

    b_hs <= M_AXI_BVALID;

    bflag_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            TLP_DONE <= '0';
            ERR_INCR <= '0';
            if (bf_push = '1') then
                bf_mem(to_integer(bf_wptr)) <= bf_last;
                bf_wptr                     <= bf_wptr + 1;
            end if;
            if (b_hs = '1') then
                TLP_DONE <= bf_mem(to_integer(bf_rptr));
                ERR_INCR <= '1' when (M_AXI_BRESP /= "00") else '0';
                bf_rptr  <= bf_rptr + 1;
            end if;
            if (bf_push = '1' and b_hs = '0') then
                bf_cnt <= bf_cnt + 1;
            elsif (bf_push = '0' and b_hs = '1') then
                bf_cnt <= bf_cnt - 1;
            end if;
            if (RESET = '1') then
                bf_wptr  <= (others => '0');
                bf_rptr  <= (others => '0');
                bf_cnt   <= (others => '0');
                TLP_DONE <= '0';
                ERR_INCR <= '0';
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- AXI outputs
    -- =============================================================================================

    M_AXI_AWID    <= std_logic_vector(to_unsigned(AXI_ID, AXI_ID_WIDTH));
    M_AXI_AWADDR  <= std_logic_vector(awaddr_r(AXI_ADDR_WIDTH-1 downto 0));
    M_AXI_AWLEN   <= std_logic_vector(awlen_r);
    M_AXI_AWSIZE  <= std_logic_vector(to_unsigned(AXSIZE, 3));
    M_AXI_AWBURST <= "01";
    M_AXI_AWLOCK  <= '0';
    M_AXI_AWCACHE <= AXI_CACHE;
    M_AXI_AWPROT  <= AXI_PROT;
    M_AXI_AWQOS   <= AXI_QOS;
    M_AXI_AWVALID <= awvalid_r;

    M_AXI_WDATA  <= wdata_r;
    M_AXI_WSTRB  <= wstrb_r;
    M_AXI_WLAST  <= wlast_r;
    M_AXI_WVALID <= wvalid_r;

    M_AXI_BREADY <= '1';

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================

    aw_cross_4k <= '1' when ((resize(awaddr_r(12-1 downto 0), 16) + shift_left(resize(awlen_r, 16) + 1, AXSIZE)) > 4096) else '0';

    b_unexpected <= '1' when (M_AXI_BVALID = '1' and bf_cnt = 0 and bf_push = '0') else '0';

    stg_overrun <= '1' when (ST_VLD = '1' and resize(st_qpos, QPOS_W+1) + st_nvld > SROWS*LW) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl assert_aw_no_4k_cross : assert always
    --     ((RESET = '0' and awvalid_r = '1') -> aw_cross_4k = '0')
    --     report "PCIE_BAR2AXI_WR: AXI write burst crosses a 4 KB boundary";

    -- psl assert_aw_stable : assert always
    --     ((RESET = '0' and awvalid_r = '1' and M_AXI_AWREADY = '0') -> next (awvalid_r = '1'))
    --     report "PCIE_BAR2AXI_WR: AWVALID dropped before AWREADY";

    -- psl assert_w_stable : assert always
    --     ((RESET = '0' and wvalid_r = '1' and M_AXI_WREADY = '0') -> next (wvalid_r = '1'))
    --     report "PCIE_BAR2AXI_WR: WVALID dropped before WREADY";

    -- psl assert_b_expected : assert always
    --     (RESET = '0' -> b_unexpected = '0')
    --     report "PCIE_BAR2AXI_WR: B response without an outstanding write burst";

    -- psl assert_bf_bound : assert always
    --     (RESET = '0' -> bf_cnt <= WR_OUTSTANDING)
    --     report "PCIE_BAR2AXI_WR: more write bursts outstanding than WR_OUTSTANDING";

    -- psl assert_stg_no_overrun : assert always
    --     (RESET = '0' -> stg_overrun = '0')
    --     report "PCIE_BAR2AXI_WR: write payload overruns its staging half";

end architecture;
