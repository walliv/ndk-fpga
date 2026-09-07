-- mi_addr_space_pkg.vhd: Package with MI address space definition
-- Copyright (C) 2021 CESNET z. s. p. o.
-- Author(s): Jakub Cabal <cabal@cesnet.cz>
--
-- SPDX-License-Identifier: BSD-3-Clause
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.type_pack.all;

package mi_addr_space_pack is

    -- Number of output MI ports
    constant MI_ADC_PORTS : natural := 8;

    -- NOTE: MI_SPLITTER_PLUS_GEN requires ADDR_BASE to be ascending with the port index, so the
    -- port numbering must follow the address order (HBM_DBG at 0x6000 sits between GENLOOP and
    -- the DMA controller).
    constant MI_ADC_PORT_TEST    : natural := 0;
    constant MI_ADC_PORT_SENSOR  : natural := 1;
    constant MI_ADC_PORT_BOOT    : natural := 2;
    constant MI_ADC_PORT_GENLOOP : natural := 3;
    constant MI_ADC_PORT_HBM_DBG : natural := 4;
    constant MI_ADC_PORT_DMA     : natural := 5;
    constant MI_ADC_PORT_PCI_DBG : natural := 6;
    constant MI_ADC_PORT_USERAPP : natural := 7;

    -- Address Space definition
    constant MI_ADC_ADDR_BASE : slv_array_t(MI_ADC_PORTS-1 downto 0)(32-1 downto 0) :=
        (MI_ADC_PORT_TEST    => X"0000_0000",   -- Test space (debug R/W registers)
         MI_ADC_PORT_SENSOR  => X"0000_1000",   -- SDM/SYSMON controller
         MI_ADC_PORT_BOOT    => X"0000_2000",   -- BOOT controller
         MI_ADC_PORT_GENLOOP => X"0000_5000",   -- Debug GLS modules
         MI_ADC_PORT_HBM_DBG => X"0000_6000",   -- HBM smoke-test debug registers
         MI_ADC_PORT_DMA     => X"0100_0000",   -- DMA controller
         MI_ADC_PORT_PCI_DBG => X"0140_0000",   -- PCIe Debug space
         MI_ADC_PORT_USERAPP => X"0200_0000");  -- Application
end package;

package body mi_addr_space_pack is
end package body;
