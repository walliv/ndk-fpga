# Vivado.inc.tcl: OOC synthesis configuration of PCIE_BAR2AXI
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Sourced by build/targets/comp_vivado.tcl. The Alveo V80 use: CPM5 1024-bit CQ/CC (4 MFB regions),
# 512-bit AXI towards the NoC NMU.
lappend SYNTH_FLAGS(USER_GENERICS) [list MFB_REGIONS 4]
lappend SYNTH_FLAGS(USER_GENERICS) [list AXI_DATA_WIDTH 512]
lappend SYNTH_FLAGS(USER_GENERICS) [list DEVICE {"VERSAL"}]
