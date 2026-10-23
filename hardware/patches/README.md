# Patches to the submodules

The hardware build depends on changes to three nested submodules: the TCP offload engine
(`parcore/libstf/coyote/hw/services/network`, upstream
[fpga-network-stack](https://github.com/fpgasystems/fpga-network-stack)), Coyote
(`parcore/libstf/coyote`) and libstf (`parcore/libstf`). They live here because
`git submodule update` resets a submodule's working tree. Run `bash hardware/patches/apply.sh`
from the repository root after every submodule checkout and before any hardware build.

| file | applies to | what it changes | `apply.sh` |
| --- | --- | --- | --- |
| `oasis-cmake-defined-guard.bundle` | network | Two commits on branch `oasis/cmake-defined-guard` (HEAD `e9edcc4b`), on top of upstream `20633d0`: `2a2625b` fixes the `#ifdef DEFINED` guards that let `TCP_STACK_*` CMake flags be ignored; `e9edcc4` raises the TCP window from 256 KiB to 1 MiB (`WINDOW_SCALE_BITS` 2 -> 4). The patches below are cut against it. | no: restore it by hand (below); `apply.sh` checks the HEAD |
| `0001-toe-rx-window-clamp.patch` | network | `rx_sar_table.cpp`: advertises a zero receive window while the shared rx FIFO has at most `375 * 64 + MSS` bytes free, the level below which `rx_engine` drops arriving segments. After 0007 the clamp applies to bypass builds only. | yes |
| `0002-toe-seed-ephemeral-port-cursor.patch` | network | `port_table`, `tx_app_if`, `tx_app_interface`, `toe.cpp`: the ephemeral-port cursor is loaded from a free-running counter at the first open request instead of starting at 32768 after every reset, so a reprogrammed board does not reuse the previous load's 4-tuples. | yes |
| `0003-driver-card-pool-12g.patch` | Coyote driver | `driver/include/coyote_defs.h`: card-memory pools of 1 GB (regular pages) + 12 GB (huge pages) instead of 4 GB + 4 GB. | no (see below) |
| `0004-driver-card-address-overflow.patch` | Coyote driver | On top of 0003. `coyote_defs.h`, `vfpga_hw.c`: card addresses computed in 64 bits (a 32-bit shift wrapped every chunk past 4 GB), regular pool 0.75 GB so that every huge page is 1 GB aligned. | no (see below) |
| `0005-driver-offload-sync-no-spin.patch` | Coyote driver | On top of 0003 and 0004. `vfpga_gup.c`: the offload and sync ioctls return `-EINVAL` for an address that starts no mapped buffer instead of looping in the kernel. | no (see below) |
| `0006-libstf-stream-profiler-input-register.patch` | libstf (HEAD `31d98eb`) | `hardware/src/hdl/util/stream_profiler.sv`: the observed stream's `valid`, `ready`, `last` and the profiler's `stop` pass through one register before anything counts them (a timing fix; the same counts, one cycle later). Part of every bitstream. | yes |
| `0007-toe-rx-ddr-buffer.patch` | network | `rx_app_stream_if`, `rx_engine`, `rx_sar_table`, `toe.cpp`, `toe_internals.hpp`, `tx_engine`: makes the TOE's receive ring in card memory (`RX_DDR_BYPASS = 0`, 512-bit data path, 1 MiB per session) work. Every change is guarded by the non-bypass mode, so bypass builds are unchanged. Covered by `hardware/unit-tests/toe_csim`. | yes |
| `0008-network-stack-rx-mem-mux.patch` | Coyote (HEAD `b21b4ec6`) | `network_stack.sv`, new `hw/hdl/network/tcp/tcp_mem_mux.sv`, `FindCoyoteHW.cmake`, `base.tcl.in`, `lynx_pkg_tmplt.txt`: wires that receive ring into the shell, sharing the TCP memory channel with the transmit rings, and emits `EN_TCP_RX_DDR` into `lynx_pkg`. Inert unless `TCP_STACK_RX_DDR_BYPASS_EN = 0` (`scripts/synthesize.sh --toe-buffer`). Covered by `hardware/unit-tests/tcp_mem_mux`. | yes |

`apply.sh` applies 0001, 0002 and 0007 (in that order; 0007 rewrites lines 0001 adds) to the network
submodule, 0008 to Coyote and 0006 to libstf. It first checks that the network submodule and Coyote
sit on the expected commits, reports a patch that is already in the tree as applied, and only ever
dry-runs (`git apply --check` or a temporary index) before touching a working tree; it never resets,
stashes or reverts. Running it twice is safe.

## Restoring the network submodule

`git submodule update --init --recursive` checks out upstream's commit, which does not contain the
bundle's two commits. From the repository root:

```sh
SM=parcore/libstf/coyote/hw/services/network
git -C $SM fetch "$PWD/hardware/patches/oasis-cmake-defined-guard.bundle" \
      'oasis/cmake-defined-guard:oasis/cmake-defined-guard'
git -C $SM checkout oasis/cmake-defined-guard
bash hardware/patches/apply.sh
```

## The driver patches (0003 to 0005)

They matter only for a shell built with card memory for the user logic (`EN_MEM = 1`), where the
driver gives every buffer a process maps a shadow in card memory. `hardware/CMakeLists.txt` does not
enable it, so `apply.sh` leaves them out. To use them, apply them in order to Coyote before building
the driver:

```sh
for p in 0003 0004 0005; do
    git -C parcore/libstf/coyote apply "$PWD"/hardware/patches/$p-*.patch
done
```
