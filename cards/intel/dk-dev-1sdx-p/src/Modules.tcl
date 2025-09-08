# Modules.tcl: script to compile DK-DEV-1SDX-P card
# Copyright (C) 2020 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# converting input list to associative array
array set ARCHGRP_ARR $ARCHGRP

# Paths
# set FPGA_COMMON_BASE "$ARCHGRP_ARR(CORE_BASE)/top"

# set COMPONENTS [list [list "FPGA_COMMON" $FPGA_COMMON_BASE $ARCHGRP]]

# IP components
set IP_COMMON_TCL $ARCHGRP_ARR(IP_TEMPLATE_ROOT)/common.tcl
source $IP_COMMON_TCL

set ARCHGRP_ARR(IP_COMMON_TCL)    $IP_COMMON_TCL
set ARCHGRP_ARR(IP_TEMPLATE_BASE) $ARCHGRP_ARR(IP_TEMPLATE_ROOT)/intel
set ARCHGRP_ARR(IP_MODIFY_BASE)   $ENTITY_BASE/ip
set ARCHGRP_ARR(IP_DEVICE_FAMILY) "Stratix 10"
set ARCHGRP_ARR(IP_DEVICE)        $ARCHGRP_ARR(FPGA)

# set PCIE_CONF [dict create 0 "1x16" 1 "2x8"]
# set PTILE_PCIE_IP_NAME "ptile_pcie_[dict get $PCIE_CONF $ARCHGRP_ARR(PCIE_ENDPOINT_MODE)]"

# see '$ARCHGRP_ARR(CORE_BASE)/src/ip/common.tcl' for more information regarding the fields
#                         script_path    script_name       ip_comp_name     type  modify
# lappend IP_COMPONENTS [list  "misc"   "mailbox_client"   "mailbox_client_ip"  0      0]
lappend IP_COMPONENTS [list  "misc"   "reset_release"    "reset_release_ip"   0      0]
# lappend IP_COMPONENTS [list  "pcie"   "ptile_pcie"       $PTILE_PCIE_IP_NAME  0      1]

# if {$ARCHGRP_ARR(VIRTUAL_DEBUG_ENABLE)} {
#     lappend IP_COMPONENTS [list "misc"  "jtag_op"        "jtag_op_ip"         0      0]
# }

lappend MOD {*}[get_ip_mod_files $IP_COMPONENTS [array get ARCHGRP_ARR]]

# IP sources
set MOD "$MOD $ENTITY_BASE/ip/iopll_ip.ip"
# set MOD "$MOD $ENTITY_BASE/ip/etile_eth_4x10g.ip"
# set MOD "$MOD $ENTITY_BASE/ip/etile_eth_4x25g.ip"
# set MOD "$MOD $ENTITY_BASE/ip/etile_eth_1x100g.ip"
# set MOD "$MOD $ENTITY_BASE/ip/emif_s10dx.ip"

# Top-level
# set MOD "$MOD $ENTITY_BASE/fpga.vhd"
