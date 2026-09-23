#!/usr/bin/env bash
# decoder_numvalues -- ColumnChunkDecoder must put exactly one tlast on its output per column chunk,
# after exactly that chunk's values, also when its front end runs a chunk ahead of a slow output.
# See the header of decoder_numvalues_tb.sv for the build-124 wedge this reproduces.
#
#   ./run.sh                     every case; exit status 1 if any of them fails
#   ./run.sh <SCEN> <OUTDIV> [BIG]   one case (SCEN 0..4, see the tb header)
#
# The DUT is the REAL decoder: parcore + libstf SystemVerilog and vhsnunzip's VHDL, elaborated with
# the lynx_pkg a Coyote build generated (LYNX_PKG=..., default build-124's).
# PARCORE=<dir> points at another parcore tree (e.g. a pre-fix copy for a before/after run).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
PARCORE="${PARCORE:-$REPO/parcore}"
LIBSTF="$PARCORE/libstf"
COYOTE="$LIBSTF/coyote/hw/hdl"
VHS="$PARCORE/vhsnunzip/src/hdl"
LYNX_PKG="${LYNX_PKG:-$REPO/hardware/build-124/oasis_shell/hdl/lynx_pkg.sv}"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log runs xvlog.pb xvhdl.pb xelab.pb webtalk* .Xil *.wdb 2>/dev/null || true

xvhdl -2008 "$VHS/vhsnunzip_utils_pkg.vhd" "$VHS/vhsnunzip_int_pkg.vhd" "$VHS/vhsnunzip_pkg.vhd" \
      "$VHS/vhsnunzip_srl.vhd" "$VHS/vhsnunzip_ram.sim.vhd" "$VHS/vhsnunzip_fifo.vhd" \
      "$VHS/vhsnunzip_pre_decoder.vhd" "$VHS/vhsnunzip_decoder.vhd" "$VHS/vhsnunzip_decoder_long.vhd" \
      "$VHS/vhsnunzip_decoder_dual.vhd" "$VHS/vhsnunzip_cmd_gen_1.vhd" "$VHS/vhsnunzip_cmd_gen_1_dual.vhd" \
      "$VHS/vhsnunzip_cmd_gen_2.vhd" "$VHS/vhsnunzip_cmd_gen_2_dual.vhd" "$VHS/vhsnunzip_execute_dual.vhd" \
      "$VHS/vhsnunzip_pipeline.vhd" "$VHS/vhsnunzip_pipeline_dual.vhd" "$VHS/vhsnunzip_unbuffered.vhd" \
      "$VHS/vhsnunzip_unbuffered_small.vhd" \
      "$LIBSTF/hardware/src/hdl/fifo/fifo.vhd" \
      "$LIBSTF/hardware/src/hdl/util/shift_register.vhd" > xvhdl.log 2>&1 || { tail -30 xvhdl.log; exit 1; }

LS_FIRST=("$LIBSTF/hardware/src/hdl/common.sv" "$LIBSTF/hardware/src/hdl/data_interfaces.sv"
          "$LIBSTF/hardware/src/hdl/util/util_interfaces.sv" "$LIBSTF/hardware/src/hdl/config/config_interfaces.sv")
mapfile -t LS_REST < <(find "$LIBSTF/hardware/src/hdl" -name '*.sv' \
  | grep -v -e '/common.sv$' -e 'data_interfaces.sv$' -e 'util_interfaces.sv$' -e 'config_interfaces.sv$' | sort)
mapfile -t PC_REST < <(ls "$PARCORE"/hardware/src/hdl/*.sv | grep -v '/common.sv$')

xvlog -sv -i "$COYOTE/pkg" -i "$LIBSTF/hardware/src/hdl" -i "$LIBSTF/hardware/src/hdl/config" \
      -i "$PARCORE/hardware/src/hdl" \
      "$LYNX_PKG" "$COYOTE/pkg/axi_intf.sv" "$COYOTE/pkg/lynx_intf.sv" \
      "${LS_FIRST[@]}" "${LS_REST[@]}" "$PARCORE/hardware/src/hdl/common.sv" "${PC_REST[@]}" \
      decoder_numvalues_tb.sv > xvlog.log 2>&1 || { grep -E 'ERROR' xvlog.log | head -30; exit 1; }

xelab -O3 -timescale 1ns/1ps -top decoder_numvalues_tb -snapshot dnv > xelab.log 2>&1 \
  || { grep -E 'ERROR' xelab.log | head -30; exit 1; }

# Each case is minutes of xsim wall clock however short the run, so the cases run in parallel. xsim
# writes its plusargs into the snapshot's xsim_script.tcl, so two runs of ONE snapshot overwrite each
# other's arguments: every case gets its own copy of the snapshot under runs/<scen>_<outdiv>/.
CASES=()
add() { CASES+=("$*"); }
run_case() { # <scen> <outdiv> [big]
  local d="runs/$1_$2"
  rm -rf "$d" && mkdir -p "$d" && cp -r xsim.dir "$d/" || return 1
  ( cd "$d" && xsim dnv -R -log case.log -testplusarg "SCEN=$1" -testplusarg "OUTDIV=$2" \
       -testplusarg "BIG=${3:-256}" -testplusarg "BUDGET=20000" > /dev/null 2>&1 )
}
report() { # <scen> <outdiv>
  local l="runs/$1_$2/case.log"
  grep -E '^Fatal' "$l" | sed 's/^/  /'
  grep -E '^decoder_numvalues' "$l" | sed 's/^/  /'
  grep -q '^decoder_numvalues: PASS' "$l"
}

if [ $# -ge 2 ]; then
  run_case "$@"
  report "$1" "$2"
  exit $?
fi

add 0 1; add 3 1                  # output always ready: the front end never gets a chunk ahead
add 0 16; add 2 16                # slow output, confs queued up front, 2-beat tiny chunks
add 3 16; add 4 16; add 4 64      # slow output, ONE-beat chunk (region-like): the build-124 wedge
add 1 16                          # slow output, host writes the next conf late
for c in "${CASES[@]}"; do run_case $c & done
wait

FAILS=0
for c in "${CASES[@]}"; do
  set -- $c
  echo "== SCEN=$1 OUTDIV=$2"
  report "$1" "$2" || FAILS=$((FAILS + 1))
done
echo "decoder_numvalues: $FAILS failed case(s)"
exit $(( FAILS > 0 ))
