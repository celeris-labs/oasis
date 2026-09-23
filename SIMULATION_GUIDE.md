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
The repository must also have its submodules initialized, and the host needs a C++17 toolchain,
CMake, Make, Boost, Python 3, and the Python `pyarrow` package.

From the repository root, initialize the required submodules if needed:

```bash
git submodule update --init extension/duckdb extension/extension-ci-tools
git submodule update --init --recursive parcore celeris
```

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
This compiles `liblibstf.so`, `libparcore.so`, and `liboasis.so` and installs them into `$HOME/opt/lib`.
Simulation mode is selected later when the DuckDB extension is configured.

```bash
cd /local/home/smalinin/oasis

# Always clean software/build before reconfiguring to prevent stale CMake caches
rm -rf software/build
mkdir -p software/build

cmake -S software -B software/build \
  -DCMAKE_INSTALL_PREFIX=$HOME/opt \
  -DCMAKE_PREFIX_PATH=$HOME/opt \
  -DEN_SIMULATION=ON \
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

# Compile DuckDB with Oasis and link against CoyoteSimulation
export CMAKE_PREFIX_PATH=$HOME/opt:$CMAKE_PREFIX_PATH
# liboasis.so/liblibstf.so carry no RPATH, so `ld` needs $HOME/opt/lib on LD_LIBRARY_PATH to
# resolve their transitive NEEDED entries (libcoyote.so, libjemalloc.so.2) at link time, not
# just at runtime.
export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH
make EXT_FLAGS="-DEN_SIMULATION=ON" -j
```

The output binary is located at:
* `./build/release/duckdb`

---

### Quick Rebuild Helper (After Any Code Edits)
Whenever you modify C++ code in `software/` (`liboasis.so`) or `extension/src/`, **or whenever you
switch branches / update the `parcore`, `celeris`, or `libstf` submodule pins**, run this single
command chain to ensure all libraries and the DuckDB binary are completely up to date:

```bash
scripts/full_rebuild_for_simulation.sh
scripts/setup_simulation.sh
```

---

## 4. Running the Extension in Simulation

### Step 4.1: Generate Sample Test Parquet Files
Use Python and `pyarrow` to create two local, fixed-width Snappy Parquet files. The build table has
1,000 keys; the probe table has 10,000 rows, of which 1,000 match:

```bash
cd /local/home/smalinin/oasis/extension/perf

# Activate an existing environment that provides pyarrow, or install it first:
# python3 -m venv .venv
# .venv/bin/python -m pip install pyarrow
source .venv/bin/activate

python - <<'PY'
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as parquet

output = Path("/tmp/oasis_bf_test")
output.mkdir(parents=True, exist_ok=True)

build_keys = list(range(1_000))
probe_keys = build_keys + list(range(1_000, 10_000))

parquet.write_table(
  pa.table({"key": build_keys}),
  output / "build.parquet",
  compression="SNAPPY",
  use_dictionary=False,
)
parquet.write_table(
  pa.table({"key": probe_keys}),
  output / "probe.parquet",
  compression="SNAPPY",
  use_dictionary=False,
)
PY
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

SELECT s_suppkey FROM read_oasis('extension/tpch_parquet/supplier.parquet');

SELECT *
FROM read_oasis('/local/home/smalinin/oasis/extension/tpch_parquet/lineitem.parquet') l
JOIN read_oasis('/local/home/smalinin/oasis/extension/tpch_parquet/orders.parquet') o
ON l.l_orderkey = o.o_orderkey;
```

---

## 5. Expected Output & Log Verification

The query should return `1000`, because exactly 1,000 probe keys occur in the build table:

```text
 count_star()
-------------
  1000
```

To enable the logging configured by the extension and its dependencies, run this before the query:

```sql
SET oasis_logging_level = 'DEBUG';
```

The Coyote simulation does not provide the RDMA/TCP networking path, so use local Parquet paths as
shown above rather than `rdma://` URLs.

---

## 6. Troubleshooting & Common Pitfalls

| Issue | Cause | Fix |
|---|---|---|
| `Table Function with name read_oasis does not exist!` | DuckDB was built before `oasis` was configured, or `make` failed. | Ensure `software` is installed to `$HOME/opt`, clean with `make clean`, and re-run `make -j`. |
| `libcoyotesim.so: cannot open shared object file` | Runtime linker cannot find `$HOME/opt/lib`. | Run `export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH`. |
| `[FATAL] you must set the COYOTE_SIM_DIR environment variable` | `COYOTE_SIM_DIR` is not set or points to a non-existent directory. | Run `export COYOTE_SIM_DIR=/local/home/smalinin/oasis/hardware/build-sim`. |
| `[FATAL] cThread.cpp: Thread with id 0 crashed` / `xelab: command not found` | Vivado binaries are not in `$PATH`. | Run `module load vivado/2024.2` (or `source /tools/Xilinx/Vivado/2024.2/settings64.sh`). |
| `ERROR: [VRFC 10-2063] Module <BFConfig> not found` | `hardware/build-sim` is out of date and missing newly added HDL modules. | Re-run `./scripts/setup_simulation.sh` with Vivado loaded. |
| `no matching function for call to 'ColumnChunkDecoderConfig::enqueue_column_chunk(...)'` (argument count/type mismatch) | `$HOME/opt` has a stale `parcore`/`libstf`/`Coyote` install from a different branch or submodule commit, and a plain reconfigure reused it via `find_package` instead of rebuilding. | Re-run the **Quick Rebuild Helper** above (it passes `-DCMAKE_DISABLE_FIND_PACKAGE_*` to force a fresh rebuild from the currently checked-out submodules). |
| `ld: ... liboasis.so, not found` / `ld: ... liblibstf.so: undefined reference to 'je_mallocx'` etc. while running `make` in `extension/` | `liboasis.so`/`liblibstf.so` have no `RPATH`, so the linker can't resolve their own dependencies (`libcoyote.so`, `libjemalloc.so.2`) unless `LD_LIBRARY_PATH` includes `$HOME/opt/lib` *at build time*, not just at runtime. | `export LD_LIBRARY_PATH=$HOME/opt/lib:$HOME/opt/lib64:$LD_LIBRARY_PATH` before running `make` in `extension/` (already included in the **Quick Rebuild Helper** and Step 3.5 above). |