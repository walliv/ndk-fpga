# Modules.tcl: Components include script
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/pcie_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"

set NVME_CMD_COMPOSER_PATH "$ENTITY_BASE/comp/command_composer"
set TAG_MANAGER_PATH       "$ENTITY_BASE/comp/tag_manager"
set MI_ASYNC_PATH          "$OFM_PATH/comp/mi_tools/async"

lappend COMPONENTS [list "NVME_CMD_COMPOSER"        $NVME_CMD_COMPOSER_PATH "FULL"]
lappend COMPONENTS [list "IUVENTUS_CMD_TAG_MANAGER" $TAG_MANAGER_PATH       "FULL"]
lappend COMPONENTS [list "MI_ASYNC"                 $MI_ASYNC_PATH          "FULL"]

lappend MOD "$ENTITY_BASE/nvme_cmd_dispatcher.vhd"
