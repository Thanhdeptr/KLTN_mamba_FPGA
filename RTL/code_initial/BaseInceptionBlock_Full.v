`timescale 1ns/1ps
`include "_parameter.v"

module BaseInceptionBlock_Full (
    input clk,
    input rst_n,
    input [1023:0] token_in,
    input valid_in,
    output reg [1023:0] token_out,
    output reg valid_out
);

    localparam integer FRAC_BITS = 12;

    // Inception weights
    reg signed [15:0] weights_bn [0:1023];          // bottleneck: [16][64]
    reg signed [15:0] weights_c1 [0:1023];          // conv1: [16][64]
    reg signed [15:0] weights_c9 [0:2303];          // conv9: [16][16][9]
    reg signed [15:0] weights_c19 [0:4863];         // conv19: [16][16][19]
    reg signed [15:0] weights_c39 [0:9983];         // conv39: [16][16][39]

    // BN folded into per-channel post-conv bias.
    reg signed [15:0] fold_bias [0:63];

    // Sliding windows for SAME padding (lookahead delay = 19 tokens).
    // Index 0 is the most recent previously received token.
    reg signed [15:0] x_buf [0:38][0:63];
    reg signed [15:0] b_buf [0:38][0:15];

    // Per-token scratch buffers
    reg signed [15:0] x_cur [0:63];
    reg signed [15:0] pool_cur [0:63];
    reg signed [15:0] bottleneck_cur [0:15];
    reg signed [15:0] conv1_out [0:15];
    reg signed [15:0] conv9_out [0:15];
    reg signed [15:0] conv19_out [0:15];
    reg signed [15:0] conv39_out [0:15];
    reg signed [15:0] concat_out [0:63];
    reg signed [15:0] post_out [0:63];

    integer ch, oc, ic, k, idx;
    integer token_seen;
    reg signed [15:0] tap_x;
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
            token_out <= 1024'h0;
            token_seen <= 0;
            for (k = 0; k < 39; k = k + 1) begin
                for (ch = 0; ch < 64; ch = ch + 1) begin
                    x_buf[k][ch] <= 16'sd0;
                end
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    b_buf[k][ic] <= 16'sd0;
                end
            end
        end else if (valid_in) begin
            // Unpack input token (64 channels)
            for (ch = 0; ch < 64; ch = ch + 1) begin
                x_cur[ch] = $signed(token_in[ch*16 +: 16]);
            end

            // Branch 1 pre-op: MaxPool(k=3, stride=1, padding=1) centered at t-19
            for (ch = 0; ch < 64; ch = ch + 1) begin
                // window indices: 20,19,18 in the new-window convention
                pool_cur[ch] = x_buf[19][ch];
                if ($signed(x_buf[18][ch]) > $signed(pool_cur[ch])) begin
                    pool_cur[ch] = x_buf[18][ch];
                end
                if ($signed(x_buf[17][ch]) > $signed(pool_cur[ch])) begin
                    pool_cur[ch] = x_buf[17][ch];
                end
            end

            // Bottleneck: 64 -> 16
            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 64; ic = ic + 1) begin
                    acc = acc + ($signed(x_cur[ic]) * $signed(weights_bn[oc*64 + ic]));
                end
                bottleneck_cur[oc] = qshift_sat16_rn(acc);
            end

            // Conv1 on maxpool branch: 64 -> 16
            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 64; ic = ic + 1) begin
                    acc = acc + ($signed(pool_cur[ic]) * $signed(weights_c1[oc*64 + ic]));
                end
                conv1_out[oc] = qshift_sat16_rn(acc);
            end

            // Conv9 on centered same-padding window (b = 23-k)
            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    for (k = 0; k < 9; k = k + 1) begin
                        idx = 23 - k;
                        if (idx == 0) begin
                            tap_b = bottleneck_cur[ic];
                        end else begin
                            tap_b = b_buf[idx-1][ic];
                        end
                        acc = acc + ($signed(tap_b) * $signed(weights_c9[oc*16*9 + ic*9 + k]));
                    end
                end
                conv9_out[oc] = qshift_sat16_rn(acc);
            end

            // Conv19 on centered same-padding window (b = 28-k)
            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    for (k = 0; k < 19; k = k + 1) begin
                        idx = 28 - k;
                        if (idx == 0) begin
                            tap_b = bottleneck_cur[ic];
                        end else begin
                            tap_b = b_buf[idx-1][ic];
                        end
                        acc = acc + ($signed(tap_b) * $signed(weights_c19[oc*16*19 + ic*19 + k]));
                    end
                end
                conv19_out[oc] = qshift_sat16_rn(acc);
            end

            // Conv39 on centered same-padding window (b = 38-k)
            for (oc = 0; oc < 16; oc = oc + 1) begin
                acc = 0;
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    for (k = 0; k < 39; k = k + 1) begin
                        idx = 38 - k;
                        if (idx == 0) begin
                            tap_b = bottleneck_cur[ic];
                        end else begin
                            tap_b = b_buf[idx-1][ic];
                        end
                        acc = acc + ($signed(tap_b) * $signed(weights_c39[oc*16*39 + ic*39 + k]));
                    end
                end
                conv39_out[oc] = qshift_sat16_rn(acc);
            end

            // Concatenate [x1, x2, x3, x4]
            for (oc = 0; oc < 16; oc = oc + 1) begin
                concat_out[oc] = conv1_out[oc];
                concat_out[oc + 16] = conv9_out[oc];
                concat_out[oc + 32] = conv19_out[oc];
                concat_out[oc + 48] = conv39_out[oc];
            end

            // BN folded into branch-specific bias; keep ReLU here.
            for (ch = 0; ch < 64; ch = ch + 1) begin
                if (($signed(concat_out[ch]) + $signed(fold_bias[ch])) <= 0) begin
                    post_out[ch] = 16'sd0;
                end else begin
                    post_out[ch] = sat16($signed(concat_out[ch]) + $signed(fold_bias[ch]));
                end
                token_out[ch*16 +: 16] <= post_out[ch];
            end

            // Delay 19 tokens to realize centered windows with future context.
            if (token_seen >= 19) begin
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end

            // Shift windows and push current token/bottleneck to index 0.
            for (k = 38; k > 0; k = k - 1) begin
                for (ch = 0; ch < 64; ch = ch + 1) begin
                    x_buf[k][ch] <= x_buf[k-1][ch];
                end
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    b_buf[k][ic] <= b_buf[k-1][ic];
                end
            end
            for (ch = 0; ch < 64; ch = ch + 1) begin
                x_buf[0][ch] <= x_cur[ch];
            end
            for (ic = 0; ic < 16; ic = ic + 1) begin
                b_buf[0][ic] <= bottleneck_cur[ic];
            end
            token_seen <= token_seen + 1;
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
