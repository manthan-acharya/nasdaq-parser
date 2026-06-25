// Pipelined Q8.24 fixed-point multiplier designed to map DSP blocks.

`timescale 1ns / 1ps
`default_nettype none

module q8_24_mul (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic        in_valid,

    output logic [31:0] c,
    output logic        out_valid,
    output logic        overflow
);

    // Intermediate 64-bit product (32-bit * 32-bit) with 48 fractional bits
    logic [63:0] product_reg;
    logic        valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_reg <= 64'h0;
            valid_reg   <= 1'b0;
        end else if (in_valid) begin
            product_reg <= 64'(a) * 64'(b);
            valid_reg   <= 1'b1;
        end else begin
            valid_reg   <= 1'b0;
        end
    end

    // Realign product back to Q8.24 format (shift right by 24 fractional bits)
    assign c         = product_reg[55:24];
    assign out_valid = valid_reg;

    // Overflow detection: check if product integer portion exceeds 8 bits
    assign overflow = |product_reg[63:56];

endmodule
