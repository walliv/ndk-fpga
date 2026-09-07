# Modules.tcl: sources for the standalone lane bench.
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set OFM "$ENTITY_BASE/../../../../.."

lappend PACKAGES "$OFM/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM/comp/base/pkg/type_pack.vhd"

lappend COMPONENTS [list "SDP_BRAM" "$OFM/comp/base/mem/sdp_bram" "FULL"]

lappend MOD "$ENTITY_BASE/../../iuventus_groupby_lane.vhd"
