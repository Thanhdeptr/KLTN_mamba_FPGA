`timescale 1ns/1ps

// OOC synth: prod NUM_EXEC=6, MAX_TOKENS=1000, h_live (no full h history), weight ROM init.
module Scan_Core_Streaming_Pipe_ooc_top #(
    parameter MAX_TOKENS      = 1000,
    parameter NUM_EXEC        = 6,
    parameter SEQ_STRIDE      = MAX_TOKENS,
    parameter H_INIT_ON_RESET = 0,
    parameter H_STORE_FULL_HISTORY = 0,
    parameter INIT_WEIGHT_MEM = 1
) (
    input  wire clk,
    input  wire rst_n,
    input  wire signed [16*16-1:0] beat_vec,
    input  wire signed [16*16-1:0] delta_beat_vec,
    output wire scan_valid,
    output wire signed [16*16-1:0] y_out_vec,
    output wire busy
);
    Scan_Core_Streaming_Pipe #(
        .MAX_TOKENS(MAX_TOKENS),
        .NUM_EXEC(NUM_EXEC),
        .SEQ_STRIDE(SEQ_STRIDE),
        .H_INIT_ON_RESET(H_INIT_ON_RESET),
        .H_STORE_FULL_HISTORY(H_STORE_FULL_HISTORY),
        .INIT_WEIGHT_MEM(INIT_WEIGHT_MEM)
    ) u_pipe (
        .clk(clk),
        .rst_n(rst_n),
        .en(1'b1),
        .clear_h(1'b0),
        .beat_valid(1'b0),
        .beat_path_x(1'b1),
        .beat_grp(3'd0),
        .beat_token(16'd0),
        .beat_vec(beat_vec),
        .delta_beat_vec(delta_beat_vec),
        .B_row({256{1'b0}}),
        .C_row({256{1'b0}}),
        .A_row_ch({256{1'b0}}),
        .D_ch(16'sd0),
        .delta_ch(16'sd0),
        .x_ch(16'sd0),
        .scan_ready(),
        .busy(busy),
        .scan_valid(scan_valid),
        .scan_token(),
        .scan_grp(),
        .y_out_vec(y_out_vec),
        .token_done(),
        .token_done_idx(),
        .dbg_active_token(),
        .dbg_lane_idx(),
        .dbg_active_grp(),
        .dbg_ch_done(),
        .dbg_ch_h_new(),
        .y_pre_rd_vec(),
        .ypre_ready_mask(),
        .z_beat_ready()
    );
endmodule
