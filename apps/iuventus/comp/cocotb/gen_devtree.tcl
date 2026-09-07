# gen_devtree.tcl: DevTree.dtb for the USER_CORE TEST-architecture cocotb testbench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Just enough of the card DevTree for cocotbext.nfb.NfbDevice to open the simulated design as a
# real nfb device and reach its component nodes.
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

# Servicer.get_node_base matches "resource = PCI0,BAR0" to pick device.mi[0]. dts_application is
# called with base=0 so the user_core node's reg offsets are absolute MI addresses.
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

# dtc warns that the intermediate user_core node re-declares no #address-cells/#size-cells; it
# inherits them from mi_pci0_bar0. Benign, and build/DevTree.tcl wraps the same step in a catch.
catch {exec dtc -I dts -O dtb -o $OUT_DTB $OUT_DTS} msg

if {![file exists $OUT_DTB]} {
    puts stderr "ERROR: dtc did not produce $OUT_DTB"
    puts stderr $msg
    exit 1
}

puts "Generated component DevTree: $OUT_DTS -> $OUT_DTB"
