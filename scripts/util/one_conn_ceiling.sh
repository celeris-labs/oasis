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

python3 - "$SERVER" "$PORT" "$OBJ" "$CHUNK" "$N" <<'PYEOF2'
import socket, sys, time
server, port, obj, chunk, n = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])

# http.client refuses to pipeline -- it raises CannotSendRequest if a reply is outstanding. HTTP/1.1
# pipelining is legal and MinIO answers in order, so this speaks it directly over a socket.
def req(i):
    off = i * chunk
    return (f"GET {obj} HTTP/1.1\r\nHost: {server}:{port}\r\n"
            f"Range: bytes={off}-{off+chunk-1}\r\nConnection: keep-alive\r\n\r\n").encode()

class Reader:
    def __init__(self, sock): self.s = sock; self.buf = b""
    def fill(self):
        d = self.s.recv(1 << 20)
        if not d: raise RuntimeError("server closed")
        self.buf += d
    def one_response(self):
        while b"\r\n\r\n" not in self.buf: self.fill()
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        self.buf = rest
        while len(self.buf) < length: self.fill()
        body, self.buf = self.buf[:length], self.buf[length:]
        return len(body)

def run(label, depth):
    s = socket.create_connection((server, port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    r = Reader(s)
    total = 0; sent = 0; pend = 0
    t0 = time.perf_counter()
    while sent < n or pend:
        while pend < depth and sent < n:
            s.sendall(req(sent)); sent += 1; pend += 1
        total += r.one_response(); pend -= 1
    el = time.perf_counter() - t0
    s.close()
    print(f"  {label:<36} {total/1e6:7.0f} MB {el:6.2f} s {total/el/1e9:7.3f} GB/s")

print(f"one TCP connection, {chunk//1024} KiB ranged GETs, {n} of them")
print()
for d in (1, 2, 4, 8, 16, 32):
    run(f"pipeline depth {d}", d)
print()
print("  FPGA on the same pattern, measured:  ~0.33 GB/s")
print()
print("  depth 8+ much higher -> the connection has headroom and the FPGA is not exploiting")
print("                          pipelining. The fault is in our request/response path.")
print("  depth 8+ ~ 0.35 GB/s -> we are AT the single-connection ceiling. Only more sessions")
print("                          would help, and RX_DDR_BYPASS forbids them.")
PYEOF2
