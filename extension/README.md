# Oasis Extension

DuckDB extension that reads Parquet through the Oasis SmartNIC. The main added functions are:

| Function | Description |
| --- | --- |
| `read_oasis(path)` | Scans a Parquet file through the accelerator. Supports projection and filter pushdown, including row-group pruning from Parquet statistics. |
| `oasis_stream_profile()` | Per-decoder handshake/starve/stall/idle cycle counters and the throughput derived from them. |

The `rdma://` file system is registered alongside them, so `read_oasis('rdma://file.parquet')`
reads from the configured RDMA file server.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `oasis_logging_level` | `ERROR` | libSTF/ParCore/OAL verbosity; records pass through DuckDB's `logging_level` into `duckdb_logs` |
| `oasis_scheduler_num_streams` | all available | Streams the scheduler drives |
| `oasis_scheduler_queue_depth` | hardware FIFO depth | Splinters in flight per stream |
| `oasis_scan_groups_in_flight` | `16` | Row groups a scan keeps submitted but not yet collected, split across its workers |
| `oasis_rdma_server` | — | RDMA file server IP; required for `rdma://` |
| `oasis_rdma_port` | Coyote default | TCP port for the QP exchange |

## Building

Needs `Coyote`, `libstf`, `parcore` and `oasis` installed where CMake can find them.

```sh
make
```

produces `build/release/extension/oasis/oasis.duckdb_extension` plus a `duckdb` shell and a
`unittest` runner with the extension linked in. Configure with `-DEN_SIMULATION=ON` to link the
Coyote simulation library and run without an FPGA (needs `xsim` and `COYOTE_SIM_DIR`).

## Testing

```sh
make test
```

Loading the extension opens the FPGA context, so the tests need a device or a simulation build.
See [test/README.md](test/README.md).

## Limitations

Fixed-width `INT32`, `INT64`, `FLOAT` and `DOUBLE` columns are decoded in hardware, and must be
`PLAIN` or hybrid-encoded. `BYTE_ARRAY` columns fall back to DuckDB's own column reader on the CPU, 
with any encoding. Column chunks may be `UNCOMPRESSED` or `SNAPPY`. Anything else is rejected at 
bind time.

NULLs in fixed-width columns are not supported — the hardware path does not read definition levels.
