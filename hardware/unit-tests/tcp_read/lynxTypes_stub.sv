// Minimal stub so tcp_read.sv (+ strip_http.sv) can be simulated without Coyote packages.
// Values mirror hw/templates/common/lynx_pkg_tmplt.txt.
package lynxTypes;
    parameter int AXI_DATA_BITS       = 512;
    parameter int TCP_NOTIFY_BITS     = 88;
    parameter int TCP_RD_PKG_REQ_BITS = 32;
    parameter int TCP_RX_META_BITS    = 16;
    parameter int TCP_SESSION_BITS    = 16;
    parameter int TCP_LEN_BITS        = 16;
    // Needed to compile tcp_send_http.sv, which tcp_read's bench does not instantiate but which
    // shares this stub for syntax checks.
    parameter int TCP_TX_META_BITS    = 32;
    parameter int TCP_TX_STAT_BITS    = 64;
    parameter int TCP_ERROR_BITS      = 2;
endpackage
