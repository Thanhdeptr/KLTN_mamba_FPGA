`timescale 1ns/1ps

// OOC synth top for full production chain through Scan (no OutProj yet).
module RMSNorm_InProj_Conv_Scan_Chain_Wrapper_ooc_top #(
    parameter NUM_TOKENS      = 16,
    parameter SCAN_MAX_TOKENS = 16,
    parameter CHAIN_Q_DEPTH   = 64,
    parameter NUM_EXEC        = 6
) (
    input  wire clk,
    input  wire rst_n,
    input  wire [64*16-1:0]              x_vec_in,
    input  wire [64*16-1:0]              gamma_vec,
    input  wire signed [8*16-1:0]        x_sub_vec_in,
    input  wire signed [128*4*16-1:0]    conv_w_packed,
    input  wire signed [128*16-1:0]      conv_b_packed,
    output wire                          scan_valid,
    output wire signed [16*16-1:0]       scan_y_vec,
    output wire                          scan_busy
);
    RMSNorm_InProj_Conv_Scan_Chain_Wrapper #(
        .NUM_TOKENS(NUM_TOKENS),
        .SCAN_MAX_TOKENS(SCAN_MAX_TOKENS),
        .CHAIN_Q_DEPTH(CHAIN_Q_DEPTH),
        .NUM_EXEC(NUM_EXEC)
    ) u_full (
        .clk(clk),
        .rst_n(rst_n),
        .en(1'b1),
        .start(1'b0),
        .frame_done(1'b0),
        .feed_idle(1'b1),
        .scan_clear_h(1'b0),
        .scan_sink_stall(1'b0),
        .x_vec_in(x_vec_in),
        .gamma_vec(gamma_vec),
        .x_sub_vec_in(x_sub_vec_in),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .y_out(),
        .done_x(),
        .done_z(),
        .conv_x_out(),
        .conv_z_out(),
        .conv_x_valid_out(),
        .conv_z_valid_out(),
        .conv_ready_in(),
        .chain_busy(),
        .stream_token_idx(),
        .inproj_streaming(),
        .feed_active(),
        .feed_complete(),
        .feed_ready(),
        .conv_x_capture_cnt(),
        .conv_z_capture_cnt(),
        .beat_q_count_dbg(),
        .beat_q_drop(),
        .beats_enq_total(),
        .scan_valid(scan_valid),
        .scan_token(),
        .scan_grp(),
        .scan_y_vec(scan_y_vec),
        .scan_busy(scan_busy),
        .scan_ready(),
        .conv_beat_ready()
    );
endmodule
