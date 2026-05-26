# Modules.tcl: Components include script
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"

set FIFOX_MULTI_PATH          "$OFM_PATH/comp/base/fifo/fifox_multi"
set NVME_CC_PKT_DISPATCH_PATH "$ENTITY_BASE/comp/cc_pkt_dispatcher"
set PCIE_RD_RESPONDER_PATH    "$ENTITY_BASE/comp/pcie_read_responder"
set DMA_PCIE_TRANS_BUFF_PATH  "$OFM_PATH/comp/dma/dma_calypte/comp/tx/comp/pcie_trans_buffer"

lappend COMPONENTS [list "FIFOX_MULTI"            $FIFOX_MULTI_PATH           "FULL" ]
lappend COMPONENTS [list "NVME_CC_PKT_DISPATCHER" $NVME_CC_PKT_DISPATCH_PATH  "FULL" ]
lappend COMPONENTS [list "PCIE_READ_RESPONDER"    $PCIE_RD_RESPONDER_PATH     "FULL" ]
lappend COMPONENTS [list "DMA_PCIE_TRANS_BUFF"    $DMA_PCIE_TRANS_BUFF_PATH   "FULL" ]

lappend MOD "$ENTITY_BASE/nvme_buffer_unit.vhd"
