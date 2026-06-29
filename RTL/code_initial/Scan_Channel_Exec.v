`include "_parameter.v"

// Per-channel scan wrapper around proven Scan_Core_Engine.
module Scan_Channel_Exec #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS  = 12,
    parameter D_STATE    = 16,
    parameter BYPASS_SOFTPLUS = 0,
    parameter DONE_HOLD_CYCLES = 0
) (
    input  wire clk,
    input  wire reset,
    input  wire start,
    input  wire en,
    output wire       done,

    input  wire signed [DATA_WIDTH-1:0] delta_raw,
    input  wire signed [DATA_WIDTH-1:0] x_val,
    input  wire signed [DATA_WIDTH-1:0] D_val,

    input  wire signed [D_STATE*DATA_WIDTH-1:0] A_vec,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] B_vec,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] C_vec,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] h_prev_vec,

    output wire signed [DATA_WIDTH-1:0] y_pre_out,
    output wire signed [D_STATE*DATA_WIDTH-1:0] h_new_vec,

    output wire [1:0] pe_op_mode_out,
    output wire       pe_clear_acc_out,
    output wire [D_STATE*DATA_WIDTH-1:0] pe_in_a_vec,
    output wire [D_STATE*DATA_WIDTH-1:0] pe_in_b_vec,
    input  wire [D_STATE*DATA_WIDTH-1:0] pe_result_vec
);

`ifdef BYPASS_SOFTPLUS
    localparam USE_BYPASS_SOFTPLUS = `BYPASS_SOFTPLUS;
`else
    localparam USE_BYPASS_SOFTPLUS = BYPASS_SOFTPLUS;
`endif

    wire signed [DATA_WIDTH-1:0] softplus_out;
    reg  signed [DATA_WIDTH-1:0] delta_act;
    reg  [1:0] sp_cnt;
    reg        sp_armed;
    wire       core_start;

    wire       core_done;
    reg  [1:0] done_hold;

    assign core_start = USE_BYPASS_SOFTPLUS ? start : (sp_armed && (sp_cnt == 2'd0));
    assign done = (DONE_HOLD_CYCLES == 0) ? core_done : (done_hold != 2'd0);

    Softplus_Unit_PWL u_softplus (
        .clk(clk),
        .in_data(delta_raw),
        .out_data(softplus_out)
    );

    Scan_Core_Engine #(
        .LOAD_H_PREV(1)
    ) u_core (
        .clk(clk),
        .reset(reset),
        .start(core_start),
        .en(en),
        .clear_h(1'b0),
        .done(core_done),
        .delta_val(USE_BYPASS_SOFTPLUS ? delta_raw : delta_act),
        .x_val(x_val),
        .D_val(D_val),
        .gate_val(16'sd0),
        .A_vec(A_vec),
        .B_vec(B_vec),
        .C_vec(C_vec),
        .h_prev_vec(h_prev_vec),
        .y_out(),
        .y_pre_out(y_pre_out),
        .h_new_out_vec(h_new_vec),
        .pe_op_mode_out(pe_op_mode_out),
        .pe_clear_acc_out(pe_clear_acc_out),
        .pe_in_a_vec(pe_in_a_vec),
        .pe_in_b_vec(pe_in_b_vec),
        .pe_result_vec(pe_result_vec)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sp_cnt   <= 2'd0;
            sp_armed <= 1'b0;
            delta_act <= 16'sd0;
            done_hold <= 2'd0;
        end else begin
            if (start)
                done_hold <= 2'd0;
            else if (DONE_HOLD_CYCLES != 0) begin
                if (core_done)
                    done_hold <= DONE_HOLD_CYCLES[1:0];
                else if (done_hold != 2'd0)
                    done_hold <= done_hold - 2'd1;
            end

            if (core_start && !USE_BYPASS_SOFTPLUS)
                sp_armed <= 1'b0;
            if (start) begin
                if (USE_BYPASS_SOFTPLUS) begin
                    sp_armed <= 1'b0;
                    sp_cnt   <= 2'd0;
                end else begin
                    sp_armed <= 1'b1;
                    sp_cnt   <= 2'd2;
                end
            end else if (sp_cnt != 2'd0) begin
                if (sp_cnt == 2'd1)
                    delta_act <= softplus_out;
                sp_cnt <= sp_cnt - 2'd1;
            end
        end
    end

endmodule
