`timescale 1ns/1ps

module tb_softplus_unit_pwl;
    localparam integer N = 1024;
    reg clk;
    reg signed [15:0] in_data;
    wire signed [15:0] out_data;
    reg signed [15:0] input_mem [0:N-1];
    integer i;
    integer fd;

    Softplus_Unit_PWL dut (
        .clk(clk),
        .in_data(in_data),
        .out_data(out_data)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        in_data = 16'sd0;
        $readmemh("input.mem", input_mem);
        fd = $fopen("rtl_output.mem", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open rtl_output.mem");
            $finish;
        end

        @(posedge clk);
        for (i = 0; i < N + 1; i = i + 1) begin
            if (i < N) in_data <= input_mem[i];
            else in_data <= 16'sd0;
            @(posedge clk);
            if (i >= 1) $fdisplay(fd, "%04h", out_data);
        end
        $fclose(fd);
        $finish;
    end
endmodule
