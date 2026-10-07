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
| `oasis_measure_join_time` | `true` | Fill `join_ms` in the query statistics (below). Needs DuckDB's profiler, which is switched on silently for each query and restored afterwards; set to `false` to leave it alone |
| `oasis_rdma_server` | — | RDMA file server IP; required for `rdma://` |
| `oasis_rdma_port` | Coyote default | TCP port for the QP exchange |

## Query statistics

Every query that scans a `read_oasis` table writes one record to DuckDB's log when it ends:

```sql
CALL enable_logging(level = 'info');
-- run a query
SELECT message.* FROM duckdb_logs WHERE type = 'OasisQueryStats';
```

All values are in milliseconds, and NULL when they do not apply to the query.

| Field | |
| --- | --- |
| `total_query_ms` | Wall clock of the whole query, planning included |
| `scan_only_ms` | Wall clock of the scans that did not use the hardware Bloom filter, summed over scans |
| `scan_celeris_bloom_ms` | Same for scans that used it, plus the time spent submitting and ending its build side |
| `duckdb_bloom_ms` | Time evaluating DuckDB's join Bloom filters in the scans (`oasis_duckdb_bloom_filter`), summed over workers. This is CPU time, so it can exceed the scans' wall clock |
| `join_ms` | DuckDB's operator timing of the query's join operators (hash, nested loop, merge, IE, as-of, cross, positional), as `EXPLAIN ANALYZE` shows it. CPU time summed over workers, for the build and probe sides of the join itself, not the scans below it. NULL without a join or with `oasis_measure_join_time` off |

A scan's wall clock runs from its first worker starting to its last worker returning.

### Hardware Bloom filter statistics

Each run of the hardware Bloom filter (one per scan that used it, so a query with several such joins
writes several) also writes one `OasisBloomFilterStats` record when the query ends. They are the
counters of celeris's `examples/06_bloomfilter`, read once the scan has ended its probe side:

```sql
SELECT message.* FROM duckdb_logs WHERE type = 'OasisBloomFilterStats';
```

| Field | |
| --- | --- |
| `run` | Index of the run within the query, from 0 |
| `build`, `probe` | Per phase, counted from its first accepted input beat to its END: `cycles`, `idle_cycles`, `stalled_cycles` (back pressure), `cmd_wait_cycles` (host too slow writing commands), the causes of the stalls (`stalled_mat_cycles`, `stalled_out_cycles`, `stalled_credit_cycles`), and the derived `stalled_internal_cycles` (e.g. bank conflicts), `data_wait_cycles` (host too slow delivering data) and `beats` |
| `run_perf` | The whole run, first build beat to last handshake on any port: `cycles`, `keys_in_beats`, `values_in_beats`, `kept_out_beats`, `mat_out_beats`, `mask_out_beats`, `out_cycles`, and the latencies `first_out_cycles` and `probe_start_cycles` (measured from the end of the build phase), plus the derived `pipeline_cycles` and `out_bytes` |
| `command_queue_overflowed` | The hardware's sticky status flag, cleared only by a device reset, so once a run overflows, every later run reports it too. Results of the run that overflowed are not reliable |

Everything is in device clock cycles (250 MHz) and beats of 64 B, except the mask out beats, which are 1 B.


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
