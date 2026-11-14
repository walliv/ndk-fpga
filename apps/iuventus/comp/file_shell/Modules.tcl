# Modules.tcl: sources of FILE_SHELL, the Iuventus file shell
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set APP_COMP_BASE [file normalize "$ENTITY_BASE/.."]

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
# The if_pipe sizes a port from the DMA's sizing package.
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_sizing_pkg.vhd"
lappend PACKAGES "$ENTITY_BASE/fs_pkg.vhd"

lappend COMPONENTS [list "FIFOX"    "$OFM_PATH/comp/base/fifo/fifox"     "FULL"]
lappend COMPONENTS [list "MFB_PIPE" "$OFM_PATH/comp/mfb_tools/flow/pipe" "FULL"]
lappend COMPONENTS [list "MI_ASYNC" "$OFM_PATH/comp/mi_tools/async"      "FULL"]

# The interface pipeline is the app's, shared with the other USER_CORE architectures; it has no
# Modules.tcl of its own.
lappend MOD "$APP_COMP_BASE/user_core_if_pipe.vhd"
lappend MOD "$ENTITY_BASE/fs_regs.vhd"
lappend MOD "$ENTITY_BASE/fs_hbm_port.vhd"
lappend MOD "$ENTITY_BASE/fs_ring_fetch.vhd"
lappend MOD "$ENTITY_BASE/fs_kernel_digest_fill.vhd"
lappend MOD "$ENTITY_BASE/fs_in_planner.vhd"
lappend MOD "$ENTITY_BASE/fs_rd_issue.vhd"
lappend MOD "$ENTITY_BASE/fs_rd_data.vhd"
lappend MOD "$ENTITY_BASE/fs_out_writer.vhd"
lappend MOD "$ENTITY_BASE/fs_wr_arb.vhd"
lappend MOD "$ENTITY_BASE/fs_ctrl.vhd"
lappend MOD "$ENTITY_BASE/file_shell.vhd"
