`timescale 1ns/1ps

// Testbench: ITM_Block + 16x Unified_PE (same integration style as Scan/Conv tests).
module tb_itm_block;
    reg clk;
    reg reset;
    reg itm_start;
    reg itm_en;
    wire itm_done;
    wire itm_valid_out;

    reg signed [15:0] feat_arr [0:15];
    reg signed [15:0] b_arr [0:15];
    reg signed [15:0] w_arr [0:63];
    reg signed [15:0] A_arr [0:15];
    reg signed [15:0] B_arr [0:15];
    reg signed [15:0] C_arr [0:15];
    reg signed [15:0] scalar_arr [0:3];

    reg signed [16*16-1:0] feat_in_vec;
    reg signed [16*4*16-1:0] conv_w_vec;
    reg signed [16*16-1:0] conv_b_vec;
    reg signed [16*16-1:0] scan_A_vec;
    reg signed [16*16-1:0] scan_B_vec;
    reg signed [16*16-1:0] scan_C_vec;

    reg signed [15:0] scan_delta_val;
    reg signed [15:0] scan_x_val;
    reg signed [15:0] scan_D_val;
    reg signed [15:0] scan_gate_val;
    reg scan_clear_h;

    wire signed [16*16-1:0] itm_out_vec;

    wire [1:0] pe_op_mode_out;
    wire pe_clear_out;
    wire [16*16-1:0] pe_in_a_vec;
    wire [16*16-1:0] pe_in_b_vec;
    wire [16*16-1:0] pe_result_vec;

    integer i;
    integer fd;
    integer timeout_cnt;

    ITM_Block dut (
        .clk(clk),
        .reset(reset),
        .itm_start(itm_start),
        .itm_en(itm_en),
        .itm_done(itm_done),
        .itm_valid_out(itm_valid_out),
        .itm_out_vec(itm_out_vec),
        .feat_in_vec(feat_in_vec),
        .conv_w_vec(conv_w_vec),
        .conv_b_vec(conv_b_vec),
        .scan_delta_val(scan_delta_val),
        .scan_x_val(scan_x_val),
        .scan_D_val(scan_D_val),
        .scan_gate_val(scan_gate_val),
        .scan_A_vec(scan_A_vec),
        .scan_B_vec(scan_B_vec),
        .scan_C_vec(scan_C_vec),
        .scan_clear_h(scan_clear_h),
        .pe_op_mode_out(pe_op_mode_out),
        .pe_clear_out(pe_clear_out),
        .pe_in_a_vec(pe_in_a_vec),
        .pe_in_b_vec(pe_in_b_vec),
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
        clk = 0;
        reset = 1;
        itm_start = 0;
        itm_en = 1;
        scan_clear_h = 0;
        feat_in_vec = 0;
        conv_w_vec = 0;
        conv_b_vec = 0;
        scan_A_vec = 0;
        scan_B_vec = 0;
        scan_C_vec = 0;
        scan_delta_val = 0;
        scan_x_val = 0;
        scan_D_val = 0;
        scan_gate_val = 0;

        $readmemh("feat_in.mem", feat_arr);
        $readmemh("bias.mem", b_arr);
        $readmemh("weights.mem", w_arr);
        $readmemh("scalar_input.mem", scalar_arr);
        $readmemh("A_vec.mem", A_arr);
        $readmemh("B_vec.mem", B_arr);
        $readmemh("C_vec.mem", C_arr);

        for (i = 0; i < 16; i = i + 1) begin
            feat_in_vec[i*16 +: 16] = feat_arr[i];
            conv_b_vec[i*16 +: 16] = b_arr[i];
            scan_A_vec[i*16 +: 16] = A_arr[i];
            scan_B_vec[i*16 +: 16] = B_arr[i];
            scan_C_vec[i*16 +: 16] = C_arr[i];
        end
        for (i = 0; i < 64; i = i + 1) begin
            conv_w_vec[i*16 +: 16] = w_arr[i];
        end

        scan_delta_val = scalar_arr[0];
        scan_x_val = scalar_arr[1];
        scan_D_val = scalar_arr[2];
        scan_gate_val = scalar_arr[3];

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
        while (itm_done == 0 && timeout_cnt < 600) begin
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
