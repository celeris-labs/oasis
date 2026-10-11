# toe_csim: csynth_design of toe_top with the flow of the submodule's make.tcl.in (what the bitstream
# builds run), minus export_design. Driven by run.sh --synth, which exports TOE_DIR, CFG_DIR, SRCS.
set toe $::env(TOE_DIR)
set cfg $::env(CFG_DIR)

open_project -reset toe_prj
open_solution -reset solution1
set_part xcu55c-fsvh2892-2L-e

create_clock -period 4 -name default
# make.tcl.in passes an unset ${CLOCK_UNCERTAINTY} here, i.e. the HLS default (27 % = 1.08 ns)
set_clock_uncertainty default

set_top toe_top

add_files $toe/../axi_utils.cpp
foreach src $::env(SRCS) {
  add_files $toe/$src -cflags "-std=c++11 -I$cfg"
}

config_rtl -reset all -reset_level low

csynth_design
exit
