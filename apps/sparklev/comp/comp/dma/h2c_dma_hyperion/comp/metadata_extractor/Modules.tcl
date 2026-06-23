# Modules.tcl: component include build script 
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

# SPDX-License-Identifier: Apache-2.0 

# Paths to components
set CQ_HDR_DEPARSE_BASE "$OFM_PATH/comp/pcie/others/hdr_gen/cq_hdr_deparser"
set PCIE_BYTE_CNT_BASE  "$OFM_PATH/comp/pcie/logic/byte_count"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"

# Architecture specific component
lappend COMPONENTS [list "PCIE_CQ_HDR_DEPARSER" $CQ_HDR_DEPARSE_BASE "FULL" ]
lappend COMPONENTS [list "PCIE_BYTE_COUNT"      $PCIE_BYTE_CNT_BASE  "FULL" ]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/h2c_hyperion_meta_ext.vhd"
