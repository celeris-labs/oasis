# OASIS DuckDB Extension: Simulation Setup & Execution Guide

This guide provides end-to-end, step-by-step instructions for configuring, building, simulating, and running the **OASIS DuckDB Extension** in hardware simulation mode (using Vivado Simulator `xsim` via Coyote Simulation, with no physical FPGA required).

---

## 1. System Architecture Overview

When running queries in DuckDB with OASIS in simulation mode:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. DuckDB Shell / Query Engine (extension/build/release/duckdb)│
│    • Executes SQL queries containing `read_oasis(...)`       │
│    • Statically links `oasis_extension`                     │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Oasis Query Optimizer (extension/src/oasis_optimizer.cpp)│
│    • Intercepts table joins between `read_oasis` scans      │
│    • Designates smaller table as BUILD, larger as PROBE     │
│    • Enables `runtime_bloom_enabled = true` on the probe    │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Oasis Hardware Bloom Engine & ParCore Decoders           │
│    • Schedules query splinters on stream 0                  │
│    • Pushes build keys to populate FPGA Bloom filter        │
│    • Streams probe keys through FPGA Bloom filter operator  │
│    • Zero-copies matching output batches to DuckDB vectors  │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Coyote Simulation Layer (`libcoyotesim.so`)              │
│    • Spawns and manages Vivado `xsim` background process    │
│    • Exchanges AXI stream beats via Unix named pipes (FIFOs)│
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Vivado SystemVerilog Simulation (`hardware/build-sim`)    │
│    • Simulates `BloomfilterOperator`, `BFConfig`,           │
│      `ColumnChunkDecoder`, `VHSNUnzip`, etc. in `xsim`      │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Prerequisites & Environment

Ensure you are working on a machine with AMD/Xilinx Vivado installed (e.g. `Vivado 2024.2`).

### Load Vivado Environment
```bash
module load vivado/2024.2

# Verify that Vivado and simulation binaries are in PATH
which vivado
which xsim
which xelab
```

---

## 3. Step-by-Step Build Instructions

All build artifacts will be installed cleanly into a local prefix (`$HOME/opt`).

### Step 3.1: Install `jemalloc` (Custom Prefix `je_`)
`libSTF` requires `jemalloc` configured with the `je_` symbol prefix:

```bash
cd /local/home/smalinin/oasis

# Run the provided jemalloc installer
./parcore/libstf/scripts/install_jemalloc.sh
```
*(Installs headers into `$HOME/opt/include/jemalloc` and library into `$HOME/opt/lib/libjemalloc.so`)*

---

### Step 3.2: Build and Install `CoyoteSimulation`
`libcoyotesim.so` provides the simulation driver that pipes software memory transfers to Vivado `xsim`:

```bash
cd /local/home/smalinin/oasis

# Ensure a clean build directory so CMake cache is always fresh
rm -rf parcore/libstf/coyote/sim/sw/build
mkdir -p parcore/libstf/coyote/sim/sw/build

cmake -S parcore/libstf/coyote/sim/sw -B parcore/libstf/coyote/sim/sw/build \
  -DCMAKE_INSTALL_PREFIX=$HOME/opt

cmake --build parcore/libstf/coyote/sim/sw/build -j
cmake --install parcore/libstf/coyote/sim/sw/build
```

---

### Step 3.3: Build and Install the `software` Library Stack
This compiles `liblibstf.so`, `libparcore.so`, and `liboasis.so` with simulation mode enabled and installs them into `$HOME/opt/lib`:

```bash
cd /local/home/smalinin/oasis

# Always clean software/build before reconfiguring to prevent stale CMake caches
rm -rf software/build
mkdir -p software/build

cmake -S software -B software/build \
  -DEN_SIMULATION=ON \
  -DCMAKE_INSTALL_PREFIX=$HOME/opt \
  -DCMAKE_PREFIX_PATH=$HOME/opt \
  -DJEMALLOC_LIBRARIES=$HOME/opt/lib/libjemalloc.so \
  -DJEMALLOC_INCLUDE_DIRS=$HOME/opt/include

cmake --build software/build -j
cmake --install software/build
```

---

### Step 3.4: Generate the Vivado Hardware Simulation Project
Generate (or refresh) the Vivado hardware simulation project to package all SystemVerilog modules (including `BFConfig`, `BloomfilterOperator`, `BloomfilterBank`, etc.):

```bash
cd /local/home/smalinin/oasis

./scripts/setup_simulation.sh
```
*(This creates `hardware/build-sim/sim/oasis.xpr` and prepares the simulation scripts)*

---

### Step 3.5: Build the DuckDB Extension
Build DuckDB with the OASIS extension statically linked:

```bash
cd /local/home/smalinin/oasis/extension

# Clean any previous configuration cache to force re-linking against $HOME/opt/lib
make clean

# Compile DuckDB with Oasis
export CMAKE_PREFIX_PATH=$HOME/opt:$CMAKE_PREFIX_PATH
make -j
```

The output binary is located at:
* `./build/release/duckdb`

---

