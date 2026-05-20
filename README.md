# Oasis -- Data Processing SmartNIC

Oasis is a data processing SmartNIC for cloud-native data lakes. It offloads Parquet decoding into
the network data path. The main components are a hardware design that embeds 
[ParCore](https://github.com/celeris-labs/parcore) into an RDMA-enabled 
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA and a software abstraction for easy 
integration into query engines.

The hardware component requires the ParCore submodule and its dependencies to be loaded by either 
cloning this repo with submodules directly:

```bash
git clone --recurse-submodules git@github.com:celeris-labs/oasis.git
```

Or initializing the submodule as a step after cloning:

```bash
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
For synthesis, execute the following command:

```bash
./scripts/synthesize.sh
```

The script spins off the synthesis in the background in a way that the user can disconnect from 
the server without the synthesis stopping. You can check the progress in `hardware/build-**/bitgen.log`. 
It is expected that the synthesis takes multiple hours to finish sometimes not printing anything new 
to the log for a while.

## Software
The Oasis software library has dependencies on the Coyote, libSTF, and ParCore software libraries to 
be installed or includes them from the submodules. In case they are not installed already, libSTF 
also has a dependency on jemalloc that can be installed with `./parcore/libstf/scripts/install_jemalloc.sh` 
and ParCore currently has a dependency on Arrow 21.0.0 which can be installed with `./parcore/scripts/install_arrow.sh`. 
The Oasis software library can be built as follows:

```bash
mkdir software/build
cmake -S software -B software/build
cmake --build software/build -j
```

If you want to install it to e.g., `~/opt`, you need to add `-DCMAKE_INSTALL_PREFIX=$HOME/opt` to 
the first `cmake` command and execute `cmake --install software/build` after the build.

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.