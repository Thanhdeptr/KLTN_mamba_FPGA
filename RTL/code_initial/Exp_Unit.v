`include "_parameter.v"

module Exp_Unit
(
    input clk,
    input signed [`DATA_WIDTH-1:0] in_data,
    output signed [`DATA_WIDTH-1:0] out_data
);
    Exp_Unit_PWL u_exp_pwl (
        .clk(clk),
        .in_data(in_data),
        .out_data(out_data)
    );
endmodule
