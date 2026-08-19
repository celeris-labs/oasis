#!/usr/bin/env bash
#
# How fast can MinIO actually deliver to THIS host? The number that turns "the decoder is the
# bottleneck" from an inference into a demonstration.
#
# The FPGA consumes ~1.0 GB/s and its receive window sits at ~13% of the buffer, which says flow
# control is throttling the sender. That only proves the DECODER is at fault if the sender could
# have gone faster. This measures exactly that: the same object, the same server, the same 100 GbE
# storage network -- with an ordinary host reading instead of the FPGA.
#
# Run it ON alveo-u55c-04 (10.253.74.78), which shares the storage net with MinIO on -03. Running it
# from a build node measures that node's uplink instead and understates MinIO badly.
#
#   ./scripts/util/minio_ceiling.sh            # 1, 2, 4, 8, 16 parallel streams
set -uo pipefail
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
OBJ=${OBJ:-/throughput/tpch-30/lineitem.parquet}
MB=${MB:-256}                     # bytes each stream pulls
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

echo "MinIO deliverable throughput to $(hostname -s)  --  $MB MiB per stream"
echo "object: http://$SERVER:$PORT$OBJ"
echo
printf '%8s %12s %12s\n' streams elapsed_s GB/s
printf '%8s %12s %12s\n' ------- --------- -----
BYTES=$((MB * 1024 * 1024))
for n in 1 2 4 8 16; do
    t0=$(date +%s.%N)
    for i in $(seq "$n"); do
        # each stream reads a DIFFERENT region, so this measures the server and the link rather
        # than MinIO's page cache serving the same block n times
        off=$(( (i - 1) * BYTES + 1000000 ))
        curl -s -o /dev/null --noproxy '*' \
             -H "Range: bytes=$off-$((off + BYTES - 1))" \
             "http://$SERVER:$PORT$OBJ" &
    done
    wait
    t1=$(date +%s.%N)
    awk -v a="$t0" -v b="$t1" -v n="$n" -v by="$BYTES" \
        'BEGIN{ e=b-a; printf "%8d %12.3f %12.2f\n", n, e, (n*by)/e/1e9 }'
done
echo
echo "compare against the FPGA path, measured from the decoder's own counters: 1.02 GB/s"
echo
echo "  much higher  -> the server and link have headroom; the FPGA's window is small because the"
echo "                  DECODER cannot drain faster. More decoders is the fix."
echo "  about 1 GB/s -> the server or the link is the limit, not the decoder, and the whole"
echo "                  argument needs rethinking before the meeting."
