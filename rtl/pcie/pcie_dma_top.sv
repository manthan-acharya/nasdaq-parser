// Top-level PCIe DMA wrapper decoding host AXI-Lite MMIO register accesses (BAR0).

`timescale 1ns / 1ps
`default_nettype none

module pcie_dma_top #(
    parameter logic [15:0] REQUESTER_ID = 16'h0100
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        bbo_valid,
    input  logic [63:0] bbo_stock,
    input  logic [31:0] bbo_bid_price,
    input  logic [31:0] bbo_ask_price,

    input  logic        arb_detected,
    input  logic [31:0] arb_profit,

    // Host AXI-Lite MMIO Register Interface (BAR0 subordinate)
    input  logic [11:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [11:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // PCIe Requester Request (RQ) AXI-Stream Interface (64-bit)
    output logic [63:0] m_axis_pcie_tdata,
    output logic [7:0]  m_axis_pcie_tkeep,
    output logic        m_axis_pcie_tvalid,
    output logic        m_axis_pcie_tlast,
    input  logic        m_axis_pcie_tready
);

    logic        bar0_wr_en;
    logic [11:0] bar0_addr;
    assign bar0_addr = bar0_wr_en ? waddr : raddr;
    logic [31:0] bar0_wr_data;
    logic        bar0_rd_en;
    logic [31:0] bar0_rd_data;

    // AXI-Lite Subordinate Interface State Machine
    typedef enum logic [1:0] {
        AXI_IDLE,
        AXI_WRITE_RESP,
        AXI_READ_RESP
    } axi_state_t;

    axi_state_t write_state, next_write_state;
    axi_state_t read_state, next_read_state;

    logic [11:0] waddr;
    logic [31:0] wdata;
    logic        waddr_latch;
    logic        wdata_latch;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_state <= AXI_IDLE;
            waddr       <= 12'h0;
            wdata       <= 32'h0;
            waddr_latch <= 1'b0;
            wdata_latch <= 1'b0;
        end else begin
            write_state <= next_write_state;

            if (s_axi_awvalid && s_axi_awready) begin
                waddr       <= s_axi_awaddr;
                waddr_latch <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata       <= s_axi_wdata;
                wdata_latch <= 1'b1;
            end

            if (write_state == AXI_WRITE_RESP && s_axi_bvalid && s_axi_bready) begin
                waddr_latch <= 1'b0;
                wdata_latch <= 1'b0;
            end
        end
    end

    always_comb begin
        next_write_state = write_state;
        s_axi_awready    = !waddr_latch;
        s_axi_wready     = !wdata_latch;
        s_axi_bvalid     = 1'b0;
        s_axi_bresp      = 2'b00;
        bar0_wr_en       = 1'b0;
        bar0_wr_data     = wdata;

        case (write_state)
            AXI_IDLE: begin
                if (waddr_latch && wdata_latch) begin
                    bar0_wr_en       = 1'b1;
                    next_write_state = AXI_WRITE_RESP;
                end
            end
            AXI_WRITE_RESP: begin
                s_axi_bvalid = 1'b1;
                if (s_axi_bready) begin
                    next_write_state = AXI_IDLE;
                end
            end
            default: next_write_state = AXI_IDLE;
        endcase
    end

    logic [11:0] raddr;
    logic        raddr_latch;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_state  <= AXI_IDLE;
            raddr       <= 12'h0;
            raddr_latch <= 1'b0;
        end else begin
            read_state <= next_read_state;

            if (s_axi_arvalid && s_axi_arready) begin
                raddr       <= s_axi_araddr;
                raddr_latch <= 1'b1;
            end

            if (read_state == AXI_READ_RESP && s_axi_rvalid && s_axi_rready) begin
                raddr_latch <= 1'b0;
            end
        end
    end

    always_comb begin
        next_read_state = read_state;
        s_axi_arready   = !raddr_latch;
        s_axi_rvalid    = 1'b0;
        s_axi_rresp     = 2'b00;
        s_axi_rdata     = 32'h0;
        bar0_rd_en      = 1'b0;

        case (read_state)
            AXI_IDLE: begin
                if (raddr_latch) begin
                    bar0_rd_en      = 1'b1;
                    next_read_state = AXI_READ_RESP;
                end
            end
            AXI_READ_RESP: begin
                s_axi_rvalid = 1'b1;
                bar0_rd_en   = 1'b1; // Keep read enable asserted to keep data valid!
                s_axi_rdata  = bar0_rd_data;
                if (s_axi_rready) begin
                    next_read_state = AXI_IDLE;
                end
            end
            default: next_read_state = AXI_IDLE;
        endcase
    end

    // Instantiate core DMA Controller
    dma_controller #(
        .REQUESTER_ID (REQUESTER_ID)
    ) u_dma_ctrl (
        .clk                (clk),
        .rst_n              (rst_n),

        .bbo_valid          (bbo_valid),
        .bbo_stock          (bbo_stock),
        .bbo_bid_price      (bbo_bid_price),
        .bbo_ask_price      (bbo_ask_price),

        .arb_detected       (arb_detected),
        .arb_profit         (arb_profit),

        .bar0_wr_en         (bar0_wr_en),
        .bar0_addr          (bar0_addr),
        .bar0_wr_data       (bar0_wr_data),
        .bar0_rd_en         (bar0_rd_en),
        .bar0_rd_data       (bar0_rd_data),

        .m_axis_pcie_tdata  (m_axis_pcie_tdata),
        .m_axis_pcie_tkeep  (m_axis_pcie_tkeep),
        .m_axis_pcie_tvalid (m_axis_pcie_tvalid),
        .m_axis_pcie_tlast  (m_axis_pcie_tlast),
        .m_axis_pcie_tready (m_axis_pcie_tready)
    );

endmodule

`default_nettype wire
