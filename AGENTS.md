# Rules
- Do not run commands like `make`, `cmake` or any kind of build scripts (as they are very slow)
- Do not run hardware simulations
- Do not run hardware synthesis
- Do not read or grep raw `.vcd` files. Use the Python parser (with .venv): `vcdcvt --input <file> --signal <signal_name>`.
   - Firstly parse the input to an SQLite DB once
   - Every time you need something query the DB
- You should work in `/local/home/smalinin/`
- Do so carefully, as files very easily grow very large. First check the (potential) file size before doing anything.

# Architecture
## Oasis
Oasis is the main repository of interest. We are currently developing logic there. This is mainly a DuckDB extension. 

**Start all bug investigations here.** Only investigate submodules if Oasis code is verified. If checking submodules, prioritize checking for git version mismatches. Check if some bug fixes already exist in the full git history.

### Debugging
- The simulation log is located at `hardware/build-sim/sim/sim_dump.vcd`.
- The synthesis log/errors are located at `extension/vivado.log`
- The bloom filter software integration mostly lives in `extension/src/oasis_hardware_bloom.cpp`
- The bloom filter hardware definitions live in `celeris/hardware/src/hdl/bloomfilter/`
- The top module for the extension is in `hardware/src/vfpga_top.svh`

## Celeris
Celeris is the main repository that contains the logic for all DB operators. This is closely related to Oasis, so expect bugs there as well (especially in the operators, rather than in the more foundational infrastrucure stuff).

## Coyote
Coyote is the framework that is used for communication with the FPGA. You can read more about how it works in `coyote/README.md`. 
