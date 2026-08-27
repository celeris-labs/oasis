#!/usr/bin/env bash
#
# How much does MinIO give us per CONNECTION, in the request shape the FPGA actually uses?
#
# one_conn_ceiling.sh answered "what can ONE session deliver" (0.463 GB/s, all of the pipelining
# gain collected by depth 2). minio_ceiling.sh answered "what can the server deliver at all", but
# with one 256 MiB curl read per stream -- the easiest possible case for a server and NOT what the
# FPGA does. Neither of them answers the question the multi-session bitstream rests on:
#
#     with N sessions each issuing back-to-back ranged GETs, what is the total, and where does it
#     stop scaling?
#
# That number is the ceiling for a bitstream with N decode lanes, and the honest prediction to write
# down BEFORE the hardware run is N x 0.46 GB/s until the server saturates.
#
# Section 2 sweeps the chunk size on ONE connection. Throughput was measured to be near-linear in
# chunk size (a GET costs ~1.4 ms of MinIO time-to-first-byte whatever its size), and the sweep has
# never been run above 1 MiB. The knee is a free win if it exists, since the chunk size is a
# software constant.
#
# Run it ON alveo-u55c-04 -- it must share the storage network with MinIO. From a build node this
# measures that node's uplink and understates the server badly.
#
#   ./scripts/util/conn_scaling.sh                 # both sections
#   MODE=conn ./scripts/util/conn_scaling.sh       # connection scaling only
#   MODE=chunk MB=512 ./scripts/util/conn_scaling.sh
set -uo pipefail
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
OBJ=${OBJ:-/throughput/tpch-30/lineitem.parquet}
CHUNK=${CHUNK:-786432}                 # the FPGA's default HTTP chunk
DEPTH=${DEPTH:-2}                      # pipelining beyond 2 buys nothing on one session
MB=${MB:-256}                          # bytes EACH connection pulls per point
CONNS=${CONNS:-"1 2 4 8 16"}
CHUNK_LIST=${CHUNK_LIST:-"131072 262144 524288 786432 1048576 2097152 4194304"}
MODE=${MODE:-both}                     # conn | chunk | both
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

python3 - "$SERVER" "$PORT" "$OBJ" "$CHUNK" "$DEPTH" "$MB" "$MODE" "$CONNS" "$CHUNK_LIST" <<'PYEOF'
import socket, sys, threading, time

server, port, obj = sys.argv[1], int(sys.argv[2]), sys.argv[3]
chunk, depth, mb, mode = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
conn_list  = [int(x) for x in sys.argv[8].split()]
chunk_list = [int(x) for x in sys.argv[9].split()]

def get(off, length):
    return (f"GET {obj} HTTP/1.1\r\nHost: {server}:{port}\r\n"
            f"Range: bytes={off}-{off+length-1}\r\nConnection: keep-alive\r\n\r\n").encode()

class Session:
    """One keep-alive socket. Bodies are drained into a scratch buffer rather than concatenated --
    at 4+ GB/s the buf += d of the simpler reader becomes the measurement."""
    def __init__(self):
        self.s = socket.create_connection((server, port))
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.scratch = memoryview(bytearray(1 << 20))

    def send(self, off, length):
        self.s.sendall(get(off, length))

    def response(self):
        while b"\r\n\r\n" not in self.buf:
            d = self.s.recv(1 << 16)
            if not d: raise RuntimeError("server closed the connection")
            self.buf += d
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0]
        if b"206" not in status and b"200" not in status:
            raise RuntimeError(f"bad status: {status!r}")
        length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        take = min(length, len(rest))
        self.buf = rest[take:]
        left = length - take
        while left:
            n = self.s.recv_into(self.scratch, min(left, len(self.scratch)))
            if n == 0: raise RuntimeError("server closed mid-body")
            left -= n
        return length

    def close(self):
        try: self.s.close()
        except OSError: pass

