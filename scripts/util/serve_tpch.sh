#!/usr/bin/env bash
#
# Stand up the TPC-H dataset on THIS node's MinIO, so the FPGA has something to fetch.
#
# WHY THIS EXISTS. MinIO's data directory is `/local/home/jkreissl/minio-data` -- node-LOCAL. The
# binaries (`~/minio`, `~/mc`, `~/duckdb`) live in NFS home and follow you anywhere; the data does
# not. So the day the HACC reservation moves to a different u55c node, the objects are simply gone
# and every script quietly fails to connect to a server that is still pingable.
#
# The recovery does NOT need dbgen: `/scratch/jkreissl/tpch-sf30.db` is on shared NFS scratch and
# holds all eight tables at full scale factor 30 (lineitem 179,998,372 rows, verified). This script
# exports it to Parquet and serves it.
#
# Run it ON the node that will serve the data. It figures out its own storage-network address from
# `<hostname>-data1`, so there is nothing to edit when the node changes:
#
#     ./scripts/util/serve_tpch.sh
#     SCALE=3 ./scripts/util/serve_tpch.sh          # smaller, for a shakedown
#     SKIP_EXPORT=1 ./scripts/util/serve_tpch.sh    # parquet already staged, just serve it
#
# Then point the benchmarks at it:  export OASIS_SERVER=<the IP this prints>
#
# THREE CONSTRAINTS THE DECODER IMPOSES, all enforced below, none of them obvious:
#
#   - SNAPPY only. The hardware rejects GZIP/ZSTD outright ("codec N not supported by ParCore").
#   - DuckDB-written only. fastparquet pads every data page with 8 bytes past the last declared
#     value and the decoder waits forever for a page header that never completes.
#   - ANONYMOUS GET *and* ListObjectsV2 must work. The FPGA's GET carries no Authorization header,
#     so a bucket left private is indistinguishable from a broken bitstream from the host side.
#
# ROW_GROUP_SIZE is pinned to DuckDB's default 122,880 rather than left implicit, so numbers stay
# comparable with every measurement taken before the node moved. Row-group size changes request
# count and therefore throughput; letting a future DuckDB pick a different default would silently
# invalidate the baseline.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SCALE=${SCALE:-30}
DB=${DB:-/scratch/jkreissl/tpch-sf${SCALE}.db}
# The EXPORT uses python3's duckdb, NOT ~/duckdb. They are different versions and it matters more
# than it looks: ~/duckdb is 1.1.3 and writes every numeric column PLAIN, while the python module is
# 1.4.4 -- the version that wrote the original objects -- and dictionary-encodes l_quantity,
# l_discount, l_tax and l_shipdate, exactly the columns q01 reads. Measured on 2,000,000 lineitem
# rows: 1.1.3 gives 47.24 bytes/row, 1.4.4 gives 37.49, the originals were 34.51. On a path that is
# network-bound at 0.46 GB/s, a 26% larger object is a 26% slower query for no reason at all.
# Both write only PLAIN and PLAIN_DICTIONARY, which are the encodings the decoder implements.
# The module lives in NFS home (~/.local/lib/python3.10/site-packages), so it follows between nodes.
PY_BIN=${PY_BIN:-python3}
MINIO=${MINIO:-$HOME/minio}
MC=${MC:-$HOME/mc}
MINIO_DATA=${MINIO_DATA:-/local/home/jkreissl/minio-data}
STAGE=${STAGE:-/local/home/jkreissl/stage/tpch-${SCALE}}
BUCKET=${BUCKET:-throughput}
PREFIX=${PREFIX:-tpch-${SCALE}}
PORT=${PORT:-9000}
ALIAS=${ALIAS:-serve}
USER_=${MINIO_ROOT_USER:-minioadmin}
PASS_=${MINIO_ROOT_PASSWORD:-minioadmin}
TABLES="lineitem orders customer part partsupp supplier nation region"

# This node's address ON THE STORAGE NETWORK -- not its management address, which the FPGA cannot
# reach. Deriving it beats hardcoding: the whole reason this script exists is that the node changes.
HOST_SHORT=$(hostname -s)
IP=$(getent hosts "${HOST_SHORT}-data1" 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$IP" ]; then
    echo "could not resolve ${HOST_SHORT}-data1 -- is this a HACC compute node?" >&2; exit 2
fi

export NO_PROXY="${IP},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

say() { printf '\n== %s\n' "$*"; }

for b in "$MINIO" "$MC"; do
    [ -x "$b" ] || { echo "missing or not executable: $b" >&2; exit 2; }
done
DUCKDB_VER=$("$PY_BIN" -c 'import duckdb;print(duckdb.__version__)' 2>/dev/null)
case "$DUCKDB_VER" in
    1.4.*|1.5.*|1.6.*) echo "exporting with python duckdb $DUCKDB_VER" ;;
    '') echo "python duckdb not importable with $PY_BIN -- cannot export" >&2; exit 2 ;;
    *)  echo "python duckdb is $DUCKDB_VER; expected 1.4.x." >&2
        echo "Older writers emit PLAIN where 1.4.4 emits PLAIN_DICTIONARY, which inflates every" >&2
        echo "object and slows every query. Set PY_BIN to an interpreter with duckdb 1.4.x," >&2
        echo "or ALLOW_ANY_DUCKDB=1 to proceed anyway." >&2
        [ "${ALLOW_ANY_DUCKDB:-0}" = 1 ] || exit 2 ;;
