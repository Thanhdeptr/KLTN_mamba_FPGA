// RMSNorm -> InProj v2 -> Conv1D -> Scan_Core_Streaming_Pipe (continuous streaming).
`timescale 1ns/1ps

module RMSNorm_InProj_Conv_Scan_Chain_Wrapper #(
    parameter DATA_WIDTH      = 16,
    parameter D_MODEL         = 64,
    parameter D_INNER         = 128,
    parameter TAPS            = 8,
    parameter LANES           = 16,
    parameter NUM_TOKENS      = 1000,
    parameter SCAN_MAX_TOKENS = 1000,
    parameter CHAIN_Q_DEPTH   = 9024,
    parameter NUM_EXEC        = 6,
    parameter Z_FIFO_DEPTH    = 256,
    parameter BEAT_Q_DEPTH    = 256,
    parameter BX_DEPTH        = 64,
    parameter XP_OVF_DEPTH    = 32,
    parameter ZP_OVF_DEPTH    = 32
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              en,
    input  wire                              start,
    input  wire                              frame_done,
    input  wire                              feed_idle,
    input  wire                              scan_clear_h,
    input  wire                              scan_sink_stall,

    input  wire [D_MODEL*DATA_WIDTH-1:0]     x_vec_in,
    input  wire [D_MODEL*DATA_WIDTH-1:0]     gamma_vec,
    input  wire signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in,

    input  wire signed [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed,
    input  wire signed [D_INNER*DATA_WIDTH-1:0]   conv_b_packed,

    output wire signed [LANES*DATA_WIDTH-1:0] y_out,
    output wire                              done_x,
    output wire                              done_z,

    output wire signed [LANES*DATA_WIDTH-1:0] conv_x_out,
    output wire signed [LANES*DATA_WIDTH-1:0] conv_z_out,
    output wire                              conv_x_valid_out,
    output wire                              conv_z_valid_out,
    output wire                              conv_ready_in,

    output wire                              chain_busy,
    output wire [15:0]                       stream_token_idx,
    output wire                              inproj_streaming,
    output wire                              feed_active,
    output wire                              feed_complete,
    output wire                              feed_ready,

    output wire [15:0]                       conv_x_capture_cnt,
    output wire [15:0]                       conv_z_capture_cnt,
    output wire [6:0]                        beat_q_count_dbg,
    output wire                              beat_q_drop,
    output wire [15:0]                       beats_enq_total,

    output wire                              scan_valid,
    output wire [15:0]                       scan_token,
    output wire [2:0]                        scan_grp,
    output wire signed [LANES*DATA_WIDTH-1:0] scan_y_vec,
    output wire                              scan_busy,
    output wire                              scan_ready,
    output wire                              conv_beat_ready
);

    wire scan_x_beat_ready;
    wire scan_z_beat_ready;
    wire [7:0] scan_x_grp_ready;
    wire [7:0] scan_z_grp_ready;
    wire [13:0] mon_q_count;
    wire        scan_stream_done;
    assign scan_stream_done = feed_complete && (mon_q_count == 14'd0) && !scan_busy;

    RMSNorm_InProj_Conv_Chain_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .TAPS(TAPS),
        .LANES(LANES),
        .NUM_TOKENS(NUM_TOKENS),
        .BEAT_Q_DEPTH(BEAT_Q_DEPTH),
        .BX_DEPTH(BX_DEPTH)
    ) u_chain (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .start(start),
        .frame_done(frame_done),
        .feed_idle(feed_idle),
        .x_vec_in(x_vec_in),
        .gamma_vec(gamma_vec),
        .x_sub_vec_in(x_sub_vec_in),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .rms_sample_idx(),
        .rms_arm_pulse(),
        .y_out(y_out),
        .done_x(done_x),
        .done_z(done_z),
        .conv_x_out(conv_x_out),
        .conv_z_out(conv_z_out),
        .conv_x_valid_out(conv_x_valid_out),
        .conv_z_valid_out(conv_z_valid_out),
        .conv_ready_in(conv_ready_in),
        .chain_busy(chain_busy),
        .stream_token_idx(stream_token_idx),
        .inproj_streaming(inproj_streaming),
        .feed_active(feed_active),
        .feed_complete(feed_complete),
        .feed_ready(feed_ready),
        .conv_x_capture_cnt(conv_x_capture_cnt),
        .conv_z_capture_cnt(conv_z_capture_cnt),
        .beat_q_count_dbg(beat_q_count_dbg),
        .beat_q_drop(beat_q_drop),
        .beats_enq_total(beats_enq_total),
        .beats_enq_x_dbg(),
        .beats_enq_z_dbg(),
        .scan_x_beat_ready(scan_x_beat_ready),
        .scan_z_beat_ready(scan_z_beat_ready),
        .scan_x_grp_ready(scan_x_grp_ready),
        .scan_z_grp_ready(scan_z_grp_ready)
    );

    Scan_Chain_Wrapper #(
        .MAX_TOKENS(SCAN_MAX_TOKENS),
        .CHAIN_Q_DEPTH(CHAIN_Q_DEPTH),
        .Z_FIFO_DEPTH(Z_FIFO_DEPTH),
        .XP_OVF_DEPTH(XP_OVF_DEPTH),
        .ZP_OVF_DEPTH(ZP_OVF_DEPTH),
        .NUM_EXEC(NUM_EXEC)
    ) u_scan (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear_h(scan_clear_h),
        .stream_done(scan_stream_done),
        .conv_x_valid(conv_x_valid_out),
        .conv_z_valid(conv_z_valid_out),
        .conv_x_grp(u_chain.u_conv.x_out_grp),
        .conv_x_token(u_chain.u_conv.x_out_token),
        .conv_z_grp(u_chain.u_conv.z_out_grp),
        .conv_z_token(u_chain.u_conv.z_out_token),
        .conv_x_vec(conv_x_out),
        .conv_z_vec(conv_z_out),
        .conv_beat_ready(conv_beat_ready_int),
        .scan_x_ready_out(scan_x_beat_ready),
        .scan_z_ready_out(scan_z_beat_ready),
        .scan_valid(scan_valid),
        .scan_token(scan_token),
        .scan_grp(scan_grp),
        .scan_y_vec(scan_y_vec),
        .scan_busy(scan_busy),
        .scan_ready(scan_ready),
        .mon_q_count(mon_q_count),
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
        .scan_x_grp_ready(scan_x_grp_ready),
        .scan_z_grp_ready(scan_z_grp_ready)
    );

    wire        scan_beat_ready_int;
    assign scan_beat_ready_int = scan_x_beat_ready & scan_z_beat_ready & !scan_sink_stall;
    assign conv_beat_ready = scan_beat_ready_int;

endmodule
