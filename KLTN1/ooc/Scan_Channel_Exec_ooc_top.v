`timescale 1ns/1ps

// Single Scan_Channel_Exec OOC — fastest scan resource estimate (~3-8 min).
// Scale LUT/DSP by production NUM_EXEC=6 for full pipe estimate.
module Scan_Channel_Exec_ooc_top (
    input  wire clk,
    input  wire signed [16*16-1:0] stim_vec,
    output wire done,
    output wire signed [16*16-1:0] h_new_flat,
    output wire signed [15:0] y_pre
);
    reg [7:0] tick;
    reg       start_r;
    reg       en_r;

    always @(posedge clk) begin
        tick    <= tick + 8'd1;
        start_r <= tick[0];
        en_r    <= 1'b1;
    end

    wire signed [16*16-1:0] h_prev = {stim_vec[15:0], {256-16{1'b0}}};

    wire [1:0] pe_op_mode;
    wire       pe_clear;
    wire signed [16*16-1:0] pe_a, pe_b, pe_r;

    Scan_Channel_Exec #(
        .DONE_HOLD_CYCLES(1)
    ) u_exec (
        .clk(clk),
        .reset(1'b0),
        .start(start_r),
        .en(en_r),
        .done(done),
        .delta_raw(stim_vec[15:0]),
        .x_val(stim_vec[31:16]),
        .D_val(16'sd0),
        .A_vec({256{1'b0}}),
        .B_vec(h_prev),
        .C_vec(h_prev),
        .h_prev_vec(h_prev),
        .y_pre_out(y_pre),
        .h_new_vec(h_new_flat),
        .pe_op_mode_out(pe_op_mode),
        .pe_clear_acc_out(pe_clear),
        .pe_in_a_vec(pe_a),
        .pe_in_b_vec(pe_b),
        .pe_result_vec(pe_r)
    );

    genvar gp;
    generate
        for (gp = 0; gp < 16; gp = gp + 1) begin : pe_gen
            Unified_PE u_pe (
                .clk(clk),
                .reset(1'b0),
                .op_mode(pe_op_mode),
                .clear_acc(pe_clear),
                .in_A(pe_a[gp*16 +: 16]),
                .in_B(pe_b[gp*16 +: 16]),
                .out_val(pe_r[gp*16 +: 16])
            );
        end
    endgenerate
endmodule