esac

# ---------------------------------------------------------------------------------------------
say "1/4  MinIO on ${IP}:${PORT}"
if pgrep -u "$(id -un)" -x minio >/dev/null 2>&1; then
    echo "   already running (pid $(pgrep -u "$(id -un)" -x minio | tr '\n' ' '))"
else
    mkdir -p "$MINIO_DATA"
    MINIO_ROOT_USER="$USER_" MINIO_ROOT_PASSWORD="$PASS_" \
        nohup "$MINIO" server "$MINIO_DATA" --address ":${PORT}" --console-address ":9001" \
        >"$HOME/minio.log" 2>&1 &
    echo "   started, log: $HOME/minio.log"
    for _ in $(seq 30); do
        curl -s --noproxy '*' -o /dev/null "http://${IP}:${PORT}/minio/health/live" && break
        sleep 1
    done
fi
curl -sf --noproxy '*' -o /dev/null "http://${IP}:${PORT}/minio/health/live" \
    || { echo "   MinIO is not answering on ${IP}:${PORT}; see $HOME/minio.log" >&2; exit 2; }
echo "   healthy"

"$MC" alias set "$ALIAS" "http://${IP}:${PORT}" "$USER_" "$PASS_" >/dev/null 2>&1 \
    || { echo "   mc alias set failed" >&2; exit 2; }
"$MC" mb --ignore-existing "${ALIAS}/${BUCKET}" >/dev/null 2>&1

# ---------------------------------------------------------------------------------------------
# Export and upload ONE TABLE AT A TIME, dropping each staged file as soon as it is safely in
# MinIO. Staging all eight first would need roughly twice the dataset on /local -- about 26 GB at
# sf30 -- for no reason. This way the extra space needed on top of MinIO's own store is one table,
# and the biggest is lineitem at ~8 GB. Set KEEP_STAGE=1 if you want the parquet files afterwards.
say "2/4  export from $DB and upload to ${BUCKET}/${PREFIX}/"
if [ "${SKIP_EXPORT:-0}" = 1 ]; then
    echo "   SKIP_EXPORT=1, uploading whatever is already in $STAGE"
elif [ ! -r "$DB" ]; then
    # Only scale 30 was ever materialised on shared scratch, but every script here defaults to
    # SCALE=1 -- tpch_demo.sh especially. Rather than fail with "no such database", generate it:
    # dbgen is deterministic, so a generated sf1 is the same data anyone else's sf1 would be.
    # Written to $DB so the next run reuses it instead of regenerating.
    echo "   $DB does not exist -- generating scale $SCALE with dbgen (this is a one-off)"
    if ! "$PY_BIN" - "$DB" "$SCALE" <<'PYGEN'
import sys, duckdb
db, sf = sys.argv[1], float(sys.argv[2])
c = duckdb.connect(db)
c.execute("SET enable_progress_bar=false")
c.execute("INSTALL tpch"); c.execute("LOAD tpch")
c.execute(f"CALL dbgen(sf={sf})")
n = c.execute("SELECT count(*) FROM lineitem").fetchone()[0]
print(f"   generated, lineitem has {n:,} rows")
PYGEN
    then
        echo "   dbgen failed -- is the tpch extension available to $PY_BIN?" >&2; exit 2
    fi
fi
mkdir -p "$STAGE" || exit 2
free_gb=$(df -BG --output=avail /local | tail -1 | tr -dc '0-9')
echo "   /local has ${free_gb}G free; the dataset needs roughly $(( $(stat -c%s "$DB" 2>/dev/null || echo 0) / 1073741824 * 2 + 6 ))G once served"
for t in $TABLES; do
    out="$STAGE/${t}.parquet"
    printf '   %-10s ' "$t"
    if [ "${SKIP_EXPORT:-0}" != 1 ] && [ ! -s "$out" ]; then
        if ! "$PY_BIN" - "$DB" "$t" "$out" >/dev/null 2>"$STAGE/.$t.err" <<'PYEXPORT'
