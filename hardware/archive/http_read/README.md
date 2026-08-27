# Retired HTTP client modules

Modules that are no longer reachable from `hardware/src/vfpga_top.svh` in either build
configuration. They are kept because they are the predecessors of what shipped, and the reasons
they were replaced are the record of how the design got where it is.

**This directory is deliberately outside `hardware/src/hdl/`.** Coyote's `cr_user.tcl` copies
`src/hdl/*` into the Vivado project and calls `add_files` on the result, both recursively -- so an
`archive/` folder nested inside `src/hdl/http_read/` would still be compiled into every build. Only
a path outside `src/hdl/` actually removes these from synthesis.

| module | what it was | replaced by | why |
|---|---|---|---|
| `handler.sv` | descriptor ring: `NUM_SLOTS` slots each holding a full 1160-bit `http_config_t`, with the FPGA rebuilding the GET text per request | `handler_stream.sv`, then `handler_multi.sv` | queue depth was an amount of FPGA registers, not a design choice. Measured on a scale-30 `lineitem` scan the 4-slot ring was full for **1462 of 1465 requests** -- the host spent essentially the whole query blocked on a slot. Every byte range is known once the Parquet footer is parsed, so the host can build all the GET text up front and DMA it in |
| `tcp_send_http.sv` | transmit FSM for one descriptor-built request | `http_req_stream.sv` | instantiated only by `handler.sv`. Its job was to drive `http_req_builder` into the TOE transmit handshake; with the text arriving as a host byte stream there is no builder to drive |
| `http_req_builder.sv` | assembled the GET text in hardware from the CSR fields (16 path words, both range endpoints, host string) | host-side construction, streamed over `axis_host_recv` | a request is only text, and nothing about it needs to be stored on the FPGA. This module is what made the per-request state large enough to bound the queue |
| `http_restart_seq.sv` | flush-then-run sequencer: held the HTTP datapath in soft reset for `RST_CYCLES` on every START, then pulsed `run` | nothing -- not instantiated anywhere | it existed because a read that ended badly left stale state in the handler and the normalize/convert pipeline, and the next START inherited it. The failure modes it papered over (`stuck state 9`, no re-arm, body doubled from leftover beats) are handled at their source now: `strip_http` has an explicit `clear` that is only legal on a new connection, and the handlers own reconnect/replay |

## Still exercised by unit tests

Moving these out of the design did not retire their benches. Three `run.sh` scripts point here:

- `hardware/unit-tests/http_req_builder/` -- the assembled GET, byte for byte
- `hardware/unit-tests/http_restart_seq/`
- `hardware/unit-tests/http_pipeline/` -- mixes archived (`handler`, `tcp_send_http`,
  `http_req_builder`) and live (`strip_http`, `tcp_read`, `tcp_session_table`, `tcp_init`) sources,
  via a separate `$ARCHIVE` variable

If a bench here starts failing because a *live* module changed under it, that is not a regression to
chase -- these are frozen designs. `hardware/unit-tests/http_stream/` and `handler_multi/` are the
benches that track what is actually built.
