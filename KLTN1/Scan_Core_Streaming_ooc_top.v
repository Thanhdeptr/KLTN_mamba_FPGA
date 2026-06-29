`timescale 1ns/1ps

module Scan_Core_Streaming_ooc_top (
    input  wire clk,
    input  wire rst_n
);
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_STATE    = 16;

    reg en;
    reg clear_h;
    reg beat_valid;
    reg beat_path_x;
    reg [2:0] beat_grp;
    reg [15:0] beat_token;
    reg signed [LANES*DATA_WIDTH-1:0] beat_vec;
    reg signed [D_STATE*DATA_WIDTH-1:0] B_row;
    reg signed [D_STATE*DATA_WIDTH-1:0] C_row;
    reg signed [D_STATE*DATA_WIDTH-1:0] A_row_ch;
    reg signed [DATA_WIDTH-1:0] D_ch;
    reg signed [DATA_WIDTH-1:0] delta_ch;
    reg signed [DATA_WIDTH-1:0] x_ch;

    wire busy;
    wire scan_valid;
    wire [15:0] scan_token;
    wire [2:0] scan_grp;
    wire signed [LANES*DATA_WIDTH-1:0] y_out_vec;

    Scan_Core_Streaming #(
        .MAX_TOKENS(2)
    ) u_scan (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear_h(clear_h),
        .beat_valid(beat_valid),
        .beat_path_x(beat_path_x),
        .beat_grp(beat_grp),
        .beat_token(beat_token),
        .beat_vec(beat_vec),
        .B_row(B_row),
        .C_row(C_row),
        .A_row_ch(A_row_ch),
        .D_ch(D_ch),
        .delta_ch(delta_ch),
        .x_ch(x_ch),
        .busy(busy),
        .scan_valid(scan_valid),
        .scan_token(scan_token),
        .scan_grp(scan_grp),
        .y_out_vec(y_out_vec),
        .token_done(),
        .token_done_idx(),
        .dbg_active_token(),
        .dbg_lane_idx(),
        .dbg_active_grp()
    );

endmodule
