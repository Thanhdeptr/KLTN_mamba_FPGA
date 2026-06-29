`include "_parameter.v"

// P4: y_out = sat( (y_pre * z_act) >>> FRAC_BITS ) — combinational for beat-aligned gate.
module Scan_XZ_Engine #(
    parameter DATA_WIDTH = 16,
    parameter LANES      = 16,
    parameter FRAC_BITS  = 12
) (
    input  wire gate_en,
    input  wire signed [LANES*DATA_WIDTH-1:0] y_pre_vec,
    input  wire signed [LANES*DATA_WIDTH-1:0] z_act_vec,
    output wire signed [LANES*DATA_WIDTH-1:0] y_out_vec
);

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : lane_gate
            wire signed [DATA_WIDTH-1:0] y_lane = y_pre_vec[gi*DATA_WIDTH +: DATA_WIDTH];
            wire signed [DATA_WIDTH-1:0] z_lane = z_act_vec[gi*DATA_WIDTH +: DATA_WIDTH];
            wire signed [31:0] prod = y_lane * z_lane;
            wire signed [31:0] gate_round_bias =
                prod[31] ? -(32'sd1 << (FRAC_BITS-1)) : (32'sd1 << (FRAC_BITS-1));
            wire signed [31:0] shifted = (prod + gate_round_bias) >>> FRAC_BITS;
            assign y_out_vec[gi*DATA_WIDTH +: DATA_WIDTH] =
                gate_en ? (
                    (shifted > 32767)  ? 16'sh7FFF :
                    (shifted < -32768) ? 16'sh8000 :
                    shifted[15:0]
                ) : 16'sd0;
        end
    endgenerate

endmodule
