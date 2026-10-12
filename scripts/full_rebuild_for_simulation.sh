#!/usr/bin/env bash
# Rebuilds the software stack (the Coyote simulation driver, Coyote, libstf, parcore, oasis) for
# simulation, installs it into $PREFIX (default: $HOME/opt), and rebuilds the DuckDB extension
# against it. Run from anywhere. The hardware simulation project is set up separately.
#
# Usage: full_rebuild_for_simulation.sh [-j N]
#   PREFIX=<dir>  install prefix (default: $HOME/opt)
#   JOBS=<n>      parallel build jobs, same as -j N (default: number of CPUs)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/opt}"
JOBS="${JOBS:-$(nproc)}"

while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    -j?*) JOBS="${arg#-j}" ;;
    -j)
        JOBS="${1:?error: -j needs a number}"
        shift
        ;;
    *)
        echo "error: unknown argument '$arg' (usage: $0 [-j N])" >&2
        exit 2
        ;;
    esac
done

# Everything stays a Release (-O3) build; -g1 adds line-table debug info (function names and source
# lines, enough for perf) to the software stack.
# The extension adds -g1 to its own sources (extension/CMakeLists.txt); DuckDB is built without it.
DEBUG_FLAGS="-g1"

# 1. Purge any previously installed Coyote (and its simulation driver)/libstf/parcore/oasis artifacts.
rm -rf "$PREFIX"/include/{coyote,coyotesim,libstf,parcore,oasis} \
       "$PREFIX"/lib/{libcoyote.so,libcoyotesim.so,liblibstf.so,libparcore.so,liboasis.so} \
       "$PREFIX"/lib/cmake/{Coyote,CoyoteSimulation,libstf,parcore,oasis}

# 2. Rebuild and reinstall the Coyote simulation driver (libcoyotesim.so).
COYOTE_SIM_SW="$REPO_ROOT/parcore/libstf/coyote/sim/sw"
rm -rf "$COYOTE_SIM_SW/build"
cmake -S "$COYOTE_SIM_SW" -B "$COYOTE_SIM_SW/build" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_CXX_FLAGS="$DEBUG_FLAGS"
cmake --build "$COYOTE_SIM_SW/build" -j"$JOBS"
cmake --install "$COYOTE_SIM_SW/build"

# 3. Rebuild and reinstall the simulation-configured software stack
rm -rf "$REPO_ROOT/software/build"
cmake -S "$REPO_ROOT/software" -B "$REPO_ROOT/software/build" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_DISABLE_FIND_PACKAGE_Coyote=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_libstf=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_parcore=ON \
  -DEN_SIMULATION=ON \
  -DCMAKE_CXX_FLAGS="$DEBUG_FLAGS" \
  -DJEMALLOC_LIBRARIES="$PREFIX/lib/libjemalloc.so" \
  -DJEMALLOC_INCLUDE_DIRS="$PREFIX/include"
cmake --build "$REPO_ROOT/software/build" -j"$JOBS"
cmake --install "$REPO_ROOT/software/build"

# 4. Rebuild the extension against the freshly installed stack
export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
make -C "$REPO_ROOT/extension" clean
# The empty flags clear a -g left in the CMake cache by an earlier build.
# The jobs go through CMAKE_BUILD_PARALLEL_LEVEL: the extension Makefile runs `cmake --build` from a
# non-recursive recipe, so a -j on this make would reach the compile as -j1 (or unlimited for a bare -j).
CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" make -C "$REPO_ROOT/extension" \
  EXT_FLAGS="-DEN_SIMULATION=ON -DCMAKE_C_FLAGS= -DCMAKE_CXX_FLAGS="

# The exports above end with this script: running the extension needs them in your own shell.
cat <<EOF

Done. To run the extension in simulation, set in your shell:
  module load vivado/2024.2
  export COYOTE_SIM_DIR="$REPO_ROOT/hardware/build-sim"
  export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
