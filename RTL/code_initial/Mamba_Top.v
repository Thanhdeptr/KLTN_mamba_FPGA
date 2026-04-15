`include "_parameter.v"

module Mamba_Top
(
    input clk,
    input reset,
    
    // --- BO CHON CHE DO ---
    // 0: Idle , 1: Linear, 2: Conv, 3: Scan, 4: Softplus, 5: ITM Block (Inception + Mamba merge)
    input [2:0] mode_select, 

    // ============================================================
    // 1. LINEAR
    // ============================================================
    input lin_start,
    input lin_en,
    input [15:0] lin_len,
    output lin_done,
    input signed [`DATA_WIDTH-1:0] lin_x_val,
    input signed [16 * `DATA_WIDTH - 1 : 0] lin_W_vals,
    input signed [16 * `DATA_WIDTH - 1 : 0] lin_bias_vals,
    output signed [16 * `DATA_WIDTH - 1 : 0] lin_y_out,

    // ============================================================
    // 2. CONV1D
    // ============================================================
    input conv_start,
    input conv_valid_in,
    input conv_en,
    output conv_valid_out,
    output conv_ready_in,
    
    input signed [16 * `DATA_WIDTH - 1 : 0] conv_x_vec,
    input signed [16 * 4 * `DATA_WIDTH - 1 : 0] conv_w_vec, // 4 tap (kernel = 4)
    input signed [16 * `DATA_WIDTH - 1 : 0] conv_b_vec,
    output signed [16 * `DATA_WIDTH - 1 : 0] conv_y_vec,

    // ============================================================
    // 3. SCAN CORE
    // ============================================================
    input scan_start,
    input scan_en,
    input scan_clear_h,
    output scan_done,
    input signed [`DATA_WIDTH-1:0] scan_delta_val, scan_x_val, scan_D_val, scan_gate_val,
    input signed [16 * `DATA_WIDTH - 1 : 0] scan_A_vec, scan_B_vec, scan_C_vec,
    output signed [`DATA_WIDTH-1:0] scan_y_out,
    
    // ============================================================
    // 4. SOFTPLUS 
    // ============================================================
    input  signed [`DATA_WIDTH-1:0] softplus_in_val,
    output signed [`DATA_WIDTH-1:0] softplus_out_val,

    // ============================================================
    // 5. ITM BLOCK (Level-B: Conv pathway + Scan pathway + ReLU add)
    // ============================================================
    input itm_start,
    input itm_en,
    output itm_done,
    output itm_valid_out,
    output signed [16 * `DATA_WIDTH - 1 : 0] itm_out_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] itm_feat_vec,
    input signed [16 * 4 * `DATA_WIDTH - 1 : 0] itm_conv_w_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] itm_conv_b_vec,
    input signed [`DATA_WIDTH-1:0] itm_scan_delta_val,
    input signed [`DATA_WIDTH-1:0] itm_scan_x_val,
    input signed [`DATA_WIDTH-1:0] itm_scan_D_val,
    input signed [`DATA_WIDTH-1:0] itm_scan_gate_val,
    input signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_A_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_B_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_C_vec,
    input itm_scan_clear_h
);

    // --- Internal buses ---
    wire [255:0] pe_result_common;

    // Linear
    wire [1:0] lin_pe_op; wire lin_pe_clr;
    wire [255:0] lin_pe_in_a, lin_pe_in_b;

    // Scan
    wire [1:0] scan_pe_op; wire scan_pe_clr;
    wire [255:0] scan_pe_in_a, scan_pe_in_b;
    
    // Conv 
    wire [1:0] conv_pe_op; wire conv_pe_clr;
    wire [255:0] conv_pe_in_a, conv_pe_in_b;

    // ITM Block
    wire [1:0] itm_pe_op; wire itm_pe_clr;
    wire [255:0] itm_pe_in_a, itm_pe_in_b;

    // MUX (combinational select)
    reg [1:0] mux_pe_op;
    reg       mux_pe_clr;
    reg [255:0] mux_pe_in_a, mux_pe_in_b;

    // Direct PE bus selection keeps the critical path local to each submodule.
    wire [1:0] pe_op_bus   = mux_pe_op;
    wire       pe_clr_bus   = mux_pe_clr;
    wire [255:0] pe_in_a_bus = mux_pe_in_a;
    wire [255:0] pe_in_b_bus = mux_pe_in_b;


    (* keep_hierarchy = "yes" *) Linear_Layer u_linear (
        .clk(clk), .reset(reset),
        .start(lin_start), .len(lin_len), .en(lin_en), .done(lin_done),
        .x_val(lin_x_val), .W_row_vals(lin_W_vals), .bias_vals(lin_bias_vals), .y_out(lin_y_out),
        // PE
        .pe_op_mode_out(lin_pe_op), .pe_clear_acc_out(lin_pe_clr),
        .pe_in_a_vec(lin_pe_in_a), .pe_in_b_vec(lin_pe_in_b), .pe_result_vec(pe_result_common)
    );

    (* keep_hierarchy = "yes" *) Scan_Core_Engine u_scan (
        .clk(clk), .reset(reset),
        .start(scan_start), .en(scan_en), .clear_h(scan_clear_h), .done(scan_done),
        .delta_val(scan_delta_val), .x_val(scan_x_val), .D_val(scan_D_val), .gate_val(scan_gate_val),
        .A_vec(scan_A_vec), .B_vec(scan_B_vec), .C_vec(scan_C_vec), .y_out(scan_y_out),
        // PE
        .pe_op_mode_out(scan_pe_op), .pe_clear_acc_out(scan_pe_clr),
        .pe_in_a_vec(scan_pe_in_a), .pe_in_b_vec(scan_pe_in_b), .pe_result_vec(pe_result_common)
    );
    
    (* keep_hierarchy = "yes" *) Conv1D_Layer u_conv (
        .clk(clk), .reset(reset),
        .start(conv_start), .en(conv_en),
        .valid_in(conv_valid_in), .valid_out(conv_valid_out), .ready_in(conv_ready_in),
        .x_in_vec(conv_x_vec), .weights_vec(conv_w_vec), .bias_vec(conv_b_vec), .y_out_vec(conv_y_vec),
        // PE
        .pe_op_mode_out(conv_pe_op), .pe_clear_out(conv_pe_clr),
        .pe_in_a_vec(conv_pe_in_a), .pe_in_b_vec(conv_pe_in_b), .pe_result_vec(pe_result_common)
    );
    
    Softplus_Unit_PWL u_softplus (
        .clk(clk),
        .in_data(softplus_in_val),
        .out_data(softplus_out_val)
    );

    (* keep_hierarchy = "yes" *) ITM_Block u_itm (
        .clk(clk),
        .reset(reset),
        .itm_start(itm_start),
        .itm_en(itm_en),
        .itm_done(itm_done),
        .itm_valid_out(itm_valid_out),
        .itm_out_vec(itm_out_vec),
        .feat_in_vec(itm_feat_vec),
        .conv_w_vec(itm_conv_w_vec),
        .conv_b_vec(itm_conv_b_vec),
        .scan_delta_val(itm_scan_delta_val),
        .scan_x_val(itm_scan_x_val),
        .scan_D_val(itm_scan_D_val),
        .scan_gate_val(itm_scan_gate_val),
        .scan_A_vec(itm_scan_A_vec),
        .scan_B_vec(itm_scan_B_vec),
        .scan_C_vec(itm_scan_C_vec),
        .scan_clear_h(itm_scan_clear_h),
        .pe_op_mode_out(itm_pe_op),
        .pe_clear_out(itm_pe_clr),
        .pe_in_a_vec(itm_pe_in_a),
        .pe_in_b_vec(itm_pe_in_b),
        .pe_result_vec(pe_result_common)
    );

    // LOGIC MUX 
    always @(*) begin
        case (mode_select)
            3'd1: begin // LINEAR
                mux_pe_op = lin_pe_op; mux_pe_clr = lin_pe_clr;
                mux_pe_in_a = lin_pe_in_a; mux_pe_in_b = lin_pe_in_b;
            end
            
            3'd2: begin // CONV
                mux_pe_op = conv_pe_op; mux_pe_clr = conv_pe_clr;
                mux_pe_in_a = conv_pe_in_a; mux_pe_in_b = conv_pe_in_b;
            end

            3'd3: begin // SCAN
                mux_pe_op = scan_pe_op; mux_pe_clr = scan_pe_clr;
                mux_pe_in_a = scan_pe_in_a; mux_pe_in_b = scan_pe_in_b;
            end

            3'd5: begin // ITM Block (time-multiplexed Conv then Scan inside ITM_Block)
                mux_pe_op = itm_pe_op; mux_pe_clr = itm_pe_clr;
                mux_pe_in_a = itm_pe_in_a; mux_pe_in_b = itm_pe_in_b;
            end

            default: begin // IDLE
                mux_pe_op = 0; mux_pe_clr = 1; mux_pe_in_a = 0; mux_pe_in_b = 0;
            end
        endcase
    end

    // 16 PE
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : pe_array
            Unified_PE u_pe (
                .clk(clk), .reset(reset),
                .op_mode(pe_op_bus), .clear_acc(pe_clr_bus),
                .in_A(pe_in_a_bus[i*16 +: 16]), .in_B(pe_in_b_bus[i*16 +: 16]),
                .out_val(pe_result_common[i*16 +: 16])
            );
        end
    endgenerate

endmodule
