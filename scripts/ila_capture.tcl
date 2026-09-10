# Capture both regex ILAs on whatever state the card is in RIGHT NOW.
# trigger_now, not a real trigger: a wedge is a *static* state, so there is no
# edge to trigger on -- we just want a snapshot of the frozen counters.
# NEVER call program_hw_devices here: the point is to observe, not disturb.
set tag [lindex $argv 0]
set out [lindex $argv 1]
set ltx /local/home/vifranz/celeris/build_hw_undercount/bitstreams/cyt_top.ltx

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
foreach d [get_hw_devices] { puts "**** DEVICE $d" }
current_hw_device $dev
set_property PROBES.FILE     $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev

set ilas [get_hw_ilas]
puts "**** ILAS $ilas"
foreach ila $ilas {
    set cell [get_property CELL_NAME [get_hw_ilas $ila]]
    puts "**** ILA $ila cell=$cell"
}
foreach ila $ilas {
    set cell [get_property CELL_NAME [get_hw_ilas $ila]]
    # capture everything, no trigger condition
    set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $ila]
    run_hw_ila -trigger_now [get_hw_ilas $ila]
    wait_on_hw_ila -timeout 1 [get_hw_ilas $ila]
    if {[catch {set st [get_property CORE_STATUS [get_hw_ilas $ila]]}]} { set st "n/a" }
    puts "**** $ila cell=$cell status=$st"
    set d [upload_hw_ila_data [get_hw_ilas $ila]]
    set safe [string map {/ _} $cell]
    write_hw_ila_data -force ${out}/${tag}_${safe}.ila $d
    puts "**** WROTE ${out}/${tag}_${safe}.ila"
}
puts "**** DONE"
