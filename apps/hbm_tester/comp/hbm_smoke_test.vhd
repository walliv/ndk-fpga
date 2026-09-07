-- hbm_smoke_test.vhd: MI-driven single-beat AXI3 read/write poke for HBM bring-up
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Lightweight HW-debug scaffolding: an MI-driven single-beat AXI3 master for the HBM ports.
-- Software pokes CTRL to fire one write or read beat at a 34-bit HBM address and reads STATUS/RDATA
-- back, proving read-after-write on silicon.
entity HBM_SMOKE_TEST is
    generic (
        -- MI bus width
        MI_WIDTH         : natural := 32;
        -- Port PORT_SEL resets to, so an untouched design smoke-tests the port the caller actually
        -- wired. Must match core_logic.vhd's HBM_SMOKE_PORT -- a mismatch leaves the reset value
        -- pointing at an unwired port, where only the caller's fallback saves it.
        SMOKE_PORT_DEFAULT : natural := 16;
        -- AXI3 field widths, mirroring the HBM IP's per-port AXI3 interface (see core_logic.vhd)
        HBM_ADDR_WIDTH   : natural := 34;
        HBM_DATA_WIDTH   : natural := 256;
        HBM_ID_WIDTH     : natural := 6;
        HBM_LEN_WIDTH    : natural := 4;
        HBM_SIZE_WIDTH   : natural := 3;
        HBM_BURST_WIDTH  : natural := 2;
        HBM_RESP_WIDTH   : natural := 2
    );
    port (
        CLK : in std_logic;
        RST : in std_logic;

        -- ---- MI slave -------------------------------------------------------------------------
        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_ARDY : out std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DRDY : out std_logic;

        -- HBM IP APB init-complete status, CDC'd into this clock domain by the caller
        HBM_INIT_DONE : in std_logic;

        -- Which HBM AXI port the caller routes this FSM's AXI group onto; unwired selections
        -- fall back to the smoke port. 5 bits, not 4: the IP exposes 32 ports and the smoke port
        -- sits at 16, which a 4-bit selector cannot name.
        PORT_SEL : out std_logic_vector(4 downto 0);

        -- ---- AXI3 master (one HBM port) --------------------------------------------------------
        AXI_AWADDR  : out std_logic_vector(HBM_ADDR_WIDTH -1 downto 0);
        AXI_AWBURST : out std_logic_vector(HBM_BURST_WIDTH -1 downto 0);
        AXI_AWID    : out std_logic_vector(HBM_ID_WIDTH -1 downto 0);
        AXI_AWLEN   : out std_logic_vector(HBM_LEN_WIDTH -1 downto 0);
        AXI_AWSIZE  : out std_logic_vector(HBM_SIZE_WIDTH -1 downto 0);
        AXI_AWVALID : out std_logic;
        AXI_AWREADY : in  std_logic;

        AXI_WDATA        : out std_logic_vector(HBM_DATA_WIDTH -1 downto 0);
        AXI_WDATA_PARITY : out std_logic_vector(HBM_DATA_WIDTH/8 -1 downto 0);
        AXI_WLAST        : out std_logic;
        AXI_WSTRB        : out std_logic_vector(HBM_DATA_WIDTH/8 -1 downto 0);
        AXI_WVALID       : out std_logic;
        AXI_WREADY       : in  std_logic;

        AXI_BID    : in  std_logic_vector(HBM_ID_WIDTH -1 downto 0);
        AXI_BRESP  : in  std_logic_vector(HBM_RESP_WIDTH -1 downto 0);
        AXI_BVALID : in  std_logic;
        AXI_BREADY : out std_logic;

        AXI_ARADDR  : out std_logic_vector(HBM_ADDR_WIDTH -1 downto 0);
        AXI_ARBURST : out std_logic_vector(HBM_BURST_WIDTH -1 downto 0);
        AXI_ARID    : out std_logic_vector(HBM_ID_WIDTH -1 downto 0);
        AXI_ARLEN   : out std_logic_vector(HBM_LEN_WIDTH -1 downto 0);
        AXI_ARSIZE  : out std_logic_vector(HBM_SIZE_WIDTH -1 downto 0);
        AXI_ARVALID : out std_logic;
        AXI_ARREADY : in  std_logic;

        AXI_RDATA        : in  std_logic_vector(HBM_DATA_WIDTH -1 downto 0);
        AXI_RDATA_PARITY : in  std_logic_vector(HBM_DATA_WIDTH/8 -1 downto 0);
        AXI_RID          : in  std_logic_vector(HBM_ID_WIDTH -1 downto 0);
        AXI_RLAST        : in  std_logic;
        AXI_RRESP        : in  std_logic_vector(HBM_RESP_WIDTH -1 downto 0);
        AXI_RVALID       : in  std_logic;
        AXI_RREADY       : out std_logic
    );
end entity;

