`timescale 1ns/1ps

module tb_out_projection_unit;

    reg                     clk, reset, start, en;
    wire                    done;
    reg  [128*16-1:0]       x_vec;
    reg  [64*128*16-1:0]    w_matrix;
    wire [64*16-1:0]        y_vec;

    Out_Projection_Unit dut (
        .clk      (clk),
        .reset    (reset),
        .start    (start),
        .en       (en),
        .done     (done),
        .x_vec    (x_vec),
        .w_matrix (w_matrix),
        .y_vec    (y_vec)
    );

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    integer i, j;
    integer mismatch_count;
    integer max_error;
    integer abs_error;

    reg signed [15:0] x_mem [0:127];
    reg signed [15:0] w_mem [0:63][0:127];
    reg signed [15:0] y_golden [0:63];
    reg signed [15:0] y_rtl;

    reg signed [47:0] acc;
    reg signed [31:0] scaled;

    initial begin
        clk = 0;
        reset = 1;
        start = 0;
        en = 0;
        mismatch_count = 0;
        max_error = 0;

        // Deterministic vectors in safe dynamic range for Q3.12
        for (j = 0; j < 128; j = j + 1) begin
            x_mem[j] = $signed((j % 11) * 64 - 320); // approx [-0.078, 0.156]
            x_vec[j*16 +: 16] = x_mem[j];
        end

        for (i = 0; i < 64; i = i + 1) begin
            for (j = 0; j < 128; j = j + 1) begin
                w_mem[i][j] = $signed(((i + j) % 9) * 48 - 192);
                w_matrix[(i*128 + j)*16 +: 16] = w_mem[i][j];
            end
        end

        // Golden compute in TB (Q3.12 MAC + shift + saturation)
        for (i = 0; i < 64; i = i + 1) begin
            acc = 0;
            for (j = 0; j < 128; j = j + 1) begin
                acc = acc + (x_mem[j] * w_mem[i][j]);
            end

            scaled = acc >>> 12;
            if (scaled > SAT_MAX)
                y_golden[i] = 16'sh7fff;
            else if (scaled < SAT_MIN)
                y_golden[i] = 16'sh8000;
            else
                y_golden[i] = scaled[15:0];
        end

        #50 reset = 0;
        #20;

        start = 1;
        en = 1;
        #10;
        start = 0;

        // Combinational datapath settle window
        #20;

        for (i = 0; i < 64; i = i + 1) begin
            y_rtl = y_vec[i*16 +: 16];
            abs_error = (y_rtl >= y_golden[i]) ? (y_rtl - y_golden[i]) : (y_golden[i] - y_rtl);

            if (abs_error > 0) begin
                mismatch_count = mismatch_count + 1;
                if (abs_error > max_error) max_error = abs_error;
                if (mismatch_count <= 5) begin
                    $display("MISMATCH lane=%0d got=%04x exp=%04x err=%0d", i, y_rtl, y_golden[i], abs_error);
                end
            end
        end

        $display("\n=== OUT_PROJECTION TEST RESULT ===");
        $display("Compared: 64 lanes");
        $display("Mismatches: %0d", mismatch_count);
        if (mismatch_count == 0)
            $display("PASS: All values matched.");
        else
            $display("FAIL: max error = %0d", max_error);
        $display("==================================\n");

        #20 $finish;
    end

    always #5 clk = ~clk;

endmodule
