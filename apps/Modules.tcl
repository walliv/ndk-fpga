# Modules.tcl: script that lists all different modules that are instantiated in various configuration of
# the APPLICATION_CORE
# Copyright 2024 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Path to source files
set MFB_PIPE_BASE          "$OFM_PATH/comp/mfb_tools/flow/pipe"
set HBM_TESTER_BASE        "$OFM_PATH/comp/mem_tools/debug/hbm_tester"
set MFB_ASFIFOX_BASE       "$OFM_PATH/comp/mfb_tools/storage/asfifox"
set MI_ASYNC_BASE          "$OFM_PATH/comp/mi_tools/async"
set APP_CORE_TEST_BASE     "$ENTITY_BASE/testing"
set APP_CORE_MANYCORE_BASE "$ENTITY_BASE/manycore"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

# Select specific group of source files according to the architecture type
if {$ARCHGRP == "TEST" || $ARCHGRP == "EMPTY"} {
    lappend COMPONENTS [list "APPLICATION_CORE" $APP_CORE_TEST_BASE     $ARCHGRP ]
} elseif {$ARCHGRP == "MANYCORE"} {
    lappend COMPONENTS [list "APPLICATION_CORE" $APP_CORE_MANYCORE_BASE "FULL" ]
}

lappend MOD "$ENTITY_BASE/application_core_ent.vhd"
lappend MOD "$ENTITY_BASE/DevTree.tcl"
