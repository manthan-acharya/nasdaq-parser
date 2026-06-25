// TCP State Machine (RFC 793) implementing handshakes and sequence/ACK tracking.

`timescale 1ns / 1ps
`default_nettype none

module tcp_state_m (
    input  logic        clk,
    input  logic        rst_n,

    // Session Control Signals
    input  logic        conn_trigger,
    input  logic        disconnect_trigger,

    // Signals from RX Packet Parser
    input  logic        rx_valid,
    input  logic        rx_syn,
    input  logic        rx_ack,
    input  logic        rx_fin,
    input  logic [31:0] rx_seq_num,
    input  logic [31:0] rx_ack_num,

    // Session Tracking Outputs
    output logic        session_established,
    output logic [3:0]  current_state,
    output logic [31:0] tx_seq_num,
    output logic [31:0] tx_ack_num,

    // Outbound Flags to TX Packet Compiler
    output logic        tx_syn,
    output logic        tx_ack,
    output logic        tx_fin
);

    typedef enum logic [3:0] {
        CLOSED      = 4'd0,
        SYN_SENT    = 4'd1,
        SYN_RCVD    = 4'd2,
        ESTABLISHED = 4'd3,
        FIN_WAIT_1  = 4'd4,
        FIN_WAIT_2  = 4'd5,
        CLOSE_WAIT  = 4'd6,
        CLOSING     = 4'd7,
        LAST_ACK    = 4'd8,
        TIME_WAIT   = 4'd9
    } tcp_state_t;

    tcp_state_t state, next_state;

    logic [31:0] r_seq_num;
    logic [31:0] r_ack_num;

    logic r_tx_syn;
    logic r_tx_ack;
    logic r_tx_fin;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= CLOSED;
        end else begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        r_tx_syn   = 1'b0;
        r_tx_ack   = 1'b0;
        r_tx_fin   = 1'b0;

        case (state)
            CLOSED: begin
                if (conn_trigger) begin
                    next_state = SYN_SENT;
                    r_tx_syn   = 1'b1;
                end
            end

            SYN_SENT: begin
                if (rx_valid && rx_syn && rx_ack) begin
                    // SYN-ACK received
                    next_state = ESTABLISHED;
                    r_tx_ack   = 1'b1;
                end else if (rx_valid && rx_syn && !rx_ack) begin
                    // Simultaneous Open
                    next_state = SYN_RCVD;
                    r_tx_syn   = 1'b1;
                    r_tx_ack   = 1'b1;
                end
            end

            SYN_RCVD: begin
                if (rx_valid && rx_ack) begin
                    next_state = ESTABLISHED;
                end
            end

            ESTABLISHED: begin
                if (disconnect_trigger) begin
                    next_state = FIN_WAIT_1;
                    r_tx_fin   = 1'b1;
                end else if (rx_valid && rx_fin) begin
                    // Passive Close
                    next_state = CLOSE_WAIT;
                    r_tx_ack   = 1'b1;
                end
            end

            FIN_WAIT_1: begin
                if (rx_valid && rx_ack && !rx_fin) begin
                    next_state = FIN_WAIT_2;
                end else if (rx_valid && rx_fin && rx_ack) begin
                    // Simultaneous Close + ACK
                    next_state = TIME_WAIT;
                    r_tx_ack   = 1'b1;
                end else if (rx_valid && rx_fin && !rx_ack) begin
                    next_state = CLOSING;
                    r_tx_ack   = 1'b1;
                end
            end

            FIN_WAIT_2: begin
                if (rx_valid && rx_fin) begin
                    next_state = TIME_WAIT;
                    r_tx_ack   = 1'b1;
                end
            end

            CLOSE_WAIT: begin
                if (disconnect_trigger) begin
                    next_state = LAST_ACK;
                    r_tx_fin   = 1'b1;
                end
            end

            CLOSING: begin
                if (rx_valid && rx_ack) begin
                    next_state = TIME_WAIT;
                end
            end

            LAST_ACK: begin
                if (rx_valid && rx_ack) begin
                    next_state = CLOSED;
                end
            end

            TIME_WAIT: begin
                // Fast-expire to CLOSED for low-latency hardware reuse
                next_state = CLOSED;
            end

            default: next_state = CLOSED;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_seq_num <= 32'h0;
            r_ack_num <= 32'h0;
        end else begin
            if (state == CLOSED && conn_trigger) begin
                r_seq_num <= 32'h10000000;
                r_ack_num <= 32'h0;
            end else if (rx_valid) begin
                case (state)
                    SYN_SENT: begin
                        if (rx_syn) begin
                            r_ack_num <= rx_seq_num + 32'h1;
                            if (rx_ack) begin
                                r_seq_num <= rx_ack_num;
                            end
                        end
                    end

                    ESTABLISHED: begin
                        if (rx_ack) begin
                            r_seq_num <= rx_ack_num;
                        end
                        if (rx_fin) begin
                            r_ack_num <= rx_seq_num + 32'h1;
                        end
                    end

                    FIN_WAIT_1: begin
                        if (rx_ack) begin
                            r_seq_num <= rx_ack_num;
                        end
                        if (rx_fin) begin
                            r_ack_num <= rx_seq_num + 32'h1;
                        end
                    end

                    FIN_WAIT_2: begin
                        if (rx_fin) begin
                            r_ack_num <= rx_seq_num + 32'h1;
                        end
                    end

                    default: ;
                endcase
            end
        end
    end

    assign session_established = (state == ESTABLISHED);
    assign current_state       = state;
    assign tx_seq_num          = r_seq_num;
    assign tx_ack_num          = r_ack_num;
    assign tx_syn              = r_tx_syn;
    assign tx_ack              = r_tx_ack;
    assign tx_fin              = r_tx_fin;

endmodule

`default_nettype wire
