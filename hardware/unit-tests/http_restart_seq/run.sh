#!/usr/bin/env bash
# Standalone xsim (Vivado) for http_restart_seq.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../archive/http_read"   # retired from the design; see archive README
OUT="$ROOT/xsim.dir"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf "$OUT" xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv "$HDL/http_restart_seq.sv" http_restart_seq_tb.sv
xelab -debug typical -timescale 1ns/1ps -top http_restart_seq_tb -snapshot http_restart_seq_tb_snap
xsim http_restart_seq_tb_snap -R
