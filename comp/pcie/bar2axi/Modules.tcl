# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: CERN-OHL-W-2.0

# Paths
set MFB_PIPE_BASE        "$OFM_PATH/comp/mfb_tools/flow/pipe"
set MFB_TRANSFORMER_BASE "$OFM_PATH/comp/mfb_tools/flow/transformer"
set FIFOX_BASE           "$OFM_PATH/comp/base/fifo/fifox"
set SDP_BRAM_BASE        "$OFM_PATH/comp/base/mem/sdp_bram"
set PCIE_HDR_GEN_BASE    "$OFM_PATH/comp/pcie/others/hdr_gen"
set PCIE_BYTE_COUNT_BASE "$OFM_PATH/comp/pcie/logic/byte_count"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$ENTITY_BASE/bar2axi_pkg.vhd"

# Components
lappend COMPONENTS [list "MFB_PIPE"        $MFB_PIPE_BASE        "FULL"]
lappend COMPONENTS [list "MFB_TRANSFORMER" $MFB_TRANSFORMER_BASE "FULL"]
lappend COMPONENTS [list "FIFOX"           $FIFOX_BASE           "FULL"]
lappend COMPONENTS [list "SDP_BRAM_BEHAV"  $SDP_BRAM_BASE        "FULL"]
lappend COMPONENTS [list "PCIE_HDR_GEN"    $PCIE_HDR_GEN_BASE    "FULL"]
lappend COMPONENTS [list "PCIE_BYTE_COUNT" $PCIE_BYTE_COUNT_BASE "FULL"]

# Files
lappend MOD "$ENTITY_BASE/bar2axi_wr.vhd"
lappend MOD "$ENTITY_BASE/bar2axi_rd.vhd"
lappend MOD "$ENTITY_BASE/bar2axi_cc.vhd"
lappend MOD "$ENTITY_BASE/pcie_bar2axi.vhd"
