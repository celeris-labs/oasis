import lynxTypes::*;

module tcp_init (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,
    input  logic [31:0]                               serverIpAddress,
    input  logic [31:0]                               serverPort,
    output logic                                      m_axis_open_connection_TVALID,
    input  logic                                      m_axis_open_connection_TREADY,
    output logic [TCP_OPEN_CONN_REQ_BITS-1:0]         m_axis_open_connection_TDATA,
    input  logic                                      s_axis_open_status_TVALID,
    output logic                                      s_axis_open_status_TREADY,
    input  logic [TCP_OPEN_CONN_RSP_BITS-1:0]         s_axis_open_status_TDATA,
    output logic                                      done,
    output logic                                      error,
    output logic [15:0]                               session_id,
    output logic [3:0]                                state_debug
);

    localparam logic [1:0] ST_IDLE = 2'd0;
    localparam logic [1:0] ST_SEND = 2'd1;
    localparam logic [1:0] ST_WAIT = 2'd2;
    localparam logic [1:0] ST_DONE = 2'd3;

    logic [1:0] state_q, state_d;
    logic [15:0] session_id_q, session_id_d;
    logic error_q, error_d;

    always_comb begin
        state_d = state_q;
        session_id_d = session_id_q;
        error_d = error_q;

        m_axis_open_connection_TVALID = 1'b0;
        m_axis_open_connection_TDATA = {serverPort[15:0], serverIpAddress};
        s_axis_open_status_TREADY = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    error_d = 1'b0;
                    state_d = ST_SEND;
                end
            end

            ST_SEND: begin
                m_axis_open_connection_TVALID = 1'b1;
                if (m_axis_open_connection_TVALID && m_axis_open_connection_TREADY) begin
                    state_d = ST_WAIT;
                end
            end

            ST_WAIT: begin
                s_axis_open_status_TREADY = 1'b1;
                if (s_axis_open_status_TVALID && s_axis_open_status_TREADY) begin
                    session_id_d = s_axis_open_status_TDATA[15:0];
                    error_d = (s_axis_open_status_TDATA[23:16] != 8'd0);
                    state_d = ST_DONE;
                end
            end

            ST_DONE: begin
                if (!start) begin
                    state_d = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            session_id_q <= 16'd0;
            error_q <= 1'b0;
        end else begin
            state_q <= state_d;
            session_id_q <= session_id_d;
            error_q <= error_d;
        end
    end

    assign done = (state_q == ST_DONE);
    assign session_id = session_id_q;
    assign error = error_q;
    assign state_debug = (state_q == ST_SEND) ? 4'd1 :
                         (state_q == ST_WAIT || state_q == ST_DONE) ? 4'd2 :
                         4'd0;

endmodule
