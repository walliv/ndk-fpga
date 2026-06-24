# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Paths to components
set MI_SPLITTER_PLUS_GEN_BASE "$OFM_PATH/comp/mi_tools/splitter_plus_gen"
set MI_ASYNC_BASE             "$OFM_PATH/comp/mi_tools/async"
set H2C_DMA_HYPERION_BASE     "$ENTITY_BASE/h2c_dma_hyperion"
set C2H_HBM_READER_BASE       "$ENTITY_BASE/c2h_hbm_reader"
set RX_DMA_CALYPTE_BASE       "$OFM_PATH/comp/dma/dma_calypte/comp/rx"
set DMA_PTR_UPDATER_BASE      "$OFM_PATH/comp/dma/dma_calypte/comp/ptr_updater"
set MFB_MERGER_SIMPLE_BASE    "$OFM_PATH/comp/mfb_tools/flow/merger_simple"
set MFB_PIPE_BASE             "$OFM_PATH/comp/mfb_tools/flow/pipe"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/dma_bus_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"

# Components
lappend COMPONENTS [list "MI_SPLITTER_PLUS_GEN" $MI_SPLITTER_PLUS_GEN_BASE "FULL"]
lappend COMPONENTS [list "MI_ASYNC"             $MI_ASYNC_BASE             "FULL"]
lappend COMPONENTS [list "H2C_DMA_HYPERION"     $H2C_DMA_HYPERION_BASE     "FULL"]
lappend COMPONENTS [list "C2H_HBM_READER"       $C2H_HBM_READER_BASE       "FULL"]
lappend COMPONENTS [list "RX_DMA_CALYPTE"       $RX_DMA_CALYPTE_BASE       "FULL"]
lappend COMPONENTS [list "DMA_PTR_UPDATER"      $DMA_PTR_UPDATER_BASE      "FULL"]
lappend COMPONENTS [list "MFB_MERGER_SIMPLE"    $MFB_MERGER_SIMPLE_BASE    "FULL"]
lappend COMPONENTS [list "MFB_PIPE"             $MFB_PIPE_BASE             "FULL"]

# Source files
lappend MOD "$ENTITY_BASE/dma_hyperion.vhd"
# dts_dma_calypte_ctrl is defined in the calypte top-level DevTree, not in the
# rx sub-component, so source it explicitly before our own DevTree.tcl.
lappend MOD "$OFM_PATH/comp/dma/dma_calypte/DevTree.tcl"
lappend MOD "$ENTITY_BASE/DevTree.tcl"
