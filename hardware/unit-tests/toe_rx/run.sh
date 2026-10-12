#!/usr/bin/env bash
# Standalone xsim (Vivado) for toe_rx -- the receive side for the TOE with per-session rings.
#   ./run.sh            every scenario
#   ./run.sh <scen>     one (fair slow solo small outlim stale bindcyc err_meta err_short err_stray budget)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv lynxTypes_stub.sv "$HDL/toe_rx.sv" toe_rx_tb.sv > xvlog.log 2>&1 || { tail -30 xvlog.log; exit 1; }
xelab -debug typical -timescale 1ns/1ps -top toe_rx_tb -snapshot toe_rx_tb_snap > xelab.log 2>&1 \
  || { tail -30 xelab.log; exit 1; }
A=()
[ $# -gt 0 ] && A=(-testplusarg "SCEN=$1")
out="$(xsim toe_rx_tb_snap -R "${A[@]}" 2>&1)"
echo "$out" | grep -E '^(PASS|FAIL)  toe_rx|^  \[cyc|\*\*\* ERROR|^toe_rx:'
echo "$out" | grep -qE '^toe_rx: 0 failed of [1-9]' || exit 1
