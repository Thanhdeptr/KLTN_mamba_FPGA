`timescale 1ns/1ps

// OOC synth top for production Scan_Chain_Wrapper (pairing + Scan_Core_Streaming_Pipe).
module Scan_Chain_Wrapper_ooc_top #(
    parameter MAX_TOKENS    = 16,
    parameter CHAIN_Q_DEPTH = 64,
    parameter NUM_EXEC      = 6
) (
    input  wire clk,
    input  wire rst_n,
    input  wire conv_x_valid,
    input  wire conv_z_valid,
    input  wire signed [16*16-1:0] conv_x_vec,
    input  wire signed [16*16-1:0] conv_z_vec,
    output wire scan_valid,
    output wire signed [16*16-1:0] scan_y_vec,
    output wire scan_busy
);
    Scan_Chain_Wrapper #(
        .MAX_TOKENS(MAX_TOKENS),
        .CHAIN_Q_DEPTH(CHAIN_Q_DEPTH),
        .Z_FIFO_DEPTH(CHAIN_Q_DEPTH),
        .NUM_EXEC(NUM_EXEC)
    ) u_wrap (
        .clk(clk),
        .rst_n(rst_n),
        .en(1'b1),
        .clear_h(1'b0),
        .stream_done(1'b0),
        .conv_x_valid(conv_x_valid),
        .conv_z_valid(conv_z_valid),
        .conv_x_grp(3'd0),
        .conv_x_token(16'd0),
        .conv_z_grp(3'd0),
        .conv_z_token(16'd0),
        .conv_x_vec(conv_x_vec),
        .conv_z_vec(conv_z_vec),
        .bx_min_token_0(16'd0),
        .bx_min_token_1(16'd0),
        .bx_min_token_2(16'd0),
        .bx_min_token_3(16'd0),
        .bx_min_token_4(16'd0),
        .bx_min_token_5(16'd0),
        .bx_min_token_6(16'd0),
        .bx_min_token_7(16'd0),
        .conv_beat_ready(),
        .conv_x_out_ready(),
        .conv_z_out_ready(),
        .scan_x_ready_out(),
        .scan_z_ready_out(),
        .scan_valid(scan_valid),
        .scan_token(),
        .scan_grp(),
        .scan_y_vec(scan_y_vec),
        .scan_busy(scan_busy),
        .scan_ready(),
        .mon_q_count(),
        .mon_q_head_x(),
        .mon_q_head_grp(),
        .mon_q_head_tok(),
        .mon_inj_valid(),
        .mon_z_slot_mask(),
        .mon_x_skid_mask(),
        .mon_await_z_mask(),
        .mon_beat_valid(),
        .mon_ing_count(),
        .mon_x_beat_pend(),
        .mon_ex_busy_mask(),
        .mon_z_state(),
        .scan_x_grp_ready(),
        .scan_z_grp_ready()
    );
endmodule
