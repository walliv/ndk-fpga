-- tx_dma_pcie_trans_buffer_banked_empty.vhd: empty architecture of the row-banked buffer without the xilinx tag
-- Copyright (C) 2023 CESNET z.s.p.o.
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek  <xvalek14@vutbr.cz>
--            David Benes      <xbenes52@vutbr.cz>
--            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: BSD-3-Clause

library IEEE;
use IEEE.std_logic_1164.all;

architecture BANKED of TX_DMA_PCIE_TRANS_BUFFER_IMPL is

begin

    assert false
        report "TX_DMA_PCIE_TRANS_BUFFER_IMPL: the BANKED architecture needs the xilinx PLATFORM_TAG!"
        severity FAILURE;

    RD_DATA_A     <= (others => '0');
    RD_DATA_VLD_A <= '0';
    RD_DATA_B     <= (others => '0');
    RD_DATA_VLD_B <= '0';

end architecture;
