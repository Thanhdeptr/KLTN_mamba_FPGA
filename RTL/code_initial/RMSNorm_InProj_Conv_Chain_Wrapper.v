// RMSNorm -> In_Projection v2 -> Conv1D streaming (8 x + 8 z beats / token).
// Maps every InProj output beat to Conv valid_in / path_x / grp_idx.

`timescale 1ns/1ps

module RMSNorm_InProj_Conv_Chain_Wrapper #(
    parameter DATA_WIDTH      = 16,
    parameter D_MODEL         = 64,
    parameter D_INNER         = 128,
    parameter TAPS            = 8,
    parameter LANES           = 16,
    parameter BEATS_PER_VEC   = 128,
    parameter FRAC_BITS       = 12,
    parameter NUM_TOKENS      = 1000,
    parameter BEAT_Q_DEPTH    = 256,
    parameter BX_DEPTH        = 64
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              en,
    input  wire                              start,
    input  wire                              frame_done,
    input  wire                              feed_idle,

    input  wire [D_MODEL*DATA_WIDTH-1:0]     x_vec_in,
    input  wire [D_MODEL*DATA_WIDTH-1:0]     gamma_vec,
    input  wire signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in,

    input  wire signed [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed,
    input  wire signed [D_INNER*DATA_WIDTH-1:0]   conv_b_packed,

    output reg  [15:0]                       rms_sample_idx,
    output reg                               rms_arm_pulse,

    output wire signed [LANES*DATA_WIDTH-1:0] y_out,
    output wire                              done_x,
    output wire                              done_z,

    output wire signed [LANES*DATA_WIDTH-1:0] conv_x_out,
    output wire signed [LANES*DATA_WIDTH-1:0] conv_z_out,
    output wire                              conv_x_valid_out,
    output wire                              conv_z_valid_out,
    output wire                              conv_ready_in,

    output reg                               chain_busy,
    output reg  [15:0]                       stream_token_idx,
    output reg                               inproj_streaming,
    output reg                               feed_active,
    output reg                               feed_complete,

    output wire                              feed_ready,

    output wire [15:0]                       conv_x_capture_cnt,
    output wire [15:0]                       conv_z_capture_cnt,

    output wire [6:0]                        beat_q_count_dbg,
    output reg                               beat_q_drop,
    output wire                              beat_q_ready,
    output wire [15:0]                       beats_enq_total,
    output wire [15:0]                       beats_enq_x_dbg,
    output wire [15:0]                       beats_enq_z_dbg,

    input  wire                              scan_x_beat_ready,
    input  wire                              scan_z_beat_ready,
    input  wire [7:0]                        scan_x_grp_ready,
    input  wire [7:0]                        scan_z_grp_ready,

    output wire [15:0]                       bx_min_token_0,
    output wire [15:0]                       bx_min_token_1,
    output wire [15:0]                       bx_min_token_2,
    output wire [15:0]                       bx_min_token_3,
    output wire [15:0]                       bx_min_token_4,
    output wire [15:0]                       bx_min_token_5,
    output wire [15:0]                       bx_min_token_6,
    output wire [15:0]                       bx_min_token_7
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_BOOT_ARM  = 3'd1;
    localparam [2:0] ST_BOOT_WAIT = 3'd2;
    localparam [2:0] ST_STREAM    = 3'd3;
    localparam [2:0] ST_DONE      = 3'd4;

    reg [2:0] state;

    wire reset = ~rst_n;

    reg        rms_start;
    reg        rms_en;
    wire       rms_done;
    wire [D_MODEL*DATA_WIDTH-1:0] rms_y_vec;
    reg  [D_MODEL*DATA_WIDTH-1:0] rms_x_hold;

    RMSNorm_Unit_IntSqrt u_rms (
        .clk(clk),
        .reset(reset),
        .start(rms_start),
        .en(rms_en),
        .done(rms_done),
        .x_vec(rms_x_hold),
        .gamma_vec(gamma_vec),
        .y_vec(rms_y_vec)
    );

    reg        inproj_start;
    reg        inproj_en;
    reg        token_swap_pending;

    wire       inproj_hold;
    wire       inproj_en_eff;

    reg signed [DATA_WIDTH-1:0] norm_buf [0:D_MODEL-1];
    reg signed [DATA_WIDTH-1:0] next_buf [0:D_MODEL-1];
    reg                         next_valid;

    reg [15:0] rms_token_idx;
    reg [15:0] next_rms_idx;
    reg        rms_busy;
    reg        rms_arm_pending;
    reg [15:0] rms_arm_idx;
    reg        rms_done_d;
    reg        rms_done_capture;
    reg        frame_done_d;
    reg        feed_last_frame_done;
    reg        beat_q_arb_z;
    reg [2:0]  bx_arb_g;

    integer li;

    In_Projection_Unit_Streaming_v2 #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS(FRAC_BITS),
        .LANES(LANES),
        .TAPS(TAPS)
    ) u_inproj (
        .clk(clk),
        .rst_n(rst_n),
        .en(inproj_en_eff),
        .start(inproj_start),
        .x_sub_vec_in(x_sub_vec_in),
        .y_out(y_out),
        .done_x(done_x),
        .done_z(done_z)
    );

    wire inproj_beat =
        u_inproj.vld_pipe[6] &&
        (u_inproj.tick_cnt_pipe[6] == (TAPS - 1));

    localparam BEAT_Q_PTR_W   = (BEAT_Q_DEPTH <= 16)  ? 4 :
                                (BEAT_Q_DEPTH <= 32)  ? 5 :
                                (BEAT_Q_DEPTH <= 64)  ? 6 :
                                (BEAT_Q_DEPTH <= 128) ? 7 :
                                (BEAT_Q_DEPTH <= 256) ? 8 :
                                (BEAT_Q_DEPTH <= 512) ? 9 : 10;
    localparam BX_PTR_W       = (BX_DEPTH <= 16)  ? 4 :
                                (BX_DEPTH <= 32)  ? 5 :
                                (BX_DEPTH <= 64)  ? 6 :
                                (BX_DEPTH <= 128) ? 7 :
                                (BX_DEPTH <= 256) ? 8 : 9;
    localparam BX_CNT_W       = BX_PTR_W + 1;
    localparam [BX_PTR_W-1:0] BX_LAST = BX_DEPTH - 1;

    reg        conv_start;
    reg        conv_en;
    wire       conv_valid_in;
    wire       conv_beat_accept;
    reg        conv_path_x;
    reg [3:0]  conv_grp_idx;
    reg [15:0] conv_token_idx;
    reg [2:0]  conv_x_bank;

    reg [15:0]             inproj_active_token;
    reg [15:0]             beats_enq_cnt;
    reg [15:0]             beats_enq_x_cnt;
    reg [15:0]             beats_enq_z_cnt;
    reg                    done_z_d;
    reg [BX_PTR_W-1:0]     bx_wr   [0:7];
    reg [BX_PTR_W-1:0]     bx_rd   [0:7];
    reg [BX_CNT_W:0]       bx_cnt  [0:7];
    reg [15:0]             bx_token [0:7][0:BX_DEPTH-1];

    wire signed [LANES*DATA_WIDTH-1:0] bx_y_rd [0:7];

    (* ram_style = "block" *)
    reg signed [LANES*DATA_WIDTH-1:0] beat_q_z_mem [0:BEAT_Q_DEPTH-1];

    reg [BEAT_Q_PTR_W:0]   beat_q_x_count;
    reg [BEAT_Q_PTR_W-1:0] beat_q_z_wr;
    reg [BEAT_Q_PTR_W-1:0] beat_q_z_rd;
    reg [BEAT_Q_PTR_W:0]   beat_q_z_count;
    reg [3:0]              beat_q_z_grp   [0:BEAT_Q_DEPTH-1];
    reg [15:0]             beat_q_z_token [0:BEAT_Q_DEPTH-1];
    reg signed [LANES*DATA_WIDTH-1:0] conv_y_hold;
    reg                    conv_xfer_active;
    reg [15:0] conv_xfer_stall;

    wire conv_xfer_stalled = conv_xfer_active && !conv_beat_accept;

    wire [2:0] inproj_x_grp = u_inproj.grp_idx_pipe[6][2:0];

    wire beat_q_z_full  = (beat_q_z_count == BEAT_Q_DEPTH);
    wire beat_q_z_empty = (beat_q_z_count == {(BEAT_Q_PTR_W+1){1'b0}});
    wire beat_q_x_empty = (beat_q_x_count == {(BEAT_Q_PTR_W+1){1'b0}});
    wire inproj_beat_is_x = (u_inproj.type_pipe[6] == 1'b0);
    wire beat_q_enq_x = inproj_beat && inproj_beat_is_x &&
                        (bx_cnt[inproj_x_grp] < BX_DEPTH[BX_CNT_W:0]);
    wire beat_q_enq_z = inproj_beat && !inproj_beat_is_x && !beat_q_z_full;
    wire [2:0] beat_q_z_head_g = beat_q_z_grp[beat_q_z_rd][2:0];

    reg [2:0] bx_pick_g;
    reg       bx_pick_ok;
    integer   bx_pi;

    always @(*) begin
        bx_pick_ok = 1'b0;
        bx_pick_g  = 3'd0;
        if (scan_x_beat_ready) begin
            for (bx_pi = 0; bx_pi < 8; bx_pi = bx_pi + 1) begin
                if (!bx_pick_ok) begin
                    if ((bx_cnt[bx_arb_g + bx_pi[2:0]] != {(BX_CNT_W+1){1'b0}})) begin
                        bx_pick_ok = 1'b1;
                        bx_pick_g  = bx_arb_g + bx_pi[2:0];
                    end
                end
            end
        end
    end

    wire beat_q_can_x = bx_pick_ok;
    wire beat_q_can_z = !beat_q_z_empty && scan_z_beat_ready &&
                          scan_z_grp_ready[beat_q_z_head_g];
    // Prefer X from bx over Z beat_q: Z must not reach scan far ahead of matching X.
    wire beat_q_start_x = beat_q_can_x;
    wire beat_q_start_z = beat_q_can_z && !beat_q_can_x;

    wire beat_q_pop   = conv_xfer_active && conv_beat_accept;
    wire bx_x_collide = beat_q_enq_x && beat_q_pop && conv_path_x &&
                        (inproj_x_grp == conv_grp_idx[2:0]);
    wire [BEAT_Q_PTR_W:0] beat_q_x_count_next =
        beat_q_x_count
        + (beat_q_enq_x ? {{BEAT_Q_PTR_W{1'b0}}, 1'b1} : {(BEAT_Q_PTR_W+1){1'b0}})
        - ((beat_q_pop && conv_path_x) ? {{BEAT_Q_PTR_W{1'b0}}, 1'b1} : {(BEAT_Q_PTR_W+1){1'b0}});
    wire [BEAT_Q_PTR_W:0] beat_q_z_count_next =
        beat_q_z_count
        + (beat_q_enq_z ? {{BEAT_Q_PTR_W{1'b0}}, 1'b1} : {(BEAT_Q_PTR_W+1){1'b0}})
        - ((beat_q_pop && !conv_path_x) ? {{BEAT_Q_PTR_W{1'b0}}, 1'b1} : {(BEAT_Q_PTR_W+1){1'b0}});

    genvar bxi;
    generate
        for (bxi = 0; bxi < 8; bxi = bxi + 1) begin : bx_y_bram
            (* ram_style = "block" *)
            reg signed [LANES*DATA_WIDTH-1:0] mem [0:BX_DEPTH-1];

            always @(posedge clk) begin
                if (bx_x_collide && beat_q_enq_x && inproj_beat_is_x && (inproj_x_grp == bxi)) begin
                    if (bx_cnt[bxi] == {{BX_CNT_W{1'b0}}, 1'b1})
                        mem[0] <= y_out;
                    else
                        mem[bx_wr[bxi]] <= y_out;
                end else if (beat_q_enq_x && inproj_beat_is_x && (inproj_x_grp == bxi))
                    mem[bx_wr[bxi]] <= y_out;
            end

            assign bx_y_rd[bxi] = mem[bx_rd[bxi]];
        end
    endgenerate

    reg any_bx_full;
    integer bx_fi;
    always @(*) begin
        any_bx_full = 1'b0;
        for (bx_fi = 0; bx_fi < 8; bx_fi = bx_fi + 1)
            if (bx_cnt[bx_fi] >= BX_DEPTH[BX_CNT_W:0])
                any_bx_full = 1'b1;
    end

    wire inproj_out_vld = u_inproj.vld_pipe[6] &&
                          (u_inproj.tick_cnt_pipe[6] == (TAPS - 1));
    wire inproj_out_backpressure = inproj_out_vld &&
        (inproj_beat_is_x ? (bx_cnt[inproj_x_grp] >= BX_DEPTH[BX_CNT_W:0]) : beat_q_z_full);

    assign inproj_hold   = feed_idle | token_swap_pending | inproj_out_backpressure;
    assign inproj_en_eff = inproj_en & ~feed_idle & ~token_swap_pending &
                           ~inproj_out_backpressure;

    wire rms_backpressure =
        any_bx_full | beat_q_z_full |
        (beat_q_x_count >= (BEAT_Q_DEPTH - 8)) |
        (beat_q_z_count >= (BEAT_Q_DEPTH - 8));

    assign feed_ready = inproj_streaming & next_valid &
                        !any_bx_full & !beat_q_z_full;
    // Stall TB before bx drop: any grp at BX_DEPTH or Z beat_q full.
    assign beat_q_ready = !any_bx_full & !beat_q_z_full;

    assign bx_min_token_0 = (bx_cnt[0] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[0][bx_rd[0]] : 16'hffff;
    assign bx_min_token_1 = (bx_cnt[1] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[1][bx_rd[1]] : 16'hffff;
    assign bx_min_token_2 = (bx_cnt[2] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[2][bx_rd[2]] : 16'hffff;
    assign bx_min_token_3 = (bx_cnt[3] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[3][bx_rd[3]] : 16'hffff;
    assign bx_min_token_4 = (bx_cnt[4] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[4][bx_rd[4]] : 16'hffff;
    assign bx_min_token_5 = (bx_cnt[5] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[5][bx_rd[5]] : 16'hffff;
    assign bx_min_token_6 = (bx_cnt[6] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[6][bx_rd[6]] : 16'hffff;
    assign bx_min_token_7 = (bx_cnt[7] != {(BX_CNT_W+1){1'b0}}) ?
                            bx_token[7][bx_rd[7]] : 16'hffff;

    assign conv_valid_in = conv_xfer_active;

    Conv1D_Layer #(
        .DATA_WIDTH(DATA_WIDTH),
        .FULL_WEIGHTS(1),
        .MAX_TOKENS(NUM_TOKENS)
    ) u_conv (
        .clk(clk),
        .reset(reset),
        .start(conv_start),
        .en(conv_en),
        .valid_in(conv_valid_in),
        .path_x(conv_path_x),
        .grp_idx(conv_grp_idx),
        .token_idx(conv_token_idx),
        .valid_out(),
        .x_valid_out(conv_x_valid_out),
        .z_valid_out(conv_z_valid_out),
        .ready_in(conv_ready_in),
        .x_in_vec(conv_y_hold),
        .weights_vec({(LANES*4*DATA_WIDTH){1'b0}}),
        .bias_vec({(LANES*DATA_WIDTH){1'b0}}),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .y_out_vec(conv_x_out),
        .z_out_vec(conv_z_out),
        .x_capture_cnt(conv_x_capture_cnt),
        .z_capture_cnt(conv_z_capture_cnt),
        .beat_accept(conv_beat_accept)
    );

    task automatic arm_rms;
        input [15:0] idx;
        begin
            if (!rms_arm_pending && !rms_busy) begin
                rms_sample_idx  <= idx;
                rms_arm_idx     <= idx;
                rms_arm_pending <= 1'b1;
                rms_arm_pulse   <= 1'b1;
            end
        end
    endtask

    task automatic schedule_rms_if_ready;
        begin
            if (!rms_backpressure && !rms_busy && !next_valid && !rms_arm_pending &&
                (next_rms_idx < NUM_TOKENS))
                arm_rms(next_rms_idx);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            rms_start         <= 1'b0;
            rms_en            <= 1'b0;
            rms_sample_idx    <= 16'd0;
            rms_arm_pulse     <= 1'b0;
            rms_token_idx     <= 16'd0;
            next_rms_idx      <= 16'd0;
            rms_busy          <= 1'b0;
            rms_arm_pending   <= 1'b0;
            rms_arm_idx       <= 16'd0;
            rms_x_hold        <= {D_MODEL*DATA_WIDTH{1'b0}};
            rms_done_d        <= 1'b0;
            rms_done_capture  <= 1'b0;
            frame_done_d      <= 1'b0;
            inproj_start      <= 1'b0;
            inproj_en         <= 1'b0;
            token_swap_pending <= 1'b0;
            inproj_streaming  <= 1'b0;
            chain_busy        <= 1'b0;
            stream_token_idx  <= 16'd0;
            feed_active       <= 1'b0;
            feed_complete     <= 1'b0;
            feed_last_frame_done <= 1'b0;
            beat_q_arb_z         <= 1'b0;
            bx_arb_g             <= 3'd0;
            conv_x_bank          <= 3'd0;
            next_valid        <= 1'b0;
            conv_start        <= 1'b0;
            conv_en           <= 1'b0;
            conv_path_x       <= 1'b1;
            conv_grp_idx      <= 4'd0;
            conv_token_idx    <= 16'd0;
            conv_y_hold       <= {(LANES*DATA_WIDTH){1'b0}};
            inproj_active_token <= 16'd0;
            beats_enq_cnt       <= 16'd0;
            beats_enq_x_cnt     <= 16'd0;
            beats_enq_z_cnt     <= 16'd0;
            done_z_d            <= 1'b0;
            beat_q_x_count      <= {(BEAT_Q_PTR_W+1){1'b0}};
            beat_q_z_wr         <= {BEAT_Q_PTR_W{1'b0}};
            beat_q_z_rd         <= {BEAT_Q_PTR_W{1'b0}};
            beat_q_z_count      <= {(BEAT_Q_PTR_W+1){1'b0}};
            conv_xfer_active  <= 1'b0;
            conv_xfer_stall   <= 16'd0;
            beat_q_drop       <= 1'b0;
            for (li = 0; li < 8; li = li + 1) begin
                bx_wr[li]  <= {BX_PTR_W{1'b0}};
                bx_rd[li]  <= {BX_PTR_W{1'b0}};
                bx_cnt[li] <= {(BX_CNT_W+1){1'b0}};
            end
        end else begin
            rms_start     <= 1'b0;
            rms_arm_pulse <= 1'b0;
            rms_done_d    <= rms_done;
            rms_done_capture <= rms_done && !rms_done_d;
            frame_done_d  <= frame_done;
            done_z_d    <= done_z;
            conv_start    <= 1'b0;

            if (!en) begin
                state            <= ST_IDLE;
                chain_busy       <= 1'b0;
                feed_active      <= 1'b0;
                feed_complete    <= 1'b0;
                inproj_streaming <= 1'b0;
                inproj_start     <= 1'b0;
                inproj_en        <= 1'b0;
                token_swap_pending <= 1'b0;
                rms_en           <= 1'b0;
                conv_en          <= 1'b0;
                beat_q_x_count     <= {(BEAT_Q_PTR_W+1){1'b0}};
                beat_q_z_count     <= {(BEAT_Q_PTR_W+1){1'b0}};
                conv_xfer_active <= 1'b0;
                for (li = 0; li < 8; li = li + 1) begin
                    bx_wr[li]  <= {BX_PTR_W{1'b0}};
                    bx_rd[li]  <= {BX_PTR_W{1'b0}};
                    bx_cnt[li] <= {(BX_CNT_W+1){1'b0}};
                end
            end else begin
                rms_en    <= 1'b1;
                inproj_en <= 1'b1;
                conv_en   <= 1'b1;

                if (rms_arm_pending && !rms_busy) begin
                    rms_x_hold      <= x_vec_in;
                    rms_start       <= 1'b1;
                    rms_token_idx   <= rms_arm_idx;
                    rms_busy        <= 1'b1;
                    rms_arm_pending <= 1'b0;
                end

                if (rms_done_capture && (state != ST_BOOT_WAIT)) begin
                    for (li = 0; li < D_MODEL; li = li + 1)
                        next_buf[li] <= $signed(rms_y_vec[li*DATA_WIDTH +: DATA_WIDTH]);
                    next_valid   <= 1'b1;
                    rms_busy     <= 1'b0;
                    next_rms_idx <= rms_token_idx + 16'd1;
                end

                if (token_swap_pending && next_valid) begin
                    for (li = 0; li < D_MODEL; li = li + 1)
                        norm_buf[li] <= next_buf[li];
                    next_valid         <= 1'b0;
                    token_swap_pending <= 1'b0;
                    stream_token_idx   <= stream_token_idx + 16'd1;
                    schedule_rms_if_ready();
                end

                if (frame_done && !frame_done_d && (state == ST_STREAM)) begin
                    if (stream_token_idx + 16'd1 >= NUM_TOKENS) begin
                        feed_last_frame_done <= 1'b1;
                        feed_active          <= 1'b0;
                        inproj_start         <= 1'b0;
                        token_swap_pending   <= 1'b0;
                    end else if (next_valid) begin
                        for (li = 0; li < D_MODEL; li = li + 1)
                            norm_buf[li] <= next_buf[li];
                        next_valid         <= 1'b0;
                        token_swap_pending <= 1'b0;
                        stream_token_idx   <= stream_token_idx + 16'd1;
                        schedule_rms_if_ready();
                    end else begin
                        token_swap_pending <= 1'b1;
                    end
                end

                if (bx_x_collide) begin
                    // Atomic enq+pop same grp/cycle: avoid NBA pop overwriting enq on bx_cnt.
                    beats_enq_cnt   <= beats_enq_cnt + 16'd1;
                    beats_enq_x_cnt <= beats_enq_x_cnt + 16'd1;
                    if (bx_cnt[inproj_x_grp] == {{BX_CNT_W{1'b0}}, 1'b1}) begin
                        bx_token[inproj_x_grp][0] <= inproj_active_token;
                        bx_rd[inproj_x_grp] <= {BX_PTR_W{1'b0}};
                        bx_wr[inproj_x_grp] <= {{(BX_PTR_W-1){1'b0}}, 1'b1};
                        bx_cnt[inproj_x_grp] <= {{BX_CNT_W{1'b0}}, 1'b1};
                    end else begin
                        bx_token[inproj_x_grp][bx_wr[inproj_x_grp]] <= inproj_active_token;
                        bx_rd[inproj_x_grp] <=
                            (bx_rd[inproj_x_grp] == BX_LAST) ?
                            {BX_PTR_W{1'b0}} :
                            bx_rd[inproj_x_grp] + {{(BX_PTR_W-1){1'b0}}, 1'b1};
                        bx_wr[inproj_x_grp] <=
                            (bx_wr[inproj_x_grp] == BX_LAST) ?
                            {BX_PTR_W{1'b0}} :
                            bx_wr[inproj_x_grp] + {{(BX_PTR_W-1){1'b0}}, 1'b1};
                    end
                end else if (beat_q_enq_x) begin
                    bx_token[inproj_x_grp][bx_wr[inproj_x_grp]] <= inproj_active_token;
                    if (bx_cnt[inproj_x_grp] == {(BX_CNT_W+1){1'b0}})
                        bx_rd[inproj_x_grp] <= bx_wr[inproj_x_grp];
                    bx_wr[inproj_x_grp] <= (bx_wr[inproj_x_grp] == BX_LAST) ?
                                          {BX_PTR_W{1'b0}} :
                                          bx_wr[inproj_x_grp] + {{(BX_PTR_W-1){1'b0}}, 1'b1};
                    bx_cnt[inproj_x_grp] <= bx_cnt[inproj_x_grp] + {{BX_CNT_W{1'b0}}, 1'b1};
                    beats_enq_cnt   <= beats_enq_cnt + 16'd1;
                    beats_enq_x_cnt <= beats_enq_x_cnt + 16'd1;
                end else if (inproj_beat && inproj_beat_is_x &&
                              (bx_cnt[inproj_x_grp] >= BX_DEPTH[BX_CNT_W:0]))
                    beat_q_drop <= 1'b1;

                if (beat_q_enq_z) begin
                    if (beat_q_z_count == {(BEAT_Q_PTR_W+1){1'b0}})
                        beat_q_z_rd <= beat_q_z_wr;
                    beat_q_z_mem[beat_q_z_wr]     <= y_out;
                    beat_q_z_grp[beat_q_z_wr]   <= u_inproj.grp_idx_pipe[6];
                    beat_q_z_token[beat_q_z_wr] <= inproj_active_token;
                    beat_q_z_wr <= beat_q_z_wr + {{(BEAT_Q_PTR_W-1){1'b0}}, 1'b1};
                    beats_enq_cnt   <= beats_enq_cnt + 16'd1;
                    beats_enq_z_cnt <= beats_enq_z_cnt + 16'd1;
                end else if (inproj_beat && !inproj_beat_is_x && beat_q_z_full)
                    beat_q_drop <= 1'b1;

                if (done_z && !done_z_d)
                    inproj_active_token <= inproj_active_token + 16'd1;

                if (beat_q_pop) begin
                    conv_xfer_active <= 1'b0;
                    conv_xfer_stall  <= 8'd0;
                    if (conv_path_x) begin
                        if (!bx_x_collide) begin
                            if (bx_cnt[conv_grp_idx[2:0]] == {{BX_CNT_W{1'b0}}, 1'b1}) begin
                                bx_rd[conv_grp_idx[2:0]] <= {BX_PTR_W{1'b0}};
                                bx_wr[conv_grp_idx[2:0]] <= {BX_PTR_W{1'b0}};
                            end else
                                bx_rd[conv_grp_idx[2:0]] <=
                                    (bx_rd[conv_grp_idx[2:0]] == BX_LAST) ?
                                    {BX_PTR_W{1'b0}} :
                                    bx_rd[conv_grp_idx[2:0]] + {{(BX_PTR_W-1){1'b0}}, 1'b1};
                            bx_cnt[conv_grp_idx[2:0]] <= bx_cnt[conv_grp_idx[2:0]] - {{BX_CNT_W{1'b0}}, 1'b1};
                        end
                    end else begin
                        if (beat_q_z_count_next == {(BEAT_Q_PTR_W+1){1'b0}}) begin
                            beat_q_z_rd <= {BEAT_Q_PTR_W{1'b0}};
                            beat_q_z_wr <= {BEAT_Q_PTR_W{1'b0}};
                        end else
                            beat_q_z_rd <= beat_q_z_rd + {{(BEAT_Q_PTR_W-1){1'b0}}, 1'b1};
                    end
                end else if (conv_xfer_stalled) begin
                    if (conv_xfer_stall == 16'd2048)
                        conv_xfer_active <= 1'b0;
                    conv_xfer_stall <= conv_xfer_stall + 16'd1;
                end else begin
                    conv_xfer_stall <= 16'd0;
                    if (beat_q_start_x) begin
                        conv_path_x      <= 1'b1;
                        conv_grp_idx     <= {1'b0, bx_pick_g};
                        conv_token_idx   <= bx_token[bx_pick_g][bx_rd[bx_pick_g]];
                        conv_y_hold      <= bx_y_rd[bx_pick_g];
                        conv_xfer_active <= 1'b1;
                        beat_q_arb_z     <= 1'b1;
                        bx_arb_g         <= bx_pick_g + 3'd1;
                    end else if (beat_q_start_z) begin
                        conv_path_x    <= 1'b0;
                        conv_grp_idx   <= beat_q_z_grp[beat_q_z_rd];
                        conv_token_idx <= beat_q_z_token[beat_q_z_rd];
                        conv_y_hold    <= beat_q_z_mem[beat_q_z_rd];
                        conv_xfer_active <= 1'b1;
                        beat_q_arb_z   <= 1'b0;
                    end
                end

                beat_q_x_count <= beat_q_x_count_next;
                beat_q_z_count <= beat_q_z_count_next;

                case (state)
                    ST_IDLE: begin
                        chain_busy       <= 1'b0;
                        feed_active      <= 1'b0;
                        inproj_streaming <= 1'b0;
                        inproj_start     <= 1'b0;
                        if (start) begin
                            chain_busy       <= 1'b1;
                            stream_token_idx <= 16'd0;
                            rms_token_idx    <= 16'd0;
                            next_rms_idx     <= 16'd0;
                            next_valid       <= 1'b0;
                            conv_start       <= 1'b1;
                            state            <= ST_BOOT_ARM;
                        end
                    end

                    ST_BOOT_ARM: begin
                        arm_rms(16'd0);
                        next_rms_idx <= 16'd1;
                        state        <= ST_BOOT_WAIT;
                    end

                    ST_BOOT_WAIT: begin
                        if (rms_done_capture) begin
                            for (li = 0; li < D_MODEL; li = li + 1)
                                norm_buf[li] <= $signed(rms_y_vec[li*DATA_WIDTH +: DATA_WIDTH]);
                            rms_busy         <= 1'b0;
                            stream_token_idx <= 16'd0;
                            inproj_start     <= 1'b1;
                            inproj_streaming <= 1'b1;
                            inproj_active_token <= 16'd0;
                            feed_active      <= 1'b1;
                            schedule_rms_if_ready();
                            state            <= ST_STREAM;
                        end
                    end

                    ST_STREAM: begin
                        schedule_rms_if_ready();
                        if (feed_last_frame_done && beat_q_x_empty && beat_q_z_empty &&
                            !conv_xfer_active)
                            state <= ST_DONE;
                    end

                    ST_DONE: begin
                        feed_active      <= 1'b0;
                        inproj_streaming <= 1'b0;
                        feed_complete    <= 1'b1;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

    wire [6:0] beat_q_total_count = beat_q_x_count + beat_q_z_count;
    assign beat_q_count_dbg = beat_q_total_count;
    assign beats_enq_total  = beats_enq_cnt;
    assign beats_enq_x_dbg  = beats_enq_x_cnt;
    assign beats_enq_z_dbg  = beats_enq_z_cnt;

endmodule
