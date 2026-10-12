#!/usr/bin/env bash
# Rebuilds only the DuckDB extension (extension/) for the real FPGA, against the software stack that
# is already installed in $PREFIX (default: $HOME/opt). Run from anywhere.
#
# Unlike full_rebuild_for_hardware.sh it does not touch Coyote, libstf, parcore, oasis, the Coyote
# kernel driver or $PREFIX: it only reads the installed stack. After changing anything under
# software/, parcore/ or celeris/, reinstall the stack first with full_rebuild_for_hardware.sh.
#
# By default the build is incremental. Pass --clean for a clean rebuild (this recompiles DuckDB too,
# which takes a long time).
#
# Usage: rebuild_extension_for_hardware.sh [--clean] [-j N]
#   PREFIX=<dir>  where the stack is installed (default: $HOME/opt)
#   JOBS=<n>      parallel build jobs, same as -j N (default: number of CPUs)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/opt}"
JOBS="${JOBS:-$(nproc)}"

CLEAN=0
while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --clean) CLEAN=1 ;;
    -j?*) JOBS="${arg#-j}" ;;
    -j)
        JOBS="${1:?error: -j needs a number}"
        shift
        ;;
    -h | --help)
        sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "error: unknown argument '$arg' (see --help)" >&2
        exit 2
        ;;
    esac
done

# The extension links against the installed stack: refuse early, with the fix, if it is not there.
missing=()
for lib in libcoyote.so liblibstf.so libparcore.so liboasis.so; do
    [ -f "$PREFIX/lib/$lib" ] || missing+=("$PREFIX/lib/$lib")
done
[ -f "$PREFIX/lib/cmake/oasis/oasisConfig.cmake" ] || missing+=("$PREFIX/lib/cmake/oasis/oasisConfig.cmake")
if [ "${#missing[@]}" -ne 0 ]; then
    echo "error: the hardware software stack is not installed in $PREFIX:" >&2
    printf '  missing %s\n' "${missing[@]}" >&2
    echo "Run scripts/full_rebuild_for_hardware.sh first (or set PREFIX)." >&2
    exit 1
fi

export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ "$CLEAN" -eq 1 ]; then
    make -C "$REPO_ROOT/extension" clean
fi
# The empty flags clear a -g left in the CMake cache by an earlier build.
# The jobs go through CMAKE_BUILD_PARALLEL_LEVEL: the extension Makefile runs `cmake --build` from a
# non-recursive recipe, so a -j on this make would reach the compile as -j1 (or unlimited for a bare -j).
CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" make -C "$REPO_ROOT/extension" \
  EXT_FLAGS="-DEN_SIMULATION=OFF -DCMAKE_C_FLAGS= -DCMAKE_CXX_FLAGS="

# The exports above end with this script: running the extension needs them in your own shell.
cat <<EOF

Done. To run the extension on the FPGA, set in your shell:
  export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

Extension: $REPO_ROOT/extension/build/release/extension/oasis/oasis.duckdb_extension
Shell:     $REPO_ROOT/extension/build/release/duckdb
EOF
