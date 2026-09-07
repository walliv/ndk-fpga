# gen_devtree.tcl: DevTree.dtb generator for cocotb.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
set SCRIPT_DIR    [file dirname [file normalize [info script]]]
set NDK_FPGA_PATH [file normalize "$SCRIPT_DIR/../../../.."]

source "$NDK_FPGA_PATH/build/scripts/dts/dts_templates.tcl"
# Per-component DevTree.tcl snippets that DevTree.tcl's dts_application calls directly (normally
# auto-discovered via each component's Modules.tcl in a full build; sourced explicitly here since
# this is a standalone build).
source "$NDK_FPGA_PATH/comp/mfb_tools/debug/generator/DevTree.tcl"
source "$NDK_FPGA_PATH/comp/debug/data_logger/DevTree.tcl"
source "$NDK_FPGA_PATH/apps/iuventus/comp/DevTree.tcl"

set OUT_DTB [lindex $argv 0]
if {$OUT_DTB eq ""} {
    set OUT_DTB "DevTree.dtb"
}
set OUT_DTS "[file rootname $OUT_DTB].dts"

# mi_pci0_bar0: the "PCI0,BAR0" node Servicer.get_node_base matches to pick device.mi[0],
# bound to USER_CORE.MI_*. base=0, so the user_core node's reg offsets are absolute MI
# addresses.
set dts ""
dts_create_default_mi_bar_node dts 0 0 {
    dts_application dts 0 "TEST"
}

set dts_string "/dts-v1/;
/ {
firmware {
$dts
};
};"

set f [open $OUT_DTS w]
puts $f $dts_string
close $f

puts "Building component DevTree: $OUT_DTS"

# dtc warnings about a missing #address-cells/#size-cells re-declaration on the intermediate
# "user_core" node are expected and benign -- it correctly inherits 1/1 from its ancestor.
# DevTreeGenerateBlob treats this step the same way, wrapped in `catch`.
catch {exec dtc -I dts -O dtb -o $OUT_DTB $OUT_DTS} msg

if {![file exists $OUT_DTB]} {
    puts stderr "ERROR: dtc did not produce $OUT_DTB"
    puts stderr $msg
    exit 1
}

puts "Generated component DevTree: $OUT_DTS -> $OUT_DTB"
