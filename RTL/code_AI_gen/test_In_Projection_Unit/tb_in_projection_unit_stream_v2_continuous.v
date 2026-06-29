`timescale 1ns/1ps
// Continuous multi-frame v2 test: keep start=1 and stream N vectors back-to-back
// (no pulse_reset between timesteps, no start=0 gap between frames).
// Compare vs golden_output_full.mem — expect mismatch if RTL/TB framing differs.
`include "inproj_tb_paths.vh"

module tb_in_projection_unit_stream_v2_continuous();
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam TAPS       = 8;
    localparam BEATS_PER_VEC = 16 * TAPS;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 10;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam TOTAL_IN  = NUM_VECTORS * 64;
    localparam TOTAL_OUT = NUM_VECTORS * 256;
    localparam DRAIN_TIMEOUT = 5000;

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;

    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in;
    wire signed [LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z;

    In_Projection_Unit_Streaming_v2 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .start(start),
        .x_sub_vec_in(x_sub_vec_in), .y_out(y_out),
        .done_x(done_x), .done_z(done_z)
    );

    always #5 clk = ~clk;

    reg [15:0] in_mem [0:TOTAL_IN-1];
    reg signed [DATA_WIDTH-1:0] xvec [0:63];
    reg [15:0] out_mem [0:TOTAL_OUT-1];
    reg [15:0] out_vec_buf [0:255];

    integer fp;
    integer li, idx, ri, lane, v, k, gi;
    integer tb_tick;
    integer feed_vector;
    integer capture_frame;
    integer groups_in_frame;
    integer total_captures;
    integer global_clk;
    integer feed_end_clk;
    integer first_cap_clk;
    integer last_cap_clk;
    integer done_z_count;
    integer vec_feed_start [0:NUM_VECTORS-1];
    integer vec_feed_end [0:NUM_VECTORS-1];
    integer vec_first_cap [0:NUM_VECTORS-1];
    integer vec_frame_done [0:NUM_VECTORS-1];
    integer vec_done_z_clk [0:NUM_VECTORS-1];
    integer done_z_frame;
    reg done_z_d;
    reg capture_en;
    reg [TAPS*DATA_WIDTH-1:0] build;
    reg [8*512-1:0] fname;
    integer fh;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;
    integer ret;
    reg vec_seen [0:15];

    always @(posedge clk) begin
        done_z_d <= done_z;
        if (!rst_n)
            global_clk <= 0;
        else if (en)
            global_clk <= global_clk + 1;
    end

    // Capture output groups; advance frame every 16 groups (one timestep).
    always @(posedge clk) begin
        if (capture_en && capture_frame < NUM_VECTORS) begin
            if (dut.vld_pipe[6] && dut.tick_cnt_pipe[6] == (TAPS - 1)) begin
                gi = dut.grp_idx_pipe[6];
                if (first_cap_clk < 0)
                    first_cap_clk = global_clk;
                last_cap_clk = global_clk;
                if (groups_in_frame == 0)
                    vec_first_cap[capture_frame] = global_clk;
                for (lane = 0; lane < LANES; lane = lane + 1)
                    out_vec_buf[gi*LANES + lane] =
                        dut.y_out[lane*DATA_WIDTH +: DATA_WIDTH];
                vec_seen[gi] = 1'b1;
                groups_in_frame = groups_in_frame + 1;
                total_captures = total_captures + 1;

                if (groups_in_frame == 16) begin
                    for (idx = 0; idx < 256; idx = idx + 1)
                        out_mem[capture_frame*256 + idx] = out_vec_buf[idx];
                    vec_frame_done[capture_frame] = global_clk;
                    capture_frame = capture_frame + 1;
                    groups_in_frame = 0;
                end
            end
            if (done_z && !done_z_d) begin
                done_z_count = done_z_count + 1;
                if (done_z_frame < NUM_VECTORS)
                    vec_done_z_clk[done_z_frame] = global_clk;
                done_z_frame = done_z_frame + 1;
            end
        end
    end

    task automatic load_weights;
        begin
            for (li = 0; li < LANES; li = li + 1) begin
                $sformat(fname, "%s/banks/weight_lane_%0d.mem", `INPROJ_TEST_ROOT, li);
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
                    dut.bram_mem[li][idx] = val;
                end
                $fclose(fh);
            end
        end
    endtask

    task automatic load_xvec;
        input integer vec_idx;
        begin
            for (ri = 0; ri < 64; ri = ri + 1)
                xvec[ri] = $signed(in_mem[vec_idx*64 + ri]);
        end
    endtask

    task automatic drive_one_beat;
        begin
            build = { xvec[tb_tick*8 + 7], xvec[tb_tick*8 + 6],
                      xvec[tb_tick*8 + 5], xvec[tb_tick*8 + 4],
                      xvec[tb_tick*8 + 3], xvec[tb_tick*8 + 2],
                      xvec[tb_tick*8 + 1], xvec[tb_tick*8 + 0] };
            x_sub_vec_in = build;
            if (tb_tick == TAPS - 1) tb_tick = 0;
            else tb_tick = tb_tick + 1;
        end
    endtask

    initial begin
        $sformat(fname, "%s/rtl_output_v2_continuous.mem", `INPROJ_TEST_ROOT);
        fp = $fopen(fname, "w");
        if (fp == 0)
            $fatal(1, "TB: cannot open output file %s", fname);

        capture_en = 0;
        capture_frame = 0;
        groups_in_frame = 0;
        total_captures = 0;
        global_clk = 0;
        first_cap_clk = -1;
        last_cap_clk = -1;
        feed_end_clk = -1;
        done_z_count = 0;
        done_z_frame = 0;
        done_z_d = 0;
        tb_tick = 0;
        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            vec_feed_start[v] = -1;
            vec_feed_end[v] = -1;
            vec_first_cap[v] = -1;
            vec_frame_done[v] = -1;
            vec_done_z_clk[v] = -1;
        end

        $sformat(fname, "%s/input_full.mem", `INPROJ_VECTORS_DIR);
        $display("TB continuous v2: load %s, NUM_VECTORS=%0d", fname, NUM_VECTORS);
        $readmemh(fname, in_mem);
        load_weights();

        rst_n = 0;
        en = 0;
        start = 0;
        x_sub_vec_in = 0;
        #20;
        rst_n = 1;
        #20;
        en = 1;

        // --- Continuous feed: start stays high across all timesteps ---
        capture_en = 1;
        start = 1;
        load_xvec(0);
        tb_tick = 0;
        drive_one_beat();
        @(posedge clk); // warm-up edge (same as single-vector TB)

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            feed_vector = v;
            load_xvec(v);
            tb_tick = 0;
            vec_feed_start[v] = global_clk + 1;
            for (k = 0; k < BEATS_PER_VEC; k = k + 1) begin
                drive_one_beat();
                @(posedge clk);
            end
            vec_feed_end[v] = global_clk;
            if ((v % 100) == 0)
                $display("TB: fed vector %0d / %0d (clk=%0d, frames_done=%0d)",
                         v, NUM_VECTORS, global_clk, capture_frame);
        end

        feed_end_clk = global_clk;
        // Stop new ingest; pipeline drains remaining outputs.
        start = 0;
        x_sub_vec_in = 0;

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

        $display("");
        $display("=== CONTINUOUS V2 TIMING (NUM_VECTORS=%0d) ===", NUM_VECTORS);
        $display("  Feed: start=1 for %0d beats/vector, no reset between frames", BEATS_PER_VEC);
        $display("");
        $display("  Vector 0 (cold / pipeline warmup):");
        $display("    feed_start=%0d  feed_end=%0d  (feed duration=%0d clk)",
                 vec_feed_start[0], vec_feed_end[0],
                 vec_feed_end[0] - vec_feed_start[0] + 1);
        if (vec_first_cap[0] >= 0)
            $display("    feed_start->first_cap=%0d clk",
                     vec_first_cap[0] - vec_feed_start[0]);
        if (vec_frame_done[0] >= 0)
            $display("    feed_start->frame_done=%0d clk  (full 256 outputs)",
                     vec_frame_done[0] - vec_feed_start[0]);
        if (vec_done_z_clk[0] >= 0)
            $display("    feed_start->done_z=%0d clk",
                     vec_done_z_clk[0] - vec_feed_start[0]);
        if (NUM_VECTORS > 1) begin
            $display("");
            $display("  Vector 1 (steady stream):");
            $display("    feed_start=%0d  feed_end=%0d  (feed duration=%0d clk)",
                     vec_feed_start[1], vec_feed_end[1],
                     vec_feed_end[1] - vec_feed_start[1] + 1);
            if (vec_first_cap[1] >= 0)
                $display("    feed_start->first_cap=%0d clk",
                         vec_first_cap[1] - vec_feed_start[1]);
            if (vec_frame_done[1] >= 0)
                $display("    feed_start->frame_done=%0d clk",
                         vec_frame_done[1] - vec_feed_start[1]);
            if (vec_frame_done[0] >= 0 && vec_frame_done[1] >= 0)
                $display("    frame0_done->frame1_done=%0d clk (throughput period)",
                         vec_frame_done[1] - vec_frame_done[0]);
            if (vec_feed_start[1] >= 0 && vec_feed_start[0] >= 0)
                $display("    feed_start spacing v0->v1=%0d clk",
                         vec_feed_start[1] - vec_feed_start[0]);
        end
        if (NUM_VECTORS > 2) begin
            $display("");
            $display("  Vector %0d (steady check):", NUM_VECTORS - 1);
            v = NUM_VECTORS - 1;
            if (vec_frame_done[v] >= 0 && vec_feed_start[v] >= 0)
                $display("    feed_start->frame_done=%0d clk",
                         vec_frame_done[v] - vec_feed_start[v]);
            if (vec_frame_done[v] >= 0 && vec_frame_done[v-1] >= 0)
                $display("    frame spacing v%0d->v%0d=%0d clk",
                         v-1, v, vec_frame_done[v] - vec_frame_done[v-1]);
        end
        $display("");
        $display("  Global: all_feed_end=%0d  first_cap_ever=%0d  last_cap_ever=%0d",
                 feed_end_clk, first_cap_clk, last_cap_clk);
        $display("  captures=%0d  frames=%0d  done_z=%0d",
                 total_captures, capture_frame, done_z_count);
        $display("==============================================");
        $display("");

        if (capture_frame == NUM_VECTORS)
            $display("SUCCESS: captured %0d continuous frames", NUM_VECTORS);
        else
            $display("FAIL: incomplete capture %0d / %0d", capture_frame, NUM_VECTORS);
        $finish;
    end

endmodule
