`include "_parameter.v"

// Level-B ITM Block (paper Fig. 2): Inception pathway + Mamba pathway, then element-wise add.
// - Inception: Conv1D_Layer (k=4 + SiLU) as hardware proxy for multi-scale Inception (full 9/19/39 can extend later).
// - Mamba: Scan_Core_Engine one step; scalar scan_y_out broadcast to 16 lanes for merge (tensor output extension later).
// - Merge: out[i] = sat16( incept[i] + relu(scan_y) )
// PE is time-multiplexed between Conv and Scan sub-blocks.

module ITM_Block
(
    input clk,
    input reset,

    input itm_start,
    input itm_en,
    output reg itm_done,
    output reg itm_valid_out,
    output reg signed [16 * `DATA_WIDTH - 1 : 0] itm_out_vec,

    input signed [16 * `DATA_WIDTH - 1 : 0] feat_in_vec,

    input signed [16 * 4 * `DATA_WIDTH - 1 : 0] conv_w_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] conv_b_vec,

    input signed [`DATA_WIDTH-1:0] scan_delta_val,
    input signed [`DATA_WIDTH-1:0] scan_x_val,
    input signed [`DATA_WIDTH-1:0] scan_D_val,
    input signed [`DATA_WIDTH-1:0] scan_gate_val,
    input signed [16 * `DATA_WIDTH - 1 : 0] scan_A_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] scan_B_vec,
    input signed [16 * `DATA_WIDTH - 1 : 0] scan_C_vec,
    input scan_clear_h,

    output reg [1:0] pe_op_mode_out,
    output reg pe_clear_out,
    output reg [16 * `DATA_WIDTH - 1 : 0] pe_in_a_vec,
    output reg [16 * `DATA_WIDTH - 1 : 0] pe_in_b_vec,
    input wire [16 * `DATA_WIDTH - 1 : 0] pe_result_vec
);

    localparam ST_IDLE      = 3'd0;
    localparam ST_CONV_ARM  = 3'd1;
    localparam ST_CONV_WAIT = 3'd2;
    localparam ST_SCAN_ARM  = 3'd3;
    localparam ST_SCAN_WAIT = 3'd4;
    localparam ST_MERGE     = 3'd5;

    reg [2:0] st;
    reg conv_start_p;
    reg conv_valid_in_p;
    reg scan_start_p;
    reg sent_conv_valid;

    wire [1:0] conv_pe_op;
    wire conv_pe_clr;
    wire [255:0] conv_pe_in_a;
    wire [255:0] conv_pe_in_b;

    wire [1:0] scan_pe_op;
    wire scan_pe_clr;
    wire [255:0] scan_pe_in_a;
    wire [255:0] scan_pe_in_b;

    wire conv_valid_out_w;
    wire conv_ready_in_w;
    wire signed [16 * `DATA_WIDTH - 1 : 0] conv_y_vec_w;

    wire scan_done_w;
    wire signed [`DATA_WIDTH-1:0] scan_y_w;

    Conv1D_Layer u_conv (
        .clk(clk),
        .reset(reset),
        .start(conv_start_p),
        .en(itm_en && ((st == ST_CONV_ARM) || (st == ST_CONV_WAIT))),
        .valid_in(conv_valid_in_p),
        .valid_out(conv_valid_out_w),
        .ready_in(conv_ready_in_w),
        .x_in_vec(feat_in_vec),
        .weights_vec(conv_w_vec),
        .bias_vec(conv_b_vec),
        .y_out_vec(conv_y_vec_w),
        .pe_op_mode_out(conv_pe_op),
        .pe_clear_out(conv_pe_clr),
        .pe_in_a_vec(conv_pe_in_a),
        .pe_in_b_vec(conv_pe_in_b),
        .pe_result_vec(pe_result_vec)
    );

    Scan_Core_Engine u_scan (
        .clk(clk),
        .reset(reset),
        .start(scan_start_p),
        .en(itm_en && ((st == ST_SCAN_ARM) || (st == ST_SCAN_WAIT))),
        .clear_h(scan_clear_h),
        .done(scan_done_w),
        .delta_val(scan_delta_val),
        .x_val(scan_x_val),
        .D_val(scan_D_val),
        .gate_val(scan_gate_val),
        .A_vec(scan_A_vec),
        .B_vec(scan_B_vec),
        .C_vec(scan_C_vec),
        .y_out(scan_y_w),
        .pe_op_mode_out(scan_pe_op),
        .pe_clear_acc_out(scan_pe_clr),
        .pe_in_a_vec(scan_pe_in_a),
        .pe_in_b_vec(scan_pe_in_b),
        .pe_result_vec(pe_result_vec)
    );

    reg signed [16 * `DATA_WIDTH - 1 : 0] incept_lat;

    integer lane;
    reg signed [15:0] merge_a;
    reg signed [15:0] merge_b;
    reg signed [15:0] merge_ru;
    reg signed [15:0] merge_rv;
    reg signed [16:0] merge_sum;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            st <= ST_IDLE;
            itm_done <= 0;
            itm_valid_out <= 0;
            itm_out_vec <= 0;
            incept_lat <= 0;
            conv_start_p <= 0;
            conv_valid_in_p <= 0;
            scan_start_p <= 0;
            sent_conv_valid <= 0;
            pe_op_mode_out <= `MODE_MUL;
            pe_clear_out <= 1'b1;
            pe_in_a_vec <= 0;
            pe_in_b_vec <= 0;
        end else begin
            conv_start_p <= 0;
            conv_valid_in_p <= 0;
            scan_start_p <= 0;

            if ((st == ST_CONV_ARM) || (st == ST_CONV_WAIT)) begin
                pe_op_mode_out <= conv_pe_op;
                pe_clear_out   <= conv_pe_clr;
                pe_in_a_vec    <= conv_pe_in_a;
                pe_in_b_vec    <= conv_pe_in_b;
            end else if ((st == ST_SCAN_ARM) || (st == ST_SCAN_WAIT)) begin
                pe_op_mode_out <= scan_pe_op;
                pe_clear_out   <= scan_pe_clr;
                pe_in_a_vec    <= scan_pe_in_a;
                pe_in_b_vec    <= scan_pe_in_b;
            end else begin
                pe_op_mode_out <= `MODE_MUL;
                pe_clear_out   <= 1'b1;
                pe_in_a_vec    <= 0;
                pe_in_b_vec    <= 0;
            end

            if (itm_done && !itm_start)
                itm_done <= 0;
            if (itm_valid_out)
                itm_valid_out <= 0;

            case (st)
                ST_IDLE: begin
                    if (itm_start && itm_en) begin
                        itm_done <= 0;
                        conv_start_p <= 1'b1;
                        sent_conv_valid <= 0;
                        st <= ST_CONV_ARM;
                    end
                end

                ST_CONV_ARM: begin
                    if (itm_en) begin
                        if (!sent_conv_valid && conv_ready_in_w) begin
                            conv_valid_in_p <= 1'b1;
                            sent_conv_valid <= 1'b1;
                            st <= ST_CONV_WAIT;
                        end
                    end
                end

                ST_CONV_WAIT: begin
                    if (itm_en) begin
                        if (conv_valid_out_w) begin
                            incept_lat <= conv_y_vec_w;
                            sent_conv_valid <= 0;
                            st <= ST_SCAN_ARM;
                        end
                    end
                end

                ST_SCAN_ARM: begin
                    scan_start_p <= 1'b1;
                    st <= ST_SCAN_WAIT;
                end

                ST_SCAN_WAIT: begin
                    if (itm_en && scan_done_w)
                        st <= ST_MERGE;
                end

                ST_MERGE: begin
                    for (lane = 0; lane < 16; lane = lane + 1) begin
                        merge_a = incept_lat[lane*`DATA_WIDTH +: `DATA_WIDTH];
                        merge_b = scan_y_w;
                        merge_ru = merge_a;
                        merge_rv = ($signed(merge_b) < 0) ? 16'sd0 : merge_b;
                        merge_sum = merge_ru + merge_rv;
                        if (merge_sum > 32767)
                            itm_out_vec[lane*`DATA_WIDTH +: `DATA_WIDTH] <= 16'sh7FFF;
                        else if (merge_sum < -32768)
                            itm_out_vec[lane*`DATA_WIDTH +: `DATA_WIDTH] <= 16'sh8000;
                        else
                            itm_out_vec[lane*`DATA_WIDTH +: `DATA_WIDTH] <= merge_sum[15:0];
                    end
                    itm_valid_out <= 1'b1;
                    itm_done <= 1'b1;
                    st <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
