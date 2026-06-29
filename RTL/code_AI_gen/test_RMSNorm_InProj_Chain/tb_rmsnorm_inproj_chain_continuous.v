`timescale 1ns/1ps
// Continuous chain test: RMSNorm -> scheduler wrapper -> In_Projection v2 (1000 tokens).
// InProj beats are fed from dut.norm_buf (RMS output), not from a separate mem file.
`include "chain_tb_paths.vh"

module tb_rmsnorm_inproj_chain_continuous();
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam TAPS       = 8;
    localparam D_MODEL    = 64;
    localparam BEATS_PER_VEC = 16 * TAPS;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 1000;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam TOTAL_IN  = NUM_VECTORS * D_MODEL;
    localparam TOTAL_OUT = NUM_VECTORS * 256;
    localparam DRAIN_TIMEOUT = 8000;

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;
    reg frame_done = 0;
    reg feed_idle = 0;

    reg [D_MODEL*DATA_WIDTH-1:0] gamma_vec;

    wire signed [LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z;
    wire chain_busy, inproj_streaming, feed_active, feed_complete, feed_ready;
    wire [15:0] stream_token_idx;
    wire [15:0] rms_sample_idx;
    wire rms_arm_pulse;

    reg [D_MODEL*DATA_WIDTH-1:0] x_vec_hold;
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_drv;

    RMSNorm_InProj_Chain_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
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
        .rms_sample_idx(rms_sample_idx),
        .rms_arm_pulse(rms_arm_pulse),
        .y_out(y_out),
        .done_x(done_x),
        .done_z(done_z),
        .chain_busy(chain_busy),
        .stream_token_idx(stream_token_idx),
        .inproj_streaming(inproj_streaming),
        .feed_active(feed_active),
        .feed_complete(feed_complete),
        .feed_ready(feed_ready)
    );

    always #5 clk = ~clk;

    reg [15:0] in_mem [0:TOTAL_IN-1];
    reg [15:0] w_mem  [0:D_MODEL-1];
    reg [15:0] out_mem [0:TOTAL_OUT-1];
    reg [15:0] norm_cap_mem [0:TOTAL_IN-1];
    reg [15:0] out_vec_buf [0:255];

    reg signed [DATA_WIDTH-1:0] xvec [0:D_MODEL-1];
    reg [2:0] tb_tick;

    integer li, idx, ri, lane, gi, v, k;
    integer fp, fh, ret;
    integer global_clk;
    integer capture_frame;
    integer groups_in_frame;
    integer total_captures;
    integer done_z_count;
    integer done_z_frame;
    reg done_z_d;
    reg capture_en;
    reg [8*512-1:0] fname;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;

    task automatic load_xvec_from_dut;
        begin
            for (ri = 0; ri < D_MODEL; ri = ri + 1)
                xvec[ri] = dut.norm_buf[ri];
        end
    endtask

    task automatic capture_norm_buf;
        input integer vec_idx;
        begin
            load_xvec_from_dut();
            for (ri = 0; ri < D_MODEL; ri = ri + 1)
                norm_cap_mem[vec_idx*D_MODEL + ri] = xvec[ri][15:0];
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

    initial begin : FEED_SER
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
        tb_tick = 0;
        frame_done = 0;
        feed_idle = 0;

        wait(inproj_streaming);
        capture_norm_buf(0);

        load_xvec_from_dut();
        tb_tick = 0;
        drive_one_beat();
        @(posedge clk);

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            tb_tick = 0;
            for (k = 0; k < BEATS_PER_VEC; k = k + 1) begin
                drive_one_beat();
                if (k == BEATS_PER_VEC - 1) begin
                    if (v + 1 < NUM_VECTORS) begin
                        feed_idle = 1'b1;
                        while (!feed_ready)
                            @(posedge clk);
                        feed_idle = 1'b0;
                    end
                    frame_done = 1'b1;
                end
                @(posedge clk);
                frame_done = 1'b0;
                if ((k == BEATS_PER_VEC - 1) && (v + 1 < NUM_VECTORS)) begin
                    while (stream_token_idx != (v + 1))
                        @(posedge clk);
                    load_xvec_from_dut();
                end
            end
            if (v + 1 < NUM_VECTORS)
                capture_norm_buf(v + 1);
        end
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
    end

    always @(*) begin
        x_vec_hold = {D_MODEL*DATA_WIDTH{1'b0}};
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            x_vec_hold[ri*DATA_WIDTH +: DATA_WIDTH] =
                in_mem[rms_sample_idx*D_MODEL + ri];
    end

    always @(posedge clk) begin
        done_z_d <= done_z;
        if (!rst_n)
            global_clk <= 0;
        else if (en)
            global_clk <= global_clk + 1;
    end

    always @(posedge clk) begin
        if (capture_en && capture_frame < NUM_VECTORS) begin
            if (dut.u_inproj.vld_pipe[6] && dut.u_inproj.tick_cnt_pipe[6] == (TAPS - 1)) begin
                gi = dut.u_inproj.grp_idx_pipe[6];
                for (lane = 0; lane < LANES; lane = lane + 1)
                    out_vec_buf[gi*LANES + lane] =
                        y_out[lane*DATA_WIDTH +: DATA_WIDTH];
                groups_in_frame = groups_in_frame + 1;
                total_captures = total_captures + 1;

                if (groups_in_frame == 16) begin
                    for (idx = 0; idx < 256; idx = idx + 1)
                        out_mem[capture_frame*256 + idx] = out_vec_buf[idx];
                    capture_frame = capture_frame + 1;
                    groups_in_frame = 0;
                end
            end
            if (done_z && !done_z_d) begin
                done_z_count = done_z_count + 1;
                done_z_frame = done_z_frame + 1;
            end
        end
    end

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

    initial begin
        $sformat(fname, "%s/rtl_output_chain_continuous.mem", `CHAIN_TEST_ROOT);
        fp = $fopen(fname, "w");
        if (fp == 0)
            $fatal(1, "TB: cannot open output file %s", fname);

        capture_en = 0;
        capture_frame = 0;
        groups_in_frame = 0;
        total_captures = 0;
        global_clk = 0;
        done_z_count = 0;
        done_z_frame = 0;
        done_z_d = 0;

        $sformat(fname, "%s/input_full.mem", `CHAIN_RMS_VECTORS_DIR);
        $display("TB chain: load RMS input %s, NUM_VECTORS=%0d", fname, NUM_VECTORS);
        $readmemh(fname, in_mem);

        $sformat(fname, "%s/weight.mem", `CHAIN_RMS_VECTORS_DIR);
        $readmemh(fname, w_mem);
        gamma_vec = 0;
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            gamma_vec[ri*DATA_WIDTH +: DATA_WIDTH] = w_mem[ri];

        load_weights();

        rst_n = 0;
        en = 0;
        start = 0;
        #30;
        rst_n = 1;
        #20;
        en = 1;
        capture_en = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        while (!feed_complete && global_clk < 200000) begin
            @(posedge clk);
            if ((global_clk % 5000) == 0)
                $display("TB: clk=%0d feed=%0d cap=%0d/%0d rms_idx=%0d tok=%0d",
                         global_clk, feed_active, capture_frame, NUM_VECTORS,
                         rms_sample_idx, stream_token_idx);
        end

        idx = 0;
        while ((capture_frame < NUM_VECTORS) && (idx < DRAIN_TIMEOUT)) begin
            @(posedge clk);
            idx = idx + 1;
        end
        capture_en = 0;
        @(posedge clk);

        for (idx = 0; idx < TOTAL_OUT; idx = idx + 1)
            $fwrite(fp, "%04x\n", out_mem[idx]);
        $fflush(fp);
        $fclose(fp);

        $sformat(fname, "%s/rtl_norm_per_token.mem", `CHAIN_TEST_ROOT);
        fp = $fopen(fname, "w");
        if (fp == 0)
            $fatal(1, "TB: cannot open norm capture file %s", fname);
        for (idx = 0; idx < TOTAL_IN; idx = idx + 1)
            $fwrite(fp, "%04x\n", norm_cap_mem[idx]);
        $fflush(fp);
        $fclose(fp);

        $display("");
        $display("=== RMSNorm -> InProj CHAIN (NUM_VECTORS=%0d) ===", NUM_VECTORS);
        $display("  captures=%0d  frames=%0d  done_z=%0d  final_clk=%0d",
                 total_captures, capture_frame, done_z_count, global_clk);
        $display("==================================================");

        if (capture_frame == NUM_VECTORS)
            $display("SUCCESS: captured %0d chain frames", NUM_VECTORS);
        else
            $display("FAIL: incomplete capture %0d / %0d", capture_frame, NUM_VECTORS);
        $finish;
    end

endmodule
