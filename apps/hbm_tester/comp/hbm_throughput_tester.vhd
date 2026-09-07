-- hbm_throughput_tester.vhd: sustained AXI3 traffic generator and beat counters for HBM ports
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- Measures what an HBM pseudo-channel delivers: back-to-back INCR bursts, beats vs cycles, in the
-- HBM port clock domain. Per-channel accepted/stalled counters name the refusing channel;
-- read+write together exposes the turnaround mixed traffic pays.
entity HBM_THROUGHPUT_TESTER is
    generic (
        -- MI bus width
        MI_WIDTH        : natural := 32;
        -- HBM AXI ports driven concurrently. Each is an independent generator, so PORTS=1 measures
        -- one pseudo-channel and PORTS=2 measures whether two scale.
        PORTS           : natural := 2;
        -- AXI3 field widths, mirroring the HBM IP's per-port interface.
        HBM_ADDR_WIDTH  : natural := 34;
        HBM_DATA_WIDTH  : natural := 256;
        HBM_ID_WIDTH    : natural := 6;
        HBM_LEN_WIDTH   : natural := 4;
        HBM_SIZE_WIDTH  : natural := 3;
        HBM_BURST_WIDTH : natural := 2;
        HBM_RESP_WIDTH  : natural := 2;
        -- Bursts in flight per port per direction. Deep enough that the port's own latency is
        -- covered and the measurement reports bandwidth rather than round-trip time.
        MAX_OUTSTANDING : natural := 24
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- ==== MI slave -- already in this entity's clock domain (core_logic crosses it with MI_ASYNC) ====
        MI_DWR  : in  std_logic_vector(MI_WIDTH-1 downto 0);
        MI_ADDR : in  std_logic_vector(MI_WIDTH-1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8-1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_ARDY : out std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH-1 downto 0);
        MI_DRDY : out std_logic;

        -- =========================================================================================
        -- AXI3 write masters, one group per port
        -- =========================================================================================
        AXI_AWADDR  : out slv_array_t(PORTS-1 downto 0)(HBM_ADDR_WIDTH-1 downto 0);
        AXI_AWID    : out slv_array_t(PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        AXI_AWLEN   : out slv_array_t(PORTS-1 downto 0)(HBM_LEN_WIDTH-1 downto 0);
        AXI_AWSIZE  : out slv_array_t(PORTS-1 downto 0)(HBM_SIZE_WIDTH-1 downto 0);
        AXI_AWBURST : out slv_array_t(PORTS-1 downto 0)(HBM_BURST_WIDTH-1 downto 0);
        AXI_AWVALID : out std_logic_vector(PORTS-1 downto 0);
        AXI_AWREADY : in  std_logic_vector(PORTS-1 downto 0);

        AXI_WDATA  : out slv_array_t(PORTS-1 downto 0)(HBM_DATA_WIDTH-1 downto 0);
        AXI_WSTRB  : out slv_array_t(PORTS-1 downto 0)(HBM_DATA_WIDTH/8-1 downto 0);
        AXI_WLAST  : out std_logic_vector(PORTS-1 downto 0);
        AXI_WVALID : out std_logic_vector(PORTS-1 downto 0);
        AXI_WREADY : in  std_logic_vector(PORTS-1 downto 0);

        AXI_BID    : in  slv_array_t(PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        AXI_BRESP  : in  slv_array_t(PORTS-1 downto 0)(HBM_RESP_WIDTH-1 downto 0);
        AXI_BVALID : in  std_logic_vector(PORTS-1 downto 0);
        AXI_BREADY : out std_logic_vector(PORTS-1 downto 0);

        -- =========================================================================================
        -- AXI3 read masters, one group per port
        -- =========================================================================================
        AXI_ARADDR  : out slv_array_t(PORTS-1 downto 0)(HBM_ADDR_WIDTH-1 downto 0);
        AXI_ARID    : out slv_array_t(PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        AXI_ARLEN   : out slv_array_t(PORTS-1 downto 0)(HBM_LEN_WIDTH-1 downto 0);
        AXI_ARSIZE  : out slv_array_t(PORTS-1 downto 0)(HBM_SIZE_WIDTH-1 downto 0);
        AXI_ARBURST : out slv_array_t(PORTS-1 downto 0)(HBM_BURST_WIDTH-1 downto 0);
        AXI_ARVALID : out std_logic_vector(PORTS-1 downto 0);
        AXI_ARREADY : in  std_logic_vector(PORTS-1 downto 0);

        AXI_RDATA  : in  slv_array_t(PORTS-1 downto 0)(HBM_DATA_WIDTH-1 downto 0);
        AXI_RID    : in  slv_array_t(PORTS-1 downto 0)(HBM_ID_WIDTH-1 downto 0);
        AXI_RRESP  : in  slv_array_t(PORTS-1 downto 0)(HBM_RESP_WIDTH-1 downto 0);
        AXI_RLAST  : in  std_logic_vector(PORTS-1 downto 0);
        AXI_RVALID : in  std_logic_vector(PORTS-1 downto 0);
        AXI_RREADY : out std_logic_vector(PORTS-1 downto 0)
    );
end entity;

architecture FULL of HBM_THROUGHPUT_TESTER is

    constant BEAT_BYTES : natural := HBM_DATA_WIDTH/8;
    constant CNT_W      : natural := 48;
    constant OUTST_W    : natural := log2(MAX_OUTSTANDING)+1;

    -- Register map, byte offsets. Counters are 48 b, read as a low and a high word.
    constant A_CTRL       : natural := 16#00#;
    constant A_STATUS     : natural := 16#04#;
    constant A_BURST_LEN  : natural := 16#08#;
    constant A_PORT_EN    : natural := 16#0C#;
    constant A_ADDR_MASK  : natural := 16#10#;
    -- Per-port counter block: A_CNT_BASE + port*A_CNT_STRIDE + field.
    constant A_CNT_BASE   : natural := 16#40#;
    constant A_CNT_STRIDE : natural := 16#20#;

    -- CTRL bits
    constant C_RUN   : natural := 0;
    constant C_CLR   : natural := 1;
    constant C_RD_EN : natural := 2;
    constant C_WR_EN : natural := 3;

    signal run_r       : std_logic;
    signal rd_en_r     : std_logic;
    signal wr_en_r     : std_logic;
    signal burst_len_r : unsigned(HBM_LEN_WIDTH-1 downto 0);
    signal port_en_r   : std_logic_vector(PORTS-1 downto 0);
    signal addr_mask_r : unsigned(HBM_ADDR_WIDTH-1 downto 0);
    signal clr_s       : std_logic;

    -- Per-port generator state
    signal ar_addr_r  : slv_array_t(PORTS-1 downto 0)(HBM_ADDR_WIDTH-1 downto 0);
    signal aw_addr_r  : slv_array_t(PORTS-1 downto 0)(HBM_ADDR_WIDTH-1 downto 0);
    signal ar_outst_r : u_array_t(PORTS-1 downto 0)(OUTST_W-1 downto 0);
    signal aw_outst_r : u_array_t(PORTS-1 downto 0)(OUTST_W-1 downto 0);
    signal w_left_r   : u_array_t(PORTS-1 downto 0)(HBM_LEN_WIDTH downto 0);
    signal w_active_r : std_logic_vector(PORTS-1 downto 0);
    signal wdata_r    : u_array_t(PORTS-1 downto 0)(HBM_DATA_WIDTH-1 downto 0);

    -- Counters: cycles the run was armed, beats accepted, and handshakes the port refused.
    signal cyc_cnt_r  : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal rb_cnt_r   : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal wb_cnt_r   : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal ars_cnt_r  : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal aws_cnt_r  : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal ws_cnt_r   : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal rdry_cnt_r : u_array_t(PORTS-1 downto 0)(CNT_W-1 downto 0);
    signal err_r      : std_logic_vector(PORTS-1 downto 0);

    signal ar_fire_s : std_logic_vector(PORTS-1 downto 0);
    signal aw_fire_s : std_logic_vector(PORTS-1 downto 0);
    signal w_fire_s  : std_logic_vector(PORTS-1 downto 0);
    signal r_fire_s  : std_logic_vector(PORTS-1 downto 0);
    signal arvalid_s : std_logic_vector(PORTS-1 downto 0);
    signal awvalid_s : std_logic_vector(PORTS-1 downto 0);
    signal wvalid_s  : std_logic_vector(PORTS-1 downto 0);

    signal mi_addr_u : unsigned(MI_WIDTH-1 downto 0);
    signal mi_drd_r  : std_logic_vector(MI_WIDTH-1 downto 0);
    signal mi_drdy_r : std_logic;

begin

    assert (HBM_DATA_WIDTH = 256)
        report "HBM_THROUGHPUT_TESTER: the HBM port is 256 b; the beat accounting assumes it."
        severity FAILURE;

    MI_ARDY <= '1';
    MI_DRD  <= mi_drd_r;
    MI_DRDY <= mi_drdy_r;

    mi_addr_u <= unsigned(MI_ADDR);
    clr_s     <= '1' when (MI_WR = '1' and to_integer(mi_addr_u(11 downto 0)) = A_CTRL
                            and MI_DWR(C_CLR) = '1') else
                 '0';

    -- =============================================================================================
    -- Control registers
    -- =============================================================================================
    ctrl_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (RST = '1') then
                run_r       <= '0';
                rd_en_r     <= '1';
                wr_en_r     <= '0';
                burst_len_r <= (others => '1');
                port_en_r   <= (others => '1');
                addr_mask_r <= (others => '1');
            elsif (MI_WR = '1') then
                case to_integer(mi_addr_u(11 downto 0)) is
                    when A_CTRL =>
                        run_r   <= MI_DWR(C_RUN);
                        rd_en_r <= MI_DWR(C_RD_EN);
                        wr_en_r <= MI_DWR(C_WR_EN);
                    when A_BURST_LEN =>
                        burst_len_r <= unsigned(MI_DWR(HBM_LEN_WIDTH-1 downto 0));
                    when A_PORT_EN =>
                        port_en_r <= MI_DWR(PORTS-1 downto 0);
                    when A_ADDR_MASK =>
                        -- Byte-address span the generator walks before wrapping, as a mask. The
                        -- default covers the whole pseudo-channel; a small mask keeps the traffic
                        -- inside one DRAM page and separates page-hit rate from raw bandwidth.
                        addr_mask_r <= resize(unsigned(MI_DWR), HBM_ADDR_WIDTH);
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- MI read-back
    -- =============================================================================================
    mi_rd_p : process (CLK) is
        variable idx_v   : natural;
        variable field_v : natural;
        variable cnt_v   : unsigned(CNT_W-1 downto 0);
    begin
        if (rising_edge(CLK)) then
            mi_drdy_r <= MI_RD;
            mi_drd_r  <= (others => '0');

            if (to_integer(mi_addr_u(11 downto 0)) < A_CNT_BASE) then
                case to_integer(mi_addr_u(11 downto 0)) is
                    when A_CTRL =>
                        mi_drd_r(C_RUN)   <= run_r;
                        mi_drd_r(C_RD_EN) <= rd_en_r;
                        mi_drd_r(C_WR_EN) <= wr_en_r;
                    when A_STATUS =>
                        mi_drd_r(PORTS-1 downto 0) <= err_r;
                    when A_BURST_LEN =>
                        mi_drd_r(HBM_LEN_WIDTH-1 downto 0) <= std_logic_vector(burst_len_r);
                    when A_PORT_EN =>
                        mi_drd_r(PORTS-1 downto 0) <= port_en_r;
                    when others =>
                        null;
                end case;
            else
                idx_v   := (to_integer(mi_addr_u(11 downto 0)) - A_CNT_BASE) / A_CNT_STRIDE;
                field_v := (to_integer(mi_addr_u(11 downto 0)) - A_CNT_BASE) mod A_CNT_STRIDE;
                if (idx_v < PORTS) then
                    case field_v / 4 is
                        when 0 | 1 => cnt_v := cyc_cnt_r(idx_v);
                        when 2 | 3 => cnt_v := rb_cnt_r(idx_v);
                        when 4 | 5 => cnt_v := wb_cnt_r(idx_v);
                        when 6     => cnt_v := ars_cnt_r(idx_v);
                        when 7     => cnt_v := aws_cnt_r(idx_v);
                        when others => cnt_v := (others => '0');
                    end case;
                    -- Even word = low 32 b, odd word = the rest. A 48 b counter at 450 MHz wraps
                    -- after ~15 hours, far beyond any run.
                    if ((field_v / 4) mod 2 = 0 and (field_v / 4) < 6) then
                        mi_drd_r <= std_logic_vector(cnt_v(MI_WIDTH-1 downto 0));
                    elsif ((field_v / 4) < 6) then
                        mi_drd_r <= std_logic_vector(resize(cnt_v(CNT_W-1 downto MI_WIDTH), MI_WIDTH));
                    else
                        mi_drd_r <= std_logic_vector(cnt_v(MI_WIDTH-1 downto 0));
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- One independent generator per port
    -- =============================================================================================
    port_g : for p in 0 to PORTS-1 generate

        -- Hold AR/AW asserted whenever the run is armed and the port has credit; the port's own
        -- READY is what paces the burst rate, which is the quantity being measured.
        arvalid_s(p) <= '1' when (RST = '0' and run_r = '1' and rd_en_r = '1' and port_en_r(p) = '1'
                                   and ar_outst_r(p) < MAX_OUTSTANDING) else
                        '0';
        awvalid_s(p) <= '1' when (RST = '0' and run_r = '1' and wr_en_r = '1' and port_en_r(p) = '1'
                                   and aw_outst_r(p) < MAX_OUTSTANDING and w_active_r(p) = '0') else
                        '0';
        wvalid_s(p)  <= '1' when (RST = '0' and w_active_r(p) = '1') else
                        '0';

        ar_fire_s(p) <= arvalid_s(p) and AXI_ARREADY(p);
        aw_fire_s(p) <= awvalid_s(p) and AXI_AWREADY(p);
        w_fire_s(p)  <= wvalid_s(p) and AXI_WREADY(p);
        r_fire_s(p)  <= AXI_RVALID(p) and run_r;

        AXI_ARVALID(p) <= arvalid_s(p);
        AXI_AWVALID(p) <= awvalid_s(p);
        AXI_WVALID(p)  <= wvalid_s(p);
        AXI_RREADY(p)  <= '1';
        AXI_BREADY(p)  <= '1';

        AXI_ARADDR(p)  <= ar_addr_r(p);
        AXI_AWADDR(p)  <= aw_addr_r(p);
        AXI_ARID(p)    <= (others => '0');
        AXI_AWID(p)    <= (others => '0');
        AXI_ARLEN(p)   <= std_logic_vector(burst_len_r);
        AXI_AWLEN(p)   <= std_logic_vector(burst_len_r);
        AXI_ARSIZE(p)  <= "101";
        AXI_AWSIZE(p)  <= "101";
        AXI_ARBURST(p) <= "01";
        AXI_AWBURST(p) <= "01";
        AXI_WSTRB(p)   <= (others => '1');
        AXI_WDATA(p)   <= std_logic_vector(wdata_r(p));
        AXI_WLAST(p)   <= '1' when (w_left_r(p) = 1) else
                          '0';

        gen_p : process (CLK) is
            variable step_v : unsigned(HBM_ADDR_WIDTH-1 downto 0);
        begin
            if (rising_edge(CLK)) then
                -- Bytes one burst covers. Address advances by exactly this, so a burst is always
                -- aligned to its own length and can never cross the AXI 4 KB boundary.
                step_v := to_unsigned((to_integer(burst_len_r) + 1) * BEAT_BYTES, HBM_ADDR_WIDTH);

                if (RST = '1') then
                    ar_addr_r(p)  <= (others => '0');
                    aw_addr_r(p)  <= (others => '0');
                    ar_outst_r(p) <= (others => '0');
                    aw_outst_r(p) <= (others => '0');
                    w_left_r(p)   <= (others => '0');
                    w_active_r(p) <= '0';
                    wdata_r(p)    <= (others => '0');
                else
                    if (ar_fire_s(p) = '1') then
                        ar_addr_r(p) <= std_logic_vector((unsigned(ar_addr_r(p)) + step_v) and addr_mask_r);
                    end if;
                    if (aw_fire_s(p) = '1') then
                        aw_addr_r(p)  <= std_logic_vector((unsigned(aw_addr_r(p)) + step_v) and addr_mask_r);
                        w_active_r(p) <= '1';
                        w_left_r(p)   <= resize(burst_len_r, HBM_LEN_WIDTH+1) + 1;
                    end if;

                    -- Outstanding credit: one per issued burst, returned on RLAST / BVALID.
                    if (ar_fire_s(p) = '1' and not (AXI_RVALID(p) = '1' and AXI_RLAST(p) = '1')) then
                        ar_outst_r(p) <= ar_outst_r(p) + 1;
                    elsif (ar_fire_s(p) = '0' and AXI_RVALID(p) = '1' and AXI_RLAST(p) = '1') then
                        ar_outst_r(p) <= ar_outst_r(p) - 1;
                    end if;
                    if (aw_fire_s(p) = '1' and AXI_BVALID(p) = '0') then
                        aw_outst_r(p) <= aw_outst_r(p) + 1;
                    elsif (aw_fire_s(p) = '0' and AXI_BVALID(p) = '1' and aw_outst_r(p) /= 0) then
                        aw_outst_r(p) <= aw_outst_r(p) - 1;
                    end if;

                    if (w_fire_s(p) = '1') then
                        wdata_r(p) <= wdata_r(p) + 1;
                        if (w_left_r(p) = 1) then
                            w_active_r(p) <= '0';
                            w_left_r(p)   <= (others => '0');
                        else
                            w_left_r(p) <= w_left_r(p) - 1;
                        end if;
                    end if;
                end if;
            end if;
        end process;

        cnt_p : process (CLK) is
        begin
            if (rising_edge(CLK)) then
                if (RST = '1' or clr_s = '1') then
                    cyc_cnt_r(p)  <= (others => '0');
                    rb_cnt_r(p)   <= (others => '0');
                    wb_cnt_r(p)   <= (others => '0');
                    ars_cnt_r(p)  <= (others => '0');
                    aws_cnt_r(p)  <= (others => '0');
                    ws_cnt_r(p)   <= (others => '0');
                    rdry_cnt_r(p) <= (others => '0');
                    err_r(p)      <= '0';
                else
                    if (run_r = '1') then
                        cyc_cnt_r(p) <= cyc_cnt_r(p) + 1;
                    end if;
                    if (r_fire_s(p) = '1') then
                        rb_cnt_r(p) <= rb_cnt_r(p) + 1;
                    end if;
                    if (w_fire_s(p) = '1') then
                        wb_cnt_r(p) <= wb_cnt_r(p) + 1;
                    end if;
                    -- Refused handshakes: the port had work offered and did not take it. This is
                    -- what a rate alone cannot say -- which channel the pseudo-channel throttled.
                    if (arvalid_s(p) = '1' and AXI_ARREADY(p) = '0') then
                        ars_cnt_r(p) <= ars_cnt_r(p) + 1;
                    end if;
                    if (awvalid_s(p) = '1' and AXI_AWREADY(p) = '0') then
                        aws_cnt_r(p) <= aws_cnt_r(p) + 1;
                    end if;
                    if (wvalid_s(p) = '1' and AXI_WREADY(p) = '0') then
                        ws_cnt_r(p) <= ws_cnt_r(p) + 1;
                    end if;
                    if (run_r = '1' and rd_en_r = '1' and AXI_RVALID(p) = '0') then
                        rdry_cnt_r(p) <= rdry_cnt_r(p) + 1;
                    end if;
                    if ((AXI_RVALID(p) = '1' and AXI_RRESP(p) /= "00") or
                        (AXI_BVALID(p) = '1' and AXI_BRESP(p) /= "00")) then
                        err_r(p) <= '1';
                    end if;
                end if;
            end if;
        end process;

    end generate;

end architecture;
