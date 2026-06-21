#!/usr/bin/env bash
# Build the Oasis DuckDB extension and query a file over httpfpga://
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="${PREFIX:-$HOME/opt}"
HTTP_SERVER="${HTTP_SERVER:-10.253.74.82}"
HTTP_PORT="${HTTP_PORT:-9000}"
HTTP_FILE="${HTTP_FILE:-dummy.parquet}"
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

if [[ "${RUN_ONLY:-0}" != "1" ]]; then
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
else
	echo "==> Skipping build (RUN_ONLY=1)"
fi

DUCKDB="$ROOT/extension/build/release/duckdb"
if [[ ! -x "$DUCKDB" ]]; then
	echo "DuckDB binary not found at $DUCKDB" >&2
	exit 1
fi

echo "==> Running DuckDB (http_server=$HTTP_SERVER http_port=$HTTP_PORT file=$HTTP_FILE)"
exec "$DUCKDB" <<SQL
SET http_server = '${HTTP_SERVER}';
SET http_port = ${HTTP_PORT};
SELECT * FROM read_parquet('httpfpga://${HTTP_FILE}');
SQL
