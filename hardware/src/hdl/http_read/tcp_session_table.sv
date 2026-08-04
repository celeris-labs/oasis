`timescale 1ns / 1ps

import lynxTypes::*;

// Per-session accounting for the TOE's appNotification stream.
//
// WHY THIS EXISTS
// ---------------
// The old single-session design let tcp_read pop notifications itself and DISCARD every one whose
// session did not match the connection it was reading:
//
//     if (s_axis_notifications_TDATA[TCP_SESSION_BITS-1:0] == session_id) begin ... end
//     // else: consumed and thrown away
//
// That is correct when exactly one connection is ever open, and fatal the moment a second one is.
// The notification saying "session B has 8 KB waiting" arrives while we are still reading session A,
// gets dropped on the floor, and when the reader finally turns to B it waits forever for an
// announcement that already came and went. Since the whole point of pipelining is to have B's
// response already in flight while A drains, nothing works until notifications are recorded rather
// than filtered.
//
// So this module owns the notification stream. It is ALWAYS ready -- backpressuring the TOE's
// notification interface would stall every session at once, including the one being read -- and it
// accumulates, per slot:
//   pending: bytes announced but not yet requested via readPkg
//   closed:  the peer has sent FIN (sticky)
//
// The handler binds a slot to a session id when the connection opens (always before the GET goes
// out, so no notification for that session can predate the binding) and releases it after the
// response has been fully read. Notifications for unbound sessions are dropped, which is the right
// behaviour for stragglers from a connection we already finished with.
//
// A BONUS PROPERTY: because `pending` is a running balance rather than a single notification's
// length, the reader may ask for FEWER bytes than were announced. The remainder simply stays on the
// balance and is picked up by the next readPkg. The old code could not do that -- it passed the
// notification's length straight through, so a short read would have stranded the rest with no
// second announcement to recover it.
module tcp_session_table #(
    parameter int NUM_SLOTS      = 4,
    // Cap on a single readPkg. The request's length field is TCP_LEN_BITS (16) wide, so this must
    // stay below 64 Ki; it is also kept well under a typical per-session rx buffer so a request can
    // never name more bytes than the TOE is actually holding.
    parameter int MAX_READ_BYTES = 32768,
    // $clog2(1) is 0, which would make every slot-index port [-1:0] and fail elaboration. One slot
    // is a legitimate configuration -- it is what the single-session tcp_read bench uses and the
    // fallback if pipelining ever has to be switched off -- so clamp the width to 1.
    localparam int IDX_BITS      = (NUM_SLOTS > 1) ? $clog2(NUM_SLOTS) : 1
) (
    input  logic clk,
    input  logic rst_n,

    // Notification sink. TREADY is hardwired high -- see above.
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,

    // Slot binding, driven by the handler's connect / read stages.
    input  logic                         bind_en,
    input  logic [IDX_BITS-1:0] bind_slot,
    input  logic [TCP_SESSION_BITS-1:0]  bind_sid,
    input  logic                         release_en,
    input  logic [IDX_BITS-1:0] release_slot,

    // Query port for the read stage.
    input  logic [IDX_BITS-1:0] q_slot,
    output logic [31:0]                  q_pending,   // full balance, for debug/decisions
    output logic [TCP_LEN_BITS-1:0]      q_req_len,   // min(pending, MAX_READ_BYTES)
    output logic                         q_closed,
    output logic                         q_bound,

    // The read stage issued a readPkg of q_req_len bytes against q_slot.
    input  logic                         take_en,
    input  logic [TCP_LEN_BITS-1:0]      take_len,

    // Debug: which slots hold an unread balance, and which have seen FIN.
    output logic [NUM_SLOTS-1:0]         dbg_has_pending,
    output logic [NUM_SLOTS-1:0]         dbg_closed
);

    // Packed appNotification layout (mirrors tcp_read.sv):
    //   sessionID[15:0], length[31:16], ipAddress[63:32], dstPort[79:64], closed[80], opened[81]
    localparam int CLOSED_BIT = TCP_SESSION_BITS + TCP_LEN_BITS + 32 + 16; // = 80

    logic                        bound_q   [NUM_SLOTS];
    logic [TCP_SESSION_BITS-1:0] sid_q     [NUM_SLOTS];
    logic [31:0]                 pending_q [NUM_SLOTS];
    logic                        closed_q  [NUM_SLOTS];

    // Never stall the TOE.
    assign s_axis_notifications_TREADY = 1'b1;

    logic                        notify_fire;
    logic [TCP_SESSION_BITS-1:0] notify_sid;
    logic [TCP_LEN_BITS-1:0]     notify_len;
    logic                        notify_closed;

    assign notify_fire   = s_axis_notifications_TVALID && s_axis_notifications_TREADY;
    assign notify_sid    = s_axis_notifications_TDATA[TCP_SESSION_BITS-1:0];
    assign notify_len    = s_axis_notifications_TDATA[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS];
    assign notify_closed = s_axis_notifications_TDATA[CLOSED_BIT];

    // Which slot (if any) this notification belongs to. Slots hold distinct session ids by
    // construction -- the handler binds one slot per open connection -- so at most one matches.
    logic [NUM_SLOTS-1:0] notify_hit;
    always_comb begin
        for (int i = 0; i < NUM_SLOTS; i++) begin
            notify_hit[i] = notify_fire && bound_q[i] && (sid_q[i] == notify_sid);
        end
    end

    // Next-state, computed per slot. Split out of the always_ff so the add/subtract collision is
    // resolved in one place and the sequential block stays a plain register update.
    logic                        bound_d   [NUM_SLOTS];
    logic [TCP_SESSION_BITS-1:0] sid_d     [NUM_SLOTS];
    logic [31:0]                 pending_d [NUM_SLOTS];
    logic                        closed_d  [NUM_SLOTS];

    logic [31:0] add_w [NUM_SLOTS];
    logic [31:0] sub_w [NUM_SLOTS];

    always_comb begin
        for (int i = 0; i < NUM_SLOTS; i++) begin
            // A notification can add bytes in the same cycle the reader takes some, so both are
            // folded into one balance update rather than letting either clobber the other.
            add_w[i] = notify_hit[i] ? {16'b0, notify_len} : 32'd0;
            sub_w[i] = (take_en && (q_slot == i[IDX_BITS-1:0])) ? {16'b0, take_len} : 32'd0;

            bound_d[i]   = bound_q[i];
            sid_d[i]     = sid_q[i];
            pending_d[i] = pending_q[i] + add_w[i] - sub_w[i];
            // A single notification can carry the last data AND the FIN, so `closed` is sticky and
            // is only acted on once the balance reaches zero.
            closed_d[i]  = closed_q[i] | (notify_hit[i] & notify_closed);

            // Bind wins over everything: it starts a fresh connection's accounting from zero. It
            // cannot collide with a notification for the same slot, because the session id only
            // becomes known when tcp_init completes and the GET is sent strictly after that --
            // there is nothing for the server to answer yet.
            if (bind_en && (bind_slot == i[IDX_BITS-1:0])) begin
                bound_d[i]   = 1'b1;
                sid_d[i]     = bind_sid;
                pending_d[i] = '0;
                closed_d[i]  = 1'b0;
            end else if (release_en && (release_slot == i[IDX_BITS-1:0])) begin
                bound_d[i]   = 1'b0;
                pending_d[i] = '0;
                closed_d[i]  = 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SLOTS; i++) begin
                bound_q[i]   <= 1'b0;
                sid_q[i]     <= '0;
                pending_q[i] <= '0;
                closed_q[i]  <= 1'b0;
            end
        end else begin
            for (int i = 0; i < NUM_SLOTS; i++) begin
                bound_q[i]   <= bound_d[i];
                sid_q[i]     <= sid_d[i];
                pending_q[i] <= pending_d[i];
                closed_q[i]  <= closed_d[i];
            end
        end
    end

    assign q_pending = pending_q[q_slot];
    assign q_closed  = closed_q[q_slot];
    assign q_bound   = bound_q[q_slot];
    assign q_req_len = (pending_q[q_slot] > MAX_READ_BYTES) ? TCP_LEN_BITS'(MAX_READ_BYTES)
                                                            : pending_q[q_slot][TCP_LEN_BITS-1:0];

    always_comb begin
        for (int i = 0; i < NUM_SLOTS; i++) begin
            dbg_has_pending[i] = (pending_q[i] != 0);
            dbg_closed[i]      = closed_q[i];
        end
    end

endmodule
