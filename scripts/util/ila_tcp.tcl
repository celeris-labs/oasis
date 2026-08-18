# -------------------------------------------------------------------------------------------------
# Attach to the running board and drive ila_perf_tcp, without reprogramming it.
#
#   vivado -mode batch -source scripts/util/ila_tcp.tcl -tclargs list   <ltx>
#   vivado -mode batch -source scripts/util/ila_tcp.tcl -tclargs close  <ltx> [out]
#   vivado -mode batch -source scripts/util/ila_tcp.tcl -tclargs txerr  <ltx> [out]
#
# NEVER calls program_hw_devices: the point is to watch the state a run built up, and reloading the
# bitstream destroys exactly that.
# -------------------------------------------------------------------------------------------------
set mode [lindex $argv 0]
set ltx  [lindex $argv 1]
set out  [lindex $argv 2]
if {$out eq ""} { set out "ila_capture" }
if {$mode eq "" || $ltx eq ""} { puts "usage: ... -tclargs <list|close|txerr> <cyt_top.ltx> \[out\]"; exit 1 }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices *xcu55c*] 0]
if {$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
current_hw_device $dev
puts "device: $dev"

# Probes only. No programming.
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes false $dev

set ila [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ *ila_perf_tcp*}] 0]
if {$ila eq ""} {
    puts "ila_perf_tcp not found. ILAs visible on this device:"
    foreach i [get_hw_ilas -of_objects $dev] { puts "  [get_property CELL_NAME $i]" }
    exit 1
}
puts "ila: [get_property CELL_NAME $ila]  depth=[get_property CONTROL.DATA_DEPTH $ila]"

set probes [get_hw_probes -of_objects $ila]

if {$mode eq "list"} {
    puts "---- probes ----"
    foreach p $probes { puts [format "  %-70s %s bits" [get_property NAME $p] [get_property WIDTH $p]] }
    puts "---- end ----"
    exit 0
}

# Every probe starts as don't-care in both the trigger and the storage qualifier; the ones this
# mode cares about are set explicitly below. Vivado keeps whatever was set last session otherwise.
proc all_x {p} {
    set w [get_property WIDTH $p]
    return "eq${w}'b[string repeat x $w]"
}
foreach p $probes {
    set_property TRIGGER_COMPARE_VALUE [all_x $p] $p
    set_property CAPTURE_COMPARE_VALUE [all_x $p] $p
}

# Find a probe by substring, so this survives whatever hierarchy prefix the ltx carries.
proc find_probe {probes pat} {
    foreach p $probes { if {[string match -nocase $pat [get_property NAME $p]]} { return $p } }
    return ""
}
proc need {probes pat} {
    set p [find_probe $probes $pat]
    if {$p eq ""} { puts "ERROR: no probe matching '$pat' -- run the 'list' mode and fix the pattern"; exit 1 }
    puts "  matched '$pat' -> [get_property NAME $p]"
    return $p
}

set_property CONTROL.TRIGGER_MODE      BASIC_ONLY $ila
set_property CONTROL.TRIGGER_CONDITION OR         $ila
set_property CONTROL.CAPTURE_MODE      BASIC      $ila
set_property CONTROL.CAPTURE_CONDITION OR         $ila
# Most of the buffer is history: we want what led UP to the event.
set_property CONTROL.TRIGGER_POSITION [expr {[get_property CONTROL.DATA_DEPTH $ila] * 9 / 10}] $ila

# The storage qualifier is what makes a 1024-sample buffer usable here. Storing only cycles where a
# TCP event is actually valid stretches the window from ~4 us of wall time to seconds.
puts "storage qualifier:"
foreach pat {*tcp_open_req*valid* *tcp_close_req*valid* *tcp_notify*valid* *tcp_tx_stat*valid* *tcp_rx_meta*valid*} {
    set p [find_probe $probes $pat]
    if {$p ne ""} { set_property CAPTURE_COMPARE_VALUE eq1'b1 $p; puts "  + [get_property NAME $p]" }
}

puts "trigger:"
if {$mode eq "close"} {
    # Who hung up? tcp_close_req.valid firing means OUR rtl asked for the close. If the run wedges
    # with peer-closed and this never fires, MinIO closed it and the handler is not the culprit.
    set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes *tcp_close_req*valid*]
    # A second open is equally diagnostic: the connection is opened once and held.
    set p [find_probe $probes *tcp_open_req*valid*]
    if {$p ne ""} { set_property TRIGGER_COMPARE_VALUE eq1'b1 $p; puts "  also [get_property NAME $p]" }
} elseif {$mode eq "txerr"} {
    # tcp_tx_stat.data = {error[63:62], remaining_space[61:32], len[31:16], sid[15:0]}.
    # Any non-zero error means the TOE refused the send.
    set p [need $probes *tcp_tx_stat*data*]
    set_property TRIGGER_COMPARE_VALUE "eq64'b01[string repeat x 62]" $p
} else {
    puts "unknown mode '$mode'"; exit 1
}

run_hw_ila $ila
puts "ARMED -- start the query run now. Waiting up to 60 min."
wait_on_hw_ila -timeout 60 $ila

set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file ${out}.csv $data
write_hw_ila_data -force ${out}.ila            $data
puts "wrote ${out}.csv and ${out}.ila"
