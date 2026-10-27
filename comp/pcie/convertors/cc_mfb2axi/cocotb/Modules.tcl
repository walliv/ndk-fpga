# Modules.tcl: Components include script of the PCIE_CC_MFB2AXI cocotb top
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_axi_meta_pack.vhd"

lappend COMPONENTS [list "PCIE_CC_MFB2AXI" "$ENTITY_BASE/.." "FULL"]

lappend MOD "$ENTITY_BASE/cc_mfb2axi_tb.vhd"
