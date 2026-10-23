import lynxTypes::*;

// =================================================================================================
// Plain AXI4-Stream FIFO (tdata / tkeep / tlast).
//
// The decoupling fifo of a receive lane (tcp_read): it takes the beats the dispatcher routes to the
// lane at line rate while the framer walks a header one byte per cycle, so the TCP stack's receive
// path never waits on the parser. Plain inferred BRAM rather than xpm_fifo_axis or axis_data_fifo,
// so the unit tests run in xsim straight from these sources with no IP catalog.
//
// Almost-full is what drives TREADY, and it leaves ALMOST_FULL_SLACK entries free. One slot would
// be enough for a purely registered producer, but the TOE side is a long combinational path and the
// slack costs nothing at this depth.
// =================================================================================================
module axis_fifo #(
    parameter int DATA_BITS         = AXI_DATA_BITS,
    parameter int DEPTH             = 1024,          // entries; x 64 B = 64 KiB at the default
    parameter int ALMOST_FULL_SLACK = 4
) (
    input  logic                     clk,
    input  logic                     rst_n,
    // Drop everything held. Used when a connection is torn down: the residue belongs to a stream
    // that no longer exists.
    input  logic                     clear,

    input  logic                     s_axis_tvalid,
    output logic                     s_axis_tready,
    input  logic [DATA_BITS-1:0]     s_axis_tdata,
    input  logic [DATA_BITS/8-1:0]   s_axis_tkeep,
    input  logic                     s_axis_tlast,

    output logic                     m_axis_tvalid,
    input  logic                     m_axis_tready,
    output logic [DATA_BITS-1:0]     m_axis_tdata,
    output logic [DATA_BITS/8-1:0]   m_axis_tkeep,
    output logic                     m_axis_tlast,

    // Occupancy, for the stall watchdogs and for tests that assert the fifo never filled.
    output logic [$clog2(DEPTH+1)-1:0] level,
    // Sticky: the producer was ever refused. The receive dispatchers do not hold a beat for TREADY,
    // so in tcp_read a refused beat is lost and the stream is corrupt; it should never set.
    output logic                     overflow_stall
);

    localparam int KEEP_BITS = DATA_BITS/8;
    localparam int WORD_BITS = DATA_BITS + KEEP_BITS + 1;
    localparam int PTR_BITS  = $clog2(DEPTH);

    // Inferred as block RAM. No reset on the array: the pointers define what is valid.
    (* ram_style = "block" *) logic [WORD_BITS-1:0] mem [DEPTH];

    logic [PTR_BITS-1:0]        wr_ptr_q, rd_ptr_q;
    logic [$clog2(DEPTH+1)-1:0] level_q;
    logic                       overflow_stall_q;

    logic full_w, empty_w, almost_full_w;
    assign full_w        = (level_q == DEPTH[$clog2(DEPTH+1)-1:0]);
    assign empty_w       = (level_q == '0);
    assign almost_full_w = (level_q >= (DEPTH - ALMOST_FULL_SLACK));

    assign s_axis_tready = !almost_full_w;

    logic wr_fire, rd_fire;
    assign wr_fire = s_axis_tvalid && s_axis_tready;
    assign rd_fire = m_axis_tvalid && m_axis_tready;

    // First-word-fall-through: the head is presented combinationally from a registered read of the
    // memory. A one-entry output register keeps the BRAM read synchronous while still showing the
    // head without a bubble.
    logic [WORD_BITS-1:0] out_q;
    logic                 out_valid_q;

    logic out_load;
    assign out_load = !empty_w && (!out_valid_q || m_axis_tready);

    assign m_axis_tvalid = out_valid_q;
    assign {m_axis_tlast, m_axis_tkeep, m_axis_tdata} = out_q;

    always_ff @(posedge clk) begin
        if (wr_fire) mem[wr_ptr_q] <= {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
        if (out_load) out_q <= mem[rd_ptr_q];
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            wr_ptr_q         <= '0;
            rd_ptr_q         <= '0;
            level_q          <= '0;
            out_valid_q      <= 1'b0;
            // Deliberately NOT cleared on `clear`: it is a run-level diagnostic, and a connection
            // teardown must not erase the evidence that the fifo had already overflowed.
            overflow_stall_q <= (!rst_n) ? 1'b0 : overflow_stall_q;
        end else begin
            if (wr_fire) wr_ptr_q <= (wr_ptr_q == PTR_BITS'(DEPTH-1)) ? '0 : wr_ptr_q + 1'b1;
            if (out_load) rd_ptr_q <= (rd_ptr_q == PTR_BITS'(DEPTH-1)) ? '0 : rd_ptr_q + 1'b1;

            // level counts entries still in the memory; the output register is not one of them,
            // so it is decremented on the memory read, not on the downstream handshake.
            case ({wr_fire, out_load})
                2'b10:   level_q <= level_q + 1'b1;
                2'b01:   level_q <= level_q - 1'b1;
                default: ;
            endcase

            if (out_load)            out_valid_q <= 1'b1;
            else if (m_axis_tready)  out_valid_q <= 1'b0;

            if (s_axis_tvalid && !s_axis_tready) overflow_stall_q <= 1'b1;
        end
    end

    assign level          = level_q;
    assign overflow_stall = overflow_stall_q;

endmodule
