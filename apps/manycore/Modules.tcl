# Modules.tcl: script that lists all different modules that are instantiated in various configuration of
# the APPLICATION_CORE
# Copyright 2024 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Path to source files
set MFB_ASFIFOX_BASE "$OFM_PATH/comp/mfb_tools/storage/asfifox"
set MI_ASYNC_BASE    "$OFM_PATH/comp/mi_tools/async"

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"

lappend COMPONENTS [list "MFB_ASFIFOX"     $MFB_ASFIFOX_BASE "FULL" ]
lappend COMPONENTS [list "MI_ASYNC"        $MI_ASYNC_BASE    "FULL" ]

lappend MOD "$ENTITY_BASE/barrel_proc_debug_core.vhd"
lappend MOD "$ENTITY_BASE/application_core_full_arch.vhd"
lappend MOD "$ENTITY_BASE/DevTree.tcl"

lappend SRCS(CONSTR_VIVADO) "$ENTITY_BASE/pblock_constr.xdc"
