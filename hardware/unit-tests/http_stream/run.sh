#!/usr/bin/env bash
# Standalone xsim for handler_stream: the host streams pre-built request text, the queue holds one
# bit per response. Same TOE model as the http_pipeline bench.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"
if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi
cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true
xvlog -sv ${TRACE:+-d TRACE} \
  ../http_pipeline/lynxTypes_stub.sv \
  "$HDL/http_types.sv" \
  "$HDL/tcp_session_table.sv" \
  "$HDL/tcp_init.sv" \
  "$HDL/http_req_stream.sv" \
  "$HDL/axis_fifo.sv" \
  "$HDL/axis_rewrite_last.sv" \
  "$HDL/strip_http.sv" \
  "$HDL/tcp_read.sv" \
  "$HDL/handler_stream.sv" \
  http_stream_tb.sv
xelab -debug typical -timescale 1ns/1ps -top http_stream_tb -snapshot http_stream_snap
xsim http_stream_snap -R
