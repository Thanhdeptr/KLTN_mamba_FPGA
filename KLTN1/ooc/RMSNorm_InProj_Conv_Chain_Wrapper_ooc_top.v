`timescale 1ns/1ps

// OOC synth top for production Norm->InProj v2->Conv chain.
module RMSNorm_InProj_Conv_Chain_Wrapper_ooc_top #(
    parameter NUM_TOKENS = 16
) (
    input  wire clk,
    input  wire rst_n,
    input  wire [64*16-1:0]              x_vec_in,
    input  wire [64*16-1:0]              gamma_vec,
    input  wire signed [8*16-1:0]        x_sub_vec_in,
    input  wire signed [128*4*16-1:0]    conv_w_packed,
    input  wire signed [128*16-1:0]      conv_b_packed,
    output wire signed [16*16-1:0]       conv_x_out,
    output wire signed [16*16-1:0]       conv_z_out,
    output wire                          conv_x_valid_out,
    output wire                          conv_z_valid_out
);
    RMSNorm_InProj_Conv_Chain_Wrapper #(
        .NUM_TOKENS(NUM_TOKENS)
    ) u_chain (
        .clk(clk),
        .rst_n(rst_n),
        .en(1'b1),
        .start(1'b0),
        .frame_done(1'b0),
        .feed_idle(1'b1),
        .x_vec_in(x_vec_in),
        .gamma_vec(gamma_vec),
        .x_sub_vec_in(x_sub_vec_in),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .rms_sample_idx(),
        .rms_arm_pulse(),
        .y_out(),
        .done_x(),
        .done_z(),
        .conv_x_out(conv_x_out),
        .conv_z_out(conv_z_out),
        .conv_x_valid_out(conv_x_valid_out),
        .conv_z_valid_out(conv_z_valid_out),
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
        .beat_q_ready(),
        .beats_enq_total(),
        .beats_enq_x_dbg(),
        .beats_enq_z_dbg(),
        .scan_x_beat_ready(1'b1),
        .scan_z_beat_ready(1'b1),
        .scan_x_grp_ready(8'hFF),
        .scan_z_grp_ready(8'hFF),
        .bx_min_token_0(),
        .bx_min_token_1(),
        .bx_min_token_2(),
        .bx_min_token_3(),
        .bx_min_token_4(),
        .bx_min_token_5(),
        .bx_min_token_6(),
        .bx_min_token_7()
    );
endmodule
