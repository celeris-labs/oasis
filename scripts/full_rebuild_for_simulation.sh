#!/usr/bin/env bash
# Rebuilds the software stack (the Coyote simulation driver, Coyote, libstf, parcore, oasis) for
# simulation, installs it into $PREFIX (default: $HOME/opt), and rebuilds the DuckDB extension
# against it. Run from anywhere. The hardware simulation project is set up separately.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/opt}"

# 1. Purge any previously installed Coyote (and its simulation driver)/libstf/parcore/oasis artifacts. These sit on
#    $PREFIX/include, which is a PUBLIC include dir of the `libstf` CMake target (via
#    JEMALLOC_INCLUDE_DIRS) and therefore leaks into every downstream target's include path.
#    If left behind, stale headers here can silently shadow the fresh ones checked out below,
#    even though the library itself gets rebuilt and reinstalled correctly.
rm -rf "$PREFIX"/include/{coyote,coyotesim,libstf,parcore,oasis} \
       "$PREFIX"/lib/{libcoyote.so,libcoyotesim.so,liblibstf.so,libparcore.so,liboasis.so} \
       "$PREFIX"/lib/cmake/{Coyote,CoyoteSimulation,libstf,parcore,oasis}

# 2. Rebuild and reinstall the Coyote simulation driver (libcoyotesim.so): it runs xsim and moves
#    the software's transfers to and from it. The extension links it with EN_SIMULATION.
COYOTE_SIM_SW="$REPO_ROOT/parcore/libstf/coyote/sim/sw"
rm -rf "$COYOTE_SIM_SW/build"
cmake -S "$COYOTE_SIM_SW" -B "$COYOTE_SIM_SW/build" -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$COYOTE_SIM_SW/build" -j
cmake --install "$COYOTE_SIM_SW/build"

# 3. Rebuild and reinstall the simulation-configured software stack
rm -rf "$REPO_ROOT/software/build"
cmake -S "$REPO_ROOT/software" -B "$REPO_ROOT/software/build" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_DISABLE_FIND_PACKAGE_Coyote=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_libstf=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_parcore=ON \
  -DEN_SIMULATION=ON \
  -DJEMALLOC_LIBRARIES="$PREFIX/lib/libjemalloc.so" \
  -DJEMALLOC_INCLUDE_DIRS="$PREFIX/include"
cmake --build "$REPO_ROOT/software/build" -j
cmake --install "$REPO_ROOT/software/build"

# 4. Rebuild the extension against the freshly installed stack
export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
make -C "$REPO_ROOT/extension" clean
make -C "$REPO_ROOT/extension" EXT_FLAGS="-DEN_SIMULATION=ON" -j

# The exports above end with this script: running the extension needs them in your own shell.
cat <<EOF

Done. To run the extension in simulation, set in your shell:
  export COYOTE_SIM_DIR="$REPO_ROOT/hardware/build-sim"
  export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
