// Combinational byte-level barrel shifter to align SBE fields for extraction.

`timescale 1ns / 1ps
`default_nettype none

module sbe_barrel_shifter #(
    parameter int DATA_WIDTH = 64
) (
    input  logic [DATA_WIDTH-1:0] data_in,
    input  logic [2:0]            shift_bytes,
    output logic [DATA_WIDTH-1:0] data_out
);

    always_comb begin
        case (shift_bytes)
            3'd0: data_out = data_in;
            3'd1: data_out = {8'h00,  data_in[DATA_WIDTH-1:8]};
            3'd2: data_out = {16'h00, data_in[DATA_WIDTH-1:16]};
            3'd3: data_out = {24'h00, data_in[DATA_WIDTH-1:24]};
            3'd4: data_out = {32'h00, data_in[DATA_WIDTH-1:32]};
            3'd5: data_out = {40'h00, data_in[DATA_WIDTH-1:40]};
            3'd6: data_out = {48'h00, data_in[DATA_WIDTH-1:48]};
            3'd7: data_out = {56'h00, data_in[DATA_WIDTH-1:56]};
            default: data_out = data_in;
        endcase
    end

endmodule

`default_nettype wire
