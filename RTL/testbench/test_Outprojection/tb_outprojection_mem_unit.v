`timescale 1ns/1ps

module tb_outprojection_mem_unit;
    localparam DATA_WIDTH = 16;
    localparam D_IN       = 128;
    localparam D_OUT      = 64;
    localparam N_TOKENS   = 1000;
    localparam FLOAT_GOLDEN_TOL_DFT = 4;

    reg clk;
    reg reset;
    reg start;
    reg en;
    wire done;

    reg  [D_IN*DATA_WIDTH-1:0] x_vec;
    reg  [D_OUT*D_IN*DATA_WIDTH-1:0] w_matrix;
    wire [D_OUT*DATA_WIDTH-1:0] y_vec;

    reg [DATA_WIDTH-1:0] input_mem       [0:D_IN-1];
    reg [DATA_WIDTH-1:0] golden_mem      [0:D_OUT-1];
    reg [DATA_WIDTH-1:0] input_full_mem  [0:N_TOKENS*D_IN-1];
    reg [DATA_WIDTH-1:0] golden_full_mem [0:N_TOKENS*D_OUT-1];
    reg [DATA_WIDTH-1:0] weight_mem      [0:D_OUT*D_IN-1];

    integer tok, i, idx;
    integer run_full;
    integer float_golden_tol;
    integer mismatch_single_fixed;
    integer mismatch_full_fixed;
    integer mismatch_single_float;
    integer mismatch_full_float;
    integer compared_single;
    integer compared_full;
    integer got_i;
    integer exp_i;
    integer abs_err;
    integer col;
    reg signed [47:0] acc;
    reg signed [31:0] prod;
    reg signed [15:0] x_val;
    reg signed [15:0] w_val;
    reg signed [15:0] exp_fixed;
    reg signed [47:0] scaled;

    Out_Projection_Unit dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .en(en),
        .done(done),
        .x_vec(x_vec),
        .w_matrix(w_matrix),
        .y_vec(y_vec)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        start = 1'b0;
        en = 1'b0;
        x_vec = {D_IN*DATA_WIDTH{1'b0}};
        w_matrix = {D_OUT*D_IN*DATA_WIDTH{1'b0}};
        mismatch_single_fixed = 0;
        mismatch_full_fixed = 0;
        mismatch_single_float = 0;
        mismatch_full_float = 0;
        compared_single = 0;
        compared_full = 0;
        run_full = 0;
        float_golden_tol = FLOAT_GOLDEN_TOL_DFT;

        if ($test$plusargs("RUN_FULL"))
            run_full = 1;
        if (!$value$plusargs("FLOAT_TOL=%d", float_golden_tol))
            float_golden_tol = FLOAT_GOLDEN_TOL_DFT;

        // Load the exact mem files requested by user.
        $readmemh("input.mem", input_mem);
        $readmemh("weight.mem", weight_mem);
        $readmemh("input_full.mem", input_full_mem);
        $readmemh("golden_output.mem", golden_mem);
        $readmemh("golden_output_full.mem", golden_full_mem);

        for (i = 0; i < D_OUT*D_IN; i = i + 1) begin
            w_matrix[i*DATA_WIDTH +: DATA_WIDTH] = weight_mem[i];
        end

        #20;
        reset = 1'b0;
        en = 1'b1;
        start = 1'b1;
        #10;
        start = 1'b0;

        // Single-token check
        for (i = 0; i < D_IN; i = i + 1) begin
            x_vec[i*DATA_WIDTH +: DATA_WIDTH] = input_mem[i];
        end
        #1;
        for (i = 0; i < D_OUT; i = i + 1) begin
            compared_single = compared_single + 1;
            got_i = $signed(y_vec[i*DATA_WIDTH +: DATA_WIDTH]);

            acc = 48'sd0;
            for (col = 0; col < D_IN; col = col + 1) begin
                x_val = input_mem[col];
                w_val = weight_mem[i*D_IN + col];
                prod = $signed(x_val) * $signed(w_val);
                acc = acc + $signed(prod);
            end
            scaled = acc >>> 12;
            if (scaled > 32'sd32767)
                exp_fixed = 16'sh7fff;
            else if (scaled < -32'sd32768)
                exp_fixed = 16'sh8000;
            else
                exp_fixed = scaled[15:0];

            if (got_i !== exp_fixed) begin
                mismatch_single_fixed = mismatch_single_fixed + 1;
                if (mismatch_single_fixed <= 8) begin
                    $display("SINGLE FIXED MISMATCH lane=%0d got=%h exp=%h",
                             i, y_vec[i*DATA_WIDTH +: DATA_WIDTH], exp_fixed);
                end
            end

            exp_i = $signed(golden_mem[i]);
            abs_err = (got_i >= exp_i) ? (got_i - exp_i) : (exp_i - got_i);
            if (abs_err > float_golden_tol) begin
                mismatch_single_float = mismatch_single_float + 1;
                if (mismatch_single_float <= 8) begin
                    $display("SINGLE FLOAT-GOLDEN DRIFT lane=%0d got=%h golden=%h err=%0d",
                             i, y_vec[i*DATA_WIDTH +: DATA_WIDTH], golden_mem[i], abs_err);
                end
            end
        end

        // Full-token check (1000 tokens), enabled with +RUN_FULL.
        if (run_full) begin
            for (tok = 0; tok < N_TOKENS; tok = tok + 1) begin
                for (i = 0; i < D_IN; i = i + 1) begin
                    idx = i*N_TOKENS + tok;
                    x_vec[i*DATA_WIDTH +: DATA_WIDTH] = input_full_mem[idx];
                end
                #1;
                for (i = 0; i < D_OUT; i = i + 1) begin
                    idx = tok*D_OUT + i;
                    compared_full = compared_full + 1;
                    got_i = $signed(y_vec[i*DATA_WIDTH +: DATA_WIDTH]);

                    acc = 48'sd0;
                    for (col = 0; col < D_IN; col = col + 1) begin
                        idx = col*N_TOKENS + tok;
                        x_val = input_full_mem[idx];
                        w_val = weight_mem[i*D_IN + col];
                        prod = $signed(x_val) * $signed(w_val);
                        acc = acc + $signed(prod);
                    end
                    scaled = acc >>> 12;
                    if (scaled > 32'sd32767)
                        exp_fixed = 16'sh7fff;
                    else if (scaled < -32'sd32768)
                        exp_fixed = 16'sh8000;
                    else
                        exp_fixed = scaled[15:0];

                    if (got_i !== exp_fixed) begin
                        mismatch_full_fixed = mismatch_full_fixed + 1;
                        if (mismatch_full_fixed <= 8) begin
                            $display("FULL FIXED MISMATCH tok=%0d lane=%0d got=%h exp=%h",
                                     tok, i, y_vec[i*DATA_WIDTH +: DATA_WIDTH], exp_fixed);
                        end
                    end

                    idx = tok*D_OUT + i;
                    exp_i = $signed(golden_full_mem[idx]);
                    abs_err = (got_i >= exp_i) ? (got_i - exp_i) : (exp_i - got_i);
                    if (abs_err > float_golden_tol) begin
                        mismatch_full_float = mismatch_full_float + 1;
                        if (mismatch_full_float <= 8) begin
                            $display("FULL FLOAT-GOLDEN DRIFT tok=%0d lane=%0d got=%h golden=%h err=%0d",
                                     tok, i, y_vec[i*DATA_WIDTH +: DATA_WIDTH], golden_full_mem[idx], abs_err);
                        end
                    end
                end
            end
        end

        $display("");
        $display("=== OutProjection MEM Unit Test ===");
        $display("mode=%s float_golden_tol=%0d",
                 run_full ? "single+full" : "single-only", float_golden_tol);
        $display("single fixed_mismatch=%0d float_drift(>%0d)=%0d",
                 mismatch_single_fixed, float_golden_tol, mismatch_single_float);
        $display("full   fixed_mismatch=%0d float_drift(>%0d)=%0d",
                 mismatch_full_fixed, float_golden_tol, mismatch_full_float);
        if ((mismatch_single_fixed == 0) && (!run_full || (mismatch_full_fixed == 0))) begin
            $display("PASS: RTL matches fixed-point reference.");
        end else begin
            $display("FAIL: RTL does not match fixed-point reference.");
        end
        $display("===================================");
        $display("");

        #10;
        $finish;
    end

endmodule
