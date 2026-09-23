package oasis;

import libstf::vaddress_t;
import libstf::size_t;

parameter longint unsigned OASIS_SYSTEM_ID = 64'h0A515;

parameter int NUM_READ_REQ_CONFIG_REGS = 3;
parameter longint unsigned READ_REQ_CONFIG_ID = 64'h2f966a70f04c0e93;

// Inline TLAST injector on the Bloom filter's input stream (see vfpga_top.svh): concatenates
// however many decoded row-group chunks make up the build side, and however many make up the
// probe side, into the two logical transfers (one tlast at the end of build, one at the end of
// probe) the Bloom filter core itself expects.
parameter int NUM_BF_LAST_INJECT_CONFIG_REGS = 3;
parameter longint unsigned BF_LAST_INJECT_CONFIG_ID = 64'ha3f19d2c6b8e0741;

typedef struct packed {
    vaddress_t vaddr;
    size_t     len;
} read_req_t;

endpackage
