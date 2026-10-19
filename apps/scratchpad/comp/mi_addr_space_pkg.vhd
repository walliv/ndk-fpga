-- mi_addr_space_pkg.vhd: MI address space of the scratchpad application
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.type_pack.all;

package mi_addr_space_pack is

    -- Endpoints with a scratchpad status block
    constant MI_ADC_STATUS_EPS : natural := 2;

    -- Number of output MI ports
    constant MI_ADC_PORTS : natural := 2 + MI_ADC_STATUS_EPS;

    -- MI_SPLITTER_PLUS_GEN requires ADDR_BASE to be ascending with the port index
    constant MI_ADC_PORT_TEST    : natural := 0;
    constant MI_ADC_PORT_PCI_DBG : natural := 1;
    constant MI_ADC_PORT_STATUS0 : natural := 2;
    constant MI_ADC_PORT_STATUS1 : natural := 3;
    -- First status port, endpoint ep uses MI_ADC_PORT_STATUS + ep
    constant MI_ADC_PORT_STATUS  : natural := MI_ADC_PORT_STATUS0;

    -- Address offset between the status blocks of two endpoints
    constant MI_ADC_STATUS_OFFSET : natural := 16#100#;

    -- Address Space definition
    constant MI_ADC_ADDR_BASE : slv_array_t(MI_ADC_PORTS-1 downto 0)(32-1 downto 0) :=
        (MI_ADC_PORT_TEST    => X"0000_0000",    -- Test space (debug R/W registers)
         MI_ADC_PORT_PCI_DBG => X"0140_0000",    -- PCIe Debug space
         MI_ADC_PORT_STATUS0 => X"0200_0000",    -- Scratchpad status, endpoint 0
         MI_ADC_PORT_STATUS1 => X"0200_0100");   -- Scratchpad status, endpoint 1
end package;

package body mi_addr_space_pack is
end package body;
