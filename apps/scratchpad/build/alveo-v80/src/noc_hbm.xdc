# noc_hbm.xdc: NoC connections of the scratchpad's NMUs to HBM stack 0 channel 0
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Read with USED_IN {synthesis_pre}: synthesis runs the NoC compiler, which needs the connections. Paths are CORE_LOGIC's SCRATCHPAD_NMU instances and its HBM block design.
set nmu_ep0_path {core_logic_i/ep_g[0].nmu_i/xpm_nmu_i}
set nmu_ep1_path {core_logic_i/ep_g[1].nmu_i/xpm_nmu_i}
set hbm_noc_path {core_logic_i/hbm_i/v80_hbm_i/axi_noc_hbm}

set nmu_ep0 [get_noc_interfaces $nmu_ep0_path/S_AXI_nmu]
set nmu_ep1 [get_noc_interfaces $nmu_ep1_path/S_AXI_nmu]

# PORT0/PORT1 are the even/odd NSUs of PC0 (0x40_0000_0000, 1 GiB) and PORT2/PORT3 those of PC1 (0x40_4000_0000), PG313. Each endpoint takes its own NSU of PC0, so both NMUs see the same PC0 window.
set hbm0_pc0_even [get_noc_interfaces $hbm_noc_path/HBM0_PORT0_hbmc]
set hbm0_pc0_odd  [get_noc_interfaces $hbm_noc_path/HBM0_PORT1_hbmc]
set hbm0_pc1_even [get_noc_interfaces $hbm_noc_path/HBM0_PORT2_hbmc]
set hbm0_pc1_odd  [get_noc_interfaces $hbm_noc_path/HBM0_PORT3_hbmc]

set conn_ep0_pc0 [create_noc_connection -source $nmu_ep0 -target $hbm0_pc0_even]
set conn_ep0_pc1 [create_noc_connection -source $nmu_ep0 -target $hbm0_pc1_even]
set conn_ep1_pc0 [create_noc_connection -source $nmu_ep1 -target $hbm0_pc0_odd]
set conn_ep1_pc1 [create_noc_connection -source $nmu_ep1 -target $hbm0_pc1_odd]

# Bandwidth in MB/s: 2 x 4000 per NMU matches a 256-bit NMU port at 250 MHz (8 GB/s).
set_property -dict [list READ_BANDWIDTH 4000 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 4000 WRITE_AVERAGE_BURST 4] $conn_ep0_pc0
set_property -dict [list READ_BANDWIDTH 4000 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 4000 WRITE_AVERAGE_BURST 4] $conn_ep0_pc1
set_property -dict [list READ_BANDWIDTH 4000 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 4000 WRITE_AVERAGE_BURST 4] $conn_ep1_pc0
set_property -dict [list READ_BANDWIDTH 4000 READ_AVERAGE_BURST 4 WRITE_BANDWIDTH 4000 WRITE_AVERAGE_BURST 4] $conn_ep1_pc1
