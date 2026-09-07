# Modules.tcl: source list for the IUVENTUS_GROUPBY_ENGINE component testbench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set APP_COMP_BASE [file normalize "$ENTITY_BASE/../.."]

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

lappend COMPONENTS [list "SDP_BRAM" "$OFM_PATH/comp/base/mem/sdp_bram" "FULL"]

lappend MOD "$APP_COMP_BASE/iuventus_groupby_lane.vhd"
lappend MOD "$APP_COMP_BASE/iuventus_groupby_engine.vhd"
