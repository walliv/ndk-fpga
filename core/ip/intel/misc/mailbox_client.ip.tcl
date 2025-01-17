package require -exact qsys 21.3

array set PARAMS $IP_PARAMS_L
source $PARAMS(IP_COMMON_TCL)

# create the system "mailbox_client_ip"
proc do_create_mailbox_client_ip {device family ipname filename} {
	# create the system
	create_system $ipname
	set_project_property DEVICE $device
	set_project_property DEVICE_FAMILY $family
	set_project_property HIDE_FROM_IP_CATALOG {true}
	set_use_testbench_naming_pattern 0 {}

	# add HDL parameters

	# add the components
	add_instance s10_mailbox_client_0 altera_s10_mailbox_client
	set_instance_parameter_value s10_mailbox_client_0 {CMD_FIFO_DEPTH} {16}
	set_instance_parameter_value s10_mailbox_client_0 {CMD_USE_MEMORY_BLOCKS} {1}
	set_instance_parameter_value s10_mailbox_client_0 {CRYPTO_MEMORY_TIMEOUT_VALUE} {10000}
	set_instance_parameter_value s10_mailbox_client_0 {DEBUG} {0}
	set_instance_parameter_value s10_mailbox_client_0 {HAS_OFFLOAD} {0}
	set_instance_parameter_value s10_mailbox_client_0 {HAS_STATUS} {1}
	set_instance_parameter_value s10_mailbox_client_0 {HAS_STREAM} {0}
	set_instance_parameter_value s10_mailbox_client_0 {HAS_URGENT} {0}
	set_instance_parameter_value s10_mailbox_client_0 {RSP_FIFO_DEPTH} {16}
	set_instance_parameter_value s10_mailbox_client_0 {RSP_USE_MEMORY_BLOCKS} {1}
	set_instance_parameter_value s10_mailbox_client_0 {STREAM_WIDTH} {32}
	set_instance_parameter_value s10_mailbox_client_0 {URG_FIFO_DEPTH} {4}
	set_instance_parameter_value s10_mailbox_client_0 {URG_USE_MEMORY_BLOCKS} {1}
	set_instance_property s10_mailbox_client_0 AUTO_EXPORT true

	# add wirelevel expressions

	# preserve ports for debug

	# add the exports
	set_interface_property in_clk EXPORT_OF s10_mailbox_client_0.in_clk
	set_interface_property in_reset EXPORT_OF s10_mailbox_client_0.in_reset
	set_interface_property avmm EXPORT_OF s10_mailbox_client_0.avmm
	set_interface_property irq EXPORT_OF s10_mailbox_client_0.irq

	# set values for exposed HDL parameters

	# set the the module properties
	set_module_property BONUS_DATA {<?xml version="1.0" encoding="UTF-8"?>
<bonusData>
 <element __value="s10_mailbox_client_0">
  <datum __value="_sortIndex" value="0" type="int" />
 </element>
</bonusData>
}
	set_module_property FILE {$filename}
	set_module_property GENERATION_ID {0x00000000}
	set_module_property NAME {$ipname}

	# save the system
	sync_sysinfo_parameters
	save_system $ipname
}

proc do_set_exported_interface_sysinfo_parameters {} {
}

# create all the systems, from bottom up
do_create_mailbox_client_ip $PARAMS(IP_DEVICE) $PARAMS(IP_DEVICE_FAMILY) $PARAMS(IP_COMP_NAME) [get_ip_filename $PARAMS(IP_COMP_NAME)]

# set system info parameters on exported interface, from bottom up
do_set_exported_interface_sysinfo_parameters
