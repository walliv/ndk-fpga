# Modules.tcl: sources of the FS_RD_ISSUE + FS_RD_DATA testbench behind USER_CORE_IF_PIPE
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set FS_BASE       [file normalize "$ENTITY_BASE/.."]
set APP_COMP_BASE [file normalize "$ENTITY_BASE/../.."]

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
# The if_pipe sizes a port from the DMA's sizing package.
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_sizing_pkg.vhd"
lappend PACKAGES "$FS_BASE/fs_pkg.vhd"

lappend COMPONENTS [list "FIFOX"    "$OFM_PATH/comp/base/fifo/fifox"     "FULL"]
lappend COMPONENTS [list "MFB_PIPE" "$OFM_PATH/comp/mfb_tools/flow/pipe" "FULL"]

lappend MOD "$APP_COMP_BASE/user_core_if_pipe.vhd"
lappend MOD "$FS_BASE/fs_rd_issue.vhd"
lappend MOD "$FS_BASE/fs_rd_data.vhd"
lappend MOD "$ENTITY_BASE/fs_rd_tb_top.vhd"
