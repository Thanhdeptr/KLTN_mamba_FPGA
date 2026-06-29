// In_Projection_Unit_Streaming_v3.v
// Standalone 4-lane compute core with 4-pass time-multiplexing.
// Physical multipliers: COMPUTE_LANES x TAPS = 4 x 8 = 32 DSP.
// Logical output: OUT_LANES = 16 (same interface as v2).
//
// Operation (v2-style pass 0 + TMUX passes 1-3):
//   Pass 0: overlap capture + replay (no separate INGEST wait).
//   Pass 1-3: replay input_buf. REPLAY_EXT + pass_g0_seen skip unchanged.
// Tag pipeline at stage6 runs one group ahead: logical_grp = (pipe_grp==0)?15:pipe_grp-1.
// Merge/emit uses merge_out[logical_grp]. After last replay cluster, REPLAY_EXT advances
// group_idx/tick_cnt (addr clamped) so warm pipe_grp=0 (vec15) reaches stage6; then DRAIN.
// Each pass skips cold pipe_grp=0 merge/emit before pass_g0_seen (stale prior-pass tail).

`timescale 1ns/1ps
module In_Projection_Unit_Streaming_v3 #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS = 12,
    parameter COMPUTE_LANES = 4,
    parameter OUT_LANES = 16,
    parameter TAPS = 8,
    parameter BRAM_DEPTH = 128,
    parameter BRAM_LATENCY = 1,
    parameter BASE_PD = 6,
    parameter integer SYNTH_OOC_KEEP = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire start,
    input  wire signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in,
    output reg  signed [OUT_LANES*DATA_WIDTH-1:0] y_out,
    output reg  done_x,
    output reg  done_z,
    output reg  busy,
    output wire frame_ready,
    output reg [1:0] pass_idx_out,
    output reg out_valid,
    output reg [3:0] out_grp,
    // Debug monitor ports (Section 6.1 STREAMING_DESIGN_GUIDE — sim waveform / TB log)
    output wire [2:0]  dbg_op_state,
    output wire [1:0]  dbg_pass_idx,
    output wire        dbg_vld_in,
    output wire [7:0]  dbg_replay_cnt,
    output wire [7:0]  dbg_ingest_cnt,
    output wire [7:0]  dbg_replay_addr,
    output wire        dbg_replay_ext,
    output wire        dbg_replay_hold,
    output wire [1:0]  dbg_pass_replay_guard,
    output wire        dbg_replay_reset_d,
    output wire [2:0]  dbg_tick_cnt,
    output wire [3:0]  dbg_group_idx,
    output wire [3:0]  dbg_pipe_grp_s0,
    output wire [3:0]  dbg_fetch_grp_s0,
    output wire [3:0]  dbg_pipe_grp_s6,
    output wire [3:0]  dbg_logical_grp_s6,
    output wire        dbg_vld_pipe0,
    output wire        dbg_vld_pipe1,
    output wire        dbg_vld_pipe3,
    output wire        dbg_vld_pipe6,
    output wire [2:0]  dbg_tick_pipe0,
    output wire [2:0]  dbg_tick_pipe3,
    output wire [2:0]  dbg_tick_pipe6,
    output wire [3:0]  dbg_grp_pipe6,
    output wire        dbg_pass_g0_seen,
    output wire        dbg_merge_skip,
    output wire signed [DATA_WIDTH-1:0] dbg_st0_p0_l0,
    output wire signed [DATA_WIDTH-1:0] dbg_st1_p0_l0,
    output wire signed [DATA_WIDTH-1:0] dbg_st0_p1_l0,
    output wire signed [DATA_WIDTH-1:0] dbg_st1_p1_l0,
    output wire signed [39:0] dbg_acc_l0,
    output wire signed [DATA_WIDTH-1:0] dbg_sat_l0,
    output wire        dbg_x_pipe0_zero,
    output wire signed [DATA_WIDTH-1:0] dbg_replay_tap0,
    output wire signed [DATA_WIDTH-1:0] dbg_xvec_tap0,
    output wire signed [DATA_WIDTH-1:0] dbg_pipe01_delta_l0
);

    localparam integer NUM_PASSES = OUT_LANES / COMPUTE_LANES;
    localparam integer PD = BASE_PD + BRAM_LATENCY;
    localparam integer DRAIN_CYCLES = PD + TAPS + 16;
    localparam integer REPLAY_EXT_CYCLES = PD + TAPS + 8;
    localparam integer TAG_LATENCY = BRAM_LATENCY + 4;
    localparam integer X_LATENCY = TAG_LATENCY + 2;
    localparam integer TOTAL_INPUTS = 16 * TAPS;
    localparam integer FLUSH_RESET_CYCLES = 2;
    localparam integer IDLE_WARM_CYCLES = TAG_LATENCY;
    localparam integer FLUSH_DRAIN_CYCLES = DRAIN_CYCLES + X_LATENCY;
    localparam integer INTER_TAG_HOLD_CYCLES = 7 * TAPS;
    localparam [3:0] PIPE_G0_TAG = 4'd1;

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_FLUSH  = 3'd1;
    localparam [2:0] S_REPLAY = 3'd2;
    localparam [2:0] S_DRAIN  = 3'd3;

    integer i, j, k, pi, li, ti;
    integer addr;
    reg [TAPS*DATA_WIDTH-1:0] word;

    reg [TAPS*DATA_WIDTH-1:0] bram_mem [0:OUT_LANES-1][0:BRAM_DEPTH-1];
    reg signed [TAPS*DATA_WIDTH-1:0] input_buf [0:TOTAL_INPUTS-1];
    reg signed [DATA_WIDTH-1:0] merge_out [0:15][0:OUT_LANES-1];

    reg [2:0] op_state;
    reg [1:0] pass_idx;
    reg [7:0] ingest_cnt;
    reg [7:0] replay_cnt;
    reg [5:0] drain_cnt;
    reg [5:0] flush_cnt;
    reg [3:0] idle_warm_cnt;
    reg inter_frame_pending;
    reg inter_frame_ingest;
    reg [7:0] inter_tag_hold_cnt;
    reg replay_reset;
    reg replay_reset_d;
    reg ingest_full;
    reg replay_hold;
    reg replay_started;
    reg [1:0] pass_replay_guard;
    reg replay_ext_active;
    reg [5:0] replay_ext_cnt;
    reg pass_g0_seen;
    reg pass0_to_ext;
    reg pass_cold_armed;
    reg pass_to_ext;
    reg [127:0] cap_mask;
    reg        emit_pending;
    reg [3:0]  emit_pending_grp;
    reg        emit_pending_type;

    reg [2:0] tick_cnt;
    reg [3:0] group_idx;
    reg vld_in;

    reg vld_pipe [0:PD-1];
    reg [2:0] tick_cnt_pipe [0:PD-1];
    reg [3:0] grp_idx_pipe [0:PD-1];
    reg type_pipe [0:PD-1];

    reg vld_del [0:TAG_LATENCY-1];
    reg [2:0] tick_cnt_del [0:TAG_LATENCY-1];
    reg [3:0] group_idx_del [0:TAG_LATENCY-1];
    reg type_del [0:TAG_LATENCY-1];

    reg signed [DATA_WIDTH-1:0] st0_x [0:COMPUTE_LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH-1:0] st1_x [0:COMPUTE_LANES-1][0:TAPS-1];
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_pipe [0:X_LATENCY-1];
    reg signed [DATA_WIDTH-1:0] st0_x_pipe [0:PD][0:COMPUTE_LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH-1:0] st1_x_pipe [0:PD][0:COMPUTE_LANES-1][0:TAPS-1];

    reg signed [DATA_WIDTH*2-1:0] mult_reg [0:COMPUTE_LANES-1][0:TAPS-1];
    reg signed [39:0] st2_sum_reg [0:COMPUTE_LANES-1];
    wire signed [39:0] st2_sum_wire [0:COMPUTE_LANES-1];

    reg signed [39:0] acc_reg [0:COMPUTE_LANES-1];
    reg signed [39:0] acc_final_reg [0:COMPUTE_LANES-1];
    reg signed [DATA_WIDTH-1:0] stage4_sat_out [0:COMPUTE_LANES-1];

    wire [3:0] bank_base;
    assign bank_base = {pass_idx, 2'b00};

    function signed [DATA_WIDTH-1:0] sat_to_16;
        input signed [39:0] inv;
        reg signed [39:0] tmp;
        begin
            tmp = inv >>> FRAC_BITS;
            if (tmp > $signed({1'b0, {(DATA_WIDTH-1){1'b1}}}))
                sat_to_16 = $signed({1'b0, {(DATA_WIDTH-1){1'b1}}});
            else if (tmp < -($signed(1 << (DATA_WIDTH-1))))
                sat_to_16 = -($signed(1 << (DATA_WIDTH-1)));
            else
                sat_to_16 = tmp[DATA_WIDTH-1:0];
        end
    endfunction

    function [3:0] pipe_grp_to_logical;
        input [3:0] pipe_grp;
        begin
            pipe_grp_to_logical = (pipe_grp == 4'd0) ? 4'd15 : (pipe_grp - 4'd1);
        end
    endfunction

    wire [3:0] pipe_grp_s0;
    wire [3:0] fetch_grp_s0;
    assign pipe_grp_s0 = grp_idx_pipe[0];
    assign fetch_grp_s0 = pipe_grp_to_logical(pipe_grp_s0);
    wire [3:0] pipe_grp_s6;
    wire [3:0] merge_grp_s6;
    assign pipe_grp_s6 = grp_idx_pipe[6];
    assign merge_grp_s6 = pipe_grp_to_logical(pipe_grp_s6);
    wire [3:0] logical_grp_s6;
    assign logical_grp_s6 = merge_grp_s6;

    initial begin
        op_state = S_IDLE;
        pass_idx = 0;
        ingest_cnt = 0;
        busy = 0;
        done_x = 0;
        done_z = 0;
        pass_idx_out = 0;
        ingest_full = 0;
        replay_hold = 0;
        replay_started = 0;
        pass_replay_guard = 0;
        replay_ext_active = 0;
        replay_ext_cnt = 0;
        pass_g0_seen = 0;
        pass0_to_ext = 0;
        pass_cold_armed = 0;
        pass_to_ext = 0;
        emit_pending = 0;
        emit_pending_grp = 0;
        tick_cnt = 0;
        group_idx = 0;
        vld_in = 0;
        replay_cnt = 0;
        drain_cnt = 0;
        flush_cnt = 0;
        idle_warm_cnt = TAG_LATENCY;
        inter_frame_pending = 0;
        inter_frame_ingest = 0;
        inter_tag_hold_cnt = 0;
        replay_reset_d = 0;
    end

    task automatic begin_replay_pass;
        begin
            tick_cnt <= 0;
            group_idx <= 0;
            vld_in <= 0;
            replay_cnt <= 0;
            replay_hold <= 1'b1;
            replay_started <= 1'b0;
            pass_replay_guard <= 2'd2;
            replay_reset <= 1'b1;
            replay_ext_active <= 1'b0;
            replay_ext_cnt <= 6'd0;
            pass_g0_seen <= 1'b0;
            pass_cold_armed <= 1'b1;
        end
    endtask

    task automatic advance_replay_tag;
        begin
            if (tick_cnt == (TAPS - 1)) begin
                tick_cnt <= 3'd0;
                group_idx <= (group_idx == 4'd15) ? 4'd0 : group_idx + 1'b1;
            end else begin
                tick_cnt <= tick_cnt + 1'b1;
            end
        end
    endtask

    reg idle_pipe_drain;
    integer pi_drain;
    always @* begin
        idle_pipe_drain = 1'b0;
        if (op_state == S_IDLE || op_state == S_FLUSH) begin
            for (pi_drain = 0; pi_drain < PD; pi_drain = pi_drain + 1)
                if (vld_pipe[pi_drain])
                    idle_pipe_drain = 1'b1;
            for (pi_drain = 0; pi_drain < TAG_LATENCY; pi_drain = pi_drain + 1)
                if (vld_del[pi_drain])
                    idle_pipe_drain = 1'b1;
        end
    end

    assign frame_ready = en && rst_n && (op_state == S_IDLE) && !busy &&
                         !idle_pipe_drain && !replay_reset && !replay_reset_d &&
                         (idle_warm_cnt >= IDLE_WARM_CYCLES);

    always @(posedge clk) begin
        replay_reset_d <= replay_reset;
        replay_reset <= 1'b0;
        if (!rst_n) begin
            op_state <= S_IDLE;
            pass_idx <= 0;
            ingest_cnt <= 0;
            busy <= 0;
            pass_idx_out <= 0;
            replay_reset_d <= 1'b0;
            ingest_full <= 1'b0;
            tick_cnt <= 0;
            group_idx <= 0;
            vld_in <= 0;
            replay_cnt <= 0;
            drain_cnt <= 0;
            flush_cnt <= 6'd0;
            idle_warm_cnt <= IDLE_WARM_CYCLES;
            inter_frame_pending <= 1'b0;
            inter_frame_ingest <= 1'b0;
            inter_tag_hold_cnt <= 8'd0;
            replay_hold <= 1'b0;
            replay_started <= 1'b0;
            pass_replay_guard <= 2'd0;
            replay_ext_active <= 1'b0;
            replay_ext_cnt <= 6'd0;
            pass_g0_seen <= 1'b0;
            pass0_to_ext <= 1'b0;
            pass_cold_armed <= 1'b0;
            pass_to_ext <= 1'b0;
            cap_mask <= 128'd0;
            emit_pending <= 1'b0;
            emit_pending_grp <= 4'd0;
            out_grp <= 4'd0;
        end else if (!en) begin
            op_state <= op_state;
        end else begin
            pass_idx_out <= pass_idx;
            case (op_state)
                S_IDLE: begin
                    busy <= idle_pipe_drain || replay_reset || replay_reset_d ||
                            (idle_warm_cnt < IDLE_WARM_CYCLES);
                    pass_idx <= 0;
                    vld_in <= 1'b0;
                    ingest_full <= 1'b0;
                    ingest_cnt <= 0;
                    replay_cnt <= 0;
                    drain_cnt <= 0;
                    replay_hold <= 1'b0;
                    replay_started <= 1'b0;
                    pass_replay_guard <= 2'd0;
                    replay_ext_active <= 1'b0;
                    replay_ext_cnt <= 6'd0;
                    pass0_to_ext <= 1'b0;
                    pass_to_ext <= 1'b0;
                    tick_cnt <= 0;
                    group_idx <= 0;
                    cap_mask <= 128'd0;
                    pass_g0_seen <= 1'b0;
                    pass_cold_armed <= 1'b0;
                    emit_pending <= 1'b0;
                    if (idle_warm_cnt < IDLE_WARM_CYCLES)
                        idle_warm_cnt <= idle_warm_cnt + 1'b1;
                    if (start && (idle_warm_cnt >= IDLE_WARM_CYCLES) &&
                        !idle_pipe_drain && !replay_reset && !replay_reset_d &&
                        !ingest_full) begin
                        op_state <= S_REPLAY;
                        busy <= 1'b1;
                        pass_idx <= 0;
                        tick_cnt <= 3'd0;
                        group_idx <= 4'd0;
                        vld_in <= 1'b1;
                        ingest_cnt <= 8'd0;
                        ingest_full <= 1'b0;
                        replay_cnt <= 0;
                        replay_hold <= 1'b0;
                        replay_started <= 1'b0;
                        pass_replay_guard <= 2'd0;
                        replay_ext_active <= 1'b0;
                        replay_ext_cnt <= 6'd0;
                        pass_g0_seen <= 1'b0;
                        pass0_to_ext <= 1'b0;
                        pass_cold_armed <= 1'b0;
                        pass_to_ext <= 1'b0;
                        cap_mask <= 128'd0;
                        emit_pending <= 1'b0;
                        idle_warm_cnt <= 4'd0;
                        if (inter_frame_pending) begin
                            inter_tag_hold_cnt <= INTER_TAG_HOLD_CYCLES;
                            inter_frame_ingest <= 1'b1;
                        end else begin
                            inter_tag_hold_cnt <= 8'd0;
                            inter_frame_ingest <= 1'b0;
                        end
                        inter_frame_pending <= 1'b0;
                    end
                end

                S_FLUSH: begin
                    busy <= 1'b1;
                    vld_in <= 1'b0;
                    inter_frame_pending <= 1'b1;
                    if (flush_cnt < FLUSH_RESET_CYCLES) begin
                        replay_reset <= 1'b1;
                        flush_cnt <= flush_cnt + 1'b1;
                    end else if (!idle_pipe_drain && !replay_reset_d) begin
                        op_state <= S_IDLE;
                        flush_cnt <= 6'd0;
                        idle_warm_cnt <= IDLE_WARM_CYCLES;
                    end else if (flush_cnt >= FLUSH_RESET_CYCLES + FLUSH_DRAIN_CYCLES) begin
                        replay_reset <= 1'b1;
                        op_state <= S_IDLE;
                        flush_cnt <= 6'd0;
                        idle_warm_cnt <= IDLE_WARM_CYCLES;
                    end else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
                end

                S_REPLAY: begin
                    busy <= 1'b1;
                    if (pass_idx == 2'd0) begin
                        if (replay_ext_active) begin
                            vld_in <= 1'b1;
                            advance_replay_tag();
                            if (replay_ext_cnt == REPLAY_EXT_CYCLES - 1) begin
                                replay_ext_active <= 1'b0;
                                op_state <= S_DRAIN;
                                drain_cnt <= 6'd0;
                                vld_in <= 1'b0;
                            end else begin
                                replay_ext_cnt <= replay_ext_cnt + 1'b1;
                            end
                        end else if (start && !ingest_full) begin
                            if (inter_tag_hold_cnt != 8'd0) begin
                                vld_in <= 1'b0;
                                inter_tag_hold_cnt <= inter_tag_hold_cnt - 1'b1;
                            end else begin
                                vld_in <= 1'b1;
                                if (vld_in)
                                    advance_replay_tag();
                            end
                        end else if (!ingest_full && inter_frame_ingest) begin
                            vld_in <= 1'b1;
                            if (vld_in)
                                advance_replay_tag();
                        end else if (!ingest_full) begin
                            vld_in <= 1'b0;
                        end else if (!replay_ext_active) begin
                            vld_in <= 1'b0;
                            inter_frame_ingest <= 1'b0;
                            pass0_to_ext <= 1'b1;
                            op_state <= S_DRAIN;
                            drain_cnt <= 6'd0;
                        end
                    end else if (replay_ext_active) begin
                        vld_in <= 1'b1;
                        advance_replay_tag();
                        if (replay_ext_cnt == REPLAY_EXT_CYCLES - 1) begin
                            replay_ext_active <= 1'b0;
                            op_state <= S_DRAIN;
                            drain_cnt <= 6'd0;
                            vld_in <= 1'b0;
                        end else begin
                            replay_ext_cnt <= replay_ext_cnt + 1'b1;
                        end
                    end else if (pass_replay_guard != 2'd0) begin
                        pass_replay_guard <= pass_replay_guard - 1'b1;
                        vld_in <= replay_hold ? 1'b1 : 1'b0;
                    end else if (replay_hold) begin
                        replay_hold <= 1'b0;
                        vld_in <= 1'b1;
                    end else begin
                        replay_started <= 1'b1;
                        vld_in <= 1'b1;
                        if (replay_cnt != TOTAL_INPUTS - 1) begin
                            replay_cnt <= replay_cnt + 1'b1;
                            advance_replay_tag();
                        end else if (pass_idx == 2'd3) begin
                            pass_to_ext <= 1'b1;
                            op_state <= S_DRAIN;
                            drain_cnt <= 6'd0;
                            vld_in <= 1'b0;
                        end else begin
                            replay_ext_active <= 1'b1;
                            replay_ext_cnt <= 6'd0;
                            advance_replay_tag();
                        end
                    end
                end

                S_DRAIN: begin
                    busy <= 1'b1;
                    vld_in <= 1'b0;
                    if (drain_cnt == DRAIN_CYCLES) begin
                        if (pass0_to_ext && pass_idx == 2'd0) begin
                            pass0_to_ext <= 1'b0;
                            op_state <= S_REPLAY;
                            replay_ext_active <= 1'b1;
                            replay_ext_cnt <= 6'd0;
                            advance_replay_tag();
                        end else if (pass_to_ext) begin
                            pass_to_ext <= 1'b0;
                            op_state <= S_REPLAY;
                            replay_ext_active <= 1'b1;
                            replay_ext_cnt <= 6'd0;
                            advance_replay_tag();
                        end else if (pass_idx == NUM_PASSES - 1) begin
                            op_state <= S_FLUSH;
                            busy <= 1'b1;
                            pass_idx <= 0;
                            ingest_cnt <= 8'd0;
                            ingest_full <= 1'b0;
                            flush_cnt <= 6'd0;
                            replay_reset <= 1'b1;
                        end else begin
                            pass_idx <= pass_idx + 1'b1;
                            op_state <= S_REPLAY;
                            begin_replay_pass();
                        end
                    end else begin
                        drain_cnt <= drain_cnt + 1;
                    end
                end

                default: op_state <= S_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < TOTAL_INPUTS; i = i + 1)
                input_buf[i] <= 0;
            for (i = 0; i < OUT_LANES; i = i + 1)
                for (j = 0; j < OUT_LANES; j = j + 1)
                    merge_out[i][j] <= 0;
        end else if (en && op_state == S_IDLE && start) begin
            for (i = 0; i < OUT_LANES; i = i + 1)
                for (j = 0; j < OUT_LANES; j = j + 1)
                    merge_out[i][j] <= 0;
            for (i = 0; i < TOTAL_INPUTS; i = i + 1)
                input_buf[i] <= 0;
        end
        if (!rst_n || replay_reset || replay_reset_d) begin
            for (i = 0; i < COMPUTE_LANES; i = i + 1) begin
                acc_reg[i] <= 0;
                acc_final_reg[i] <= 0;
                st2_sum_reg[i] <= 0;
                stage4_sat_out[i] <= 0;
                for (j = 0; j < TAPS; j = j + 1) begin
                    mult_reg[i][j] <= 0;
                    st0_x[i][j] <= 0;
                    st1_x[i][j] <= 0;
                end
            end
            for (pi = 0; pi <= PD; pi = pi + 1) begin
                for (li = 0; li < COMPUTE_LANES; li = li + 1) begin
                    for (ti = 0; ti < TAPS; ti = ti + 1) begin
                        st0_x_pipe[pi][li][ti] <= 0;
                        st1_x_pipe[pi][li][ti] <= 0;
                    end
                end
            end
            for (i = 0; i < PD; i = i + 1) begin
                vld_pipe[i] <= 0;
                tick_cnt_pipe[i] <= 0;
                grp_idx_pipe[i] <= 0;
                type_pipe[i] <= 0;
            end
            for (i = 0; i < TAG_LATENCY; i = i + 1) begin
                vld_del[i] <= 0;
                tick_cnt_del[i] <= 0;
                group_idx_del[i] <= 0;
                type_del[i] <= 0;
            end
            for (i = 0; i < X_LATENCY; i = i + 1)
                x_sub_vec_pipe[i] <= 0;
        end
    end

    wire [7:0] replay_addr_ext;
    assign replay_addr_ext = (group_idx * TAPS) + tick_cnt;
    assign replay_addr = replay_ext_active ? replay_addr_ext : replay_cnt;
    wire signed [TAPS*DATA_WIDTH-1:0] replay_vec;
    assign replay_vec = input_buf[replay_addr];

    wire frame_cold_accept = (op_state == S_IDLE) && start && !ingest_full &&
                             (idle_warm_cnt >= IDLE_WARM_CYCLES) &&
                             !idle_pipe_drain && !replay_reset && !replay_reset_d;
    wire frame_accept = frame_cold_accept;
    wire pass0_tail_ingest = inter_frame_ingest && !start && !ingest_full;
    wire pass0_feed_x = (pass_idx == 0) && !ingest_full && !replay_ext_active &&
                        ((op_state == S_REPLAY) || frame_accept) &&
                        (start || (vld_in && !pass0_tail_ingest));
    wire pass0_flush_x = (op_state == S_REPLAY) && (pass_idx == 0) && !start &&
                        !ingest_full && !replay_ext_active;
    wire use_buf_x = (pass_idx != 2'd0) || replay_ext_active;
    wire [7:0] fetch_addr_s0;
    wire [7:0] buf_x_addr;
    assign fetch_addr_s0 = (fetch_grp_s0 * TAPS) + tick_cnt_pipe[0];
    assign buf_x_addr = fetch_addr_s0;

    always @(posedge clk) begin
        if (!en)
            ;
        else if (frame_accept) begin
            x_sub_vec_pipe[0] <= x_sub_vec_in;
            for (i = 1; i < X_LATENCY; i = i + 1)
                x_sub_vec_pipe[i] <= 0;
            for (i = 0; i < TAG_LATENCY; i = i + 1) begin
                vld_del[i] <= 1'b0;
                tick_cnt_del[i] <= 3'd0;
                group_idx_del[i] <= 4'd0;
                type_del[i] <= 1'b0;
            end
            for (i = 0; i < PD; i = i + 1) begin
                vld_pipe[i] <= 1'b0;
                tick_cnt_pipe[i] <= 3'd0;
                grp_idx_pipe[i] <= 4'd0;
                type_pipe[i] <= 1'b0;
            end
        end else if (replay_reset || replay_reset_d)
            ;
        else if (op_state == S_REPLAY || op_state == S_DRAIN) begin
            if (pass0_feed_x)
                x_sub_vec_pipe[0] <= x_sub_vec_in;
            else if (pass0_tail_ingest)
                x_sub_vec_pipe[0] <= x_sub_vec_pipe[0];
            else if (!pass0_flush_x && op_state == S_REPLAY && (replay_hold || vld_in))
                x_sub_vec_pipe[0] <= replay_vec;
            for (i = 1; i < X_LATENCY; i = i + 1)
                x_sub_vec_pipe[i] <= x_sub_vec_pipe[i-1];

            vld_del[0] <= vld_in;
            tick_cnt_del[0] <= tick_cnt;
            group_idx_del[0] <= group_idx;
            type_del[0] <= group_idx[3];
            for (i = 1; i < TAG_LATENCY; i = i + 1) begin
                vld_del[i] <= vld_del[i-1];
                tick_cnt_del[i] <= tick_cnt_del[i-1];
                group_idx_del[i] <= group_idx_del[i-1];
                type_del[i] <= type_del[i-1];
            end

            vld_pipe[0] <= vld_del[TAG_LATENCY-1];
            tick_cnt_pipe[0] <= tick_cnt_del[TAG_LATENCY-1];
            grp_idx_pipe[0] <= group_idx_del[TAG_LATENCY-1];
            type_pipe[0] <= type_del[TAG_LATENCY-1];
            for (i = 1; i < PD; i = i + 1) begin
                vld_pipe[i] <= vld_pipe[i-1];
                tick_cnt_pipe[i] <= tick_cnt_pipe[i-1];
                grp_idx_pipe[i] <= grp_idx_pipe[i-1];
                type_pipe[i] <= type_pipe[i-1];
            end
        end
    end

    wire [7:0] cap_addr_s0;
    assign cap_addr_s0 = (fetch_grp_s0 * TAPS) + tick_cnt_pipe[0];
    // Store MAC-aligned x (same sample pass0 compute used) indexed by fetch address.
    always @(posedge clk) begin
        if (en && pass_idx == 2'd0 && !ingest_full && !replay_ext_active &&
            (op_state == S_REPLAY) && vld_pipe[0] && !replay_reset_d && !frame_accept &&
            (inter_tag_hold_cnt == 8'd0)) begin
            addr = cap_addr_s0;
            if (!cap_mask[addr[6:0]]) begin
                input_buf[addr] <= x_sub_vec_pipe[X_LATENCY-1];
                cap_mask[addr[6:0]] <= 1'b1;
                ingest_cnt <= ingest_cnt + 1'b1;
                if ((ingest_cnt + 1'b1) == TOTAL_INPUTS) begin
                    ingest_full <= 1'b1;
                    inter_frame_ingest <= 1'b0;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (en && op_state != S_IDLE && vld_pipe[0] && !replay_reset_d) begin
            addr = fetch_addr_s0;
            for (i = 0; i < COMPUTE_LANES; i = i + 1) begin
                word = bram_mem[bank_base + i][addr];
                for (j = 0; j < TAPS; j = j + 1) begin
                    st0_x[i][j] <= $signed(word[j*DATA_WIDTH +: DATA_WIDTH]);
                    if (use_buf_x)
                        st1_x[i][j] <= $signed(input_buf[buf_x_addr][j*DATA_WIDTH +: DATA_WIDTH]);
                    else
                        st1_x[i][j] <= $signed(x_sub_vec_pipe[X_LATENCY-1][j*DATA_WIDTH +: DATA_WIDTH]);
                    st0_x_pipe[0][i][j] <= $signed(word[j*DATA_WIDTH +: DATA_WIDTH]);
                    if (use_buf_x)
                        st1_x_pipe[0][i][j] <= $signed(input_buf[buf_x_addr][j*DATA_WIDTH +: DATA_WIDTH]);
                    else
                        st1_x_pipe[0][i][j] <= $signed(x_sub_vec_pipe[X_LATENCY-1][j*DATA_WIDTH +: DATA_WIDTH]);
                end
            end
            for (i = 1; i <= PD; i = i + 1) begin
                for (k = 0; k < COMPUTE_LANES; k = k + 1) begin
                    for (j = 0; j < TAPS; j = j + 1) begin
                        st0_x_pipe[i][k][j] <= st0_x_pipe[i-1][k][j];
                        st1_x_pipe[i][k][j] <= st1_x_pipe[i-1][k][j];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (en && op_state != S_IDLE && vld_pipe[1] && !replay_reset_d) begin
            for (i = 0; i < COMPUTE_LANES; i = i + 1) begin
                for (j = 0; j < TAPS; j = j + 1)
                    mult_reg[i][j] <= st0_x_pipe[0][i][j] * st1_x_pipe[0][i][j];
            end
        end
    end

    genvar lane_sum;
    generate
        for (lane_sum = 0; lane_sum < COMPUTE_LANES; lane_sum = lane_sum + 1) begin : G_SUM_WIRE
            integer sum_idx;
            reg signed [39:0] s_wire;
            always @* begin
                s_wire = 0;
                for (sum_idx = 0; sum_idx < TAPS; sum_idx = sum_idx + 1)
                    s_wire = s_wire + $signed(mult_reg[lane_sum][sum_idx]);
            end
            assign st2_sum_wire[lane_sum] = s_wire;
        end
    endgenerate

    always @(posedge clk) begin
        if (en && op_state != S_IDLE && vld_pipe[2] && !replay_reset_d) begin
            for (i = 0; i < COMPUTE_LANES; i = i + 1)
                st2_sum_reg[i] <= st2_sum_wire[i];
        end
    end

    always @(posedge clk) begin
        if (en && op_state != S_IDLE && vld_pipe[3] && !replay_reset_d) begin
            for (i = 0; i < COMPUTE_LANES; i = i + 1) begin
                if (tick_cnt_pipe[3] == 3'd0) begin
                    acc_reg[i] <= st2_sum_reg[i];
                    acc_final_reg[i] <= st2_sum_reg[i];
                end else begin
                    acc_reg[i] <= acc_reg[i] + st2_sum_reg[i];
                    if (tick_cnt_pipe[3] == (TAPS - 1)) begin
                        acc_final_reg[i] <= acc_reg[i] + st2_sum_reg[i];
                        stage4_sat_out[i] <= sat_to_16(acc_reg[i] + st2_sum_reg[i]);
                    end
                end
            end
        end
    end

    initial begin
        for (i = 0; i < OUT_LANES; i = i + 1)
            for (j = 0; j < OUT_LANES; j = j + 1)
                merge_out[i][j] = {DATA_WIDTH{1'b0}};
    end

    wire cold_tail_skip = pass_cold_armed &&
                          (logical_grp_s6 == 4'd15) &&
                          (pipe_grp_s6 == 4'd0) &&
                          (pass_idx != NUM_PASSES - 1);
    wire pass0_ext_log15_skip = (pass_idx == 2'd0) &&
                                replay_ext_active &&
                                (logical_grp_s6 == 4'd15);
    wire pass3_ext_merge_skip = (pass_idx == NUM_PASSES - 1) && replay_ext_active;
    wire skip_merge = cold_tail_skip || pass0_ext_log15_skip || pass3_ext_merge_skip;

    always @(posedge clk) begin
        if (!rst_n) begin
            pass_cold_armed <= 1'b0;
            pass_g0_seen <= 1'b0;
            emit_pending <= 1'b0;
            emit_pending_grp <= 4'd0;
            emit_pending_type <= 1'b0;
        end else begin
            if (en && op_state != S_IDLE &&
                vld_pipe[6] && tick_cnt_pipe[6] == (TAPS - 1) && !replay_reset_d) begin
                if (skip_merge) begin
                    if (cold_tail_skip)
                        pass_cold_armed <= 1'b0;
                end else begin
                    for (i = 0; i < COMPUTE_LANES; i = i + 1)
                        merge_out[merge_grp_s6][bank_base + i] <= stage4_sat_out[i];
                    if (cold_tail_skip)
                        pass_cold_armed <= 1'b0;
                end

                if (logical_grp_s6 == 4'd0)
                    pass_g0_seen <= 1'b1;

                if (pass_idx == NUM_PASSES - 1 && !skip_merge) begin
                    emit_pending <= 1'b1;
                    emit_pending_grp <= logical_grp_s6;
                    emit_pending_type <= type_pipe[6];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            y_out <= 0;
            done_x <= 0;
            done_z <= 0;
            out_valid <= 0;
            out_grp <= 4'd0;
        end else begin
            done_x <= 0;
            done_z <= 0;
            out_valid <= 0;
            if (emit_pending) begin
                emit_pending <= 1'b0;
                out_grp <= emit_pending_grp;
                for (i = 0; i < OUT_LANES; i = i + 1)
                    y_out[i*DATA_WIDTH +: DATA_WIDTH] <= merge_out[emit_pending_grp][i];
                out_valid <= 1'b1;

                if (emit_pending_type == 1'b0 && emit_pending_grp == 4'd7)
                    done_x <= 1'b1;
                if (emit_pending_type == 1'b1 && emit_pending_grp == 4'd15)
                    done_z <= 1'b1;
            end
        end
    end

    assign dbg_merge_skip        = skip_merge;

    assign dbg_op_state          = op_state;
    assign dbg_pass_idx          = pass_idx;
    assign dbg_vld_in            = vld_in;
    assign dbg_replay_cnt        = replay_cnt;
    assign dbg_ingest_cnt        = ingest_cnt;
    assign dbg_replay_addr       = replay_addr;
    assign dbg_replay_ext        = replay_ext_active;
    assign dbg_replay_hold       = replay_hold;
    assign dbg_pass_replay_guard = pass_replay_guard;
    assign dbg_replay_reset_d    = replay_reset_d;
    assign dbg_tick_cnt          = tick_cnt;
    assign dbg_group_idx         = group_idx;
    assign dbg_pipe_grp_s0       = pipe_grp_s0;
    assign dbg_fetch_grp_s0      = fetch_grp_s0;
    assign dbg_pipe_grp_s6       = pipe_grp_s6;
    assign dbg_logical_grp_s6    = logical_grp_s6;
    assign dbg_vld_pipe0         = vld_pipe[0];
    assign dbg_vld_pipe1         = vld_pipe[1];
    assign dbg_vld_pipe3         = vld_pipe[3];
    assign dbg_vld_pipe6         = vld_pipe[6];
    assign dbg_tick_pipe0        = tick_cnt_pipe[0];
    assign dbg_tick_pipe3        = tick_cnt_pipe[3];
    assign dbg_tick_pipe6        = tick_cnt_pipe[6];
    assign dbg_grp_pipe6         = grp_idx_pipe[6];
    assign dbg_pass_g0_seen      = pass_g0_seen;
    assign dbg_st0_p0_l0         = st0_x_pipe[0][0][0];
    assign dbg_st1_p0_l0         = st1_x_pipe[0][0][0];
    assign dbg_st0_p1_l0         = st0_x_pipe[1][0][0];
    assign dbg_st1_p1_l0         = st1_x_pipe[1][0][0];
    assign dbg_acc_l0            = acc_reg[0];
    assign dbg_sat_l0            = stage4_sat_out[0];
    assign dbg_x_pipe0_zero      = (x_sub_vec_pipe[0] == {TAPS*DATA_WIDTH{1'b0}});
    assign dbg_replay_tap0       = replay_vec[0 +: DATA_WIDTH];
    assign dbg_xvec_tap0         = x_sub_vec_pipe[X_LATENCY-1][0 +: DATA_WIDTH];
    assign dbg_pipe01_delta_l0   = st0_x_pipe[0][0][0] - st0_x_pipe[1][0][0];

`ifdef INPROJ_V3_DEBUG
    integer dbg_sim_cyc;
    initial dbg_sim_cyc = 0;

    // Section 6 STREAMING_DESIGN_GUIDE: end-to-end watch + startup + alignment
    always @(posedge clk) begin
        if (!rst_n)
            dbg_sim_cyc = 0;
        else if (en)
            dbg_sim_cyc = dbg_sim_cyc + 1;

        if (en && dbg_sim_cyc <= 15) begin
            $display("[DBG_STARTUP] cyc=%0d st=%0d pass=%0d start=%b vld_in=%b ingest=%0d replay=%0d addr=%0d x_zero=%b xvec_t0=%0d replay_t0=%0d in_t0=%0d",
                dbg_sim_cyc, op_state, pass_idx, start, vld_in, ingest_cnt, replay_cnt, replay_addr,
                dbg_x_pipe0_zero, $signed(dbg_xvec_tap0), $signed(dbg_replay_tap0),
                $signed(x_sub_vec_in[0 +: DATA_WIDTH]));
        end

        if (en && vld_pipe[1] && !replay_reset_d && dbg_sim_cyc <= 20) begin
            $display("[DBG_PIPE_DELTA] cyc=%0d pass=%0d pipe_grp=%0d tick=%0d st0_p0=%0d st0_p1=%0d delta=%0d",
                dbg_sim_cyc, pass_idx, pipe_grp_s0, tick_cnt_pipe[1],
                $signed(dbg_st0_p0_l0), $signed(dbg_st0_p1_l0), $signed(dbg_pipe01_delta_l0));
        end

        if (en && vld_pipe[0] && !replay_reset_d && fetch_grp_s0 == 4'd0) begin
            $display("[DBG_FETCH G0] cyc=%0d pass=%0d pipe=%0d tick=%0d st0=%0d xvec=%0d",
                dbg_sim_cyc, pass_idx, pipe_grp_s0, tick_cnt_pipe[0],
                $signed(dbg_st0_p0_l0), $signed(dbg_xvec_tap0));
        end

        if (en && vld_pipe[1] && !replay_reset_d &&
            pipe_grp_to_logical(grp_idx_pipe[1]) == 4'd0 && tick_cnt_pipe[1] == 3'd0) begin
            $display("[DBG_MULT G0_T0] cyc=%0d pass=%0d st0=%0d st1=%0d",
                dbg_sim_cyc, pass_idx, $signed(dbg_st0_p0_l0), $signed(dbg_st1_p0_l0));
        end

        if (en && vld_pipe[6] && tick_cnt_pipe[6] == (TAPS - 1) && !replay_reset_d) begin
            if (skip_merge)
                $display("[DBG_MERGE_SKIP] cyc=%0d pass=%0d pipe=%0d log=%0d g0_seen=%b cold=%b p0ext=%b",
                    dbg_sim_cyc, pass_idx, pipe_grp_s6, logical_grp_s6, pass_g0_seen,
                    cold_tail_skip, pass0_ext_log15_skip);
            else if (logical_grp_s6 == 4'd0 && pass_idx == NUM_PASSES - 1)
                $display("[DBG_EMIT G0] cyc=%0d sat0=%0d acc=%0d",
                    dbg_sim_cyc, $signed(dbg_sat_l0), $signed(dbg_acc_l0));
        end

        if (en && op_state == S_REPLAY && pass_idx == 0 && vld_in &&
            (replay_cnt != ingest_cnt) && ((replay_cnt + 8'd1) != ingest_cnt)) begin
            $display("[DBG_CAPTURE_LAG] cyc=%0d ingest=%0d replay=%0d addr=%0d",
                dbg_sim_cyc, ingest_cnt, replay_cnt, replay_addr);
        end
    end
`endif

endmodule
