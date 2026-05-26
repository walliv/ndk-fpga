# Modules.tcl: Components include script
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"

set BARREL_SHIFTER_PATH    "$OFM_PATH/comp/base/logic/barrel_shifter"

lappend COMPONENTS [list "BARREL_SHIFTER_GEN"          $BARREL_SHIFTER_PATH "FULL"]

lappend MOD "$ENTITY_BASE/nvme_cc_hdr_insertor.vhd"
