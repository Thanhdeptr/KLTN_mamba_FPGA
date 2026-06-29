`timescale 1ns/1ps

// OOC synth top: full production Mamba streaming block (chain + OutProj v2).
// Override via verilog_define: OOC_MAX_TOKENS, OOC_CHAIN_Q, OOC_NUM_EXEC,
//   OOC_Z_FIFO_DEPTH, OOC_BEAT_Q_DEPTH, OOC_BX_DEPTH
module Mamba_Streaming_Block_Wrapper_ooc_top #(
`ifdef OOC_MAX_TOKENS
    parameter NUM_TOKENS      = `OOC_MAX_TOKENS,
    parameter SCAN_MAX_TOKENS = `OOC_MAX_TOKENS,
`else
    parameter NUM_TOKENS      = 1000,
    parameter SCAN_MAX_TOKENS = 1000,
`endif
`ifdef OOC_CHAIN_Q
    parameter CHAIN_Q_DEPTH   = `OOC_CHAIN_Q,
`else
    parameter CHAIN_Q_DEPTH   = 9024,
`endif
`ifdef OOC_NUM_EXEC
    parameter NUM_EXEC        = `OOC_NUM_EXEC,
`else
    parameter NUM_EXEC        = 2,
`endif
`ifdef OOC_Z_FIFO_DEPTH
    parameter Z_FIFO_DEPTH    = `OOC_Z_FIFO_DEPTH,
`else
    parameter Z_FIFO_DEPTH    = 256,
`endif
`ifdef OOC_BEAT_Q_DEPTH
    parameter BEAT_Q_DEPTH    = `OOC_BEAT_Q_DEPTH,
`else
    parameter BEAT_Q_DEPTH    = 256,
`endif
`ifdef OOC_BX_DEPTH
    parameter BX_DEPTH        = `OOC_BX_DEPTH,
`else
    parameter BX_DEPTH        = 64,
`endif
`ifdef OOC_XP_OVF_DEPTH
    parameter XP_OVF_DEPTH    = `OOC_XP_OVF_DEPTH,
`else
    parameter XP_OVF_DEPTH    = 32,
`endif
`ifdef OOC_ZP_OVF_DEPTH
    parameter ZP_OVF_DEPTH    = `OOC_ZP_OVF_DEPTH,
`else
    parameter ZP_OVF_DEPTH    = 32,
`endif
    parameter OUTPROJ_NUM_MAC = 4,
    parameter OUTFIFO_DEPTH   = 512
) (
    input  wire clk,
    input  wire rst_n,
    input  wire [64*16-1:0]              x_vec_in,
    input  wire [64*16-1:0]              gamma_vec,
    input  wire signed [8*16-1:0]        x_sub_vec_in,
    input  wire signed [128*4*16-1:0]    conv_w_packed,
    input  wire signed [128*16-1:0]      conv_b_packed,
    output wire                          out_valid,
    output wire signed [64*16-1:0]       out_vec,
    output wire                          scan_busy,
    output wire                          outproj_busy
);
    Mamba_Streaming_Block_Wrapper #(
        .NUM_TOKENS(NUM_TOKENS),
        .SCAN_MAX_TOKENS(SCAN_MAX_TOKENS),
        .CHAIN_Q_DEPTH(CHAIN_Q_DEPTH),
        .NUM_EXEC(NUM_EXEC),
        .Z_FIFO_DEPTH(Z_FIFO_DEPTH),
        .BEAT_Q_DEPTH(BEAT_Q_DEPTH),
        .BX_DEPTH(BX_DEPTH),
        .XP_OVF_DEPTH(XP_OVF_DEPTH),
        .ZP_OVF_DEPTH(ZP_OVF_DEPTH),
        .OUTPROJ_NUM_MAC(OUTPROJ_NUM_MAC),
        .OUTFIFO_DEPTH(OUTFIFO_DEPTH)
    ) u_mamba (
        .clk(clk),
        .rst_n(rst_n),
        .en(1'b1),
        .start(1'b0),
        .frame_done(1'b0),
        .feed_idle(1'b1),
        .scan_clear_h(1'b0),
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
        .scan_valid(),
        .scan_token(),
        .scan_grp(),
        .scan_y_vec(),
        .scan_busy(scan_busy),
        .scan_ready(),
        .conv_beat_ready(),
        .out_valid(out_valid),
        .out_token(),
        .out_vec(out_vec),
        .outproj_busy(outproj_busy),
        .outproj_beat_ready(),
        .outfifo_count_dbg(),
        .outfifo_stall_dbg(),
        .outproj_sm_dbg(),
        .outproj_release_tok_dbg(),
        .outproj_asm_mask_dbg(),
        .outproj_fifo_head_tok_dbg(),
        .outproj_beats_done_dbg(),
        .outproj_feed_beat_cnt_dbg()
    );
endmodule
