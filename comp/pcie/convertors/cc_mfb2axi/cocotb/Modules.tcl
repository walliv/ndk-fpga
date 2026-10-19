# Modules.tcl: Components include script of the PCIE_CC_MFB2AXI cocotb top
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend COMPONENTS [list "PCIE_CC_MFB2AXI" "$ENTITY_BASE/.." "FULL"]
lappend COMPONENTS [list "PCIE_CPM5_TX_COND" "$ENTITY_BASE/../../cpm5_tx_cond" "FULL"]

lappend MOD "$ENTITY_BASE/cc_mfb2axi_tb.vhd"
