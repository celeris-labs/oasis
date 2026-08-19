#!/usr/bin/env bash
#
# Who is the bottleneck? Read it off the receive window the FPGA advertises.
#
# The window is (appd - recvd) - 1: free space in the TOE's 1 MiB buffer. `recvd` advances when
# bytes ARRIVE, `appd` when our reader CONSUMES. So the window is literally the race between the
# network and the decoder, sampled on every ACK.
#
#   window stays high        -> the reader keeps up. Bottleneck is upstream: MinIO, RTT, or not
#                               enough requests in flight. More depth would help.
#   window parks low / zero  -> data arrives faster than we drain. The DECODER is the bottleneck.
#                               More depth would only fill the fifo sooner.
#   sawtooth                 -> roughly balanced, decoder marginally behind.
#
# A single connection is also capped at throughput <= window / RTT, so a window stuck at 100 KB
# caps you near 1 GB/s on this LAN whatever else is fast.
#
#   ./scripts/util/win_profile.sh capture.pcapng
set -uo pipefail
PCAP=${1:-}
FPGA=${FPGA:-10.253.74.80}
MINIO=${MINIO:-10.253.74.74}
[ -n "$PCAP" ] && [ -f "$PCAP" ] || { echo "usage: $0 <capture.pcap|pcapng>"; exit 1; }
command -v tshark >/dev/null || { echo "tshark not found"; exit 1; }

tshark -r "$PCAP" -Y "ip.src==$FPGA && ip.dst==$MINIO && tcp.len==0 && tcp.flags.ack==1" \
    -T fields -e tcp.window_size 2>/dev/null \
  | awk '
    /^[0-9]+$/ { w[n++] = $1; if ($1 > mx) mx = $1; s += $1 }
    END {
      if (n == 0) { print "no ACKs from the FPGA matched -- check FPGA/MINIO addresses"; exit 1 }
      # buckets as a fraction of the largest window ever advertised (~the buffer size)
      for (i = 0; i < n; i++) {
        f = w[i] / mx
        if      (w[i] == 0)  z++
        else if (f < 0.05)   b1++
        else if (f < 0.25)   b2++
        else if (f < 0.75)   b3++
        else                 b4++
      }
      printf "ACKs sampled       %d\n", n
      printf "largest window     %d bytes  (buffer size)\n", mx
      printf "mean window        %d bytes  (%.0f%% of buffer)\n\n", s/n, 100*(s/n)/mx
      printf "  zero (clamped)   %6.1f%%   %s\n", 100*z/n,  bar(100*z/n)
      printf "  < 5%%  of buffer  %6.1f%%   %s\n", 100*b1/n, bar(100*b1/n)
      printf "  5-25%%            %6.1f%%   %s\n", 100*b2/n, bar(100*b2/n)
      printf "  25-75%%           %6.1f%%   %s\n", 100*b3/n, bar(100*b3/n)
      printf "  > 75%%            %6.1f%%   %s\n\n", 100*b4/n, bar(100*b4/n)
      low = 100*(z+b1+b2)/n
      high = 100*b4/n
      if (low > 50)
        print "VERDICT: the window spends most of its life near empty.\n         The CONSUMER is the bottleneck -- the decoder. More requests in flight\n         would fill the fifo sooner, not move more data."
      else if (high > 50)
        print "VERDICT: the window stays wide open. The reader keeps up easily.\n         The bottleneck is UPSTREAM -- MinIO, round-trip latency, or too few\n         requests in flight. Raising oasis_scan_groups_in_flight should help."
      else
        print "VERDICT: mixed. The two sides are close to balanced; the decoder is\n         marginally behind. Confirm with the decoder counters (in_starved vs\n         in_stalled) before spending area on it."
    }
    function bar(p,  i, out) { out = ""; for (i = 0; i < int(p/2); i++) out = out "#"; return out }
  '
