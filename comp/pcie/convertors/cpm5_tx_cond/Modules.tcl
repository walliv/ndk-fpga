# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: CERN-OHL-W-2.0

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

# Components
lappend COMPONENTS [ list "MFB_RECONFIGURATOR" "$OFM_PATH/comp/mfb_tools/flow/reconfigurator" "FULL" ]
lappend COMPONENTS [ list "MFB_FIFOX"          "$OFM_PATH/comp/mfb_tools/storage/fifox"       "FULL" ]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/pcie_cpm5_tx_cond.vhd"
