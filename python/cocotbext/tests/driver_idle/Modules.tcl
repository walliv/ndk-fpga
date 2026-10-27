# Modules.tcl: top level of the driver idle-word bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set PACKAGES "$PACKAGES $OFM_PATH/comp/base/pkg/math_pack.vhd"

lappend MOD "$ENTITY_BASE/driver_idle_tb.vhd"
