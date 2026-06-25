// Top-level simulation wrapper for Verilator cycle-accurate verification.

`timescale 1ns / 1ps
`default_nettype none

module tb_hft_top (
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

    hft_top #(
        .ORDER_ADDR_WIDTH (12),
        .BOOK_ADDR_WIDTH  (10)
    ) u_top (
        .clk                     (clk),
        .rst_n                   (rst_n),

        .s_axis_rx_tdata         (s_axis_rx_tdata),
        .s_axis_rx_tkeep         (s_axis_rx_tkeep),
        .s_axis_rx_tvalid        (s_axis_rx_tvalid),
        .s_axis_rx_tlast         (s_axis_rx_tlast),
        .s_axis_rx_tuser         (s_axis_rx_tuser),
        .s_axis_rx_tready        (s_axis_rx_tready),

        .rate_ab                 (rate_ab),
        .rate_bc                 (rate_bc),
        .rate_ca                 (rate_ca),
        .rates_valid             (rates_valid),

        .tcp_conn_trigger        (tcp_conn_trigger),
        .tcp_disc_trigger        (tcp_disc_trigger),
        .tcp_session_established (tcp_session_established),
        .tcp_state_out           (tcp_state_out),

        .tcp_rx_valid            (tcp_rx_valid),
        .tcp_rx_syn              (tcp_rx_syn),
        .tcp_rx_ack              (tcp_rx_ack),
        .tcp_rx_fin              (tcp_rx_fin),
        .tcp_rx_seq              (tcp_rx_seq),
        .tcp_rx_ack_num          (tcp_rx_ack_num),

        .m_axis_tx_tdata         (m_axis_tx_tdata),
        .m_axis_tx_tkeep         (m_axis_tx_tkeep),
        .m_axis_tx_tvalid        (m_axis_tx_tvalid),
        .m_axis_tx_tlast         (m_axis_tx_tlast),
        .m_axis_tx_tready        (m_axis_tx_tready),

        .bbo_valid               (bbo_valid),
        .bbo_stock               (bbo_stock),
        .bbo_bid_price           (bbo_bid_price),
        .bbo_bid_size            (bbo_bid_size),
        .bbo_ask_price           (bbo_ask_price),
        .bbo_ask_size            (bbo_ask_size),

        .arb_detected            (arb_detected),
        .arb_profit              (arb_profit),
        .arb_valid               (arb_valid),
        .math_overflow           (math_overflow),

        .s_axi_dma_awaddr        (s_axi_dma_awaddr),
        .s_axi_dma_awvalid       (s_axi_dma_awvalid),
        .s_axi_dma_awready       (s_axi_dma_awready),
        .s_axi_dma_wdata         (s_axi_dma_wdata),
        .s_axi_dma_wstrb         (s_axi_dma_wstrb),
        .s_axi_dma_wvalid        (s_axi_dma_wvalid),
        .s_axi_dma_wready        (s_axi_dma_wready),
        .s_axi_dma_bresp         (s_axi_dma_bresp),
        .s_axi_dma_bvalid        (s_axi_dma_bvalid),
        .s_axi_dma_bready        (s_axi_dma_bready),
        .s_axi_dma_araddr        (s_axi_dma_araddr),
        .s_axi_dma_arvalid       (s_axi_dma_arvalid),
        .s_axi_dma_arready       (s_axi_dma_arready),
        .s_axi_dma_rdata         (s_axi_dma_rdata),
        .s_axi_dma_rresp         (s_axi_dma_rresp),
        .s_axi_dma_rvalid        (s_axi_dma_rvalid),
        .s_axi_dma_rready        (s_axi_dma_rready),

        .m_axis_pcie_tdata       (m_axis_pcie_tdata),
        .m_axis_pcie_tkeep       (m_axis_pcie_tkeep),
        .m_axis_pcie_tvalid      (m_axis_pcie_tvalid),
        .m_axis_pcie_tlast       (m_axis_pcie_tlast),
        .m_axis_pcie_tready      (m_axis_pcie_tready)
    );

endmodule
