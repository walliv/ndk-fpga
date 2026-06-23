# Modules.tcl: component include build script 
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

# SPDX-License-Identifier: Apache-2.0 

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

# Source files for implemented component
lappend MOD "$ENTITY_BASE/h2c_hyperion_axi_adapter.vhd"
