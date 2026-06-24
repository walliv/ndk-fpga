-- user_core_full_arch.vhd: End-user application core full architecture
-- Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

library unisim;
use unisim.vcomponents.BUFG;

-- =============================================================================
-- USER TEMPLATE — architecture FULL of USER_CORE
-- =============================================================================
-- This is the entry point for your custom application logic.  Replace the
-- tie-off assignments below by wiring your own IP to the interfaces exposed
-- here.
--
-- Available interfaces
-- --------------------
--   HBM AXI ports 0..30 (31 user-accessible ports)
--     Each port is a full AXI4 master interface.  Port 31 is permanently
--     reserved for DMA_HYPERION and is driven in CORE_LOGIC — do NOT use
--     index 31 here.
--
--   MI register bus (MI_CLK domain)
--     A single MI slave port.  Use MI_SPLITTER_PLUS_GEN to fan it out to
--     multiple sub-cores if needed.
--
-- Clocks and resets
-- -----------------
--   USR_CLK / USR_RST  — application clock (deasserted after MMCM lock)
--   MI_CLK  / MI_RST   — MI bus clock (deasserted after MMCM lock)
--
-- Status inputs (read-only, no driver obligation)
-- ------------------------------------------------
--   HBM_INIT_DONE  — asserted when the HBM calibration is complete; safe to
--                    start HBM transactions only after this is '1'
--   FPGA_ID        — board-unique identifier (MI_CLK domain)
--   FPGA_ID_VLD    — qualifies FPGA_ID
-- =============================================================================

architecture FULL of USER_CORE is

    -- =========================================================================
    -- Internal signals
    -- =========================================================================
    -- Active-low HBM reset buffered through a BUFG.  All 32 HBM port resets
    -- are driven from this single net.  A user may override individual port
    -- resets by routing their own domain reset to the specific port index.
    signal hbm_rst_n_bufg : std_logic;

    -- Registered MI response signals.  The stub below acknowledges every
    -- request in the cycle after it arrives and always returns zero read data.
    signal mi_ardy_reg : std_logic;
    signal mi_drdy_reg : std_logic;

begin

    -- =========================================================================
    -- Clock and reset distribution to HBM ports
    -- =========================================================================
    -- Drive all 32 HBM port clocks from USR_CLK.  The reset is inverted
    -- (HBM uses active-low reset_n) and buffered through a global BUFG to
    -- minimise clock-domain crossing skew on the reset net.
    --
    -- If your custom IP uses a different clock for some ports, replace the
    -- (others => USR_CLK) slice for that specific port index with your clock
    -- and supply a matching reset_n from your domain.

    HBM_AXI_CLK <= (others => USR_CLK);

    rst_bufg_i : component BUFG
    port map (
        I => not USR_RST,
        O => hbm_rst_n_bufg
    );

    HBM_AXI_RESET_N <= (others => hbm_rst_n_bufg);

    -- =========================================================================
    -- HBM AXI tie-offs — safe idle state for all 32 ports
    -- =========================================================================
    -- === CONNECT YOUR CUSTOM IP HERE: drive HBM ports 0..30 ===
    --
    -- Replace the assignments below for ports 0..30 with connections to your
    -- AXI master(s).  Leave port 31 undriven here — it is taken care of in
    -- CORE_LOGIC (reserved for DMA_HYPERION).
    --
    -- Safe idle: all VALID signals held low so no spurious transactions are
    -- issued; BREADY/RREADY held high so any stray response is consumed and
    -- does not stall the bus.

    -- Write-address channel
    HBM_AXI_AWVALID <= (others => '0');
    HBM_AXI_AWID    <= (others => (others => '0'));
    HBM_AXI_AWADDR  <= (others => (others => '0'));
    HBM_AXI_AWLEN   <= (others => (others => '0'));
    HBM_AXI_AWSIZE  <= (others => (others => '0'));
    HBM_AXI_AWBURST <= (others => (others => '0'));

    -- Write-data channel
    HBM_AXI_WVALID       <= (others => '0');
    HBM_AXI_WDATA        <= (others => (others => '0'));
    HBM_AXI_WSTRB        <= (others => (others => '0'));
    HBM_AXI_WDATA_PARITY <= (others => (others => '0'));
    HBM_AXI_WLAST        <= (others => '0');

    -- Write-response channel (always ready to accept responses)
    HBM_AXI_BREADY <= (others => '1');

    -- Read-address channel
    HBM_AXI_ARVALID <= (others => '0');
    HBM_AXI_ARID    <= (others => (others => '0'));
    HBM_AXI_ARADDR  <= (others => (others => '0'));
    HBM_AXI_ARLEN   <= (others => (others => '0'));
    HBM_AXI_ARSIZE  <= (others => (others => '0'));
    HBM_AXI_ARBURST <= (others => (others => '0'));

    -- Read-data channel (always ready to accept read data)
    HBM_AXI_RREADY <= (others => '1');

    -- =========================================================================
    -- MI register interface — inert stub
    -- =========================================================================
    -- === CONNECT YOUR CUSTOM IP HERE: MI register decode ===
    --
    -- Replace this stub with your register-space implementation.  A typical
    -- approach is to instantiate MI_SPLITTER_PLUS_GEN here, fan the bus out
    -- to individual sub-cores, and let each sub-core expose its own control
    -- and status registers.
    --
    -- The stub below:
    --   - acknowledges every request one cycle after arrival (MI_ARDY)
    --   - returns a read-acknowledge one cycle after a read request (MI_DRDY)
    --   - always returns zero on reads (MI_DRD)
    -- This ensures the MI bus is never stalled even with no real registers.

    mi_stub_p : process (MI_CLK) is
    begin
        if rising_edge(MI_CLK) then
            if (MI_RST = '1') then
                mi_ardy_reg <= '0';
                mi_drdy_reg <= '0';
            else
                mi_ardy_reg <= MI_RD or MI_WR;
                mi_drdy_reg <= MI_RD;
            end if;
        end if;
    end process;

    MI_ARDY <= mi_ardy_reg;
    MI_DRDY <= mi_drdy_reg;
    MI_DRD  <= (others => '0');

end architecture;
