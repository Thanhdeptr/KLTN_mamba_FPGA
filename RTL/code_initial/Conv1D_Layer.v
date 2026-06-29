`include "_parameter.v"

// Streaming Conv1D depthwise k=4: 8 MACs time-multiplexed, 16 lanes / 8 clk per frame.
// Internal mux: path_x -> MAC + SiLU_x; !path_x -> SiLU_z + z_silu buffer.
// shift_reg[127:0] for 128 global x channels (8 InProj x groups).
module Conv1D_Layer #(
    parameter DATA_WIDTH     = `DATA_WIDTH,
    parameter NUM_MAC        = 8,
    parameter NUM_LANES      = 16,
    parameter D_INNER        = `D_INNER,
    parameter SILU_LATENCY   = 2,
    parameter X_FIFO_DEPTH   = 8,
    parameter MAX_TOKENS     = 1024,
    parameter FULL_WEIGHTS   = 0
) (
    input  wire clk,
    input  wire reset,

    input  wire start,
    input  wire en,
    input  wire valid_in,
    input  wire path_x,
    input  wire [3:0] grp_idx,
    input  wire [15:0] token_idx,

    output reg  valid_out,
    output reg  x_valid_out,
    output reg  z_valid_out,
    output reg  ready_in,

    input  wire signed [NUM_LANES * DATA_WIDTH - 1 : 0] x_in_vec,

    input  wire signed [NUM_LANES * 4 * DATA_WIDTH - 1 : 0] weights_vec,
    input  wire signed [NUM_LANES * DATA_WIDTH - 1 : 0] bias_vec,
    input  wire signed [D_INNER * 4 * DATA_WIDTH - 1 : 0] conv_w_packed,
    input  wire signed [D_INNER * DATA_WIDTH - 1 : 0] conv_b_packed,

    output wire signed [NUM_LANES * DATA_WIDTH - 1 : 0] y_out_vec,
    output wire signed [NUM_LANES * DATA_WIDTH - 1 : 0] z_out_vec,

    output reg  [15:0] x_capture_cnt,
    output reg  [15:0] z_capture_cnt,
    output reg  [15:0] x_accept_cnt,

    output reg  [2:0]  x_out_grp,
    output reg  [15:0] x_out_token,
    output reg  [2:0]  z_out_grp,
    output reg  [15:0] z_out_token,

    output wire beat_accept
);

    wire signed [DATA_WIDTH-1:0] x_in [0:NUM_LANES-1];

    genvar gi, gk;
    generate
        for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : unpack_in
            assign x_in[gi] = x_in_vec[gi*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    function signed [DATA_WIDTH-1:0] pick_weight;
        input [3:0] grp;
        input [3:0] lane;
        input [1:0] tap;
        reg [9:0] idx;
        begin
            if (FULL_WEIGHTS)
                idx = (grp * NUM_LANES + lane) * 4 + tap;
            else
                idx = lane * 4 + tap;
            if (FULL_WEIGHTS)
                pick_weight = conv_w_packed[idx*DATA_WIDTH +: DATA_WIDTH];
            else
                pick_weight = weights_vec[idx*DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    function signed [DATA_WIDTH-1:0] pick_bias;
        input [3:0] grp;
        input [3:0] lane;
        reg [7:0] idx;
        begin
            if (FULL_WEIGHTS)
                idx = grp * NUM_LANES + lane;
            else
                idx = lane;
            if (FULL_WEIGHTS)
                pick_bias = conv_b_packed[idx*DATA_WIDTH +: DATA_WIDTH];
            else
                pick_bias = bias_vec[idx*DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    reg signed [DATA_WIDTH-1:0] shift_reg [0:D_INNER-1][0:2];
    reg signed [DATA_WIDTH-1:0] current_x [0:NUM_LANES-1];
    reg [3:0] active_grp;
    reg [15:0] active_token;
    reg [3:0] push_grp;
    reg [15:0] push_token;
    reg signed [DATA_WIDTH-1:0] push_x_snap [0:NUM_LANES-1];
    reg signed [DATA_WIDTH-1:0] push_pe_snap [0:NUM_LANES-1];

    reg [3:0] cycle_cnt;
    reg       mac_active;
    reg       en_r;
    reg       mac_clear;

    reg signed [DATA_WIDTH-1:0] pipeline_pe_out [0:NUM_LANES-1];

    reg       mac_path_x_latched;

    wire [1:0] tap_idx  = cycle_cnt[1:0];
    wire       batch1   = cycle_cnt[2];
    wire [3:0] lane_base = batch1 ? 4'd8 : 4'd0;
    wire       mac_step = mac_active && en_r;
    wire       bias_init_en = (tap_idx == 2'd0);

    wire signed [DATA_WIDTH-1:0] mac_out [0:NUM_MAC-1];

    wire signed [DATA_WIDTH-1:0] w_lane [0:NUM_LANES-1][0:3];
    wire signed [DATA_WIDTH-1:0] b_lane [0:NUM_LANES-1];

    genvar wl;
    generate
        for (wl = 0; wl < NUM_LANES; wl = wl + 1) begin : wsel
            assign b_lane[wl] = pick_bias(active_grp, wl[3:0]);
            assign w_lane[wl][0] = pick_weight(active_grp, wl[3:0], 2'd0);
            assign w_lane[wl][1] = pick_weight(active_grp, wl[3:0], 2'd1);
            assign w_lane[wl][2] = pick_weight(active_grp, wl[3:0], 2'd2);
            assign w_lane[wl][3] = pick_weight(active_grp, wl[3:0], 2'd3);
        end
    endgenerate

    genvar p;
    generate
        for (p = 0; p < NUM_MAC; p = p + 1) begin : mac_gen
            wire [3:0] lane = lane_base + p[3:0];
            wire [6:0] global_ch = {active_grp[2:0], lane[3:0]};
            wire signed [DATA_WIDTH-1:0] x_op =
                (tap_idx == 2'd0) ? current_x[lane] :
                (tap_idx == 2'd1) ? shift_reg[global_ch][0] :
                (tap_idx == 2'd2) ? shift_reg[global_ch][1] : shift_reg[global_ch][2];

            Conv1D_MAC #(
                .DATA_WIDTH(DATA_WIDTH),
                .FRAC_BITS(`FRAC_BITS)
            ) u_mac (
                .clk(clk),
                .reset(reset),
                .clear_acc(mac_clear),
                .compute_en(mac_step),
                .bias_init_en(bias_init_en),
                .in_A(x_op),
                .in_B(w_lane[lane][3 - tap_idx]),
                .in_bias(b_lane[lane]),
                .out_val(mac_out[p])
            );
        end
    endgenerate

    localparam X_FIFO_CNT_W = (X_FIFO_DEPTH <= 2) ? 2 :
                              (X_FIFO_DEPTH <= 4) ? 3 :
                              (X_FIFO_DEPTH <= 8) ? 4 : 5;

    // --- X path: FIFO between MAC and SiLU ---
    reg signed [DATA_WIDTH-1:0] x_fifo_data [0:X_FIFO_DEPTH-1][0:NUM_LANES-1];
    reg [3:0]  x_fifo_grp   [0:X_FIFO_DEPTH-1];
    reg [15:0] x_fifo_token [0:X_FIFO_DEPTH-1];
    reg [X_FIFO_CNT_W-1:0] x_fifo_count;
    reg        mac_push_pending;

    reg signed [DATA_WIDTH-1:0] silu_x_in [0:NUM_LANES-1];
    reg        x_silu_busy;
    reg [1:0]  x_silu_wait;

    wire       x_silu_start = !x_silu_busy && (x_fifo_count != {X_FIFO_CNT_W{1'b0}});

    wire signed [DATA_WIDTH-1:0] silu_x_out [0:NUM_LANES-1];

    generate
        for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : silu_x_gen
            SiLU_Unit u_silu_x (
                .clk(clk),
                .in_data(silu_x_in[gi]),
                .out_data(silu_x_out[gi])
            );
            assign y_out_vec[gi*DATA_WIDTH +: DATA_WIDTH] = silu_x_out[gi];
        end
    endgenerate

    // --- Z path: SiLU only ---
    reg signed [DATA_WIDTH-1:0] z_hold [0:NUM_LANES-1];
    reg signed [DATA_WIDTH-1:0] silu_z_in [0:NUM_LANES-1];
    reg [3:0]  z_active_grp;
    reg [15:0] z_active_token;
    reg        z_silu_busy;
    reg [1:0]  z_silu_wait;

    wire signed [DATA_WIDTH-1:0] silu_z_out [0:NUM_LANES-1];

    generate
        for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : silu_z_gen
            SiLU_Unit u_silu_z (
                .clk(clk),
                .in_data(silu_z_in[gi]),
                .out_data(silu_z_out[gi])
            );
            assign z_out_vec[gi*DATA_WIDTH +: DATA_WIDTH] = silu_z_out[gi];
        end
    endgenerate

    reg signed [DATA_WIDTH-1:0] z_silu_mem [0:MAX_TOKENS*D_INNER-1];

    reg [3:0] cycle_cnt_d1;
    reg       mac_step_d1;

    integer c, f;

    wire mac_fifo_has_room = (x_fifo_count < X_FIFO_DEPTH);
    wire mac_burst_done    = mac_step_d1 && (cycle_cnt_d1 == 4'd7);
    // Never accept a new X beat on the same cycle MAC completes: otherwise
    // mac_push_pending stays set while mac_active restarts and the second
    // completion is dropped (lost conv outputs at end of long streams).
    wire mac_ready = !mac_active && mac_fifo_has_room && !mac_push_pending;
    wire z_ready   = !z_silu_busy;
    wire accept_x  = valid_in && path_x && en && mac_ready && !mac_burst_done;
    wire accept_z  = valid_in && !path_x && en && z_ready;
    assign beat_accept = accept_x || accept_z;
    wire fifo_push = mac_push_pending && mac_fifo_has_room;
    wire fifo_pop  = x_silu_start && !(mac_push_pending && mac_fifo_has_room);

    always @(*) begin
        ready_in = en && (path_x ? mac_ready : z_ready);
    end

    always @(posedge clk) begin
        if (reset) begin
            cycle_cnt      <= 4'd0;
            mac_active     <= 1'b0;
            mac_clear      <= 1'b1;
            valid_out      <= 1'b0;
            x_fifo_count   <= {X_FIFO_CNT_W{1'b0}};
            x_silu_busy    <= 1'b0;
            x_silu_wait    <= 2'd0;
            z_silu_busy    <= 1'b0;
            z_silu_wait    <= 2'd0;
            active_grp     <= 4'd0;
            active_token   <= 16'd0;
            push_grp       <= 4'd0;
            push_token     <= 16'd0;
            z_active_grp   <= 4'd0;
            z_active_token <= 16'd0;
            x_capture_cnt  <= 16'd0;
            z_capture_cnt  <= 16'd0;
            x_accept_cnt   <= 16'd0;
            x_out_grp      <= 3'd0;
            x_out_token    <= 16'd0;
            z_out_grp      <= 3'd0;
            z_out_token    <= 16'd0;
            mac_push_pending <= 1'b0;
            cycle_cnt_d1   <= 4'd0;
            mac_step_d1    <= 1'b0;
            for (c = 0; c < D_INNER; c = c + 1) begin
                shift_reg[c][0] <= 0;
                shift_reg[c][1] <= 0;
                shift_reg[c][2] <= 0;
            end
            for (c = 0; c < NUM_LANES; c = c + 1) begin
                current_x[c]  <= 0;
                silu_x_in[c]  <= 0;
                z_hold[c]     <= 0;
                silu_z_in[c]  <= 0;
                pipeline_pe_out[c] <= 0;
            end
        end else begin
            en_r           <= en;
            mac_clear      <= 1'b0;
            valid_out      <= 1'b0;
            x_valid_out    <= 1'b0;
            z_valid_out    <= 1'b0;
            if (accept_x)
                x_accept_cnt <= x_accept_cnt + 16'd1;

            if (start) begin
                cycle_cnt    <= 4'd0;
                mac_active   <= 1'b0;
                mac_clear    <= 1'b1;
                x_fifo_count <= 2'd0;
                x_silu_busy  <= 1'b0;
                z_silu_busy  <= 1'b0;
                for (c = 0; c < D_INNER; c = c + 1) begin
                    shift_reg[c][0] <= 0;
                    shift_reg[c][1] <= 0;
                    shift_reg[c][2] <= 0;
                end
            end else begin
                // Z beat: latch and start SiLU z
                if (accept_z) begin
                    z_active_grp   <= grp_idx;
                    z_active_token <= token_idx;
                    for (c = 0; c < NUM_LANES; c = c + 1)
                        z_hold[c] <= x_in[c];
                end

                if (!z_silu_busy && accept_z) begin
                    for (c = 0; c < NUM_LANES; c = c + 1)
                        silu_z_in[c] <= x_in[c];
                    z_silu_busy <= 1'b1;
                    z_silu_wait <= SILU_LATENCY[1:0];
                end else if (z_silu_busy && en) begin
                    if (z_silu_wait == 2'd1) begin
                        z_silu_busy  <= 1'b0;
                        z_valid_out  <= 1'b1;
                        z_out_grp    <= z_active_grp[2:0];
                        z_out_token  <= z_active_token;
                        valid_out    <= 1'b1;
                        z_capture_cnt <= z_capture_cnt + 16'd1;
                        for (c = 0; c < NUM_LANES; c = c + 1) begin
                            if ((z_active_token * D_INNER + (z_active_grp - 4'd8) * NUM_LANES + c) < MAX_TOKENS * D_INNER)
                                z_silu_mem[z_active_token * D_INNER + (z_active_grp - 4'd8) * NUM_LANES + c] <= silu_z_out[c];
                        end
                    end
                    if (z_silu_wait != 2'd0)
                        z_silu_wait <= z_silu_wait - 2'd1;
                end

                // X SiLU stage (from FIFO)
                if (x_silu_start) begin
                    for (c = 0; c < NUM_LANES; c = c + 1)
                        silu_x_in[c] <= x_fifo_data[0][c];
                    x_silu_busy <= 1'b1;
                    x_silu_wait <= SILU_LATENCY[1:0];
                end else if (x_silu_busy && en) begin
                    if (x_silu_wait == 2'd1) begin
                        x_silu_busy   <= 1'b0;
                        x_valid_out   <= 1'b1;
                        x_out_grp     <= x_fifo_grp[0][2:0];
                        x_out_token   <= x_fifo_token[0];
                        valid_out     <= 1'b1;
                        x_capture_cnt <= x_capture_cnt + 16'd1;
                    end
                    if (x_silu_wait != 2'd0)
                        x_silu_wait <= x_silu_wait - 2'd1;
                end

                // MAC burst
                if (accept_x) begin
                    active_grp   <= grp_idx;
                    active_token <= token_idx;
                    mac_path_x_latched <= 1'b1;
                    for (c = 0; c < NUM_LANES; c = c + 1)
                        current_x[c] <= x_in[c];
                    cycle_cnt  <= 4'd0;
                end else if (mac_active && mac_step && cycle_cnt != 4'd7)
                    cycle_cnt <= cycle_cnt + 4'd1;
            end

            cycle_cnt_d1 <= cycle_cnt;
            mac_step_d1  <= mac_step;

            if (mac_step_d1 && cycle_cnt_d1 == 4'd3) begin
                for (c = 0; c < NUM_MAC; c = c + 1)
                    pipeline_pe_out[c] <= mac_out[c];
            end

            // Drain pending push before latching a new MAC completion (same-cycle ordering)
            if (fifo_push && !fifo_pop) begin
                for (c = 0; c < NUM_LANES; c = c + 1)
                    x_fifo_data[x_fifo_count][c] <= push_pe_snap[c];
                x_fifo_grp[x_fifo_count]   <= push_grp;
                x_fifo_token[x_fifo_count] <= push_token;

                for (c = 0; c < NUM_LANES; c = c + 1) begin
                    shift_reg[{push_grp[2:0], c[3:0]}][2] <= shift_reg[{push_grp[2:0], c[3:0]}][1];
                    shift_reg[{push_grp[2:0], c[3:0]}][1] <= shift_reg[{push_grp[2:0], c[3:0]}][0];
                    shift_reg[{push_grp[2:0], c[3:0]}][0] <= push_x_snap[c];
                end
                mac_push_pending <= 1'b0;
            end

            if (mac_step_d1 && cycle_cnt_d1 == 4'd7 && !mac_push_pending) begin
                for (c = 0; c < NUM_MAC; c = c + 1)
                    pipeline_pe_out[NUM_MAC + c] <= mac_out[c];
                for (c = 0; c < NUM_MAC; c = c + 1) begin
                    push_pe_snap[c] <= pipeline_pe_out[c];
                    push_pe_snap[NUM_MAC + c] <= mac_out[c];
                end
                mac_push_pending <= 1'b1;
                push_grp   <= active_grp;
                push_token <= active_token;
                for (c = 0; c < NUM_LANES; c = c + 1)
                    push_x_snap[c] <= current_x[c];
            end

            // accept_x wins over burst-end clear when both occur same cycle
            if (accept_x)
                mac_active <= 1'b1;
            else if (mac_step_d1 && cycle_cnt_d1 == 4'd7)
                mac_active <= 1'b0;

            if (fifo_pop) begin
                if (x_fifo_count > {{(X_FIFO_CNT_W-1){1'b0}}, 1'b1}) begin
                    for (f = 0; f < X_FIFO_DEPTH - 1; f = f + 1) begin
                        x_fifo_grp[f]   <= x_fifo_grp[f+1];
                        x_fifo_token[f] <= x_fifo_token[f+1];
                        for (c = 0; c < NUM_LANES; c = c + 1)
                            x_fifo_data[f][c] <= x_fifo_data[f+1][c];
                    end
                end
                x_fifo_count <= x_fifo_count - {{(X_FIFO_CNT_W-1){1'b0}}, 1'b1};
            end else if (fifo_push && !fifo_pop)
                x_fifo_count <= x_fifo_count + {{(X_FIFO_CNT_W-1){1'b0}}, 1'b1};
        end
    end

    // Legacy debug alias (single-frame TB)
    wire signed [DATA_WIDTH-1:0] silu_in_hold [0:NUM_LANES-1];
    generate
        for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : legacy_alias
            assign silu_in_hold[gi] = silu_x_in[gi];
        end
    endgenerate

endmodule
