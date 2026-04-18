`timescale 1ns/1ps

module Inception_Final_Stage (
    input clk,
    input rst_n,
    input [1023:0] token_in,
    input valid_in,
    output reg [1023:0] token_out,
    output reg valid_out
);

    localparam integer FRAC_BITS = 12;
    localparam real EPS = 1.0e-5;

    reg signed [15:0] bn_weight [0:63];
    reg signed [15:0] bn_bias [0:63];
    reg signed [15:0] bn_mean [0:63];
    reg signed [15:0] bn_var [0:63];

    integer ch;
    integer qval;
    real x_r, gamma_r, beta_r, mean_r, var_r, y_r, scaled;

    function automatic signed [15:0] sat16;
        input integer x;
        begin
            if (x > 32767) begin
                sat16 = 16'sd32767;
            end else if (x < -32768) begin
                sat16 = -16'sd32768;
            end else begin
                sat16 = x[15:0];
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            token_out <= 1024'h0;
        end else if (valid_in) begin
            for (ch = 0; ch < 64; ch = ch + 1) begin
                x_r = $itor($signed(token_in[ch*16 +: 16])) / 4096.0;
`ifdef BYPASS_BN
                y_r = x_r;
`else
                gamma_r = $itor($signed(bn_weight[ch])) / 4096.0;
                beta_r = $itor($signed(bn_bias[ch])) / 4096.0;
                mean_r = $itor($signed(bn_mean[ch])) / 4096.0;
                var_r = $itor($signed(bn_var[ch])) / 4096.0;
                y_r = ((x_r - mean_r) * gamma_r / (var_r + EPS)) + beta_r;
`endif
                scaled = y_r * 4096.0;
                if (scaled >= 0.0) begin
                    qval = $rtoi(scaled + 0.5);
                end else begin
                    qval = $rtoi(scaled - 0.5);
                end
                qval = sat16(qval);
                if (qval < 0) begin
                    token_out[ch*16 +: 16] <= 16'h0000;
                end else begin
                    token_out[ch*16 +: 16] <= qval[15:0];
                end
            end
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule