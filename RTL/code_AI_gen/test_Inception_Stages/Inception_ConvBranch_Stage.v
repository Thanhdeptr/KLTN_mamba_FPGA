`timescale 1ns/1ps
`include "../../code_initial/_parameter.v"

module Inception_ConvBranch_Stage #(
    parameter integer KERNEL = 9,
    parameter integer CENTER = 23,
    parameter integer WEIGHT_LIMIT = 2303
) (
    input clk,
    input rst_n,
    input [255:0] token_in,
    input valid_in,
    output reg [255:0] token_out,
    output reg valid_out
);

    localparam integer FRAC_BITS = 12;

    reg signed [15:0] weights_c [0:9983];
    reg signed [15:0] b_buf [0:38][0:15];
    reg signed [15:0] b_cur [0:15];
    reg signed [15:0] branch_cur [0:15];

    integer ch, oc, ic, k, idx;
    integer token_seen;
    reg signed [15:0] tap_b;
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
            token_seen <= 0;
            for (k = 0; k < 39; k = k + 1) begin
                for (ch = 0; ch < 16; ch = ch + 1) begin
                    b_buf[k][ch] <= 16'sd0;
                end
            end
        end else if (valid_in) begin
            for (ch = 0; ch < 16; ch = ch + 1) begin
                b_cur[ch] = $signed(token_in[ch*16 +: 16]);
            end

            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    for (k = 0; k < KERNEL; k = k + 1) begin
                        idx = CENTER - k;
                        if (idx == 0) begin
                            tap_b = b_cur[ic];
                        end else begin
                            tap_b = b_buf[idx-1][ic];
                        end
                        acc = acc + ($signed(tap_b) * $signed(weights_c[oc*16*KERNEL + ic*KERNEL + k]));
                    end
                end
                branch_cur[oc] = qshift_sat16_rn(acc);
                token_out[oc*16 +: 16] <= branch_cur[oc];
            end

            if (token_seen >= 19) begin
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end

            for (k = 38; k > 0; k = k - 1) begin
                for (ch = 0; ch < 16; ch = ch + 1) begin
                    b_buf[k][ch] <= b_buf[k-1][ch];
                end
            end
            for (ch = 0; ch < 16; ch = ch + 1) begin
                b_buf[0][ch] <= b_cur[ch];
            end
            token_seen <= token_seen + 1;
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule