# Modules.tcl: Components include script of the scratchpad application core
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# converting input list to associative array
array set ARCHGRP_ARR $ARCHGRP

# Component paths
set ASYNC_RESET_BASE   "$OFM_PATH/comp/base/async/reset"
set PCIE_BASE          "$ARCHGRP_ARR(CORE_BASE)/comp/pcie/pcie_mod"
set MI_SPLITTER_BASE   "$OFM_PATH/comp/mi_tools/splitter_plus_gen"
set MI_TEST_SPACE_BASE "$OFM_PATH/comp/mi_tools/test_space"
set MI_ASYNC_BASE      "$OFM_PATH/comp/mi_tools/async"
set BAR2AXI_BASE       "$OFM_PATH/comp/pcie/bar2axi"
set CARD_IP_BASE       "$OFM_PATH/cards/amd/alveo-v80/src/ip"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$ARCHGRP_ARR(CORE_BASE)/config/core_const.vhd"
lappend PACKAGES "$ENTITY_BASE/mi_addr_space_pkg.vhd"

# Components
lappend COMPONENTS [list "ASYNC_RESET"          $ASYNC_RESET_BASE   "FULL"                     ]
lappend COMPONENTS [list "PCIE"                 $PCIE_BASE          $ARCHGRP_ARR(PCIE_MOD_ARCH)]
lappend COMPONENTS [list "MI_SPLITTER_PLUS_GEN" $MI_SPLITTER_BASE   "FULL"                     ]
lappend COMPONENTS [list "MI_TEST_SPACE"        $MI_TEST_SPACE_BASE "FULL"                     ]
lappend COMPONENTS [list "MI_ASYNC"             $MI_ASYNC_BASE      "FULL"                     ]
lappend COMPONENTS [list "PCIE_BAR2AXI"         $BAR2AXI_BASE       "FULL"                     ]

# Block designs: the CIPS the CPM5 PCIe core instantiates and the HBM NoC this core instantiates
lappend MOD [list "$CARD_IP_BASE/v80_platform_bd.tcl" TYPE "VIVADO_BD_TCL" BD_NAME "cpm5_cips" BD_PROC "create_v80_cips_bd"]
lappend MOD [list "$CARD_IP_BASE/v80_platform_bd.tcl" TYPE "VIVADO_BD_TCL" BD_NAME "v80_hbm"   BD_PROC "create_v80_hbm_bd"]

lappend MOD "$ENTITY_BASE/scratchpad_nmu.vhd"
lappend MOD "$ENTITY_BASE/scratchpad_status.vhd"
lappend MOD "$ENTITY_BASE/core_logic.vhd"
lappend MOD "$ARCHGRP_ARR(CORE_BASE)/top/DevTree.tcl"
lappend MOD "$ENTITY_BASE/DevTree.tcl"
