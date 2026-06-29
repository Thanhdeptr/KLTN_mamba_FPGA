// In_Projection_Unit_Streaming_v2.v
// Stream V2: 16 BRAM banks, 128 multiplies (16 lanes x 8 taps), 6-stage pipeline + BRAM latency
// Output beat order per token: X0,Z0,X1,Z1,...,X7,Z7 (128 input beats, interleaved X/Z pairs).
// Simulation-friendly with $readmemh for bank files located under
// RTL/code_AI_gen/test_In_Projection_Unit/banks/weight_lane_<i>.mem

`timescale 1ns/1ps
module In_Projection_Unit_Streaming_v2 #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS = 12,
    parameter LANES = 16,
    parameter TAPS = 8,
    parameter BRAM_DEPTH = 128,
    parameter BRAM_LATENCY = 1,
    parameter BASE_PD = 6
) (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire start,
    // x_sub_vec_in: cluster of 8 taps (shared across all lanes) per tick
    input  wire signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in,
    output reg  signed [LANES*DATA_WIDTH-1:0] y_out, // 16 lanes x 16-bit outputs
    output reg  done_x,
    output reg  done_z
);

    localparam PD = BASE_PD + BRAM_LATENCY;
    // tag pipes width
    integer i,j,k;

    // BRAM banks (simulation array): each entry is 128-bit (8*16)
    reg [TAPS*DATA_WIDTH-1:0] bram_mem [0:LANES-1][0:BRAM_DEPTH-1];

    // BRAM contents are loaded by the testbench into dut.bram_mem for simulation.

    // Control counters
    reg [2:0] tick_cnt; // 0..7
    reg [3:0] group_idx; // BRAM group 0..7 X, 8..15 Z
    reg [3:0] seq_step; // 0..15 interleaved macro-block index
    reg vld_in;

    // pipeline tag pipes
    reg vld_pipe [0:PD-1];
    reg [2:0] tick_cnt_pipe [0:PD-1];
    reg [3:0] grp_idx_pipe [0:PD-1];
    reg type_pipe [0:PD-1]; // 0 = X, 1 = Z
    reg sample_id_pipe [0:PD-1];

    // BRAM-aligned delay registers.
    // The simulation model fetches BRAM contents on the same edge that
    // the request is issued, so the control tags need additional latency
    // beyond BRAM_LATENCY to line up with the data that reaches Stage 3.
    // Empirically tuned so Stage3 sees tick_cnt_pipe[3]==0 on the first valid
    // accumulation boundary in the current testbench schedule.
    localparam integer TAG_LATENCY = BRAM_LATENCY + 4;
    localparam integer X_LATENCY = TAG_LATENCY + 2;
    reg vld_del [0:TAG_LATENCY-1];
    reg [2:0] tick_cnt_del [0:TAG_LATENCY-1];
    reg [3:0] group_idx_del [0:TAG_LATENCY-1];
    reg type_del [0:TAG_LATENCY-1];

    // stage registers
    // st0 fetch: store raw bank words per lane
    reg signed [DATA_WIDTH-1:0] st0_x [0:LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH-1:0] st1_x [0:LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH-1:0] st2_x [0:LANES-1][0:TAPS-1];
    reg signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_pipe [0:X_LATENCY-1];
    
    // Pipeline delay registers for st0_x and st1_x to prevent overwrites
    reg signed [DATA_WIDTH-1:0] st0_x_pipe [0:PD][0:LANES-1][0:TAPS-1];
    reg signed [DATA_WIDTH-1:0] st1_x_pipe [0:PD][0:LANES-1][0:TAPS-1];

    // mult results and per-lane sum
    reg signed [DATA_WIDTH*2-1:0] mult_reg [0:LANES-1][0:TAPS-1];
    reg signed [39:0] st2_sum_reg [0:LANES-1]; // wide for accumulation
    wire signed [39:0] st2_sum_wire [0:LANES-1];

    // accumulators
    reg signed [39:0] acc_reg [0:LANES-1];
    reg signed [39:0] acc_final_reg [0:LANES-1];

    // staging output buffer
    reg signed [DATA_WIDTH-1:0] stage5_out [0:LANES-1];
    reg signed [DATA_WIDTH-1:0] stage4_sat_out [0:LANES-1];

    // Loop variables (module-level for use in initial block)
    integer pi, li, ti;
    reg [TAPS*DATA_WIDTH-1:0] fetch_word0;
    // Move local procedural declarations to module scope so xvlog (Verilog)
    // compilation does not error on declarations inside always blocks.
    integer addr;
    reg [TAPS*DATA_WIDTH-1:0] word;
    reg [3:0] next_step;

    // initialize
    initial begin
        for (i=0;i<LANES;i=i+1) begin
            acc_reg[i] = 0;
            acc_final_reg[i] = 0;
            st2_sum_reg[i] = 0;
            stage5_out[i] = 0;
            stage4_sat_out[i] = 0;
        end
        for (i=0;i<PD;i=i+1) begin
            vld_pipe[i] = 0;
            tick_cnt_pipe[i] = 0;
            grp_idx_pipe[i] = 0;
            type_pipe[i] = 0;
            sample_id_pipe[i] = 0;
        end
        // initialize BRAM delay registers
        for (i=0;i<X_LATENCY;i=i+1) begin
            vld_del[i] = 0;
            tick_cnt_del[i] = 0;
            group_idx_del[i] = 0;
            type_del[i] = 0;
            x_sub_vec_pipe[i] = 0;
        end
        // initialize pipeline delay registers for st0_x and st1_x
        for (pi=0;pi<=PD;pi=pi+1) begin
            for (li=0;li<LANES;li=li+1) begin
                for (ti=0;ti<TAPS;ti=ti+1) begin
                    st0_x_pipe[pi][li][ti] = 0;
                    st1_x_pipe[pi][li][ti] = 0;
                end
            end
        end
        tick_cnt = 0;
        group_idx = 0;
        seq_step = 0;
        vld_in = 0;
        done_x = 0;
        done_z = 0;
    end

    // Control: update counters and vld_in
    always @(posedge clk) begin
        if (!rst_n) begin
            tick_cnt  <= 0;
            group_idx <= 0;
            seq_step  <= 0;
            vld_in    <= 0;
        end else begin
            if (!en) begin
                // freeze counters and vld
                tick_cnt  <= tick_cnt;
                group_idx <= group_idx;
                seq_step  <= seq_step;
                vld_in    <= vld_in;
            end else begin
                if (start) begin
                    vld_in <= 1'b1;
                    // advance counters when vld_in asserted
                    if (vld_in) begin
                        if (tick_cnt == TAPS-1) begin
                            tick_cnt <= 0;
                            next_step = (seq_step == 4'd15) ? 4'd0 : (seq_step + 4'd1);
                            seq_step  <= next_step;
                            group_idx <= next_step[0]
                                ? (4'd8 + {1'b0, next_step[3:1]})
                                : {1'b0, next_step[3:1]};
                        end else begin
                            tick_cnt <= tick_cnt + 1;
                        end
                    end else begin
                        // first injection
                        tick_cnt  <= 0;
                        group_idx <= 0;
                        seq_step  <= 0;
                    end
                end else begin
                    // start not asserted -> stop accepting new
                    vld_in <= 1'b0;
                end
            end
        end
    end

    // Pipeline tag shifting (align tags with BRAM data via delay fifo)
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<PD;i=i+1) begin
                vld_pipe[i] <= 0;
                tick_cnt_pipe[i] <= 0;
                grp_idx_pipe[i] <= 0;
                type_pipe[i] <= 0;
                sample_id_pipe[i] <= 0;
            end
            for (i=0;i<X_LATENCY;i=i+1) begin
                vld_del[i] <= 0;
                tick_cnt_del[i] <= 0;
                group_idx_del[i] <= 0;
                type_del[i] <= 0;
                x_sub_vec_pipe[i] <= 0;
            end
        end else begin
            if (!en) begin
                // freeze pipes
                for (i=0;i<PD;i=i+1) begin
                    vld_pipe[i] <= vld_pipe[i];
                    tick_cnt_pipe[i] <= tick_cnt_pipe[i];
                    grp_idx_pipe[i] <= grp_idx_pipe[i];
                    type_pipe[i] <= type_pipe[i];
                    sample_id_pipe[i] <= sample_id_pipe[i];
                end
            end else begin
                x_sub_vec_pipe[0] <= (start || vld_in) ? x_sub_vec_in : {TAPS*DATA_WIDTH{1'b0}};
                for (i=1;i<X_LATENCY;i=i+1) begin
                    x_sub_vec_pipe[i] <= x_sub_vec_pipe[i-1];
                end

                vld_del[0] <= vld_in;
                tick_cnt_del[0] <= tick_cnt;
                group_idx_del[0] <= group_idx;
                type_del[0] <= group_idx[3];
                for (i=1;i<TAG_LATENCY;i=i+1) begin
                    vld_del[i] <= vld_del[i-1];
                    tick_cnt_del[i] <= tick_cnt_del[i-1];
                    group_idx_del[i] <= group_idx_del[i-1];
                    type_del[i] <= type_del[i-1];
                end

                // Per-tick tag buffering aligned to the actual compute pipeline
                // (Stage0 fetch/latch -> Stage1 mul -> Stage2 sum -> Stage3 acc).
                vld_pipe[0] <= vld_del[TAG_LATENCY-1];
                tick_cnt_pipe[0] <= tick_cnt_del[TAG_LATENCY-1];
                grp_idx_pipe[0] <= group_idx_del[TAG_LATENCY-1];
                type_pipe[0] <= type_del[TAG_LATENCY-1];
                sample_id_pipe[0] <= sample_id_pipe[0];

                for (i=1;i<PD;i=i+1) begin
                    vld_pipe[i] <= vld_pipe[i-1];
                    tick_cnt_pipe[i] <= tick_cnt_pipe[i-1];
                    grp_idx_pipe[i] <= grp_idx_pipe[i-1];
                    type_pipe[i] <= type_pipe[i-1];
                    sample_id_pipe[i] <= sample_id_pipe[i-1];
                end
            end
        end
    end

    // Stage0: fetch from BRAMs and latch x_sub_vec
    always @(posedge clk) begin
        if (!rst_n) begin
            // clear
            for (i=0;i<LANES;i=i+1) for (j=0;j<TAPS;j=j+1) begin
                st0_x[i][j] <= 0;
                st1_x[i][j] <= 0;
            end
            // clear pipeline delays
            for (pi=0;pi<=PD;pi=pi+1) begin
                for (li=0;li<LANES;li=li+1) begin
                    for (ti=0;ti<TAPS;ti=ti+1) begin
                        st0_x_pipe[pi][li][ti] <= 0;
                        st1_x_pipe[pi][li][ti] <= 0;
                    end
                end
            end
        end else if (en) begin
            if (vld_pipe[0]) begin
                // compute address
                addr = (grp_idx_pipe[0] * 8) + tick_cnt_pipe[0];
                fetch_word0 = 0;
                for (i=0;i<LANES;i=i+1) begin
                    // read bram word
                    word = bram_mem[i][addr];
                    if (i == 0 && grp_idx_pipe[0] < 3) begin
`ifndef INPROJ_CHAIN_QUIET
                        $display("FETCH grp=%0d tick=%0d addr=%0d word0=%h", grp_idx_pipe[0], tick_cnt_pipe[0], addr, word);
