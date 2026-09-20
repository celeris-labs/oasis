# Out-of-tree state for the network submodule

Every bitstream this project builds depends on changes that live in a nested submodule and
nowhere else. `git submodule update` silently destroys them. This directory is the rescue copy.

| file | what it is |
| --- | --- |
| `oasis-cmake-defined-guard.bundle` | the two local-only **commits** on branch `oasis/cmake-defined-guard` |
| `0001-toe-rx-window-clamp.patch` | the **uncommitted** working-tree change that sits on top of them |
| `apply.sh` | idempotent, non-destructive re-application of the patch |

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
git -C $SM diff --stat               # hls/toe/rx_sar_table/rx_sar_table.cpp | 29 +++-
```

`apply.sh` refuses to do anything unless HEAD is the expected commit, reports "already applied"
and exits 0 on a second run, and only ever dry-runs (`git apply --check`) before touching the
tree. It never resets, stashes or reverts.

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
