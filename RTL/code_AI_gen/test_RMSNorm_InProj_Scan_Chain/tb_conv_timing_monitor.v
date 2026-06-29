`timescale 1ns/1ps
// Timing monitor: InProj beat spacing (X0,Z0,...) and Conv X/Z valid_out skew.
// Run: ./run_timing_monitor.sh
`include "chain_tb_paths.vh"

module tb_conv_timing_monitor;
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_INNER    = 128;
    localparam TAPS       = 8;
    localparam D_MODEL    = 64;
    localparam GRPS       = 8;
    localparam BEATS_PER_VEC = 16 * TAPS; // 128 input tap-clusters per token
    localparam NUM_VECTORS = 1;
    localparam CLK_PERIOD_NS = 10;
    localparam SIM_TIMEOUT_NS = 30_000_000;

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
    wire [4:0]  beat_q_count_dbg;
    wire        beat_q_drop;
    wire [15:0] beats_enq_total;

    integer global_clk;
    integer inproj_x_clk [0:GRPS-1];
    integer inproj_z_clk [0:GRPS-1];
    integer conv_x_clk   [0:GRPS-1];
    integer conv_z_clk   [0:GRPS-1];
    integer inproj_pairs;
    integer conv_pairs;
    integer gi;
    integer delta;
    integer expect_beats;

    reg [D_MODEL*DATA_WIDTH-1:0] x_vec_hold;
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_drv;

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
        .beats_enq_total(beats_enq_total),
        .beats_enq_x_dbg(),
        .beats_enq_z_dbg(),
        .scan_x_beat_ready(1'b1),
        .scan_z_beat_ready(1'b1),
        .scan_x_grp_ready(8'hff),
        .scan_z_grp_ready(8'hff)
    );

    always #5 clk = ~clk;

    reg [15:0] in_mem [0:NUM_VECTORS*D_MODEL-1];
    reg [15:0] w_mem  [0:D_MODEL-1];
    reg [15:0] conv_w_mem [0:D_INNER*4-1];
    reg [15:0] conv_b_mem [0:D_INNER-1];

    reg signed [DATA_WIDTH-1:0] xvec [0:D_MODEL-1];
    reg [2:0] tb_tick;

    integer li, idx, ri, v, k, st;
    integer fp, fh, ret;
    reg [8*512-1:0] fname;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;

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
        end
    endtask

    // --- InProj output beat monitor: only final tap (tick==7) per macro block ---
    always @(posedge clk) begin
        if (rst_n && dut.u_inproj.vld_pipe[6] &&
            (dut.u_inproj.tick_cnt_pipe[6] == (TAPS - 1)) &&
            (dut.inproj_active_token == 0)) begin
            gi = dut.u_inproj.grp_idx_pipe[6][2:0];
            if (dut.u_inproj.type_pipe[6] == 1'b0) begin
                inproj_x_clk[gi] = global_clk;
                $display("[CHECK INPROJ] clk=%0d tok=0 grp=%0d path=X tick=7",
                         global_clk, gi);
            end else begin
                inproj_z_clk[gi] = global_clk;
                delta = global_clk - inproj_x_clk[gi];
                inproj_pairs = inproj_pairs + 1;
                $display("[CHECK INPROJ] clk=%0d tok=0 grp=%0d path=Z tick=7 delta_from_X=%0d",
                         global_clk, gi, delta);
            end
        end
    end

    // --- beat_q enqueue monitor (one beat per macro block) ---
    always @(posedge clk) begin
        if (rst_n && (dut.beat_q_enq_x || dut.beat_q_enq_z) && dut.inproj_active_token == 0 &&
            (dut.u_inproj.tick_cnt_pipe[6] == (TAPS - 1)))
            $display("[CHECK BEAT_Q] clk=%0d enq tok=%0d grp=%0d path=%s q_cnt=%0d",
                     global_clk, dut.inproj_active_token,
                     dut.u_inproj.grp_idx_pipe[6],
                     dut.u_inproj.type_pipe[6] ? "Z" : "X",
                     beat_q_count_dbg);
    end

    // --- Conv valid_out monitor ---
    always @(posedge clk) begin
        if (rst_n && conv_x_valid_out && dut.u_conv.x_out_token == 0) begin
            gi = dut.u_conv.x_out_grp;
            conv_x_clk[gi] = global_clk;
            $display("[CHECK CONV] clk=%0d tok=0 grp=%0d path=X ready_in=%b",
                     global_clk, gi, conv_ready_in);
        end
        if (rst_n && conv_z_valid_out && dut.u_conv.z_out_token == 0) begin
            gi = dut.u_conv.z_out_grp;
            conv_z_clk[gi] = global_clk;
            delta = global_clk - conv_x_clk[gi];
            conv_pairs = conv_pairs + 1;
            $display("[CHECK CONV] clk=%0d tok=0 grp=%0d path=Z ready_in=%b delta_from_X=%0d",
                     global_clk, gi, conv_ready_in, delta);
        end
    end

    initial begin : FEED_SER
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
        tb_tick = 0;
        frame_done = 0;
        feed_idle = 0;

        wait(inproj_streaming);
        load_xvec_from_dut();
        tb_tick = 0;
        drive_one_beat();
        @(posedge clk);

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            tb_tick = 0;
            for (k = 0; k < BEATS_PER_VEC; k = k + 1) begin
                drive_one_beat();
                if (k == BEATS_PER_VEC - 1)
                    frame_done = 1'b1;
                @(posedge clk);
                frame_done = 1'b0;
            end
        end
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
    end

    always @(*) begin
        x_vec_hold = {D_MODEL*DATA_WIDTH{1'b0}};
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            x_vec_hold[ri*DATA_WIDTH +: DATA_WIDTH] =
                in_mem[dut.rms_sample_idx*D_MODEL + ri];
    end

    initial begin
        global_clk = 0;
        inproj_pairs = 0;
        conv_pairs = 0;
        for (gi = 0; gi < GRPS; gi = gi + 1) begin
            inproj_x_clk[gi] = -1;
            inproj_z_clk[gi] = -1;
            conv_x_clk[gi]   = -1;
            conv_z_clk[gi]   = -1;
        end

        $sformat(fname, "%s/input_full.mem", `CHAIN_RMS_VECTORS_DIR);
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

        expect_beats = GRPS * 2; // 8 X + 8 Z macro beats
        while (!feed_complete && global_clk < 500_000) begin
            @(posedge clk);
            global_clk = global_clk + 1;
        end

        // Wait until all conv beats for token 0 are captured
        while ((conv_x_capture_cnt < GRPS || conv_z_capture_cnt < GRPS) &&
               global_clk < 500_000) begin
            @(posedge clk);
            global_clk = global_clk + 1;
        end
        repeat (50) @(posedge clk);

        $display("");
        $display("=== TIMING SUMMARY (token 0, expect %0d X/Z pairs) ===", GRPS);
        for (gi = 0; gi < GRPS; gi = gi + 1) begin
            delta = inproj_z_clk[gi] - inproj_x_clk[gi];
            $display("[SUMMARY INPROJ] grp=%0d X@%0d Z@%0d delta=%0d (8 input beats => %0d clk @2clk/tap)",
                     gi, inproj_x_clk[gi], inproj_z_clk[gi], delta, delta / 2);
        end
        for (gi = 0; gi < GRPS; gi = gi + 1) begin
            delta = conv_z_clk[gi] - conv_x_clk[gi];
            $display("[SUMMARY CONV] grp=%0d X@%0d Z@%0d delta=Z-X=%0d (Z_lead=%0d clk)",
                     gi, conv_x_clk[gi], conv_z_clk[gi], delta,
                     (conv_z_clk[gi] < conv_x_clk[gi]) ?
                         (conv_x_clk[gi] - conv_z_clk[gi]) : 0);
        end
        $display("  inproj_pairs=%0d conv_pairs=%0d conv_x=%0d conv_z=%0d beat_drop=%b",
                 inproj_pairs, conv_pairs, conv_x_capture_cnt, conv_z_capture_cnt, beat_q_drop);
        $display("  beats_enq=%0d expect=%0d final_clk=%0d",
                 beats_enq_total, expect_beats, global_clk);
        $display("======================================================");

        if (inproj_pairs == GRPS && conv_pairs == GRPS &&
            conv_x_capture_cnt == GRPS && conv_z_capture_cnt == GRPS &&
            beats_enq_total == expect_beats && !beat_q_drop)
            $display("SUCCESS: timing monitor complete");
        else
            $display("FAIL: incomplete beat capture");

        $finish;
    end

    always @(posedge clk)
        if (rst_n) global_clk = global_clk + 1;

    initial begin
        #(SIM_TIMEOUT_NS);
        $display("TIMEOUT");
        $finish;
    end
endmodule