architecture FULL of HBM_SMOKE_TEST is

    -- MI register map (offset=MI_ADDR(6:2)): 0x00 CTRL(WO) bit0=wr,bit1=rd; 0x04 STATUS(RO)
    -- busy/done,[9:8]=BRESP,[11:10]=RRESP; 0x08/0x0C ADDR_L/ADDR_H(RW) 34-bit addr; 0x10-4C
    -- WDATA0..7(RW)/RDATA0..7(RO) 256-bit beat; 0x50 PORT_SEL(RW) 0..31.

    type wr_state_t is (S_WR_IDLE, S_WR_XFER, S_WR_RESP);
    type rd_state_t is (S_RD_IDLE, S_RD_ADDR, S_RD_DATA);

    signal wr_state : wr_state_t := S_WR_IDLE;
    signal rd_state : rd_state_t := S_RD_IDLE;

    signal aw_pending : std_logic;
    signal w_pending  : std_logic;

    signal wr_busy_r : std_logic;
    signal wr_done_r : std_logic;
    signal bresp_reg : std_logic_vector(HBM_RESP_WIDTH -1 downto 0);

    signal rd_busy_r : std_logic;
    signal rd_done_r : std_logic;
    signal rresp_reg : std_logic_vector(HBM_RESP_WIDTH -1 downto 0);

    signal addr_l_reg   : std_logic_vector(31 downto 0);
    signal addr_h_reg   : std_logic_vector(HBM_ADDR_WIDTH-32 -1 downto 0);
    signal wdata_reg    : std_logic_vector(HBM_DATA_WIDTH -1 downto 0);
    signal rdata_reg    : std_logic_vector(HBM_DATA_WIDTH -1 downto 0);
    signal port_sel_reg : std_logic_vector(4 downto 0);

    signal status_word : std_logic_vector(MI_WIDTH -1 downto 0);

    signal mi_drd_r  : std_logic_vector(MI_WIDTH -1 downto 0);
    signal mi_drdy_r : std_logic;

