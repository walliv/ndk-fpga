# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_mfb_meta_pkg.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_bar_map_pkg.vhd"

set TRANS_BUFF_PATH       "$OFM_PATH/comp/dma/dma_calypte/comp/tx/comp/pcie_trans_buffer"
set MFB_AUX_SIGNALS_PATH  "$OFM_PATH/comp/mfb_tools/logic/auxiliary_signals"
set CMD_DISPATCHER_PATH   "$ENTITY_BASE/comp/command_dispatcher"
set MFB_MERGER_PATH       "$OFM_PATH/comp/mfb_tools/flow/merger_simple"
set FIFOX_PATH            "$OFM_PATH/comp/base/fifo/fifox_multi"
set PCIE_RD_RESP_PATH     "$ENTITY_BASE/comp/pcie_read_responder"
set CC_PKT_DISP_PATH      "$ENTITY_BASE/comp/cc_pkt_dispatcher"

lappend COMPONENTS [ list "TX_DMA_PCIE_TRANS_BUFFER" $TRANS_BUFF_PATH      "FULL" ]
lappend COMPONENTS [ list "MFB_AUXILIARY_SIGNALS"    $MFB_AUX_SIGNALS_PATH "FULL" ]
lappend COMPONENTS [ list "NVME_CMD_DISPATCHER"      $CMD_DISPATCHER_PATH  "FULL" ]
lappend COMPONENTS [ list "MFB_MERGER_SIMPLE"        $MFB_MERGER_PATH      "FULL" ]
lappend COMPONENTS [ list "FIFOX_MULTI"              $FIFOX_PATH           "FULL" ]
lappend COMPONENTS [ list "PCIE_RD_RESPONDER"        $PCIE_RD_RESP_PATH    "FULL" ]
lappend COMPONENTS [ list "NVME_CC_PKT_DISPATCHER"   $CC_PKT_DISP_PATH     "FULL" ]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/c2n_controller.vhd"
