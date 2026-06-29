`include "_parameter.v"

// 16-lane Unified_PE array — one engine for a pipeline stage (MUL / MAC / ADD).
module Scan_Vector_Mul16 #(
    parameter DATA_WIDTH = 16,
    parameter LANES      = 16
) (
    input  wire clk,
    input  wire reset,
    input  wire [1:0] op_mode,
    input  wire       clear_acc,
    input  wire signed [LANES*DATA_WIDTH-1:0] a_vec,
    input  wire signed [LANES*DATA_WIDTH-1:0] b_vec,
    output wire signed [LANES*DATA_WIDTH-1:0] result_vec
);

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : pe_lane
            Unified_PE u_pe (
                .clk(clk),
                .reset(reset),
                .op_mode(op_mode),
                .clear_acc(clear_acc),
                .in_A(a_vec[gi*DATA_WIDTH +: DATA_WIDTH]),
                .in_B(b_vec[gi*DATA_WIDTH +: DATA_WIDTH]),
                .out_val(result_vec[gi*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

endmodule
