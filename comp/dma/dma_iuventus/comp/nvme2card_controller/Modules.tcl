# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_mfb_meta_pkg.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_bar_map_pkg.vhd"

set MFB_SPEED_METER_PATH  "$OFM_PATH/comp/mfb_tools/logic/speed_meter"
set TRANS_BUFF_PATH       "$OFM_PATH/comp/dma/dma_calypte/comp/tx/comp/pcie_trans_buffer"
set CQE_PROC_PATH         "$ENTITY_BASE/comp/cqe_processor"
set PKT_DISP_PATH         "$ENTITY_BASE/comp/pkt_dispatcher"

lappend COMPONENTS [ list "MFB_SPEED_METER_MI"       $MFB_SPEED_METER_PATH  "FULL" ]
lappend COMPONENTS [ list "TX_DMA_PCIE_TRANS_BUFFER" $TRANS_BUFF_PATH       "FULL" ]
lappend COMPONENTS [ list "CQE_PROCESSOR"            $CQE_PROC_PATH         "FULL" ]
lappend COMPONENTS [ list "PKT_DISPATCHER"           $PKT_DISP_PATH         "FULL" ]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/n2c_controller.vhd"
