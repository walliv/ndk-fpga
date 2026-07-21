# gen_devtree.tcl: generates a component-level DevTree.dtb for the USER_CORE (TEST architecture)
# cocotb testbench.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Just enough of the real card DevTree (see build/DevTree.tcl's DevTreeBuildString/
# DevTreeGenerateBlob, and apps/iuventus/comp/DevTree.tcl) for cocotbext.nfb.NfbDevice to open the
# simulated design as a real nfb device (nfb.open) and reach the "ziti,iuventus_test_ctrl" /
# "nvme_wr_data_gen" / "latency_meter" MI nodes that USER_CORE's own MI_SPLITTER_PLUS_GEN exposes.
#
# Deliberately narrower than the real per-card DevTree: only the user_core subtree is emitted (no
# PCIe debug, no dma_iuventus, no boot/SDM/HWID nodes) since none of those components are part of
# this standalone build. The "user_core" application base is 0 here (this testbench's MI bus
# drives USER_CORE.MI_* directly -- there is no outer app-level MI_SPLITTER rebasing it, unlike
# the real full-firmware build where user_core sits at NdkCore::ADDR_USERAPP).
#
# Usage: tclsh gen_devtree.tcl <path-to-output.dtb>

set SCRIPT_DIR    [file dirname [file normalize [info script]]]
set NDK_FPGA_PATH [file normalize "$SCRIPT_DIR/../../../.."]

source "$NDK_FPGA_PATH/build/scripts/dts/dts_templates.tcl"
# Per-component DevTree.tcl snippets that apps/iuventus/comp/DevTree.tcl's dts_application calls
# directly (normally auto-discovered via each component's own Modules.tcl entry in a full app
# build; sourced explicitly here since this is a standalone, non-full-app build).
source "$NDK_FPGA_PATH/comp/mfb_tools/debug/generator/DevTree.tcl"
source "$NDK_FPGA_PATH/comp/debug/data_logger/DevTree.tcl"
source "$NDK_FPGA_PATH/apps/iuventus/comp/DevTree.tcl"

set OUT_DTB [lindex $argv 0]
if {$OUT_DTB eq ""} {
    set OUT_DTB "DevTree.dtb"
}
set OUT_DTS "[file rootname $OUT_DTB].dts"

# mi_pci0_bar0: the "resource = PCI0,BAR0" bus node cocotbext.nfb.ext.python.Servicer.get_node_base
# matches (regex PCI(?P<pci>\d+),BAR(?P<bar>\d+)) to pick device.mi[0] -- i.e. our single
# MIRequestDriver bound straight to USER_CORE.MI_*. dts_application (apps/iuventus/comp/DevTree.tcl)
# is called with base=0 so that the "user_core" node's own reg offsets (0x00/0x100/0x200, matching
# USER_CORE's internal MI_SPLIT_BASES) are absolute MI addresses on this bus, exactly what our
# MIRequestDriver drives onto USER_CORE.MI_ADDR with no rebasing in between.
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

# dtc -O dts warnings (missing #address-cells/#size-cells re-declaration on the intermediate
# "user_core" node, which correctly inherits mi_pci0_bar0's 1/1 from its ancestor) are expected
# and benign -- build/DevTree.tcl's own DevTreeGenerateBlob treats this step the same way
# (wrapped in `catch`, result/status not checked).
catch {exec dtc -I dts -O dtb -o $OUT_DTB $OUT_DTS} msg

if {![file exists $OUT_DTB]} {
    puts stderr "ERROR: dtc did not produce $OUT_DTB"
    puts stderr $msg
    exit 1
}

puts "Generated component DevTree: $OUT_DTS -> $OUT_DTB"