def object_size():
    s = Session()
    s.send(0, 1)
    # Content-Range: bytes 0-0/6291456789 -- the only way to the length without a HEAD, and HEAD is
    # not what the FPGA speaks.
    while b"\r\n\r\n" not in s.buf:
        s.buf += s.s.recv(1 << 16)
    head = s.buf.split(b"\r\n\r\n")[0]
    total = None
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-range:"):
            total = int(line.split(b"/")[1])
    s.response(); s.close()
    if total is None: raise RuntimeError("no Content-Range; cannot size the object")
    return total

SIZE = object_size()
print(f"object {obj} on {server}:{port} -- {SIZE/1e9:.2f} GB")
print()

def stream(idx, n_conns, chunk, reqs, depth, results, barrier):
    """Each connection walks its OWN slice of the file, so this measures the server rather than
    MinIO serving one hot block n times."""
    slice_len = SIZE // n_conns
    base = idx * slice_len
    span = max(1, slice_len // chunk)          # chunks available in this slice, before wrapping
    sess = Session()
    total = 0
    try:
        barrier.wait()
        t0 = time.perf_counter()
        sent = done = 0
        while done < reqs:
            while sent - done < depth and sent < reqs:
                sess.send(base + (sent % span) * chunk, chunk); sent += 1
            total += sess.response(); done += 1
        results[idx] = (total, time.perf_counter() - t0, None)
    except Exception as e:
        results[idx] = (total, 0.0, e)
    finally:
        sess.close()

def point(n_conns, chunk, depth, mb):
    reqs = max(1, (mb * 1024 * 1024) // chunk)
    results = [None] * n_conns
    barrier = threading.Barrier(n_conns)
    threads = [threading.Thread(target=stream, args=(i, n_conns, chunk, reqs, depth, results, barrier))
               for i in range(n_conns)]
    t0 = time.perf_counter()
    for t in threads: t.start()
    for t in threads: t.join()
    wall = time.perf_counter() - t0
    err = next((r[2] for r in results if r and r[2]), None)
    if err: return None, None, str(err)
    total = sum(r[0] for r in results)
    return total, wall, None

if mode in ("conn", "both"):
    print(f"1. connection scaling -- {chunk//1024} KiB ranged GETs, depth {depth}, {mb} MiB per connection")
    print()
    print(f"  {'conns':>6} {'MB':>9} {'s':>7} {'GB/s':>9} {'GB/s per conn':>15}")
    print(f"  {'-'*6:>6} {'-'*9:>9} {'-'*7:>7} {'-'*9:>9} {'-'*15:>15}")
    for n in conn_list:
        total, wall, err = point(n, chunk, depth, mb)
        if err:
            print(f"  {n:>6}   FAILED: {err}")
            continue
        print(f"  {n:>6} {total/1e6:9.0f} {wall:7.2f} {total/wall/1e9:9.3f} {total/wall/1e9/n:15.3f}")
    print()
    print("  per-conn column flat  -> the server is not the limit yet; N lanes are worth N x.")
    print("  per-conn column falls -> MinIO is saturating; that N is the useful lane count.")
    print()

if mode in ("chunk", "both"):
    print(f"2. chunk size on ONE connection -- {mb} MiB per point")
    print()
    print(f"  {'chunk KiB':>10} {'depth':>6} {'s':>7} {'GB/s':>9} {'ms per GET':>12}")
    print(f"  {'-'*10:>10} {'-'*6:>6} {'-'*7:>7} {'-'*9:>9} {'-'*12:>12}")
    for c in chunk_list:
        for d in (1, depth) if depth != 1 else (1,):
            total, wall, err = point(1, c, d, mb)
            if err:
                print(f"  {c//1024:>10} {d:>6}   FAILED: {err}")
                continue
            reqs = max(1, (mb * 1024 * 1024) // c)
            print(f"  {c//1024:>10} {d:>6} {wall:7.2f} {total/wall/1e9:9.3f} {wall/reqs*1e3:12.3f}")
    print()
    print("  ms-per-GET flat across sizes -> the cost is per-REQUEST latency and bigger chunks keep")
    print("                                  winning; raise HTTP_DEFAULT_CHUNK_BYTES to the knee.")
    print("  ms-per-GET rising linearly   -> that size is bandwidth-bound, i.e. the knee is here.")
PYEOF
