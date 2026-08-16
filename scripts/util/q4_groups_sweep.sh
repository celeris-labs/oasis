#!/usr/bin/env bash
# q4 at several groups-in-flight settings, to find where the receive path stops keeping up.
#
# q4 projects 3 column chunks per row group, so occupancy is 3 x this setting. At the default 16
# that is 48 chunks of data arriving concurrently against a decoder that handles one at a time --
# and the TOE drops every segment once its buffer has less than 24000 bytes free rather than
# throttling cleanly, so falling behind costs a dup-ACK storm instead of back-pressure.
set -uo pipefail
ROOT=/scratch/jkreissl/oasis
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-30}
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

# NOT "GROUPS": that is a bash built-in holding the caller's group IDs, so ${GROUPS:-...} silently
# used those instead of the default and ran the sweep at groups_in_flight=264587.
for g in ${SWEEP_GROUPS:-2 4 8 16}; do
    echo "=============== oasis_scan_groups_in_flight=$g  (expect inflight ~ 3x) ==============="
    OASIS_HTTP_DEBUG=1 OASIS_HTTP_CHUNK_BYTES=${OASIS_HTTP_CHUNK_BYTES:-786432} \
    timeout "${TIMEOUT:-120}" "$ROOT/extension/build/release/duckdb" -c "
        SET http_server='$SERVER'; SET http_port=$PORT; SET threads=1;
        SET oasis_scan_groups_in_flight=$g;
        CREATE OR REPLACE VIEW orders   AS SELECT * FROM read_oasis('httpfpga:///throughput/tpch-$SCALE/orders.parquet');
        CREATE OR REPLACE VIEW lineitem AS SELECT * FROM read_oasis('httpfpga:///throughput/tpch-$SCALE/lineitem.parquet');
        $(sed 's/;$//' "$ROOT/scripts/tpch/q04.sql");" > /tmp/q4-g$g.txt 2>&1
    rc=$?
    peak=$(grep -oE 'inflight=[0-9]+' /tmp/q4-g$g.txt | grep -oE '[0-9]+' | sort -n | tail -1)
    if [ "$rc" = 124 ]; then
        echo "  TIMED OUT   peak inflight=${peak:-?}   $(grep -oE 'stalled:.*' /tmp/q4-g$g.txt | tail -1)"
        echo "  -> this is where the receive path stops keeping up"
        break
    elif [ "$rc" != 0 ]; then
        echo "  ERROR rc=$rc"
        grep -iE 'error|Error|exception|stalled' /tmp/q4-g$g.txt | tail -4 | sed 's/^/    /'
        break
    else
        echo "  OK          peak inflight=${peak:-?}"
        grep -vE '^\[oasis-http\]|^ ' /tmp/q4-g$g.txt | grep -v '^$' | head -6 | sed 's/^/    /'
    fi
done
