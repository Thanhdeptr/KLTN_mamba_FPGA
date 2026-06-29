`timescale 1ns/1ps

module RMSNorm_Unit_IntSqrt_ooc_top (
    input  wire clk,
    input  wire [64*16-1:0] x_vec,
    input  wire [64*16-1:0] gamma_vec,
    output wire [64*16-1:0] y_vec
);
    RMSNorm_Unit_IntSqrt u_rms (
        .clk(clk),
        .reset(1'b0),
        .start(1'b1),
        .en(1'b1),
        .done(),
        .x_vec(x_vec),
        .gamma_vec(gamma_vec),
        .y_vec(y_vec)
    );
endmodule
