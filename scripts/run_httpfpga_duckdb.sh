#!/usr/bin/env bash
# Build the Oasis DuckDB extension and query a file over httpfpga://
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="${PREFIX:-$HOME/opt}"
HTTP_SERVER="${HTTP_SERVER:-10.253.74.74}"
HTTP_PORT="${HTTP_PORT:-9000}"
HTTP_FILE="${HTTP_FILE:-/testbench/dummy.parquet}"
JOBS="${JOBS:-$(nproc)}"

export PREFIX
export CMAKE_PREFIX_PATH="$PREFIX"

# Bypass corporate proxies for the FPGA HTTP server and local addresses.
# Prepend the HTTP server so it wins even when NO_PROXY is already set (e.g. .ethz.ch).
export NO_PROXY="${HTTP_SERVER},127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="${NO_PROXY}"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true

echo "==> PREFIX=$PREFIX"
echo "==> NO_PROXY=$NO_PROXY"

DUCKDB="$ROOT/extension/build/release/duckdb"
BUILD_STAMP="$ROOT/extension/build/.run-build-stamp"

# Only build when a source file changed since the last successful build. The stamp is
# touched after a build, so an unchanged tree makes a re-run instant. RUN_ONLY=1 still
# forces a skip; SKIP_SOFTWARE=1 still skips just the oasis-library step when we do build.
need_build=0
if [[ "${RUN_ONLY:-0}" != "1" ]]; then
	if [[ ! -x "$DUCKDB" || ! -f "$BUILD_STAMP" ]] || [[ -n "$(find \
			"$ROOT/software/oasis" "$ROOT/software/CMakeLists.txt" \
			"$ROOT/extension/src" "$ROOT/extension/CMakeLists.txt" \
			-type f -newer "$BUILD_STAMP" -print -quit 2>/dev/null)" ]]; then
		need_build=1
	fi
fi

if [[ "$need_build" == "1" ]]; then
	if [[ "${SKIP_SOFTWARE:-0}" != "1" ]]; then
		echo "==> Building oasis library"
		cmake -S "$ROOT/software" -B "$ROOT/software/build" \
			-DCMAKE_INSTALL_PREFIX="$PREFIX" \
			-DCMAKE_PREFIX_PATH="$PREFIX"
		cmake --build "$ROOT/software/build" -j"$JOBS"
		cmake --install "$ROOT/software/build"
	fi

	echo "==> Building DuckDB extension"
	cd "$ROOT/extension"
	make -j"$JOBS"
	touch "$BUILD_STAMP"
else
	echo "==> Up to date; skipping build"
fi

if [[ ! -x "$DUCKDB" ]]; then
	echo "DuckDB binary not found at $DUCKDB" >&2
	exit 1
fi

# Runtime library resolution. coyote + libstf are installed under $ROOT/.local (kept in
# sync with each other), while liboasis / libparcore live under $PREFIX. The duckdb binary
# records both dirs in DT_RUNPATH, but RUNPATH only resolves the binary's *direct* deps:
# liblibstf.so is pulled in transitively via liboasis.so, so RUNPATH does not apply to it and
# the loader falls back to a stale copy in $PREFIX/lib whose coyote ABI no longer matches
# (userMap(void*,uint32,int) vs the current uint64 -> "undefined symbol ...userMapEPvji").
# LD_LIBRARY_PATH applies to every dependency, direct and transitive, so it pins the
# consistent .local set first while still exposing $PREFIX/lib for libparcore/liboasis.
export LD_LIBRARY_PATH="$ROOT/.local/lib:$PREFIX/lib:${LD_LIBRARY_PATH:-}"

echo "==> Running DuckDB (http_server=$HTTP_SERVER http_port=$HTTP_PORT file=$HTTP_FILE)"
exec "$DUCKDB" <<SQL
SET http_server = '${HTTP_SERVER}';
SET http_port = ${HTTP_PORT};
SELECT * FROM read_parquet('httpfpga://${HTTP_FILE}');
SQL
