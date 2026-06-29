`timescale 1ns/1ps
// RMSNorm -> InProj v2 -> Conv1D streaming chain (8 x + 8 z frames / token).
// InProj beats fed from dut.norm_buf (RMS output); RMS raw from test_RMSNorm/input_full.mem.
`include "chain_tb_paths.vh"

module tb_rmsnorm_inproj_conv_chain();
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_INNER    = 128;
    localparam TAPS       = 8;
    localparam D_MODEL    = 64;
    localparam BEATS_PER_VEC = 16 * TAPS;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 10;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam FRAMES_PER_TOKEN = 16;
    localparam TOTAL_X_OUT = NUM_VECTORS * 8 * LANES;
    localparam TOTAL_Z_OUT = NUM_VECTORS * 8 * LANES;
    localparam DRAIN_TIMEOUT = 200000;

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
    wire [15:0] rms_sample_idx;
    wire rms_arm_pulse;
    wire [15:0] conv_x_capture_cnt, conv_z_capture_cnt;
    wire [4:0]  beat_q_count_dbg;
    wire [15:0] beats_enq_total, beats_enq_x_dbg, beats_enq_z_dbg;
    wire        beat_q_drop;

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
        .rms_sample_idx(rms_sample_idx),
        .rms_arm_pulse(rms_arm_pulse),
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
        .beats_enq_x_dbg(beats_enq_x_dbg),
        .beats_enq_z_dbg(beats_enq_z_dbg),
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
    reg [15:0] x_cap_mem [0:TOTAL_X_OUT-1];
    reg [15:0] z_cap_mem [0:TOTAL_Z_OUT-1];

    reg signed [DATA_WIDTH-1:0] xvec [0:D_MODEL-1];
    reg [2:0] tb_tick;

    integer li, idx, ri, lane, gi, v, k;
    integer fp, fh, ret;
    integer global_clk;
    integer x_cap_idx, z_cap_idx;
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

    integer z_accept_cnt, x_accept_cnt;

    always @(posedge clk) begin
        if (dut.u_conv.valid_in && dut.conv_path_x && dut.conv_ready_in)
            x_accept_cnt = x_accept_cnt + 1;
        if (dut.u_conv.valid_in && !dut.conv_path_x && dut.conv_ready_in)
            z_accept_cnt = z_accept_cnt + 1;
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
        end
        x_sub_vec_drv = {TAPS*DATA_WIDTH{1'b0}};
    end

    always @(*) begin
        x_vec_hold = {D_MODEL*DATA_WIDTH{1'b0}};
        for (ri = 0; ri < D_MODEL; ri = ri + 1)
            x_vec_hold[ri*DATA_WIDTH +: DATA_WIDTH] =
                in_mem[rms_sample_idx*D_MODEL + ri];
    end

    initial begin
        x_cap_idx = 0;
        z_cap_idx = 0;
        x_accept_cnt = 0;
        z_accept_cnt = 0;
        global_clk = 0;

        $sformat(fname, "%s/input_full.mem", `CHAIN_RMS_VECTORS_DIR);
        $display("TB conv chain: load RMS input %s, NUM_VECTORS=%0d", fname, NUM_VECTORS);
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

        while (!feed_complete && global_clk < 500000) begin
            @(posedge clk);
            global_clk = global_clk + 1;
        end

        idx = 0;
        while (((x_cap_idx < NUM_VECTORS * 8) || (z_cap_idx < NUM_VECTORS * 8) ||
                (conv_x_capture_cnt < NUM_VECTORS * 8) || (conv_z_capture_cnt < NUM_VECTORS * 8)) &&
               (idx < DRAIN_TIMEOUT)) begin
            @(posedge clk);
            idx = idx + 1;
            global_clk = global_clk + 1;
        end
        repeat (20000) @(posedge clk);

        fp = $fopen("rtl_output_conv_x_chain.mem", "w");
        for (idx = 0; idx < x_cap_idx * LANES; idx = idx + 1)
            $fwrite(fp, "%04x\n", x_cap_mem[idx]);
        $fclose(fp);

        fp = $fopen("rtl_output_conv_z_chain.mem", "w");
        for (idx = 0; idx < z_cap_idx * LANES; idx = idx + 1)
            $fwrite(fp, "%04x\n", z_cap_mem[idx]);
        $fclose(fp);

        $display("");
        $display("=== RMSNorm -> InProj -> Conv CHAIN (N=%0d) ===", NUM_VECTORS);
        $display("  x_captures=%0d (expect %0d) dut=%0d",
                 x_cap_idx, NUM_VECTORS * 8, conv_x_capture_cnt);
        $display("  z_captures=%0d (expect %0d) dut=%0d",
                 z_cap_idx, NUM_VECTORS * 8, conv_z_capture_cnt);
        $display("  accepts: x=%0d z=%0d", x_accept_cnt, z_accept_cnt);
        $display("  beat_q_remain=%0d beats_enq=%0d (x=%0d z=%0d) beat_drop=%b",
                 beat_q_count_dbg, beats_enq_total, beats_enq_x_dbg, beats_enq_z_dbg, beat_q_drop);
        $display("  final_clk=%0d", global_clk);
        $display("================================================");

        if (x_cap_idx == NUM_VECTORS * 8 && z_cap_idx == NUM_VECTORS * 8)
            $display("SUCCESS: capture counts OK");
        else
            $display("FAIL: incomplete capture");

        $finish;
    end

endmodule
