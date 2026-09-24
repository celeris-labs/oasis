#!/usr/bin/env python3
"""Summarise the FEEDTRACE lines of decoder_feed logs: the per-response turnaround of decoder 0.

All times are cycles relative to the decoder taking the previous response's last beat.
  body     first body byte of the next response at the decoder = the bubble the decoder sees
  rd->dat  card read issued -> first beat back (card latency + queueing on the shared channel)
  dat->bd  first beat back -> first body byte (strip_http parses the header byte-serially)
"""
import re, statistics as st, sys

PAT = re.compile(r'FEEDTRACE dec0 (\w+)\s+conn (\d+) \((\d+) B landed.*framer done (-?\d+), pop (-?\d+), '
                 r'next head (-?\d+), card read (-?\d+), card data (-?\d+), first body byte (-?\d+)')
for f in sys.argv[1:]:
    rows = [(m.group(1),) + tuple(int(x) for x in m.groups()[1:])
            for m in (PAT.search(l) for l in open(f, errors='replace')) if m]
    for kind in ('SWITCH', 'CONTINUE'):
        r = [x for x in rows if x[0] == kind]
        if not r:
            continue
        body = [x[8] for x in r]
        rd = [x[7] - x[6] for x in r if x[6] < 99999 and x[7] < 99999]
        hd = [x[8] - x[7] for x in r if x[7] < 99999]
        q = lambda v: 'n/a' if not v else '%d/%d/%d' % (min(v), st.median(v), max(v))
        print('%-40s %-8s n=%-3d bubble min/med/max %-14s rd->dat %-14s dat->bd %s'
              % (f.split('/')[-1], kind, len(r), q(body), q(rd), q(hd)))
