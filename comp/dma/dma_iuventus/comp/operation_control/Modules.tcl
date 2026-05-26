# Modules.tcl: Components include script
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"

set MVB_PIPE_PATH "$OFM_PATH/comp/mvb_tools/flow/pipe"

lappend COMPONENTS [list "MVB_PIPE" $MVB_PIPE_PATH "FULL"]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/op_ctrl.vhd"