### Quick Rebuild Helper (After Any Code Edits)
Whenever you modify C++ code in `software/` (`liboasis.so`) or `extension/src/`, run this single command chain to ensure all libraries and the DuckDB binary are completely up to date:

```bash
# 1. Rebuild and reinstall software stack
cd /local/home/smalinin/oasis && \
rm -rf software/build && \
cmake -S software -B software/build -DEN_SIMULATION=ON \
  -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt \
  -DJEMALLOC_LIBRARIES=$HOME/opt/lib/libjemalloc.so \
  -DJEMALLOC_INCLUDE_DIRS=$HOME/opt/include && \
cmake --build software/build -j && \
cmake --install software/build && \
# 2. Rebuild DuckDB extension
cd /local/home/smalinin/oasis/extension && \
export CMAKE_PREFIX_PATH=$HOME/opt:$CMAKE_PREFIX_PATH && \
make clean && make -j
```

---

## 4. Running the Extension in Simulation

### Step 4.1: Generate Sample Test Parquet Files
Use the Python data generator in `extension/perf` to create sample `build` and `probe` Parquet tables:

```bash
cd /local/home/smalinin/oasis/extension/perf

# Activate Python environment
./scripts/setup_venv.sh
source .venv/bin/activate

# Generate a small test dataset
python -m oasis_perf.generate_data \
  --out /tmp/oasis_bf_test \
  --build-rows 1000 \
  --probe-rows 10000 \
  --match-rate 0.1 \
  --payload-cols 1
```

This creates:
* `/tmp/oasis_bf_test/build.parquet` (Build table, 1,000 rows)
* `/tmp/oasis_bf_test/probe.parquet` (Probe table, 10,000 rows, 10% match rate)

---

### Step 4.2: Export Required Runtime Variables

In your active terminal session:

```bash
# 1. Vivado environment
module load vivado/2024.2

# 2. Location of the hardware simulation project
export COYOTE_SIM_DIR=/local/home/smalinin/oasis/hardware/build-sim

# 3. Path to custom installed libraries
export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH

# 4. Enable verbose logging for the hardware Bloom filter
export OASIS_HW_BLOOM_VERBOSE=1
```

---

### Step 4.3: Launch DuckDB and Run Queries

```bash
cd /local/home/smalinin/oasis/extension
./build/release/duckdb
```

Execute a join query in DuckDB using `read_oasis`:

```sql
SELECT count(*)
FROM read_oasis('/tmp/oasis_bf_test/probe.parquet') p
JOIN read_oasis('/tmp/oasis_bf_test/build.parquet') b
ON p.key = b.key;
```

---

## 5. Expected Output & Log Verification

With `OASIS_HW_BLOOM_VERBOSE=1`, you will observe the complete lifecycle in the console:

```text
[OASIS][OPT] registered optimizer extension through ExtensionCallbackManager
[OASIS][SCAN] bind read_oasis('/tmp/oasis_bf_test/probe.parquet'), columns=1, row_groups=1
[OASIS][SCAN] bind read_oasis('/tmp/oasis_bf_test/build.parquet'), columns=2, row_groups=1
[OASIS][OPT] found read_oasis equi-join
[OASIS][OPT] build file   = /tmp/oasis_bf_test/build.parquet
[OASIS][OPT] probe file   = /tmp/oasis_bf_test/probe.parquet
[OASIS][OPT] rewrite done: probe read_oasis bind_data marked runtime_bloom_enabled=true
[OASIS][HW_BLOOM] Bloom plan: build_groups=1 probe_groups=1 build_beats=125 probe_beats=1250
[OASIS][HW_BLOOM] enqueue BUILD group=0 beats=125
[OASIS][HW_BLOOM] enqueue PROBE group=0 beats=1250
[OASIS][HW_BLOOM] BF counters after output: build=... probe=...
┌──────────────┐
│ count_star() │
│    int64     │
├──────────────┤
│     1000     │
└──────────────┘
```

---

## 6. Troubleshooting & Common Pitfalls

| Issue | Cause | Fix |
|---|---|---|
| `Table Function with name read_oasis does not exist!` | DuckDB was built before `oasis` was configured, or `make` failed. | Ensure `software` is installed to `$HOME/opt`, clean with `make clean`, and re-run `make -j`. |
| `libcoyotesim.so: cannot open shared object file` | Runtime linker cannot find `$HOME/opt/lib`. | Run `export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH`. |
| `[FATAL] you must set the COYOTE_SIM_DIR environment variable` | `COYOTE_SIM_DIR` is not set or points to a non-existent directory. | Run `export COYOTE_SIM_DIR=/local/home/smalinin/oasis/hardware/build-sim`. |
| `[FATAL] cThread.cpp: Thread with id 0 crashed` / `xelab: command not found` | Vivado binaries are not in `$PATH`. | Run `module load vivado/2024.2` (or `source /tools/Xilinx/Vivado/2024.2/settings64.sh`). |
| `ERROR: [VRFC 10-2063] Module <BFConfig> not found` | `hardware/build-sim` is out of date and missing newly added HDL modules. | Re-run `./scripts/setup_simulation.sh` with Vivado loaded. |

