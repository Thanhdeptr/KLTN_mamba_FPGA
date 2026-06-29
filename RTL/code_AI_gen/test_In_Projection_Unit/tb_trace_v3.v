`timescale 1ns/1ps
// Trace testbench for In_Projection_Unit_Streaming_v3 vector-0 debug.
// Logs pass-3 merge/emit events and merge_out snapshots to trace_v3.log
module tb_trace_v3();
    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;

    localparam DATA_WIDTH = 16;
    localparam OUT_LANES = 16;
    localparam TAPS = 8;

    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in;
    wire signed [OUT_LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z, busy;
    wire [1:0] pass_idx_out;
    wire out_valid;
    wire [3:0] out_grp;
    reg [15:0] golden_mem [0:255];

    integer trace_fp;
    integer cycle;
    integer lane;
    integer out_count;
    integer grp;
    integer pi;

    In_Projection_Unit_Streaming_v3 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .start(start),
        .x_sub_vec_in(x_sub_vec_in), .y_out(y_out),
        .done_x(done_x), .done_z(done_z), .busy(busy),
        .pass_idx_out(pass_idx_out), .out_valid(out_valid), .out_grp(out_grp),
        .dbg_op_state(),
        .dbg_pass_idx(),
        .dbg_vld_in(),
        .dbg_replay_cnt(),
        .dbg_ingest_cnt(),
        .dbg_replay_addr(),
        .dbg_replay_ext(),
        .dbg_replay_hold(),
        .dbg_pass_replay_guard(),
        .dbg_replay_reset_d(),
        .dbg_tick_cnt(),
        .dbg_group_idx(),
        .dbg_pipe_grp_s0(),
        .dbg_fetch_grp_s0(),
        .dbg_pipe_grp_s6(),
        .dbg_logical_grp_s6(),
        .dbg_vld_pipe0(),
        .dbg_vld_pipe1(),
        .dbg_vld_pipe3(),
        .dbg_vld_pipe6(),
        .dbg_tick_pipe0(),
        .dbg_tick_pipe3(),
        .dbg_tick_pipe6(),
        .dbg_grp_pipe6(),
        .dbg_pass_g0_seen(),
        .dbg_merge_skip(),
        .dbg_st0_p0_l0(),
        .dbg_st1_p0_l0(),
        .dbg_st0_p1_l0(),
        .dbg_st1_p1_l0(),
        .dbg_acc_l0(),
        .dbg_sat_l0(),
        .dbg_x_pipe0_zero(),
        .dbg_replay_tap0(),
        .dbg_xvec_tap0(),
        .dbg_pipe01_delta_l0()
    );

    function [3:0] pipe_to_logical;
        input [3:0] pipe_grp;
        begin
            pipe_to_logical = (pipe_grp == 4'd0) ? 4'd15 : (pipe_grp - 4'd1);
        end
    endfunction

    task dump_merge_row;
        input [3:0] row;
        input [255:0] tag;
        integer li;
        begin
            $fwrite(trace_fp, "  MERGE_SNAP %s row=%0d lanes:", tag, row);
            for (li = 0; li < OUT_LANES; li = li + 1)
                $fwrite(trace_fp, " %0d", $signed(dut.merge_out[row][li]));
            $fwrite(trace_fp, "\n");
        end
    endtask

    always #5 clk = ~clk;

    // Log stage5 boundary events (merge + would-be emit data)
    always @(posedge clk) begin
        if (rst_n && en && dut.vld_pipe[6] && dut.tick_cnt_pipe[6] == (TAPS - 1)) begin
            grp = dut.grp_idx_pipe[6];
            if (dut.pass_idx == 2'd3) begin
                $fwrite(trace_fp,
                    "P3_STAGE6 cyc=%0d pipe_grp=%0d log_grp=%0d ext=%b g0_seen=%b bank_base=%0d sat0=%0d\n",
                    cycle, grp, pipe_to_logical(grp), dut.replay_ext_active, dut.pass_g0_seen,
                    dut.pass_idx * 4, $signed(dut.stage4_sat_out[0]));
            end
            if (dut.pass_idx == 2'd3)
                $fwrite(trace_fp, "  P3_MERGE pipe_grp=%0d -> merge_out[%0d][%0d:%0d] sat=[%0d,%0d,%0d,%0d]\n",
                    grp, pipe_to_logical(grp), dut.pass_idx*4, dut.pass_idx*4+3,
                    $signed(dut.stage4_sat_out[0]), $signed(dut.stage4_sat_out[1]),
                    $signed(dut.stage4_sat_out[2]), $signed(dut.stage4_sat_out[3]));
        end
    end

    always @(posedge clk) begin
        if (rst_n && en && out_valid && dut.pass_idx == 2'd3) begin
            grp = dut.out_grp;
            $fwrite(trace_fp, "P3_EMIT cyc=%0d seq=%0d out_grp=%0d pipe_grp=%0d log_grp=%0d y0=%0d",
                cycle, out_count, grp, dut.grp_idx_pipe[6], pipe_to_logical(dut.grp_idx_pipe[6]), $signed(y_out[0 +: DATA_WIDTH]));
            $fwrite(trace_fp, " merge_used=[");
            for (lane = 0; lane < 12; lane = lane + 1)
                $fwrite(trace_fp, "%0d,", $signed(dut.merge_out[grp][lane]));
            $fwrite(trace_fp, "] sat=[");
            for (lane = 0; lane < 4; lane = lane + 1)
                $fwrite(trace_fp, "%0d,", $signed(dut.stage4_sat_out[lane]));
            $fwrite(trace_fp, "]\n");
            out_count = out_count + 1;
        end
    end

    // Terminal visibility for done_x/done_z aligned with out_valid on pass 3
    always @(posedge clk) begin
        if (rst_n && en && dut.pass_idx == 2'd3) begin
            if (done_x)
                $display("DONE_X cyc=%0d out_valid=%b out_grp=%0d done_z=%b",
                    cycle, out_valid, out_grp, done_z);
            if (done_z)
                $display("DONE_Z cyc=%0d out_valid=%b out_grp=%0d done_x=%b",
                    cycle, out_valid, out_grp, done_x);
        end
    end

    // Snapshot merge_out[0] and [1] at end of each pass FIXUP
    reg [2:0] last_state;
    reg fixup_done_pulse;
    always @(posedge clk) begin
        fixup_done_pulse <= 1'b0;
        if (rst_n && en) begin
            if (last_state == 3'd3 && dut.op_state == 3'd4)
                fixup_done_pulse <= 1'b1;
            last_state = dut.op_state;
        end
    end
    always @(posedge clk) begin
        if (rst_n && en && fixup_done_pulse) begin
            $fwrite(trace_fp, "FIXUP_END pass=%0d cyc=%0d\n", dut.pass_idx, cycle);
            dump_merge_row(0, "row0");
            dump_merge_row(1, "row1");
        end
    end

    // Pass 3 replay startup
    reg pass3_replay_seen;
    always @(posedge clk) begin
        if (rst_n && en && dut.pass_idx == 2'd3 && dut.op_state == 3'd2 && !pass3_replay_seen) begin
            if (dut.replay_hold && !dut.replay_started) begin
                $fwrite(trace_fp, "P3_REPLAY_START cyc=%0d guard=%0d hold=%b\n",
                    cycle, dut.pass_replay_guard, dut.replay_hold);
                pass3_replay_seen = 1'b1;
            end
        end
        if (!rst_n) pass3_replay_seen = 1'b0;
    end

    initial begin : init_block
        integer fp, fh, idx, ri, tb_tick, ret, timeout_cycles;
        reg [8*256-1:0] fname;
        reg [15:0] tmpmem [0:63];
        reg signed [DATA_WIDTH-1:0] xvec [0:63];
        reg [TAPS*DATA_WIDTH-1:0] build, val;
        reg [8*1024-1:0] line;

        trace_fp = $fopen("trace_v3.log", "w");
        cycle = 0;
        out_count = 0;
        pass3_replay_seen = 0;
        last_state = 0;

        $readmemh("golden_output.mem", golden_mem);
        rst_n = 0; en = 0; start = 0; x_sub_vec_in = 0;
        #20;

        for (lane = 0; lane < OUT_LANES; lane = lane + 1) begin
            $sformat(fname, "%s/banks/weight_lane_%0d.mem",
                "/home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_In_Projection_Unit", lane);
            fh = $fopen(fname, "r");
            for (idx = 0; idx < 128; idx = idx + 1) begin
                line = "";
                if ($fgets(line, fh) != 0) begin
                    ret = $sscanf(line, "%h", val);
                    if (ret != 1) val = 0;
                end else val = 0;
                dut.bram_mem[lane][idx] = val;
            end
            $fclose(fh);
        end

        rst_n = 1; #20; en = 1;
        $readmemh("input.mem", tmpmem);
        for (ri = 0; ri < 64; ri = ri + 1) xvec[ri] = $signed(tmpmem[ri]);

        start = 1; tb_tick = 0;
        build = { xvec[7], xvec[6], xvec[5], xvec[4], xvec[3], xvec[2], xvec[1], xvec[0] };
        x_sub_vec_in = build;
        @(posedge clk); cycle = cycle + 1;
        for (idx = 0; idx < (16*TAPS); idx = idx + 1) begin
            build = { xvec[tb_tick*8 + 7], xvec[tb_tick*8 + 6], xvec[tb_tick*8 + 5], xvec[tb_tick*8 + 4],
                      xvec[tb_tick*8 + 3], xvec[tb_tick*8 + 2], xvec[tb_tick*8 + 1], xvec[tb_tick*8 + 0] };
            x_sub_vec_in = build;
            @(posedge clk); cycle = cycle + 1;
            if (tb_tick == TAPS-1) tb_tick = 0; else tb_tick = tb_tick + 1;
        end
        start = 0; x_sub_vec_in = 0;
        @(posedge clk); cycle = cycle + 1;

        timeout_cycles = 12000;
        while (out_count < 16 && timeout_cycles > 0) begin
            @(posedge clk);
            cycle = cycle + 1;
            timeout_cycles = timeout_cycles - 1;
        end

        $fwrite(trace_fp, "FINISH cyc=%0d emits=%0d busy=%b\n", cycle, out_count, busy);
        dump_merge_row(0, "FINAL_row0");
        dump_merge_row(1, "FINAL_row1");
        $fclose(trace_fp);
        $display("Trace written to trace_v3.log (%0d pass-3 emits)", out_count);
        $finish;
    end

    always @(posedge clk) if (rst_n) cycle = cycle + 1;

endmodule
