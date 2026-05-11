# Oasis -- Data Processing SmartNIC

Oasis is a data processing SmartNIC for cloud-native data lakes. It offloads Parquet decoding into
the network data path. The main components are a hardware design that embeds 
[ParCore](https://github.com/celeris-labs/parcore) into an RDMA-enabled 
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA and a software abstraction for easy 
integration into query engines.

The hardware component requires the Coyote, [libSTF](https://github.com/fpgasystems/libstf), and 
ParCore submodules to be loaded by either cloning this repo with submodules directly:

```bash
git clone --recurse-submodules git@github.com:celeris-labs/oasis.git
```

Or initializing the submodules as a step after cloning:

```bash
git submodule update --init --remote
```

## Hardware
The functionality of the hardware component can be verified with unit tests that are built on top of 
the Coyote unit test framework. We also describe how to synthesize the hardware.

### Unit tests
To run the unit tests, the Vivado simulation project needs to be set up:

```bash
./setup_simulation.sh
```

After this is finished, VSCode shows the unit tests as a test flask on the left side. The simulation
project needs to be regenerated whenever new files are added (also for the dependencies).

### Synthesis
For synthesis, execute the following commands:

```bash
mkdir build-hw
cmake -S hardware -B build-hw
tmux new-session -d -s bitgen 'cmake --build build-hw --target project --target bitgen &> build-hw/bitgen.log'
```

The command `nohup` runs the synthesis in the background in a way that the user can disconnect from 
the server without the synthesis stopping. You can check the progress in `build-hw/bitgen.log`. It 
is expected that the synthesis takes multiple hours to finish sometimes not printing anything new to 
the log for a while.

## Software
The software consists of the Oasis library and a DuckDB extension.

### Oasis library
The software library can be built as follows:

```bash
mkdir build
cmake -S software -B build
cmake --build build -j
```

If you want to install it to e.g., `~/opt`, you need to add `-DCMAKE_INSTALL_PREFIX=$HOME/opt` to 
the first `cmake` command and execute `cmake --install build` after the build.

### DuckDB extension
The DuckDB Oasis extension can be built as follows:

```bash
cd extension
make -j
```

More detail can be found in the `extension/README.md`.

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.