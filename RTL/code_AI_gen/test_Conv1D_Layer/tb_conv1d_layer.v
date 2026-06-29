`timescale 1ns/1ps
// Unit test: Conv1D_Layer vs real-model vectors from test_Conv1D&Silu.
// Dumps post-SiLU (y_out_vec) and pre-SiLU (silu_in_hold) for two-step compare.

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

    integer i;
    integer fd_silu;
    integer fd_pre;
    integer timeout_cnt;

    Conv1D_Layer dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .en(en),
        .valid_in(valid_in),
        .path_x(1'b1),
        .grp_idx(4'd0),
        .token_idx(16'd0),
        .valid_out(valid_out),
        .x_valid_out(),
        .z_valid_out(),
        .ready_in(ready_in),
        .x_in_vec(x_in_vec),
        .weights_vec(weights_vec),
        .bias_vec(bias_vec),
        .conv_w_packed({(`D_INNER*4*`DATA_WIDTH){1'b0}}),
        .conv_b_packed({(`D_INNER*`DATA_WIDTH){1'b0}}),
        .y_out_vec(y_out_vec),
        .z_out_vec(),
        .x_capture_cnt(),
        .z_capture_cnt()
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        start = 0;
        en = 1;
        valid_in = 0;
        x_in_vec = 0;
        weights_vec = 0;
        bias_vec = 0;

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

        fd_silu = $fopen("rtl_output.mem", "w");
        fd_pre  = $fopen("rtl_pre_silu.mem", "w");
        if (fd_silu == 0 || fd_pre == 0) begin
            $display("ERROR: cannot open rtl output files");
            $finish;
        end

        repeat (3) @(posedge clk);
        reset <= 0;

        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        wait (ready_in == 1'b1);
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

        // Sample one cycle after valid_out: y_out_vec and silu_in_hold are stable
        @(posedge clk);
        for (i = 0; i < 16; i = i + 1) begin
            $fdisplay(fd_silu, "%04h", y_out_vec[i*16 +: 16]);
            $fdisplay(fd_pre, "%04h", dut.silu_in_hold[i]);
        end
        $fclose(fd_silu);
        $fclose(fd_pre);
        $finish;
    end
endmodule
