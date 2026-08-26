#!/usr/bin/env bash
# tx_arbiter -- round-robin grant for N claimants sharing one TOE transmit interface.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv "$HDL/tx_arbiter.sv" tx_arbiter_tb.sv
xelab -debug typical -timescale 1ns/1ps -top tx_arbiter_tb -snapshot tx_arbiter_tb_snap
xsim tx_arbiter_tb_snap -R
