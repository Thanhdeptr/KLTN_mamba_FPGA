`timescale 1ns/1ps
// RMSNorm -> InProj -> Conv -> Scan -> OutProj (Mamba_Streaming_Block_Wrapper).
`include "streaming_chain_tb_paths.vh"

module tb_mamba_streaming_chain;
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_INNER    = 128;
    localparam D_STATE    = 16;
    localparam TAPS       = 8;
    localparam D_MODEL    = 64;
    localparam GRPS       = 8;
    localparam BEATS_PER_VEC = LANES * TAPS;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 10;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam CLK_PERIOD_NS  = 10;
    localparam SIM_TIMEOUT_NS = (NUM_VECTORS <= 10) ? 400_000_000 :
                                (NUM_VECTORS * 800_000);
    localparam SIM_MAX_CYCLES = SIM_TIMEOUT_NS / CLK_PERIOD_NS;
    localparam STALL_LIMIT    = (NUM_VECTORS <= 10) ? 80_000 :
                                (NUM_VECTORS * 8_000);

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;
    reg frame_done = 0;
    reg feed_idle = 0;

    reg [D_MODEL*DATA_WIDTH-1:0] gamma_vec;
    reg signed [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed;
    reg signed [D_INNER*DATA_WIDTH-1:0] conv_b_packed;
    reg [D_MODEL*D_INNER*DATA_WIDTH-1:0] outproj_w_packed;

    wire signed [LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z;
    wire signed [LANES*DATA_WIDTH-1:0] conv_x_out, conv_z_out;
    wire conv_x_valid_out, conv_z_valid_out, conv_ready_in;
    wire chain_busy, inproj_streaming, feed_active, feed_complete, feed_ready;
    wire [15:0] stream_token_idx;
    wire [15:0] conv_x_capture_cnt, conv_z_capture_cnt;
    wire [6:0]  beat_q_count_dbg;
    wire        beat_q_drop;
    wire [15:0] beats_enq_total;

    wire conv_beat_ready;
    wire scan_valid;
    wire [15:0] scan_token;
    wire [2:0]  scan_grp;
    wire signed [LANES*DATA_WIDTH-1:0] scan_y_vec;
    wire scan_busy, scan_ready;

    wire out_valid;
    wire [15:0] out_token;
    wire signed [D_MODEL*DATA_WIDTH-1:0] out_vec;
    wire outproj_busy, outproj_beat_ready;
    wire [9:0] outfifo_count_dbg;
    wire       outfifo_stall_dbg;
    wire [1:0] outproj_sm_dbg;
    wire [15:0] outproj_release_tok_dbg;
    wire [7:0] outproj_asm_mask_dbg;
    wire [15:0] outproj_fifo_head_tok_dbg;
    wire outproj_beats_done_dbg;
    wire [7:0] outproj_feed_beat_cnt_dbg;

    wire beat_q_ready = dut.u_chain.u_chain.beat_q_ready;
    wire [13:0] scan_q_count_dbg = dut.u_chain.u_scan.mon_q_count;

    reg feed_stall;
    reg drain_stall;
    reg feed_abort;
    reg [D_MODEL*DATA_WIDTH-1:0] x_vec_hold;
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_drv;

    integer global_clk;
    integer mon_clk;
    integer lat_start;
    integer lat_first_inproj_x;
    integer lat_last_inproj_beat;
    integer lat_first_conv_x;
    integer lat_first_scan;
    integer lat_feed_complete;
    integer lat_first_out;
    integer lat_token0_out;
    integer y_unique_grps;
    integer y_last_clk;
    integer out_count;
    integer conv_last_clk;
    integer last_conv_x;

    reg scan_y_seen [0:NUM_VECTORS-1][0:GRPS-1];
    reg out_seen [0:NUM_VECTORS-1];

    integer mon_feed_abort_tok;
    integer mon_feed_abort_beat;
    integer mon_feed_beatq_wait_max;
    integer mon_feed_frm_wait_max;
    integer mon_feed_tok_wait_max;
    integer mon_fp;

    localparam SCAN_CHAIN_Q = (NUM_VECTORS * GRPS) + 1024;
    localparam NUM_EXEC_SIM = 1;

    Mamba_Streaming_Block_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .TAPS(TAPS),
        .LANES(LANES),
        .NUM_TOKENS(NUM_VECTORS),
        .SCAN_MAX_TOKENS(1000),
        .CHAIN_Q_DEPTH(SCAN_CHAIN_Q),
        .NUM_EXEC(NUM_EXEC_SIM),
        .OUTPROJ_NUM_MAC(4)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .start(start),
        .frame_done(frame_done),
        .feed_idle(feed_idle),
        .scan_clear_h(1'b0),
        .x_vec_in(x_vec_hold),
        .gamma_vec(gamma_vec),
        .x_sub_vec_in(x_sub_vec_drv),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .outproj_w_packed(outproj_w_packed),
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
        .conv_beat_ready(conv_beat_ready),
        .out_valid(out_valid),
        .out_token(out_token),
        .out_vec(out_vec),
        .outproj_busy(outproj_busy),
        .outproj_beat_ready(outproj_beat_ready),
        .outfifo_count_dbg(outfifo_count_dbg),
        .outfifo_stall_dbg(outfifo_stall_dbg),
        .outproj_sm_dbg(outproj_sm_dbg),
        .outproj_release_tok_dbg(outproj_release_tok_dbg),
        .outproj_asm_mask_dbg(outproj_asm_mask_dbg),
        .outproj_fifo_head_tok_dbg(outproj_fifo_head_tok_dbg),
        .outproj_beats_done_dbg(outproj_beats_done_dbg),
        .outproj_feed_beat_cnt_dbg(outproj_feed_beat_cnt_dbg)
    );

    always #5 clk = ~clk;

    reg [15:0] in_mem [0:NUM_VECTORS*D_MODEL-1];
    reg [15:0] w_mem  [0:D_MODEL-1];
    reg [15:0] conv_w_mem [0:D_INNER*4-1];
    reg [15:0] conv_b_mem [0:D_INNER-1];
    reg [15:0] outproj_w_mem [0:D_MODEL*D_INNER-1];
    reg [15:0] out_cap_mem [0:NUM_VECTORS*D_MODEL-1];
    reg [15:0] y_cap_mem [0:NUM_VECTORS*D_INNER-1];
    reg [15:0] x_cap_mem [0:NUM_VECTORS*8*LANES-1];
    reg [15:0] z_cap_mem [0:NUM_VECTORS*8*LANES-1];

    integer x_cap_idx, z_cap_idx;
    integer lane;

    reg signed [DATA_WIDTH-1:0] xvec [0:D_MODEL-1];
    reg [2:0] tb_tick;

    integer li, idx, ri, gi, v, k, t, g, st;
    integer y_lane, y_ch;
    integer fp, fh, ret;
    reg [8*512-1:0] fname;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;

    task automatic load_xvec_from_dut;
        begin
            for (ri = 0; ri < D_MODEL; ri = ri + 1)
                xvec[ri] = dut.u_chain.u_chain.norm_buf[ri];
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
                    dut.u_chain.u_chain.u_inproj.bram_mem[li][idx] = val;
                end
                $fclose(fh);
            end
            $display("[TB] InProj weights loaded");
        end
    endtask

    task automatic dump_outproj_state;
        begin
            $display("[TB] outproj: sm=%0d rel_tok=%0d asm_mask=%b fifo_cnt=%0d head_tok=%0d beats_done=%b feed_cnt=%0d outproj_busy=%b beat_rdy=%b",
                     outproj_sm_dbg, outproj_release_tok_dbg, outproj_asm_mask_dbg,
                     outfifo_count_dbg, outproj_fifo_head_tok_dbg,
                     outproj_beats_done_dbg, outproj_feed_beat_cnt_dbg,
                     outproj_busy, outproj_beat_ready);
        end
    endtask

    task automatic dump_wedge_state;
        begin
            $display("[TB] wedge: conv_x=%0d conv_z=%0d y_grp=%0d/%0d out=%0d/%0d fifo=%0d stall=%b scan_busy=%b",
                     conv_x_capture_cnt, conv_z_capture_cnt,
                     y_unique_grps, NUM_VECTORS * GRPS,
                     out_count, NUM_VECTORS,
                     outfifo_count_dbg, outfifo_stall_dbg, scan_busy);
            dump_outproj_state();
        end
    endtask

`include "../test_RMSNorm_InProj_Scan_Chain/chain_tb_feed_guard.vh"

    always @(posedge clk) begin
        if (rst_n)
            mon_clk <= mon_clk + 1;
    end

    always @(posedge clk) begin
        if (rst_n && start && (lat_start < 0))
            lat_start <= mon_clk;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            mon_clk <= 0;
            lat_start <= -1;
            lat_first_inproj_x <= -1;
            lat_last_inproj_beat <= -1;
            lat_first_conv_x <= -1;
            lat_first_scan <= -1;
            lat_feed_complete <= -1;
            lat_first_out <= -1;
            lat_token0_out <= -1;
        end else begin
            if (dut.u_chain.u_chain.u_inproj.vld_pipe[6] &&
                (dut.u_chain.u_chain.u_inproj.tick_cnt_pipe[6] == (TAPS - 1)) &&
                (dut.u_chain.u_chain.inproj_active_token == 0)) begin
                lat_last_inproj_beat <= mon_clk;
                if (!dut.u_chain.u_chain.u_inproj.type_pipe[6] &&
                    (dut.u_chain.u_chain.u_inproj.grp_idx_pipe[6][2:0] == 3'd0) &&
                    (lat_first_inproj_x < 0))
                    lat_first_inproj_x <= mon_clk;
            end
            if (conv_x_valid_out && (dut.u_chain.u_chain.u_conv.x_out_token == 0) &&
                (dut.u_chain.u_chain.u_conv.x_out_grp == 3'd0) && (lat_first_conv_x < 0))
                lat_first_conv_x <= mon_clk;
            if (scan_valid && (scan_token == 0) && (lat_first_scan < 0))
                lat_first_scan <= mon_clk;
            if (feed_complete && (lat_feed_complete < 0))
                lat_feed_complete <= mon_clk;
            if (out_valid && en && (lat_first_out < 0))
                lat_first_out <= mon_clk;
            if (out_valid && en && (out_token == 0) && (lat_token0_out < 0))
                lat_token0_out <= mon_clk;
        end
    end

    always @(posedge clk) begin
        if (conv_x_valid_out) begin
            for (lane = 0; lane < LANES; lane = lane + 1)
                x_cap_mem[x_cap_idx * LANES + lane] =
                    conv_x_out[lane*DATA_WIDTH +: DATA_WIDTH];
            x_cap_idx = x_cap_idx + 1;
        end
        if (conv_z_valid_out) begin
            for (lane = 0; lane < LANES; lane = lane + 1)
                z_cap_mem[z_cap_idx * LANES + lane] =
                    conv_z_out[lane*DATA_WIDTH +: DATA_WIDTH];
            z_cap_idx = z_cap_idx + 1;
        end
        if (scan_valid) begin
            y_last_clk = global_clk;
            if (!scan_y_seen[scan_token][scan_grp]) begin
                scan_y_seen[scan_token][scan_grp] = 1'b1;
                y_unique_grps = y_unique_grps + 1;
                for (y_lane = 0; y_lane < LANES; y_lane = y_lane + 1) begin
                    y_ch = scan_grp * LANES + y_lane;
                    y_cap_mem[scan_token * D_INNER + y_ch] =
                        scan_y_vec[y_lane*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
        if (out_valid && en) begin
            if (!out_seen[out_token]) begin
                out_seen[out_token] = 1'b1;
                out_count = out_count + 1;
                for (ri = 0; ri < D_MODEL; ri = ri + 1)
                    out_cap_mem[out_token*D_MODEL + ri] =
                        out_vec[ri*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end

    initial begin : FEED_SER
        reg feed_to;
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
        tb_tick = 0;
        frame_done = 0;
        feed_idle = 0;
        mon_fp = 0;

        wait(inproj_streaming);
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
            $display("[TB] FEED_SER abort tok=%0d beat=%0d", mon_feed_abort_tok, mon_feed_abort_beat);
        else
            $display("[TB] FEED_SER done %0d tokens", NUM_VECTORS);
    end

    always @(*) begin
        x_vec_hold = {D_MODEL*DATA_WIDTH{1'b0}};
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            x_vec_hold[ri*DATA_WIDTH +: DATA_WIDTH] =
                in_mem[dut.u_chain.u_chain.rms_sample_idx*D_MODEL + ri];
    end

    initial begin
        y_unique_grps = 0;
        y_last_clk = 0;
        out_count = 0;
        x_cap_idx = 0;
        z_cap_idx = 0;
        conv_last_clk = 0;
        last_conv_x = 0;
        mon_feed_abort_tok = -1;
        mon_feed_abort_beat = -1;
        mon_feed_beatq_wait_max = 0;
        mon_feed_frm_wait_max = 0;
        mon_feed_tok_wait_max = 0;
        for (t = 0; t < NUM_VECTORS; t = t + 1) begin
            out_seen[t] = 1'b0;
            for (g = 0; g < GRPS; g = g + 1)
                scan_y_seen[t][g] = 1'b0;
        end
        feed_stall = 1'b0;
        drain_stall = 1'b0;
        feed_abort = 1'b0;
        global_clk = 0;
        mon_clk = 0;
        lat_start = -1;
        lat_first_inproj_x = -1;
        lat_last_inproj_beat = -1;
        lat_first_conv_x = -1;
        lat_first_scan = -1;
        lat_feed_complete = -1;
        lat_first_out = -1;
        lat_token0_out = -1;

        $sformat(fname, "%s/input_full.mem", `CHAIN_RMS_VECTORS_DIR);
        $display("TB mamba streaming: RMS input %s, NUM_VECTORS=%0d", fname, NUM_VECTORS);
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

        $sformat(fname, "%s/outproj_weight.mem", `CHAIN_FB_VECTORS_DIR);
        $readmemh(fname, outproj_w_mem);
        outproj_w_packed = 0;
        for (gi = 0; gi < D_MODEL * D_INNER; gi = gi + 1)
            outproj_w_packed[gi*DATA_WIDTH +: DATA_WIDTH] = outproj_w_mem[gi];

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

        $display("[TB] waiting feed_complete (max %0d cycles)", SIM_MAX_CYCLES);
        while (!feed_complete && !feed_stall && !feed_abort && global_clk < SIM_MAX_CYCLES) begin
            @(posedge clk);
            global_clk = global_clk + 1;
            if (conv_x_capture_cnt != last_conv_x) begin
                last_conv_x = conv_x_capture_cnt;
                conv_last_clk = global_clk;
            end else if ((global_clk - conv_last_clk) > STALL_LIMIT) begin
                feed_stall = 1'b1;
                $display("[TB] FEED_WEDGE: conv stalled %0d cycles", STALL_LIMIT);
                dump_wedge_state();
            end
            if ((global_clk % 20000) == 0)
                $display("[HB] clk=%0d feed_done=%b conv=%0d y_grp=%0d out=%0d fifo=%0d",
                         global_clk, feed_complete,
                         conv_x_capture_cnt, y_unique_grps, out_count, outfifo_count_dbg);
        end

        $display("[TB] drain: y_grp=%0d/%0d out=%0d/%0d",
                 y_unique_grps, NUM_VECTORS * GRPS, out_count, NUM_VECTORS);
        while ((out_count < NUM_VECTORS) && (global_clk < SIM_MAX_CYCLES) && !drain_stall) begin
            @(posedge clk);
            global_clk = global_clk + 1;
            if ((global_clk % 50000) == 0)
                $display("[HB drain] clk=%0d y_grp=%0d out=%0d sm=%0d rel=%0d asm=%b fifo=%0d head=%0d feed=%0d",
                         global_clk, y_unique_grps, out_count,
                         outproj_sm_dbg, outproj_release_tok_dbg, outproj_asm_mask_dbg,
                         outfifo_count_dbg, outproj_fifo_head_tok_dbg,
                         outproj_feed_beat_cnt_dbg);
            if ((global_clk - y_last_clk) > STALL_LIMIT &&
                (y_unique_grps < NUM_VECTORS * GRPS) &&
                !scan_busy && (out_count < NUM_VECTORS)) begin
                drain_stall = 1'b1;
                $display("[TB] WEDGE: scan drain stalled %0d cycles", STALL_LIMIT);
                dump_wedge_state();
            end
        end
        repeat (500) @(posedge clk);

        fp = $fopen("rtl_y_streaming.mem", "w");
        for (idx = 0; idx < NUM_VECTORS * D_INNER; idx = idx + 1)
            $fwrite(fp, "%04x\n", y_cap_mem[idx] & 16'hFFFF);
        $fclose(fp);

        fp = $fopen("rtl_output_conv_x_streaming.mem", "w");
        for (idx = 0; idx < NUM_VECTORS * 8 * LANES; idx = idx + 1)
            $fwrite(fp, "%04x\n", x_cap_mem[idx] & 16'hFFFF);
        $fclose(fp);

        fp = $fopen("rtl_output_conv_z_streaming.mem", "w");
        for (idx = 0; idx < NUM_VECTORS * 8 * LANES; idx = idx + 1)
            $fwrite(fp, "%04x\n", z_cap_mem[idx] & 16'hFFFF);
        $fclose(fp);

        fp = $fopen("rtl_final.mem", "w");
        for (idx = 0; idx < NUM_VECTORS * D_MODEL; idx = idx + 1)
            $fwrite(fp, "%04x\n", out_cap_mem[idx] & 16'hFFFF);
        $fclose(fp);

        $display("");
        $display("=== Mamba Streaming Block (N=%0d) ===", NUM_VECTORS);
        $display("  conv_x=%0d conv_z=%0d beats_enq=%0d beat_drop=%b",
                 conv_x_capture_cnt, conv_z_capture_cnt, beats_enq_total, beat_q_drop);
        $display("  y_grps=%0d/%0d out_tokens=%0d/%0d scan_busy=%b outproj_busy=%b",
                 y_unique_grps, NUM_VECTORS * GRPS, out_count, NUM_VECTORS,
                 scan_busy, outproj_busy);
        $display("  outfifo_max_stall=%b final_clk=%0d", outfifo_stall_dbg, global_clk);
        $display("[LATENCY] start=%0d first_inproj_X0=%0d last_inproj_beat=%0d",
                 lat_start, lat_first_inproj_x, lat_last_inproj_beat);
        $display("[LATENCY] first_conv_X0=%0d first_scan_valid=%0d feed_complete=%0d",
                 lat_first_conv_x, lat_first_scan, lat_feed_complete);
        $display("[LATENCY] first_out_valid=%0d token0_out_valid=%0d",
                 lat_first_out, lat_token0_out);
        if (lat_start >= 0 && lat_first_inproj_x >= 0 && lat_last_inproj_beat >= 0 &&
            lat_first_scan >= 0 && lat_first_conv_x >= 0) begin
            $display("[LATENCY] batch_model_first_scan~=%0d (InProj full token then Conv+Scan)",
                     lat_last_inproj_beat + (lat_first_scan - lat_first_inproj_x));
            $display("[LATENCY] overlap_saved_first_scan~=%0d cy (~%.1f%% of batch wait)",
                     lat_last_inproj_beat - lat_first_inproj_x,
                     100.0 * (lat_last_inproj_beat - lat_first_inproj_x) /
                     (lat_last_inproj_beat + (lat_first_scan - lat_first_inproj_x)));
        end
        $display("=======================================");

        if (out_count == NUM_VECTORS)
            $display("SUCCESS: out capture count OK");
        else
            $display("FAIL: incomplete out capture (%0d/%0d)", out_count, NUM_VECTORS);

        $finish;
    end

    initial begin
        #(SIM_TIMEOUT_NS);
        $display("TIMEOUT after %0d ns (N=%0d)", SIM_TIMEOUT_NS, NUM_VECTORS);
        $finish;
    end
endmodule
