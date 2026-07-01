# pcie4_uscale_plus.ip.tcl: generation script for the PCIe IP
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

array set PARAMS $IP_PARAMS_L

set IP_COMP_NAME $PARAMS(IP_COMP_NAME)
if {[get_ips -quiet $IP_COMP_NAME] eq ""} {
    if {$PARAMS(IP_GEN_FILES) eq true} {
        create_ip -name pcie4c_uscale_plus -vendor xilinx.com -library ip -module_name $IP_COMP_NAME -dir $PARAMS(IP_BUILD_DIR) -force
    } else {
        create_ip -name pcie4c_uscale_plus -vendor xilinx.com -library ip -module_name $IP_COMP_NAME -dir $PARAMS(IP_BUILD_DIR)
    }
}

# Figure out if the name of the instance of the IP contains the index on its last character
set name_parts [split $IP_COMP_NAME _]
set last_part [lindex $name_parts end]
if {[string is integer -strict $last_part]} {
    set endpoint_idx $last_part
} else {
    set endpoint_idx 0
}

puts "Creating PCIe endpoint with index $endpoint_idx"

set IP [get_ips $IP_COMP_NAME]

# ==============================================================================
# general settings for each card
# ==============================================================================

set VENDOR_ID {18ec}
set PF0_DEVICE_ID {c000}

# ==============================================================================
# common properties they should be the same for all cards
# ==============================================================================

set config_list [list \
    CONFIG.ext_pcie_cfg_space_enabled {true} \
    CONFIG.extended_tag_field {true} \
    CONFIG.plltype {QPLL0} \
    CONFIG.axisten_freq {250} \
    CONFIG.axisten_if_enable_client_tag {true} \
    CONFIG.pf0_dev_cap_max_payload {512_bytes} \
    CONFIG.PF0_Use_Class_Code_Lookup_Assistant {false} \
    CONFIG.PF0_CLASS_CODE {020000} \
    CONFIG.MSI_X_OPTIONS {None} \
    CONFIG.mode_selection {Advanced} \
    CONFIG.pf0_msix_enabled {false} \
    CONFIG.pf0_bar0_64bit {true} \
    CONFIG.pf0_bar0_prefetchable {false} \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {64} \
    CONFIG.pf0_bar2_64bit {true} \
    CONFIG.pf0_bar2_prefetchable {false} \
    CONFIG.pf0_bar2_enabled {true} \
    CONFIG.pf0_bar2_scale {Megabytes} \
    CONFIG.pf0_bar2_size {16} \
    CONFIG.pf0_rbar_cap_bar0 {0xffffffffffff} \
    CONFIG.pf0_dsn_enabled {true} \
    CONFIG.PF0_MSIX_CAP_PBA_BIR {BAR_1:0} \
    CONFIG.PF0_MSIX_CAP_TABLE_BIR {BAR_1:0} \
    CONFIG.type1_membase_memlimit_enable {Disabled} \
    CONFIG.type1_prefetchable_membase_memlimit {Disabled} \
    CONFIG.cfg_ctl_if {true} \
    CONFIG.cfg_fc_if {true} \
    CONFIG.cfg_mgmt_if {false} \
    CONFIG.cfg_pm_if {false} \
    CONFIG.cfg_tx_msg_if {false} \
    CONFIG.rcv_msg_if {false} \
    CONFIG.tx_fc_if {false} \
    CONFIG.pf0_msi_enabled {false} \
]

if {$PARAMS(PCIE_GEN) == 3} {
    lappend config_list CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s}
} else {
    lappend config_list CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {16.0_GT/s}
}

# x16 endpoint
if {$PARAMS(PCIE_ENDPOINT_MODE) == 0} {
    lappend config_list \
        CONFIG.pcie_blk_locn {X1Y1} \
        CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X16} \
        CONFIG.AXISTEN_IF_EXT_512_CQ_STRADDLE {true} \
        CONFIG.AXISTEN_IF_EXT_512_RC_4TLP_STRADDLE {true} \
        CONFIG.AXISTEN_IF_EXT_512_RQ_STRADDLE {true} \
        CONFIG.axisten_if_width {512_bit}

