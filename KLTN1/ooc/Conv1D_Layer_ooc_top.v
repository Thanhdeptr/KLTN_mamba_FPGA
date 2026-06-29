`timescale 1ns/1ps
`include "_parameter.v"

module Conv1D_Layer_ooc_top (
    input  wire clk,
    input  wire signed [`D_INNER*4*`DATA_WIDTH-1:0] conv_w_packed,
    input  wire signed [`D_INNER*`DATA_WIDTH-1:0]   conv_b_packed,
    input  wire signed [16*`DATA_WIDTH-1:0]        x_in_vec,
    output wire signed [16*`DATA_WIDTH-1:0]      y_out_vec,
    output wire signed [16*`DATA_WIDTH-1:0]      z_out_vec
);
    wire valid_out;
    wire x_valid_out;
    wire z_valid_out;
    wire ready_in;
    wire beat_accept;

    wire signed [16*`DATA_WIDTH-1:0] y_out_int;
    wire signed [16*`DATA_WIDTH-1:0] z_out_int;

    reg signed [16*`DATA_WIDTH-1:0] y_out_r;
    reg signed [16*`DATA_WIDTH-1:0] z_out_r;

    always @(posedge clk) begin
        y_out_r <= y_out_int;
        z_out_r <= z_out_int;
    end

    assign y_out_vec = y_out_r;
    assign z_out_vec = z_out_r;

    Conv1D_Layer #(
        .FULL_WEIGHTS(1),
        .MAX_TOKENS(16)
    ) u_conv (
        .clk(clk),
        .reset(1'b0),
        .start(1'b1),
        .en(1'b1),
        .valid_in(1'b1),
        .path_x(1'b1),
        .grp_idx(4'd0),
        .token_idx(16'd0),
        .valid_out(valid_out),
        .x_valid_out(x_valid_out),
        .z_valid_out(z_valid_out),
        .ready_in(ready_in),
        .x_in_vec(x_in_vec),
        .weights_vec({16*4*`DATA_WIDTH{1'b0}}),
        .bias_vec({16*`DATA_WIDTH{1'b0}}),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .y_out_vec(y_out_int),
        .z_out_vec(z_out_int),
        .x_capture_cnt(),
        .z_capture_cnt(),
        .x_accept_cnt(),
        .x_out_grp(),
        .x_out_token(),
        .z_out_grp(),
        .z_out_token(),
        .beat_accept(beat_accept)
    );
endmodule
