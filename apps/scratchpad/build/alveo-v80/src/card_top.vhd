-- card_top.vhd: Alveo V80 board top level of the scratchpad application
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.combo_user_const.all;

-- Only the PCIe lanes, their reference clocks and the HBM reference clock reach the fabric; PERST# and the PMC boot pins belong to the CIPS. RX/TX bits 7:0 are endpoint 0 (CPM5 controller 1), 15:8 endpoint 1.
entity CARD_TOP is
    port (
        -- PCIe reference clocks, 100 MHz: SYSCLK0 for endpoint 0 (GTYP Quad 104), SYSCLK1 for endpoint 1 (Quad 102)
        PCIE_SYSCLK0_P : in  std_logic;
        PCIE_SYSCLK0_N : in  std_logic;
        PCIE_SYSCLK1_P : in  std_logic;
        PCIE_SYSCLK1_N : in  std_logic;

        PCIE_RX_P      : in  std_logic_vector(PCIE_LANES-1 downto 0);
        PCIE_RX_N      : in  std_logic_vector(PCIE_LANES-1 downto 0);
        PCIE_TX_P      : out std_logic_vector(PCIE_LANES-1 downto 0);
        PCIE_TX_N      : out std_logic_vector(PCIE_LANES-1 downto 0);

        -- HBM stack 0 reference clock, 200 MHz
        HBM_REFCLK0_P  : in  std_logic;
        HBM_REFCLK0_N  : in  std_logic
    );
end entity;

architecture FULL of CARD_TOP is

    constant PCIE_CONS : natural := 1;
    constant DEVICE    : string  := "VERSAL";

    signal pcie_sysclk_p : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_sysclk_n : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

begin

    pcie_sysclk_p <= PCIE_SYSCLK1_P & PCIE_SYSCLK0_P;
    pcie_sysclk_n <= PCIE_SYSCLK1_N & PCIE_SYSCLK0_N;

    core_logic_i : entity work.CORE_LOGIC
    generic map (
        DEVICE             => DEVICE,
        PCIE_GEN           => PCIE_GEN,
        PCIE_CONS          => PCIE_CONS,
        PCIE_LANES         => PCIE_LANES,
        PCIE_ENDPOINTS     => PCIE_ENDPOINTS,
        PCIE_MOD_ARCH      => PCIE_MOD_ARCH,
        PCIE_ENDPOINT_MODE => PCIE_ENDPOINT_MODE
    )
    port map (
        PCIE_SYSCLK_P => pcie_sysclk_p,
        PCIE_SYSCLK_N => pcie_sysclk_n,
        PCIE_RX_P     => PCIE_RX_P,
        PCIE_RX_N     => PCIE_RX_N,
        PCIE_TX_P     => PCIE_TX_P,
        PCIE_TX_N     => PCIE_TX_N,

        HBM_REFCLK_P  => HBM_REFCLK0_P,
        HBM_REFCLK_N  => HBM_REFCLK0_N
    );

end architecture;
