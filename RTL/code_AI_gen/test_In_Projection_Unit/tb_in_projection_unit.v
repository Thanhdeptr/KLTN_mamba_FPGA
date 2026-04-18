`timescale 1ns/1ps

module tb_in_projection_unit;

    reg                           clk, reset, start, en;
    wire                          done;
    reg  [64*16-1:0]              x_vec;
    reg  [128*64*16-1:0]          w_matrix;
    wire [128*16-1:0]             y_vec;

    In_Projection_Unit dut (
        .clk      (clk),
        .reset    (reset),
        .start    (start),
        .en       (en),
        .done     (done),
        .x_vec    (x_vec),
        .w_matrix (w_matrix),
        .y_vec    (y_vec)
    );

    // Memory arrays for test vectors
    reg [15:0] input_mem [0:63];
    reg [15:0] weight_matrix [0:8191];    // 128x64
    reg [15:0] golden_output_mem [0:255999];  // 2000 samples x 128 dim

    integer i, test_num, mismatch_count, max_error, error;
    integer gold_addr, out_addr;
    reg [15:0] gold_val, out_val;
    integer abs_error;

    initial begin
        $readmemh("input.mem", input_mem);
        $readmemh("weight_1.mem", weight_matrix);
        $readmemh("golden_output.mem", golden_output_mem);
        
        clk = 0;
        reset = 1;
        start = 0;
        en = 0;
        mismatch_count = 0;
        max_error = 0;
        
        #100 reset = 0;
        #100;

        // Load weights into w_matrix register
        for (i = 0; i < 8192; i = i + 1) begin
            w_matrix[i*16 +: 16] = weight_matrix[i];
        end

        // Load input into x_vec register
        for (i = 0; i < 64; i = i + 1) begin
            x_vec[i*16 +: 16] = input_mem[i];
        end

        $display("[tb_in_projection] Starting test vectors (max 1 for quick debug)...");

        // Run just 1 test case for quick validation
        for (test_num = 0; test_num < 1; test_num = test_num + 1) begin
            $display("  [debug] Starting test %0d", test_num);
            // Trigger module
            start = 1;
            en = 1;
            #10;
            start = 0;
            #20;

            // Projection unit is combinational; done may be a short pulse.
            // Wait a fixed settling time to avoid missing the pulse in testbench.
            $display("  [debug] Test %0d compare window reached", test_num);

            // Compare output: y_vec[0:127] vs golden_output_mem[test_num*128 +: 128]
            for (i = 0; i < 128; i = i + 1) begin
                out_val = y_vec[i*16 +: 16];
                gold_addr = test_num * 128 + i;
                gold_val  = golden_output_mem[gold_addr];

                // Compute error
                abs_error = (gold_val >= out_val) ? (gold_val - out_val) : (out_val - gold_val);

                if (abs_error > 256) begin
                    mismatch_count = mismatch_count + 1;
                    if (mismatch_count <= 5) begin
                        $display("  MISMATCH at test %0d, lane %0d: got %04x, expected %04x (error=%0d)",
                                 test_num, i, out_val, gold_val, abs_error);
                    end
                    if (abs_error > max_error) max_error = abs_error;
                end
            end
            $display("  [debug] Comparison for test %0d done", test_num);
        end

        $display("\n=== IN_PROJECTION TEST RESULT (1 sample, sampled from 2000 total) ===");
        $display("Compared: 1 sample × 128 lane = 128 values");
        $display("Mismatches (>|256|): %0d / 128", mismatch_count);
        if (mismatch_count == 0) begin
            $display("✓ PASS: All values matched!");
        end else begin
            $display("✗ FAIL: %0d mismatches detected (max error: %0d)", mismatch_count, max_error);
        end
        $display("================================\n");

        #100 $finish;
    end

    always #5 clk = ~clk;

endmodule
