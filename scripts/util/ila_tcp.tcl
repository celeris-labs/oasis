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

puts "targets:  [get_hw_targets]"
puts "devices:  [get_hw_devices]"

set dev [lindex [get_hw_devices *xcu55c*] 0]
if {$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
if {$dev eq ""} { puts "ERROR: no device on the target at all -- is the board visible to the hw_server?"; exit 1 }
current_hw_device $dev
puts "using:    $dev"

set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
# NO -update_hw_probes false here. That flag skips probe enumeration, and then get_hw_ilas finds
# nothing however correct the ltx is. Probe discovery is the entire reason we are refreshing.
refresh_hw_device $dev

set ila [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ *ila_perf_tcp*}] 0]
if {$ila eq ""} { set ila [lindex [get_hw_ilas -filter {CELL_NAME =~ *ila_perf_tcp*}] 0] }
if {$ila eq ""} {
    puts "----------------------------------------------------------------"
    puts "ila_perf_tcp not found."
    puts "PROBES.FILE      = [get_property PROBES.FILE $dev]"
    puts "FULL_PROBES.FILE = [get_property FULL_PROBES.FILE $dev]"
    set all [get_hw_ilas]
    if {[llength $all] == 0} {
        puts "NO ILAs of any kind were enumerated."
        puts "That means the debug hub was not reached, not that the probe map is wrong."
        puts "Most likely the bitstream on the board is not the one this ltx describes --"
        puts "check that build-\$BUILD matches what program_hacc_local.sh actually loaded."
    } else {
        puts "ILAs that WERE found:"
        foreach i $all { puts "  [get_property CELL_NAME $i]" }
    }
    puts "debug cores:"
    foreach c [get_hw_devices] { puts "  device $c" }
    puts "----------------------------------------------------------------"
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

# Not every CONTROL property is writable: they depend on how the IP was generated. TRIGGER_MODE is
# read-only unless C_ADV_TRIGGER was set, and DATA_DEPTH is fixed at build time. Setting one of
# those is not an error worth aborting on -- the value it is stuck at is the value we wanted.
proc try_set {obj prop val} {
    if {[catch {set_property $prop $val $obj} err]} {
        set cur "?"
        catch {set cur [get_property $prop $obj]}
        puts "  note: $prop not writable (stuck at $cur) -- continuing"
        return 0
    }
    return 1
}

# Reset every probe to don't-care in both the trigger and the storage qualifier. Vivado otherwise
# keeps whatever a previous session left set, which silently changes what you are measuring.
foreach p $probes {
    set w [get_property WIDTH $p]
    set x "eq${w}'b[string repeat x $w]"
    set_property TRIGGER_COMPARE_VALUE $x $p
    set_property CAPTURE_COMPARE_VALUE $x $p
}

try_set $ila CONTROL.TRIGGER_MODE BASIC_ONLY
try_set $ila CONTROL.CAPTURE_MODE BASIC
try_set $ila CONTROL.CAPTURE_CONDITION OR
# Keep most of the buffer as history: we want what led UP to the event, not what followed it.
try_set $ila CONTROL.TRIGGER_POSITION [expr {$depth * 9 / 10}]

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
        try_set $ila CONTROL.TRIGGER_CONDITION AND
        set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes *tcp_notify*valid*]
        set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes {*tcp_notify*closed*}]
    }
    weclose {
        try_set $ila CONTROL.TRIGGER_CONDITION AND
        set_property TRIGGER_COMPARE_VALUE eq1'b1 [need $probes *tcp_close_req*valid*]
    }
    txerr {
        try_set $ila CONTROL.TRIGGER_CONDITION AND
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
