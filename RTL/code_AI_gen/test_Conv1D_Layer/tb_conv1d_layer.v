`timescale 1ns/1ps

module tb_conv1d_layer;
    reg clk, reset, start, en, valid_in;
    wire valid_out, ready_in;

    reg signed [15:0] x_arr [0:15];
    reg signed [15:0] b_arr [0:15];
    reg signed [15:0] w_arr [0:63];

    reg signed [16*16-1:0] x_in_vec;
    reg signed [16*4*16-1:0] weights_vec;
    reg signed [16*16-1:0] bias_vec;
    wire signed [16*16-1:0] y_out_vec;

    wire [1:0] pe_op_mode_out;
    wire pe_clear_out;
    wire [16*16-1:0] pe_in_a_vec;
    wire [16*16-1:0] pe_in_b_vec;
    wire [16*16-1:0] pe_result_vec;

    integer i;
    integer fd;
    integer timeout_cnt;

    Conv1D_Layer dut (
        .clk(clk), .reset(reset), .start(start), .en(en), .valid_in(valid_in),
        .valid_out(valid_out), .ready_in(ready_in),
        .x_in_vec(x_in_vec), .weights_vec(weights_vec), .bias_vec(bias_vec),
        .y_out_vec(y_out_vec),
        .pe_op_mode_out(pe_op_mode_out), .pe_clear_out(pe_clear_out),
        .pe_in_a_vec(pe_in_a_vec), .pe_in_b_vec(pe_in_b_vec),
        .pe_result_vec(pe_result_vec)
    );

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : pe_gen
            Unified_PE u_pe (
                .clk(clk),
                .reset(reset),
                .op_mode(pe_op_mode_out),
                .clear_acc(pe_clear_out),
                .in_A(pe_in_a_vec[g*16 +: 16]),
                .in_B(pe_in_b_vec[g*16 +: 16]),
                .out_val(pe_result_vec[g*16 +: 16])
            );
        end
    endgenerate

    always #5 clk = ~clk;

    initial begin
        clk = 0; reset = 1; start = 0; en = 1; valid_in = 0;
        x_in_vec = 0; weights_vec = 0; bias_vec = 0;

        $readmemh("x_in.mem", x_arr);
        $readmemh("bias.mem", b_arr);
        $readmemh("weights.mem", w_arr);

        for (i = 0; i < 16; i = i + 1) begin
            x_in_vec[i*16 +: 16] = x_arr[i];
            bias_vec[i*16 +: 16] = b_arr[i];
        end
        for (i = 0; i < 64; i = i + 1) begin
            weights_vec[i*16 +: 16] = w_arr[i];
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

        @(posedge clk);
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;

        timeout_cnt = 0;
        while (valid_out == 0 && timeout_cnt < 200) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        if (valid_out == 0) begin
            $display("ERROR: timeout waiting valid_out");
            $finish;
        end

        #1;
        for (i = 0; i < 16; i = i + 1) begin
            $fdisplay(fd, "%04h", y_out_vec[i*16 +: 16]);
        end
        $fclose(fd);
        $finish;
    end
endmodule
