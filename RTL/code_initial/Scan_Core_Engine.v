`include "_parameter.v"

module Scan_Core_Engine
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
    reg signed [31:0] y_final_raw;
    reg signed [31:0] sum_stage1_0, sum_stage1_1, sum_stage1_2, sum_stage1_3;
    reg signed [31:0] sum_stage2_0, sum_stage2_1;
    reg signed [31:0] sum_stage3;
    (* use_dsp = "yes" *) wire signed [31:0] gated_raw_mul = (y_with_D * silu_out);
    wire signed [31:0] gated_raw_comb = gated_raw_mul >>> `FRAC_BITS;

    // Unpack 
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : unpack
            assign A_in[i] = A_vec[i*`DATA_WIDTH +: `DATA_WIDTH];
            assign B_in[i] = B_vec[i*`DATA_WIDTH +: `DATA_WIDTH];
            assign C_in[i] = C_vec[i*`DATA_WIDTH +: `DATA_WIDTH];
            
            // Wiring Exp Unit
            // Exp Unit lay input tu ket qua PE tra ve (khi tinh xong Delta * A)
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
    localparam S_STEP3 = 3; // Calc (DeltaB) * x
    localparam S_STEP4 = 4; // Calc discA * h_old
    localparam S_STEP5 = 5; // Calc h_new = ... + ...
    localparam S_STEP6 = 6; // Calc C * h_new
    localparam S_STEP7 = 7;  // Reduce stage 1
    localparam S_STEP8 = 8;  // Reduce stage 2
    localparam S_STEP9 = 9;  // Residual add
    localparam S_STEP10 = 10; // Gate mul + saturate output

    integer j;

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
            for(j=0; j<16; j=j+1) begin
                h_reg[j] <= 0;
                discA_stored[j] <= 0;
                deltaBx_stored[j] <= 0;
                exp_in_reg[j] <= 0;
            end
        end else begin
            if (clear_h) begin
                for(j=0; j<16; j=j+1) h_reg[j] <= 0;
            end
        
            if (start) begin
                state <= S_STEP1;
                done <= 0;
            end 
            else if (en) begin 
                case(state)
                    
                    S_STEP1: state <= S_STEP2;
                    
                    S_STEP2: begin
                        // Register PE output before feeding Exp unit to shorten PE->Exp path
                        for(j=0; j<16; j=j+1) exp_in_reg[j] <= pe_result_vec[j*16 +: 16];
                        state <= S_STEP3;
                    end
                    
                    S_STEP3: begin
                        state <= S_STEP4;
                    end
                    
                    S_STEP4: begin
                        for(j=0; j<16; j=j+1) begin
                            discA_stored[j] <= exp_out[j];
                            deltaBx_stored[j] <= pe_result_vec[j*16 +: 16];
                        end
                        state <= S_STEP5;
                    end
                    
                    S_STEP5: state <= S_STEP6;
                    
                    S_STEP6: begin
                        for(j=0; j<16; j=j+1) h_reg[j] <= pe_result_vec[j*16 +: 16];
                        state <= S_STEP7;
                    end

                    S_STEP7: begin
                        // Balanced reduction tree - stage 1 (16 -> 4 partial sums)
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
                        // Reduction stage 2 (4 -> 2)
                        sum_stage2_0 <= sum_stage1_0 + sum_stage1_1;
                        sum_stage2_1 <= sum_stage1_2 + sum_stage1_3;
                        state <= S_STEP9;
                    end

                    S_STEP9: begin
                        // Reduction stage 3 + residual add
                        sum_stage3 <= sum_stage2_0 + sum_stage2_1;
                        Dx_prod <= x_val * D_val;
                        y_with_D <= (sum_stage2_0 + sum_stage2_1) + ((x_val * D_val) >>> `FRAC_BITS);
                        state <= S_STEP10;
                    end

                    S_STEP10: begin
                        // Final gate and saturation
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

    // Combinational Logic
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

            S_STEP2: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = delta_val;
                    pe_in_b_vec[j*16 +: 16] = B_in[j];
                end
            end

            S_STEP3: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = pe_result_vec[j*16 +: 16]; 
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

            S_STEP5: begin 
                pe_op_mode_out = `MODE_ADD;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = pe_result_vec[j*16 +: 16];
                    pe_in_b_vec[j*16 +: 16] = deltaBx_stored[j];
                end
            end

            S_STEP6: begin 
                pe_op_mode_out = `MODE_MUL;
                for(j=0; j<16; j=j+1) begin
                    pe_in_a_vec[j*16 +: 16] = pe_result_vec[j*16 +: 16];
                    pe_in_b_vec[j*16 +: 16] = C_in[j];
                end
            end
            
            S_STEP7, S_STEP8, S_STEP9, S_STEP10: begin
                pe_clear_acc_out = 0;
            end
        endcase
    end 
        


endmodule
