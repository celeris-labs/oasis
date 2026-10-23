#!/usr/bin/env bash
# toe_csim -- C simulation of the Coyote TCP offload engine (toe_top) with its receive buffer in
# card memory (RX_DDR_BYPASS = 0), at the build's configuration: 512-bit data path, MSS 4096,
# 512 sessions, TCP_NODELAY, fast retransmit, window scaling with WINDOW_SCALE_BITS 4, so
# WINDOW_BITS 20 = a 1 MiB ring per session. toe_config.hpp is generated here from the submodule's
# toe_config.hpp.in exactly as CMake would for a --toe-buffer build.
#
# The testbench (toe_csim_tb.cpp, tb_model.hpp) plays the remote server, the application and the
# card memory; see the header of toe_csim_tb.cpp for what each case checks. Every case runs in its
# own process, all in parallel; per-case logs land in $BUILD_DIR/logs/<case>.log.
#
#   ./run.sh                     csim_design (Vitis HLS 2024.2, as the builds use), all cases
#   ./run.sh c1,c4               ...a selection
#   ./run.sh --gxx [cases]       the same sources compiled with the host g++ against the Vitis HLS
#                                headers -- quick iteration only, the gate is csim_design
#   ./run.sh --synth [0|1]       csynth_design of toe_top with the build's flow (make.tcl.in: 4 ns
#                                clock, default uncertainty, config_rtl -reset all -reset_level low)
#                                with RX_DDR_BYPASS 0 (default) or 1; report in
#                                $BUILD_DIR/synth-bypass<N>/toe_prj/solution1/syn/report/csynth.rpt
#
#   TOE_DIR=<.../hls/toe>        TOE sources to use (default: this checkout's network submodule,
#                                which hardware/patches/apply.sh has patched); e.g. a copy with
#                                patch 0007 reverted, to see the cases fail
#   BUILD_DIR=<dir>              Vitis HLS projects and logs (default: ./build, git-ignored)
#
# Exit status 1 if any case failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
TOE_DIR="${TOE_DIR:-$REPO/parcore/libstf/coyote/hw/services/network/hls/toe}"
TOE_DIR="$(cd "$TOE_DIR" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
VITIS_HLS="${VITIS_HLS:-/tools/Xilinx/Vitis_HLS/2024.2/bin/vitis_hls}"
HLS_INC="${HLS_INC:-/tools/Xilinx/Vitis/2024.2/include}"

MODE=csim
BYPASS=0
CASES=all
case "${1:-}" in
  --synth) MODE=synth; BYPASS="${2:-0}" ;;
  --gxx)   MODE=gxx;   CASES="${2:-all}" ;;
  "")      ;;
  *)       CASES="$1" ;;
esac
[ "$MODE" = csim ] || [ "$MODE" = gxx ] && BYPASS=0

# the source list of make.tcl.in, in its order
SRCS="ack_delay/ack_delay.cpp close_timer/close_timer.cpp event_engine/event_engine.cpp
port_table/port_table.cpp probe_timer/probe_timer.cpp retransmit_timer/retransmit_timer.cpp
rx_app_if/rx_app_if.cpp rx_app_stream_if/rx_app_stream_if.cpp rx_engine/rx_engine.cpp
rx_sar_table/rx_sar_table.cpp session_lookup_controller/session_lookup_controller.cpp
state_table/state_table.cpp tx_app_if/tx_app_if.cpp tx_app_stream_if/tx_app_stream_if.cpp
tx_engine/tx_engine.cpp tx_sar_table/tx_sar_table.cpp tx_app_interface/tx_app_interface.cpp toe.cpp"

# toe_config.hpp the way CMake's configure_file writes it (the builds' values, RX_DDR_BYPASS varied)
CFG_DIR="$BUILD_DIR/cfg-bypass$BYPASS"
mkdir -p "$CFG_DIR"
sed -e 's/\${TCP_STACK_MSS}/4096/' \
    -e 's/\${TCP_STACK_MAX_SESSIONS}/512/' \
    -e 's/\${DATA_WIDTH}/64/' \
    -e 's/\${TCP_STACK_NODELAY_EN}/1/' \
    -e "s/\\\${TCP_STACK_RX_DDR_BYPASS_EN}/$BYPASS/" \
    -e 's/\${TCP_STACK_FAST_RETRANSMIT_EN}/1/' \
    -e 's/\${TCP_STACK_WINDOW_SCALING_EN}/1/' \
    "$TOE_DIR/toe_config.hpp.in" > "$CFG_DIR/toe_config.hpp"
