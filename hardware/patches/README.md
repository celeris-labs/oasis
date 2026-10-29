# Patches to the submodules

The hardware build depends on changes to four nested submodules: ParCore (`parcore`), libstf
(`parcore/libstf`), Coyote (`parcore/libstf/coyote`) and its TCP offload engine
(`parcore/libstf/coyote/hw/services/network`, upstream
[fpga-network-stack](https://github.com/fpgasystems/fpga-network-stack)). They live here because
every submodule is pinned to an upstream commit and `git submodule update` resets a submodule's
working tree. Run `bash hardware/patches/apply.sh` from the repository root after every submodule
checkout and before any build.

A recursive clone checks out Coyote's `master` (`590af08`, pinned by libstf). `apply.sh` first
checks out Coyote at `003c7344` on its `dev/tcp` branch and the network submodule at `20633d0`, the
commit that `003c7344` pins, and then applies:

| file | applies to (base) | what it changes |
| --- | --- | --- |
| `0012-parcore-decoder-value-count-once.patch` | parcore (`b3879a0`) | `normalize_until.sv`, `column_chunk_decoder.sv`: every column chunk's value count is taken exactly once. `TypedNormalizeUntil` reads it with the type from its input skid buffer's head, and `ColumnChunkDecoder` retires it on its handshake in any state and takes the next chunk only after that. |
| `0006-libstf-stream-profiler-input-register.patch` | libstf (`7afc162`) | `hardware/src/hdl/util/stream_profiler.sv`: the observed stream's `valid`, `ready`, `last` and the profiler's `stop` pass through one register before anything counts them (a timing fix; the same counts, one cycle later). |
| `0013-libstf-huge-page-cap.patch` | libstf (`7afc162`) | `software/libstf/memory_pool.cpp`: the host memory pool maps 4 free 1 GiB huge pages instead of all of them; `LIBSTF_HUGE_PAGES=N` changes the count, `0` takes them all. |
| `0010-coyote-tcp-management-ports.patch` | Coyote (`003c7344`) | `user_logic`, `user_wrapper` and `dynamic_top` templates: the TCP open, listen and close interfaces go to the user logic instead of the MMU, so the vFPGA opens and closes its own sessions (the host's `openConnTcp` and `listenTcp` no longer reach the stack); `util/program_hacc_local.sh` is made executable. |
| `0011-coyote-rx-buffer-fifo-1mib.patch` | Coyote (`003c7344`) | `tcp_stack.sv`, `network_infrastructure.tcl`: the shared receive FIFO behind the TOE holds 16384 beats of 64 B (1 MiB) instead of 1024, and `axis_max_data_count`, the capacity the TOE is told, moves with it. |
| `0009-toe-window-1mib.patch` | network (`20633d0`) | `toe_config.hpp.in`: the TCP window goes from 256 KiB to 1 MiB (`WINDOW_SCALE_BITS` 2 -> 4). |
| `0001-toe-rx-window-clamp.patch` | network (`20633d0`) | `rx_sar_table.cpp`: advertises a zero receive window while the shared rx FIFO has at most `375 * 64 + MSS` bytes free, the level below which `rx_engine` drops arriving segments. |
| `0002-toe-seed-ephemeral-port-cursor.patch` | network (`20633d0`) | `port_table`, `tx_app_if`, `tx_app_interface`, `toe.cpp`: the ephemeral-port cursor is loaded from a free-running counter at the first open request instead of starting at 32768 after every reset, so a reprogrammed board does not reuse the previous load's 4-tuples. |

`apply.sh` checks every submodule's commit before it changes anything and stops on one it does not
expect, reports a patch that is already in the tree as applied, and only ever dry-runs
(`git apply --check`) before touching a working tree; it never resets, stashes or reverts. Running
it twice is safe.
