`timescale 1ns/1ps
// 1000-timestep In_Projection_Unit_Streaming_v3 test.
// Vivado: add inproj_tb_paths.vh from test_In_Projection_Unit to the project.
`include "/home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_In_Projection_Unit/inproj_tb_paths.vh"

module tb_in_projection_v3_full();
    localparam DATA_WIDTH = 16;
    localparam OUT_LANES  = 16;
    localparam TAPS       = 8;
`ifndef NUM_VECTORS
    localparam NUM_VECTORS = 1000;
`else
    localparam NUM_VECTORS = `NUM_VECTORS;
`endif
    localparam TOTAL_IN    = NUM_VECTORS * 64;
    localparam TOTAL_OUT   = NUM_VECTORS * 256;
    localparam TIMEOUT_PER_VEC = 20000;
    localparam INTER_TAG_HOLD_CYCLES = 56;

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;

    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in;
    wire signed [OUT_LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z, busy, frame_ready;
    wire [1:0] pass_idx_out;
    wire out_valid;
    wire [3:0] out_grp;

    In_Projection_Unit_Streaming_v3 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .start(start),
        .x_sub_vec_in(x_sub_vec_in), .y_out(y_out),
        .done_x(done_x), .done_z(done_z), .busy(busy),
        .frame_ready(frame_ready),
        .pass_idx_out(pass_idx_out), .out_valid(out_valid),
        .out_grp(out_grp),
        .dbg_op_state(), .dbg_pass_idx(), .dbg_vld_in(),
        .dbg_replay_cnt(), .dbg_ingest_cnt(), .dbg_replay_addr(),
        .dbg_replay_ext(), .dbg_replay_hold(), .dbg_pass_replay_guard(),
        .dbg_replay_reset_d(), .dbg_tick_cnt(), .dbg_group_idx(),
        .dbg_pipe_grp_s0(), .dbg_fetch_grp_s0(), .dbg_pipe_grp_s6(),
        .dbg_logical_grp_s6(), .dbg_vld_pipe0(), .dbg_vld_pipe1(),
        .dbg_vld_pipe3(), .dbg_vld_pipe6(), .dbg_tick_pipe0(),
        .dbg_tick_pipe3(), .dbg_tick_pipe6(), .dbg_grp_pipe6(),
        .dbg_pass_g0_seen(), .dbg_merge_skip(), .dbg_st0_p0_l0(),
        .dbg_st1_p0_l0(), .dbg_st0_p1_l0(), .dbg_st1_p1_l0(),
        .dbg_acc_l0(), .dbg_sat_l0(), .dbg_x_pipe0_zero(),
        .dbg_replay_tap0(), .dbg_xvec_tap0(), .dbg_pipe01_delta_l0()
    );

    reg out_valid_d;
    reg [3:0] out_grp_d;
    reg [1:0] pass_idx_d;

    reg [15:0] in_mem [0:TOTAL_IN-1];
    reg signed [DATA_WIDTH-1:0] xvec [0:63];
    reg [15:0] out_vec_buf [0:255];

    integer fp;
    integer li, idx, ri, lane, grp, v, k;
    integer tb_tick;
    integer out_count;
    integer timeout_cycles;
    integer global_clk;
    integer vec_start_clk;
    integer vec_busy_end_clk;
    reg [TAPS*DATA_WIDTH-1:0] build;
    reg [8*512:1] fname;
    integer fh;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;
    integer ret;
    reg vec_seen [0:15];
    integer vec_fail;
    reg vec_track_en;
    reg last_busy;

    always @(posedge clk) begin
        out_valid_d <= out_valid;
        out_grp_d <= out_grp;
        pass_idx_d <= pass_idx_out;
    end

    always @(posedge clk) begin
        if (!rst_n)
            global_clk <= 0;
        else if (en)
            global_clk <= global_clk + 1;
    end

    always @(posedge clk) begin
        last_busy <= busy;
        if (rst_n && en && vec_track_en && last_busy && !busy)
            vec_busy_end_clk = global_clk;
    end

    always #5 clk = ~clk;

    task automatic feed_one_vector;
        input integer extra_cycles;
        integer fc;
        begin
            tb_tick = 0;
            build = { xvec[7], xvec[6], xvec[5], xvec[4],
                      xvec[3], xvec[2], xvec[1], xvec[0] };
            x_sub_vec_in = build;
            start = 1;
            @(posedge clk);
            for (k = 0; k < (16*TAPS + extra_cycles); k = k + 1) begin
                build = { xvec[tb_tick*8 + 7], xvec[tb_tick*8 + 6],
                          xvec[tb_tick*8 + 5], xvec[tb_tick*8 + 4],
                          xvec[tb_tick*8 + 3], xvec[tb_tick*8 + 2],
                          xvec[tb_tick*8 + 1], xvec[tb_tick*8 + 0] };
                x_sub_vec_in = build;
                @(posedge clk);
                if (tb_tick == TAPS-1) tb_tick = 0; else tb_tick = tb_tick + 1;
            end
            start = 0;
            @(posedge clk);
        end
    endtask

    task automatic capture_one_vector;
        begin
            out_count = 0;
            for (grp = 0; grp < 16; grp = grp + 1)
                vec_seen[grp] = 1'b0;
            for (ri = 0; ri < 256; ri = ri + 1)
                out_vec_buf[ri] = 16'h0000;

            timeout_cycles = TIMEOUT_PER_VEC;
            while (out_count < 16 && timeout_cycles > 0) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles - 1;
                if (out_valid_d && pass_idx_d == 2'd3) begin
                    grp = out_grp_d;
                    for (lane = 0; lane < OUT_LANES; lane = lane + 1)
                        out_vec_buf[grp*OUT_LANES + lane] =
                            dut.y_out[lane*DATA_WIDTH +: DATA_WIDTH];
                    vec_seen[grp] = 1'b1;
                    out_count = out_count + 1;
                end
            end
        end
    endtask

    initial begin
        $sformat(fname, "%s/rtl_output_full.mem", `INPROJ_VECTORS_DIR);
        fp = $fopen(fname, "w");
        if (fp == 0)
            $fatal(1, "TB: cannot open output file %s", fname);

        rst_n = 0;
        en = 0;
        start = 0;
        x_sub_vec_in = 0;
        vec_fail = 0;
        global_clk = 0;
        vec_track_en = 0;
        last_busy = 0;

        $sformat(fname, "%s/input_full.mem", `INPROJ_VECTORS_DIR);
        $display("TB loading %s (%0d samples)", fname, TOTAL_IN);
        $readmemh(fname, in_mem);

        for (li = 0; li < OUT_LANES; li = li + 1) begin
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

        rst_n = 1;
        #20;
        en = 1;

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            for (ri = 0; ri < 64; ri = ri + 1)
                xvec[ri] = $signed(in_mem[v*64 + ri]);

            if (v > 0) begin
                while (!frame_ready)
                    @(posedge clk);
            end

            vec_track_en = 1;
            vec_busy_end_clk = -1;
            vec_start_clk = global_clk + 1;
            feed_one_vector(v > 0 ? INTER_TAG_HOLD_CYCLES : 0);
            capture_one_vector();

            if (out_count != 16) begin
                $display("ERROR: vector %0d capture timeout (got %0d/16)", v, out_count);
                vec_fail = vec_fail + 1;
            end else begin
                for (grp = 0; grp < 16; grp = grp + 1) begin
                    if (!vec_seen[grp]) begin
                        $display("ERROR: vector %0d missing group %0d", v, grp);
                        vec_fail = vec_fail + 1;
                    end
                end
            end

            for (grp = 0; grp < 16; grp = grp + 1)
                for (lane = 0; lane < OUT_LANES; lane = lane + 1)
                    $fwrite(fp, "%04x\n", out_vec_buf[grp*OUT_LANES + lane]);
            $fflush(fp);

            while (busy)
                @(posedge clk);

            vec_track_en = 0;

            if (v == 0 || v == 1 || (v % 100) == 0 || v == NUM_VECTORS - 1)
                $display("TIMING v=%0d: start->busy_end = %0d clk",
                         v, vec_busy_end_clk - vec_start_clk);

            if ((v % 100) == 0)
                $display("TB: %0d / %0d vectors done", v, NUM_VECTORS);
        end

        $fclose(fp);
        if (vec_fail == 0)
            $display("SUCCESS: %0d vectors (%0d values) -> rtl_output_full.mem",
                     NUM_VECTORS, TOTAL_OUT);
        else
            $display("FAIL: %0d capture errors", vec_fail);
        $finish;
    end

endmodule
