#!/usr/bin/env bash
#
# Build an UNCOMPRESSED copy of one column and put it next to the original, so the Snappy stage can
# be isolated. Decompressor.sv bypasses vhsnunzip entirely for COMPRESSION_RAW, so the same query
# against the two files differs in exactly one thing: whether the decompressor runs.
#
#   in_stalled drops sharply  -> the Snappy core is the ceiling; the 5-core variant earns its area
#   in_stalled stays ~80%     -> the Parquet decode stage is the ceiling; more DECODERS is the answer
#
# TOPOLOGY, which is what makes this fiddly:
#   10.253.74.74 = alveo-u55c-03-data1   MinIO runs HERE
#   10.253.74.78 = alveo-u55c-04-data1   duckdb and the FPGA driver run here
#   10.253.74.80 = the FPGA
# An `mc` alias configured on 04 does NOT necessarily point at 03's MinIO -- it will accept the
# upload into some other instance and report success. So this script never trusts mc's exit code:
# it verifies the object over plain HTTP at the address the FPGA will actually use.
#
# /pub/scratch is NFS and shared cluster-wide, so the file is written there and can be uploaded from
# whichever host has a working alias, with no copying between machines.
#
#   ./scripts/util/make_uncompressed.sh                    # l_quantity from lineitem
#   COL=l_extendedprice ./scripts/util/make_uncompressed.sh
#   SKIP_BUILD=1 ./scripts/util/make_uncompressed.sh        # file already made, just upload+verify
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-30}
TABLE=${TABLE:-lineitem}
COL=${COL:-l_quantity}
MC=${MC:-$HOME/mc}
ALIAS=${MC_ALIAS:-local}   # NOT "minio" -- no such alias exists; see the guard below
BUCKET=${BUCKET:-throughput}
NAME=${TABLE}_${COL}_raw.parquet
STAGE=${STAGE:-$ROOT/.raw}
OUT="$STAGE/$NAME"
URL="http://$SERVER:$PORT/$BUCKET/tpch-$SCALE/$NAME"

mkdir -p "$STAGE"
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

if [ "${SKIP_BUILD:-0}" != 1 ]; then
    echo "1/4  reading $COL from $TABLE (scale $SCALE) over plain HTTP"
    "$DUCKDB" -c "
      SET threads=8;
      COPY (SELECT $COL FROM read_parquet('http://$SERVER:$PORT/$BUCKET/tpch-$SCALE/$TABLE.parquet'))
      TO '$OUT' (FORMAT parquet, COMPRESSION uncompressed);" || exit 1

    echo "2/4  verifying it really is uncompressed"
    codec=$("$DUCKDB" -noheader -list -c "SELECT DISTINCT compression FROM parquet_metadata('$OUT');")
    echo "     codec = $codec"
    [ "$codec" = UNCOMPRESSED ] || { echo "     NOT uncompressed -- the experiment would be meaningless"; exit 1; }
fi
ls -la "$OUT" || exit 1

echo "3/4  uploading to the MinIO the FPGA actually reads ($SERVER)"
# mc does NOT error on an unknown alias -- it treats "foo/bucket/key" as a LOCAL PATH and happily
# creates ./foo/bucket/ and copies into it, at NFS speed, reporting success. That cost us two
# 130 MiB "uploads" into ./minio/throughput/tpch-30/ before anyone noticed. So check the alias is
# real before using it.
if ! "$MC" alias list "$ALIAS" >/dev/null 2>&1; then
    echo "     no mc alias named '$ALIAS'. Available:"
    "$MC" alias list 2>/dev/null | grep -E '^[a-zA-Z]' | sed 's/^/       /'
    echo "     Re-run with MC_ALIAS=<one of those>. Without this check mc would have silently"
    echo "     written a directory called '$ALIAS' into the current folder."
    exit 1
fi
"$MC" cp "$OUT" "$ALIAS/$BUCKET/tpch-$SCALE/$NAME" 2>&1 | tail -1 || true

echo "4/4  verifying over HTTP -- mc's exit code proves nothing about WHICH MinIO it wrote to"
code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -I "$URL")
if [ "$code" = 200 ]; then
    len=$(curl -sI --noproxy '*' "$URL" | tr -d '\r' | awk '/[Cc]ontent-[Ll]ength/{print $2}')
    echo "     OK  $URL  ($len bytes)"
    echo
    echo "now compare, same query, same bytes on the wire, only the decompressor differs:"
    echo
    echo "  OASIS_HTTP_DEBUG=1 OASIS_HTTP_CHUNK_BYTES=786432 $DUCKDB -c \\"
    echo "    \"SET http_server='$SERVER'; SET http_port=$PORT; SET threads=1;"
    echo "     SELECT sum($COL) FROM read_oasis('httpfpga:///$BUCKET/tpch-$SCALE/$NAME');\" \\"
    echo "    2>&1 | grep 'decoder in:' | tail -20"
else
    echo "     HTTP $code -- the object is NOT on the MinIO at $SERVER."
    echo
    echo "     Your mc alias '$ALIAS' points somewhere else. MinIO runs on alveo-u55c-03;"
    echo "     the staged file is on shared NFS, so upload it from there instead:"
    echo
    echo "       ssh alveo-u55c-03.inf.ethz.ch \\"
    echo "         '~/mc cp $OUT $ALIAS/$BUCKET/tpch-$SCALE/$NAME'"
    echo
    echo "     then re-check with:"
    echo "       curl -sI --noproxy '*' $URL | head -2"
    exit 2
fi
