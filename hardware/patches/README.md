# Out-of-tree state for the network submodule

Every bitstream this project builds depends on changes that live in a nested submodule and
nowhere else. `git submodule update` silently destroys them. This directory is the rescue copy.

| file | what it is |
| --- | --- |
| `oasis-cmake-defined-guard.bundle` | the two local-only **commits** on branch `oasis/cmake-defined-guard` |
| `0001-toe-rx-window-clamp.patch` | **uncommitted** working-tree change on top of them: the receive-window clamp |
| `0002-toe-seed-ephemeral-port-cursor.patch` | **uncommitted** working-tree change on top of them: the seeded port cursor (build-121 on) |
| `0007-toe-rx-ddr-buffer.patch` | **uncommitted** working-tree change on top of 0001+0002: the receive ring in card memory (`RX_DDR_BYPASS = 0`) made to work; a no-op for bypass builds |
| `0008-network-stack-rx-mem-mux.patch` | **uncommitted** working-tree change to `parcore/libstf/coyote` (not the network submodule): that receive ring wired into the shell (`tcp_mem_mux`, `network_stack.sv`, the CMake flag); a no-op for bypass builds |
| `apply.sh` | idempotent, non-destructive re-application of 0001, 0002, 0007 (network submodule), 0008 (Coyote) and 0006 (libstf) |

## The submodule

```
path (from repo root):  parcore/libstf/coyote/hw/services/network
upstream remote:        https://github.com/fpgasystems/fpga-network-stack.git
branch:                 oasis/cmake-defined-guard   (local only -- never pushed)
expected HEAD:          e9edcc4b2b48b161b17cd60148515130ebeed66a
```

The branch forks from `20633d0` ("Various TCP fixes for Coyote compatibility", the tip of
upstream's `coyote-TCP-RDMA`) and adds two commits:

- `2a2625b` fix the DEFINED guards that made TCP_STACK_* flags silently ignorable
- `e9edcc4` raise the TCP window 256 KiB -> 1 MiB (WINDOW_SCALE_BITS 2 -> 4)

The bundle carries exactly those two. `20633d0` is its prerequisite, so the submodule must
already have upstream's history fetched before the bundle can be unpacked (a normal
`git submodule update --init --recursive` gives you that).

## Restoring after a `git submodule update` wiped it

From the repo root:

```sh
SM=parcore/libstf/coyote/hw/services/network
git -C $SM fetch hardware/patches/oasis-cmake-defined-guard.bundle \
      'oasis/cmake-defined-guard:oasis/cmake-defined-guard'
git -C $SM checkout oasis/cmake-defined-guard
bash hardware/patches/apply.sh
```

Then confirm:

```sh
git -C $SM rev-parse HEAD            # e9edcc4b2b48b161b17cd60148515130ebeed66a
git -C $SM diff --stat               # 14 files: rx_sar_table.cpp (0001) + port_table, tx_app_if,
                                     # tx_app_interface, toe.cpp (0002) + rx_engine, rx_sar_table.hpp,
                                     # rx_app_stream_if, toe_internals.hpp, tx_engine, toe.cpp (0007)
git -C parcore/libstf/coyote diff --stat -- . ':!hw/services/network'
                                     # 4 files (0008): FindCoyoteHW.cmake, network_stack.sv,
                                     # lynx_pkg_tmplt.txt, base.tcl.in -- plus the new, untracked
                                     # hw/hdl/network/tcp/tcp_mem_mux.sv
```

`apply.sh` refuses to do anything unless HEAD is the expected commit (for the network submodule and,
for 0008, Coyote at `b21b4ec6`), reports "already applied" per patch and exits 0 on a second run, and only ever dry-runs (`git apply --check`, or a throw-away
index) before touching the tree. It never resets, stashes or reverts. The patches are a stack in the
listed order: 0007 rewrites lines 0001 added, so once 0007 is in, 0001 no longer reverse-applies on its
own; `apply.sh` therefore first rebuilds HEAD + 0001..k in a temporary index and compares it with the
working tree to find how much of the stack is already there, then falls back to the per-patch check.

## Why the clamp exists

