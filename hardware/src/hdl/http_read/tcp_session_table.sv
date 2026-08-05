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
// records, per slot, a QUEUE of the announced segment lengths plus a sticky `closed` flag.
//
// WHY A QUEUE AND NOT A RUNNING BYTE BALANCE
// ------------------------------------------
// The first version of this module kept `pending` as a single running total and let the reader ask
// for min(pending, 32 KB), on the assumption that a readPkg returns exactly the number of bytes it
// names. It does not. Coyote builds the TOE with TCP_STACK_RX_DDR_BYPASS_EN=1
// (Coyote/hw/services/network/hls/toe/CMakeLists.txt), and on that path the receive buffer is a
// shared on-chip packet FIFO rather than a per-session circular buffer in DDR:
//
//   rx_app_stream_if.cpp        #if RX_DDR_BYPASS -> rxBufferReadCmd.write(1);   // a bare token
//   toe.cpp  rxAppMemDataRead   reads ONE packet, forwarding words until currWord.last
//
// So a readPkg returns exactly ONE announced segment no matter what length it names, and the length
// field is used for one thing only:
//
//   rxApp2rxSar_upd_req.write(rxSarAppd(rxSar.sessionID, rxSar.appd + rasi_readLength));
//
// -- it advances the app read pointer the receive window is computed from. Coalescing therefore
// broke the receive path twice over. One readPkg for 32 KB drained a single ~4 KB segment while
// telling the TOE that 32 KB had been consumed, so the window ran ahead of reality; and the reader's
// own balance dropped by 32 KB while only 4 KB reached the decoder, so it went back to waiting for
// announcements that had already been counted. The unread segments piled up in the shared FIFO
// until rx_engine hit its `(rxbuffer_max_data_count - rxbuffer_data_count) > 375` guard and started
// dropping segments with ACK_NODELAY -- the duplicate-ACK storm and the ~100% starved decoder
// observed on build-90.
//
// One readPkg per notification, naming exactly that notification's length, is the contract. That is
// what the pre-pipelining tcp_read did by passing the notification's length straight through, and it
// is what this queue restores -- the only difference being that the announcements are now kept per
// slot instead of being consumed from a stream that serves every session at once.
module tcp_session_table #(
    parameter int NUM_SLOTS    = 4,
    // Announcements that may be outstanding for one slot before the reader gets to it. The TOE
    // announces one segment at a time (MSS = 4096 on this build) and the shared rx FIFO is far
    // smaller than 32 x MSS, so this cannot fill in practice; if it ever does, the notification is
    // dropped and `dbg_overflow` latches rather than the stream silently losing sync.
    parameter int NOTIFY_DEPTH = 32,
    // $clog2(1) is 0, which would make every slot-index port [-1:0] and fail elaboration. One slot
    // is a legitimate configuration -- it is what the single-session tcp_read bench uses and the
    // fallback if pipelining ever has to be switched off -- so clamp the width to 1.
    localparam int IDX_BITS    = (NUM_SLOTS > 1) ? $clog2(NUM_SLOTS) : 1,
    localparam int PTR_BITS    = $clog2(NOTIFY_DEPTH),
    localparam int CNT_BITS    = $clog2(NOTIFY_DEPTH + 1)
) (
    input  logic clk,
    input  logic rst_n,

    // Notification sink. TREADY is hardwired high -- see above.
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,

    // Slot binding, driven by the handler's connect / read stages.
    input  logic                        bind_en,
    input  logic [IDX_BITS-1:0]         bind_slot,
    input  logic [TCP_SESSION_BITS-1:0] bind_sid,
    input  logic                        release_en,
    input  logic [IDX_BITS-1:0]         release_slot,

    // Query port for the read stage.
    input  logic [IDX_BITS-1:0]    q_slot,
    output logic [31:0]            q_pending,   // bytes announced and not yet requested (debug)
    output logic [TCP_LEN_BITS-1:0] q_req_len,  // length of the OLDEST unread announcement, 0 if none
    output logic                   q_closed,
    output logic                   q_bound,

    // The read stage issued the readPkg for q_req_len; retire that announcement.
    input  logic                   take_en,

    // Debug: which slots hold an unread announcement, which have seen FIN, and which overflowed.
    output logic [NUM_SLOTS-1:0]   dbg_has_pending,
    output logic [NUM_SLOTS-1:0]   dbg_closed,
    output logic [NUM_SLOTS-1:0]   dbg_overflow
);

    // Packed appNotification layout (mirrors tcp_read.sv):
    //   sessionID[15:0], length[31:16], ipAddress[63:32], dstPort[79:64], closed[80], opened[81]
    localparam int CLOSED_BIT = TCP_SESSION_BITS + TCP_LEN_BITS + 32 + 16; // = 80

    // With one slot the index ports are a clamped single bit that the handler always drives to 0.
    // Force it here too so a stray 1 can never index past the arrays.
    logic [IDX_BITS-1:0] q_slot_s, bind_slot_s, release_slot_s;
    assign q_slot_s       = (NUM_SLOTS > 1) ? q_slot       : '0;
    assign bind_slot_s    = (NUM_SLOTS > 1) ? bind_slot    : '0;
    assign release_slot_s = (NUM_SLOTS > 1) ? release_slot : '0;

    logic                        bound_q   [NUM_SLOTS];
    logic [TCP_SESSION_BITS-1:0] sid_q     [NUM_SLOTS];
    logic                        closed_q  [NUM_SLOTS];
    logic                        ovf_q     [NUM_SLOTS];
    logic [31:0]                 pending_q [NUM_SLOTS]; // debug only: bytes still queued

    // The announcement queue itself: one circular buffer of segment lengths per slot. The head is
    // read combinationally (the reader needs q_req_len in the same cycle it decides to take), which
    // is the classic distributed-RAM access pattern.
    logic [TCP_LEN_BITS-1:0] len_mem [NUM_SLOTS][NOTIFY_DEPTH];
    logic [PTR_BITS-1:0]     wr_ptr_q [NUM_SLOTS];
    logic [PTR_BITS-1:0]     rd_ptr_q [NUM_SLOTS];
    logic [CNT_BITS-1:0]     cnt_q    [NUM_SLOTS];

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

    // A zero-length notification carries only the FIN and must not become a queue entry -- a readPkg
    // of length 0 would hang the data mover (rx_app_stream_if drops it, and we would then wait for
    // rx data that never comes).
    logic [NUM_SLOTS-1:0] push_en, pop_en, ovf_en;
    always_comb begin
        for (int i = 0; i < NUM_SLOTS; i++) begin
            automatic logic want_push = notify_hit[i] && (notify_len != 0);
            automatic logic full      = (cnt_q[i] == CNT_BITS'(NOTIFY_DEPTH));
            push_en[i] = want_push && !full;
            ovf_en[i]  = want_push && full;
            pop_en[i]  = take_en && (q_slot_s == IDX_BITS'(i)) && (cnt_q[i] != 0);
        end
    end

    assign q_pending = pending_q[q_slot_s];
    assign q_closed  = closed_q[q_slot_s];
    assign q_bound   = bound_q[q_slot_s];
    // Exactly one announcement, never a coalesced total. See the header comment.
    assign q_req_len = (cnt_q[q_slot_s] != 0) ? len_mem[q_slot_s][rd_ptr_q[q_slot_s]]
                                              : TCP_LEN_BITS'(0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SLOTS; i++) begin
                bound_q[i]   <= 1'b0;
                sid_q[i]     <= '0;
                closed_q[i]  <= 1'b0;
                ovf_q[i]     <= 1'b0;
                pending_q[i] <= '0;
                wr_ptr_q[i]  <= '0;
                rd_ptr_q[i]  <= '0;
                cnt_q[i]     <= '0;
            end
        end else begin
            for (int i = 0; i < NUM_SLOTS; i++) begin
                // A single notification can carry the last data AND the FIN, so `closed` is sticky
                // and is only acted on once the queue has drained.
                closed_q[i] <= closed_q[i] | (notify_hit[i] & notify_closed);
                ovf_q[i]    <= ovf_q[i]    | ovf_en[i];

                if (push_en[i]) begin
                    len_mem[i][wr_ptr_q[i]] <= notify_len;
                    wr_ptr_q[i]             <= wr_ptr_q[i] + 1'b1;
                end
                if (pop_en[i]) begin
                    rd_ptr_q[i] <= rd_ptr_q[i] + 1'b1;
                end

                // A push and a pop can land in the same cycle; the count only moves on a net change.
                case ({push_en[i], pop_en[i]})
                    2'b10:   cnt_q[i] <= cnt_q[i] + 1'b1;
                    2'b01:   cnt_q[i] <= cnt_q[i] - 1'b1;
                    default: cnt_q[i] <= cnt_q[i];
                endcase

                pending_q[i] <= pending_q[i]
                              + (push_en[i] ? {16'b0, notify_len} : 32'd0)
                              - (pop_en[i]  ? {16'b0, len_mem[i][rd_ptr_q[i]]} : 32'd0);

                // Bind wins over everything: it starts a fresh connection's accounting from zero. It
                // cannot collide with a notification for the same slot, because the session id only
                // becomes known when tcp_init completes and the GET is sent strictly after that --
                // there is nothing for the server to answer yet.
                if (bind_en && (bind_slot_s == IDX_BITS'(i))) begin
                    bound_q[i]   <= 1'b1;
                    sid_q[i]     <= bind_sid;
                    closed_q[i]  <= 1'b0;
                    ovf_q[i]     <= 1'b0;
                    pending_q[i] <= '0;
                    wr_ptr_q[i]  <= '0;
                    rd_ptr_q[i]  <= '0;
                    cnt_q[i]     <= '0;
                end else if (release_en && (release_slot_s == IDX_BITS'(i))) begin
                    bound_q[i]   <= 1'b0;
                    closed_q[i]  <= 1'b0;
                    ovf_q[i]     <= 1'b0;
                    pending_q[i] <= '0;
                    wr_ptr_q[i]  <= '0;
                    rd_ptr_q[i]  <= '0;
                    cnt_q[i]     <= '0;
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < NUM_SLOTS; i++) begin
            dbg_has_pending[i] = (cnt_q[i] != 0);
            dbg_closed[i]      = closed_q[i];
            dbg_overflow[i]    = ovf_q[i];
        end
    end

endmodule
