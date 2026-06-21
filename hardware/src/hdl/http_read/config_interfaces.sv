`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::data32_t;
import http_types::http_config_t;

/**
 * One queued HTTP ranged-GET request for HTTPRead.
 * The host writes binary server_ip/port/path/range plus expected payload size;
 * ASCII for Host:/Range: is formatted inside http_req_builder.
 */
interface http_read_config_i (
    input logic clk,
    input logic rst_n
);
    http_config_t cfg;
    data32_t      size;
    logic         valid;
    logic         ready;
    // Debug-only: live FSM state packed by HTTPRead (modport s drives it), read back
    // by HTTPReadConfig (modport m) and exposed on a host-readable read CSR.
    data32_t      status;

    modport m (
        output cfg, size, valid,
        input ready, status
    );

    modport s (
        output ready, status,
        input cfg, size, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(cfg, valid, ready);
    `STF_ASSERT_STABLE(size, valid, ready);
    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
`endif
endinterface
