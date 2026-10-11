#!/usr/bin/env bash
# Rebuilds the software stack (Coyote, libstf, parcore, oasis) for the real FPGA, installs it into
# $PREFIX (default: $HOME/opt), rebuilds the DuckDB extension against it, and builds the Coyote
# kernel driver from the same tree the bitstream is synthesized from. Run from anywhere.
#
# It does not program the FPGA. Do that afterwards with (from parcore/libstf/coyote):
#   ./util/program_hacc_local.sh <bitstream> $PWD/driver/build/coyote_driver.ko
#
# Only the hardware artifacts in $PREFIX are replaced, so an installed simulation stack
# (libcoyotesim.so, see full_rebuild_for_simulation.sh) is left alone.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/opt}"
COYOTE_DIR="$REPO_ROOT/parcore/libstf/coyote"

if [ ! -f "$PREFIX/lib/libjemalloc.so" ]; then
    echo "error: no libjemalloc.so in $PREFIX/lib: set PREFIX or run parcore/libstf/scripts/install_jemalloc.sh" >&2
    exit 1
fi

# 1. Purge any previously installed hardware Coyote/libstf/parcore/oasis artifacts.
rm -rf "$PREFIX"/include/{coyote,libstf,parcore,oasis} \
       "$PREFIX"/lib/{libcoyote.so,liblibstf.so,libparcore.so,liboasis.so} \
       "$PREFIX"/lib/cmake/{Coyote,libstf,parcore,oasis}

# 2. Rebuild and reinstall the software stack. The find_package lookups are disabled so that the
#    libraries are built from this checkout instead of picking up whatever is installed.
rm -rf "$REPO_ROOT/software/build"
cmake -S "$REPO_ROOT/software" -B "$REPO_ROOT/software/build" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_DISABLE_FIND_PACKAGE_Coyote=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_libstf=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_parcore=ON \
  -DEN_SIMULATION=OFF \
  -DJEMALLOC_LIBRARIES="$PREFIX/lib/libjemalloc.so" \
  -DJEMALLOC_INCLUDE_DIRS="$PREFIX/include"
cmake --build "$REPO_ROOT/software/build" -j
cmake --install "$REPO_ROOT/software/build"

# 3. Rebuild the extension against the freshly installed stack
export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
make -C "$REPO_ROOT/extension" clean
make -C "$REPO_ROOT/extension" EXT_FLAGS="-DEN_SIMULATION=OFF" -j

# 4. Build the Coyote kernel driver
make -C "$COYOTE_DIR/driver" clean
make -C "$COYOTE_DIR/driver" -j

# The exports above end with this script: running the extension needs them in your own shell.
cat <<EOF

Done. To run the extension on the FPGA, set in your shell:
  export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

Extension: $REPO_ROOT/extension/build/release/extension/oasis/oasis.duckdb_extension
Driver:    $COYOTE_DIR/driver/build/coyote_driver.ko

To flash (needs sudo and a tty):
  cd $COYOTE_DIR
  ./util/program_hacc_local.sh <bitstream> \$PWD/driver/build/coyote_driver.ko
  sudo /opt/hdev/cli/hdev set hugepages --num-2m 0 --num-1g 8
EOF
