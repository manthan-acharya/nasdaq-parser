// Top-level synthesizable HFT FPGA platform.

`timescale 1ns / 1ps
`default_nettype none

module hft_top #(
    parameter logic [47:0] SRC_MAC = 48'h000a3502410b,
    parameter logic [47:0] DST_MAC = 48'h000a3502410a,
    parameter logic [31:0] SRC_IP  = 32'hc0a80164,
    parameter logic [31:0] DST_IP  = 32'hc0a801c8,
    parameter logic [15:0] SRC_PORT = 16'h3039,
    parameter logic [15:0] DST_PORT = 16'h3cc3,
    
    parameter int ORDER_ADDR_WIDTH = 12,
    parameter int BOOK_ADDR_WIDTH  = 10,
    parameter logic [31:0] ARB_THRESHOLD = 32'h010013aa 
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [63:0] s_axis_rx_tdata,
    input  logic [7:0]  s_axis_rx_tkeep,
    input  logic        s_axis_rx_tvalid,
    input  logic        s_axis_rx_tlast,
    input  logic        s_axis_rx_tuser,
    output logic        s_axis_rx_tready,

    input  logic [31:0] rate_ab,
    input  logic [31:0] rate_bc,
    input  logic [31:0] rate_ca,
    input  logic        rates_valid,

    input  logic        tcp_conn_trigger,
    input  logic        tcp_disc_trigger,
    output logic        tcp_session_established,
    output logic [3:0]  tcp_state_out,

    input  logic        tcp_rx_valid,
    input  logic        tcp_rx_syn,
    input  logic        tcp_rx_ack,
    input  logic        tcp_rx_fin,
    input  logic [31:0] tcp_rx_seq,
    input  logic [31:0] tcp_rx_ack_num,

    output logic [63:0] m_axis_tx_tdata,
    output logic [7:0]  m_axis_tx_tkeep,
    output logic        m_axis_tx_tvalid,
    output logic        m_axis_tx_tlast,
    input  logic        m_axis_tx_tready,

    output logic                         bbo_valid,
    output logic [63:0]                  bbo_stock,
    output logic [31:0]                  bbo_bid_price,
    output logic [31:0]                  bbo_bid_size,
    output logic [31:0]                  bbo_ask_price,
    output logic [31:0]                  bbo_ask_size,

    output logic                         arb_detected,
    output logic [31:0]                  arb_profit,
    output logic                         arb_valid,
    output logic                         math_overflow,

    input  logic [11:0]                  s_axi_dma_awaddr,
    input  logic                         s_axi_dma_awvalid,
    output logic                         s_axi_dma_awready,
    input  logic [31:0]                  s_axi_dma_wdata,
    input  logic [3:0]                   s_axi_dma_wstrb,
    input  logic                         s_axi_dma_wvalid,
    output logic                         s_axi_dma_wready,
    output logic [1:0]                   s_axi_dma_bresp,
    output logic                         s_axi_dma_bvalid,
    input  logic                         s_axi_dma_bready,
    input  logic [11:0]                  s_axi_dma_araddr,
    input  logic                         s_axi_dma_arvalid,
    output logic                         s_axi_dma_arready,
    output logic [31:0]                  s_axi_dma_rdata,
    output logic [1:0]                   s_axi_dma_rresp,
    output logic                         s_axi_dma_rvalid,
    input  logic                         s_axi_dma_rready,

    output logic [63:0]                  m_axis_pcie_tdata,
    output logic [7:0]                   m_axis_pcie_tkeep,
    output logic                         m_axis_pcie_tvalid,
    output logic                         m_axis_pcie_tlast,
    input  logic                         m_axis_pcie_tready
);

    logic [31:0] dummy_src_ip;
    logic [31:0] dummy_dst_ip;
    logic [15:0] dummy_src_port;
    logic [15:0] dummy_dst_port;
    logic [15:0] dummy_udp_length;
    logic        dummy_packet_valid;

    logic                         add_order_valid;
    itch_types::add_order_msg_t   add_order_data;
    logic                         exec_order_valid;
    itch_types::exec_order_msg_t  exec_order_data;
    logic                         cancel_order_valid;
    itch_types::cancel_order_msg_t cancel_order_data;
    logic                         delete_order_valid;
    itch_types::delete_order_msg_t delete_order_data;
    logic                         replace_order_valid;
    itch_types::replace_order_msg_t replace_order_data;

    // 1. Inbound Feed Handler (UDP & NASDAQ ITCH-5.0)
    nasdaq_pipeline #(
        .MOLDUDP64_SUPPORT (1'b1)
    ) u_feed_handler (
        .clk                (clk),
        .rst_n              (rst_n),

        .s_axis_tdata       (s_axis_rx_tdata),
        .s_axis_tkeep       (s_axis_rx_tkeep),
        .s_axis_tvalid      (s_axis_rx_tvalid),
        .s_axis_tlast       (s_axis_rx_tlast),
        .s_axis_tuser       (s_axis_rx_tuser),
        .s_axis_tready      (s_axis_rx_tready),

        .meta_src_ip        (dummy_src_ip),
        .meta_dst_ip        (dummy_dst_ip),
        .meta_src_port      (dummy_src_port),
        .meta_dst_port      (dummy_dst_port),
        .meta_udp_length    (dummy_udp_length),
        .packet_valid       (dummy_packet_valid),

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

    // 2. Hardware Limit Order Book (Dual-Port BRAM Core)
    order_book #(
        .ORDER_ADDR_WIDTH (ORDER_ADDR_WIDTH),
        .BOOK_ADDR_WIDTH  (BOOK_ADDR_WIDTH)
    ) u_order_book (
        .clk                (clk),
        .rst_n              (rst_n),

        .add_order_valid    (add_order_valid),
        .add_order_data     (add_order_data),
        .exec_order_valid   (exec_order_valid),
        .exec_order_data    (exec_order_data),
        .cancel_order_valid (cancel_order_valid),
        .cancel_order_data  (cancel_order_data),
        .delete_order_valid (delete_order_valid),
        .delete_order_data  (delete_order_data),
        .replace_order_valid(replace_order_valid),
        .replace_order_data (replace_order_data),

        .bbo_valid          (bbo_valid),
        .bbo_stock          (bbo_stock),
        .bbo_best_bid_price (bbo_bid_price),
        .bbo_best_bid_size  (bbo_bid_size),
        .bbo_best_ask_price (bbo_ask_price),
        .bbo_best_ask_size  (bbo_ask_size)
    );

    // 3. Triangular Arbitrage Detection Engine
    logic        arb_detected_sig;
    logic [31:0] arb_profit_sig;
    logic        arb_valid_sig;
    logic        overflow_sig;

    arb_engine #(
        .ARB_THRESHOLD (ARB_THRESHOLD)
    ) u_arb_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        
        .rate_ab       (rate_ab),
        .rate_bc       (rate_bc),
        .rate_ca       (rate_ca),
        .rates_valid   (rates_valid),
        
        .arb_detected  (arb_detected_sig),
        .arb_profit    (arb_profit_sig),
        .arb_valid     (arb_valid_sig),
        .math_overflow (overflow_sig)
    );

    assign arb_detected  = arb_detected_sig;
    assign arb_profit    = arb_profit_sig;
    assign arb_valid     = arb_valid_sig;
    assign math_overflow = overflow_sig;

    // 4. Outbound TCP Offload Engine (TOE)
    // When arbitrage is detected and the TCP session is open, we trigger an order.
    // We target the current BBO asset price and execute a standard buy/sell size.
    logic        send_order_trigger;
    logic [63:0] order_stock;
    logic [31:0] order_shares;
    logic [31:0] order_price;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            send_order_trigger <= 1'b0;
            order_stock        <= 64'h0;
            order_shares       <= 32'h0;
            order_price        <= 32'h0;
        end else begin
            send_order_trigger <= 1'b0;
            if (arb_detected_sig && tcp_session_established) begin
                send_order_trigger <= 1'b1;
                order_stock        <= bbo_stock;
                order_shares       <= bbo_bid_size; 
                order_price        <= bbo_bid_price; 
            end
        end
    end

    toe_top #(
        .SRC_MAC  (SRC_MAC),
        .DST_MAC  (DST_MAC),
        .SRC_IP   (SRC_IP),
        .DST_IP   (DST_IP),
        .SRC_PORT (SRC_PORT),
        .DST_PORT (DST_PORT)
    ) u_toe (
        .clk                     (clk),
        .rst_n                   (rst_n),

        .conn_trigger            (tcp_conn_trigger),
        .disconnect_trigger      (tcp_disc_trigger),
        .session_established     (tcp_session_established),
        .tcp_state               (tcp_state_out),

        .send_order              (send_order_trigger),
        .order_stock             (order_stock),
        .order_shares            (order_shares),
        .order_price             (order_price),

        .rx_valid                (tcp_rx_valid),
        .rx_syn                  (tcp_rx_syn),
        .rx_ack                  (tcp_rx_ack),
        .rx_fin                  (tcp_rx_fin),
        .rx_seq_num              (tcp_rx_seq),
        .rx_ack_num              (tcp_rx_ack_num),

        .m_axis_tdata            (m_axis_tx_tdata),
        .m_axis_tkeep            (m_axis_tx_tkeep),
        .m_axis_tvalid           (m_axis_tx_tvalid),
        .m_axis_tlast            (m_axis_tx_tlast),
        .m_axis_tready           (m_axis_tx_tready)
    );

    // 5. PCIe direct DMA Subsystem
    pcie_dma_top #(
        .REQUESTER_ID            (16'h0100)
    ) u_pcie_dma (
        .clk                     (clk),
        .rst_n                   (rst_n),

        .bbo_valid               (bbo_valid),
        .bbo_stock               (bbo_stock),
        .bbo_bid_price           (bbo_bid_price),
        .bbo_ask_price           (bbo_ask_price),

        .arb_detected            (arb_detected_sig),
        .arb_profit              (arb_profit_sig),

        .s_axi_awaddr            (s_axi_dma_awaddr),
        .s_axi_awvalid           (s_axi_dma_awvalid),
        .s_axi_awready           (s_axi_dma_awready),
        .s_axi_wdata             (s_axi_dma_wdata),
        .s_axi_wstrb             (s_axi_dma_wstrb),
        .s_axi_wvalid            (s_axi_dma_wvalid),
        .s_axi_wready            (s_axi_dma_wready),
        .s_axi_bresp             (s_axi_dma_bresp),
        .s_axi_bvalid            (s_axi_dma_bvalid),
        .s_axi_bready            (s_axi_dma_bready),

        .s_axi_araddr            (s_axi_dma_araddr),
        .s_axi_arvalid           (s_axi_dma_arvalid),
        .s_axi_arready           (s_axi_dma_arready),
        .s_axi_rdata             (s_axi_dma_rdata),
        .s_axi_rresp             (s_axi_dma_rresp),
        .s_axi_rvalid            (s_axi_dma_rvalid),
        .s_axi_rready            (s_axi_dma_rready),

        .m_axis_pcie_tdata       (m_axis_pcie_tdata),
        .m_axis_pcie_tkeep       (m_axis_pcie_tkeep),
        .m_axis_pcie_tvalid      (m_axis_pcie_tvalid),
        .m_axis_pcie_tlast       (m_axis_pcie_tlast),
        .m_axis_pcie_tready      (m_axis_pcie_tready)
    );

endmodule

`default_nettype wire
