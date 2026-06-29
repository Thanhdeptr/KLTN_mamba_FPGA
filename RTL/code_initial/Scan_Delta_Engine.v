`include "_parameter.v"

// P0-P1 partition: softplus + delta-front tag queue for synthesis budgeting.
// Simulation uses Scan_Channel_Exec softplus wrapper; this module documents the delta slice.
module Scan_Delta_Engine #(
    parameter DATA_WIDTH = 16,
    parameter LANES      = 16
) (
    input  wire clk,
    input  wire rst_n,
    input  wire delta_valid,
    input  wire signed [LANES*DATA_WIDTH-1:0] delta_raw_vec,
    output wire signed [LANES*DATA_WIDTH-1:0] delta_act_vec,
    output wire        delta_act_valid
);

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : lane_sp
            wire signed [DATA_WIDTH-1:0] din  = delta_raw_vec[gi*DATA_WIDTH +: DATA_WIDTH];
            wire signed [DATA_WIDTH-1:0] dout;
            Softplus_Unit_PWL u_sp (
                .clk(clk),
                .in_data(din),
                .out_data(dout)
            );
            assign delta_act_vec[gi*DATA_WIDTH +: DATA_WIDTH] = dout;
        end
    endgenerate

    assign delta_act_valid = delta_valid;

endmodule
