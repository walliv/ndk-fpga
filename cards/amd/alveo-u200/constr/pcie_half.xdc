# pcie_half.xdc: Adds base lanes of a PCIe x8 endpoint and also its clock
# which is used by every PCIe configuration.
# Copyright (C) 2023 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Vladislav Valek <valekv@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause


set_property LOC GTYE4_CHANNEL_X1Y35 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[32].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AF2 [get_ports {PCIE_RX_P[0]}]
set_property PACKAGE_PIN AF1 [get_ports {PCIE_RX_N[0]}]
set_property PACKAGE_PIN AF7 [get_ports {PCIE_TX_P[0]}]
set_property PACKAGE_PIN AF6 [get_ports {PCIE_TX_N[0]}]
set_property LOC GTYE4_CHANNEL_X1Y34 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[32].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AG4 [get_ports {PCIE_RX_P[1]}]
set_property PACKAGE_PIN AG3 [get_ports {PCIE_RX_N[1]}]
set_property PACKAGE_PIN AG9 [get_ports {PCIE_TX_P[1]}]
set_property PACKAGE_PIN AG8 [get_ports {PCIE_TX_N[1]}]
set_property LOC GTYE4_CHANNEL_X1Y33 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[32].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AH2 [get_ports {PCIE_RX_P[2]}]
set_property PACKAGE_PIN AH1 [get_ports {PCIE_RX_N[2]}]
set_property PACKAGE_PIN AH7 [get_ports {PCIE_TX_P[2]}]
set_property PACKAGE_PIN AH6 [get_ports {PCIE_TX_N[2]}]
set_property LOC GTYE4_CHANNEL_X1Y32 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[32].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AJ4 [get_ports {PCIE_RX_P[3]}]
set_property PACKAGE_PIN AJ3 [get_ports {PCIE_RX_N[3]}]
set_property PACKAGE_PIN AJ9 [get_ports {PCIE_TX_P[3]}]
set_property PACKAGE_PIN AJ8 [get_ports {PCIE_TX_N[3]}]
set_property LOC GTYE4_CHANNEL_X1Y31 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[31].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AK2 [get_ports {PCIE_RX_P[4]}]
set_property PACKAGE_PIN AK1 [get_ports {PCIE_RX_N[4]}]
set_property PACKAGE_PIN AK7 [get_ports {PCIE_TX_P[4]}]
set_property PACKAGE_PIN AK6 [get_ports {PCIE_TX_N[4]}]
set_property LOC GTYE4_CHANNEL_X1Y30 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[31].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AL4 [get_ports {PCIE_RX_P[5]}]
set_property PACKAGE_PIN AL3 [get_ports {PCIE_RX_N[5]}]
set_property PACKAGE_PIN AL9 [get_ports {PCIE_TX_P[5]}]
set_property PACKAGE_PIN AL8 [get_ports {PCIE_TX_N[5]}]
set_property LOC GTYE4_CHANNEL_X1Y29 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[31].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AM2 [get_ports {PCIE_RX_P[6]}]
set_property PACKAGE_PIN AM1 [get_ports {PCIE_RX_N[6]}]
set_property PACKAGE_PIN AM7 [get_ports {PCIE_TX_P[6]}]
set_property PACKAGE_PIN AM6 [get_ports {PCIE_TX_N[6]}]
set_property LOC GTYE4_CHANNEL_X1Y28 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[31].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AN4 [get_ports {PCIE_RX_P[7]}]
set_property PACKAGE_PIN AN3 [get_ports {PCIE_RX_N[7]}]
set_property PACKAGE_PIN AN9 [get_ports {PCIE_TX_P[7]}]
set_property PACKAGE_PIN AN8 [get_ports {PCIE_TX_N[7]}]

set_property PACKAGE_PIN BD21 [get_ports PCIE_SYSRST_N]
set_property IOSTANDARD LVCMOS12 [get_ports PCIE_SYSRST_N]
set_property PULLTYPE PULLUP [get_ports PCIE_SYSRST_N]

set_property PACKAGE_PIN AM10 [get_ports PCIE_SYSCLK_N]
set_property PACKAGE_PIN AM11 [get_ports PCIE_SYSCLK_P]

create_clock -period 10.000 -name pcie_clk_p -waveform {0.000 5.000} [get_ports PCIE_SYSCLK_P]

create_pblock pblock_pcie_i
add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet [list cm_i/dma_i cm_i/pcie_i]]
resize_pblock [get_pblocks pblock_pcie_i] -add {CLOCKREGION_X4Y5:CLOCKREGION_X5Y8}
set_property IS_SOFT TRUE [get_pblocks pblock_pcie_i]



