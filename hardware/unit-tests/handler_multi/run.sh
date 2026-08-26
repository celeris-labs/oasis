#!/usr/bin/env bash
# handler_multi -- N TCP sessions, one per decoder lane, end to end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv lynxTypes_stub.sv \
  "$HDL/http_types.sv" "$HDL/axis_fifo.sv" "$HDL/strip_http.sv" "$HDL/tcp_read.sv" \
  "$HDL/rx_dispatch.sv" "$HDL/tcp_init.sv" "$HDL/http_req_stream.sv" \
  "$HDL/axis_rewrite_last.sv" "$HDL/tx_arbiter.sv" "$HDL/handler_multi.sv" \
  handler_multi_tb.sv
xelab -debug typical -timescale 1ns/1ps -top handler_multi_tb -snapshot handler_multi_tb_snap
xsim handler_multi_tb_snap -R
