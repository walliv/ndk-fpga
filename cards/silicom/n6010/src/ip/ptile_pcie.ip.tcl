package require -exact qsys 21.3

array set PARAMS $IP_PARAMS_L
source $PARAMS(IP_COMMON_TCL)

proc do_adjust_ptile_pcie_ip_1x16 {} {
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_enable_cii_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_enable_power_mgnt_intf_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_user_vsec_cap_enable_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_cap_slot_clk_config_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_bar0_address_width_user_hwtcl} {26}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_bar0_type_user_hwtcl} {64-bit non-prefetchable memory}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_bar2_address_width_user_hwtcl} {24}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_bar2_type_user_hwtcl} {64-bit non-prefetchable memory}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_class_code_hwtcl} {131072}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_pasid_cap_max_pasid_width} {20}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_pci_type0_device_id_hwtcl} {49152}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core16_pf0_pci_type0_vendor_id_hwtcl} {6380}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {top_topology_hwtcl} {Gen4x16, Interface - 512 bit}

	set_interface_property p0_power_mgnt EXPORT_OF intel_pcie_ptile_ast_0.p0_power_mgnt
	set_interface_property p0_cii EXPORT_OF intel_pcie_ptile_ast_0.p0_cii
}

proc do_adjust_ptile_pcie_ip_2x8 {} {
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_enable_cii_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_enable_power_mgnt_intf_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_user_vsec_cap_enable_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_cap_slot_clk_config_hwtcl} {1}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_bar0_address_width_user_hwtcl} {26}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_bar0_type_user_hwtcl} {64-bit non-prefetchable memory}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_bar2_address_width_user_hwtcl} {24}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_bar2_type_user_hwtcl} {64-bit non-prefetchable memory}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_class_code_hwtcl} {131072}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_pasid_cap_max_pasid_width} {20}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_pci_type0_device_id_hwtcl} {49152}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {core8_pf0_pci_type0_vendor_id_hwtcl} {6380}
	set_instance_parameter_value intel_pcie_ptile_ast_0 {top_topology_hwtcl} {Gen4 2x8, Interface - 256 bit}

	set_interface_property p1_rx_st EXPORT_OF intel_pcie_ptile_ast_0.p1_rx_st
	set_interface_property p1_rx_st_misc EXPORT_OF intel_pcie_ptile_ast_0.p1_rx_st_misc
	set_interface_property p1_tx_st EXPORT_OF intel_pcie_ptile_ast_0.p1_tx_st
	set_interface_property p1_tx_st_misc EXPORT_OF intel_pcie_ptile_ast_0.p1_tx_st_misc
	set_interface_property p1_tx_cred EXPORT_OF intel_pcie_ptile_ast_0.p1_tx_cred
	set_interface_property p1_config_tl EXPORT_OF intel_pcie_ptile_ast_0.p1_config_tl
	set_interface_property p1_reset_status_n EXPORT_OF intel_pcie_ptile_ast_0.p1_reset_status_n
	set_interface_property p1_hip_status EXPORT_OF intel_pcie_ptile_ast_0.p1_hip_status
	set_interface_property p1_power_mgnt EXPORT_OF intel_pcie_ptile_ast_0.p1_power_mgnt
	set_interface_property p1_cii EXPORT_OF intel_pcie_ptile_ast_0.p1_cii
	set_interface_property p1_pin_perst EXPORT_OF intel_pcie_ptile_ast_0.p1_pin_perst
}

# adjust parameters in "ptile_pcie_ip" system
proc do_adjust_ptile_pcie_ip {device family ipname filename adjust_proc} {

	load_system $filename
	set_project_property DEVICE $device
	set_project_property DEVICE_FAMILY $family
	set_project_property HIDE_FROM_IP_CATALOG {true}

	# common IP core parameters
	set_instance_parameter_value intel_pcie_ptile_ast_0 {standard_interface_selection_hwtcl} {0}

	# configuration-specific parameters
	$adjust_proc

	save_system $ipname
}

proc do_nothing {} {}

set cb do_nothing
if {$PARAMS(PCIE_ENDPOINT_MODE) == 0} {
	set cb do_adjust_ptile_pcie_ip_1x16
} elseif {$PARAMS(PCIE_ENDPOINT_MODE) == 1} {
	set cb do_adjust_ptile_pcie_ip_2x8
}

do_adjust_ptile_pcie_ip $PARAMS(IP_DEVICE) $PARAMS(IP_DEVICE_FAMILY) $PARAMS(IP_COMP_NAME) $PARAMS(IP_BUILD_DIR)/[get_ip_filename $PARAMS(IP_COMP_NAME)] $cb
