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
    reg [15:0] weight_matrix_1 [0:8191];    // 128x64
    reg [15:0] weight_matrix_2 [0:8191];    // 128x64
    reg [15:0] golden_output_mem [0:255];   // 256 values (128 from w1 + 128 from w2 expected)
    
    // RTL output: store results from both weight matrices
    reg [15:0] rtl_output_combined [0:255];  // 256 output values (128 from w1 + 128 from w2)

    integer i, test_num, mismatch_count, max_error, error;
    integer gold_addr, out_addr, rtl_out_idx;
    reg [15:0] gold_val, out_val;
    integer abs_error;
    
    // File handle to write rtl_output.mem
    integer rtl_output_file;

    initial begin
        $readmemh("input.mem", input_mem);
        $readmemh("weight_1.mem", weight_matrix_1);
        $readmemh("weight_2.mem", weight_matrix_2);
        $readmemh("golden_output.mem", golden_output_mem);
        
        clk = 0;
        reset = 1;
        start = 0;
        en = 0;
        mismatch_count = 0;
        max_error = 0;
        rtl_out_idx = 0;
        
        #100 reset = 0;
        #100;

        // Load input into x_vec register
        for (i = 0; i < 64; i = i + 1) begin
            x_vec[i*16 +: 16] = input_mem[i];
        end

        $display("[tb_in_projection] Starting combined weight test (weight_1 + weight_2)...");
        $display("  Input loaded: 64-dim vector");

        // ============================================================
        // TEST 1: Run with weight_1
        // ============================================================
        $display("\n[STAGE 1] Running with weight_1 (128x64 matrix)");
        
        // Load weight_1 into w_matrix register
        for (i = 0; i < 8192; i = i + 1) begin
            w_matrix[i*16 +: 16] = weight_matrix_1[i];
        end

        // Trigger module
        start = 1;
        en = 1;
        #10;
        start = 0;
        #20;

        // Collect output: y_vec[0:127] → rtl_output_combined[0:127]
        for (i = 0; i < 128; i = i + 1) begin
            rtl_output_combined[i] = y_vec[i*16 +: 16];
        end
        $display("  Stage 1 done: collected 128 outputs from weight_1");

        // ============================================================
        // TEST 2: Run with weight_2
        // ============================================================
        $display("\n[STAGE 2] Running with weight_2 (128x64 matrix)");
        
        // Load weight_2 into w_matrix register
        for (i = 0; i < 8192; i = i + 1) begin
            w_matrix[i*16 +: 16] = weight_matrix_2[i];
        end

        // Trigger module again
        start = 1;
        en = 1;
        #10;
        start = 0;
        #20;

        // Collect output: y_vec[0:127] → rtl_output_combined[128:255]
        for (i = 0; i < 128; i = i + 1) begin
            rtl_output_combined[128 + i] = y_vec[i*16 +: 16];
        end
        $display("  Stage 2 done: collected 128 outputs from weight_2");

        // ============================================================
        // Write combined RTL output to file
        // ============================================================
        $display("\n[WRITE] Writing 256 combined outputs to rtl_output.mem...");
        rtl_output_file = $fopen("rtl_output.mem", "w");
        if (rtl_output_file == 0) begin
            $display("ERROR: Cannot open rtl_output.mem for writing");
            $finish;
        end
        
        for (i = 0; i < 256; i = i + 1) begin
            $fwrite(rtl_output_file, "%04x\n", rtl_output_combined[i]);
        end
        $fclose(rtl_output_file);
        $display("  Written 256 values to rtl_output.mem");

        // ============================================================
        // Compare: RTL output vs Golden output
        // ============================================================
        $display("\n[COMPARE] Comparing RTL output (256 val) vs Golden output...");
        mismatch_count = 0;
        max_error = 0;

        for (i = 0; i < 256; i = i + 1) begin
            out_val = rtl_output_combined[i];
            gold_val = golden_output_mem[i];  // Sample 0: 0-127 (w1), Sample 1: 128-255 (w2 expected)

            // Compute error
            abs_error = (gold_val >= out_val) ? (gold_val - out_val) : (out_val - gold_val);

            if (abs_error > 256) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 10) begin
                    $display("  MISMATCH at lane %3d: got %04x, expected %04x (error=%0d)",
                             i, out_val, gold_val, abs_error);
                end
                if (abs_error > max_error) max_error = abs_error;
            end
        end

        $display("\n=== IN_PROJECTION TEST RESULT (2-Weight Combined) ===");
        $display("Tested: weight_1 → 128 outputs + weight_2 → 128 outputs = 256 total");
        $display("Mismatches (>|256|): %0d / 256", mismatch_count);
        if (mismatch_count == 0) begin
            $display("✓ PASS: All 256 values matched!");
        end else begin
            $display("✗ FAIL: %0d mismatches detected (max error: %0d)", mismatch_count, max_error);
        end
        $display("Output written to: rtl_output.mem");
        $display("================================\n");

        #100 $finish;
    end

    always #5 clk = ~clk;

endmodule
