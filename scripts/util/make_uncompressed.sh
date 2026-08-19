#!/usr/bin/env bash
#
# Build an UNCOMPRESSED copy of one column and put it next to the original, so the Snappy stage can
# be isolated.
#
# Decompressor.sv bypasses vhsnunzip entirely for COMPRESSION_RAW, so the same query against the two
# files differs in exactly one thing: whether the decompressor runs. Compare `decoder in: stalled`
# between them and the answer is unambiguous.
#
#   in_stalled drops sharply  -> the Snappy core is the ceiling; the 5-core variant is worth the area
#   in_stalled stays ~80%     -> the Parquet decode stage is the ceiling; more DECODERS is the answer
#
#   ./scripts/util/make_uncompressed.sh                    # l_quantity from lineitem
#   COL=l_extendedprice ./scripts/util/make_uncompressed.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-30}
TABLE=${TABLE:-lineitem}
COL=${COL:-l_quantity}
MC=${MC:-$HOME/mc}
ALIAS=${MC_ALIAS:-minio}
OUT=/tmp/${TABLE}_${COL}_raw.parquet

# The proxy is why the obvious one-liner fails: DuckDB's httpfs honours http_proxy, and a bare
# 10.253.x address routed through it just times out on the HEAD. tpch_demo.sh unsets these before
# every run, which is why the demo works and a hand-typed COPY does not.
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

echo "1/3  reading $COL from $TABLE (scale $SCALE) over plain HTTP"
"$DUCKDB" -c "
  SET threads=8;
  COPY (SELECT $COL FROM read_parquet('http://$SERVER:$PORT/throughput/tpch-$SCALE/$TABLE.parquet'))
  TO '$OUT' (FORMAT parquet, COMPRESSION uncompressed);"
ls -la "$OUT"

echo "2/3  verifying it really is uncompressed"
"$DUCKDB" -noheader -list -c "
  SELECT DISTINCT compression FROM parquet_metadata('$OUT');"

echo "3/3  uploading next to the original"
[ -x "$MC" ] || { echo "mc not found at $MC -- set MC=/path/to/mc"; exit 1; }
"$MC" cp "$OUT" "$ALIAS/throughput/tpch-$SCALE/"

echo
echo "now compare the two, same query, same everything except the decompressor:"
echo
echo "  OASIS_HTTP_DEBUG=1 OASIS_HTTP_CHUNK_BYTES=786432 $DUCKDB -c \\"
echo "    \"SET http_server='$SERVER'; SET http_port=$PORT; SET threads=1;"
echo "     SELECT sum($COL) FROM read_oasis('httpfpga:///throughput/tpch-$SCALE/$(basename "$OUT")');\" \\"
echo "    2>&1 | grep 'decoder in:' | tail -20"
