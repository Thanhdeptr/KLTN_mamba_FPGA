`timescale 1ns/1ps
module tb_in_projection_unit_stream_v3();
    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;

    localparam DATA_WIDTH = 16;
    localparam OUT_LANES = 16;
    localparam TAPS = 8;

    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in;
    wire signed [OUT_LANES*DATA_WIDTH-1:0] y_out;
    wire done_x;
    wire done_z;
    wire busy;
    wire frame_ready;
    wire [1:0] pass_idx_out;
    wire out_valid;
    wire [3:0] out_grp;

    wire [2:0]  dbg_op_state;
    wire [1:0]  dbg_pass_idx;
    wire        dbg_vld_in;
    wire [7:0]  dbg_replay_cnt;
    wire [7:0]  dbg_ingest_cnt;
    wire [7:0]  dbg_replay_addr;
    wire        dbg_replay_ext;
    wire        dbg_replay_hold;
    wire [1:0]  dbg_pass_replay_guard;
    wire        dbg_replay_reset_d;
    wire [2:0]  dbg_tick_cnt;
    wire [3:0]  dbg_group_idx;
    wire [3:0]  dbg_pipe_grp_s0;
    wire [3:0]  dbg_fetch_grp_s0;
    wire [3:0]  dbg_pipe_grp_s6;
    wire [3:0]  dbg_logical_grp_s6;
    wire        dbg_vld_pipe0;
    wire        dbg_vld_pipe1;
    wire        dbg_vld_pipe3;
    wire        dbg_vld_pipe6;
    wire [2:0]  dbg_tick_pipe0;
    wire [2:0]  dbg_tick_pipe3;
    wire [2:0]  dbg_tick_pipe6;
    wire [3:0]  dbg_grp_pipe6;
    wire        dbg_pass_g0_seen;
    wire        dbg_merge_skip;
    wire signed [DATA_WIDTH-1:0] dbg_st0_p0_l0;
    wire signed [DATA_WIDTH-1:0] dbg_st1_p0_l0;
    wire signed [DATA_WIDTH-1:0] dbg_st0_p1_l0;
    wire signed [DATA_WIDTH-1:0] dbg_st1_p1_l0;
    wire signed [39:0] dbg_acc_l0;
    wire signed [DATA_WIDTH-1:0] dbg_sat_l0;
    wire        dbg_x_pipe0_zero;
    wire signed [DATA_WIDTH-1:0] dbg_replay_tap0;
    wire signed [DATA_WIDTH-1:0] dbg_xvec_tap0;
    wire signed [DATA_WIDTH-1:0] dbg_pipe01_delta_l0;

    reg [15:0] golden_mem [0:255];

    In_Projection_Unit_Streaming_v3 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .start(start),
        .x_sub_vec_in(x_sub_vec_in), .y_out(y_out),
        .done_x(done_x), .done_z(done_z), .busy(busy),
        .frame_ready(frame_ready),
        .pass_idx_out(pass_idx_out), .out_valid(out_valid),
        .out_grp(out_grp),
        .dbg_op_state(dbg_op_state),
        .dbg_pass_idx(dbg_pass_idx),
        .dbg_vld_in(dbg_vld_in),
        .dbg_replay_cnt(dbg_replay_cnt),
        .dbg_ingest_cnt(dbg_ingest_cnt),
        .dbg_replay_addr(dbg_replay_addr),
        .dbg_replay_ext(dbg_replay_ext),
        .dbg_replay_hold(dbg_replay_hold),
        .dbg_pass_replay_guard(dbg_pass_replay_guard),
        .dbg_replay_reset_d(dbg_replay_reset_d),
        .dbg_tick_cnt(dbg_tick_cnt),
        .dbg_group_idx(dbg_group_idx),
        .dbg_pipe_grp_s0(dbg_pipe_grp_s0),
        .dbg_fetch_grp_s0(dbg_fetch_grp_s0),
        .dbg_pipe_grp_s6(dbg_pipe_grp_s6),
        .dbg_logical_grp_s6(dbg_logical_grp_s6),
        .dbg_vld_pipe0(dbg_vld_pipe0),
        .dbg_vld_pipe1(dbg_vld_pipe1),
        .dbg_vld_pipe3(dbg_vld_pipe3),
        .dbg_vld_pipe6(dbg_vld_pipe6),
        .dbg_tick_pipe0(dbg_tick_pipe0),
        .dbg_tick_pipe3(dbg_tick_pipe3),
        .dbg_tick_pipe6(dbg_tick_pipe6),
        .dbg_grp_pipe6(dbg_grp_pipe6),
        .dbg_pass_g0_seen(dbg_pass_g0_seen),
        .dbg_merge_skip(dbg_merge_skip),
        .dbg_st0_p0_l0(dbg_st0_p0_l0),
        .dbg_st1_p0_l0(dbg_st1_p0_l0),
        .dbg_st0_p1_l0(dbg_st0_p1_l0),
        .dbg_st1_p1_l0(dbg_st1_p1_l0),
        .dbg_acc_l0(dbg_acc_l0),
        .dbg_sat_l0(dbg_sat_l0),
        .dbg_x_pipe0_zero(dbg_x_pipe0_zero),
        .dbg_replay_tap0(dbg_replay_tap0),
        .dbg_xvec_tap0(dbg_xvec_tap0),
        .dbg_pipe01_delta_l0(dbg_pipe01_delta_l0)
    );

    reg out_valid_d;
    reg [3:0] out_grp_d;
    reg [1:0] pass_idx_d;

    always @(posedge clk) begin
        out_valid_d <= out_valid;
        out_grp_d <= out_grp;
        pass_idx_d <= pass_idx_out;
    end

    always #5 clk = ~clk;

    integer fp;
    integer li;
    reg [8*256-1:0] fname;
    reg signed [DATA_WIDTH-1:0] xvec [0:63];
    integer tb_tick;
    reg [15:0] tmpmem [0:63];
    integer ri;
    integer idx;
    reg [TAPS*DATA_WIDTH-1:0] build;
    integer fh;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val;
    integer ret;
    integer rel_cycle;
    integer out_count;
    integer lane;
    integer grp;
    integer timeout_cycles;
    reg [15:0] out_vec_buf [0:255];
    reg vec_seen [0:15];

    // Cycle timing markers (t=0 at first ingest feed posedge)
    integer cyc;
    integer cyc_ingest_end;
    integer cyc_replay_start [0:3];
    integer cyc_pass_drain_end [0:3];
    integer cyc_first_emit;
    integer cyc_done_x;
    integer cyc_done_z;
    integer cyc_busy_end;
    integer emit_cyc [0:15];
    integer emit_mon_count;
    integer prev_emit_cyc;
    reg [2:0] last_op_state;
    reg [1:0] last_pass_idx;
    reg last_busy;
    reg cyc_run;

    integer dbg_fp;
    integer dbg_startup_zero;
    integer dbg_capture_lag;
    reg dbg_g0_emit_logged;

    // TB debug log (Section 6.2 STREAMING_DESIGN_GUIDE) -> debug_v3.log
    always @(posedge clk) begin
        if (rst_n && en && cyc_run) begin
            if (cyc >= 0 && cyc <= 20) begin
                $fwrite(dbg_fp,
                    "STARTUP cyc=%0d st=%0d pass=%0d start=%b vld_in=%b ingest=%0d replay=%0d addr=%0d guard=%0d x_zero=%b xvec_t0=%0d replay_t0=%0d in_t0=%0d\n",
                    cyc, dbg_op_state, dbg_pass_idx, start, dbg_vld_in,
                    dbg_ingest_cnt, dbg_replay_cnt, dbg_replay_addr, dbg_pass_replay_guard,
                    dbg_x_pipe0_zero, $signed(dbg_xvec_tap0), $signed(dbg_replay_tap0),
                    $signed(x_sub_vec_in[0 +: DATA_WIDTH]));
                if (dbg_x_pipe0_zero && (start || dbg_vld_in))
                    dbg_startup_zero = dbg_startup_zero + 1;
            end

            if (dbg_vld_pipe1 && !dbg_replay_reset_d && cyc <= 20) begin
                $fwrite(dbg_fp,
                    "PIPE_DELTA cyc=%0d pass=%0d pipe_grp=%0d tick=%0d st0_p0=%0d st0_p1=%0d delta=%0d\n",
                    cyc, dbg_pass_idx, dbg_pipe_grp_s0, dut.tick_cnt_pipe[1],
                    $signed(dbg_st0_p0_l0), $signed(dbg_st0_p1_l0), $signed(dbg_pipe01_delta_l0));
            end

            if (dbg_vld_pipe0 && !dbg_replay_reset_d && dbg_fetch_grp_s0 == 4'd0) begin
                $fwrite(dbg_fp,
                    "FETCH_G0 cyc=%0d pass=%0d pipe=%0d tick=%0d st0=%0d xvec=%0d replay=%0d\n",
                    cyc, dbg_pass_idx, dbg_pipe_grp_s0, dbg_tick_pipe0,
                    $signed(dbg_st0_p0_l0), $signed(dbg_xvec_tap0), $signed(dbg_replay_tap0));
            end

            if (dbg_vld_pipe6 && dbg_tick_pipe6 == (TAPS - 1) && !dbg_replay_reset_d) begin
                if (dbg_merge_skip)
                    $fwrite(dbg_fp,
                        "MERGE_SKIP cyc=%0d pass=%0d pipe=%0d log=%0d g0_seen=%b\n",
                        cyc, dbg_pass_idx, dbg_pipe_grp_s6, dbg_logical_grp_s6, dbg_pass_g0_seen);
                else if (dbg_logical_grp_s6 == 4'd0 && dbg_pass_idx == 2'd3 && !dbg_g0_emit_logged) begin
                    dbg_g0_emit_logged = 1'b1;
                    $fwrite(dbg_fp,
                        "EMIT_G0 cyc=%0d sat0=%0d acc=%0d rtl_y0=%0d gold_y0=%0d err=%0d\n",
                        cyc, $signed(dbg_sat_l0), $signed(dbg_acc_l0),
                        $signed(y_out[0 +: DATA_WIDTH]), $signed(golden_mem[0]),
                        $signed(y_out[0 +: DATA_WIDTH]) - $signed(golden_mem[0]));
                end
            end

            if (dbg_op_state == 3'd2 && dbg_pass_idx == 0 && dbg_vld_in &&
                (dbg_replay_cnt != dbg_ingest_cnt) &&
                ((dbg_replay_cnt + 8'd1) != dbg_ingest_cnt)) begin
                dbg_capture_lag = dbg_capture_lag + 1;
                if (dbg_capture_lag <= 4)
                    $fwrite(dbg_fp,
                        "CAPTURE_LAG cyc=%0d ingest=%0d replay=%0d addr=%0d\n",
                        cyc, dbg_ingest_cnt, dbg_replay_cnt, dbg_replay_addr);
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && en && cyc_run) begin
            cyc = cyc + 1;

            if (done_x && (cyc_done_x < 0))
                cyc_done_x = cyc;
            if (done_z && (cyc_done_z < 0))
                cyc_done_z = cyc;

            if (out_valid_d && (pass_idx_d == 2'd3)) begin
                if (cyc_first_emit < 0)
                    cyc_first_emit = cyc;
                if (emit_mon_count < 16) begin
                    emit_cyc[emit_mon_count] = cyc;
                    emit_mon_count = emit_mon_count + 1;
                end
            end

            if (last_op_state != dut.op_state) begin
                if (dut.op_state == 3'd2 && last_op_state == 3'd0)
                    cyc_replay_start[0] = cyc;
                if (dut.op_state == 3'd2 && last_op_state == 3'd3)
                    cyc_replay_start[dut.pass_idx] = cyc;
                if (last_op_state == 3'd3 && (dut.op_state == 3'd2 || dut.op_state == 3'd0))
                    cyc_pass_drain_end[last_pass_idx] = cyc;
            end

            if (last_busy && !dut.busy && (cyc_busy_end < 0))
                cyc_busy_end = cyc;

            last_op_state = dut.op_state;
            last_pass_idx = dut.pass_idx;
            last_busy = dut.busy;
        end
    end

    initial begin
        $dumpfile("tb_stream_v3.vcd");
        $dumpvars(0, tb_in_projection_unit_stream_v3);

        fp = $fopen("rtl_output_v3.mem", "w");
        dbg_fp = $fopen("debug_v3.log", "w");
        dbg_startup_zero = 0;
        dbg_capture_lag = 0;
        dbg_g0_emit_logged = 0;
        $fwrite(dbg_fp, "# In_Projection v3 debug log (STREAMING_DESIGN_GUIDE Section 6)\n");
        $readmemh("golden_output.mem", golden_mem);
        rst_n = 0; en = 0; start = 0; x_sub_vec_in = 0;
        #20;

        for (li = 0; li < OUT_LANES; li = li + 1) begin
            $sformat(fname, "%s/banks/weight_lane_%0d.mem",
                     "/home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_In_Projection_Unit", li);
            $display("TB loading %s into DUT", fname);
            fh = $fopen(fname, "r");
            if (fh == 0) begin
                $display("ERROR: cannot open %s", fname);
            end else begin
                for (idx = 0; idx < 128; idx = idx + 1) begin
                    line = "";
                    if ($fgets(line, fh) == 0) begin
                        val = 0;
                    end else begin
                        ret = $sscanf(line, "%h", val);
                        if (ret != 1) val = 0;
                    end
                    dut.bram_mem[li][idx] = val;
                end
                $fclose(fh);
            end
        end

        rst_n = 1;
        #20;
        en = 1;

        $display("TB loading input.mem");
        $readmemh("input.mem", tmpmem);
        for (ri = 0; ri < 64; ri = ri + 1)
            xvec[ri] = $signed(tmpmem[ri]);

        tb_tick = 0;
        out_count = 0;
        rel_cycle = 0;
        cyc = -1;
        cyc_ingest_end = -1;
        cyc_first_emit = -1;
        cyc_done_x = -1;
        cyc_done_z = -1;
        cyc_busy_end = -1;
        emit_mon_count = 0;
        prev_emit_cyc = -1;
        last_op_state = 0;
        last_pass_idx = 0;
        last_busy = 0;
        cyc_run = 0;
        for (grp = 0; grp < 16; grp = grp + 1) begin
            vec_seen[grp] = 0;
            cyc_replay_start[grp] = -1;
            cyc_pass_drain_end[grp] = -1;
            emit_cyc[grp] = -1;
        end
        for (ri = 0; ri < 256; ri = ri + 1)
            out_vec_buf[ri] = 16'h0000;

        // Full run: feed 16 groups x 8 ticks = 128 valid clusters (same as v2 TB).
        // One warm-up posedge because DUT asserts vld_in one cycle after start.
        build = { xvec[7], xvec[6], xvec[5], xvec[4], xvec[3], xvec[2], xvec[1], xvec[0] };
        x_sub_vec_in = build;
        start = 1;
        cyc_run = 1;
        tb_tick = 0;
        $display("\n========== CYCLE TIMING (t=0 = first feed posedge, pass0 live) ==========");
        @(posedge clk);
        rel_cycle = rel_cycle + 1;
        for (idx = 0; idx < (16*TAPS); idx = idx + 1) begin
            build = { xvec[tb_tick*8 + 7], xvec[tb_tick*8 + 6], xvec[tb_tick*8 + 5], xvec[tb_tick*8 + 4],
                      xvec[tb_tick*8 + 3], xvec[tb_tick*8 + 2], xvec[tb_tick*8 + 1], xvec[tb_tick*8 + 0] };
            x_sub_vec_in = build;
            @(posedge clk);
            rel_cycle = rel_cycle + 1;
            if (tb_tick == TAPS-1) tb_tick = 0; else tb_tick = tb_tick + 1;
        end

        start = 0;
        x_sub_vec_in = 0;
        @(posedge clk);
        rel_cycle = rel_cycle + 1;
        cyc_ingest_end = cyc;

        timeout_cycles = 12000;
        while (out_count < 16 && timeout_cycles > 0) begin
            @(posedge clk);
            rel_cycle = rel_cycle + 1;
            timeout_cycles = timeout_cycles - 1;

            if (out_valid_d && pass_idx_d == 2'd3) begin
                grp = out_grp_d;
                for (lane = 0; lane < OUT_LANES; lane = lane + 1) begin
                    out_vec_buf[grp*OUT_LANES + lane] =
                        dut.y_out[lane*DATA_WIDTH +: DATA_WIDTH];
                end
                vec_seen[grp] = 1'b1;
                if (prev_emit_cyc >= 0)
                    $display("EMIT seq=%0d grp=%0d cyc=%0d delta=%0d y0=%0d",
                             out_count, grp, cyc,
                             cyc - prev_emit_cyc,
                             $signed(dut.y_out[0 +: DATA_WIDTH]));
                else
                    $display("EMIT seq=%0d grp=%0d cyc=%0d delta=NA y0=%0d",
                             out_count, grp, cyc,
                             $signed(dut.y_out[0 +: DATA_WIDTH]));
                prev_emit_cyc = cyc;
                out_count = out_count + 1;
            end
        end

        for (grp = 0; grp < 16; grp = grp + 1) begin
            for (lane = 0; lane < OUT_LANES; lane = lane + 1) begin
                $fwrite(fp, "%04x\n", out_vec_buf[grp*OUT_LANES + lane]);
            end
        end

        $display("\n========== SUMMARY ==========");
        if (out_count != 16) begin
            $display("ERROR: capture timeout, expected 16 vectors but got %0d (busy=%b)", out_count, busy);
        end else begin
            $display("SUCCESS: Captured %0d vectors (%0d values) to rtl_output_v3.mem",
                     out_count, out_count*OUT_LANES);
        end
        for (grp = 0; grp < 16; grp = grp + 1) begin
            if (!vec_seen[grp])
                $display("WARN: missing output vector for group %0d", grp);
        end
        $display("Total rel_cycle (TB): %0d", rel_cycle);
        $display("--- Timing from first ingest feed (cyc) ---");
        $display("  feed_end (start=0):       cyc=%0d", cyc_ingest_end);
        $display("  pass0 live start:        cyc=%0d", cyc_replay_start[0]);
        $display("  replay_start pass1:       cyc=%0d", cyc_replay_start[1]);
        $display("  replay_start pass2:       cyc=%0d", cyc_replay_start[2]);
        $display("  replay_start pass3:       cyc=%0d", cyc_replay_start[3]);
        $display("  drain_end pass0:          cyc=%0d", cyc_pass_drain_end[0]);
        $display("  drain_end pass1:          cyc=%0d", cyc_pass_drain_end[1]);
        $display("  drain_end pass2:          cyc=%0d", cyc_pass_drain_end[2]);
        $display("  drain_end pass3:          cyc=%0d", cyc_pass_drain_end[3]);
        $display("  first out_valid (pass3):  cyc=%0d", cyc_first_emit);
        $display("  done_x (out_grp=7):       cyc=%0d", cyc_done_x);
        $display("  done_z (out_grp=15):      cyc=%0d", cyc_done_z);
        $display("  busy deassert:            cyc=%0d", cyc_busy_end);
        if (cyc_done_x >= 0)
            $display("  latency feed->done_x:     %0d clk", cyc_done_x);
        if (cyc_done_z >= 0)
            $display("  latency feed->done_z:     %0d clk", cyc_done_z);
        if (cyc_first_emit >= 0 && cyc_done_x >= 0)
            $display("  first_emit->done_x:       %0d clk", cyc_done_x - cyc_first_emit);
        if (cyc_done_x >= 0 && cyc_done_z >= 0)
            $display("  done_x->done_z:           %0d clk", cyc_done_z - cyc_done_x);
        if (emit_cyc[1] >= 0 && emit_cyc[0] >= 0)
            $display("  steady emit interval:     %0d clk (pass3, seq1-seq0)", emit_cyc[1] - emit_cyc[0]);
        if (cyc_replay_start[0] >= 0 && cyc_pass_drain_end[0] >= 0)
            $display("  pass0 duration:           %0d clk", cyc_pass_drain_end[0] - cyc_replay_start[0]);
        if (cyc_replay_start[1] >= 0 && cyc_pass_drain_end[1] >= 0)
            $display("  pass1 duration:           %0d clk", cyc_pass_drain_end[1] - cyc_replay_start[1]);
        if (cyc_replay_start[2] >= 0 && cyc_pass_drain_end[2] >= 0)
            $display("  pass2 duration:           %0d clk", cyc_pass_drain_end[2] - cyc_replay_start[2]);
        if (cyc_replay_start[3] >= 0 && cyc_pass_drain_end[3] >= 0)
            $display("  pass3 duration:           %0d clk", cyc_pass_drain_end[3] - cyc_replay_start[3]);
        else if (cyc_replay_start[3] >= 0 && cyc_done_z >= 0)
            $display("  pass3 start->done_z:      %0d clk", cyc_done_z - cyc_replay_start[3]);
        $display("  final cyc:                %0d", cyc);
        $display("--- Debug monitor (debug_v3.log) ---");
        $display("  startup x_pipe0_zero hits: %0d (cycles 0-20)", dbg_startup_zero);
        $display("  capture lag events:        %0d (pass0 ingest vs replay)", dbg_capture_lag);
        $display("==============================\n");

        $fwrite(dbg_fp, "SUMMARY startup_zero=%0d capture_lag=%0d mismatch_vec0=%0d\n",
            dbg_startup_zero, dbg_capture_lag,
            $signed(out_vec_buf[0]) - $signed(golden_mem[0]));
        $fclose(dbg_fp);
        $fclose(fp);
        $finish;
    end

endmodule