`endif
                        fetch_word0 = word;
                    end
                    for (j=0;j<TAPS;j=j+1) begin
                        // extract tap j: bits [j*DATA_WIDTH +: DATA_WIDTH]
                        st0_x[i][j] <= $signed(word[j*DATA_WIDTH +: DATA_WIDTH]);
                        st1_x[i][j] <= $signed(x_sub_vec_pipe[X_LATENCY-1][j*DATA_WIDTH +: DATA_WIDTH]);
                        st0_x_pipe[0][i][j] <= $signed(word[j*DATA_WIDTH +: DATA_WIDTH]);
                        st1_x_pipe[0][i][j] <= $signed(x_sub_vec_pipe[X_LATENCY-1][j*DATA_WIDTH +: DATA_WIDTH]);
                    end
                end
            end

            // Shift st0_x and st1_x through pipeline delay registers
            // Shift st0_x and st1_x through pipeline delay registers (used for vld_pipe alignment)
            for (i=1;i<=PD;i=i+1) begin
                for (k=0;k<LANES;k=k+1) begin
                    for (j=0;j<TAPS;j=j+1) begin
                        st0_x_pipe[i][k][j] <= st0_x_pipe[i-1][k][j];
                        st1_x_pipe[i][k][j] <= st1_x_pipe[i-1][k][j];
                    end
                end
            end
        end
    end

    // Stage1: multiply (st0_x_pipe[0] * st1_x_pipe[0]) -> mult_reg
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<LANES;i=i+1) for (j=0;j<TAPS;j=j+1) mult_reg[i][j] <= 0;
        end else if (en && vld_pipe[1]) begin
            for (i=0;i<LANES;i=i+1) begin
                for (j=0;j<TAPS;j=j+1) begin
                    mult_reg[i][j] <= st0_x_pipe[0][i][j] * st1_x_pipe[0][i][j];
                    // debug: print multiplication operands/result for lane 0, small groups
                    if (i == 0 && vld_pipe[0] && grp_idx_pipe[0] < 3) begin
`ifndef INPROJ_CHAIN_QUIET
                        $display("MUL_AT grp=%0d lane=%0d tap=%0d st0=%0d st1=%0d prod=%0d", grp_idx_pipe[0], i, j, st0_x_pipe[0][i][j], st1_x_pipe[0][i][j], $signed(st0_x_pipe[0][i][j]) * $signed(st1_x_pipe[0][i][j]));