The clamp is in `hls/toe/rx_sar_table/rx_sar_table.cpp`. It forces the advertised receive window
to **zero** whenever free space in the rx buffer falls to `375*64 + MSS` bytes or below.

The TOE computes the window it advertises purely from the rx_sar table -- `(appd - recvd) - 1` --
and has no knowledge of how full the shared rx FIFO actually is. The rx_engine, meanwhile,
accepts an arriving segment only while more than 375 beats are free
(`(rxbuffer_max_data_count - rxbuffer_data_count) > 375` in `rx_engine.cpp`, the `RX_DDR_BYPASS`
branch), i.e. 375 * 64 = 24000 bytes.

Those two disagree. Whenever the reader falls behind far enough that the advertised window lands
in 1..24000 bytes, the receiver invites the peer to send bytes the rx_engine will then drop:
dup-ACK storm, go-back-N, exponential backoff. Measured on this design a single such event costs
up to 13 s of dead air, and any receiver slower than its sender reaches that band eventually.

A zero window is the case TCP already handles well: the sender stops, its persist timer probes
every ~200 ms, and it resumes the moment the application drains. Same throttling, no storm. So
the clamp collapses the entire refuse-band to zero, with one MSS of margin because free space can
shrink between advertising the window and the segment arriving.

## Why the port-cursor seed exists (0002, from build-121)

`free_port_table` in `hls/toe/port_table/port_table.cpp` hands out ephemeral ports 32768..33279
from a cursor that is a `static` initialised to 0, and it pre-fills the depth-4
`portTable2txApp_port_rsp` FIFO a few cycles after reset. So every bitstream load gave its first
four connections **32768, 32769, 32770, 32771**, always the same four.

An origin server cannot tell that the board was reprogrammed, so it still holds the previous
load's sockets `ESTAB`. The new load dials identical 4-tuples, the server answers the SYN with an
ACK for the old connection, the board RSTs, and the SYN retries every ~1.25 s forever
(`[TCP Port numbers reused]` in Wireshark, captured three times on 2026-09-15). Which lanes lock
out is decided by which of the old sockets survived.

The patch makes the port table allocate nothing until `tx_app_if` sees the first open request.
`tx_app_if` then sends one token on the long-commented-out `txApp2portTable_port_req` stream, and
the table loads its cursor from a free-running counter. The cycle that token arrives on is set by
host timing, not by reset, so the start port differs from load to load. After that the allocator
behaves exactly as before. A reprogram still leaves the origin's old sockets behind, but a
collision now needs the new start to land within a few ports of the old one (~1-2% per
reprogram with four lanes) instead of happening every time.

Verified in C simulation (`port_table` + `tx_app_if` cycle by cycle): no port leaves the table
before the first open; the first port is `32768 + ((idle + 2) mod 512)` for any idle time; ports
stay consecutive and in range; used-port checks and releases still work. The full TOE also goes
through Vitis HLS 2024.2 `csynth_design` with these changes.

## The receive ring in card memory (0007)

`0007-toe-rx-ddr-buffer.patch` makes the TOE's non-bypass receive path work at this project's
configuration (512-bit data path, `WINDOW_BITS` 20, i.e. a 1 MiB ring per session in card memory at
`{00, sid, seq[19:0]}`). Upstream only ever exercised that path at 64 bits with 64 KiB rings. Every
change is guarded by `#if !(RX_DDR_BYPASS)` or sits in a function that only exists in that mode, so a
bypass build (every bitstream so far) is unchanged: csynth of `toe_top` with `RX_DDR_BYPASS 1` gives the
same resource numbers and the same RTL with and without the patch. What it fixes:

