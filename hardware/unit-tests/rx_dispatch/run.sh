#!/usr/bin/env bash
# Standalone xsim (Vivado) for rx_dispatch -- the arrival-order receive dispatcher.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv lynxTypes_stub.sv "$HDL/rx_dispatch.sv" rx_dispatch_tb.sv
xelab -debug typical -timescale 1ns/1ps -top rx_dispatch_tb -snapshot rx_dispatch_tb_snap
xsim rx_dispatch_tb_snap -R
