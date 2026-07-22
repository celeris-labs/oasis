# Oasis - Data Processing SmartNIC

Oasis is a data processing SmartNIC for data lakes. It offloads Parquet decoding into
the network data path. The main components are: A hardware design that embeds 
[ParCore](https://github.com/celeris-labs/parcore) (hardware Parquet decoder) into an RDMA-enabled 
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA, a software abstraction featuring a scheduler 
for easy integration into query engines, and a DuckDB extension with a table function (scan 
operator).

The hardware component requires the ParCore submodule and its dependencies to be loaded by either 
cloning this repo with submodules directly:

```bash
git clone --recurse-submodules git@github.com:celeris-labs/oasis.git
```

Or initializing the submodule as a step after cloning:

```bash
git submodule update --init extension/duckdb
git submodule update --init extension/extension-ci-tools
git submodule update --init --recursive parcore
git submodule update --init celeris
```

## Hardware
The functionality of the hardware component can be verified with unit tests that are built on top of 
the Coyote unit test framework. We also describe how to synthesize the hardware.

### Unit tests
To run the unit tests, the Vivado simulation project needs to be set up:

```bash
./scripts/setup_simulation.sh
```

After this is finished, VSCode shows the unit tests as a test flask on the left side. The simulation
project needs to be regenerated whenever new files are added (also for the dependencies).

### Synthesis
For synthesis, execute the following command on one of the build servers (`hacc-build-**`):

```bash
./scripts/synthesize.sh [--no-rdma] [--decoders <number-of-decoders>] [--v80]
```

The script spins off the synthesis in the background in a new tmux session so the user can 
disconnect from the server without the synthesis stopping. You can check the progress in 
`hardware/build-**/bitgen.log`. It is expected that the synthesis takes multiple hours to finish 
sometimes not printing anything new to the log for a while. The finished bitstream will be available 
in `hardware/build-**/bitstreams/cyt_top.bit`.

### Programming the FPGA
To program an FPGA, book one of the `alveo-u55c-**` or `alveo-v80-01` servers respectively and clone 
the Coyote repo. Inside the Coyote repo, go to the driver folder and execute `make -j`. Then, 
execute this command:

```bash
./util/program_hacc_local.sh <bitstream> driver/build/coyote_driver.ko
```

The easiest way to share bitstreams across servers is to copy it to `/scratch/<nethz-user>/...` 
which is available as a network mounted file system across servers.

## Software
The software consists of the Oasis software library and a DuckDB extension.

### Oasis library
The Oasis software library has dependencies on the Coyote, libSTF, and ParCore software libraries 
which need to be installed first. In case they are not installed already, libSTF also has a 
dependency on jemalloc that can be installed with `./parcore/libstf/scripts/install_jemalloc.sh`. 
The Oasis software library can be built as follows:

```bash
mkdir software/build
cmake -S software -B software/build
cmake --build software/build -j
```

On the HACC cluster, your home directory is a network mounted file system available across all 
server. So, if you want to install the library to e.g., `$HOME/opt`, you need to append 
`-DCMAKE_INSTALL_PREFIX=$HOME/opt` to the first `cmake` command and execute 
`cmake --install software/build` after the build.

### DuckDB extension
The DuckDB Oasis extension can be built as follows and requires the Oasis software library to be 
installed first:

```bash
cd extension
make -j
```

More detail can be found in `extension/README.md`.

## Misc
To generate a LaTeX table of the resource generation run:

```bash
./scripts/utilization_latex.py hardware/build-**
```

To run Oasis on an AMD V80 FPGA (hacc-box-04 & 05):

1. Program FPGA
2. Warm reboot
3. Insert driver

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.