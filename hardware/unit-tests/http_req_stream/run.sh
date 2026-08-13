#!/usr/bin/env bash
# Standalone xsim for http_req_stream -- host request bytes into the TCP transmit path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"
if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi
cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true
xvlog -sv ../http_pipeline/lynxTypes_stub.sv "$HDL/http_req_stream.sv" http_req_stream_tb.sv
xelab -debug typical -timescale 1ns/1ps -top http_req_stream_tb -snapshot req_stream_snap
xsim req_stream_snap -R
