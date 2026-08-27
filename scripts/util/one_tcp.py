#!/usr/bin/env python3
"""Raw single-TCP-connection ceiling against MinIO. Drains into a scratch buffer (no concat),
reports wall GB/s plus this process's CPU time so we can see if the *receiver* is the limit."""
import socket, sys, time, os, resource

SERVER = os.environ.get("SERVER", "10.253.74.74")
PORT   = int(os.environ.get("PORT", "9000"))
OBJ    = os.environ.get("OBJ", "/throughput/tpch-30/lineitem.parquet")
RCVBUF = int(os.environ.get("RCVBUF", "0"))          # 0 = kernel default/autotune

def connect():
    s = socket.create_connection((SERVER, PORT))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if RCVBUF:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RCVBUF)
    return s

def get(off, length):
    return (f"GET {OBJ} HTTP/1.1\r\nHost: {SERVER}:{PORT}\r\n"
            f"Range: bytes={off}-{off+length-1}\r\nConnection: keep-alive\r\n\r\n").encode()

class Sess:
    def __init__(self):
        self.s = connect(); self.buf = b""
        self.scratch = memoryview(bytearray(1 << 20))
    def send(self, off, n): self.s.sendall(get(off, n))
    def resp(self):
        while b"\r\n\r\n" not in self.buf:
            d = self.s.recv(1 << 16)
            if not d: raise RuntimeError("closed")
            self.buf += d
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        if b"206" not in head.split(b"\r\n")[0] and b"200" not in head.split(b"\r\n")[0]:
            raise RuntimeError(head.split(b"\r\n")[0])
        n = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"): n = int(line.split(b":")[1])
        take = min(n, len(rest)); self.buf = rest[take:]; left = n - take
        while left:
            got = self.s.recv_into(self.scratch, min(left, len(self.scratch)))
            if not got: raise RuntimeError("closed mid-body")
            left -= got
        return n
    def close(self):
        try: self.s.close()
        except OSError: pass

def cpu(): 
    r = resource.getrusage(resource.RUSAGE_SELF); return r.ru_utime + r.ru_stime

def run(chunk, depth, total_bytes, span_bytes):
    """Walk `total_bytes` in `chunk`-sized ranged GETs, `depth` outstanding, within [0, span_bytes)."""
    reqs = max(1, total_bytes // chunk)
    span = max(1, span_bytes // chunk)
    s = Sess(); got = 0
    c0 = cpu(); t0 = time.perf_counter()
    sent = done = 0
    while done < reqs:
        while sent - done < depth and sent < reqs:
            s.send((sent % span) * chunk, chunk); sent += 1
        got += s.resp(); done += 1
    wall = time.perf_counter() - t0; cput = cpu() - c0
    s.close()
    return got, wall, cput, reqs

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "depth"
    GB = 1 << 30
    SPAN = int(os.environ.get("SPAN", str(2 * GB)))       # keep inside the warmed prefix
    LOAD = int(os.environ.get("LOAD", str(2 * GB)))       # bytes moved per point
    if mode == "depth":
        chunk = int(os.environ.get("CHUNK", str(768 * 1024)))
        print(f"one connection, {chunk//1024} KiB ranged GETs, {LOAD/GB:.1f} GiB per point")
        print(f"  {'depth':>5} {'s':>7} {'GB/s':>8} {'cpu s':>7} {'cpu%':>6} {'ms/GET':>8}")
        for d in (1, 2, 4, 8, 16, 32):
            got, wall, cput, reqs = run(chunk, d, LOAD, SPAN)
            print(f"  {d:>5} {wall:7.2f} {got/wall/1e9:8.3f} {cput:7.2f} {100*cput/wall:5.0f}% {wall/reqs*1e3:8.3f}")
    elif mode == "conns":
        pass
    elif mode == "chunk":
        depth = int(os.environ.get("DEPTH", "2"))
        print(f"one connection, depth {depth}, {LOAD/GB:.1f} GiB per point")
        print(f"  {'chunk KiB':>9} {'s':>7} {'GB/s':>8} {'cpu%':>6} {'ms/GET':>8}")
        for c in (64, 128, 256, 512, 768, 1024, 2048, 4096, 8192, 16384, 65536):
            got, wall, cput, reqs = run(c * 1024, depth, LOAD, SPAN)
            print(f"  {c:>9} {wall:7.2f} {got/wall/1e9:8.3f} {100*cput/wall:5.0f}% {wall/reqs*1e3:8.3f}")

def conns_mode():
    import threading
    chunk = int(os.environ.get("CHUNK", str(16 * 1024 * 1024)))
    depth = int(os.environ.get("DEPTH", "2"))
    GB = 1 << 30
    SPAN = int(os.environ.get("SPAN", str(2 * GB)))
    LOAD = int(os.environ.get("LOAD", str(GB)))
    print(f"{chunk//1024//1024} MiB ranged GETs, depth {depth}, {LOAD/GB:.1f} GiB per connection, all inside the warm {SPAN/GB:.0f} GiB prefix")
    print(f"  {'conns':>5} {'s':>7} {'GB/s':>8} {'GB/s per conn':>14}")
    for n in (1, 2, 4, 8):
        res = [None]*n
        bar = threading.Barrier(n)
        def worker(i):
            s = Sess(); got = 0
            reqs = max(1, LOAD // chunk); span = max(1, SPAN // chunk)
            bar.wait(); t0 = time.perf_counter()
            sent = done = 0
            while done < reqs:
                while sent - done < depth and sent < reqs:
                    s.send(((i * 7 + sent) % span) * chunk, chunk); sent += 1
                got += s.resp(); done += 1
            res[i] = got; s.close()
        ts = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
        t0 = time.perf_counter()
        for t in ts: t.start()
        for t in ts: t.join()
        wall = time.perf_counter() - t0
        tot = sum(res)
        print(f"  {n:>5} {wall:7.2f} {tot/wall/1e9:8.3f} {tot/wall/1e9/n:14.3f}")

if __name__ == "__main__" and sys.argv[1:2] == ["conns"]:
    conns_mode()
