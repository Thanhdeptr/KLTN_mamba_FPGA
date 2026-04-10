`include "_parameter.v"

module Exp_Unit
(
    input clk,
    input signed [`DATA_WIDTH-1:0] in_data,
    output signed [`DATA_WIDTH-1:0] out_data
);
    reg signed [`DATA_WIDTH-1:0] in_data_r;

    always @(posedge clk) begin
        in_data_r <= in_data;
    end

    Exp_Unit_PWL u_exp_pwl (
        .clk(clk),
        .in_data(in_data_r),
        .out_data(out_data)
    );
endmodule