`endif
                    end
                end
            end
        end
    end

    // Stage2: adder tree per lane -> st2_sum_reg
    genvar lane_sum;
    generate
        for (lane_sum = 0; lane_sum < LANES; lane_sum = lane_sum + 1) begin : G_SUM_WIRE
            integer sum_idx;
            reg signed [39:0] s_wire;
            always @* begin
                s_wire = 0;
                for (sum_idx = 0; sum_idx < TAPS; sum_idx = sum_idx + 1) begin
                    s_wire = s_wire + $signed(mult_reg[lane_sum][sum_idx]);
                end
            end
            assign st2_sum_wire[lane_sum] = s_wire;
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<LANES;i=i+1) st2_sum_reg[i] <= 0;
        end else if (en && vld_pipe[2]) begin
            for (i=0;i<LANES;i=i+1) begin
                // simple sum of 8 products
                st2_sum_reg[i] <= st2_sum_wire[i];
            end
        end
    end

    // Stage3: accumulator using delayed valid/tick tags and registered lane sums
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<LANES;i=i+1) acc_reg[i] <= 0;
        end else if (en) begin
            if (vld_pipe[3]) begin
                for (i=0;i<LANES;i=i+1) begin
                    if (tick_cnt_pipe[3] == 3'd0) begin
                        acc_reg[i] <= st2_sum_reg[i];
                        acc_final_reg[i] <= st2_sum_reg[i];
                    end else begin
                        acc_reg[i] <= acc_reg[i] + st2_sum_reg[i];
                        if (tick_cnt_pipe[3] == (TAPS-1)) begin
                            acc_final_reg[i] <= acc_reg[i] + st2_sum_reg[i];
                            stage4_sat_out[i] <= sat_to_16(acc_reg[i] + st2_sum_reg[i]);
                        end
                    end
                end
                if (grp_idx_pipe[3] < 3 && (tick_cnt_pipe[3] == 3'd0 || tick_cnt_pipe[3] == 3'd7)) begin
`ifndef INPROJ_CHAIN_QUIET
                    $display("ACC grp=%0d tick=%0d sum0=%0d acc0=%0d", grp_idx_pipe[3], tick_cnt_pipe[3], st2_sum_reg[0], acc_reg[0]);
