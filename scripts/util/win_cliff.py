#!/usr/bin/env python3
"""Decide whether a capture is consistent with the rx_engine flow-control cliff.

rx_engine.cpp:1295, RX_DDR_BYPASS branch, accepts a segment only when
    (rxbuffer_max_data_count - rxbuffer_data_count) > 375   beats  = 24000 bytes.
rx_sar_table advertises (appd - recvd) - 1 and knows nothing about that floor, so an
advertised window anywhere in 1..24000 invites the peer to send bytes the receiver will
drop -- and only the reader draining can ever end it.

Reads tshark CSV on stdin:
    time, stream, ip.src, tcp.window_size, dup_ack, rst, fin, tcp.len
"""
import sys, os, collections

FPGA  = os.environ.get("FPGA", "10.253.74.80")
CLIFF = int(os.environ.get("CLIFF", "24000"))
# A handful of dup ACKs is ordinary loss recovery; a storm is the deadlock signature.
DUP_STORM = int(os.environ.get("DUP_STORM", "20"))


def blank():
    return {"win": [], "dup": 0, "rst": False, "fin": False, "bytes": 0,
            "min": None, "cliff_t": None, "last_t": None}


def main():
    S = collections.defaultdict(blank)
    for line in sys.stdin:
        f = line.rstrip("\n").split(",")
        if len(f) < 8:
            continue
        t, st, src, win, dup, rst, fin, ln = f[:8]
        if not st:
            continue
        try:
            t = float(t)
        except ValueError:
            continue
        s = S[st]
        s["last_t"] = t
        if rst == "1":
            s["rst"] = True
        if fin == "1":
            s["fin"] = True
        try:
            s["bytes"] += int(ln or 0)
        except ValueError:
            pass
        if src != FPGA:
            continue
        if dup:
            s["dup"] += 1
        if not win:
            continue
        try:
            w = int(win)
        except ValueError:
            continue
        s["win"].append((t, w))
        if s["min"] is None or w < s["min"]:
            s["min"] = w
        if 0 < w <= CLIFF and s["cliff_t"] is None:
            s["cliff_t"] = t

    if not S:
        print("no packets matched -- check the FPGA/MINIO addresses")
        return 1

    hits = miss = 0
    hdr = "{:>6} {:>9} {:>8} {:>7} {:>5}  {}".format(
        "stream", "MiB", "minWin", "dupACK", "end", "verdict")
    print(hdr)
    print("-" * len(hdr))
    for st, s in sorted(S.items(), key=lambda kv: int(kv[0])):
        if not s["win"]:
            continue
        end = "RST" if s["rst"] else ("FIN" if s["fin"] else "-")
        died = s["rst"] or s["dup"] >= DUP_STORM
        band = s["cliff_t"] is not None
        if died and band:
            verdict = "DIED after entering the band at t={:.3f}s -> PREDICTED".format(s["cliff_t"])
            hits += 1
        elif died and not band:
            verdict = "DIED with window never below {} -> FALSIFIES".format(CLIFF)
            miss += 1
        elif band:
            verdict = "survived despite entering the band -> FALSIFIES"
            miss += 1
        else:
            verdict = "healthy, never approached the cliff -> PREDICTED"
            hits += 1
        print("{:>6} {:>9.1f} {:>8} {:>7} {:>5}  {}".format(
            st, s["bytes"] / 1048576.0, s["min"], s["dup"], end, verdict))

    print("-" * len(hdr))
    print("consistent: {}   inconsistent: {}".format(hits, miss))
    if miss:
        print()
        print("At least one stream contradicts the cliff. Do NOT build the rx_sar_table")
        print("change on this evidence -- something else is ending these connections.")
        return 2
    print()
    print("Every stream behaves as the cliff predicts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
