// Minimal stub so slot_writer / slot_reader / the card DMA model can be simulated without the
// Coyote packages. Values mirror hw/templates/common/lynx_pkg_tmplt.txt (VADDR_BITS is the shell's
// cnfg.vaddr_bits, 48 on the U55C build; LEN_BITS is 28).
package lynxTypes;
    parameter int AXI_DATA_BITS       = 512;
    parameter int VADDR_BITS          = 48;
    parameter int LEN_BITS            = 28;
    parameter int PID_BITS            = 6;
    parameter int DEST_BITS           = 4;
    parameter int OPCODE_BITS         = 5;
    parameter int STRM_BITS           = 2;
    // Only needed so strip_http and friends compile against the same stub.
    parameter int TCP_NOTIFY_BITS     = 88;
    parameter int TCP_RD_PKG_REQ_BITS = 32;
    parameter int TCP_RX_META_BITS    = 16;
    parameter int TCP_SESSION_BITS    = 16;
    parameter int TCP_LEN_BITS        = 16;
endpackage
