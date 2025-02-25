# pcie.xdc
# Copyright (C) 2023 CESNET z.s.p.o.
# Author(s): Vladislav Valek <valekv@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

set_false_path              -from [get_ports {PCIE_SYSRST_N}]
set_property PACKAGE_PIN AM17     [get_ports {PCIE_SYSRST_N}]
set_property IOSTANDARD  LVCMOS18 [get_ports {PCIE_SYSRST_N}]
set_property PULLUP      TRUE     [get_ports {PCIE_SYSRST_N}]

set_property PACKAGE_PIN AL9 [get_ports {PCIE_SYSCLK_P}]
set_property PACKAGE_PIN AL8 [get_ports {PCIE_SYSCLK_N}]

create_clock -name pci_clk -period 10 [get_ports {PCIE_SYSCLK_P}]

create_pblock pblock_pcie_i
set_property IS_SOFT TRUE [get_pblocks pblock_pcie_i]
resize_pblock [get_pblocks pblock_pcie_i] -add {CLOCKREGION_X5Y8:CLOCKREGION_X5Y5}

add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet cm_i/pcie_i]
add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet cm_i/dma_i]

create_pblock init_ctr_rst
resize_pblock [get_pblocks init_ctr_rst] -add {SLICE_X157Y300:SLICE_X168Y372}
add_cells_to_pblock [get_pblocks init_ctr_rst] [get_cells -hierarchical -filter {NAME =~ *pcie4_uscale_plus_pcie_4_0_pipe_inst/pcie_4_0_init_ctrl_inst}]

# pci_clk vs TXOUTCLK
set_clock_groups -name async18 -asynchronous -group [get_clocks {pci_clk}] -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *gen_channel_container[32].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST/TXOUTCLK}]]
set_clock_groups -name async19 -asynchronous -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *gen_channel_container[32].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST/TXOUTCLK}]] -group [get_clocks {pci_clk}]
#
# refclk vs TXOUTCLK
set_clock_groups -name async22 -asynchronous -group [get_clocks -of_objects [get_ports REFCLK_P]] -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *gen_channel_container[32].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST/TXOUTCLK}]]
set_clock_groups -name async23 -asynchronous -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *gen_channel_container[32].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST/TXOUTCLK}]] -group [get_clocks -of_objects [get_ports REFCLK_P]]
#
#
#set_clock_groups -name asynco -asynchronous -group [get_clocks -of_objects [get_pins mem_clk_inst/clk_out1]] -group [get_clocks {pci_clk}]
#set_clock_groups -name asyncp -asynchronous -group [get_clocks {pci_clk}] -group [get_clocks -of_objects [get_pins mem_clk_inst/clk_out1]]
#
#
# ASYNC CLOCK GROUPINGS
# pci_clk vs user_clk
set_clock_groups -name async5 -asynchronous -group [get_clocks {pci_clk}] -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/phy_clk_i/bufg_gt_userclk/O}]]
set_clock_groups -name async6 -asynchronous -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/phy_clk_i/bufg_gt_userclk/O}]] -group [get_clocks {pci_clk}]
# pci_clk vs pclk
set_clock_groups -name async1 -asynchronous -group [get_clocks {pci_clk}] -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/phy_clk_i/bufg_gt_pclk/O}]]
set_clock_groups -name async2 -asynchronous -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/phy_clk_i/bufg_gt_pclk/O}]] -group [get_clocks {pci_clk}]