if grep -q '\${' "$CFG_DIR/toe_config.hpp"; then
  echo "run.sh: unsubstituted variable in toe_config.hpp:" >&2
  grep -n '\${' "$CFG_DIR/toe_config.hpp" >&2
  exit 2
fi

export TOE_DIR CFG_DIR TB_DIR="$ROOT" SRCS CASES
echo "run.sh: mode $MODE, TOE sources $TOE_DIR, RX_DDR_BYPASS $BYPASS, build dir $BUILD_DIR"

case "$MODE" in
csim)
  WORK="$BUILD_DIR/csim"
  rm -rf "$WORK"; mkdir -p "$WORK"
  export TOE_CSIM_LOGDIR="$BUILD_DIR/logs"
  rm -rf "$TOE_CSIM_LOGDIR"; mkdir -p "$TOE_CSIM_LOGDIR"
  ( cd "$WORK" && "$VITIS_HLS" -f "$ROOT/csim.tcl" ) > "$BUILD_DIR/csim.log" 2>&1
  rc=$?
  sed -n '/^toe_csim results/,/^toe_csim: .* case(s)/p' "$BUILD_DIR/csim.log"
  if ! grep -q '^toe_csim: 0 failed' "$BUILD_DIR/csim.log"; then
    echo "run.sh: csim FAILED (vitis_hls rc $rc) -- see $BUILD_DIR/csim.log and $TOE_CSIM_LOGDIR/" >&2
    exit 1
  fi
  ;;
gxx)
  WORK="$BUILD_DIR/gxx"
  mkdir -p "$WORK"
  export TOE_CSIM_LOGDIR="$BUILD_DIR/logs-gxx"
  rm -rf "$TOE_CSIM_LOGDIR"; mkdir -p "$TOE_CSIM_LOGDIR"
  OBJS=""
  pids=""
  for s in ../axi_utils.cpp $SRCS; do
    o="$WORK/$(echo "$s" | tr '/.' '__').o"
    OBJS="$OBJS $o"
    g++ -O2 -std=c++11 -w -D__VITIS_HLS__ -I"$HLS_INC" -I"$CFG_DIR" -c "$TOE_DIR/$s" -o "$o" &
    pids="$pids $!"
  done
  g++ -O2 -std=c++14 -w -D__VITIS_HLS__ -I"$HLS_INC" -I"$CFG_DIR" -I"$TOE_DIR" -c "$ROOT/toe_csim_tb.cpp" \
      -o "$WORK/tb.o" &
  pids="$pids $!"
  fail=0
  for p in $pids; do wait "$p" || fail=1; done
  [ $fail = 0 ] || { echo "run.sh: compile failed" >&2; exit 2; }
  g++ -o "$WORK/toe_csim" $OBJS "$WORK/tb.o" || exit 2
  "$WORK/toe_csim" "$CASES"
  ;;
synth)
  WORK="$BUILD_DIR/synth-bypass$BYPASS"
  rm -rf "$WORK"; mkdir -p "$WORK"
  ( cd "$WORK" && "$VITIS_HLS" -f "$ROOT/synth.tcl" ) > "$WORK/vitis_hls.log" 2>&1
  rc=$?
  RPT="$WORK/toe_prj/solution1/syn/report/csynth.rpt"
  [ -f "$RPT" ] || { echo "run.sh: csynth failed (rc $rc), see $WORK/vitis_hls.log" >&2; exit 1; }
  grep -m1 'Estimated Fmax' "$WORK/vitis_hls.log"
  # the top row of the performance & resource table: slack (vs period - uncertainty), BRAM, DSP, FF, LUT, URAM
  grep -m1 -B4 -E '^ *\|\+ toe_top' "$RPT" | grep -E 'Slack|toe_top'
  echo "run.sh: report $RPT"
  ;;
esac
