# Modules.tcl: Components include script
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"

set PCIE_RQ_HDR_GEN_PATH   "$OFM_PATH/comp/pcie/others/hdr_gen"
set FIFOX_MULTI_PATH       "$OFM_PATH/comp/base/fifo/fifox_multi"

lappend COMPONENTS [list "PCIE_RQ_HDR_GEN"   $PCIE_RQ_HDR_GEN_PATH   "FULL"]
lappend COMPONENTS [list "FIFOX_MULTI"       $FIFOX_MULTI_PATH       "FULL"]


lappend MOD "$ENTITY_BASE/dbl_updater.vhd"
