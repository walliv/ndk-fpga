# Modules.tcl: Components include script
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"

set MI_ASYNC_PATH         "$OFM_PATH/comp/mi_tools/async"
set MI_SPLIT_BASE         "$OFM_PATH/comp/mi_tools/splitter_plus_gen"
set NVME_SW_MGR_PATH      "$ENTITY_BASE/comp/software_manager"
set DBL_UPDATER_PATH      "$ENTITY_BASE/comp/dbl_updater"
set NVME_CQ_META_EXT_PATH "$ENTITY_BASE/comp/cq_meta_extractor"
set MFB_FRAME_LNG_PATH    "$OFM_PATH/comp/mfb_tools/logic/frame_lng"
set N2C_CTRL_PATH         "$ENTITY_BASE/comp/nvme2card_controller"
set C2N_CTRL_PATH         "$ENTITY_BASE/comp/card2nvme_controller"
set OP_CTRL_PATH          "$ENTITY_BASE/comp/operation_control"
set MFB_PIPE_PATH         "$OFM_PATH/comp/mfb_tools/flow/pipe"

lappend COMPONENTS [ list "MI_ASYNC"               $MI_ASYNC_PATH         "FULL" ]
lappend COMPONENTS [ list "MI_SPLITTER_PLUS_GEN"   $MI_SPLIT_BASE         "FULL" ]
lappend COMPONENTS [ list "NVME_SW_MANAGER"        $NVME_SW_MGR_PATH      "FULL" ]
lappend COMPONENTS [ list "DBL_UPDATER"            $DBL_UPDATER_PATH      "FULL" ]
lappend COMPONENTS [ list "NVME_CQ_META_EXTRACTOR" $NVME_CQ_META_EXT_PATH "FULL" ]
lappend COMPONENTS [ list "MFB_FRAME_LNG"          $MFB_FRAME_LNG_PATH    "FULL" ]
lappend COMPONENTS [ list "N2C_CONTROLLER"         $N2C_CTRL_PATH         "FULL" ]
lappend COMPONENTS [ list "C2N_CONTROLLER"         $C2N_CTRL_PATH         "FULL" ]
lappend COMPONENTS [ list "OP_CTRL"                $OP_CTRL_PATH          "FULL" ]
lappend COMPONENTS [ list "MFB_PIPE"               $MFB_PIPE_PATH         "FULL" ]

lappend MOD "$ENTITY_BASE/DevTree.tcl"
lappend MOD "$ENTITY_BASE/dma_iuventus.vhd"
