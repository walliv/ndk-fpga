# pcie_full.xdc: Adds second half of the connector pins when full x16 endpoint
# is used.
# Copyright (C) 2023 CESNET z. s. p. o.
# Author(s): Vladislav Valek <valekv@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause


set_property LOC GTYE4_CHANNEL_X1Y27 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[30].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AP2 [get_ports {PCIE_RX_P[8]}]
set_property PACKAGE_PIN AP1 [get_ports {PCIE_RX_N[8]}]
set_property PACKAGE_PIN AP7 [get_ports {PCIE_TX_P[8]}]
set_property PACKAGE_PIN AP6 [get_ports {PCIE_TX_N[8]}]
set_property LOC GTYE4_CHANNEL_X1Y26 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[30].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AR4 [get_ports {PCIE_RX_P[9]}]
set_property PACKAGE_PIN AR3 [get_ports {PCIE_RX_N[9]}]
set_property PACKAGE_PIN AR9 [get_ports {PCIE_TX_P[9]}]
set_property PACKAGE_PIN AR8 [get_ports {PCIE_TX_N[9]}]
set_property LOC GTYE4_CHANNEL_X1Y25 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[30].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AT2 [get_ports {PCIE_RX_P[10]}]
set_property PACKAGE_PIN AT1 [get_ports {PCIE_RX_N[10]}]
set_property PACKAGE_PIN AT7 [get_ports {PCIE_TX_P[10]}]
set_property PACKAGE_PIN AT6 [get_ports {PCIE_TX_N[10]}]
set_property LOC GTYE4_CHANNEL_X1Y24 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[30].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AU4 [get_ports {PCIE_RX_P[11]}]
set_property PACKAGE_PIN AU3 [get_ports {PCIE_RX_N[11]}]
set_property PACKAGE_PIN AU9 [get_ports {PCIE_TX_P[11]}]
set_property PACKAGE_PIN AU8 [get_ports {PCIE_TX_N[11]}]
set_property LOC GTYE4_CHANNEL_X1Y23 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[29].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AV2 [get_ports {PCIE_RX_P[12]}]
set_property PACKAGE_PIN AV1 [get_ports {PCIE_RX_N[12]}]
set_property PACKAGE_PIN AV7 [get_ports {PCIE_TX_P[12]}]
set_property PACKAGE_PIN AV6 [get_ports {PCIE_TX_N[12]}]
set_property LOC GTYE4_CHANNEL_X1Y22 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[29].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AW4 [get_ports {PCIE_RX_P[13]}]
set_property PACKAGE_PIN AW3 [get_ports {PCIE_RX_N[13]}]
set_property PACKAGE_PIN BB5 [get_ports {PCIE_TX_P[13]}]
set_property PACKAGE_PIN BB4 [get_ports {PCIE_TX_N[13]}]
set_property LOC GTYE4_CHANNEL_X1Y21 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[29].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN BA2 [get_ports {PCIE_RX_P[14]}]
set_property PACKAGE_PIN BA1 [get_ports {PCIE_RX_N[14]}]
set_property PACKAGE_PIN BD5 [get_ports {PCIE_TX_P[14]}]
set_property PACKAGE_PIN BD4 [get_ports {PCIE_TX_N[14]}]
set_property LOC GTYE4_CHANNEL_X1Y20 [get_cells {cm_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i/inst/pcie4_uscale_plus_gt_top_i/diablo_gt.diablo_gt_phy_wrapper/gt_wizard.gtwizard_top_i/pcie4_uscale_plus_gt_i/inst/gen_gtwizard_gtye4_top.pcie4_uscale_plus_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[29].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN BC2 [get_ports {PCIE_RX_P[15]}]
set_property PACKAGE_PIN BC1 [get_ports {PCIE_RX_N[15]}]
set_property PACKAGE_PIN BF5 [get_ports {PCIE_TX_P[15]}]
set_property PACKAGE_PIN BF4 [get_ports {PCIE_TX_N[15]}]



