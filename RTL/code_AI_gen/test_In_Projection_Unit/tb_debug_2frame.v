`timescale 1ns/1ps
module tb_debug_2frame();
    localparam DATA_WIDTH = 16, OUT_LANES = 16, TAPS = 8;
    localparam INTER_TAG_HOLD_CYCLES = 56;
    reg clk = 0; reg rst_n = 0; reg en = 0; reg start = 0;
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in;
    wire signed [OUT_LANES*DATA_WIDTH-1:0] y_out;
    wire done_x, done_z, busy, frame_ready;
    wire [1:0] pass_idx_out; wire out_valid; wire [3:0] out_grp;
    In_Projection_Unit_Streaming_v3 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .start(start),
        .x_sub_vec_in(x_sub_vec_in), .y_out(y_out),
        .done_x(done_x), .done_z(done_z), .busy(busy), .frame_ready(frame_ready),
        .pass_idx_out(pass_idx_out), .out_valid(out_valid), .out_grp(out_grp),
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
    always #5 clk = ~clk;
    reg [15:0] in_mem [0:127];
    reg signed [DATA_WIDTH-1:0] xvec [0:63];
    integer v, k, tb_tick, li, idx, fh, ret;
    reg [8*256-1:0] fname;
    reg [8*1024-1:0] line;
    reg [TAPS*DATA_WIDTH-1:0] val, build;
    initial begin
        $readmemh("../../testbench/test_Inprojection/input_full.mem", in_mem);
        for (li = 0; li < OUT_LANES; li = li + 1) begin
            $sformat(fname, "banks/weight_lane_%0d.mem", li);
            fh = $fopen(fname, "r");
            for (idx = 0; idx < 128; idx = idx + 1) begin
                line = "";
                if ($fgets(line, fh) == 0) val = 0;
                else if ($sscanf(line, "%h", val) != 1) val = 0;
                dut.bram_mem[li][idx] = val;
            end
            $fclose(fh);
        end
        rst_n = 0; #20; rst_n = 1; #20; en = 1;
        for (v = 0; v < 2; v = v + 1) begin
            for (idx = 0; idx < 64; idx = idx + 1)
                xvec[idx] = $signed(in_mem[v*64 + idx]);
            if (v > 0) while (!frame_ready) @(posedge clk);
            build = {xvec[7],xvec[6],xvec[5],xvec[4],xvec[3],xvec[2],xvec[1],xvec[0]};
            x_sub_vec_in = build; start = 1; tb_tick = 0; @(posedge clk);
            for (k = 0; k < (128 + (v > 0 ? INTER_TAG_HOLD_CYCLES : 0)); k = k + 1) begin
                build = {xvec[tb_tick*8+7],xvec[tb_tick*8+6],xvec[tb_tick*8+5],xvec[tb_tick*8+4],
                         xvec[tb_tick*8+3],xvec[tb_tick*8+2],xvec[tb_tick*8+1],xvec[tb_tick*8+0]};
                x_sub_vec_in = build; @(posedge clk);
                if (tb_tick == TAPS-1) tb_tick = 0; else tb_tick = tb_tick + 1;
            end
            start = 0; @(posedge clk);
            while (busy) @(posedge clk);
            $display("v=%0d input_buf[0]=%0d expect=%0d ingest=%0d",
                     v, $signed(dut.input_buf[0][0+:DATA_WIDTH]), xvec[0],
                     dut.ingest_cnt);
        end
        $finish;
    end
endmodule