# x8x8 bifurcated endpoint
} elseif {$PARAMS(PCIE_ENDPOINT_MODE) == 1} {
    if {$endpoint_idx == 0} {
        lappend config_list CONFIG.pcie_blk_locn {X1Y1}
    } else {
        lappend config_list CONFIG.pcie_blk_locn {X1Y0}
    }

    lappend config_list \
        CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X8} \
        CONFIG.AXISTEN_IF_EXT_512_CQ_STRADDLE {true} \
        CONFIG.AXISTEN_IF_EXT_512_RC_4TLP_STRADDLE {true} \
        CONFIG.AXISTEN_IF_EXT_512_RQ_STRADDLE {true} \
        CONFIG.axisten_if_width {512_bit}

# x8 
} elseif {$PARAMS(PCIE_ENDPOINT_MODE) == 2} {
    lappend config_list \
        CONFIG.pcie_blk_locn {X1Y1} \
        CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X8}

    # The 3rd generation allows for low-latency setting whith gets activated by
    # increasing clock frequency
    if {$PARAMS(PCIE_GEN) == 3} {
        lappend config_list \
            CONFIG.coreclk_freq {500} \
            CONFIG.axisten_if_width {256_bit}
    } else {
        lappend config_list \
            CONFIG.AXISTEN_IF_EXT_512_CQ_STRADDLE {true} \
            CONFIG.AXISTEN_IF_EXT_512_RC_4TLP_STRADDLE {true} \
            CONFIG.AXISTEN_IF_EXT_512_RQ_STRADDLE {true} \
            CONFIG.axisten_if_width {512_bit}
    }

# x4 endpoint (256-bit non-straddle AXI interface; IS_FULL_EP=false in pcie_core_usp for this mode)
} else {
    lappend config_list \
        CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
        CONFIG.pcie_blk_locn {X1Y0} \
        CONFIG.axisten_if_width {256_bit}
}

# DMA Hyperion (type 6): enable PF0 BAR2 as a 64-bit prefetchable 16 GB window for direct HBM writes.
# Prefetchable is required so the host can place this multi-GB BAR in the 64-bit above-4 GB window
# (a non-prefetchable BAR is confined to the bridge's 32-bit window and cannot exceed 4 GB).
# The host maps BAR2 to the full HBM address space; the H2C AXI adapter uses addr[33:0] as AWADDR.
if {$PARAMS(DMA_TYPE) == 6} {
    lappend config_list \
        CONFIG.pf0_bar2_enabled {true} \
        CONFIG.pf0_bar2_64bit {true} \
        CONFIG.pf0_bar2_prefetchable {true} \
        CONFIG.pf0_bar2_size {16} \
        CONFIG.pf0_bar2_scale {Gigabytes}
}

if {$PARAMS(DMA_TYPE) == 5} {
    lappend config_list \
        CONFIG.TL_PF_ENABLE_REG {2} \
        CONFIG.copy_pf0 {false} \
        CONFIG.PF1_DEVICE_ID {c020} \
        CONFIG.PF1_SUBSYSTEM_ID {c020} \
        CONFIG.pf1_bar0_size {256} \
        CONFIG.pf1_bar0_64bit {true} \
        CONFIG.pf1_bar0_prefetchable {true} \
        CONFIG.pf1_bar0_scale {Kilobytes} \
        CONFIG.pf1_bar2_enabled {true} \
        CONFIG.pf1_bar2_size {256} \
        CONFIG.pf1_bar2_64bit {true} \
        CONFIG.pf1_bar2_prefetchable {true} \
        CONFIG.pf1_bar2_scale {Kilobytes} \
        CONFIG.pf1_base_class_menu {Memory_controller} \
        CONFIG.pf1_class_code_interface {00} \
        CONFIG.pf1_sub_class_interface_menu {Other_memory_controller} \
        CONFIG.pf1_msi_enabled {false} \
        CONFIG.pf1_msix_enabled {false}
}

# set PCIE IDs, must be in last set_property
lappend config_list \
    CONFIG.PF0_DEVICE_ID [subst $PF0_DEVICE_ID] \
    CONFIG.PF0_SUBSYSTEM_ID [subst $PF0_DEVICE_ID] \
    CONFIG.PF0_SUBSYSTEM_VENDOR_ID [subst $VENDOR_ID] \
    CONFIG.vendor_id [subst $VENDOR_ID]

set_property -dict $config_list $IP
