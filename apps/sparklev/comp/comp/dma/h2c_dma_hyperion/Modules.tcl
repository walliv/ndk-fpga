# Modules.tcl: component include build script
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

# SPDX-License-Identifier: Apache-2.0

# Paths to components
set FIFOX_BASE        "$OFM_PATH/comp/mfb_tools/storage/fifox"
set DATA_SHIFT_BASE   "$ENTITY_BASE/comp/data_shifter"
set META_EXT_BASE     "$ENTITY_BASE/comp/metadata_extractor"
set AXI_ADAPT_BASE    "$ENTITY_BASE/comp/axi_adapter"
set SW_MGR_BASE       "$ENTITY_BASE/comp/sw_manager"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$ENTITY_BASE/pkg/h2c_meta_pkg.vhd"

# Architecture specific component
lappend COMPONENTS [list "MFB_FIFOX"                 $FIFOX_BASE      "FULL" ]
lappend COMPONENTS [list "H2C_HYPERION_DATA_SHIFTER" $DATA_SHIFT_BASE "FULL" ]
lappend COMPONENTS [list "H2C_HYPERION_META_EXT"     $META_EXT_BASE   "FULL" ]
lappend COMPONENTS [list "H2C_HYPERION_AXI_ADAPTER"  $AXI_ADAPT_BASE  "FULL" ]
lappend COMPONENTS [list "H2C_HYPERION_SW_MGR"       $SW_MGR_BASE     "FULL" ]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/h2c_dma_hyperion.vhd"
