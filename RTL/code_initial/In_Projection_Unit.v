`timescale 1ns/1ps
`include "_parameter.v"

module In_Projection_Unit
(
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          start,
    input  wire                          en,
    output reg                           done,

    input  wire [64*`DATA_WIDTH-1:0]     x_vec,           // 64-dim input, Q3.12
    input  wire [128*64*`DATA_WIDTH-1:0] w_matrix,        // 128x64 weight, Q3.12

    output wire [128*`DATA_WIDTH-1:0]    y_vec            // 128-dim output, Q3.12
);

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    integer i, j;
    wire signed [15:0] x_val, w_val;
    wire signed [31:0] acc [0:127];
    wire signed [31:0] out_tmp [0:127];
    wire signed [15:0] y_out [0:127];

    // Combinational: compute all 128 outputs in parallel
    genvar gi, gj;

    generate
        for (gi = 0; gi < 128; gi = gi + 1) begin : output_lanes
            // Compute accumulation for lane gi: sum over j=0:63 of w[gi,j] * x[j]
            wire signed [31:0] partial_sums [0:63];
            
            for (gj = 0; gj < 64; gj = gj + 1) begin : dot_product
                wire signed [15:0] x_gj = x_vec[gj*`DATA_WIDTH +: `DATA_WIDTH];
                wire signed [15:0] w_gi_gj = w_matrix[gi*64*`DATA_WIDTH + gj*`DATA_WIDTH +: `DATA_WIDTH];
                assign partial_sums[gj] = x_gj * w_gi_gj;
            end

            // Sum all partial products
            wire signed [31:0] lane_acc;
            assign lane_acc = partial_sums[0] + partial_sums[1] + partial_sums[2] + partial_sums[3]
                            + partial_sums[4] + partial_sums[5] + partial_sums[6] + partial_sums[7]
                            + partial_sums[8] + partial_sums[9] + partial_sums[10] + partial_sums[11]
                            + partial_sums[12] + partial_sums[13] + partial_sums[14] + partial_sums[15]
                            + partial_sums[16] + partial_sums[17] + partial_sums[18] + partial_sums[19]
                            + partial_sums[20] + partial_sums[21] + partial_sums[22] + partial_sums[23]
                            + partial_sums[24] + partial_sums[25] + partial_sums[26] + partial_sums[27]
                            + partial_sums[28] + partial_sums[29] + partial_sums[30] + partial_sums[31]
                            + partial_sums[32] + partial_sums[33] + partial_sums[34] + partial_sums[35]
                            + partial_sums[36] + partial_sums[37] + partial_sums[38] + partial_sums[39]
                            + partial_sums[40] + partial_sums[41] + partial_sums[42] + partial_sums[43]
                            + partial_sums[44] + partial_sums[45] + partial_sums[46] + partial_sums[47]
                            + partial_sums[48] + partial_sums[49] + partial_sums[50] + partial_sums[51]
                            + partial_sums[52] + partial_sums[53] + partial_sums[54] + partial_sums[55]
                            + partial_sums[56] + partial_sums[57] + partial_sums[58] + partial_sums[59]
                            + partial_sums[60] + partial_sums[61] + partial_sums[62] + partial_sums[63];

            // Scale back from Q(3.12+3.12) → Q3.12
            wire signed [31:0] scaled = lane_acc >>> `FRAC_BITS;
            
            // Saturate
            assign y_out[gi] = (scaled > SAT_MAX) ? 16'sh7fff :
                               (scaled < SAT_MIN) ? 16'sh8000 :
                               scaled[15:0];
            
            assign y_vec[gi*`DATA_WIDTH +: `DATA_WIDTH] = y_out[gi];
        end
    endgenerate

    // Done signal: pulse on (start && en)
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            done <= 1'b0;
        end else begin
            done <= (start && en) ? 1'b1 : 1'b0;
        end
    end

endmodule
