// Two-stage pipelined Triangular Arbitrage math engine.

`timescale 1ns / 1ps
`default_nettype none

module arb_engine #(
    // Default threshold is Q8.24 format: 32'h01000000 (1.0) + 32'h000013aa (0.0003 or 3 bps fee)
    // 32'h010013aa = 1.0003
    parameter logic [31:0] ARB_THRESHOLD = 32'h010013aa
) (
    input  logic        clk,
    input  logic        rst_n,
 
    input  logic [31:0] rate_ab,
    input  logic [31:0] rate_bc,
    input  logic [31:0] rate_ca,
    input  logic        rates_valid,
 
    output logic        arb_detected,
    output logic [31:0] arb_profit,     // Profit percentage in Q8.24 (product - 1.0)
    output logic        arb_valid,      
    output logic        math_overflow   
);

    // Stage 1: Product of first two rates (Rate_AB * Rate_BC)
    logic [31:0] s1_prod;
    logic        s1_valid;
    logic        s1_overflow;
    
    // Delay rate_ca to align with Stage 1 output (1-cycle delay)
    logic [31:0] s1_rate_ca;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_rate_ca <= 32'h0;
        end else if (rates_valid) begin
            s1_rate_ca <= rate_ca;
        end
    end

    q8_24_mul u_mul1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (rate_ab),
        .b         (rate_bc),
        .in_valid  (rates_valid),
        
        .c         (s1_prod),
        .out_valid (s1_valid),
        .overflow  (s1_overflow)
    );

    // Stage 2: Product of intermediate result and third rate (s1_prod * s1_rate_ca)
    logic [31:0] s2_prod;
    logic        s2_valid;
    logic        s2_overflow;

    q8_24_mul u_mul2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (s1_prod),
        .b         (s1_rate_ca),
        .in_valid  (s1_valid),
        
        .c         (s2_prod),
        .out_valid (s2_valid),
        .overflow  (s2_overflow)
    );

    logic s2_s1_overflow;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_s1_overflow <= 1'b0;
        end else if (s1_valid) begin
            s2_s1_overflow <= s1_overflow;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_detected  <= 1'b0;
            arb_profit    <= 32'h0;
            arb_valid     <= 1'b0;
            math_overflow <= 1'b0;
        end else begin
            arb_detected  <= 1'b0;
            arb_profit    <= 32'h0;
            arb_valid     <= s2_valid;
            math_overflow <= s2_overflow || s2_s1_overflow;

            if (s2_valid && !s2_overflow && !s2_s1_overflow) begin
                if (s2_prod > ARB_THRESHOLD) begin
                    arb_detected <= 1'b1;
                    arb_profit   <= s2_prod - 32'h01000000;
                end
            end
        end
    end

endmodule
