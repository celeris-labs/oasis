#!/usr/bin/env bash
# Standalone xsim (Vivado) for tcp_read (+ strip_http).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"
OUT="$ROOT/xsim.dir"

# Source Vivado if needed
if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf "$OUT" xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv lynxTypes_stub.sv "$HDL/tcp_session_table.sv" "$HDL/axis_fifo.sv" "$HDL/strip_http.sv" \
          "$HDL/tcp_read.sv" tcp_read_tb.sv
xelab -debug typical -timescale 1ns/1ps -top tcp_read_tb -snapshot tcp_read_tb_snap
xsim tcp_read_tb_snap -R
