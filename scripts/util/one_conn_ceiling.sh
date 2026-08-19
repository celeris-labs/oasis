#!/usr/bin/env bash
#
# What can ONE TCP connection to MinIO deliver, using the same request shape the FPGA uses?
#
# This is the number the whole design rests on. The FPGA holds a single session -- RX_DDR_BYPASS
# gives one shared rx FIFO with no per-session demux, so concurrent connections are impossible --
# and it fetches ~768 KiB ranged GETs back to back over it.
#
# The earlier ceiling test used one huge 256 MiB read per connection, which is the easiest case for
# a server and told us 0.58 GB/s. This uses the FPGA's actual pattern: many medium ranged GETs,
# keep-alive, one socket. If the FPGA's ~330 MB/s is close to this, then no amount of decoder work
# helps and the architecture question is per-session receive buffering.
#
# Run ON alveo-u55c-04 -- it must share the storage network with MinIO on -03.
#
#   ./scripts/util/one_conn_ceiling.sh
set -uo pipefail
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
OBJ=${OBJ:-/throughput/tpch-30/lineitem.parquet}
CHUNK=${CHUNK:-786432}
N=${N:-400}
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

python3 - "$SERVER" "$PORT" "$OBJ" "$CHUNK" "$N" <<'PYEOF'
import http.client, sys, time
server, port, obj, chunk, n = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])

def run(label, pipeline):
    c = http.client.HTTPConnection(server, port)
    c.connect()
    total = 0
    t0 = time.perf_counter()
    if pipeline:
        # send several requests before reading any reply -- what the FPGA does
        depth = 8
        pend = 0
        i = 0
        while i < n or pend:
            while pend < depth and i < n:
                off = i * chunk
                c.putrequest("GET", obj, skip_host=True, skip_accept_encoding=True)
                c.putheader("Host", f"{server}:{port}")
                c.putheader("Range", f"bytes={off}-{off+chunk-1}")
                c.endheaders()
                pend += 1; i += 1
            r = c.getresponse(); total += len(r.read()); pend -= 1
    else:
        for i in range(n):
            off = i * chunk
            c.request("GET", obj, headers={"Range": f"bytes={off}-{off+chunk-1}"})
            r = c.getresponse(); total += len(r.read())
    el = time.perf_counter() - t0
    c.close()
    print(f"  {label:<34} {total/1e6:8.0f} MB  {el:6.2f} s  {total/el/1e9:6.3f} GB/s")

print(f"one TCP connection, {chunk//1024} KiB ranged GETs, {n} of them")
print()
run("sequential (request, wait, repeat)", False)
run("pipelined depth 8 (as the FPGA)", True)
print()
print("  FPGA measured on the same pattern:  ~0.33 GB/s wall, ~0.75 GB/s in-stream")
print()
print("  pipelined number >> FPGA  -> the connection has headroom; the fault is ours")
print("  pipelined number ~ FPGA   -> we are AT the single-connection ceiling, and no decoder")
print("                               or parser work will move it. Per-session buffering is the")
print("                               only way past, and that is a shell-level change.")
PYEOF
