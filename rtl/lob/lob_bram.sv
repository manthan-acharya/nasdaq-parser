// Synthesizable parameterized dual-port Block RAM

`timescale 1ns / 1ps
`default_nettype none

module lob_bram #(
    parameter int DATA_WIDTH = 64,
    parameter int ADDR_WIDTH = 10
) (
    input  logic                    clk,

    // Port A (Control/Write/Read)
    input  logic                    we_a,
    input  logic [ADDR_WIDTH-1:0]   addr_a,
    input  logic [DATA_WIDTH-1:0]   din_a,
    output logic [DATA_WIDTH-1:0]   dout_a,

    // Port B (Control/Write/Read)
    input  logic                    we_b,
    input  logic [ADDR_WIDTH-1:0]   addr_b,
    input  logic [DATA_WIDTH-1:0]   din_b,
    output logic [DATA_WIDTH-1:0]   dout_b
);

    localparam int RAM_DEPTH = 1 << ADDR_WIDTH;

    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram [RAM_DEPTH-1:0];

    always_ff @(posedge clk) begin
        if (we_a) begin
            ram[addr_a] <= din_a;
        end
        dout_a <= ram[addr_a];
    end

    always_ff @(posedge clk) begin
        if (we_b) begin
            ram[addr_b] <= din_b;
        end
        dout_b <= ram[addr_b];
    end

endmodule

`default_nettype wire
