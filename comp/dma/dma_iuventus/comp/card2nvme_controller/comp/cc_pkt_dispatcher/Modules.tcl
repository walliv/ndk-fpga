# Modules.tcl: Components include script
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"

set FIFOX_PATH             "$OFM_PATH/comp/base/fifo/fifox"
set RX_CAL_TRBUF_PATH      "$OFM_PATH/comp/dma/dma_calypte/comp/rx/comp/trans_buffer"
set CC_HDR_INS_PATH        "$ENTITY_BASE/comp/hdr_insertor"

lappend COMPONENTS [list "FIFOX"                       $FIFOX_PATH          "FULL"]
lappend COMPONENTS [list "RX_DMA_CALYPTE_TRANS_BUFFER" $RX_CAL_TRBUF_PATH   "FULL"]
lappend COMPONENTS [list "NVME_CC_HDR_INSERTOR"        $CC_HDR_INS_PATH     "FULL"]

lappend MOD "$ENTITY_BASE/nvme_cc_pkt_dispatcher.vhd"
