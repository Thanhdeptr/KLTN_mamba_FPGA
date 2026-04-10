`timescale 1ns/1ps

module tb_unified_pe;
    localparam integer N = 512;

    reg clk;
    reg reset;
    reg [1:0] op_mode;
    reg clear_acc;
    reg signed [15:0] in_A;
    reg signed [15:0] in_B;
    wire signed [15:0] out_val;

    reg [1:0] op_mem [0:N-1];
    reg clr_mem [0:N-1];
    reg signed [15:0] a_mem [0:N-1];
    reg signed [15:0] b_mem [0:N-1];
    integer i;
    integer fd;

    Unified_PE dut (
        .clk(clk),
        .reset(reset),
        .op_mode(op_mode),
        .clear_acc(clear_acc),
        .in_A(in_A),
        .in_B(in_B),
        .out_val(out_val)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        op_mode = 2'b00;
        clear_acc = 1'b0;
        in_A = 16'sd0;
        in_B = 16'sd0;

        $readmemh("op_mode.mem", op_mem);
        $readmemh("clear_acc.mem", clr_mem);
        $readmemh("in_a.mem", a_mem);
        $readmemh("in_b.mem", b_mem);

        fd = $fopen("rtl_output.mem", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open rtl_output.mem");
            $finish;
        end

        repeat (2) @(posedge clk);
        reset <= 1'b0;

        for (i = 0; i < N; i = i + 1) begin
            op_mode <= op_mem[i];
            clear_acc <= clr_mem[i];
            in_A <= a_mem[i];
            in_B <= b_mem[i];
            @(posedge clk);
            #1;
            $fdisplay(fd, "%04h", out_val);
        end

        $fclose(fd);
        $finish;
    end
endmodule
