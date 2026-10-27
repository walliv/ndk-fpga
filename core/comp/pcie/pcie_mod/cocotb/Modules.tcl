# Modules.tcl: Components include script of the PCIE_COMPLETER_TB cocotb top
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set PCIE_COMP_BASE "$ENTITY_BASE/../comp"

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_axi_meta_pack.vhd"

lappend COMPONENTS [list "PCIE_ADAPTER_TB"        "$PCIE_COMP_BASE/pcie_adapter/cocotb"               "FULL"]
lappend COMPONENTS [list "PCIE_CTRL_CQ_TB"        "$PCIE_COMP_BASE/pcie_ctrl/cocotb"                  "FULL"]
lappend COMPONENTS [list "LFSR_SIMPLE_RANDOM_GEN" "$OFM_PATH/comp/base/logic/lfsr_simple_random_gen" "FULL"]

lappend MOD "$ENTITY_BASE/pcie_completer_tb.vhd"
