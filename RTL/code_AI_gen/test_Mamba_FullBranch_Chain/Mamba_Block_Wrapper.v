`timescale 1ns/1ps

module Mamba_Block_Wrapper #(
    parameter DATA_WIDTH = 16,
    parameter D_MODEL    = 64,
    parameter D_INNER    = 128,
    parameter D_STATE    = 16
) (
    input  wire                              clk,
    input  wire                              reset,

    input  wire                              rms_start,
    input  wire                              rms_en,
    input  wire                              inproj_start,
    input  wire                              inproj_en,
    input  wire                              conv_start,
    input  wire                              conv_en,
    input  wire                              conv_valid_in,
    input  wire                              scan_start,
    input  wire                              scan_en,
    input  wire                              scan_clear_h,
    input  wire                              outproj_start,
    input  wire                              outproj_en,

    input  wire [D_MODEL*DATA_WIDTH-1:0]     x_vec_packed,
    input  wire [D_MODEL*DATA_WIDTH-1:0]     gamma_packed,
    input  wire [D_INNER*D_MODEL*DATA_WIDTH-1:0] inproj_w_packed,
    input  wire [D_INNER*4*DATA_WIDTH-1:0]   conv_w_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     conv_b_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     delta_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     gate_packed,
    input  wire [D_STATE*DATA_WIDTH-1:0]     B_packed,
    input  wire [D_STATE*DATA_WIDTH-1:0]     C_packed,
    input  wire [D_INNER*D_STATE*DATA_WIDTH-1:0] A_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     D_packed,
    input  wire [D_MODEL*D_INNER*DATA_WIDTH-1:0] outproj_w_packed,

    output wire                              rms_done,
    output wire                              inproj_done,
    output wire                              all_conv_valid,
    output wire                              all_scan_done,
    output wire                              outproj_done,

    output wire [D_MODEL*DATA_WIDTH-1:0]     rms_out_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     inproj_out_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     x_activated_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     y_scan_packed,
    output wire [D_MODEL*DATA_WIDTH-1:0]     final_out_packed,

    output wire [D_INNER*4-1:0]              scan_state_dbg_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     scan_discA0_dbg_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     scan_deltaB0_dbg_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     scan_deltaBx0_dbg_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     scan_hnew0_dbg_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     scan_h0_dbg_packed,
    output wire [D_INNER*32-1:0]             scan_ywithd_dbg_packed,
    output wire [D_INNER*32-1:0]             scan_yfinal_dbg_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     scan_gateact_dbg_packed
);

    localparam CONV_GROUPS = D_INNER / 16;

    wire [CONV_GROUPS-1:0] conv_valid_out_vec;
    wire [CONV_GROUPS-1:0] conv_ready_in_vec;

    wire [1:0] conv_pe_op_mode [0:CONV_GROUPS-1];
    wire conv_pe_clear [0:CONV_GROUPS-1];
    wire [16*DATA_WIDTH-1:0] conv_pe_in_a [0:CONV_GROUPS-1];
    wire [16*DATA_WIDTH-1:0] conv_pe_in_b [0:CONV_GROUPS-1];
    wire [16*DATA_WIDTH-1:0] conv_pe_out  [0:CONV_GROUPS-1];

    wire [D_INNER*DATA_WIDTH-1:0] x_activated_raw_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] x_activated_latched;

    wire [D_INNER-1:0] scan_done_vec;
    wire [1:0] scan_pe_op_mode [0:D_INNER-1];
    wire scan_pe_clear [0:D_INNER-1];
    wire [D_STATE*DATA_WIDTH-1:0] scan_pe_in_a [0:D_INNER-1];
    wire [D_STATE*DATA_WIDTH-1:0] scan_pe_in_b [0:D_INNER-1];
    wire [D_STATE*DATA_WIDTH-1:0] scan_pe_out  [0:D_INNER-1];

    assign all_conv_valid = &conv_valid_out_vec;
    assign all_scan_done  = &scan_done_vec;
    assign x_activated_packed = x_activated_latched;

    always @(posedge clk) begin
        if (reset) begin
            x_activated_latched <= {D_INNER*DATA_WIDTH{1'b0}};
        end else if (all_conv_valid) begin
            x_activated_latched <= x_activated_raw_packed;
        end
    end

    RMSNorm_Unit_IntSqrt u_rmsnorm (
        .clk(clk),
        .reset(reset),
        .start(rms_start),
        .en(rms_en),
        .done(rms_done),
        .x_vec(x_vec_packed),
        .gamma_vec(gamma_packed),
        .y_vec(rms_out_packed)
    );

    In_Projection_Unit u_inproj (
        .clk(clk),
        .reset(reset),
        .start(inproj_start),
        .en(inproj_en),
        .done(inproj_done),
        .x_vec(rms_out_packed),
        .w_matrix(inproj_w_packed),
        .y_vec(inproj_out_packed)
    );

    genvar cg;
    generate
        for (cg = 0; cg < CONV_GROUPS; cg = cg + 1) begin : G_CONV
            wire [16*DATA_WIDTH-1:0] conv_x_in_vec;
            wire [16*DATA_WIDTH-1:0] conv_y_out_vec;

            assign conv_x_in_vec = inproj_out_packed[cg*16*DATA_WIDTH +: 16*DATA_WIDTH];
            assign x_activated_raw_packed[cg*16*DATA_WIDTH +: 16*DATA_WIDTH] = conv_y_out_vec;

            Conv1D_Layer u_conv (
                .clk(clk),
                .reset(reset),
                .start(conv_start),
                .en(conv_en),
                .valid_in(conv_valid_in),
                .valid_out(conv_valid_out_vec[cg]),
                .ready_in(conv_ready_in_vec[cg]),
                .x_in_vec(conv_x_in_vec),
                .weights_vec(conv_w_packed[cg*16*4*DATA_WIDTH +: 16*4*DATA_WIDTH]),
                .bias_vec(conv_b_packed[cg*16*DATA_WIDTH +: 16*DATA_WIDTH]),
                .y_out_vec(conv_y_out_vec),
                .pe_op_mode_out(conv_pe_op_mode[cg]),
                .pe_clear_out(conv_pe_clear[cg]),
                .pe_in_a_vec(conv_pe_in_a[cg]),
                .pe_in_b_vec(conv_pe_in_b[cg]),
                .pe_result_vec(conv_pe_out[cg])
            );

            genvar cp;
            for (cp = 0; cp < 16; cp = cp + 1) begin : G_CONV_PE
                Unified_PE u_pe (
                    .clk(clk),
                    .reset(reset),
                    .op_mode(conv_pe_op_mode[cg]),
                    .clear_acc(conv_pe_clear[cg]),
                    .in_A(conv_pe_in_a[cg][cp*DATA_WIDTH +: DATA_WIDTH]),
                    .in_B(conv_pe_in_b[cg][cp*DATA_WIDTH +: DATA_WIDTH]),
                    .out_val(conv_pe_out[cg][cp*DATA_WIDTH +: DATA_WIDTH])
                );
            end
        end
    endgenerate

    genvar ch;
    generate
        for (ch = 0; ch < D_INNER; ch = ch + 1) begin : G_SCAN_CH
            wire signed [DATA_WIDTH-1:0] delta_ch = delta_packed[ch*DATA_WIDTH +: DATA_WIDTH];
            wire signed [DATA_WIDTH-1:0] x_ch     = x_activated_latched[ch*DATA_WIDTH +: DATA_WIDTH];
            wire signed [DATA_WIDTH-1:0] D_ch     = D_packed[ch*DATA_WIDTH +: DATA_WIDTH];
            wire signed [DATA_WIDTH-1:0] gate_ch  = gate_packed[ch*DATA_WIDTH +: DATA_WIDTH];
            wire signed [D_STATE*DATA_WIDTH-1:0] A_ch = A_packed[ch*D_STATE*DATA_WIDTH +: D_STATE*DATA_WIDTH];

            Scan_Core_Engine u_scan (
                .clk(clk),
                .reset(reset),
                .start(scan_start),
                .en(scan_en),
                .clear_h(scan_clear_h),
                .done(scan_done_vec[ch]),
                .delta_val(delta_ch),
                .x_val(x_ch),
                .D_val(D_ch),
                .gate_val(gate_ch),
                .A_vec(A_ch),
                .B_vec(B_packed),
                .C_vec(C_packed),
                .y_out(y_scan_packed[ch*DATA_WIDTH +: DATA_WIDTH]),
                .pe_op_mode_out(scan_pe_op_mode[ch]),
                .pe_clear_acc_out(scan_pe_clear[ch]),
                .pe_in_a_vec(scan_pe_in_a[ch]),
                .pe_in_b_vec(scan_pe_in_b[ch]),
                .pe_result_vec(scan_pe_out[ch])
            );

            assign scan_state_dbg_packed[ch*4 +: 4] = G_SCAN_CH[ch].u_scan.state;
            assign scan_discA0_dbg_packed[ch*DATA_WIDTH +: DATA_WIDTH] = G_SCAN_CH[ch].u_scan.discA_stored[0];
            assign scan_deltaB0_dbg_packed[ch*DATA_WIDTH +: DATA_WIDTH] = G_SCAN_CH[ch].u_scan.deltaB_stored[0];
            assign scan_deltaBx0_dbg_packed[ch*DATA_WIDTH +: DATA_WIDTH] = G_SCAN_CH[ch].u_scan.deltaBx_stored[0];
            assign scan_hnew0_dbg_packed[ch*DATA_WIDTH +: DATA_WIDTH] = G_SCAN_CH[ch].u_scan.h_new_temp[0];
            assign scan_h0_dbg_packed[ch*DATA_WIDTH +: DATA_WIDTH] = G_SCAN_CH[ch].u_scan.h_reg[0];
            assign scan_ywithd_dbg_packed[ch*32 +: 32] = G_SCAN_CH[ch].u_scan.y_with_D;
            assign scan_yfinal_dbg_packed[ch*32 +: 32] = G_SCAN_CH[ch].u_scan.y_final_raw;
            assign scan_gateact_dbg_packed[ch*DATA_WIDTH +: DATA_WIDTH] = G_SCAN_CH[ch].u_scan.silu_out;

            genvar p;
            for (p = 0; p < D_STATE; p = p + 1) begin : G_SCAN_PE
                Unified_PE u_pe (
                    .clk(clk),
                    .reset(reset),
                    .op_mode(scan_pe_op_mode[ch]),
                    .clear_acc(scan_pe_clear[ch]),
                    .in_A(scan_pe_in_a[ch][p*DATA_WIDTH +: DATA_WIDTH]),
                    .in_B(scan_pe_in_b[ch][p*DATA_WIDTH +: DATA_WIDTH]),
                    .out_val(scan_pe_out[ch][p*DATA_WIDTH +: DATA_WIDTH])
                );
            end
        end
    endgenerate

    Out_Projection_Unit u_outproj (
        .clk(clk),
        .reset(reset),
        .start(outproj_start),
        .en(outproj_en),
        .done(outproj_done),
        .x_vec(y_scan_packed),
        .w_matrix(outproj_w_packed),
        .y_vec(final_out_packed)
    );

endmodule
