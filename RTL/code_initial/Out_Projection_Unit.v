`timescale 1ns/1ps
`include "_parameter.v"

module Out_Projection_Unit
(
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          start,
    input  wire                          en,
    output reg                           done,

    input  wire [128*`DATA_WIDTH-1:0]    x_vec,           // 128-dim input, Q3.12
    input  wire [64*128*`DATA_WIDTH-1:0] w_matrix,        // 64x128 weight, Q3.12

    output wire [64*`DATA_WIDTH-1:0]     y_vec            // 64-dim output, Q3.12
);

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    wire signed [15:0] x_val, w_val;
    wire signed [15:0] y_out [0:63];

    // Combinational: compute all 64 outputs in parallel
    genvar gi, gj;

    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : output_lanes
            // Compute accumulation for lane gi: sum over j=0:127 of w[gi,j] * x[j]
            wire signed [31:0] partial_sums [0:127];
            
            for (gj = 0; gj < 128; gj = gj + 1) begin : dot_product
                wire signed [15:0] x_gj = x_vec[gj*`DATA_WIDTH +: `DATA_WIDTH];
                wire signed [15:0] w_gi_gj = w_matrix[gi*128*`DATA_WIDTH + gj*`DATA_WIDTH +: `DATA_WIDTH];
                assign partial_sums[gj] = x_gj * w_gi_gj;
            end

            // Sum all partial products
            wire signed [47:0] lane_acc;
            assign lane_acc = $signed(partial_sums[0]) + partial_sums[1] + partial_sums[2] + partial_sums[3]
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
                            + partial_sums[60] + partial_sums[61] + partial_sums[62] + partial_sums[63]
                            + partial_sums[64] + partial_sums[65] + partial_sums[66] + partial_sums[67]
                            + partial_sums[68] + partial_sums[69] + partial_sums[70] + partial_sums[71]
                            + partial_sums[72] + partial_sums[73] + partial_sums[74] + partial_sums[75]
                            + partial_sums[76] + partial_sums[77] + partial_sums[78] + partial_sums[79]
                            + partial_sums[80] + partial_sums[81] + partial_sums[82] + partial_sums[83]
                            + partial_sums[84] + partial_sums[85] + partial_sums[86] + partial_sums[87]
                            + partial_sums[88] + partial_sums[89] + partial_sums[90] + partial_sums[91]
                            + partial_sums[92] + partial_sums[93] + partial_sums[94] + partial_sums[95]
                            + partial_sums[96] + partial_sums[97] + partial_sums[98] + partial_sums[99]
                            + partial_sums[100] + partial_sums[101] + partial_sums[102] + partial_sums[103]
                            + partial_sums[104] + partial_sums[105] + partial_sums[106] + partial_sums[107]
                            + partial_sums[108] + partial_sums[109] + partial_sums[110] + partial_sums[111]
                            + partial_sums[112] + partial_sums[113] + partial_sums[114] + partial_sums[115]
                            + partial_sums[116] + partial_sums[117] + partial_sums[118] + partial_sums[119]
                            + partial_sums[120] + partial_sums[121] + partial_sums[122] + partial_sums[123]
                            + partial_sums[124] + partial_sums[125] + partial_sums[126] + partial_sums[127];

            // Scale back from Q(3.12+3.12) → Q3.12
            wire signed [47:0] scaled = lane_acc >>> `FRAC_BITS;
            
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
