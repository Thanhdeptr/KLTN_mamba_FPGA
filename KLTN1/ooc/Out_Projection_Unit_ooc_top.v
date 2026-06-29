`timescale 1ns/1ps
`include "_parameter.v"

module Out_Projection_Unit_ooc_top (
    input  wire clk,
    input  wire [128*`DATA_WIDTH-1:0]    x_vec,
    input  wire [64*128*`DATA_WIDTH-1:0] w_matrix,
    output wire [64*`DATA_WIDTH-1:0]     y_vec
);
    Out_Projection_Unit u_out (
        .clk(clk),
        .reset(1'b0),
        .start(1'b1),
        .en(1'b1),
        .done(),
        .x_vec(x_vec),
        .w_matrix(w_matrix),
        .y_vec(y_vec)
    );
endmodule
