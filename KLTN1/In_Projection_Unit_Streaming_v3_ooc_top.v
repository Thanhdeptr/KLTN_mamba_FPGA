`timescale 1ns/1ps
// OOC synthesis top: tie active control so Vivado keeps the compute core.
module In_Projection_Unit_Streaming_v3_ooc_top (
    input  wire clk,
    input  wire signed [127:0] x_sub_vec_in,
    output wire signed [255:0] y_out,
    output wire done_x,
    output wire done_z,
    output wire busy,
    output wire [1:0] pass_idx_out,
    output wire out_valid,
    output wire [3:0] out_grp
);
    In_Projection_Unit_Streaming_v3 #(
        .SYNTH_OOC_KEEP(1)
    ) u_core (
        .clk(clk),
        .rst_n(1'b1),
        .en(1'b1),
        .start(1'b0),
        .x_sub_vec_in(x_sub_vec_in),
        .y_out(y_out),
        .done_x(done_x),
        .done_z(done_z),
        .busy(busy),
        .pass_idx_out(pass_idx_out),
        .out_valid(out_valid),
        .out_grp(out_grp)
    );
endmodule
