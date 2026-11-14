# Modules.tcl: sources of the FS_RD_DATA testbench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set FS_BASE [file normalize "$ENTITY_BASE/.."]

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$FS_BASE/fs_pkg.vhd"

lappend MOD "$FS_BASE/fs_rd_data.vhd"
