`timescale 1ns/1ps
`include "../../code_initial/_parameter.v"

module Inception_Bottleneck_Stage (
    input clk,
    input rst_n,
    input [1023:0] token_in,
    input valid_in,
    output reg [255:0] token_out,
    output reg valid_out
);

    localparam integer FRAC_BITS = 12;

    reg signed [15:0] weights_bn [0:1023];
    reg signed [15:0] x_cur [0:63];
    reg signed [15:0] bottleneck_cur [0:15];

    integer ch, oc, ic;
    reg signed [63:0] acc;

    function automatic signed [15:0] sat16;
        input signed [63:0] x;
        begin
            if (x > 64'sd32767) begin
                sat16 = 16'sd32767;
            end else if (x < -64'sd32768) begin
                sat16 = -16'sd32768;
            end else begin
                sat16 = x[15:0];
            end
        end
    endfunction

    function automatic signed [15:0] qshift_sat16_rn;
        input signed [63:0] x;
        reg signed [63:0] y;
        begin
            if (x >= 0) begin
                y = (x + (64'sd1 <<< (FRAC_BITS-1))) >>> FRAC_BITS;
            end else begin
                y = -(((-x) + (64'sd1 <<< (FRAC_BITS-1))) >>> FRAC_BITS);
            end
            qshift_sat16_rn = sat16(y);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            token_out <= 256'h0;
        end else if (valid_in) begin
            for (ch = 0; ch < 64; ch = ch + 1) begin
                x_cur[ch] = $signed(token_in[ch*16 +: 16]);
            end

            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 64; ic = ic + 1) begin
                    acc = acc + ($signed(x_cur[ic]) * $signed(weights_bn[oc*64 + ic]));
                end
                bottleneck_cur[oc] = qshift_sat16_rn(acc);
                token_out[oc*16 +: 16] <= bottleneck_cur[oc];
            end

            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule