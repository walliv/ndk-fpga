# Modules.tcl: script to compile card
# Copyright (C) 2023 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Vladislav Valek <valekv@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# converting input list to associative array
array set ARCHGRP_ARR $ARCHGRP

set BOOT_CTRL_BASE           "$ARCHGRP_ARR(CORE_BASE)/boot_ctrl"
set AXI_QSPI_FLASH_CTRL_BASE "$ARCHGRP_ARR(CORE_BASE)/axi_quad_flash_controller"

# Components
lappend COMPONENTS [list "FPGA_COMMON"         $ARCHGRP_ARR(CORE_BASE)   $ARCHGRP ]
lappend COMPONENTS [list "BOOT_CTRL"           $BOOT_CTRL_BASE           "FULL"   ]
lappend COMPONENTS [list "AXI_QSPI_FLASH_CTRL" $AXI_QSPI_FLASH_CTRL_BASE "FULL"   ]

# IP components
# set IP_MODIFY_BASE   "$ENTITY_BASE"
set ARCHGRP_ARR(IP_MODIFY_BASE)   $ENTITY_BASE

# modify == 1 -> provide '$IP_MODIFY_BASE/<script_name>/<script_name>.ip.tcl' file with IP modification commands
#                         script_path     script_name   ip_comp_name         type  modify
lappend IP_COMPONENTS [list "pcie" "pcie4_uscale_plus"  "pcie4_uscale_plus"  0     1]
lappend IP_COMPONENTS [list "mem"  "axi_quad_spi_0"     "axi_quad_spi_0"     0     1]

if {$ARCHGRP_ARR(VIRTUAL_DEBUG_ENABLE)} {
    lappend IP_COMPONENTS [list  "misc"  "xvc_vsec"  "xvc_vsec"  0  1]
}

# process_ip_scripts $IP_COMPONENTS $IP_MODIFY_BASE $ARCHGRP
lappend MOD {*}[get_ip_mod_files $IP_COMPONENTS [array get ARCHGRP_ARR]]

# Top-level
lappend MOD "$ENTITY_BASE/fpga.vhd"
