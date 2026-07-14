# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"

set CQE_ERR_TRACKER_PATH "$ENTITY_BASE/comp/cqe_error_tracker"
set DATA_LOGGER_BASE     "$OFM_PATH/comp/debug/data_logger"
set MI_SPLIT_BASE        "$OFM_PATH/comp/mi_tools/splitter_plus_gen"
set EV_CNTR_PATH         "$OFM_PATH/comp/base/misc/event_counter"
set NP_LUTRAM_BASE       "$OFM_PATH/comp/base/mem/np_lutram"

lappend COMPONENTS [ list "CQE_ERROR_TRACKER"    $CQE_ERR_TRACKER_PATH "FULL" ]
lappend COMPONENTS [ list "DATA_LOGGER"          $DATA_LOGGER_BASE     "FULL" ]
lappend COMPONENTS [ list "MI_SPLITTER_PLUS_GEN" $MI_SPLIT_BASE        "FULL" ]
lappend COMPONENTS [ list "EVENT_COUNTER"        $EV_CNTR_PATH         "FULL" ]
lappend COMPONENTS [ list "NP_LUTRAM"            $NP_LUTRAM_BASE       "FULL" ]

lappend MOD "$ENTITY_BASE/stat_cntr.vhd"
lappend MOD "$ENTITY_BASE/nvme_sw_manager.vhd"
