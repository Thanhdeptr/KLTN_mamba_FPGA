`timescale 1ns/1ps
`include "_parameter.v"

module tb_rmsnorm_unit;

    reg clk = 0;
    reg reset = 1;
    reg start = 0;
    reg en = 0;

    reg [64*`DATA_WIDTH-1:0] x_vec;
    reg [64*`DATA_WIDTH-1:0] gamma_vec;

    wire done;
    wire [64*`DATA_WIDTH-1:0] y_vec;

    integer i;
    integer fd_out;
    reg [15:0] x_mem [0:63];
    reg [15:0] w_mem [0:63];

    RMSNorm_Unit_IntSqrt dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .en(en),
        .done(done),
        .x_vec(x_vec),
        .gamma_vec(gamma_vec),
        .y_vec(y_vec)
    );

    always #5 clk = ~clk;

    initial begin
        $readmemh("input.mem", x_mem);
        $readmemh("weight.mem", w_mem);

        x_vec = 0;
        gamma_vec = 0;
        for (i = 0; i < 64; i = i + 1) begin
            x_vec[i*16 +: 16] = x_mem[i];
            gamma_vec[i*16 +: 16] = w_mem[i];
        end

        #20;
        reset = 0;
        en = 1;
        start = 1;
        #10;
        start = 0;

        wait(done == 1'b1);

        fd_out = $fopen("rtl_output.mem", "w");
        for (i = 0; i < 64; i = i + 1) begin
            $fdisplay(fd_out, "%04h", y_vec[i*16 +: 16]);
        end
        $fclose(fd_out);

        #20;
        $finish;
    end

endmodule