begin

    -- ---- MI handshake (always-ready ARDY, one-cycle-registered DRD/DRDY) ----------------------
    MI_ARDY <= MI_RD or MI_WR;
    MI_DRD  <= mi_drd_r;
    MI_DRDY <= mi_drdy_r;

    mi_drdy_reg_p : process (CLK)
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                mi_drdy_r <= '0';
            else
                mi_drdy_r <= MI_RD;
            end if;
        end if;
    end process;

    -- ---- MI-side registers (ADDR_L/ADDR_H/WDATA0..7, all plain RW) ----------------------------
    mi_reg_wr_p : process (CLK)
        variable waddr_v : natural range 0 to 31;
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                addr_l_reg   <= (others => '0');
                addr_h_reg   <= (others => '0');
                wdata_reg    <= (others => '0');
                port_sel_reg <= std_logic_vector(to_unsigned(SMOKE_PORT_DEFAULT, port_sel_reg'length));
            elsif (MI_WR = '1') then
                waddr_v := to_integer(unsigned(MI_ADDR(6 downto 2)));
                case waddr_v is
                    when 2      => addr_l_reg <= MI_DWR;
                    when 3      => addr_h_reg <= MI_DWR(addr_h_reg'range);
                    when 4      => wdata_reg(31 downto 0)    <= MI_DWR;
                    when 5      => wdata_reg(63 downto 32)   <= MI_DWR;
                    when 6      => wdata_reg(95 downto 64)   <= MI_DWR;
                    when 7      => wdata_reg(127 downto 96)  <= MI_DWR;
                    when 8      => wdata_reg(159 downto 128) <= MI_DWR;
                    when 9      => wdata_reg(191 downto 160) <= MI_DWR;
                    when 10     => wdata_reg(223 downto 192) <= MI_DWR;
                    when 11     => wdata_reg(255 downto 224) <= MI_DWR;
                    when 20     => port_sel_reg <= MI_DWR(port_sel_reg'range);
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    status_word <= std_logic_vector(to_unsigned(0, MI_WIDTH-12)) & rresp_reg & bresp_reg & "000"
                   & HBM_INIT_DONE & rd_done_r & wr_done_r & rd_busy_r & wr_busy_r;

    mi_reg_rd_p : process (CLK)
        variable raddr_v : natural range 0 to 31;
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                mi_drd_r <= (others => '0');
            else
                raddr_v := to_integer(unsigned(MI_ADDR(6 downto 2)));
                case raddr_v is
                    when 0      => mi_drd_r <= (others => '0');
                    when 1      => mi_drd_r <= status_word;
                    when 2      => mi_drd_r <= addr_l_reg;
                    when 3      => mi_drd_r <= std_logic_vector(resize(unsigned(addr_h_reg), MI_WIDTH));
                    when 4      => mi_drd_r <= wdata_reg(31 downto 0);
                    when 5      => mi_drd_r <= wdata_reg(63 downto 32);
                    when 6      => mi_drd_r <= wdata_reg(95 downto 64);
                    when 7      => mi_drd_r <= wdata_reg(127 downto 96);
                    when 8      => mi_drd_r <= wdata_reg(159 downto 128);
                    when 9      => mi_drd_r <= wdata_reg(191 downto 160);
                    when 10     => mi_drd_r <= wdata_reg(223 downto 192);
                    when 11     => mi_drd_r <= wdata_reg(255 downto 224);
                    when 12     => mi_drd_r <= rdata_reg(31 downto 0);
                    when 13     => mi_drd_r <= rdata_reg(63 downto 32);
                    when 14     => mi_drd_r <= rdata_reg(95 downto 64);
                    when 15     => mi_drd_r <= rdata_reg(127 downto 96);
                    when 16     => mi_drd_r <= rdata_reg(159 downto 128);
                    when 17     => mi_drd_r <= rdata_reg(191 downto 160);
                    when 18     => mi_drd_r <= rdata_reg(223 downto 192);
                    when 19     => mi_drd_r <= rdata_reg(255 downto 224);
                    when 20     => mi_drd_r <= std_logic_vector(resize(unsigned(port_sel_reg), MI_WIDTH));
                    when others => mi_drd_r <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    PORT_SEL <= port_sel_reg;

    -- ---- Fixed AXI3 single-beat field values ---------------------------------------------------
    AXI_AWID    <= (others => '0');
    AXI_AWLEN   <= (others => '0');
    AXI_AWBURST <= std_logic_vector(to_unsigned(1, HBM_BURST_WIDTH));  -- INCR
    AXI_AWSIZE  <= std_logic_vector(to_unsigned(5, HBM_SIZE_WIDTH));   -- 32 B/beat
    AXI_AWADDR  <= addr_h_reg & addr_l_reg;

    AXI_ARID    <= (others => '0');
    AXI_ARLEN   <= (others => '0');
    AXI_ARBURST <= std_logic_vector(to_unsigned(1, HBM_BURST_WIDTH));  -- INCR
    AXI_ARSIZE  <= std_logic_vector(to_unsigned(5, HBM_SIZE_WIDTH));   -- 32 B/beat
    AXI_ARADDR  <= addr_h_reg & addr_l_reg;

    AXI_WDATA        <= wdata_reg;
    AXI_WDATA_PARITY <= (others => '0');
    AXI_WSTRB        <= (others => '1');
    AXI_WLAST        <= AXI_WVALID;

    AXI_BREADY <= '1';
    AXI_RREADY <= '1';

    -- ---- Write FSM: independently track AW/W acceptance (each may land on a different cycle) --
    AXI_AWVALID <= '1' when (wr_state = S_WR_XFER and aw_pending = '1') else '0';
    AXI_WVALID  <= '1' when (wr_state = S_WR_XFER and w_pending = '1') else '0';

    wr_fsm_p : process (CLK)
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                wr_state   <= S_WR_IDLE;
                aw_pending <= '0';
                w_pending  <= '0';
                wr_busy_r  <= '0';
                wr_done_r  <= '0';
                bresp_reg  <= (others => '0');
            else
                case wr_state is
                    when S_WR_IDLE =>
                        if (MI_WR = '1' and MI_ADDR(6 downto 2) = "00000" and MI_DWR(0) = '1') then
                            aw_pending <= '1';
                            w_pending  <= '1';
                            wr_busy_r  <= '1';
                            wr_done_r  <= '0';
                            wr_state   <= S_WR_XFER;
                        end if;

                    when S_WR_XFER =>
                        if (AXI_AWREADY = '1') then
                            aw_pending <= '0';
                        end if;
                        if (AXI_WREADY = '1') then
                            w_pending <= '0';
                        end if;
                        if ((aw_pending = '0' or AXI_AWREADY = '1') and (w_pending = '0' or AXI_WREADY = '1')) then
                            wr_state <= S_WR_RESP;
                        end if;

                    when S_WR_RESP =>
                        if (AXI_BVALID = '1') then
                            bresp_reg <= AXI_BRESP;
                            wr_busy_r <= '0';
                            wr_done_r <= '1';
                            wr_state  <= S_WR_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- ---- Read FSM --------------------------------------------------------------------------
    AXI_ARVALID <= '1' when (rd_state = S_RD_ADDR) else '0';

    rd_fsm_p : process (CLK)
    begin
        if rising_edge(CLK) then
            if (RST = '1') then
                rd_state  <= S_RD_IDLE;
                rd_busy_r <= '0';
                rd_done_r <= '0';
                rresp_reg <= (others => '0');
                rdata_reg <= (others => '0');
            else
                case rd_state is
                    when S_RD_IDLE =>
                        if (MI_WR = '1' and MI_ADDR(6 downto 2) = "00000" and MI_DWR(1) = '1') then
                            rd_busy_r <= '1';
                            rd_done_r <= '0';
                            rd_state  <= S_RD_ADDR;
                        end if;

                    when S_RD_ADDR =>
                        if (AXI_ARREADY = '1') then
                            rd_state <= S_RD_DATA;
                        end if;

                    when S_RD_DATA =>
                        if (AXI_RVALID = '1') then
                            rdata_reg <= AXI_RDATA;
                            rresp_reg <= AXI_RRESP;
                            rd_busy_r <= '0';
                            rd_done_r <= '1';
                            rd_state  <= S_RD_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture;
