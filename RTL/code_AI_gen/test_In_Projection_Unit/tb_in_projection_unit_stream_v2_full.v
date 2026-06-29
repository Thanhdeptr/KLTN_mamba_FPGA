`timescale 1ns/1ps
// Full-sequence v2 test: NUM_VECTORS timesteps x 256 outputs.
// Vivado: add inproj_tb_paths.vh to project; paths default to repo absolute paths.
`include "inproj_tb_paths.vh"

module tb_in_projection_unit_stream_v2_full();
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam TAPS       = 8;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 1000;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam TOTAL_IN  = NUM_VECTORS * 64;
    localparam TOTAL_OUT = NUM_VECTORS * 256;
    localparam TIMEOUT_PER_VEC = 2000;

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
    reg [15:0] out_vec_buf [0:255];

    integer fp;
    integer li, idx, ri, lane, v, k;
    integer tb_tick;
    integer out_count;
    integer timeout_cycles;
    integer feed_cycles;
    integer capture_cycles;
    integer global_clk;
    integer vec_start_clk;
    integer vec_feed_end_clk;
    integer vec_first_cap_clk;
    integer vec_last_cap_clk;
    integer vec_done_clk;
    reg [TAPS*DATA_WIDTH-1:0] build;
    reg [8*512-1:0] fname;
    integer fh;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;
    integer ret;
    reg vec_seen [0:15];
    integer vec_fail;
    reg capture_en;

    always @(posedge clk) begin
        if (!rst_n)
            global_clk <= 0;
        else if (en)
            global_clk <= global_clk + 1;
    end

    always @(posedge clk) begin
        if (capture_en && out_count < 16) begin
            if (dut.vld_pipe[6] && dut.tick_cnt_pipe[6] == (TAPS - 1)) begin
                if (vec_first_cap_clk < 0)
                    vec_first_cap_clk = global_clk;
                vec_last_cap_clk = global_clk;
                for (lane = 0; lane < LANES; lane = lane + 1)
                    out_vec_buf[dut.grp_idx_pipe[6]*LANES + lane] =
                        dut.y_out[lane*DATA_WIDTH +: DATA_WIDTH];
                vec_seen[dut.grp_idx_pipe[6]] = 1'b1;
                out_count = out_count + 1;
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

    task automatic pulse_reset;
        begin
            rst_n = 0;
            en = 0;
            start = 0;
            x_sub_vec_in = 0;
            capture_en = 0;
            @(posedge clk);
            @(posedge clk);
            rst_n = 1;
            @(posedge clk);
            @(posedge clk);
            en = 1;
        end
    endtask

    task automatic feed_one_vector;
        begin
            tb_tick = 0;
            build = { xvec[7], xvec[6], xvec[5], xvec[4],
                      xvec[3], xvec[2], xvec[1], xvec[0] };
            x_sub_vec_in = build;
            start = 1;
            feed_cycles = 0;
            @(posedge clk);
            feed_cycles = feed_cycles + 1;
            for (k = 0; k < (16 * TAPS); k = k + 1) begin
                build = { xvec[tb_tick*8 + 7], xvec[tb_tick*8 + 6],
                          xvec[tb_tick*8 + 5], xvec[tb_tick*8 + 4],
                          xvec[tb_tick*8 + 3], xvec[tb_tick*8 + 2],
                          xvec[tb_tick*8 + 1], xvec[tb_tick*8 + 0] };
                x_sub_vec_in = build;
                @(posedge clk);
                feed_cycles = feed_cycles + 1;
                if (tb_tick == TAPS - 1) tb_tick = 0;
                else tb_tick = tb_tick + 1;
            end
            start = 0;
            x_sub_vec_in = 0;
            @(posedge clk);
            feed_cycles = feed_cycles + 1;
            vec_feed_end_clk = global_clk;
        end
    endtask

    task automatic capture_one_vector;
        begin
            out_count = 0;
            capture_cycles = 0;
            vec_first_cap_clk = -1;
            vec_last_cap_clk = -1;
            for (idx = 0; idx < 16; idx = idx + 1)
                vec_seen[idx] = 1'b0;
            for (ri = 0; ri < 256; ri = ri + 1)
                out_vec_buf[ri] = 16'h0000;

            capture_en = 1;
            timeout_cycles = TIMEOUT_PER_VEC;
            while (out_count < 16 && timeout_cycles > 0) begin
                @(posedge clk);
                capture_cycles = capture_cycles + 1;
                timeout_cycles = timeout_cycles - 1;
            end
            capture_en = 0;
            vec_done_clk = global_clk;
        end
    endtask

    initial begin
        $sformat(fname, "%s/rtl_output_v2_full.mem", `INPROJ_TEST_ROOT);
        fp = $fopen(fname, "w");
        if (fp == 0)
            $fatal(1, "TB: cannot open output file %s", fname);

        vec_fail = 0;
        global_clk = 0;

        $sformat(fname, "%s/input_full.mem", `INPROJ_VECTORS_DIR);
        $display("TB loading %s (%0d samples)", fname, TOTAL_IN);
        $readmemh(fname, in_mem);
        load_weights();
        pulse_reset();

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            if (v > 0)
                pulse_reset();

            for (ri = 0; ri < 64; ri = ri + 1)
                xvec[ri] = $signed(in_mem[v*64 + ri]);

            @(posedge clk);
            vec_start_clk = global_clk;
            feed_one_vector();
            capture_one_vector();

            if (out_count != 16) begin
                $display("ERROR: vector %0d capture timeout (got %0d/16)", v, out_count);
                vec_fail = vec_fail + 1;
            end else begin
                for (idx = 0; idx < 16; idx = idx + 1) begin
                    if (!vec_seen[idx]) begin
                        $display("ERROR: vector %0d missing output group %0d", v, idx);
                        vec_fail = vec_fail + 1;
                    end
                end
            end

            for (idx = 0; idx < 256; idx = idx + 1)
                $fwrite(fp, "%04x\n", out_vec_buf[idx]);
            $fflush(fp);

            if (v == 0 || v == 1 || (v % 100) == 0 || v == NUM_VECTORS - 1) begin
                $display("LATENCY v=%0d: start=%0d feed_end=%0d first_cap=%0d last_cap=%0d done=%0d",
                         v, vec_start_clk, vec_feed_end_clk,
                         vec_first_cap_clk, vec_last_cap_clk, vec_done_clk);
                if (vec_first_cap_clk >= 0)
                    $display("  start->first_cap=%0d clk  start->done=%0d clk  feed=%0d capture=%0d",
                             vec_first_cap_clk - vec_start_clk,
                             vec_done_clk - vec_start_clk,
                             vec_feed_end_clk - vec_start_clk,
                             vec_done_clk - vec_feed_end_clk);
            end
            if ((v % 100) == 0)
                $display("TB: vector %0d / %0d done", v, NUM_VECTORS);
        end

        $display("");
        $display("=== V2 TIMING SUMMARY (NUM_VECTORS=%0d) ===", NUM_VECTORS);
        $display("Per-vector: reset between frames, feed 128 beats, capture 16 groups");
        $display("Output file: rtl_output_v2_full.mem (%0d values)", TOTAL_OUT);
        $display("============================================");
        $display("");

        $fclose(fp);
        if (vec_fail == 0)
            $display("SUCCESS: Captured %0d vectors to rtl_output_v2_full.mem", NUM_VECTORS);
        else
            $display("FAIL: %0d vector capture errors", vec_fail);
        $finish;
    end

endmodule
