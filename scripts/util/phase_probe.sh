#!/usr/bin/env bash
#
# Sample the host's socket state and MinIO's latency every few seconds, while a tpch_demo run is in
# progress. Run it in a second terminal alongside the demo.
#
# Why: the CPU phase's early queries (q1-q9) are reproducible to within 3% across runs, while the
# late ones vary by up to 26x (q22: 7.31 s one run, 191.34 s another). Something accumulates DURING
# the phase. This records what, instead of guessing -- socket counts, ephemeral port usage, and a
# fixed 256-byte fetch whose latency is the control.
#
#   ./scripts/util/phase_probe.sh            # samples until you Ctrl-C
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=${OUT:-$ROOT/.traces/phase-probe.txt}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
EVERY=${EVERY:-5}
mkdir -p "$(dirname "$OUT")"
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

printf '%-8s %8s %8s %8s %9s %9s  %s\n' time tw estab syn ports_used probe_ms note | tee "$OUT"
while true; do
    tw=$(ss -tan state time-wait 2>/dev/null | wc -l)
    est=$(ss -tan state established 2>/dev/null | wc -l)
    syn=$(ss -tan state syn-sent 2>/dev/null | wc -l)
    # distinct local ports in use, against the ephemeral range width
    used=$(ss -tan 2>/dev/null | awk 'NR>1{split($4,a,":"); if(a[length(a)]+0>=32768) print a[length(a)]}' | sort -u | wc -l)
    # the control: one small ranged GET, same shape as a parquet page header read
    ms=$( { /usr/bin/time -f %e curl -s -o /dev/null --noproxy '*' \
            -H "Range: bytes=0-255" "http://$SERVER:$PORT/throughput/tpch-30/orders.parquet" ; } 2>&1 \
          | awk '{printf "%.0f", $1*1000}')
    note=""
    [ "${ms:-0}" -gt 100 ] 2>/dev/null && note="SLOW"
    printf '%-8s %8s %8s %8s %9s %9s  %s\n' "$(date +%H:%M:%S)" "$tw" "$est" "$syn" "$used" "${ms:-?}" "$note" | tee -a "$OUT"
    sleep "$EVERY"
done
