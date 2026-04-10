`timescale 1ns/1ps

module tb_linear_layer;
    reg clk, reset, start, en;
    wire done;
    reg signed [15:0] x_val;
    reg signed [16*16-1:0] W_row_vals;
    reg signed [16*16-1:0] bias_vals;
    wire [16*16-1:0] y_out;
    wire [1:0] pe_op_mode_out;
    wire pe_clear_acc_out;
    wire [16*16-1:0] pe_in_a_vec, pe_in_b_vec, pe_result_vec;
    reg [15:0] len;

    reg signed [15:0] w_arr [0:15];
    reg signed [15:0] b_arr [0:15];
    reg signed [15:0] x_arr [0:0];
    integer i;
    integer fd;
    integer timeout_cnt;

    Linear_Layer dut (
        .clk(clk), .reset(reset), .start(start), .len(len), .en(en), .done(done),
        .x_val(x_val), .W_row_vals(W_row_vals), .bias_vals(bias_vals),
        .y_out(y_out), .pe_op_mode_out(pe_op_mode_out), .pe_clear_acc_out(pe_clear_acc_out),
        .pe_in_a_vec(pe_in_a_vec), .pe_in_b_vec(pe_in_b_vec), .pe_result_vec(pe_result_vec)
    );

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : pe_gen
            Unified_PE u_pe (
                .clk(clk),
                .reset(reset),
                .op_mode(pe_op_mode_out),
                .clear_acc(pe_clear_acc_out),
                .in_A(pe_in_a_vec[g*16 +: 16]),
                .in_B(pe_in_b_vec[g*16 +: 16]),
                .out_val(pe_result_vec[g*16 +: 16])
            );
        end
    endgenerate

    always #5 clk = ~clk;

    initial begin
        clk = 0; reset = 1; start = 0; en = 1; len = 16'd1;
        x_val = 0; W_row_vals = 0; bias_vals = 0;
        $readmemh("W_row.mem", w_arr);
        $readmemh("bias.mem", b_arr);
        $readmemh("x_val.mem", x_arr);
        x_val = x_arr[0];
        for (i = 0; i < 16; i = i + 1) begin
            W_row_vals[i*16 +: 16] = w_arr[i];
            bias_vals[i*16 +: 16] = b_arr[i];
        end

        fd = $fopen("rtl_output.mem", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open rtl_output.mem");
            $finish;
        end

        repeat (3) @(posedge clk);
        reset <= 0;
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        timeout_cnt = 0;
        while (done == 0 && timeout_cnt < 200) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        if (done == 0) begin
            $display("ERROR: timeout waiting done");
            $finish;
        end

        #1;
        for (i = 0; i < 16; i = i + 1) begin
            $fdisplay(fd, "%04h", y_out[i*16 +: 16]);
        end
        $fclose(fd);
        $finish;
    end
endmodule
