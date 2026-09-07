# Modules.tcl: USER_CORE component list for cocotb.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
set APP_COMP_BASE [file normalize "$ENTITY_BASE/.."]

set MI_ASYNC_BASE      "$OFM_PATH/comp/mi_tools/async"
set MI_SPLITTER_BASE   "$OFM_PATH/comp/mi_tools/splitter_plus_gen"
set MFB_GEN_BASE       "$OFM_PATH/comp/mfb_tools/debug/generator"
set MFB_RECONF_BASE    "$OFM_PATH/comp/mfb_tools/flow/reconfigurator"
set DATA_LOGGER_BASE   "$OFM_PATH/comp/debug/data_logger"
set LATENCY_METER_BASE "$OFM_PATH/comp/debug/latency_meter"
set LFSR_GEN_BASE      "$OFM_PATH/comp/base/logic/lfsr_simple_random_gen"
set EVENT_CNTR_BASE    "$OFM_PATH/comp/base/misc/event_counter"

# Packages
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"
# See combo_user_const_pkg.vhd's own header for why this stub exists.
lappend PACKAGES "$ENTITY_BASE/combo_user_const_pkg.vhd"

# Components
lappend COMPONENTS [list "MI_ASYNC"               $MI_ASYNC_BASE       "FULL"]
lappend COMPONENTS [list "MI_SPLITTER_PLUS_GEN"   $MI_SPLITTER_BASE    "FULL"]
lappend COMPONENTS [list "MFB_GENERATOR_MI32"     $MFB_GEN_BASE        "FULL"]
lappend COMPONENTS [list "MFB_RECONFIGURATOR"     $MFB_RECONF_BASE     "FULL"]
lappend COMPONENTS [list "DATA_LOGGER"            $DATA_LOGGER_BASE    "FULL"]
lappend COMPONENTS [list "LATENCY_METER"          $LATENCY_METER_BASE  "FULL"]
lappend COMPONENTS [list "LFSR_SIMPLE_RANDOM_GEN" $LFSR_GEN_BASE       "FULL"]
lappend COMPONENTS [list "EVENT_COUNTER"          $EVENT_CNTR_BASE     "FULL"]

# USER_CORE itself, straight from the app's own component directory (one level up).
lappend MOD "$APP_COMP_BASE/iuventus_integrity_checker.vhd"
lappend MOD "$APP_COMP_BASE/user_core_ent.vhd"
lappend MOD "$APP_COMP_BASE/user_core_test_arch.vhd"
