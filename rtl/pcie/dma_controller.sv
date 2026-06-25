// Low-latency DMA controller compiling PCIe Memory Write (MWr) TLPs.

`timescale 1ns / 1ps
`default_nettype none

module dma_controller #(
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

    // BAR0 Register Bus (from Host MMIO)
    input  logic        bar0_wr_en,
    input  logic [11:0] bar0_addr,
    input  logic [31:0] bar0_wr_data,
    input  logic        bar0_rd_en,
    output logic [31:0] bar0_rd_data,

    // PCIe Requester Request (RQ) AXI-Stream Interface (64-bit)
    output logic [63:0] m_axis_pcie_tdata,
    output logic [7:0]  m_axis_pcie_tkeep,
    output logic        m_axis_pcie_tvalid,
    output logic        m_axis_pcie_tlast,
    input  logic        m_axis_pcie_tready
);

    // BAR0 Configuration Registers
    // 0x000: Control Register (bit 0: DMA Enable, bit 1: Reset Offset)
    // 0x004: DMA Base Address Low [31:0]
    // 0x008: DMA Base Address High [63:32]
    // 0x00C: DMA Buffer Size [31:0] (Max offset before wrap, power-of-2)
    // 0x010: DMA Write Pointer Offset [31:0] (Read-Only)
    logic [31:0] reg_ctrl;
    logic [31:0] reg_base_addr_low;
    logic [31:0] reg_base_addr_high;
    logic [31:0] reg_buf_size;
    logic [31:0] reg_wr_offset;

    logic dma_enabled;
    assign dma_enabled = reg_ctrl[0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl           <= 32'h0;
            reg_base_addr_low  <= 32'h0;
            reg_base_addr_high <= 32'h0;
            reg_buf_size       <= 32'h0010_0000;
            reg_wr_offset      <= 32'h0;
        end else begin
            if (bar0_wr_en) begin
                case (bar0_addr)
                    12'h000: reg_ctrl           <= bar0_wr_data;
                    12'h004: reg_base_addr_low  <= bar0_wr_data;
                    12'h008: reg_base_addr_high <= bar0_wr_data;
                    12'h00C: reg_buf_size       <= bar0_wr_data;
                    default: ;
                endcase
            end

            if (reg_ctrl[1]) begin
                reg_wr_offset <= 32'h0;
                reg_ctrl[1]   <= 1'b0;
            end else if (dma_enabled && m_axis_pcie_tvalid && m_axis_pcie_tready && m_axis_pcie_tlast) begin
                if (reg_wr_offset + 32 >= reg_buf_size) begin
                    reg_wr_offset <= 32'h0;
                end else begin
                    reg_wr_offset <= reg_wr_offset + 32;
                end
            end
        end
    end

    always_comb begin
        bar0_rd_data = 32'h0;
        if (bar0_rd_en) begin
            case (bar0_addr)
                12'h000: bar0_rd_data = reg_ctrl;
                12'h004: bar0_rd_data = reg_base_addr_low;
                12'h008: bar0_rd_data = reg_base_addr_high;
                12'h00C: bar0_rd_data = reg_buf_size;
                12'h010: bar0_rd_data = reg_wr_offset;
                default: bar0_rd_data = 32'hDEADBEEF;
            endcase
        end
    end

    // Event Request FIFO
    // Queue structure:
    // [136]    : Event Type (0: BBO, 1: Arb)
    // [135:72] : Stock ticker (64 bits)
    // [71:40]  : Bid Price or Profit (32 bits)
    // [39:8]   : Ask Price (32 bits)
    // [7:0]    : Unused padding
    localparam int FIFO_WIDTH = 137;
    localparam int FIFO_DEPTH = 16;

    logic [FIFO_WIDTH-1:0] fifo_mem [FIFO_DEPTH-1:0];
    logic [3:0]            fifo_wr_ptr;
    logic [3:0]            fifo_rd_ptr;
    logic [4:0]            fifo_cnt;
    
    logic                  fifo_full;
    logic                  fifo_empty;
    assign fifo_full  = (fifo_cnt == FIFO_DEPTH);
    assign fifo_empty = (fifo_cnt == 0);

    logic                  fifo_push;
    logic                  fifo_pop;
    logic [FIFO_WIDTH-1:0] fifo_din;
    logic [FIFO_WIDTH-1:0] fifo_dout;

    // Push logic: prioritize Arb over BBO
    always_comb begin
        fifo_push = 1'b0;
        fifo_din  = '0;
        if (dma_enabled && !fifo_full) begin
            if (arb_detected) begin
                fifo_push = 1'b1;
                fifo_din  = {1'b1, 64'h4152425f4c4f4f50, arb_profit, 32'h0, 8'h0};
            end else if (bbo_valid) begin
                fifo_push = 1'b1;
                fifo_din  = {1'b0, bbo_stock, bbo_bid_price, bbo_ask_price, 8'h0};
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= 4'h0;
            fifo_rd_ptr <= 4'h0;
            fifo_cnt    <= 5'd0;
        end else begin
            if (fifo_push && !fifo_full) begin
                fifo_mem[fifo_wr_ptr] <= fifo_din;
                fifo_wr_ptr           <= fifo_wr_ptr + 1;
            end
            if (fifo_pop && !fifo_empty) begin
                fifo_rd_ptr           <= fifo_rd_ptr + 1;
            end

            case ({fifo_push && !fifo_full, fifo_pop && !fifo_empty})
                2'b10: fifo_cnt <= fifo_cnt + 1;
                2'b01: fifo_cnt <= fifo_cnt - 1;
                default: ;
            endcase
        end
    end

    assign fifo_dout = fifo_mem[fifo_rd_ptr];

    // PCIe MWr TLP Compilation State Machine
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_HDR_0,    
        ST_HDR_1,    
        ST_DATA_0,   
        ST_DATA_1    
    } state_t;

    state_t state, next_state;

    logic [63:0] tx_addr;
    logic [63:0] tx_stock;
    logic [31:0] tx_val1;
    logic [31:0] tx_val2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            tx_addr  <= 64'h0;
            tx_stock <= 64'h0;
            tx_val1  <= 32'h0;
            tx_val2  <= 32'h0;
        end else begin
            if (state == ST_IDLE && !fifo_empty) begin
                state    <= ST_HDR_0;
                tx_addr  <= {reg_base_addr_high, reg_base_addr_low} + reg_wr_offset;
                tx_stock <= fifo_dout[135:72];
                tx_val1  <= fifo_dout[71:40];
                tx_val2  <= fifo_dout[39:8];
            end else if (m_axis_pcie_tready && m_axis_pcie_tvalid) begin
                state    <= next_state;
            end
        end
    end

    always_comb begin
        next_state = state;
        fifo_pop   = 1'b0;

        case (state)
            ST_HDR_0: begin
                if (m_axis_pcie_tready) next_state = ST_HDR_1;
            end
            ST_HDR_1: begin
                if (m_axis_pcie_tready) next_state = ST_DATA_0;
            end
            ST_DATA_0: begin
                if (m_axis_pcie_tready) next_state = ST_DATA_1;
            end
            ST_DATA_1: begin
                if (m_axis_pcie_tready) begin
                    next_state = ST_IDLE;
                    fifo_pop   = 1'b1;
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // 64-bit Address Memory Write (MWr) 4-DW Header format:
    // DW0: {3'b011 (Fmt: 4-DW with data), 5'b00000 (Type: MWr), 1'b0, 3'b000 (TC), 8'h00, 2'b00 (Attr), 10'd4 (Length: 4 DW)}
    //      = 32'h6000_0004
    // DW1: {REQUESTER_ID, 8'h01 (Tag), 4'hF (Last BE), 4'hF (First BE)}
    //      = {REQUESTER_ID, 8'h01, 8'hFF}
    // DW2: Address [63:32]
    // DW3: Address [31:0]
    // DW4: Stock [63:32]
    // DW5: Stock [31:0]
    // DW6: Price 1 (Bid / Profit)
    // DW7: Price 2 (Ask / 0)
    always_comb begin
        m_axis_pcie_tdata  = 64'h0;
        m_axis_pcie_tkeep  = 8'h00;
        m_axis_pcie_tvalid = 1'b0;
        m_axis_pcie_tlast  = 1'b0;

        case (state)
            ST_HDR_0: begin
                m_axis_pcie_tdata  = { {REQUESTER_ID, 8'h01, 8'hFF}, 32'h6000_0004 }; 
                m_axis_pcie_tkeep  = 8'hFF;
                m_axis_pcie_tvalid = 1'b1;
            end

            ST_HDR_1: begin
                m_axis_pcie_tdata  = { tx_addr[31:0], tx_addr[63:32] }; 
                m_axis_pcie_tkeep  = 8'hFF;
                m_axis_pcie_tvalid = 1'b1;
            end

            ST_DATA_0: begin
                m_axis_pcie_tdata  = { tx_stock[31:0], tx_stock[63:32] }; 
                m_axis_pcie_tkeep  = 8'hFF;
                m_axis_pcie_tvalid = 1'b1;
            end

            ST_DATA_1: begin
                m_axis_pcie_tdata  = { tx_val2, tx_val1 }; 
                m_axis_pcie_tkeep  = 8'hFF;
                m_axis_pcie_tvalid = 1'b1;
                m_axis_pcie_tlast  = 1'b1;
            end

            default: ;
        endcase
    end

endmodule

`default_nettype wire
