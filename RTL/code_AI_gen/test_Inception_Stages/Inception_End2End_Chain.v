`timescale 1ns/1ps

module Inception_End2End_Chain (
    input clk,
    input rst_n,
    input [1023:0] token_in,
    input valid_in,
    output [1023:0] token_out,
    output valid_out
);

    wire [255:0] bottleneck_out;
    wire bottleneck_valid;

    reg [255:0] bottleneck_pipe;
    reg bottleneck_pipe_valid;

    wire [255:0] conv1_out;
    wire conv1_valid;

    reg [255:0] conv1_hold;
    reg [255:0] conv9_hold;
    reg [255:0] conv19_hold;
    reg [255:0] conv39_hold;
    reg conv1_flag;
    reg conv9_flag;
    reg conv19_flag;
    reg conv39_flag;

    wire [255:0] conv9_out;
    wire conv9_valid;

    wire [255:0] conv19_out;
    wire conv19_valid;

    wire [255:0] conv39_out;
    wire conv39_valid;

    reg [1023:0] concat_token;
    reg concat_valid;

    integer oc;

    Inception_Bottleneck_Stage u_bottleneck (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(token_in),
        .valid_in(valid_in),
        .token_out(bottleneck_out),
        .valid_out(bottleneck_valid)
    );

    Inception_Conv1_Stage u_conv1 (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(token_in),
        .valid_in(valid_in),
        .token_out(conv1_out),
        .valid_out(conv1_valid)
    );

    Inception_Conv9_Stage u_conv9 (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(bottleneck_pipe),
        .valid_in(bottleneck_pipe_valid),
        .token_out(conv9_out),
        .valid_out(conv9_valid)
    );

    Inception_Conv19_Stage u_conv19 (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(bottleneck_pipe),
        .valid_in(bottleneck_pipe_valid),
        .token_out(conv19_out),
        .valid_out(conv19_valid)
    );

    Inception_Conv39_Stage u_conv39 (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(bottleneck_pipe),
        .valid_in(bottleneck_pipe_valid),
        .token_out(conv39_out),
        .valid_out(conv39_valid)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            concat_token <= 1024'h0;
            concat_valid <= 1'b0;
            bottleneck_pipe <= 256'h0;
            bottleneck_pipe_valid <= 1'b0;
            conv1_hold <= 256'h0;
            conv9_hold <= 256'h0;
            conv19_hold <= 256'h0;
            conv39_hold <= 256'h0;
            conv1_flag <= 1'b0;
            conv9_flag <= 1'b0;
            conv19_flag <= 1'b0;
            conv39_flag <= 1'b0;
        end else begin
            bottleneck_pipe <= bottleneck_out;
            bottleneck_pipe_valid <= bottleneck_valid;

            if (conv1_valid) begin
                conv1_hold <= conv1_out;
                conv1_flag <= 1'b1;
            end
            if (conv9_valid) begin
                conv9_hold <= conv9_out;
                conv9_flag <= 1'b1;
            end
            if (conv19_valid) begin
                conv19_hold <= conv19_out;
                conv19_flag <= 1'b1;
            end
            if (conv39_valid) begin
                conv39_hold <= conv39_out;
                conv39_flag <= 1'b1;
            end

            concat_valid <= 1'b0;
            if (conv1_flag && conv9_flag && conv19_flag && conv39_flag) begin
                for (oc = 0; oc < 16; oc = oc + 1) begin
                    concat_token[oc*16 +: 16] <= conv1_hold[oc*16 +: 16];
                    concat_token[(oc+16)*16 +: 16] <= conv9_hold[oc*16 +: 16];
                    concat_token[(oc+32)*16 +: 16] <= conv19_hold[oc*16 +: 16];
                    concat_token[(oc+48)*16 +: 16] <= conv39_hold[oc*16 +: 16];
                end
                concat_valid <= 1'b1;
                conv1_flag <= 1'b0;
                conv9_flag <= 1'b0;
                conv19_flag <= 1'b0;
                conv39_flag <= 1'b0;
            end
        end
    end

    Inception_Final_Stage u_final (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(concat_token),
        .valid_in(concat_valid),
        .token_out(token_out),
        .valid_out(valid_out)
    );

endmodule