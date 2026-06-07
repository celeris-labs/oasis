#!/bin/bash
COYOTE_SIM_DIR=$(pwd)/../hardware/build-sim ./build/release/duckdb -init data/tpch/tpch_init.sql