1. app reads split at a hard-coded 64 KiB instead of the 1 MiB ring end (wrong bytes after every 64 KiB);
2. the read-split stitcher was 64-bit only (now a copy of the tx path's width-generic one);
3. a retransmission overlapping data held behind a gap took no branch, so no drop decision: every later
   packet of every session was paired with the wrong decision, write command and status;
4. sequence numbers compared with plain `<`/`>` (wrong across 2^32);
5. the gap-fill notification length was truncated to 16 bits (bytes never announced): out-of-order data
   is now held only while it ends within 0xFFFF bytes of `recvd`;
6. `free_space > len` refused a segment that exactly fills the advertised window;
7. 0001's clamp (a bypass-FIFO workaround) closed the window ~28 KiB early: now bypass-only;
8. a passive open's "opened" notification waited forever for a write status;
9. a zero-length probe at `recvd - 1` (Linux's zero-window probe and keepalive) got no ACK, so a closed
   window never reopened;
10. a peer without window scaling got the free space modulo 65536 instead of at most 0xFFFF;
11. the second half of a tx retransmission that wraps the tx ring was read from session 0's ring;
12. the ring space of a read was offered to the peer when the read was *issued*: with a near-full ring
    and a read slower than one round trip the peer's next bytes overwrote unread data. A second pointer
    (`appdIssued`) now addresses reads; `appd`, which the window and free space use, moves when the
    read's last beat leaves the TOE.

Verified in C simulation by `hardware/unit-tests/toe_csim` (`./run.sh`, Vitis HLS 2024.2
`csim_design`, the TOE's real top `toe_top` against a model of the peer, the application and card
memory): one case per fix, every case passes with the patch, and reverting any single fix makes its case
fail. Turning the mode on is 0008 below (`--toe-buffer`); every other build keeps the bypass.

## The receive ring wired into the shell (0008) — Coyote

`0008-network-stack-rx-mem-mux.patch` is a working-tree change to **`parcore/libstf/coyote`**
(expected HEAD `b21b4ec6`, which `apply.sh` checks), applied by `apply.sh` after the network stack
(0001/0002/0007). It is what turns 0007 on in a bitstream; oasis selects it with
`ENABLE_HTTP_TOE_BUFFER` (`scripts/synthesize.sh --toe-buffer`), which FORCEs
`TCP_STACK_RX_DDR_BYPASS_EN` to 0 (and to 1 otherwise).

- **One variable for both halves.** `TCP_STACK_RX_DDR_BYPASS_EN` already writes `RX_DDR_BYPASS` into
  the TOE's `toe_config.hpp` (HLS). 0008 makes the same cache variable drive the shell:
  `FindCoyoteHW.cmake` declares it (same default/docstring as `hls/toe/CMakeLists.txt`, whose own
  `set(CACHE)` then does nothing) and refuses anything but the literals `0`/`1` (CMake reads `ON` as
  true, the C preprocessor reads it as 0); `base.tcl` carries it as `cfg(tcp_rx_ddr_bypass)`; the
  `lynx_pkg` template emits `` `define EN_TCP_RX_DDR `` only when it is 0. A mismatch that slipped
  through anyway would not build: the two `toe_ip` variants have different ports.
- **`network_stack.sv`.** Under `` `ifdef EN_TCP_RX_DDR ``: `tcp_stack #(.RX_DDR_BYPASS_EN(0))`
  (which drops the 1 MiB `axis_data_fifo_512_d16384` rx FIFO, `tcp_stack.sv:679`) and `tcp_mem_mux`
  between tcp_stack's memory channels [0] (tx ring) and [1] (rx ring) and the shell's one TCP memory
  channel. `` `else `` is the original text, so a bypass build compiles exactly the old
  `network_stack.sv` (only three comment lines differ) and the old `lynx_pkg.sv` (byte-identical).
- **`tcp_mem_mux.sv`** (new, `hw/hdl/network/tcp/`, picked up by `cr_shell.tcl`'s directory
  `add_files`): rx addresses get bit 29 (rx rings at [512 MiB, 1 GiB), tx rings stay at [0, 512 MiB);
  the datamover returns read data, read status and write status in command order, so the channel of
  every granted command goes into in-order FIFOs and the returns are routed by their heads. Tx writes
  are store-and-forward (1024 beats = the TOE's largest tx write, 65535 B): the TOE issues a tx write
  command before the application has delivered its data, and a granted command whose data is missing
  would stall every later rx write. Write commands are accepted eagerly (the TOE writes a ring-end
  split's second command together with the first part's last beat), and per-channel write-status FIFOs
  with credits keep a channel that stops reading its statuses from stopping the other one. Read data
  is not buffered: a stalled read consumer holds up the other channel's reads (head-of-line, documented
  in the file; oasis keeps the rx read consumer at tready = 1).

Verified by `hardware/unit-tests/tcp_mem_mux` (`./run.sh`, xsim 2024.2: random traffic on both
channels against an in-order datamover model, plus three mutants the bench must catch) and by a
shell synthesis with the flag on (toe-buffer WP2 report, oasis-debug/2026-10-11/toe-buffer/WP2.md).

## The card-memory pool constants (0003) — EN_MEM shells only

`0003-driver-card-pool-12g.patch` is the odd one out here: it is **not** an HDL patch against the
network submodule, so `apply.sh` neither knows nor should know about it. It changes the Coyote
*driver* — `driver/include/coyote_defs.h` in the `parcore/libstf/coyote` submodule — and the driver
this project actually inserts is the out-of-tree copy `oasis-debug/coyote-driver-$(uname -r)/`, so
the change is made and built there; the patch exists only so it survives a `git submodule update`
and can be re-cut against a newer Coyote. It raises the UltraScale+ card-memory pools from
upstream's 4 GB + 4 GB to `N_SMALL_CHUNKS` = 256 Ki chunks (1 GB of regular pages) and
`N_LARGE_CHUNKS` = 12 × 256 Ki chunks (12 GB of huge pages), which with `MEM_START` = 256 MB puts
the top of the pool at 13.25 GB of the U55C's 16 GB HBM. It matters **only for a shell built with
`EN_MEM=1`** (the HBM-slot receive path, ADR-5 in `hardware/src/hdl/http_read/ARCHITECTURE.md`):
with `en_mem` the driver allocates a card-memory shadow for every buffer a process maps
(`vfpga_gup.c` → `alloc_card_memory`), and huge pages are billed in 4 KB chunks, so a single 1 GB
huge page costs 262144 of them and the fifth `userMap` fails against upstream's 4 GB pool — while
OASIS maps `LIBSTF_HUGE_PAGES=10` huge pages plus one 1 GB slot page. On an `EN_MEM=0` shell (every
bitstream up to build-122) no card shadow is allocated at all and the two constants are dead. Cost
is 52 MB of `vzalloc`'d chunk metadata instead of 32 MB (`sizeof(struct chunk)` = 16 B).

## The StreamProfiler input register (0006) — libstf

`0006-libstf-stream-profiler-input-register.patch` is, like 0003/0004, not for the network submodule,
so it is not applied to that submodule; `apply.sh` applies it to libstf in a second step. It is a working-tree change to **`parcore/libstf`** (expected HEAD
`31d98eb`), file `hardware/src/hdl/util/stream_profiler.sv`, and unlike 0003/0004 it **is** part of
every bitstream: the build seals libstf's HDL into `hdl/ext/raw/lib1/`, so a `git submodule update`
that wipes it silently rebuilds the old profiler. Re-apply from the repo root and confirm:

```sh
git -C parcore/libstf apply --check ../../hardware/patches/0006-libstf-stream-profiler-input-register.patch
git -C parcore/libstf apply         ../../hardware/patches/0006-libstf-stream-profiler-input-register.patch
git -C parcore/libstf diff --stat -- hardware/src/hdl/util   # stream_profiler.sv | 41 (32 insertions, 9 deletions)
```

(`git -C parcore/libstf apply --check --reverse ...` succeeding means it is already applied.)

What it does: `StreamProfiler` takes the observed stream's `valid`, `ready` and `last`, and its own
`stop`, through one register before anything counts them. Every ColumnChunkDecoder instantiates two of
them (`inst_profile_in` / `inst_profile_out`, parcore `column_chunk_decoder.sv`), and the decoder's
`in.ready` -- a deep cone out of the page header parser -- fanned out into the clock enables of the
64-bit handshake/stalled/starved counters. On build-133 (4 decoders, placed) that was the worst path
of the whole design, SLR2 -> SLR1: `gen_http_decoders[1]` page_header_parser -> inst_profile_in
counters CE at -2.188 ns (-1.866 for decoder 3; 1,231 failing endpoints in 133). With every input
registered the profiler is exactly its old self one cycle later: the same counts, reported one cycle
late, and nothing about the observed stream changes. The instantiation is inside parcore, which is
why the register lives in libstf and not at the call site.
