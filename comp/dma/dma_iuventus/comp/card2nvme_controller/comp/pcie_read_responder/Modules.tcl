# Modules.tcl: Components include script
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_bar_map_pkg.vhd"

set PCIE_CQ_HDR_DEPARSER_BASE  "$OFM_PATH/comp/pcie/others/hdr_gen"

# Includes also CC_HDR_GEN
lappend COMPONENTS [ list "PCIE_CQ_HDR_DEPARSER"  $PCIE_CQ_HDR_DEPARSER_BASE  "FULL"]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/pcie_read_responder.vhd"
