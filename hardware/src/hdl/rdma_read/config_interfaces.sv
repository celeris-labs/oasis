`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::data32_t;

/**
 * Interface that contains the address (and length) at which to perform an
 * RDMA read.
 */
interface rdma_read_config_i (
    input logic clk,
    input logic rst_n
);
    vaddress_t    vaddr;
    data32_t      size;
    logic         valid;
    logic         ready;

    modport m (
        output vaddr, size, valid,
        input ready
    );

    modport s (
        output ready,
        input vaddr, size, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(vaddr, valid, ready);
    `STF_ASSERT_STABLE(size, valid, ready);
    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
`endif
endinterface
