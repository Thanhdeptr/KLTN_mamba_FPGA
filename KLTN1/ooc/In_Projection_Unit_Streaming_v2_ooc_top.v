`timescale 1ns/1ps

module In_Projection_Unit_Streaming_v2_ooc_top (
    input  wire clk,
    input  wire signed [8*16-1:0] x_sub_vec_in,
    output wire signed [16*16-1:0] y_out,
    output wire done_x,
    output wire done_z
);
    In_Projection_Unit_Streaming_v2 u_inproj (
        .clk(clk),
        .rst_n(1'b1),
        .en(1'b1),
        .start(1'b1),
        .x_sub_vec_in(x_sub_vec_in),
        .y_out(y_out),
        .done_x(done_x),
        .done_z(done_z)
    );
endmodule
