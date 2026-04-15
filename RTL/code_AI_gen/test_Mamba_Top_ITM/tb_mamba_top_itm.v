`timescale 1ns/1ps

// Mamba_Top with mode_select=5: ITM uses internal 16x Unified_PE (mux + register slice).
module tb_mamba_top_itm;
    reg clk;
    reg reset;
    reg [2:0] mode_select;

    // Linear (idle)
    reg lin_start;
    reg lin_en;
    reg [15:0] lin_len;
    wire lin_done;
    reg signed [15:0] lin_x_val;
    reg signed [16*16-1:0] lin_W_vals;
    reg signed [16*16-1:0] lin_bias_vals;
    wire signed [16*16-1:0] lin_y_out;

    // Conv1D (idle)
    reg conv_start;
    reg conv_valid_in;
    reg conv_en;
    wire conv_valid_out;
    wire conv_ready_in;
    reg signed [16*16-1:0] conv_x_vec;
    reg signed [16*4*16-1:0] conv_w_vec;
    reg signed [16*16-1:0] conv_b_vec;
    wire signed [16*16-1:0] conv_y_vec;

    // Scan (idle)
    reg scan_start;
    reg scan_en;
    reg scan_clear_h;
    wire scan_done;
    reg signed [15:0] scan_delta_val;
    reg signed [15:0] scan_x_val;
    reg signed [15:0] scan_D_val;
    reg signed [15:0] scan_gate_val;
    reg signed [16*16-1:0] scan_A_vec;
    reg signed [16*16-1:0] scan_B_vec;
    reg signed [16*16-1:0] scan_C_vec;
    wire signed [15:0] scan_y_out;

    // Softplus (tie-off)
    reg signed [15:0] softplus_in_val;
    wire signed [15:0] softplus_out_val;

    // ITM
    reg itm_start;
    reg itm_en;
    wire itm_done;
    wire itm_valid_out;
    wire signed [16*16-1:0] itm_out_vec;

    reg signed [15:0] feat_arr [0:15];
    reg signed [15:0] b_arr [0:15];
    reg signed [15:0] w_arr [0:63];
    reg signed [15:0] A_arr [0:15];
    reg signed [15:0] B_arr [0:15];
    reg signed [15:0] C_arr [0:15];
    reg signed [15:0] scalar_arr [0:3];

    reg signed [16*16-1:0] itm_feat_vec;
    reg signed [16*4*16-1:0] itm_conv_w_vec;
    reg signed [16*16-1:0] itm_conv_b_vec;
    reg signed [16*16-1:0] itm_scan_A_vec;
    reg signed [16*16-1:0] itm_scan_B_vec;
    reg signed [16*16-1:0] itm_scan_C_vec;
    reg signed [15:0] itm_scan_delta_val;
    reg signed [15:0] itm_scan_x_val;
    reg signed [15:0] itm_scan_D_val;
    reg signed [15:0] itm_scan_gate_val;
    reg itm_scan_clear_h;

    integer i;
    integer fd;
    integer timeout_cnt;

    Mamba_Top dut (
        .clk(clk),
        .reset(reset),
        .mode_select(mode_select),
        .lin_start(lin_start),
        .lin_en(lin_en),
        .lin_len(lin_len),
        .lin_done(lin_done),
        .lin_x_val(lin_x_val),
        .lin_W_vals(lin_W_vals),
        .lin_bias_vals(lin_bias_vals),
        .lin_y_out(lin_y_out),
        .conv_start(conv_start),
        .conv_valid_in(conv_valid_in),
        .conv_en(conv_en),
        .conv_valid_out(conv_valid_out),
        .conv_ready_in(conv_ready_in),
        .conv_x_vec(conv_x_vec),
        .conv_w_vec(conv_w_vec),
        .conv_b_vec(conv_b_vec),
        .conv_y_vec(conv_y_vec),
        .scan_start(scan_start),
        .scan_en(scan_en),
        .scan_clear_h(scan_clear_h),
        .scan_done(scan_done),
        .scan_delta_val(scan_delta_val),
        .scan_x_val(scan_x_val),
        .scan_D_val(scan_D_val),
        .scan_gate_val(scan_gate_val),
        .scan_A_vec(scan_A_vec),
        .scan_B_vec(scan_B_vec),
        .scan_C_vec(scan_C_vec),
        .scan_y_out(scan_y_out),
        .softplus_in_val(softplus_in_val),
        .softplus_out_val(softplus_out_val),
        .itm_start(itm_start),
        .itm_en(itm_en),
        .itm_done(itm_done),
        .itm_valid_out(itm_valid_out),
        .itm_out_vec(itm_out_vec),
        .itm_feat_vec(itm_feat_vec),
        .itm_conv_w_vec(itm_conv_w_vec),
        .itm_conv_b_vec(itm_conv_b_vec),
        .itm_scan_delta_val(itm_scan_delta_val),
        .itm_scan_x_val(itm_scan_x_val),
        .itm_scan_D_val(itm_scan_D_val),
        .itm_scan_gate_val(itm_scan_gate_val),
        .itm_scan_A_vec(itm_scan_A_vec),
        .itm_scan_B_vec(itm_scan_B_vec),
        .itm_scan_C_vec(itm_scan_C_vec),
        .itm_scan_clear_h(itm_scan_clear_h)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        mode_select = 3'd5;

        lin_start = 0;
        lin_en = 0;
        lin_len = 0;
        lin_x_val = 0;
        lin_W_vals = 0;
        lin_bias_vals = 0;

        conv_start = 0;
        conv_valid_in = 0;
        conv_en = 0;
        conv_x_vec = 0;
        conv_w_vec = 0;
        conv_b_vec = 0;

        scan_start = 0;
        scan_en = 0;
        scan_clear_h = 0;
        scan_delta_val = 0;
        scan_x_val = 0;
        scan_D_val = 0;
        scan_gate_val = 0;
        scan_A_vec = 0;
        scan_B_vec = 0;
        scan_C_vec = 0;

        softplus_in_val = 0;

        itm_start = 0;
        itm_en = 1;
        itm_scan_clear_h = 0;
        itm_feat_vec = 0;
        itm_conv_w_vec = 0;
        itm_conv_b_vec = 0;
        itm_scan_A_vec = 0;
        itm_scan_B_vec = 0;
        itm_scan_C_vec = 0;
        itm_scan_delta_val = 0;
        itm_scan_x_val = 0;
        itm_scan_D_val = 0;
        itm_scan_gate_val = 0;

        $readmemh("feat_in.mem", feat_arr);
        $readmemh("bias.mem", b_arr);
        $readmemh("weights.mem", w_arr);
        $readmemh("scalar_input.mem", scalar_arr);
        $readmemh("A_vec.mem", A_arr);
        $readmemh("B_vec.mem", B_arr);
        $readmemh("C_vec.mem", C_arr);

        for (i = 0; i < 16; i = i + 1) begin
            itm_feat_vec[i*16 +: 16] = feat_arr[i];
            itm_conv_b_vec[i*16 +: 16] = b_arr[i];
            itm_scan_A_vec[i*16 +: 16] = A_arr[i];
            itm_scan_B_vec[i*16 +: 16] = B_arr[i];
            itm_scan_C_vec[i*16 +: 16] = C_arr[i];
        end
        for (i = 0; i < 64; i = i + 1) begin
            itm_conv_w_vec[i*16 +: 16] = w_arr[i];
        end

        itm_scan_delta_val = scalar_arr[0];
        itm_scan_x_val = scalar_arr[1];
        itm_scan_D_val = scalar_arr[2];
        itm_scan_gate_val = scalar_arr[3];

        fd = $fopen("rtl_output.mem", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open rtl_output.mem");
            $finish;
        end

        repeat (3) @(posedge clk);
        reset <= 0;
        @(posedge clk);

        itm_start <= 1;
        @(posedge clk);
        itm_start <= 0;

        timeout_cnt = 0;
        while (itm_done == 0 && timeout_cnt < 2000) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        if (itm_done == 0) begin
            $display("ERROR: timeout waiting itm_done");
            $finish;
        end

        #1;
        for (i = 0; i < 16; i = i + 1) begin
            $fdisplay(fd, "%04h", itm_out_vec[i*16 +: 16]);
        end
        $fclose(fd);
        $finish;
    end
endmodule
