# -------------------------------------------------------------------------------------------------
# Drive ila_perf_tcp on the RUNNING board. Never programs the device: the whole point is to watch
# the state a run built up, and reloading the bitstream destroys exactly that.
#
#   vivado -mode batch -source ila_tcp.tcl -tclargs <mode> <cyt_top.ltx> [out]
#
#   list       print every probe name the ltx carries, and exit
#   peerclose  MinIO hung up      -> tcp_notify.valid & tcp_notify.data[closed]
#   weclose    our RTL hung up    -> tcp_close_req.valid
#   txerr      TOE refused a send -> tcp_tx_stat.valid & tcp_tx_stat.data[error] != 0
#
# peerclose vs weclose is the measurement that splits the bug in half. Run peerclose first.
# -------------------------------------------------------------------------------------------------
set mode [lindex $argv 0]
set ltx  [lindex $argv 1]
set out  [lindex $argv 2]
if {$out eq ""} { set out "ila_capture" }
if {$mode eq "" || $ltx eq ""} { puts "usage: -tclargs <list|peerclose|weclose|txerr> <ltx> \[out\]"; exit 1 }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices *xcu55c*] 0]
if {$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
current_hw_device $dev
puts "device: $dev"

set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes false $dev

set ila [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ *ila_perf_tcp*}] 0]
if {$ila eq ""} {
    puts "ila_perf_tcp not found. ILAs on this device:"
    foreach i [get_hw_ilas -of_objects $dev] { puts "  [get_property CELL_NAME $i]" }
    exit 1
}
set depth [get_property CONTROL.DATA_DEPTH $ila]
puts "ila: [get_property CELL_NAME $ila]   depth=$depth samples"

set probes [get_hw_probes -of_objects $ila]

if {$mode eq "list"} {
    foreach p $probes { puts [format "  %-4s %s" [get_property WIDTH $p] [get_property NAME $p]] }
    exit 0
}

proc find_probe {probes pat} {
    foreach p $probes { if {[string match -nocase $pat [get_property NAME $p]]} { return $p } }
    return ""
}
proc need {probes pat} {
    set p [find_probe $probes $pat]
    if {$p eq ""} { puts "ERROR: no probe matches '$pat' -- run 'list' mode and fix the pattern"; exit 1 }
    puts "    [get_property NAME $p]"
    return $p
}

# Reset every probe to don't-care in both the trigger and the storage qualifier. Vivado otherwise
# keeps whatever a previous session left set, which silently changes what you are measuring.
foreach p $probes {
    set w [get_property WIDTH $p]
    set x "eq${w}'b[string repeat x $w]"
    set_property TRIGGER_COMPARE_VALUE $x $p
    set_property CAPTURE_COMPARE_VALUE $x $p
}

set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila
set_property CONTROL.CAPTURE_MODE BASIC      $ila
set_property CONTROL.CAPTURE_CONDITION OR    $ila
# Keep most of the buffer as history: we want what led UP to the event, not what followed it.
set_property CONTROL.TRIGGER_POSITION [expr {$depth * 9 / 10}] $ila

# The storage qualifier is what makes a 1024-sample buffer usable. Storing only cycles on which a
# TCP event is actually valid stretches the window from ~4 us of wall clock to seconds of run time.
puts "storage qualifier (capture only these cycles):"
foreach pat {*tcp_open_req*valid* *tcp_open_rsp*valid* *tcp_close_req*valid*
             *tcp_notify*valid* *tcp_tx_meta*valid* *tcp_tx_stat*valid* *tcp_rx_meta*valid*} {
    set p [find_probe $probes $pat]
    if {$p ne ""} { set_property CAPTURE_COMPARE_VALUE eq1'b1 $p; puts "    [get_property NAME $p]" }
}

puts "trigger:"
switch -- $mode {
    peerclose {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes *tcp_notify*valid*]
        set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes {*tcp_notify*closed*}]
    }
    weclose {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes *tcp_close_req*valid*]
    }
    txerr {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        set_property TRIGGER_COMPARE_VALUE eq1'b1  [need $probes *tcp_tx_stat*valid*]
        set_property TRIGGER_COMPARE_VALUE neq2'b00 [need $probes {*tcp_tx_stat*error*}]
    }
    default { puts "unknown mode '$mode'"; exit 1 }
}

run_hw_ila $ila
puts ""
puts "ARMED. Start the query run now -- it stays armed through the queries that pass."
puts "Waiting up to 60 minutes for the trigger."
if {[catch {wait_on_hw_ila -timeout 60 $ila} err]} {
    puts "NO TRIGGER within the timeout: $err"
    puts "For peerclose that is itself the answer -- nobody sent a close notification."
    exit 2
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file ${out}.csv $data
write_hw_ila_data -force ${out}.ila           $data
puts "TRIGGERED. wrote ${out}.csv and ${out}.ila"
