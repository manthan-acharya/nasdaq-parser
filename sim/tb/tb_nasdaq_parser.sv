// Simulation top-level for Verilator testbench flattening the NASDAQ ITCH parser ports.

`timescale 1ns / 1ps
`default_nettype none

module tb_nasdaq_parser (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tuser,
    output logic        s_axis_tready,

    output logic [31:0] meta_src_ip,
    output logic [31:0] meta_dst_ip,
    output logic [15:0] meta_src_port,
    output logic [15:0] meta_dst_port,
    output logic [15:0] meta_udp_length,
    output logic        packet_valid,

    output logic        add_order_valid,
    output logic [63:0] add_order_id,
    output logic [7:0]  add_buy_sell,
    output logic [31:0] add_shares,
    output logic [63:0] add_stock,
    output logic [31:0] add_price,

    output logic        exec_order_valid,
    output logic [63:0] exec_order_id,
    output logic [31:0] exec_shares,

    output logic        cancel_order_valid,
    output logic [63:0] cancel_order_id,
    output logic [31:0] cancel_shares,

    output logic        delete_order_valid,
    output logic [63:0] delete_order_id,

    output logic        replace_order_valid,
    output logic [63:0] replace_original_order_id,
    output logic [63:0] replace_new_order_id,
    output logic [31:0] replace_shares,
    output logic [31:0] replace_price
);

    itch_types::add_order_msg_t    add_order_data;
    itch_types::exec_order_msg_t   exec_order_data;
    itch_types::cancel_order_msg_t cancel_order_data;
    itch_types::delete_order_msg_t delete_order_data;
    itch_types::replace_order_msg_t replace_order_data;

    assign add_order_id    = add_order_data.order_ref_id;
    assign add_buy_sell    = add_order_data.buy_sell_indicator;
    assign add_shares      = add_order_data.shares;
    assign add_stock       = add_order_data.stock;
    assign add_price       = add_order_data.price;

    assign exec_order_id   = exec_order_data.order_ref_id;
    assign exec_shares     = exec_order_data.shares;

    assign cancel_order_id = cancel_order_data.order_ref_id;
    assign cancel_shares   = cancel_order_data.shares;

    assign delete_order_id = delete_order_data.order_ref_id;

    assign replace_original_order_id = replace_order_data.original_order_ref_id;
    assign replace_new_order_id      = replace_order_data.new_order_ref_id;
    assign replace_shares            = replace_order_data.shares;
    assign replace_price             = replace_order_data.price;

    nasdaq_pipeline #(
        .MOLDUDP64_SUPPORT (1'b1)
    ) u_pipeline (
        .clk                (clk),
        .rst_n              (rst_n),

        .s_axis_tdata       (s_axis_tdata),
        .s_axis_tkeep       (s_axis_tkeep),
        .s_axis_tvalid      (s_axis_tvalid),
        .s_axis_tlast       (s_axis_tlast),
        .s_axis_tuser       (s_axis_tuser),
        .s_axis_tready      (s_axis_tready),

        .meta_src_ip        (meta_src_ip),
        .meta_dst_ip        (meta_dst_ip),
        .meta_src_port      (meta_src_port),
        .meta_dst_port      (meta_dst_port),
        .meta_udp_length    (meta_udp_length),
        .packet_valid       (packet_valid),

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

    always @(posedge clk) begin
        if (u_pipeline.udp_payload_tvalid || u_pipeline.u_itch_parser.buf_bytes > 0) begin
            $display("[DEBUG] Cycle %0d: AXIS_VAL=%b, DATA=%h, KEEP=%h, LAST=%b | BUF_BYTES=%0d, STATE=%s, MSG_LEN=%0d | MSG_TYPE=%h ('%c')",
                     u_pipeline.u_itch_parser.packet_byte_cnt,
                     u_pipeline.udp_payload_tvalid,
                     u_pipeline.udp_payload_tdata,
                     u_pipeline.udp_payload_tkeep,
                     u_pipeline.udp_payload_tlast,
                     u_pipeline.u_itch_parser.buf_bytes,
                     u_pipeline.u_itch_parser.parser_state.name(),
                     u_pipeline.u_itch_parser.r_msg_length,
                     u_pipeline.u_itch_parser.byte_buf[2],
                     u_pipeline.u_itch_parser.byte_buf[2]);
        end
    end

endmodule
