# Modules.tcl: script to compile single module
# Copyright (C) 2019 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# converting input list to associative array (uncomment when needed)
array set ARCHGRP_ARR $ARCHGRP

# Component paths
set BRISKI_BASE "$ENTITY_BASE/BRISKI/hardware/rtl"
set ASYNC_RESET_BASE "$OFM_PATH/comp/base/async/reset"

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"

lappend COMPONENTS [ list "core_dummy_wrapper" $BRISKI_BASE    "FULL" ]
lappend COMPONENTS [ list "ASYNC_RESET" $ASYNC_RESET_BASE    "FULL" ]

lappend MOD "$ENTITY_BASE/app_briski_top.vhd"
