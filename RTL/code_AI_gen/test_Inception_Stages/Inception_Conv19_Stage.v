`timescale 1ns/1ps

module Inception_Conv19_Stage (
    input clk,
    input rst_n,
    input [255:0] token_in,
    input valid_in,
    output [255:0] token_out,
    output valid_out
);

    Inception_ConvBranch_Stage #(.KERNEL(19), .CENTER(28), .WEIGHT_LIMIT(4863)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(token_in),
        .valid_in(valid_in),
        .token_out(token_out),
        .valid_out(valid_out)
    );

endmodule