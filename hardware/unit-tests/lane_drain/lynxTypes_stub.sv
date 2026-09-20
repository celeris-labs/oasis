// Minimal stub so the HTTP client RTL can be simulated without the Coyote packages.
// Values mirror hw/templates/common/lynx_pkg_tmplt.txt (cross-checked against
// hardware/build-*/oasis_config_0/user_c0_0/hdl/lynx_pkg.sv).
//
// VADDR_BITS is the shell's cnfg.vaddr_bits (48 on the U55C build) and LEN_BITS is 28. Both are
// needed by handler_slots' card-DMA side and by unit-tests/card_dma/card_dma_model.sv, and they are
// the same values unit-tests/slot_writer/lynxTypes_stub.sv carries.
package lynxTypes;
    parameter int AXI_DATA_BITS           = 512;
    parameter int TCP_OPEN_CONN_REQ_BITS  = 48;
    parameter int TCP_OPEN_CONN_RSP_BITS  = 72;
    parameter int TCP_CLOSE_CONN_REQ_BITS = 16;
    parameter int TCP_NOTIFY_BITS         = 88;
    parameter int TCP_RD_PKG_REQ_BITS     = 32;
    parameter int TCP_RX_META_BITS        = 16;
    parameter int TCP_SESSION_BITS        = 16;
    parameter int TCP_LEN_BITS            = 16;
    parameter int TCP_TX_META_BITS        = 32;
    parameter int TCP_TX_STAT_BITS        = 64;
    parameter int TCP_ERROR_BITS          = 2;
    parameter int VADDR_BITS              = 48;
    parameter int LEN_BITS                = 28;
    parameter int PID_BITS                = 6;
    parameter int DEST_BITS               = 4;
    parameter int OPCODE_BITS             = 5;
    parameter int STRM_BITS               = 2;
endpackage
