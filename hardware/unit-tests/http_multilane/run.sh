#!/usr/bin/env bash
# rx_dispatch + N x tcp_read(EXTERNAL_DISPATCH=1): the multi-session receive path, end to end.
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
  "$HDL/axis_fifo.sv" "$HDL/strip_http.sv" "$HDL/tcp_read.sv" "$HDL/rx_dispatch.sv" \
  http_multilane_tb.sv
xelab -debug typical -timescale 1ns/1ps -top http_multilane_tb -snapshot http_multilane_tb_snap
xsim http_multilane_tb_snap -R