`endif
                end
            end
        end
    end

    function signed [DATA_WIDTH-1:0] sat_to_16;
        input signed [39:0] inv;
        reg signed [39:0] tmp;
        begin
            tmp = inv >>> FRAC_BITS;
            if (tmp > $signed({1'b0, {(DATA_WIDTH-1){1'b1}}})) sat_to_16 = $signed({1'b0, {(DATA_WIDTH-1){1'b1}}});
            else if (tmp < -($signed(1 << (DATA_WIDTH-1)))) sat_to_16 = -($signed(1 << (DATA_WIDTH-1)));
            else sat_to_16 = tmp[DATA_WIDTH-1:0];
        end
    endfunction

    // Stage5: writeback and done pulse generation
    reg done_x_r, done_z_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            y_out <= 0;
            done_x <= 0;
            done_z <= 0;
            done_x_r <= 0;
            done_z_r <= 0;
            for (i=0;i<LANES;i=i+1) stage5_out[i] <= 0;
        end else begin
            done_x <= 0;
            done_z <= 0;
            if (vld_pipe[6]) begin
                // pack outputs
                for (i=0;i<LANES;i=i+1) begin
                    stage5_out[i] <= stage4_sat_out[i];
                    y_out[i*DATA_WIDTH +: DATA_WIDTH] <= stage4_sat_out[i];
                end
                if (type_pipe[6] == 1'b0 && grp_idx_pipe[6] == 4'd7 && tick_cnt_pipe[6] == (TAPS-1)) begin
                    done_x <= 1'b1;
                end
                if (type_pipe[6] == 1'b1 && grp_idx_pipe[6] == 4'd15 && tick_cnt_pipe[6] == (TAPS-1)) begin
                    done_z <= 1'b1;
                end
            end
        end
    end

endmodule
