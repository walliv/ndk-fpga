# Modules.tcl: standalone component list to elaborate USER_CORE (GROUPBY architecture) by itself.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Mirrors the USR_CORE_ARCH=="GROUPBY" branch of ../Modules.tcl. Far shorter than the TEST mirror
# because this architecture instantiates only its MI slave, the engine and the engine's table.
set APP_COMP_BASE [file normalize "$ENTITY_BASE/.."]

set MI_ASYNC_BASE      "$OFM_PATH/comp/mi_tools/async"
set SDP_BRAM_BASE      "$OFM_PATH/comp/base/mem/sdp_bram"
set EVENT_CNTR_BASE    "$OFM_PATH/comp/base/misc/event_counter"
set MFB_PIPE_BASE      "$OFM_PATH/comp/mfb_tools/flow/pipe"
set FIFOX_BASE         "$OFM_PATH/comp/base/fifo/fifox"

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"
# See the TEST bench's copy for why this stub exists: user_core_ent.vhd uses the package but reads
# nothing from it, and the real one is generated during a card build.
lappend PACKAGES "$ENTITY_BASE/combo_user_const_pkg.vhd"

lappend COMPONENTS [list "MI_ASYNC"      $MI_ASYNC_BASE   "FULL"]
lappend COMPONENTS [list "SDP_BRAM"      $SDP_BRAM_BASE   "FULL"]
lappend COMPONENTS [list "EVENT_COUNTER" $EVENT_CNTR_BASE "FULL"]
lappend COMPONENTS [list "MFB_PIPE"      $MFB_PIPE_BASE   "FULL"]
lappend COMPONENTS [list "FIFOX"         $FIFOX_BASE      "FULL"]

lappend MOD "$APP_COMP_BASE/iuventus_groupby_lane.vhd"
lappend MOD "$APP_COMP_BASE/iuventus_groupby_engine.vhd"
lappend MOD "$APP_COMP_BASE/groupby_if_pipe.vhd"
lappend MOD "$APP_COMP_BASE/user_core_ent.vhd"
lappend MOD "$APP_COMP_BASE/user_core_groupby_arch.vhd"