import sys, duckdb
db, table, out = sys.argv[1], sys.argv[2], sys.argv[3]
c = duckdb.connect(db, read_only=True)
c.execute("SET enable_progress_bar=false")
# ROW_GROUP_SIZE pinned rather than left to the writer's default: row-group size sets how many
# ranged GETs a scan costs, so letting a future DuckDB pick a different one would silently move
# every throughput number while looking like a code change.
c.execute(f"COPY (SELECT * FROM {table}) TO '{out}' "
          "(FORMAT PARQUET, COMPRESSION SNAPPY, ROW_GROUP_SIZE 122880)")
# The decoder implements PLAIN and PLAIN_DICTIONARY. Anything else -- DELTA_BINARY_PACKED above
# all, which newer writers reach for on sorted integers -- does not fail loudly at run time; it
# decodes to wrong numbers or hangs waiting for a page that never completes. Catch it here.
OK = {"PLAIN", "PLAIN_DICTIONARY", "RLE_DICTIONARY", "RLE", "BIT_PACKED", ""}
bad = set()
for (enc,) in c.execute(
        f"SELECT DISTINCT encodings FROM parquet_metadata('{out}')").fetchall():
    for e in (enc or "").replace(",", " ").split():
        if e.strip() not in OK:
            bad.add(e.strip())
if bad:
    sys.exit(f"{table}: unsupported parquet encoding(s) {sorted(bad)} -- the decoder cannot read this")
PYEXPORT
        then
            echo "EXPORT FAILED"; sed 's/^/      /' "$STAGE/.$t.err" >&2; exit 2
        fi
    fi
    [ -s "$out" ] || { echo "MISSING $out"; exit 2; }
    printf '%6s  ' "$(stat -c%s "$out" | numfmt --to=iec)"
    if "$MC" cp --quiet "$out" "${ALIAS}/${BUCKET}/${PREFIX}/${t}.parquet" >/dev/null 2>&1; then
        echo "uploaded"
        [ "${KEEP_STAGE:-0}" = 1 ] || rm -f "$out"
    else
        echo "UPLOAD FAILED"; exit 2
    fi
done

# ---------------------------------------------------------------------------------------------
# The FPGA sends no Authorization header, so this is not optional and not cosmetic.
say "3/4  anonymous access"
"$MC" anonymous set download "${ALIAS}/${BUCKET}" >/dev/null 2>&1 \
    || "$MC" policy set download "${ALIAS}/${BUCKET}" >/dev/null 2>&1 \
    || { echo "   could not make ${BUCKET} anonymously readable" >&2; exit 2; }
echo "   ${BUCKET} is anonymously readable"

# ---------------------------------------------------------------------------------------------
# Verify over plain HTTP at the address the FPGA will really use. mc talks to whatever its alias
# points at and reports success either way -- see the topology note in make_uncompressed.sh, where
# trusting mc's exit code cost a day.
say "4/4  verify as the FPGA sees it"
fail=0
url="http://${IP}:${PORT}/${BUCKET}/${PREFIX}/lineitem.parquet"
code=$(curl -s --noproxy '*' -r 0-1023 -o /dev/null -w '%{http_code}' "$url")
[ "$code" = 206 ] && echo "   ranged GET   206 ok" || { echo "   ranged GET   got $code, want 206"; fail=1; }
code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' \
        "http://${IP}:${PORT}/${BUCKET}/?list-type=2&prefix=${PREFIX}/&max-keys=3")
[ "$code" = 200 ] && echo "   anon list    200 ok" || { echo "   anon list    got $code, want 200"; fail=1; }
for t in $TABLES; do
    len=$(curl -s --noproxy '*' -I "http://${IP}:${PORT}/${BUCKET}/${PREFIX}/${t}.parquet" \
          | awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}')
    if [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null; then
        printf '   %-10s %s\n' "$t" "$(numfmt --to=iec "$len")"
    else
        printf '   %-10s MISSING\n' "$t"; fail=1
    fi
done

# Longest object path, against the hardware's 64-character budget.
longest=$(for t in $TABLES; do echo -n "/${BUCKET}/${PREFIX}/${t}.parquet" | wc -c; done | sort -rn | head -1)
echo "   longest object path: ${longest} chars (hardware budget is 64)"
[ "$longest" -le 64 ] || { echo "   PATH TOO LONG -- shorten the bucket or prefix"; fail=1; }

echo
if [ "$fail" = 0 ]; then
    echo "Ready. Point the benchmarks at this node:"
    echo
    echo "    export OASIS_SERVER=${IP}"
    echo "    ./scripts/util/decoder_ab.sh"
else
    echo "Something above did not verify -- do not trust a benchmark against this server yet." >&2
    exit 1
fi
