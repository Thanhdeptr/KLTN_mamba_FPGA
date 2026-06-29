`timescale 1ns/1ps
module tb_in_projection_unit_stream_v2();
    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg start = 0;

    localparam DATA_WIDTH = 16;
    localparam LANES = 16;
    localparam TAPS = 8;

    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in;
    wire signed [LANES*DATA_WIDTH-1:0] y_out;
    wire done_x;
    wire done_z;
    wire [8*DATA_WIDTH-1:0] dbg_fetch0;
    wire [8*(DATA_WIDTH*2)-1:0] dbg_mult0;
    wire signed [39:0] dbg_sum0;
    wire signed [39:0] dbg_acc0;
    wire signed [DATA_WIDTH-1:0] dbg_sat0;
    reg [15:0] golden_mem [0:255];
    
    // Module-level variables for test
    integer err_final;

    // instantiate DUT
    In_Projection_Unit_Streaming_v2 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .start(start),
        .x_sub_vec_in(x_sub_vec_in), .y_out(y_out), .done_x(done_x), .done_z(done_z)
    );

    // clock
    always #5 clk = ~clk; // 100 MHz

    integer fp;
    integer li;
    reg [8*256-1:0] fname; // filename buffer (bytes)
    // input vector memory (64 values)
    reg signed [DATA_WIDTH-1:0] xvec [0:63];
    integer tb_tick;
    // temp memory for $readmemh
    reg [15:0] tmpmem [0:63];
    integer ri;
    reg [8*256-1:0] inpf; // input filename buffer
    integer tj;
    reg [TAPS*DATA_WIDTH-1:0] build;
    integer chk_count;
    // file read helpers
    integer fh;
    reg [8*1024-1:0] line; // large line buffer for $fgets
    integer idx;
    reg [TAPS*DATA_WIDTH-1:0] val;
    integer ret;
    // tracing counters
    integer rel_cycle;
    integer total_cycles;
    integer addr_val;
    integer out_count;
    integer lane;
    integer timeout_cycles;
    reg capture_en;
    // group to follow end-to-end
    integer watch_grp = 2;

    // Capture snapshot registers to hold pipeline state at different stages
    reg signed [DATA_WIDTH-1:0] snap_st0_x[0:LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH-1:0] snap_st1_x[0:LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH*2-1:0] snap_mult_reg[0:LANES-1][0:TAPS-1];
    reg signed [39:0] snap_acc_reg[0:LANES-1];
    reg signed [DATA_WIDTH-1:0] snap_sat0;
    
    task capture_pipeline_snapshot;
        // Capture stage data when it's at Stage 5 (output stage)
        // Use st0_x_pipe[5], st1_x_pipe[5], etc. which are delayed versions
        integer ii, jj;
        begin
            for (ii=0; ii<LANES; ii=ii+1) begin
                for (jj=0; jj<TAPS; jj=jj+1) begin
                    snap_st0_x[ii][jj] = $signed(dut.st0_x_pipe[5][ii][jj]);
                    snap_st1_x[ii][jj] = $signed(dut.st1_x_pipe[5][ii][jj]);
                    snap_mult_reg[ii][jj] = $signed(dut.mult_reg[ii][jj]);
                end
                snap_acc_reg[ii] = $signed(dut.acc_reg[ii]);
            end
            snap_sat0 = $signed(dut.dbg_sat0);
        end
    endtask

    `include "trace_helpers.vh"
    always @(posedge clk) begin
        // Follow a single group (`watch_grp`) through all stages and print aligned values
        if (capture_en) begin
            // Stage 0: fetch
            if (dut.vld_pipe[0] && dut.grp_idx_pipe[0] == watch_grp) begin
                $display("[GRP%0d_ST0] cyc=%0d tick=%0d addr=%0d word0=%h tap0=%0d", watch_grp, rel_cycle, dut.tick_cnt_pipe[0],
                         (dut.grp_idx_pipe[0] * 8) + dut.tick_cnt_pipe[0],
                         dut.bram_mem[0][(dut.grp_idx_pipe[0] * 8) + dut.tick_cnt_pipe[0]],
                         $signed(dut.bram_mem[0][(dut.grp_idx_pipe[0] * 8) + dut.tick_cnt_pipe[0]][0 +: DATA_WIDTH]));
            end
            // Stage 1: multiply operands/results
            if (dut.vld_pipe[1] && dut.grp_idx_pipe[1] == watch_grp) begin
                $display("[GRP%0d_ST1] cyc=%0d tick=%0d st0=%0d st1=%0d prod_now=%0d mult_reg=%0d", watch_grp, rel_cycle, dut.tick_cnt_pipe[1],
                         $signed(dut.st0_x_pipe[1][0][0]), $signed(dut.st1_x_pipe[1][0][0]),
                         $signed(dut.st0_x_pipe[1][0][0]) * $signed(dut.st1_x_pipe[1][0][0]),
                         $signed(dut.mult_reg[0][0]));
            end
            // Stage 2: adder tree result
            if (dut.vld_pipe[2] && dut.grp_idx_pipe[2] == watch_grp) begin
                $display("[GRP%0d_ST2] cyc=%0d tick=%0d st2_sum=%0d", watch_grp, rel_cycle, dut.tick_cnt_pipe[2], $signed(dut.st2_sum_reg[0]));
            end
            // Stage 3: accumulator evolution
            if (dut.vld_pipe[3] && dut.grp_idx_pipe[3] == watch_grp) begin
                $display("[GRP%0d_ST3] cyc=%0d tick=%0d acc=%0d", watch_grp, rel_cycle, dut.tick_cnt_pipe[3], $signed(dut.acc_reg[0]));
            end
            // Stage 4: saturated value computed
            if (dut.vld_pipe[4] && dut.grp_idx_pipe[4] == watch_grp) begin
                $display("[GRP%0d_ST4] cyc=%0d tick=%0d sat=%0d", watch_grp, rel_cycle, dut.tick_cnt_pipe[4], $signed(dut.stage4_sat_out[0]));
            end
            // Stage 5/6: writeback
            if (dut.vld_pipe[6] && dut.grp_idx_pipe[6] == watch_grp) begin
                $display("[GRP%0d_ST6] cyc=%0d tick=%0d y=%0d", watch_grp, rel_cycle, dut.tick_cnt_pipe[6], $signed(dut.y_out[0 +: DATA_WIDTH]));
            end
        end
        // keep original detailed traces for group 0 (legacy)
        #1;
        if (capture_en && dut.vld_pipe[1] && dut.grp_idx_pipe[1] == 4'd0 && rel_cycle < 200) begin
            $display("MULT_STAGE1 grp=0 tick=%0d st0_x0_t0=%0d st1_x0_t0=%0d mult0=%0d",
                     dut.tick_cnt_pipe[1], $signed(dut.st0_x_pipe[1][0][0]), $signed(dut.st1_x_pipe[1][0][0]), 
                     $signed(dut.mult_reg[0][0]));
            `DISP_XPIPE(0);
            `DISP_XPIPE(1);
            `DISP_XPIPE(2);
            `DISP_XPIPE(3);
            `DISP_ST1X(1,0);
            `DISP_ST1X(2,0);
            `DISP_ST1X(3,0);
        end
        
        // Detailed Stage 2 tracing for group 0
        if (capture_en && dut.vld_pipe[2] && dut.grp_idx_pipe[2] == 4'd0 && rel_cycle < 100) begin
            $display("SUM_STAGE2  grp=0 tick=%0d mult0=%0d st2_sum_reg0=%0d",
                     dut.tick_cnt_pipe[2], $signed(dut.mult_reg[0][0]), $signed(dut.st2_sum_reg[0]));
        end
        
        // Detailed Stage 3 tracing for group 0
        if (capture_en && dut.vld_pipe[3] && dut.grp_idx_pipe[3] == 4'd0 && rel_cycle < 100) begin
            $display("ACC_STAGE3  grp=0 tick=%0d sum_in0=%0d acc0_before=%0d acc0_after=%0d sat_out0=%0d",
                     dut.tick_cnt_pipe[3], $signed(dut.st2_sum_reg[0]), $signed(dut.acc_reg[0]),
                     (dut.tick_cnt_pipe[3] == 0) ? $signed(dut.st2_sum_reg[0]) : ($signed(dut.acc_reg[0]) + $signed(dut.st2_sum_reg[0])),
                     $signed(dut.stage4_sat_out[0]));
        end
        
        if (capture_en && out_count < 16) begin
            if (dut.vld_pipe[6] && dut.tick_cnt_pipe[6] == (TAPS-1)) begin
                // Capture pipeline snapshot for analysis
                capture_pipeline_snapshot();
                
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    $fwrite(fp, "%04x\n", dut.y_out[lane*DATA_WIDTH +: DATA_WIDTH]);
                end
                if (out_count < 3) begin
                    $display("DBG group=%0d type=%0d tick5=%0d fetch0=%h mult0=%h sum0=%0d acc0=%0d sat0=%0d y0=%h",
                             dut.grp_idx_pipe[6], dut.type_pipe[6], dut.tick_cnt_pipe[6],
                             dut.dbg_fetch0, dut.dbg_mult0, dut.dbg_sum0, dut.dbg_acc0, dut.dbg_sat0,
                             dut.y_out[0 +: DATA_WIDTH]);
                    $display("DBG_DETAIL st0_x0 = %h %h %h %h %h %h %h %h",
                             snap_st0_x[0][0], snap_st0_x[0][1], snap_st0_x[0][2], snap_st0_x[0][3],
                             snap_st0_x[0][4], snap_st0_x[0][5], snap_st0_x[0][6], snap_st0_x[0][7]);
                    $display("DBG_DETAIL st1_x0 = %h %h %h %h %h %h %h %h",
                             snap_st1_x[0][0], snap_st1_x[0][1], snap_st1_x[0][2], snap_st1_x[0][3],
                             snap_st1_x[0][4], snap_st1_x[0][5], snap_st1_x[0][6], snap_st1_x[0][7]);
                    $display("DBG_DETAIL mult0  = %h %h %h %h %h %h %h %h",
                             snap_mult_reg[0][0], snap_mult_reg[0][1], snap_mult_reg[0][2], snap_mult_reg[0][3],
                             snap_mult_reg[0][4], snap_mult_reg[0][5], snap_mult_reg[0][6], snap_mult_reg[0][7]);
                end
                out_count = out_count + 1;
                $display("CAPTURE group=%0d type=%0d vec=%0d y0=%h", dut.grp_idx_pipe[6], dut.type_pipe[6], out_count, dut.y_out[0 +: DATA_WIDTH]);
            end
        end
    end

    initial begin
        // Waveform dump: VCD and WDB
        $dumpfile("tb_stream_v2.vcd");
        $dumpvars(0, tb_in_projection_unit_stream_v2);
        // xsim will also create .wdb automatically when run with default options; ensure dut scope recorded

        fp = $fopen("rtl_output.mem", "w");
        $readmemh("golden_output.mem", golden_mem);

        // reset
        rst_n = 0; en = 0; start = 0; x_sub_vec_in = 0;
        #20;
        // load bank files into DUT memory (ensure simulator can access them from CWD)
        for (li = 0; li < 16; li = li + 1) begin
            $sformat(fname, "%s/banks/weight_lane_%0d.mem", "/home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_In_Projection_Unit", li);
            $display("TB loading %s into DUT (line-by-line)", fname);
            fh = $fopen(fname, "r");
            if (fh == 0) begin
                $display("ERROR: cannot open %s", fname);
            end else begin
                for (idx = 0; idx < 128; idx = idx + 1) begin
                    line = "";
                    if ($fgets(line, fh) == 0) begin
                        $display("WARN: unexpected EOF in %s at idx %0d", fname, idx);
                        val = 0;
                    end else begin
                        // parse hex string into value
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

        // enable
        en = 1;

        // load input.mem (64 16-bit hex words)
        $display("TB loading input.mem");
        inpf = "input.mem";
        $readmemh(inpf, tmpmem);
        for (ri = 0; ri < 64; ri = ri + 1) begin
            // interpret as signed 16-bit
            xvec[ri] = $signed(tmpmem[ri]);
        end

        // prepare counters
        tb_tick = 0;
        out_count = 0;
        capture_en = 0;
        rel_cycle = 0;

        // Full run: feed 16 groups x 8 ticks = 128 valid clusters.
        // Keep start high with one warm-up edge because DUT asserts vld_in one cycle later.
        start = 1;
        capture_en = 1;
        build = { xvec[7], xvec[6], xvec[5], xvec[4], xvec[3], xvec[2], xvec[1], xvec[0] };
        x_sub_vec_in = build;
        @(posedge clk); // warm-up edge

        for (idx = 0; idx < (16*TAPS); idx = idx + 1) begin
            build = { xvec[tb_tick*8 + 7], xvec[tb_tick*8 + 6], xvec[tb_tick*8 + 5], xvec[tb_tick*8 + 4],
                      xvec[tb_tick*8 + 3], xvec[tb_tick*8 + 2], xvec[tb_tick*8 + 1], xvec[tb_tick*8 + 0] };
            x_sub_vec_in = build;
            @(posedge clk);
            if (rel_cycle < 32) begin
                $display("PIPE_CYCLE %0d: start=%b en=%b done_x=%b done_z=%b vld=%b%b%b%b%b%b%b tick=%0d %0d %0d %0d %0d %0d %0d grp=%0d %0d %0d %0d %0d %0d %0d y0=%0d gold0=%0d",
                         rel_cycle, start, en, done_x, done_z,
                         dut.vld_pipe[0], dut.vld_pipe[1], dut.vld_pipe[2], dut.vld_pipe[3], dut.vld_pipe[4], dut.vld_pipe[5], dut.vld_pipe[6],
                         dut.tick_cnt_pipe[0], dut.tick_cnt_pipe[1], dut.tick_cnt_pipe[2], dut.tick_cnt_pipe[3], dut.tick_cnt_pipe[4], dut.tick_cnt_pipe[5], dut.tick_cnt_pipe[6],
                         dut.grp_idx_pipe[0], dut.grp_idx_pipe[1], dut.grp_idx_pipe[2], dut.grp_idx_pipe[3], dut.grp_idx_pipe[4], dut.grp_idx_pipe[5], dut.grp_idx_pipe[6],
                         $signed(dut.y_out[0 +: DATA_WIDTH]), $signed(golden_mem[out_count*LANES]));
            end
            rel_cycle = rel_cycle + 1;
            if (tb_tick == TAPS-1) tb_tick = 0; else tb_tick = tb_tick + 1;
        end

        start = 0;
        x_sub_vec_in = 0;

        // Drain pipeline and capture 16 output vectors (each vector = 16 lanes).
        timeout_cycles = 300;
        while (out_count < 16 && timeout_cycles > 0) begin
            @(posedge clk);
            rel_cycle = rel_cycle + 1;
            timeout_cycles = timeout_cycles - 1;
        end
        capture_en = 0;

        if (out_count != 16) begin
            $display("ERROR: capture timeout, expected 16 vectors but got %0d", out_count);
        end else begin
            $display("Captured %0d vectors (%0d values) to rtl_output.mem", out_count, out_count*LANES);
            // Final trace using captured snapshots from last output
            err_final = $signed(dut.y_out[0 +: DATA_WIDTH]) - $signed(golden_mem[(out_count-1)*LANES]);
            $display("TRACE vec=%0d lane=0 cyc=%0d start=%b en=%b done_x=%b done_z=%b vld=%b%b%b%b%b%b%b tick=%0d %0d %0d %0d %0d %0d %0d grp=%0d %0d %0d %0d %0d %0d %0d y0=%0d gold0=%0d err0=%0d",
                     out_count-1, rel_cycle, start, en, done_x, done_z,
                     dut.vld_pipe[0], dut.vld_pipe[1], dut.vld_pipe[2], dut.vld_pipe[3], dut.vld_pipe[4], dut.vld_pipe[5], dut.vld_pipe[6],
                     dut.tick_cnt_pipe[0], dut.tick_cnt_pipe[1], dut.tick_cnt_pipe[2], dut.tick_cnt_pipe[3], dut.tick_cnt_pipe[4], dut.tick_cnt_pipe[5], dut.tick_cnt_pipe[6],
                     dut.grp_idx_pipe[0], dut.grp_idx_pipe[1], dut.grp_idx_pipe[2], dut.grp_idx_pipe[3], dut.grp_idx_pipe[4], dut.grp_idx_pipe[5], dut.grp_idx_pipe[6],
                     $signed(dut.y_out[0 +: DATA_WIDTH]), $signed(golden_mem[(out_count-1)*LANES]), err_final);
            $display("  st0_x0   = %0d %0d %0d %0d %0d %0d %0d %0d",
                     snap_st0_x[0][0], snap_st0_x[0][1], snap_st0_x[0][2], snap_st0_x[0][3],
                     snap_st0_x[0][4], snap_st0_x[0][5], snap_st0_x[0][6], snap_st0_x[0][7]);
            $display("  st1_x0   = %0d %0d %0d %0d %0d %0d %0d %0d",
                     snap_st1_x[0][0], snap_st1_x[0][1], snap_st1_x[0][2], snap_st1_x[0][3],
                     snap_st1_x[0][4], snap_st1_x[0][5], snap_st1_x[0][6], snap_st1_x[0][7]);
            $display("  mult0    = %0d %0d %0d %0d %0d %0d %0d %0d",
                     snap_mult_reg[0][0], snap_mult_reg[0][1], snap_mult_reg[0][2], snap_mult_reg[0][3],
                     snap_mult_reg[0][4], snap_mult_reg[0][5], snap_mult_reg[0][6], snap_mult_reg[0][7]);
            $display("  sum/acc/sat = %0d / %0d / %0d  stage5_out0=%0d",
                     $signed(dut.st2_sum_reg[0]), snap_acc_reg[0], snap_sat0, $signed(dut.stage5_out[0]));
        end

        $fclose(fp);
        $display("Simulation finished, outputs in rtl_output.mem");
        $finish;
    end

endmodule
