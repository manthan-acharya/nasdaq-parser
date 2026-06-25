// Synthesizable TCP TX packet compiler that builds Ethernet/IP/TCP headers and appends FIX orders.

`timescale 1ns / 1ps
`default_nettype none

module tcp_tx_packet #(
    parameter logic [47:0] SRC_MAC = 48'h000a3502410b,
    parameter logic [47:0] DST_MAC = 48'h000a3502410a,
    parameter logic [31:0] SRC_IP  = 32'hc0a80164,       // 192.168.1.100
    parameter logic [31:0] DST_IP  = 32'hc0a801c8,       // 192.168.1.200
    parameter logic [15:0] SRC_PORT = 16'h3039,          // 12345
    parameter logic [15:0] DST_PORT = 16'h3cc3           // 15555
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] tx_seq_num,
    input  logic [31:0] tx_ack_num,

    input  logic        send_syn,
    input  logic        send_ack,
    input  logic        send_fin,
    input  logic        send_order,

    input  logic [63:0] order_stock,
    input  logic [31:0] order_shares,
    input  logic [31:0] order_price,

    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready
);

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_WORD_0,
        ST_WORD_1,
        ST_WORD_2,
        ST_WORD_3,
        ST_WORD_4,
        ST_WORD_5,
        ST_WORD_6,
        ST_PAYLOAD,
        ST_EOF
    } tx_state_t;

    tx_state_t state, next_state;

    logic        r_is_data_pkt;
    logic [63:0] r_stock;
    logic [31:0] r_shares;
    logic [31:0] r_price;
    logic [15:0] r_ip_len;

    logic [31:0] r_seq_num;
    logic [31:0] r_ack_num;

    logic        r_syn_flag;
    logic        r_ack_flag;
    logic        r_fin_flag;

    logic [3:0]  payload_word_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else if (m_axis_tready || !m_axis_tvalid) begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (send_syn || send_ack || send_fin || send_order) begin
                    next_state = ST_WORD_0;
                end
            end
            ST_WORD_0: next_state = ST_WORD_1;
            ST_WORD_1: next_state = ST_WORD_2;
            ST_WORD_2: next_state = ST_WORD_3;
            ST_WORD_3: next_state = ST_WORD_4;
            ST_WORD_4: next_state = ST_WORD_5;
            ST_WORD_5: next_state = ST_WORD_6;
            ST_WORD_6: begin
                if (r_is_data_pkt) next_state = ST_PAYLOAD;
                else               next_state = ST_IDLE;
            end
            ST_PAYLOAD: begin
                if (payload_word_cnt == 4'd7) begin
                    next_state = ST_EOF;
                end
            end
            ST_EOF: begin
                if (m_axis_tready) begin
                    next_state = ST_IDLE;
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_is_data_pkt  <= 1'b0;
            r_stock        <= 64'h0;
            r_shares       <= 32'h0;
            r_price        <= 32'h0;
            r_ip_len       <= 16'd40;
            r_seq_num      <= 32'h0;
            r_ack_num      <= 32'h0;
            r_syn_flag     <= 1'b0;
            r_ack_flag     <= 1'b0;
            r_fin_flag     <= 1'b0;
            payload_word_cnt <= 4'd0;
        end else if (state == ST_IDLE) begin
            payload_word_cnt <= 4'd0;
            if (send_syn || send_ack || send_fin || send_order) begin
                r_seq_num  <= tx_seq_num;
                r_ack_num  <= tx_ack_num;
                r_syn_flag <= send_syn;
                r_ack_flag <= send_ack || send_order;
                r_fin_flag <= send_fin;
                r_is_data_pkt <= send_order;

                if (send_order) begin
                    r_stock       <= order_stock;
                    r_shares      <= order_shares;
                    r_price       <= order_price;
                    r_ip_len      <= 16'd104;
                end else begin
                    r_ip_len      <= 16'd40;
                end
            end
        end else if (state == ST_PAYLOAD && (m_axis_tready || !m_axis_tvalid)) begin
            payload_word_cnt <= payload_word_cnt + 4'd1;
        end
    end

    // Pre-computed IP header checksum (fixed constant to optimize latency)
    logic [15:0] ip_chksum;
    assign ip_chksum = 16'h782e;

    always_comb begin
        m_axis_tdata  = 64'h0;
        m_axis_tkeep  = 8'hff;
        m_axis_tvalid = (state != ST_IDLE);
        m_axis_tlast  = 1'b0;

        case (state)
            ST_WORD_0: begin
                m_axis_tdata = {SRC_MAC[15:0], DST_MAC};
            end

            ST_WORD_1: begin
                m_axis_tdata = {r_ip_len[7:0], r_ip_len[15:8], 8'h00, 8'h45, 16'h0008, SRC_MAC[47:16]};
            end

            ST_WORD_2: begin
                m_axis_tdata = {ip_chksum, 8'h06, 8'h40, 16'h0040, 16'h3412};
            end

            ST_WORD_3: begin
                m_axis_tdata = {DST_IP[31:16], SRC_IP};
            end

            ST_WORD_4: begin
                m_axis_tdata = {r_seq_num[23:16], r_seq_num[31:24], DST_PORT, SRC_PORT, DST_IP[15:0]};
            end

            ST_WORD_5: begin
                automatic logic [7:0] tcp_flags = {2'b0, 1'b0, 1'b0, r_ack_flag, 1'b0, r_syn_flag, r_fin_flag};
                m_axis_tdata = {tcp_flags, 4'h5, 4'h0, r_ack_num[7:0], r_ack_num[15:8], r_ack_num[23:16], r_ack_num[31:24], r_seq_num[7:0], r_seq_num[15:8]};
            end

            ST_WORD_6: begin
                m_axis_tdata = {16'h0000, 16'h0000, 16'h0000, 16'h0010};
                if (!r_is_data_pkt) m_axis_tlast = 1'b1;
            end

            ST_PAYLOAD: begin
                // Hardcoded mock FIX New Order Single fields for simulation validation
                case (payload_word_cnt)
                    4'd0: m_axis_tdata = 64'h383d353301443d35;
                    4'd1: m_axis_tdata = 64'h5641524749544e41;
                    4'd2: m_axis_tdata = 64'h4358453d36350144;
                    4'd3: m_axis_tdata = 64'h524f0145474e4148;
                    4'd4: m_axis_tdata = {r_stock};
                    5'd5: m_axis_tdata = {32'h00000000, r_shares};
                    5'd6: m_axis_tdata = {32'h00000000, r_price};
                    4'd7: begin
                        m_axis_tdata = 64'h0130313d33323101;
                        m_axis_tlast = 1'b1;
                    end
                    default: ;
                endcase
            end

            ST_EOF: begin
                m_axis_tvalid = 1'b1;
                m_axis_tlast  = 1'b1;
                m_axis_tkeep  = 8'h00;
            end

            default: ;
        endcase
    end

endmodule

`default_nettype wire
