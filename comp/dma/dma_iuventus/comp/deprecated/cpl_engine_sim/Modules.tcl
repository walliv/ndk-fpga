# Modules.tcl: Components include script
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"

set NVME_CQ_META_EXT_PATH     "$ENTITY_BASE/../cq_meta_extractor"
set CQE_PROCESSOR_PATH        "$ENTITY_BASE/../cqe_processor"
set NVME_BUFFER_UNIT_PATH     "$ENTITY_BASE/../buffer_unit"

lappend COMPONENTS [list "NVME_CQ_META_EXTRACTOR" $NVME_CQ_META_EXT_PATH      "FULL" ]
lappend COMPONENTS [list "CQE_PROCESSOR"          $CQE_PROCESSOR_PATH         "FULL" ]
lappend COMPONENTS [list "NVME_BUFFER_UNIT"       $NVME_BUFFER_UNIT_PATH      "FULL" ]


lappend MOD "$ENTITY_BASE/cpl_engine_sim_wrapper.vhd"
