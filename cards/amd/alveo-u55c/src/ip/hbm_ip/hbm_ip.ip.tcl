# hbm.ip.tcl: generation script for HBM IP
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

array set PARAMS $IP_PARAMS_L

# Global Addressing lets every port reach every pseudo-channel (PG276). An app whose RTL addresses
# only each port's own pseudo-channel sets HBM_SWITCH_ENABLE false, or its accesses hit wrong banks.
set SWITCH_ENABLE TRUE
if {[info exists PARAMS(HBM_SWITCH_ENABLE)] && !$PARAMS(HBM_SWITCH_ENABLE)} {
    set SWITCH_ENABLE FALSE
}

set IP_COMP_NAME $PARAMS(IP_COMP_NAME)
if {[get_ips -quiet $IP_COMP_NAME] eq ""} {
    if {$PARAMS(IP_GEN_FILES) eq true} {
        create_ip -name hbm -vendor xilinx.com -library ip -module_name $IP_COMP_NAME -dir $PARAMS(IP_BUILD_DIR) -force
    } else {
        create_ip -name hbm -vendor xilinx.com -library ip -module_name $IP_COMP_NAME
    }
}

set IP [get_ips $IP_COMP_NAME]

set config_list [list \
    CONFIG.USER_APB_EN {false} \
    CONFIG.USER_HBM_DENSITY {16GB} \
    CONFIG.USER_SWITCH_ENABLE_00 $SWITCH_ENABLE \
    CONFIG.USER_SWITCH_ENABLE_01 $SWITCH_ENABLE \
    CONFIG.USER_XSDB_INTF_EN {FALSE} \
]

set_property -dict $config_list $IP
