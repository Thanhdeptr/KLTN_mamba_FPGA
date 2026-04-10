`timescale 1ns/1ps

module tb_silu_unit_pwl;
    localparam integer TOTAL_SAMPLES = 131072;
    localparam integer MAX_TEST_SAMPLES = 4096;

    reg clk;
    reg signed [`DATA_WIDTH-1:0] in_data;
    wire signed [`DATA_WIDTH-1:0] out_data;

    reg signed [`DATA_WIDTH-1:0] input_mem [0:TOTAL_SAMPLES-1];
    integer i;
    integer out_fd;

    SiLU_Unit_PWL dut (
        .clk(clk),
        .in_data(in_data),
        .out_data(out_data)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        in_data = 16'sd0;
        $readmemh("input.mem", input_mem);

        out_fd = $fopen("rtl_output.mem", "w");
        if (out_fd == 0) begin
            $display("ERROR: cannot open rtl_output.mem");
            $finish;
        end

        @(posedge clk);
        for (i = 0; i < MAX_TEST_SAMPLES + 2; i = i + 1) begin
            if (i < MAX_TEST_SAMPLES) begin
                in_data <= input_mem[i];
            end else begin
                in_data <= 16'sd0;
            end
            @(posedge clk);
            if (i >= 1 && i <= MAX_TEST_SAMPLES) begin
                $fdisplay(out_fd, "%04h", out_data);
            end
        end

        $fclose(out_fd);
        $display("INFO: SiLU test done");
        $finish;
    end
endmodule
