// Top-level TCP Offload Engine (TOE) integrating TCP State Machine and Outbound Packet Compiler.

`timescale 1ns / 1ps
`default_nettype none

module toe_top #(
    parameter logic [47:0] SRC_MAC = 48'h000a3502410b,
    parameter logic [47:0] DST_MAC = 48'h000a3502410a,
    parameter logic [31:0] SRC_IP  = 32'hc0a80164,
    parameter logic [31:0] DST_IP  = 32'hc0a801c8,
    parameter logic [15:0] SRC_PORT = 16'h3039,
    parameter logic [15:0] DST_PORT = 16'h3cc3
) (
    input  logic        clk,
    input  logic        rst_n,

    // Command Triggers
    input  logic        conn_trigger,
    input  logic        disconnect_trigger,

    // Strategy Trade Trigger input
    input  logic        send_order,
    input  logic [63:0] order_stock,
    input  logic [31:0] order_shares,
    input  logic [31:0] order_price,

    // Session Status Output
    output logic        session_established,
    output logic [3:0]  tcp_state,

    // Inbound TCP packet decoding signals
    input  logic        rx_valid,
    input  logic        rx_syn,
    input  logic        rx_ack,
    input  logic        rx_fin,
    input  logic [31:0] rx_seq_num,
    input  logic [31:0] rx_ack_num,

    // Outbound AXI-Stream interface
    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready
);

    logic [31:0] tx_seq_num;
    logic [31:0] tx_ack_num;

    logic        tx_syn_sig;
    logic        tx_ack_sig;
    logic        tx_fin_sig;

    tcp_state_m u_state_m (
        .clk                 (clk),
        .rst_n               (rst_n),
        
        .conn_trigger        (conn_trigger),
        .disconnect_trigger  (disconnect_trigger),
        
        .rx_valid            (rx_valid),
        .rx_syn              (rx_syn),
        .rx_ack              (rx_ack),
        .rx_fin              (rx_fin),
        .rx_seq_num          (rx_seq_num),
        .rx_ack_num          (rx_ack_num),
        
        .session_established (session_established),
        .current_state       (tcp_state),
        .tx_seq_num          (tx_seq_num),
        .tx_ack_num          (tx_ack_num),
        
        .tx_syn              (tx_syn_sig),
        .tx_ack              (tx_ack_sig),
        .tx_fin              (tx_fin_sig)
    );

    tcp_tx_packet #(
        .SRC_MAC  (SRC_MAC),
        .DST_MAC  (DST_MAC),
        .SRC_IP   (SRC_IP),
        .DST_IP   (DST_IP),
        .SRC_PORT (SRC_PORT),
        .DST_PORT (DST_PORT)
    ) u_tx_packet (
        .clk          (clk),
        .rst_n        (rst_n),
        
        .tx_seq_num   (tx_seq_num),
        .tx_ack_num   (tx_ack_num),
        
        .send_syn     (tx_syn_sig),
        .send_ack     (tx_ack_sig),
        .send_fin     (tx_fin_sig),
        .send_order   (send_order && session_established), // Only send if session is established
        
        .order_stock  (order_stock),
        .order_shares (order_shares),
        .order_price  (order_price),
        
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tkeep (m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

endmodule

`default_nettype wire
