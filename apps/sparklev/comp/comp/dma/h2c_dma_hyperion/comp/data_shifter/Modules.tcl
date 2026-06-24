# Modules.tcl: component include build script 
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

# SPDX-License-Identifier: Apache-2.0 

# Paths to components
set BARREL_SHIFT_BASE "$OFM_PATH/comp/base/logic/barrel_shifter"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

# Architecture specific component
lappend COMPONENTS [list "BARREL_SHIFTER_GEN" $BARREL_SHIFT_BASE "FULL" ]

# Source files for implemented component
lappend MOD "$ENTITY_BASE/h2c_hyperion_data_shifter.vhd"
