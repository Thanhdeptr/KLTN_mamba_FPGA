`include "../../code_initial/_parameter.v"

module Scan_Core_Engine_baseline_instr
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

    // PE interface
    output reg [1:0] pe_op_mode_out,
    output reg       pe_clear_acc_out,

    output reg [16 * `DATA_WIDTH - 1 : 0] pe_in_a_vec,
    output reg [16 * `DATA_WIDTH - 1 : 0] pe_in_b_vec,

    input wire [16 * `DATA_WIDTH - 1 : 0] pe_result_vec
);

    // (body based on RTL/code_initial/Scan_Core_Engine.v but with same instrumentation prints
    // as used in the pipelined test so logs can be diffed)

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
    // register a local copy of PE results for instrumentation (match pipeline)
    reg [16 * `DATA_WIDTH - 1 : 0] pe_result_vec_r;
    
    // Residual + Gating pipeline
    (* use_dsp = "yes" *) reg signed [31:0] Dx_prod;
    reg signed [31:0] y_with_D;
    reg signed [63:0] y_final_raw;
    reg signed [31:0] sum_stage1_0, sum_stage1_1, sum_stage1_2, sum_stage1_3;
    reg signed [31:0] sum_stage2_0, sum_stage2_1;
    reg signed [31:0] sum_stage3;
    (* use_dsp = "yes" *) wire signed [63:0] gated_raw_mul = $signed(y_with_D) * $signed(silu_out);
    wire signed [63:0] gated_raw_comb = gated_raw_mul >>> `FRAC_BITS;

    // Registered PE inputs (none in baseline, but keep for similar interface)
    
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

    // FSM (copy of baseline states)
    reg [3:0] state;
    localparam S_IDLE  = 0;
    localparam S_STEP1 = 1;
    localparam S_STEP2 = 2;
    localparam S_STEP2W = 14;
    localparam S_STEP3 = 3;
    localparam S_STEP3W = 11;
    localparam S_STEP4 = 4;
    localparam S_STEP5 = 5;
    localparam S_STEP5W = 12;
    localparam S_STEP6 = 6;
    localparam S_STEP6W = 13;
    localparam S_STEP7 = 7;
    localparam S_STEP8 = 8;
    localparam S_STEP9 = 9;
    localparam S_STEP10 = 10;

    integer j;
    reg [3:0] prev_state;
    reg prev_start_r;
    reg prev_done_r;
    // Per-state cycle counters to match pipeline monitor output
    reg [31:0] state_cycles [0:15];

    // SEQUENTIAL LOGIC (behavior copied from baseline, with inserted $display points matching pipe1)
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
            for(j=0; j<16; j=j+1) begin
                h_reg[j] <= 0;
                h_new_temp[j] <= 0;
                deltaB_stored[j] <= 0;
                discA_stored[j] <= 0;
                deltaBx_stored[j] <= 0;
                exp_in_reg[j] <= 0;
            end
            pe_result_vec_r <= 0;
            for (j=0; j<16; j=j+1) state_cycles[j] <= 0;
        end else begin
            // register the raw PE outputs for comparison with pipelined variant
            pe_result_vec_r <= pe_result_vec;

            // Per-cycle logging to trace timing of PE outputs vs registered copy
            $display("CYCLE_LOG BASE time=%0t state=%0d pe_result_vec=%h pe_result_vec_r=%h exp_in_reg0=%04h", $time, state, pe_result_vec, pe_result_vec_r, exp_in_reg[0]);
            if (clear_h) begin
                for(j=0; j<16; j=j+1) h_reg[j] <= 0;
            end
            if (start) begin
                state <= S_STEP1;
                done <= 0;
            end else if (en) begin
                state_cycles[state] <= state_cycles[state] + 1;
                case(state)
                    S_STEP1: state <= S_STEP2;
                    S_STEP2: begin
                        // Register PE output before feeding Exp unit (baseline behavior)
                        for(j=0; j<16; j=j+1) begin
                            exp_in_reg[j] <= pe_result_vec[j*16 +: 16];
                        end
                        // Per-lane instrumentation: show exp_in_reg values assigned this cycle
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_EXP_IN_BASE lane=%0d exp_in_reg=%04h", j, exp_in_reg[j]);
                        end
                        $display("SCAN_DBG S_STEP2 time=%0t B_vec(before_reg)=%h", $time, B_vec);
                        state <= S_STEP2W;
                    end
                    S_STEP2W: begin
                        for(j=0; j<16; j=j+1) begin
                            deltaB_stored[j] <= pe_result_vec[j*16 +: 16];
                        end
                        $display("PE_DBG S_STEP2W time=%0t pe_result_vec_raw=%h pe_result_vec_r=%h", $time, pe_result_vec, pe_result_vec_r);
                        // Per-lane raw vs registered comparison for debug
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_PE_REG_BASE lane=%0d pe_result_raw=%04h pe_result_r=%04h", j, pe_result_vec[j*16 +: 16], pe_result_vec_r[j*16 +: 16]);
                        end
                        // Print exp_in_reg values here when they have taken effect
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_EXP_IN_BASE lane=%0d exp_in_reg=%04h", j, exp_in_reg[j]);
                        end
                        $display("INSTR_S_STEP2W: exp_in_reg[0]=%04h pe_result_vec_r[0]=%04h", exp_in_reg[0], pe_result_vec_r[0*16 +: 16]);
                        state <= S_STEP3;
                    end
                    S_STEP3: state <= S_STEP3W;
                    S_STEP3W: begin
                        $display("PE_DBG S_STEP3W time=%0t pe_result_vec_raw=%h pe_result_vec_r=%h", $time, pe_result_vec, pe_result_vec_r);
                        state <= S_STEP4;
                    end
                    S_STEP4: begin
                        for(j=0; j<16; j=j+1) begin
                            discA_stored[j] <= exp_out[j];
                            deltaBx_stored[j] <= pe_result_vec[j*16 +: 16];
                        end
                        // Per-lane instrumentation: show exp_out values used to fill discA_stored
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_EXP_OUT_BASE lane=%0d exp_out=%04h discA_stored(next)=%04h", j, exp_out[j], exp_out[j]);
                        end
                        state <= S_STEP5;
                    end
                    S_STEP5: begin
                        $display("INSTR_S_STEP5: discA_stored[0]=%04h (%0d) deltaBx_stored[0]=%04h (%0d) exp_out[0]=%04h (%0d)",
                                 discA_stored[0], $signed(discA_stored[0]), deltaBx_stored[0], $signed(deltaBx_stored[0]), exp_out[0], $signed(exp_out[0]));
                        state <= S_STEP5W;
                    end
                    S_STEP5W: begin
                        for(j=0; j<16; j=j+1) begin
                            h_new_temp[j] <= pe_result_vec[j*16 +: 16];
                        end
                        $display("PE_DBG S_STEP5W time=%0t pe_result_vec=%h", $time, pe_result_vec);
                        state <= S_STEP6;
                    end
                    S_STEP6: begin
                        for(j=0; j<16; j=j+1) begin
                            h_reg[j] <= h_new_temp[j];
                        end
                        state <= S_STEP6W;
                    end
                    S_STEP6W: state <= S_STEP7;
                    S_STEP7: begin
                        sum_stage1_0 <= $signed(pe_result_vec[0*16 +: 16]) + $signed(pe_result_vec[1*16 +: 16]) +
                                        $signed(pe_result_vec[2*16 +: 16]) + $signed(pe_result_vec[3*16 +: 16]);
                        sum_stage1_1 <= $signed(pe_result_vec[4*16 +: 16]) + $signed(pe_result_vec[5*16 +: 16]) +
                                        $signed(pe_result_vec[6*16 +: 16]) + $signed(pe_result_vec[7*16 +: 16]);
                        sum_stage1_2 <= $signed(pe_result_vec[8*16 +: 16]) + $signed(pe_result_vec[9*16 +: 16]) +
                                        $signed(pe_result_vec[10*16 +: 16]) + $signed(pe_result_vec[11*16 +: 16]);
                        sum_stage1_3 <= $signed(pe_result_vec[12*16 +: 16]) + $signed(pe_result_vec[13*16 +: 16]) +
                                        $signed(pe_result_vec[14*16 +: 16]) + $signed(pe_result_vec[15*16 +: 16]);
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
                        // Dump instrumentation at done to match pipelined log
                        $display("SCAN_STATS: per-state cycles (module-local)");
                        for (j=0; j<16; j=j+1) $display("SCAN_STATS: state %0d cycles=%0d", j, state_cycles[j]);
                        $display("INSTR_DUMP: pe_result_vec=%h", pe_result_vec);
                        $display("INSTR_DUMP: sum_stage1 = %0d %0d %0d %0d", sum_stage1_0, sum_stage1_1, sum_stage1_2, sum_stage1_3);
                        $display("INSTR_DUMP: sum_stage2 = %0d %0d", sum_stage2_0, sum_stage2_1);
                        $display("INSTR_DUMP: sum_stage3 = %0d", sum_stage3);
                        $display("INSTR_DUMP: Dx_prod=%0d y_with_D=%0d gated_raw_comb=%h y_final_raw=%0d y_out=%h", Dx_prod, y_with_D, gated_raw_comb, y_final_raw, y_out);
                        for (j = 0; j < 16; j = j + 1) begin
                            $display("INSTR_PE[%0d]: pe_result=%04h (%0d) exp_out=%04h (%0d) h_new_temp=%04h (%0d) h_reg=%04h (%0d)", j,
                                     pe_result_vec[j*16 +: 16], $signed(pe_result_vec[j*16 +: 16]),
                                     exp_out[j], $signed(exp_out[j]),
                                     h_new_temp[j], $signed(h_new_temp[j]),
                                     h_reg[j], $signed(h_reg[j]));
                        end
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
            if (!prev_done_r && done) $display("SCAN: done asserted time=%0t", $time);

            prev_state <= state;
            prev_start_r <= start;
            prev_done_r <= done;
        end
    end

    // Combinational Logic (baseline uses direct pe_in vectors)
    always @(*) begin
        pe_op_mode_out   = `MODE_MUL;
        pe_clear_acc_out = 0;
        pe_in_a_vec      = 0;
        pe_in_b_vec      = 0;

        case(state)
            S_STEP1: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = delta_val;
                    pe_in_b_vec[j*16 +: 16] = A_in[j];
                end
            end

            S_STEP2, S_STEP2W: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = delta_val;
                    pe_in_b_vec[j*16 +: 16] = B_in[j];
                end
            end

            S_STEP3, S_STEP3W: begin
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = deltaB_stored[j];
                    pe_in_b_vec[j*16 +: 16] = x_val;
                end
            end

            S_STEP4: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = exp_out[j];
                    pe_in_b_vec[j*16 +: 16] = h_reg[j];
                end
            end

            S_STEP5, S_STEP5W: begin 
                pe_op_mode_out = `MODE_ADD;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = pe_result_vec[j*16 +: 16];
                    pe_in_b_vec[j*16 +: 16] = deltaBx_stored[j];
                end
            end

            S_STEP6, S_STEP6W: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = h_new_temp[j];
                    pe_in_b_vec[j*16 +: 16] = C_in[j];
                end
            end
            S_STEP7, S_STEP8, S_STEP9, S_STEP10: begin
                pe_clear_acc_out = 0;
            end
        endcase
    end
endmodule
