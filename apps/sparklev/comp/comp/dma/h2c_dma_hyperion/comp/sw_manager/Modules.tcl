# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

set SUM_ONE_PATH  "$OFM_PATH/comp/base/logic/sum_one"

lappend COMPONENTS [ list "SUM_ONE" $SUM_ONE_PATH "FULL" ]

lappend MOD "$ENTITY_BASE/stat_cntr.vhd"
lappend MOD "$ENTITY_BASE/h2c_dma_hyperion_sw_mgr.vhd"
