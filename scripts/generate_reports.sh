#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DIR=${1:-.}
cd "$DIR"

vivado -mode batch -source "$SCRIPT_DIR"/tcl/generate_reports.tcl
