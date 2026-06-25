// Top-level NASDAQ feed handler that integrates the UDP Parser and the NASDAQ ITCH-5.0 Parser.

`timescale 1ns / 1ps
`default_nettype none

module nasdaq_pipeline #(
    parameter bit MOLDUDP64_SUPPORT = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // Raw AXI-Stream Input (from 10G MAC)
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tuser,
    output logic        s_axis_tready,

    // Parsed Network Metadata
    output logic [31:0] meta_src_ip,
    output logic [31:0] meta_dst_ip,
    output logic [15:0] meta_src_port,
    output logic [15:0] meta_dst_port,
    output logic [15:0] meta_udp_length,
    output logic        packet_valid,

    // Decoded ITCH-5.0 Messages
    output logic                         add_order_valid,
    output itch_types::add_order_msg_t   add_order_data,

    output logic                         exec_order_valid,
    output itch_types::exec_order_msg_t  exec_order_data,

    output logic                         cancel_order_valid,
    output itch_types::cancel_order_msg_t cancel_order_data,

    output logic                         delete_order_valid,
    output itch_types::delete_order_msg_t delete_order_data,

    output logic                         replace_order_valid,
    output itch_types::replace_order_msg_t replace_order_data
);

    logic [63:0] udp_payload_tdata;
    logic [7:0]  udp_payload_tkeep;
    logic        udp_payload_tvalid;
    logic        udp_payload_tlast;
    logic        udp_payload_tready;

    udp_parser u_udp_parser (
        .clk             (clk),
        .rst_n           (rst_n),

        // Inputs
        .s_axis_tdata    (s_axis_tdata),
        .s_axis_tkeep    (s_axis_tkeep),
        .s_axis_tvalid   (s_axis_tvalid),
        .s_axis_tlast    (s_axis_tlast),
        .s_axis_tuser    (s_axis_tuser),
        .s_axis_tready   (s_axis_tready),

        // Outputs (Realigned Payload AXIS)
        .m_axis_tdata    (udp_payload_tdata),
        .m_axis_tkeep    (udp_payload_tkeep),
        .m_axis_tvalid   (udp_payload_tvalid),
        .m_axis_tlast    (udp_payload_tlast),
        .m_axis_tready   (udp_payload_tready),

        // Metadata
        .meta_src_ip     (meta_src_ip),
        .meta_dst_ip     (meta_dst_ip),
        .meta_src_port   (meta_src_port),
        .meta_dst_port   (meta_dst_port),
        .meta_udp_length (meta_udp_length),
        .packet_valid    (packet_valid)
    );

    itch_parser #(
        .MOLDUDP64_SUPPORT (MOLDUDP64_SUPPORT)
    ) u_itch_parser (
        .clk                (clk),
        .rst_n              (rst_n),

        // Inputs (from UDP Parser output)
        .s_axis_tdata       (udp_payload_tdata),
        .s_axis_tkeep       (udp_payload_tkeep),
        .s_axis_tvalid      (udp_payload_tvalid),
        .s_axis_tlast       (udp_payload_tlast),
        .s_axis_tready      (udp_payload_tready),

        // Decoded Struct Outputs
        .add_order_valid    (add_order_valid),
        .add_order_data     (add_order_data),

        .exec_order_valid   (exec_order_valid),
        .exec_order_data    (exec_order_data),

        .cancel_order_valid (cancel_order_valid),
        .cancel_order_data  (cancel_order_data),

        .delete_order_valid (delete_order_valid),
        .delete_order_data  (delete_order_data),

        .replace_order_valid(replace_order_valid),
        .replace_order_data (replace_order_data)
    );

endmodule

`default_nettype wire

