# ILA insertion on the synthesized checkpoint (manual single-session flow).
# MODE: "verify" = opt_design only + dbg_hub DRC check (~2 min); "build" = full P&R + bitstream.
# Usage: vivado -mode batch -source ila_insert.tcl -tclargs <MODE>
set MODE [lindex $argv 0]
if {$MODE eq ""} { set MODE "verify" }
puts "### ILA insert MODE=$MODE"

set RUNS alveo-u55c-iuventus-pcie1xGen4x8.runs
set DMA  {core_logic_i/dma_g[0].dma_i}

open_checkpoint $RUNS/synth_1/CARD_TOP.dcp

# --- link OOC IP black boxes ---
read_checkpoint -cell {core_logic_i/pcie_i/pcie_core_i/pcie_mode_0_2_g.pcie_hip_g[0].pcie0_g.pcie_i} \
    $RUNS/pcie4_uscale_plus_synth_1/pcie4_uscale_plus.dcp
read_checkpoint -cell {axi_qspi_flash_i/axi_quad_ctrl_i} \
    $RUNS/axi_quad_spi_0_synth_1/axi_quad_spi_0.dcp

# The synth checkpoint lacks the implementation-only card I/O constraints (pin LOC / IOSTANDARD
# for STATUS_LEDS, HBM_CATTRIP, SYSCLK3, PCIE_SYSRST_N, ...). Without them place_design assigns a
# wrong pinout and write_bitstream fails DRC NSTD-1/UCIO-1. Re-read the top-level card XDCs (the
# component XDCs are already baked into the synth netlist).
set REPO /home/vladislav/projects/work_files/ndk-fpga
foreach xdc [list \
    $REPO/apps/iuventus/build/alveo-u55c/src/general.xdc \
    $REPO/apps/iuventus/build/alveo-u55c/src/pblock.xdc \
    $REPO/cards/amd/alveo-u55c/constr/pcie_half.xdc ] {
    puts "### read_xdc $xdc"
    read_xdc $xdc
}

# --- clock net for the ILA (the DMA Iuventus clock) ---
set clknet [get_nets -of_objects [get_pins $DMA/CLK]]
puts "### ILA clock net = $clknet"

# --- gather probe nets. Handshakes already MARK_DEBUG; mark META too (has the TLP header). ---
proc bus {pat} { return [lsort -dictionary [get_nets -quiet $pat]] }
set rq_sof  [bus "$DMA/PCIE_RQ_MFB_SOF[*]"]
set rq_eof  [bus "$DMA/PCIE_RQ_MFB_EOF[*]"]
set rq_sr   [get_nets "$DMA/PCIE_RQ_MFB_SRC_RDY"]
set rq_dr   [get_nets "$DMA/PCIE_RQ_MFB_DST_RDY"]
set rq_meta [bus "$DMA/PCIE_RQ_MFB_META[*]"]
set cq_sof  [bus "$DMA/PCIE_CQ_MFB_SOF[*]"]
set cq_eof  [bus "$DMA/PCIE_CQ_MFB_EOF[*]"]
set cq_sr   [get_nets "$DMA/PCIE_CQ_MFB_SRC_RDY"]
set cq_dr   [get_nets "$DMA/PCIE_CQ_MFB_DST_RDY"]
set cq_meta [bus "$DMA/PCIE_CQ_MFB_META[*]"]

# DATA[255:0] = region-0 of the 512-bit MFB. For the NDK->Xilinx RQ/CQ interface the TLP
# descriptor (address, req_type, dw_count, attributes, BE) sits in DATA[127:0]; the following
# DWs are payload (doorbell value / SQE bytes / CQE bytes). 256 bits catches header + start.
proc bus_range {pat lo hi} {
    # Only include DATA bits that survived synthesis (unused/constant lanes are trimmed).
    set all [get_nets -quiet "${pat}\[*\]"]
    set out {}
    foreach n $all {
        if {[regexp {\[(\d+)\]$} $n -> i] && $i >= $lo && $i <= $hi} { lappend out $n }
    }
    return [lsort -dictionary $out]
}
set rq_data [bus_range "$DMA/PCIE_RQ_MFB_DATA" 0 255]
set cq_data [bus_range "$DMA/PCIE_CQ_MFB_DATA" 0 255]
puts "### rq_meta=[llength $rq_meta] cq_meta=[llength $cq_meta] rq_data=[llength $rq_data] cq_data=[llength $cq_data]"
foreach n [concat $rq_meta $cq_meta $rq_data $cq_data] { set_property MARK_DEBUG true [get_nets $n] }

# probe list: {name netlist}
set probes [list \
    [list rq_hs   [concat $rq_sof $rq_eof $rq_sr $rq_dr]] \
    [list rq_meta $rq_meta] \
    [list rq_data $rq_data] \
    [list cq_hs   [concat $cq_sof $cq_eof $cq_sr $cq_dr]] \
    [list cq_meta $cq_meta] \
    [list cq_data $cq_data] ]

# --- create ILA ---
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER true [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 2 [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk $clknet

set idx 0
foreach p $probes {
    set pname [lindex $p 0]; set nets [lindex $p 1]
    if {$idx > 0} { create_debug_port u_ila_0 probe }
    set port "u_ila_0/probe$idx"
    set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports $port]
    set_property port_width [llength $nets] [get_debug_ports $port]
    connect_debug_port $port $nets
    puts "### $port ($pname) width [llength $nets]"
    incr idx
}

# --- implement ---
opt_design
puts "### DRC after opt_design:"
set drc [report_drc -return_string]
puts $drc
if {[string match "*dbg_hub*" $drc] && ([string match "*unconnected*" $drc] || [string match "*CHECK-3*" $drc])} {
    puts "### !!! dbg_hub connection PROBLEM detected"
} else {
    puts "### dbg_hub OK (no unconnected-clk DRC)"
}

if {$MODE eq "build"} {
    place_design
    route_design
    set RN [pwd]/alveo-u55c-iuventus-pcie1xGen4x8_ila
    write_checkpoint -force ${RN}.dcp
    write_bitstream -force ${RN}.bit
    write_debug_probes -force ${RN}.ltx
    puts "### BUILD DONE: ${RN}.bit / .ltx"
}
puts "### SCRIPT COMPLETE MODE=$MODE"
