# Arm the ILA with a trigger, wait, upload, and export CSV.
# args: <target> <ltx> <trig_probe> <trig_value> <trig_pos> <out_csv> <timeout_s>
lassign $argv TGT LTX TPROBE TVAL TPOS OUT TMO
if {$TPOS eq ""} { set TPOS 256 }
if {$TMO  eq ""} { set TMO 30 }

open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target $TGT
open_hw_target
set dev ""
foreach d [get_hw_devices] {
    current_hw_device $d
    refresh_hw_device -quiet $d
    if {[llength [get_hw_ilas -quiet -of_objects $d]]} { set dev $d; break }
}
if {$dev eq ""} { puts "### NO ILA DEVICE"; exit 1 }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
set_property FULL_PROBES.FILE $LTX $dev
refresh_hw_device -quiet $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
puts "### ILA=$ila on $dev"
foreach pr [get_hw_probes -of_objects $ila] { puts "  PROBE $pr" }

# basic trigger: probe whose name contains TPROBE (substring; avoids []-glob issues) == TVAL
set p ""
foreach pr [get_hw_probes -of_objects $ila] { if {[string match "*$TPROBE*" $pr]} { set p $pr; break } }
if {$p eq ""} { puts "### TRIGGER PROBE '$TPROBE' NOT FOUND"; exit 1 }
puts "### trigger probe = $p"
set_property TRIGGER_COMPARE_VALUE $TVAL $p
set_property CONTROL.TRIGGER_POSITION $TPOS $ila
set_property CONTROL.DATA_DEPTH 2048 $ila
puts "### arming: $TPROBE = $TVAL, pos=$TPOS"
run_hw_ila $ila
puts "### ARMED - waiting up to ${TMO}s for trigger"
flush stdout
set ok 1
if {[catch {wait_on_hw_ila -timeout $TMO $ila} e]} { puts "### wait error/timeout: $e"; set ok 0 }
if {[catch {upload_hw_ila_data $ila} e]} { puts "### upload error: $e" }
if {[catch {write_hw_ila_data -csv_file -force $OUT [current_hw_ila_data]} e]} { puts "### write error: $e" }
puts "### wrote $OUT (triggered=$ok)"
puts "### CAPTURE DONE"
