`timescale 1ns/1ps

module tb_scan_core_engine;
    reg clk, reset, start, en, clear_h;
    reg signed [15:0] delta_val, x_val, D_val, gate_val;
    reg signed [15:0] A_arr [0:15];
    reg signed [15:0] B_arr [0:15];
    reg signed [15:0] C_arr [0:15];
    reg signed [16*16-1:0] A_vec, B_vec, C_vec;
    wire signed [15:0] y_out;
    wire done;

    wire [1:0] pe_op_mode_out;
    wire pe_clear_acc_out;
    wire [16*16-1:0] pe_in_a_vec, pe_in_b_vec;
    wire [16*16-1:0] pe_result_vec;

    integer i;
    integer fd;
    integer timeout_cnt;
    reg signed [15:0] scalar_arr [0:3];

    Scan_Core_Engine dut (
        .clk(clk), .reset(reset), .start(start), .en(en), .clear_h(clear_h), .done(done),
        .delta_val(delta_val), .x_val(x_val), .D_val(D_val), .gate_val(gate_val),
        .A_vec(A_vec), .B_vec(B_vec), .C_vec(C_vec), .y_out(y_out),
        .pe_op_mode_out(pe_op_mode_out), .pe_clear_acc_out(pe_clear_acc_out),
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
        clk = 0; reset = 1; start = 0; en = 1; clear_h = 0;
        delta_val = 0; x_val = 0; D_val = 0; gate_val = 0;
        A_vec = 0; B_vec = 0; C_vec = 0;

        $readmemh("scalar_input.mem", scalar_arr);
        $readmemh("A_vec.mem", A_arr);
        $readmemh("B_vec.mem", B_arr);
        $readmemh("C_vec.mem", C_arr);

        delta_val = scalar_arr[0];
        x_val = scalar_arr[1];
        D_val = scalar_arr[2];
        gate_val = scalar_arr[3];

        for (i = 0; i < 16; i = i + 1) begin
            A_vec[i*16 +: 16] = A_arr[i];
            B_vec[i*16 +: 16] = B_arr[i];
            C_vec[i*16 +: 16] = C_arr[i];
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
        $fdisplay(fd, "%04h", y_out);
        $fclose(fd);
        $finish;
    end
endmodule
