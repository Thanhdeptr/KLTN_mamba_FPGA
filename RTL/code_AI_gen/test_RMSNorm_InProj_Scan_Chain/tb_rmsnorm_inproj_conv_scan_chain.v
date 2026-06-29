`timescale 1ns/1ps
// RMSNorm -> InProj v2 -> Conv1D -> Scan_Core_Streaming_Pipe (continuous streaming).
`include "chain_tb_paths.vh"

module tb_rmsnorm_inproj_conv_scan_chain;
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_INNER    = 128;
    localparam D_STATE    = 16;
    localparam TAPS       = 8;
    localparam D_MODEL    = 64;
    localparam GRPS = 8;
    localparam BEATS_PER_VEC = 16 * TAPS;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 10;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam CLK_PERIOD_NS  = 10;
    // Scale sim budget: N=10 ~25k cycles; N=1000 ~2.5M+ (scan backpressure gaps >> 50k).
    localparam SIM_TIMEOUT_NS = (NUM_VECTORS <= 10) ? 300_000_000 :
                                (NUM_VECTORS * 600_000); // headroom for NUM_EXEC=1 drain
    localparam SIM_MAX_CYCLES = SIM_TIMEOUT_NS / CLK_PERIOD_NS;
    localparam STALL_LIMIT    = (NUM_VECTORS <= 10) ? 50_000 :
                                (NUM_VECTORS * 5_000);  // allow long scan drain gaps
    localparam SEQ_STRIDE    = 1000;

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;
    reg frame_done = 0;
    reg feed_idle = 0;

    reg [D_MODEL*DATA_WIDTH-1:0] gamma_vec;
    reg signed [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed;
    reg signed [D_INNER*DATA_WIDTH-1:0] conv_b_packed;

    wire signed [LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z;
    wire signed [LANES*DATA_WIDTH-1:0] conv_x_out, conv_z_out;
    wire conv_x_valid_out, conv_z_valid_out, conv_ready_in;
    wire chain_busy, inproj_streaming, feed_active, feed_complete, feed_ready;
    wire [15:0] stream_token_idx;
    wire [15:0] conv_x_capture_cnt, conv_z_capture_cnt;
    wire [6:0]  beat_q_count_dbg;
    wire        beat_q_drop;
    wire        beat_q_ready;
    wire [15:0] beats_enq_total;

    wire conv_beat_ready;
    wire scan_x_beat_ready;
    wire scan_z_beat_ready;
    wire [7:0] scan_x_grp_ready;
    wire [7:0] scan_z_grp_ready;
    wire [15:0] bx_min_token_0, bx_min_token_1, bx_min_token_2, bx_min_token_3;
    wire [15:0] bx_min_token_4, bx_min_token_5, bx_min_token_6, bx_min_token_7;
    wire [15:0] scan_token;
    wire [2:0]  scan_grp;
    wire signed [LANES*DATA_WIDTH-1:0] scan_y_vec;
    wire scan_busy;
    wire scan_ready;
    wire [13:0] scan_q_count_dbg;
    wire       scan_q_head_x_dbg;
    wire [7:0] scan_z_slot_dbg, scan_await_dbg, scan_x_skid_dbg;
    wire [2:0] scan_z_state_dbg;
    wire [7:0] scan_ypre_dbg;
    wire       mon_beat_valid;
    wire [4:0] mon_ing_count;
    wire       mon_x_beat_pend;

    reg beat_x_seen [0:NUM_VECTORS-1][0:GRPS-1];
    reg beat_z_seen [0:NUM_VECTORS-1][0:GRPS-1];
    reg scan_y_seen [0:NUM_VECTORS-1][0:GRPS-1];
    reg conv_x_seen [0:NUM_VECTORS-1][0:GRPS-1];
    reg conv_z_seen [0:NUM_VECTORS-1][0:GRPS-1];
    integer beat_x_cnt, beat_z_cnt, scan_valid_cnt;
    integer z_pend_set_cnt, z_pend_stuck_cnt;
    integer x_repair_dup_cnt, pair_enq_cnt;
    reg z_pend_prev;
    integer last_scan_tok, last_scan_grp;
    integer last_beat_z_tok, last_beat_z_grp;

    integer global_clk;
    integer y_samples;
    integer y_unique_grps;
    integer y_last_clk;
    integer conv_last_clk;
    integer last_conv_x;
    reg     feed_stall;
    reg     drain_stall;
    reg     feed_abort;
    reg     scan_stream_done;
    reg [D_MODEL*DATA_WIDTH-1:0] x_vec_hold;
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_drv;

    integer x_cap_idx, z_cap_idx;
    reg [15:0] x_cap_mem [0:NUM_VECTORS*GRPS*LANES-1];
    reg [15:0] z_cap_mem [0:NUM_VECTORS*GRPS*LANES-1];

    RMSNorm_InProj_Conv_Chain_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .TAPS(TAPS),
        .LANES(LANES),
        .NUM_TOKENS(NUM_VECTORS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .start(start),
        .frame_done(frame_done),
        .feed_idle(feed_idle),
        .x_vec_in(x_vec_hold),
        .gamma_vec(gamma_vec),
        .x_sub_vec_in(x_sub_vec_drv),
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
        .beat_q_ready(beat_q_ready),
        .beats_enq_total(beats_enq_total),
        .beats_enq_x_dbg(),
        .beats_enq_z_dbg(),
        .scan_x_beat_ready(scan_x_beat_ready),
        .scan_z_beat_ready(scan_z_beat_ready),
        .scan_x_grp_ready(scan_x_grp_ready),
        .scan_z_grp_ready(scan_z_grp_ready),
        .bx_min_token_0(bx_min_token_0),
        .bx_min_token_1(bx_min_token_1),
        .bx_min_token_2(bx_min_token_2),
        .bx_min_token_3(bx_min_token_3),
        .bx_min_token_4(bx_min_token_4),
        .bx_min_token_5(bx_min_token_5),
        .bx_min_token_6(bx_min_token_6),
        .bx_min_token_7(bx_min_token_7)
    );

    localparam SCAN_CHAIN_Q = (NUM_VECTORS * GRPS) + 1024; // N=1000 needs ~8k+ beats while scan drains
    localparam NUM_EXEC_SIM = 2;

    Scan_Chain_Wrapper #(
        .MAX_TOKENS(1000),
        .CHAIN_Q_DEPTH(SCAN_CHAIN_Q),
        .NUM_EXEC(NUM_EXEC_SIM)
`ifdef SCAN_H_LIVE
        ,.H_STORE_FULL_HISTORY(0)
`else
        ,.H_STORE_FULL_HISTORY(1)
`endif
    ) u_scan (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear_h(1'b0),
        .stream_done(scan_stream_done),
        .conv_x_valid(conv_x_valid_out),
        .conv_z_valid(conv_z_valid_out),
        .conv_x_grp(dut.u_conv.x_out_grp),
        .conv_x_token(dut.u_conv.x_out_token),
        .conv_z_grp(dut.u_conv.z_out_grp),
        .conv_z_token(dut.u_conv.z_out_token),
        .conv_x_vec(conv_x_out),
        .conv_z_vec(conv_z_out),
        .bx_min_token_0(bx_min_token_0),
        .bx_min_token_1(bx_min_token_1),
        .bx_min_token_2(bx_min_token_2),
        .bx_min_token_3(bx_min_token_3),
        .bx_min_token_4(bx_min_token_4),
        .bx_min_token_5(bx_min_token_5),
        .bx_min_token_6(bx_min_token_6),
        .bx_min_token_7(bx_min_token_7),
        .conv_beat_ready(conv_beat_ready),
        .scan_x_ready_out(scan_x_beat_ready),
        .scan_z_ready_out(scan_z_beat_ready),
        .scan_valid(scan_valid),
        .scan_token(scan_token),
        .scan_grp(scan_grp),
        .scan_y_vec(scan_y_vec),
        .scan_busy(scan_busy),
        .scan_ready(scan_ready),
        .mon_q_count(scan_q_count_dbg),
        .mon_q_head_x(scan_q_head_x_dbg),
        .mon_q_head_grp(),
        .mon_q_head_tok(),
        .mon_inj_valid(),
        .mon_z_slot_mask(scan_z_slot_dbg),
        .mon_x_skid_mask(scan_x_skid_dbg),
        .mon_await_z_mask(scan_await_dbg),
        .mon_beat_valid(mon_beat_valid),
        .mon_ing_count(mon_ing_count),
        .mon_x_beat_pend(mon_x_beat_pend),
        .mon_ex_busy_mask(),
        .mon_z_state(scan_z_state_dbg),
        .scan_x_grp_ready(scan_x_grp_ready),
        .scan_z_grp_ready(scan_z_grp_ready)
    );

    always #5 clk = ~clk;

    reg [15:0] in_mem [0:NUM_VECTORS*D_MODEL-1];
    reg [15:0] w_mem  [0:D_MODEL-1];
    reg [15:0] conv_w_mem [0:D_INNER*4-1];
    reg [15:0] conv_b_mem [0:D_INNER-1];
    reg [15:0] y_cap_mem [0:NUM_VECTORS*D_INNER-1];
    reg signed [DATA_WIDTH-1:0] rtl_h [0:NUM_VECTORS*D_INNER*D_STATE-1];

    reg signed [DATA_WIDTH-1:0] xvec [0:D_MODEL-1];
    reg [2:0] tb_tick;

    integer li, idx, ri, lane, gi, v, k, st, t, g;
    integer fp, fh, ret;
    reg [8*512-1:0] fname;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;
    reg [7:0] cur_ch;

    task automatic load_xvec_from_dut;
        begin
            for (ri = 0; ri < D_MODEL; ri = ri + 1)
                xvec[ri] = dut.norm_buf[ri];
        end
    endtask

    task automatic drive_one_beat;
        reg [TAPS*DATA_WIDTH-1:0] build;
        begin
            build = { xvec[tb_tick*TAPS + 7], xvec[tb_tick*TAPS + 6],
                      xvec[tb_tick*TAPS + 5], xvec[tb_tick*TAPS + 4],
                      xvec[tb_tick*TAPS + 3], xvec[tb_tick*TAPS + 2],
                      xvec[tb_tick*TAPS + 1], xvec[tb_tick*TAPS + 0] };
            x_sub_vec_drv = build;
            if (tb_tick == TAPS - 1)
                tb_tick = 0;
            else
                tb_tick = tb_tick + 1;
        end
    endtask

    task automatic load_weights;
        begin
            $display("[TB] loading InProj weights (16 lanes x 128)...");
            for (li = 0; li < LANES; li = li + 1) begin
                $sformat(fname, "%s/banks/weight_lane_%0d.mem",
                         `CHAIN_INPROJ_WEIGHTS_DIR, li);
                fh = $fopen(fname, "r");
                if (fh == 0)
                    $fatal(1, "TB: cannot open weight file %s", fname);
                for (idx = 0; idx < 128; idx = idx + 1) begin
                    line = "";
                    if ($fgets(line, fh) == 0)
                        val = 0;
                    else begin
                        ret = $sscanf(line, "%h", val);
                        if (ret != 1) val = 0;
                    end
                    dut.u_inproj.bram_mem[li][idx] = val;
                end
                $fclose(fh);
            end
            $display("[TB] InProj weights loaded");
        end
    endtask

    function integer idx_h;
        input [15:0] t;
        input [7:0] ch;
        input integer s;
        begin
            idx_h = t * D_INNER * D_STATE + ch * D_STATE + s;
        end
    endfunction

    integer y_lane, y_ch;

`include "chain_tb_monitor.vh"
`include "chain_tb_feed_guard.vh"

    // Deassert until all y captured; early stream_done truncated scan @ N=1000.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scan_stream_done <= 1'b0;
        else if (drain_stall)
            scan_stream_done <= 1'b1;
        else if (y_unique_grps >= NUM_VECTORS * GRPS)
            scan_stream_done <= 1'b1;
        else if (feed_stall && feed_complete)
            scan_stream_done <= 1'b1;
        else
            scan_stream_done <= 1'b0;
    end

    always @(posedge clk) begin
        if (scan_valid) begin
            y_last_clk = global_clk;
            if (!scan_y_seen[scan_token][scan_grp]) begin
                scan_y_seen[scan_token][scan_grp] = 1'b1;
                y_unique_grps = y_unique_grps + 1;
                y_samples = y_samples + LANES;
                for (y_lane = 0; y_lane < LANES; y_lane = y_lane + 1) begin
                    y_ch = scan_grp * LANES + y_lane;
                    y_cap_mem[scan_token * D_INNER + y_ch] =
                        scan_y_vec[y_lane*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (u_scan.u_scan.dbg_ch_done) begin
            cur_ch = u_scan.u_scan.dbg_active_grp * LANES + u_scan.u_scan.dbg_lane_idx;
            for (st = 0; st < D_STATE; st = st + 1)
                rtl_h[idx_h(u_scan.u_scan.dbg_active_token, cur_ch[7:0], st)] =
                    u_scan.u_scan.dbg_ch_h_new[st*DATA_WIDTH +: DATA_WIDTH];
        end
        if (scan_valid) begin
            scan_valid_cnt = scan_valid_cnt + 1;
            last_scan_tok = scan_token;
            last_scan_grp = scan_grp;
        end
        if (mon_beat_valid) begin
            if (u_scan.beat_path_x_r) begin
                beat_x_cnt = beat_x_cnt + 1;
                beat_x_seen[u_scan.beat_token_r][u_scan.beat_grp_r] = 1'b1;
            end else begin
                beat_z_cnt = beat_z_cnt + 1;
                beat_z_seen[u_scan.beat_token_r][u_scan.beat_grp_r] = 1'b1;
                last_beat_z_tok = u_scan.beat_token_r;
                last_beat_z_grp = u_scan.beat_grp_r;
            end
        end
        if (u_scan.u_scan.z_pend_valid && !z_pend_prev)
            z_pend_set_cnt = z_pend_set_cnt + 1;
        if (u_scan.u_scan.z_pend_valid)
            z_pend_stuck_cnt = z_pend_stuck_cnt + 1;
        z_pend_prev = u_scan.u_scan.z_pend_valid;
        if (u_scan.x_repair_dup)
            x_repair_dup_cnt = x_repair_dup_cnt + 1;
        if (u_scan.do_x && u_scan.do_z_pair)
            pair_enq_cnt = pair_enq_cnt + 1;
        if (conv_x_valid_out) begin
            conv_x_seen[dut.u_conv.x_out_token][dut.u_conv.x_out_grp] = 1'b1;
            for (lane = 0; lane < LANES; lane = lane + 1)
                x_cap_mem[x_cap_idx * LANES + lane] =
                    conv_x_out[lane*DATA_WIDTH +: DATA_WIDTH];
            x_cap_idx = x_cap_idx + 1;
        end
        if (conv_z_valid_out) begin
            conv_z_seen[dut.u_conv.z_out_token][dut.u_conv.z_out_grp] = 1'b1;
            for (lane = 0; lane < LANES; lane = lane + 1)
                z_cap_mem[z_cap_idx * LANES + lane] =
                    conv_z_out[lane*DATA_WIDTH +: DATA_WIDTH];
            z_cap_idx = z_cap_idx + 1;
        end
        mon_tick();
    end

    initial begin : FEED_SER
        reg feed_to;
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
        tb_tick = 0;
        frame_done = 0;
        feed_idle = 0;

        wait(inproj_streaming);
        mon_open_logs();
        $display("[TB] FEED: inproj_streaming active at t=%0t", $time);

        load_xvec_from_dut();
        tb_tick = 0;
        drive_one_beat();
        @(posedge clk);

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            if (feed_abort)
                disable FEED_SER;
            tb_tick = 0;
            for (k = 0; k < BEATS_PER_VEC; k = k + 1) begin
                if (feed_abort)
                    disable FEED_SER;
                feed_wait_beat_q(v[15:0], k, feed_to);
                if (feed_to)
                    disable FEED_SER;
                drive_one_beat();
                if (k == BEATS_PER_VEC - 1) begin
                    if (v + 1 < NUM_VECTORS) begin
                        feed_idle = 1'b1;
                        feed_wait_frame_ready(v[15:0], feed_to);
                        if (feed_to) begin
                            feed_idle = 1'b0;
                            disable FEED_SER;
                        end
                        feed_idle = 1'b0;
                    end
                    frame_done = 1'b1;
                end
                @(posedge clk);
                frame_done = 1'b0;
                if ((k == BEATS_PER_VEC - 1) && (v + 1 < NUM_VECTORS)) begin
                    feed_wait_stream_token(v[15:0] + 16'd1, feed_to);
                    if (feed_to)
                        disable FEED_SER;
                    load_xvec_from_dut();
                end
            end
        end
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
        if (feed_abort)
            $display("[TB] FEED_SER abort at tok=%0d beat=%0d", mon_feed_abort_tok, mon_feed_abort_beat);
        else
            $display("[TB] FEED_SER done %0d tokens", NUM_VECTORS);
    end

    always @(*) begin
        x_vec_hold = {D_MODEL*DATA_WIDTH{1'b0}};
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            x_vec_hold[ri*DATA_WIDTH +: DATA_WIDTH] =
                in_mem[dut.rms_sample_idx*D_MODEL + ri];
    end

    task automatic dump_wedge_state;
        integer dg;
        integer bx_sum;
        begin
            bx_sum = 0;
            $display("[TB] === WEDGE STATE DUMP ===");
            for (dg = 0; dg < GRPS; dg = dg + 1) begin
                bx_sum = bx_sum + dut.bx_cnt[dg];
                $display("  grp%0d: bx_cnt=%0d bx_min_tok=%0d | x_skid=%b tok=%0d | z_fifo=%0d z_head_tok=%0d | xp_cnt=%0d",
                         dg, dut.bx_cnt[dg],
                         (dg==0)?dut.bx_min_token_0:(dg==1)?dut.bx_min_token_1:
                         (dg==2)?dut.bx_min_token_2:(dg==3)?dut.bx_min_token_3:
                         (dg==4)?dut.bx_min_token_4:(dg==5)?dut.bx_min_token_5:
                         (dg==6)?dut.bx_min_token_6:dut.bx_min_token_7,
                         u_scan.x_skid_valid[dg], u_scan.x_skid_token[dg],
                         u_scan.zq_cnt[dg], u_scan.zq_token[dg][u_scan.zq_rd[dg]],
                         u_scan.xp_cnt[dg]);
            end
            $display("  hold: xin=%b xg=%0d xt=%0d | zin=%b zg=%0d zt=%0d",
                     u_scan.xin_hold_v, u_scan.xin_hold_g, u_scan.xin_hold_t,
                     u_scan.zin_hold_v, u_scan.zin_hold_g, u_scan.zin_hold_t);
            $display("  chain: bx_sum=%0d beat_q=%0d beat_q_x=%0d beat_q_z=%0d xfer_act=%b",
                     bx_sum, beat_q_count_dbg, dut.beat_q_x_count, dut.beat_q_z_count,
                     dut.conv_xfer_active);
            $display("  conv: mac_act=%b x_fifo=%0d x_silu=%b z_silu=%b enq_x=%0d enq_z=%0d accept_x=%0d",
                     dut.u_conv.mac_active, dut.u_conv.x_fifo_count,
                     dut.u_conv.x_silu_busy, dut.u_conv.z_silu_busy,
                     dut.beats_enq_x_cnt, dut.beats_enq_z_cnt,
                     dut.u_conv.x_accept_cnt);
            $display("  scan: x_rdy=%b z_rdy=%b conv_x=%0d conv_z=%0d",
                     scan_x_beat_ready, scan_z_beat_ready,
                     conv_x_capture_cnt, conv_z_capture_cnt);
            $display("  chain_q: count=%0d hold_v=%b hold_x=%b hold_g=%0d hold_t=%0d",
                     u_scan.q_count, u_scan.hold_valid, u_scan.hold_x,
                     u_scan.hold_grp, u_scan.hold_tok);
            $display("  q_head: path_x=%b grp=%0d tok=%0d | beat_r=%b path_x_r=%b",
                     u_scan.q_path_x[u_scan.q_rd], u_scan.q_grp[u_scan.q_rd],
                     u_scan.q_token[u_scan.q_rd],
                     u_scan.beat_valid_r, u_scan.beat_path_x_r);
            $display("  pipe: x_pend=%b z_pend=%b z_st=%0d ing=%0d scan_rdy=%b ypre=%b",
                     u_scan.u_scan.x_beat_pending, u_scan.u_scan.z_pend_valid,
                     u_scan.u_scan.z_state, u_scan.u_scan.ing_count,
                     scan_ready, u_scan.u_scan.ypre_ready_mask);
            if (u_scan.u_scan.z_pend_valid)
                $display("  z_pend: grp=%0d tok=%0d ypre[%0d]=%b",
                         u_scan.u_scan.z_pend_grp, u_scan.u_scan.z_pend_token,
                         u_scan.u_scan.z_pend_grp,
                         u_scan.u_scan.ypre_ready_mask[u_scan.u_scan.z_pend_grp]);
            $display("  TB cnt: beat_x=%0d beat_z=%0d scan_valid=%0d z_pend_set=%0d pair_enq=%0d x_repair_dup=%0d",
                     beat_x_cnt, beat_z_cnt, scan_valid_cnt, z_pend_set_cnt,
                     pair_enq_cnt, x_repair_dup_cnt);
            $display("  last_paired: g5 tok=%0d v=%b | g7 tok=%0d v=%b",
                     u_scan.last_paired_tok[5], u_scan.last_paired_v[5],
                     u_scan.last_paired_tok[7], u_scan.last_paired_v[7]);
            $display("[TB] === END WEDGE DUMP ===");
        end
    endtask

    task automatic report_pair_gaps;
        integer t, g, miss_y, miss_z, miss_x, z_no_y;
        begin
            miss_y = 0; miss_z = 0; miss_x = 0; z_no_y = 0;
            $display("[TB] === PAIR GAP REPORT (N=%0d) ===", NUM_VECTORS);
            for (t = 0; t < NUM_VECTORS; t = t + 1) begin
                for (g = 0; g < GRPS; g = g + 1) begin
                    if (!scan_y_seen[t][g]) begin
                        miss_y = miss_y + 1;
                        $display("  MISSING scan_y: tok=%0d grp=%0d | conv_x=%b conv_z=%b beat_x=%b beat_z=%b",
                                 t, g, conv_x_seen[t][g], conv_z_seen[t][g],
                                 beat_x_seen[t][g], beat_z_seen[t][g]);
                    end
                    if (!beat_z_seen[t][g]) miss_z = miss_z + 1;
                    if (!beat_x_seen[t][g]) miss_x = miss_x + 1;
                    if (beat_z_seen[t][g] && !scan_y_seen[t][g])
                        z_no_y = z_no_y + 1;
                end
            end
            $display("  summary: missing_y=%0d missing_beat_z=%0d missing_beat_x=%0d z_in_pipe_no_y=%0d",
                     miss_y, miss_z, miss_x, z_no_y);
            $display("  last scan_valid: tok=%0d grp=%0d | last beat_z: tok=%0d grp=%0d",
                     last_scan_tok, last_scan_grp, last_beat_z_tok, last_beat_z_grp);
            $display("[TB] === END PAIR GAP ===");
        end
    endtask

    initial begin
        y_samples = 0;
        y_unique_grps = 0;
        y_last_clk = 0;
        conv_last_clk = 0;
        last_conv_x = 0;
        beat_x_cnt = 0;
        beat_z_cnt = 0;
        scan_valid_cnt = 0;
        z_pend_set_cnt = 0;
        z_pend_stuck_cnt = 0;
        x_repair_dup_cnt = 0;
        pair_enq_cnt = 0;
        z_pend_prev = 1'b0;
        last_scan_tok = -1;
        last_scan_grp = -1;
        last_beat_z_tok = -1;
        last_beat_z_grp = -1;
        for (t = 0; t < NUM_VECTORS; t = t + 1)
            for (g = 0; g < GRPS; g = g + 1) begin
                beat_x_seen[t][g] = 1'b0;
                beat_z_seen[t][g] = 1'b0;
                scan_y_seen[t][g] = 1'b0;
                conv_x_seen[t][g] = 1'b0;
                conv_z_seen[t][g] = 1'b0;
            end
        feed_stall = 1'b0;
        drain_stall = 1'b0;
        feed_abort = 1'b0;
        scan_stream_done = 1'b0;
        for (idx = 0; idx < NUM_VECTORS * D_INNER; idx = idx + 1)
            y_cap_mem[idx] = 16'd0;
        x_cap_idx = 0;
        z_cap_idx = 0;
        global_clk = 0;

        $sformat(fname, "%s/input_full.mem", `CHAIN_RMS_VECTORS_DIR);
        $display("TB full chain: RMS input %s, NUM_VECTORS=%0d", fname, NUM_VECTORS);
        $readmemh(fname, in_mem);

        $sformat(fname, "%s/weight.mem", `CHAIN_RMS_VECTORS_DIR);
        $readmemh(fname, w_mem);
        gamma_vec = 0;
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            gamma_vec[ri*DATA_WIDTH +: DATA_WIDTH] = w_mem[ri];

        $sformat(fname, "%s/conv_weight.mem", `CHAIN_FB_VECTORS_DIR);
        $readmemh(fname, conv_w_mem);
        $sformat(fname, "%s/conv_bias.mem", `CHAIN_FB_VECTORS_DIR);
        $readmemh(fname, conv_b_mem);
        conv_w_packed = 0;
        conv_b_packed = 0;
        for (gi = 0; gi < D_INNER * 4; gi = gi + 1)
            conv_w_packed[gi*DATA_WIDTH +: DATA_WIDTH] = conv_w_mem[gi];
        for (gi = 0; gi < D_INNER; gi = gi + 1)
            conv_b_packed[gi*DATA_WIDTH +: DATA_WIDTH] = conv_b_mem[gi];

        load_weights();
        $display("[TB] weights loaded, starting DUT");

        rst_n = 0;
        en = 0;
        start = 0;
        #30;
        rst_n = 1;
        #20;
        en = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        $display("[TB] DUT started, waiting feed_complete (max %0d cycles)", SIM_MAX_CYCLES);
        while (!feed_complete && !feed_stall && !feed_abort && global_clk < SIM_MAX_CYCLES) begin
            @(posedge clk);
            global_clk = global_clk + 1;
            if (conv_x_capture_cnt != last_conv_x) begin
                last_conv_x = conv_x_capture_cnt;
                conv_last_clk = global_clk;
            end else if ((global_clk - conv_last_clk) > STALL_LIMIT) begin
                feed_stall = 1'b1;
                $display("[TB] FEED_WEDGE: conv stalled %0d cycles at conv_x=%0d",
                         STALL_LIMIT, conv_x_capture_cnt);
                $display("  beat_q=%0d ready=%b z_slot=%b x_skid=%b",
                         beat_q_count_dbg, beat_q_ready,
                         scan_z_slot_dbg, scan_x_skid_dbg);
                dump_wedge_state();
            end
            if ((global_clk % 10000) == 0)
                $display("[HB] clk=%0d feed_done=%b conv=%0d/%0d y=%0d scan_q=%0d",
                         global_clk, feed_complete,
                         conv_x_capture_cnt, conv_z_capture_cnt,
                         y_samples, scan_q_count_dbg);
        end
        if (feed_stall || feed_abort)
            $display("[TB] feed exit: conv wedge or feed_abort, entering drain");
        $display("[TB] feed_complete=%b feed_stall=%b at clk=%0d",
                 feed_complete, feed_stall, global_clk);

        idx = 0;
        while ((y_unique_grps < NUM_VECTORS * GRPS) &&
               (global_clk < SIM_MAX_CYCLES) && !drain_stall) begin
            @(posedge clk);
            idx = idx + 1;
            global_clk = global_clk + 1;
            if ((global_clk % 50000) == 0)
                $display("[HB drain] clk=%0d y_grp=%0d/%0d scan_q=%0d z_slot=%b scan_busy=%b",
                         global_clk, y_unique_grps, NUM_VECTORS * GRPS,
                         scan_q_count_dbg, scan_z_slot_dbg, scan_busy);
            if ((global_clk - y_last_clk) > STALL_LIMIT &&
                (scan_q_count_dbg == 0) && !scan_busy &&
                (y_unique_grps < NUM_VECTORS * GRPS)) begin
                drain_stall = 1'b1;
                $display("[TB] WEDGE: no y progress for %0d cycles", STALL_LIMIT);
                $display("  y_grp=%0d/%0d conv_x=%0d conv_z=%0d scan_q=%0d",
                         y_unique_grps, NUM_VECTORS * GRPS,
                         conv_x_capture_cnt, conv_z_capture_cnt, scan_q_count_dbg);
                $display("  z_slot=%b x_skid=%b conv_ready=%b scan_rdy=%b z_st=%b",
                         scan_z_slot_dbg, scan_x_skid_dbg, conv_beat_ready,
                         scan_ready, scan_z_state_dbg);
                dump_wedge_state();
            end
        end
        if (drain_stall)
            $display("[TB] drain exit: wedge in Scan_Chain_Wrapper (Z in z_slot without matching X)");
        if (!drain_stall && (y_unique_grps < NUM_VECTORS * GRPS))
            dump_wedge_state();
        report_pair_gaps();
        repeat (200) @(posedge clk);

        fp = $fopen("rtl_y_gated_chain.mem", "w");
        for (idx = 0; idx < NUM_VECTORS * D_INNER; idx = idx + 1)
            $fwrite(fp, "%04x\n", y_cap_mem[idx] & 16'hFFFF);
        $fclose(fp);

        fp = $fopen("rtl_h_state_chain.mem", "w");
`ifdef SCAN_H_LIVE
        for (idx = 0; idx < NUM_VECTORS * D_INNER * D_STATE; idx = idx + 1)
            $fwrite(fp, "%04x\n", rtl_h[idx] & 16'hFFFF);
`else
        for (idx = 0; idx < NUM_VECTORS * D_INNER * D_STATE; idx = idx + 1) begin
            u_scan.u_scan.h_rd_lin = idx;
            #1;
            $fwrite(fp, "%04x\n", u_scan.u_scan.h_rd_data);
        end
`endif
        $fclose(fp);

        fp = $fopen("rtl_output_conv_x_chain.mem", "w");
        for (idx = 0; idx < x_cap_idx * LANES; idx = idx + 1)
            $fwrite(fp, "%04x\n", x_cap_mem[idx]);
        $fclose(fp);

        fp = $fopen("rtl_output_conv_z_chain.mem", "w");
        for (idx = 0; idx < z_cap_idx * LANES; idx = idx + 1)
            $fwrite(fp, "%04x\n", z_cap_mem[idx]);
        $fclose(fp);

        $display("");
        $display("=== RMSNorm -> InProj -> Conv -> Scan PIPE (N=%0d) ===", NUM_VECTORS);
        $display("  conv_x=%0d conv_z=%0d beats_enq=%0d beat_drop=%b",
                 conv_x_capture_cnt, conv_z_capture_cnt, beats_enq_total, beat_q_drop);
        $display("  y_grps=%0d/%0d y_samples=%0d scan_busy=%b conv_beat_ready=%b",
                 y_unique_grps, NUM_VECTORS * GRPS, y_samples, scan_busy, conv_beat_ready);
        $display("  diag: beat_x=%0d beat_z=%0d scan_valid=%0d z_pend_set=%0d pair_enq=%0d x_repair_dup=%0d",
                 beat_x_cnt, beat_z_cnt, scan_valid_cnt, z_pend_set_cnt,
                 pair_enq_cnt, x_repair_dup_cnt);
        $display("  scan_q=%0d scan_rdy=%b head_x=%b z_slot=%b await=%b z_st=%b ypre=%b",
                 scan_q_count_dbg, scan_ready, scan_q_head_x_dbg,
                 scan_z_slot_dbg, scan_await_dbg,
                 scan_z_state_dbg, u_scan.u_scan.ypre_ready_mask);
        $display("  final_clk=%0d", global_clk);
        $display("=====================================================");

        if (y_unique_grps == NUM_VECTORS * GRPS)
            $display("SUCCESS: y capture count OK");
        else
            $display("FAIL: incomplete y capture (%0d/%0d grps)", y_unique_grps, NUM_VECTORS * GRPS);

        mon_print_summary();
        $finish;
    end

    initial begin
        #(SIM_TIMEOUT_NS);
        $display("TIMEOUT after %0d ns (N=%0d)", SIM_TIMEOUT_NS, NUM_VECTORS);
        $finish;
    end
endmodule
