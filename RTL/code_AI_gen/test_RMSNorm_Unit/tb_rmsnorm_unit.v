`timescale 1ns/1ps
`include "_parameter.v"

module tb_rmsnorm_unit;

`ifdef RMSNORM_FULL_RUN
    localparam integer NUM_VECTORS = 1000;
    localparam integer TOTAL_SAMPLES = NUM_VECTORS * 64;
`else
    localparam integer NUM_VECTORS = 1;
    localparam integer TOTAL_SAMPLES = 64;
`endif

    reg clk = 0;
    reg reset = 1;
    reg start = 0;
    reg en = 0;

    reg [64*`DATA_WIDTH-1:0] x_vec;
    reg [64*`DATA_WIDTH-1:0] gamma_vec;

    wire done;
    wire [64*`DATA_WIDTH-1:0] y_vec;

    integer i, v;
    integer fd_out;
    reg [15:0] x_mem [0:TOTAL_SAMPLES-1];
    reg [15:0] w_mem [0:63];

    integer global_clk;
    integer lat_start_clk;
    integer lat_end_clk;
    integer vec_latency_clk;

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

    always @(posedge clk or posedge reset) begin
        if (reset)
            global_clk <= 0;
        else
            global_clk <= global_clk + 1;
    end

    initial begin
`ifdef RMSNORM_FULL_RUN
        $readmemh("input_full.mem", x_mem);
        fd_out = $fopen("rtl_output_full.mem", "w");
`else
        $readmemh("input.mem", x_mem);
        fd_out = $fopen("rtl_output.mem", "w");
`endif
        $readmemh("weight.mem", w_mem);

        gamma_vec = 0;
        for (i = 0; i < 64; i = i + 1)
            gamma_vec[i*16 +: 16] = w_mem[i];

        #20;
        reset = 0;
        en = 1;

        for (v = 0; v < NUM_VECTORS; v = v + 1) begin
            x_vec = 0;
            for (i = 0; i < 64; i = i + 1)
                x_vec[i*16 +: 16] = x_mem[v*64 + i];

            @(posedge clk);
            start = 1;
            @(posedge clk);
            lat_start_clk = global_clk;
            start = 0;

            wait(done == 1'b1);
            @(posedge clk);
            lat_end_clk = global_clk;
            vec_latency_clk = lat_end_clk - lat_start_clk + 1;

            if (v == 0) begin
                $display("TB: 64 outputs latency = %0d clk cycles (start posedge -> done posedge)",
                         vec_latency_clk);
            end

            for (i = 0; i < 64; i = i + 1)
                $fdisplay(fd_out, "%04h", y_vec[i*16 +: 16]);
            $fflush(fd_out);

            if ((v % 100) == 0)
                $display("TB: vector %0d / %0d done", v, NUM_VECTORS);
        end

        $fclose(fd_out);
        $display("TB: wrote %0d samples", NUM_VECTORS * 64);

        #20;
        $finish;
    end

endmodule
