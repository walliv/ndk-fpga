# Discover which JTAG target holds our FPGA's ILA, and list its probes.
# Usage: vivado_lab -mode batch -source ila_discover.tcl -tclargs <ltx_path>
set LTX [lindex $argv 0]
open_hw_manager
connect_hw_server -url localhost:3121
foreach tgt [get_hw_targets] {
    if {[catch {
        current_hw_target $tgt
        open_hw_target
    } e]} { puts "### skip $tgt ($e)"; continue }
    foreach dev [get_hw_devices] {
        current_hw_device $dev
        refresh_hw_device -quiet [current_hw_device]
        set ilas [get_hw_ilas -quiet -of_objects $dev]
        set part [get_property -quiet PART $dev]
        puts "### TARGET $tgt DEVICE $dev part=$part ILAs={$ilas}"
        if {[llength $ilas] && $LTX ne ""} {
            set_property PROBES.FILE $LTX $dev
            set_property FULL_PROBES.FILE $LTX $dev
            refresh_hw_device -quiet $dev
            puts "### PROBES on $dev:"
            foreach pr [get_hw_probes -quiet -of_objects [get_hw_ilas -of_objects $dev]] {
                puts "     PROBE: $pr  width=[get_property -quiet PROBE_WIDTH $pr]"
            }
        }
    }
    close_hw_target
}
puts "### DISCOVER DONE"
