`include "../../code_initial/_parameter.v"

module Scan_Core_Engine_pipe1
(
    input clk,
    input reset,
    
    input start,           
    input en,           
    input clear_h,         // Reset Hidden State
    output reg done,       
    
    // Inputs
    input signed [`DATA_WIDTH-1:0] delta_val,
    input signed [`DATA_WIDTH-1:0] x_val,
    input signed [`DATA_WIDTH-1:0] D_val,     
    input signed [`DATA_WIDTH-1:0] gate_val,  

    input signed [16 * `DATA_WIDTH - 1 : 0] A_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] B_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] C_vec,

    // Output
    output reg signed [`DATA_WIDTH-1:0] y_out,

    // ============================================================
    // PE ARRAY EXTERNAL
    // ============================================================

    output reg [1:0] pe_op_mode_out,
    output reg       pe_clear_acc_out,

    // Data dua vao pe (16 PE * 16 bit)
    output reg [16 * `DATA_WIDTH - 1 : 0] pe_in_a_vec,
    output reg [16 * `DATA_WIDTH - 1 : 0] pe_in_b_vec,

    input wire [16 * `DATA_WIDTH - 1 : 0] pe_result_vec
);

    // Internal Registers
    reg signed [`DATA_WIDTH-1:0] h_reg [15:0];
    reg signed [`DATA_WIDTH-1:0] h_new_temp [15:0];
    reg signed [`DATA_WIDTH-1:0] deltaB_stored [15:0];
    reg signed [`DATA_WIDTH-1:0] discA_stored [15:0];   
    reg signed [`DATA_WIDTH-1:0] deltaBx_stored [15:0]; 
    
    // Internal Wires for Local Units
    wire signed [`DATA_WIDTH-1:0] A_in [15:0];
    wire signed [`DATA_WIDTH-1:0] B_in [15:0];
    wire signed [`DATA_WIDTH-1:0] C_in [15:0];
    
    // Exp Unit & SiLU Unit
    wire signed [`DATA_WIDTH-1:0] exp_in [15:0];
    wire signed [`DATA_WIDTH-1:0] exp_out [15:0];
    wire signed [`DATA_WIDTH-1:0] silu_out; 
    reg  signed [`DATA_WIDTH-1:0] exp_in_reg [15:0];
    
    // Residual + Gating pipeline
    (* use_dsp = "yes" *) reg signed [31:0] Dx_prod;
    reg signed [31:0] y_with_D;
    reg signed [63:0] y_final_raw;
    reg signed [31:0] sum_stage1_0, sum_stage1_1, sum_stage1_2, sum_stage1_3;
    reg signed [31:0] sum_stage2_0, sum_stage2_1;
    reg signed [31:0] sum_stage3;
    (* use_dsp = "yes" *) wire signed [63:0] gated_raw_mul = $signed(y_with_D) * $signed(silu_out);
    wire signed [63:0] gated_raw_comb = gated_raw_mul >>> `FRAC_BITS;

    // Registered PE inputs (pipeline cut after unpack)
    reg [16 * `DATA_WIDTH - 1 : 0] pe_in_a_vec_r;
    reg [16 * `DATA_WIDTH - 1 : 0] pe_in_b_vec_r;
    reg [16 * `DATA_WIDTH - 1 : 0] pe_result_vec_r;

    // Unpack 
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : unpack
            assign A_in[i] = A_vec[i*`DATA_WIDTH +: `DATA_WIDTH];
            assign B_in[i] = B_vec[i*`DATA_WIDTH +: `DATA_WIDTH];
            assign C_in[i] = C_vec[i*`DATA_WIDTH +: `DATA_WIDTH];
            
            assign exp_in[i] = exp_in_reg[i];
            
            Exp_Unit exp_u (
                .clk(clk),
                .in_data(exp_in[i]),
                .out_data(exp_out[i])
            );
        end
    endgenerate

    SiLU_Unit_PWL silu_u (
        .clk(clk),
        .in_data(gate_val),
        .out_data(silu_out)
    );

    // FSM
    reg [3:0] state;
    localparam S_IDLE  = 0;
    localparam S_STEP1 = 1; // Calc Delta * A
    localparam S_STEP2 = 2; // Calc Delta * B
    localparam S_STEP2W = 14; // Wait for Delta*B PE output
    localparam S_STEP3 = 3; // Calc (DeltaB) * x
    localparam S_STEP3W = 11; // Wait for Exp_Unit 2-cycle latency
    localparam S_STEP4 = 4; // Calc discA * h_old
    localparam S_STEP5 = 5; // Calc h_new = ... + ...
    localparam S_STEP5W = 12; // Wait for PE ADD output to settle (1-cycle latency)
    localparam S_STEP6 = 6; // Calc C * h_new
    localparam S_STEP6W = 13; // Wait for PE MUL output (C*h_new) to settle
    localparam S_STEP6WW = 15; // Extra wait for registered PE results to settle (pipe1)
    localparam S_STEP7 = 7;  // Reduce stage 1
    localparam S_STEP8 = 8;  // Reduce stage 2
    localparam S_STEP9 = 9;  // Residual add
    localparam S_STEP10 = 10; // Gate mul + saturate output

    integer j;
    // Instrumentation
    reg [3:0] prev_state;
    reg prev_start_r;
    reg prev_done_r;
    // small extra-cycle flag for S_STEP3W to compensate added pipeline latency
    reg step3w_extra;
    // small counter to allow multiple extra cycles in S_STEP3W
    reg [1:0] step3w_cnt;
    // small counter to allow multiple extra cycles in S_STEP2W so pe_result_vec_r can settle
    reg [1:0] step2w_cnt;

    // Per-state cycle counters (instrumentation)
    reg [31:0] state_cycles [0:15];

    // SEQUENTIAL LOGIC
    always @(posedge clk or posedge reset) begin
            if (reset) begin
            state <= S_IDLE;
            done <= 0;
            y_out <= 0;
            sum_stage1_0 <= 0;
            sum_stage1_1 <= 0;
            sum_stage1_2 <= 0;
            sum_stage1_3 <= 0;
            sum_stage2_0 <= 0;
            sum_stage2_1 <= 0;
            sum_stage3 <= 0;
            Dx_prod <= 0;
            y_with_D <= 0;
            y_final_raw <= 0;
            pe_in_a_vec_r <= 0;
            pe_in_b_vec_r <= 0;
            pe_result_vec_r <= 0;
            for(j=0; j<16; j=j+1) begin
                h_reg[j] <= 0;
                h_new_temp[j] <= 0;
                deltaB_stored[j] <= 0;
                discA_stored[j] <= 0;
                deltaBx_stored[j] <= 0;
                exp_in_reg[j] <= 0;
            end
            step3w_extra <= 0;
            step3w_cnt <= 0;
            step2w_cnt <= 0;
            for (j=0; j<16; j=j+1) state_cycles[j] <= 0;
        end else begin
            // capture PE outputs into a local register to stabilize reduction stage
            pe_result_vec_r <= pe_result_vec;

            // Per-cycle logging to trace timing of PE outputs vs registered copy
            $display("CYCLE_LOG PIPE time=%0t state=%0d pe_result_vec=%h pe_result_vec_r=%h exp_in_reg0=%04h", $time, state, pe_result_vec, pe_result_vec_r, exp_in_reg[0]);

            if (clear_h) begin
                for(j=0; j<16; j=j+1) h_reg[j] <= 0;
            end
        
            if (start) begin
                state <= S_STEP1;
                done <= 0;
            end 
            else if (en) begin 
                // increment per-state counter every active cycle
                state_cycles[state] <= state_cycles[state] + 1;

                // Prepare registered PE inputs at the beginning of the step
                case(state)
                    S_STEP1: begin
                        for (j=0; j<16; j=j+1) begin
                            pe_in_a_vec_r[j*`DATA_WIDTH +: `DATA_WIDTH] <= delta_val;
                            pe_in_b_vec_r[j*`DATA_WIDTH +: `DATA_WIDTH] <= A_in[j];
                        end
                        state <= S_STEP2;
                    end
                    S_STEP2: begin
                        $display("SCAN_DBG S_STEP2 time=%0t B_vec(before_reg)=%h", $time, B_vec);
                        for(j=0; j<16; j=j+1) begin
                            pe_in_a_vec_r[j*`DATA_WIDTH +: `DATA_WIDTH] <= delta_val;
                            pe_in_b_vec_r[j*`DATA_WIDTH +: `DATA_WIDTH] <= B_in[j];
                        end
                        // Match baseline timing: sample exp_in_reg from current raw PE outputs here
                        for(j=0; j<16; j=j+1) begin
                            exp_in_reg[j] <= pe_result_vec[j*16 +: 16];
                        end
                        // Per-lane instrumentation to mirror baseline sampling point
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_EXP_IN_PIPE lane=%0d exp_in_reg=%04h", j, exp_in_reg[j]);
                        end
                        state <= S_STEP2W;
                    end
                    S_STEP2W: begin
                        // allow two extra cycles for the registered PE outputs to capture raw PE results
                        if (step2w_cnt < 2) begin
                            step2w_cnt <= step2w_cnt + 1;
                            $display("PE_DBG S_STEP2W wait%0d time=%0t pe_result_vec_raw=%h pe_result_vec_r=%h pe_in_a_vec_r=%h pe_in_b_vec_r=%h", step2w_cnt, $time, pe_result_vec, pe_result_vec_r, pe_in_a_vec_r, pe_in_b_vec_r);
                            state <= S_STEP2W;
                        end else begin
                            $display("PE_DBG S_STEP2W time=%0t pe_result_vec_raw=%h pe_result_vec_r=%h pe_in_a_vec_r=%h pe_in_b_vec_r=%h", $time, pe_result_vec, pe_result_vec_r, pe_in_a_vec_r, pe_in_b_vec_r);
                            // Per-lane raw vs registered comparison for debug
                            for (j = 0; j < 16; j = j + 1) begin
                                $display("INSTR_PE_REG_PIPE lane=%0d pe_result_raw=%04h pe_result_r=%04h pe_in_a_r=%04h pe_in_b_r=%04h", j,
                                         pe_result_vec[j*16 +: 16], pe_result_vec_r[j*16 +: 16], pe_in_a_vec_r[j*16 +: 16], pe_in_b_vec_r[j*16 +: 16]);
                            end
                            $display("INSTR_S_STEP2W: observed_pe_result_registered[0]=%04h", pe_result_vec_r[0*16 +: 16]);
                            step2w_cnt <= 0;
                            state <= S_STEP3;
                        end
                    end
                    S_STEP3: begin
                        // Sampling was moved earlier (S_STEP2) to match baseline; no overwrite here
                        $display("INSTR_S_STEP3: enter (no sample) sampled_pe_result_r[0]=%04h", pe_result_vec_r[0*16 +: 16]);
                        step3w_extra <= 0;
                        state <= S_STEP3W;
                    end
                    S_STEP3W: begin
                        // allow multiple extra cycles to wait for registered PE results to settle
                        if (step3w_cnt < 2) begin
                            step3w_cnt <= step3w_cnt + 1;
                            $display("PE_DBG S_STEP3W wait%0d time=%0t pe_result_vec_r=%h", step3w_cnt, $time, pe_result_vec_r);
                            state <= S_STEP3W;
                        end else begin
                            // Now that pe_result_vec_r holds the valid Delta*B results, capture them
                            for(j=0; j<16; j=j+1) begin
                                // store Delta*B from the registered PE outputs (temporal alignment)
                                deltaB_stored[j] <= pe_result_vec_r[j*16 +: 16];
                                // also capture deltaBx_stored here to ensure we use the registered result
                                deltaBx_stored[j] <= pe_result_vec_r[j*16 +: 16];
                                // start the (DeltaB * x) PE by loading registered inputs
                                pe_in_a_vec_r[j*`DATA_WIDTH +: `DATA_WIDTH] <= pe_result_vec_r[j*16 +: `DATA_WIDTH];
                                pe_in_b_vec_r[j*`DATA_WIDTH +: `DATA_WIDTH] <= x_val;
                            end
                            $display("PE_DBG S_STEP3W time=%0t pe_result_vec_r=%h", $time, pe_result_vec_r);
                            // Now print the exp_in_reg values that were assigned in S_STEP3
                            for (j = 0; j < 16; j = j + 1) begin
                                $display("INSTR_EXP_IN_PIPE lane=%0d exp_in_reg=%04h", j, exp_in_reg[j]);
                            end
                            step3w_cnt <= 0;
                            state <= S_STEP4;
                        end
                    end
                    S_STEP4: begin
                        for(j=0; j<16; j=j+1) begin
                            discA_stored[j] <= exp_out[j];
                        end
                        // Per-lane instrumentation: show exp_out values used to fill discA_stored
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_EXP_OUT_PIPE lane=%0d exp_out=%04h discA_stored(next)=%04h", j, exp_out[j], exp_out[j]);
                        end
                            state <= S_STEP5;
                    end
                        S_STEP5: begin
                            // after S_STEP4 assignments, print stored values for diagnosis
                            $display("INSTR_S_STEP5: discA_stored[0]=%04h (%0d) deltaBx_stored[0]=%04h (%0d) exp_out[0]=%04h (%0d)",
                                     discA_stored[0], $signed(discA_stored[0]), deltaBx_stored[0], $signed(deltaBx_stored[0]), exp_out[0], $signed(exp_out[0]));
                            state <= S_STEP5W;
                        end
                    S_STEP5: begin
                        state <= S_STEP5W;
                    end
                    S_STEP5W: begin
                        for(j=0; j<16; j=j+1) begin
                            h_new_temp[j] <= pe_result_vec[j*16 +: 16];
                        end
                        $display("PE_DBG S_STEP5W time=%0t pe_result_vec=%h pe_in_a_vec_r=%h pe_in_b_vec_r=%h", $time, pe_result_vec_r, pe_in_a_vec_r, pe_in_b_vec_r);
                        state <= S_STEP6;
                    end
                    S_STEP6: begin
                        for(j=0; j<16; j=j+1) begin
                            h_reg[j] <= h_new_temp[j];
                        end
                        state <= S_STEP6W;
                    end
                    S_STEP6W: state <= S_STEP6WW;
                    S_STEP6WW: state <= S_STEP7;
                    S_STEP7: begin
                        sum_stage1_0 <= $signed(pe_result_vec_r[0*16 +: 16]) + $signed(pe_result_vec_r[1*16 +: 16]) +
                                        $signed(pe_result_vec_r[2*16 +: 16]) + $signed(pe_result_vec_r[3*16 +: 16]);
                        sum_stage1_1 <= $signed(pe_result_vec_r[4*16 +: 16]) + $signed(pe_result_vec_r[5*16 +: 16]) +
                                        $signed(pe_result_vec_r[6*16 +: 16]) + $signed(pe_result_vec_r[7*16 +: 16]);
                        sum_stage1_2 <= $signed(pe_result_vec_r[8*16 +: 16]) + $signed(pe_result_vec_r[9*16 +: 16]) +
                                        $signed(pe_result_vec_r[10*16 +: 16]) + $signed(pe_result_vec_r[11*16 +: 16]);
                        sum_stage1_3 <= $signed(pe_result_vec_r[12*16 +: 16]) + $signed(pe_result_vec_r[13*16 +: 16]) +
                                        $signed(pe_result_vec_r[14*16 +: 16]) + $signed(pe_result_vec_r[15*16 +: 16]);
                        state <= S_STEP8;
                    end
                    S_STEP8: begin
                        sum_stage2_0 <= sum_stage1_0 + sum_stage1_1;
                        sum_stage2_1 <= sum_stage1_2 + sum_stage1_3;
                        state <= S_STEP9;
                    end
                    S_STEP9: begin
                        sum_stage3 <= $signed(sum_stage2_0) + $signed(sum_stage2_1);
                        Dx_prod <= $signed(x_val) * $signed(D_val);
                        y_with_D <= ($signed(sum_stage2_0) + $signed(sum_stage2_1)) +
                                    (($signed(x_val) * $signed(D_val)) >>> `FRAC_BITS);
                        state <= S_STEP10;
                    end
                    S_STEP10: begin
                        y_final_raw <= gated_raw_comb;
                        if (gated_raw_comb > 32767) y_out <= 32767;
                        else if (gated_raw_comb < -32768) y_out <= -32768;
                        else y_out <= gated_raw_comb[15:0];
                        done <= 1;
                        state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end

            if (done && !start) done <= 0; 
        end
    end

    // Debug instrumentation: state transitions and start/done edges
    always @(posedge clk) begin
        if (reset) begin
            prev_state <= S_IDLE;
            prev_start_r <= 1'b0;
            prev_done_r <= 1'b0;
        end else begin
            if (state != prev_state) $display("SCAN: state %0d -> %0d time=%0t", prev_state, state, $time);
            if (!prev_start_r && start) $display("SCAN: start asserted time=%0t", $time);
            if (!prev_done_r && done) begin
                $display("SCAN: done asserted time=%0t", $time);
                $display("SCAN_STATS: per-state cycles (module-local)");
                for (j=0; j<16; j=j+1) $display("SCAN_STATS: state %0d cycles=%0d", j, state_cycles[j]);
                // Additional instrumentation dump to help trace mismatches
                $display("INSTR_DUMP: pe_result_vec_r=%h", pe_result_vec_r);
                $display("INSTR_DUMP: sum_stage1 = %0d %0d %0d %0d", sum_stage1_0, sum_stage1_1, sum_stage1_2, sum_stage1_3);
                $display("INSTR_DUMP: sum_stage2 = %0d %0d", sum_stage2_0, sum_stage2_1);
                $display("INSTR_DUMP: sum_stage3 = %0d", sum_stage3);
                $display("INSTR_DUMP: Dx_prod=%0d y_with_D=%0d gated_raw_comb=%h y_final_raw=%0d y_out=%h", Dx_prod, y_with_D, gated_raw_comb, y_final_raw, y_out);
                // Print per-PE results and selected internal regs for diagnosis
                for (j = 0; j < 16; j = j + 1) begin
                    $display("INSTR_PE[%0d]: pe_result=%04h (%0d) exp_out=%04h (%0d) h_new_temp=%04h (%0d) h_reg=%04h (%0d)", j,
                             pe_result_vec_r[j*16 +: 16], $signed(pe_result_vec_r[j*16 +: 16]),
                             exp_out[j], $signed(exp_out[j]),
                             h_new_temp[j], $signed(h_new_temp[j]),
                             h_reg[j], $signed(h_reg[j]));
                end
            end

            prev_state <= state;
            prev_start_r <= start;
            prev_done_r <= done;
        end
    end

    // Combinational Logic (use registered inputs)
    always @(*) begin
        pe_op_mode_out   = `MODE_MUL;
        pe_clear_acc_out = 0;
        pe_in_a_vec      = pe_in_a_vec_r;
        pe_in_b_vec      = pe_in_b_vec_r;

        case(state)
            S_STEP1: begin 
                pe_op_mode_out = `MODE_MUL;
            end

            S_STEP2, S_STEP2W: begin 
                pe_op_mode_out = `MODE_MUL;
            end

            S_STEP3, S_STEP3W: begin
                pe_op_mode_out = `MODE_MUL;
            end

            S_STEP4: begin 
                pe_op_mode_out = `MODE_MUL;
            end

            S_STEP5, S_STEP5W: begin 
                pe_op_mode_out = `MODE_ADD;
            end

            S_STEP6, S_STEP6W: begin 
                pe_op_mode_out = `MODE_MUL;
            end
            
            S_STEP7, S_STEP8, S_STEP9, S_STEP10: begin
                pe_clear_acc_out = 0;
            end
        endcase
    end 
        
endmodule
