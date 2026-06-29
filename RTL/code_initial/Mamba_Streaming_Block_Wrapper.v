`timescale 1ns/1ps
// Production Mamba block: RMSNorm -> InProj v2 -> Conv -> Scan (streaming) -> OutProj v2.
`include "_parameter.v"

module Mamba_Streaming_Block_Wrapper #(
    parameter DATA_WIDTH      = 16,
    parameter D_MODEL         = 64,
    parameter D_INNER         = 128,
    parameter D_STATE         = 16,
    parameter TAPS            = 8,
    parameter LANES           = 16,
    parameter NUM_GRP         = 8,
    parameter NUM_TOKENS      = 1000,
    parameter SCAN_MAX_TOKENS = 1000,
    parameter CHAIN_Q_DEPTH   = 9024,
    parameter NUM_EXEC        = 6,
    parameter OUTPROJ_NUM_MAC = 4,
    parameter OUTFIFO_DEPTH   = 512,
    parameter OUTFIFO_PTR_W   = 9,
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

    input  wire [D_MODEL*DATA_WIDTH-1:0]     x_vec_in,
    input  wire [D_MODEL*DATA_WIDTH-1:0]     gamma_vec,
    input  wire signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in,

    input  wire signed [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed,
    input  wire signed [D_INNER*DATA_WIDTH-1:0]   conv_b_packed,
    input  wire [D_MODEL*D_INNER*DATA_WIDTH-1:0]  outproj_w_packed,

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
    output wire                              conv_beat_ready,

    output wire                              out_valid,
    output wire [15:0]                       out_token,
    output wire signed [D_MODEL*DATA_WIDTH-1:0] out_vec,
    output wire                              outproj_busy,
    output wire                              outproj_beat_ready,

    output wire [OUTFIFO_PTR_W:0]            outfifo_count_dbg,
    output wire                              outfifo_stall_dbg,

    // OutProj feeder debug (tie off if unused)
    output wire [1:0]                        outproj_sm_dbg,
    output wire [15:0]                       outproj_release_tok_dbg,
    output wire [NUM_GRP-1:0]                outproj_asm_mask_dbg,
    output wire [15:0]                       outproj_fifo_head_tok_dbg,
    output wire                              outproj_beats_done_dbg,
    output wire [7:0]                        outproj_feed_beat_cnt_dbg
);

    wire scan_sink_stall;
    wire conv_beat_ready_core;

    RMSNorm_InProj_Conv_Scan_Chain_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .TAPS(TAPS),
        .LANES(LANES),
        .NUM_TOKENS(NUM_TOKENS),
        .SCAN_MAX_TOKENS(SCAN_MAX_TOKENS),
        .CHAIN_Q_DEPTH(CHAIN_Q_DEPTH),
        .NUM_EXEC(NUM_EXEC),
        .Z_FIFO_DEPTH(Z_FIFO_DEPTH),
        .BEAT_Q_DEPTH(BEAT_Q_DEPTH),
        .BX_DEPTH(BX_DEPTH),
        .XP_OVF_DEPTH(XP_OVF_DEPTH),
        .ZP_OVF_DEPTH(ZP_OVF_DEPTH)
    ) u_chain (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .start(start),
        .frame_done(frame_done),
        .feed_idle(feed_idle),
        .scan_clear_h(scan_clear_h),
        .scan_sink_stall(scan_sink_stall),
        .x_vec_in(x_vec_in),
        .gamma_vec(gamma_vec),
        .x_sub_vec_in(x_sub_vec_in),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
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
        .scan_valid(scan_valid),
        .scan_token(scan_token),
        .scan_grp(scan_grp),
        .scan_y_vec(scan_y_vec),
        .scan_busy(scan_busy),
        .scan_ready(scan_ready),
        .conv_beat_ready(conv_beat_ready_core)
    );

    assign conv_beat_ready = conv_beat_ready_core;

    wire outproj_beat_valid_w;
    wire [15:0] outproj_beat_token_w;
    wire [2:0] outproj_beat_grp_w;
    wire signed [LANES*DATA_WIDTH-1:0] outproj_beat_vec_w;
    wire [OUTFIFO_PTR_W:0] outfifo_count_w;
    wire outfifo_stall_w;
    wire [1:0] outproj_sm_w;
    wire [15:0] outproj_release_tok_w;
    wire [NUM_GRP-1:0] outproj_asm_mask_w;
    wire [15:0] outproj_fifo_head_tok_w;
    wire outproj_beats_done_w;
    wire [7:0] outproj_feed_beat_cnt_w;

    Out_Projection_Streaming_v2 #(
        .DATA_WIDTH(DATA_WIDTH),
        .LANES(LANES),
        .D_IN(D_INNER),
        .D_OUT(D_MODEL),
        .NUM_GRP(NUM_GRP),
        .NUM_MAC(OUTPROJ_NUM_MAC)
    ) u_outproj (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .beat_valid(outproj_beat_valid_w),
        .beat_token(outproj_beat_token_w),
        .beat_grp(outproj_beat_grp_w),
        .beat_vec(outproj_beat_vec_w),
        .beat_ready(outproj_beat_ready),
        .out_valid(out_valid),
        .out_token(out_token),
        .out_vec(out_vec),
        .busy(outproj_busy)
    );

    generate
        if (NUM_EXEC == 1) begin : g_direct
            assign scan_sink_stall = scan_valid && en && !outproj_beat_ready;
            assign outfifo_count_w   = {(OUTFIFO_PTR_W+1){1'b0}};
            assign outfifo_stall_w   = scan_sink_stall;
            assign outproj_sm_w            = 2'd0;
            assign outproj_release_tok_w   = 16'd0;
            assign outproj_asm_mask_w      = {NUM_GRP{1'b0}};
            assign outproj_fifo_head_tok_w = 16'd0;
            assign outproj_beats_done_w    = 1'b0;
            assign outproj_feed_beat_cnt_w = 8'd0;

            reg beat_valid_r;
            reg [15:0] beat_token_r;
            reg [2:0] beat_grp_r;
            reg signed [LANES*DATA_WIDTH-1:0] beat_vec_r;

            wire beat_xfer = scan_valid && en && outproj_beat_ready;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    beat_valid_r <= 1'b0;
                    beat_token_r <= 16'd0;
                    beat_grp_r   <= 3'd0;
                    beat_vec_r   <= {(LANES*DATA_WIDTH){1'b0}};
                end else begin
                    beat_valid_r <= 1'b0;
                    if (beat_xfer) begin
                        beat_valid_r <= 1'b1;
                        beat_token_r <= scan_token;
                        beat_grp_r   <= scan_grp;
                        beat_vec_r   <= scan_y_vec;
                    end
                end
            end

            assign outproj_beat_valid_w = beat_valid_r;
            assign outproj_beat_token_w = beat_token_r;
            assign outproj_beat_grp_w   = beat_grp_r;
            assign outproj_beat_vec_w   = beat_vec_r;
        end else begin : g_reorder
            // Scan beats may interleave tokens when NUM_EXEC>1.
            // FIFO buffers beats; drain only release_tok into OutProj (scan arrival order).
            localparam [OUTFIFO_PTR_W-1:0] FIFO_LAST = OUTFIFO_DEPTH - 1;
            localparam OS_DRAIN = 2'd0;
            localparam OS_WAIT  = 2'd1;

            reg [OUTFIFO_PTR_W:0]           fifo_count;
            reg [OUTFIFO_PTR_W-1:0]         fifo_wr;
            reg [OUTFIFO_PTR_W-1:0]         fifo_rd;
            reg [15:0]                      fifo_tok [0:OUTFIFO_DEPTH-1];
            reg [2:0]                       fifo_grp [0:OUTFIFO_DEPTH-1];
            (* ram_style = "block" *)
            reg signed [DATA_WIDTH-1:0]     fifo_vec_lane [0:LANES-1][0:OUTFIFO_DEPTH-1];
            integer                         lane_i;
            reg [1:0]                         out_sm;
            reg [15:0]                        release_tok;
            reg [3:0]                         rel_feed_cnt;
            reg                               out_valid_q;
            wire                              out_valid_rise;

            reg                                 beat_valid_r;
            reg [15:0]                          beat_token_r;
            reg [2:0]                           beat_grp_r;
            reg signed [LANES*DATA_WIDTH-1:0] beat_vec_r;

            wire fifo_full  = (fifo_count == OUTFIFO_DEPTH[OUTFIFO_PTR_W:0]);
            wire fifo_empty = (fifo_count == {(OUTFIFO_PTR_W+1){1'b0}});
            wire fifo_push  = scan_valid && en && !fifo_full;
            wire fifo_head_match = !fifo_empty && (fifo_tok[fifo_rd] == release_tok);
            wire fifo_pop   = fifo_push ? 1'b0 :
                              (out_sm == OS_DRAIN) && fifo_head_match &&
                              outproj_beat_ready && (rel_feed_cnt < NUM_GRP[3:0]);

            assign scan_sink_stall = scan_valid && en && fifo_full;
            assign outfifo_count_w = fifo_count;
            assign outfifo_stall_w = scan_sink_stall;
            assign outproj_sm_w            = out_sm;
            assign outproj_release_tok_w   = release_tok;
            assign outproj_asm_mask_w      = {NUM_GRP{1'b0}};
            assign outproj_fifo_head_tok_w = fifo_empty ? 16'hFFFF : fifo_tok[fifo_rd];
            assign outproj_beats_done_w    = (rel_feed_cnt == NUM_GRP);
            assign outproj_feed_beat_cnt_w = {4'd0, rel_feed_cnt};
            assign out_valid_rise = out_valid && !out_valid_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    fifo_count <= {(OUTFIFO_PTR_W+1){1'b0}};
                    fifo_wr    <= {OUTFIFO_PTR_W{1'b0}};
                    fifo_rd    <= {OUTFIFO_PTR_W{1'b0}};
                    out_sm        <= OS_DRAIN;
                    release_tok   <= 16'd0;
                    rel_feed_cnt  <= 4'd0;
                    out_valid_q   <= 1'b0;
                    beat_valid_r  <= 1'b0;
                    beat_token_r  <= 16'd0;
                    beat_grp_r    <= 3'd0;
                    beat_vec_r    <= {(LANES*DATA_WIDTH){1'b0}};
                end else begin
                    beat_valid_r <= 1'b0;
                    out_valid_q  <= out_valid;

                    if (fifo_push && !fifo_pop)
                        fifo_count <= fifo_count + {{OUTFIFO_PTR_W{1'b0}}, 1'b1};
                    else if (!fifo_push && fifo_pop)
                        fifo_count <= fifo_count - {{OUTFIFO_PTR_W{1'b0}}, 1'b1};

                    if (fifo_push) begin
                        fifo_tok[fifo_wr] <= scan_token;
                        fifo_grp[fifo_wr] <= scan_grp;
                        fifo_wr <= (fifo_wr == FIFO_LAST) ? {OUTFIFO_PTR_W{1'b0}} :
                                  fifo_wr + {{(OUTFIFO_PTR_W-1){1'b0}}, 1'b1};
                    end

                    if (fifo_pop) begin
                        beat_valid_r <= 1'b1;
                        beat_token_r <= fifo_tok[fifo_rd];
                        beat_grp_r   <= fifo_grp[fifo_rd];
                        rel_feed_cnt <= rel_feed_cnt + 4'd1;
                        fifo_rd <= (fifo_rd == FIFO_LAST) ? {OUTFIFO_PTR_W{1'b0}} :
                                  fifo_rd + {{(OUTFIFO_PTR_W-1){1'b0}}, 1'b1};
                    end

                    case (out_sm)
                        OS_DRAIN: begin
                            if (rel_feed_cnt == NUM_GRP)
                                out_sm <= OS_WAIT;
                        end

                        OS_WAIT: begin
                            if (out_valid_rise) begin
                                release_tok  <= release_tok + 16'd1;
                                rel_feed_cnt <= 4'd0;
                                out_sm       <= OS_DRAIN;
                            end
                        end

                        default: out_sm <= OS_DRAIN;
                    endcase
                end
            end

            assign outproj_beat_valid_w = beat_valid_r;
            assign outproj_beat_token_w = beat_token_r;
            assign outproj_beat_grp_w   = beat_grp_r;
            assign outproj_beat_vec_w   = beat_vec_r;

            always @(posedge clk) begin
                if (fifo_push) begin
                    for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1)
                        fifo_vec_lane[lane_i][fifo_wr] <=
                            scan_y_vec[lane_i*DATA_WIDTH +: DATA_WIDTH];
                end
            end

            always @(posedge clk) begin
                if (fifo_pop) begin
                    for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1)
                        beat_vec_r[lane_i*DATA_WIDTH +: DATA_WIDTH] <=
                            fifo_vec_lane[lane_i][fifo_rd];
                end
            end
        end
    endgenerate

    assign outfifo_count_dbg        = outfifo_count_w;
    assign outfifo_stall_dbg        = outfifo_stall_w;
    assign outproj_sm_dbg           = outproj_sm_w;
    assign outproj_release_tok_dbg  = outproj_release_tok_w;
    assign outproj_asm_mask_dbg     = outproj_asm_mask_w;
    assign outproj_fifo_head_tok_dbg = outproj_fifo_head_tok_w;
    assign outproj_beats_done_dbg   = outproj_beats_done_w;
    assign outproj_feed_beat_cnt_dbg = outproj_feed_beat_cnt_w;

endmodule
