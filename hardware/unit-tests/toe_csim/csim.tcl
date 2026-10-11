# toe_csim: csim_design of toe_top with the toe_csim testbench (driven by run.sh, which exports
# TOE_DIR, CFG_DIR, TB_DIR, SRCS and CASES).
set toe   $::env(TOE_DIR)
set cfg   $::env(CFG_DIR)
set tb    $::env(TB_DIR)
set cases $::env(CASES)

open_project -reset toe_csim_prj
set_top toe_top

add_files $toe/../axi_utils.cpp
foreach src $::env(SRCS) {
  add_files $toe/$src -cflags "-std=c++11 -I$cfg"
}
add_files -tb $tb/toe_csim_tb.cpp -cflags "-std=c++14 -I$cfg -I$toe"
add_files -tb $tb/tb_model.hpp

open_solution -reset solution1 -flow_target vivado
set_part xcu55c-fsvh2892-2L-e
create_clock -period 4 -name default

if {[catch {csim_design -O -argv $cases} err]} {
  puts "csim_design reported: $err"
}
exit
