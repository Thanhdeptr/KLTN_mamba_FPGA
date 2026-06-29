`timescale 1ns/1ps
// Continuous stream unit test: 8 x-frames + 8 z-frames per token (128 clk beats).
// Beat order matches InProj v2 interleave: X0,Z0,X1,Z1,...,X7,Z7.

module tb_conv1d_stream_continuous;
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_INNER    = 128;
    localparam SEQ_LEN    = 1000;
`ifndef NUM_TOKENS
    localparam NUM_TOKENS = 1;
`else
    localparam NUM_TOKENS = `NUM_TOKENS;
`endif
    localparam FRAMES_PER_TOKEN = 16;
    localparam TOTAL_X_OUT = NUM_TOKENS * 8 * LANES;
    localparam TOTAL_Z_OUT = NUM_TOKENS * 8 * LANES;
    localparam BEAT_CLK    = 8;

    reg clk = 0;
    reg reset = 1;
    reg en = 1;
    reg start = 0;
    reg valid_in = 0;
    reg path_x = 1;
    reg [3:0] grp_idx = 0;
    reg [15:0] token_idx = 0;

    wire valid_out, x_valid_out, z_valid_out, ready_in;
    wire signed [LANES*DATA_WIDTH-1:0] y_out_vec, z_out_vec;

    reg signed [LANES*DATA_WIDTH-1:0] x_in_vec;
    reg signed [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed;
    reg signed [D_INNER*DATA_WIDTH-1:0] conv_b_packed;

    wire [15:0] x_capture_cnt, z_capture_cnt;

    reg [15:0] xbc_mem [0:D_INNER*SEQ_LEN-1];
    reg [15:0] xz_mem  [0:256*SEQ_LEN-1];
    reg [15:0] conv_w_mem [0:D_INNER*4-1];
    reg [15:0] conv_b_mem [0:D_INNER-1];

    reg [15:0] x_cap_mem [0:TOTAL_X_OUT-1];
    reg [15:0] z_cap_mem [0:TOTAL_Z_OUT-1];

    integer x_cap_idx, z_cap_idx;
    integer lane, beat, t, g;
    integer fp;

    Conv1D_Layer #(
        .FULL_WEIGHTS(1)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .en(en),
        .valid_in(valid_in),
        .path_x(path_x),
        .grp_idx(grp_idx),
        .token_idx(token_idx),
        .valid_out(valid_out),
        .x_valid_out(x_valid_out),
        .z_valid_out(z_valid_out),
        .ready_in(ready_in),
        .x_in_vec(x_in_vec),
        .weights_vec({(LANES*4*DATA_WIDTH){1'b0}}),
        .bias_vec({(LANES*DATA_WIDTH){1'b0}}),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .y_out_vec(y_out_vec),
        .z_out_vec(z_out_vec),
        .x_capture_cnt(x_capture_cnt),
        .z_capture_cnt(z_capture_cnt)
    );

    integer x_valid_in_cnt, x_valid_out_cnt;

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (valid_in && path_x)
            x_valid_in_cnt = x_valid_in_cnt + 1;
        if (x_valid_out)
            x_valid_out_cnt = x_valid_out_cnt + 1;
    end

    function integer xbc_index;
        input integer ch;
        input integer timestep;
        begin
            xbc_index = ch * SEQ_LEN + timestep;
        end
    endfunction

    function integer xz_index;
        input integer ch;
        input integer timestep;
        begin
            xz_index = timestep * 256 + ch;
        end
    endfunction

    task automatic load_frame_input;
        input integer timestep;
        input integer grp;
        integer li;
        begin
            for (li = 0; li < LANES; li = li + 1) begin
                if (grp < 8)
                    x_in_vec[li*DATA_WIDTH +: DATA_WIDTH] =
                        xbc_mem[xbc_index(grp * LANES + li, timestep)];
                else
                    x_in_vec[li*DATA_WIDTH +: DATA_WIDTH] =
                        xz_mem[xz_index(128 + (grp - 8) * LANES + li, timestep)];
            end
        end
    endtask

    always @(posedge clk) begin
        if (x_valid_out) begin
            for (lane = 0; lane < LANES; lane = lane + 1)
                x_cap_mem[x_cap_idx * LANES + lane] =
                    y_out_vec[lane*DATA_WIDTH +: DATA_WIDTH];
            x_cap_idx = x_cap_idx + 1;
        end
        if (z_valid_out) begin
            for (lane = 0; lane < LANES; lane = lane + 1)
                z_cap_mem[z_cap_idx * LANES + lane] =
                    z_out_vec[lane*DATA_WIDTH +: DATA_WIDTH];
            z_cap_idx = z_cap_idx + 1;
        end
    end

    initial begin
        x_valid_in_cnt = 0;
        x_valid_out_cnt = 0;
        x_cap_idx = 0;
        z_cap_idx = 0;

        $readmemh("/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_Conv1D&Silu/x_before_conv_full.mem", xbc_mem);
        $readmemh("/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_Inprojection/golden_output_full.mem", xz_mem);
        $readmemh("/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_Full_mamba_Branch/conv_weight.mem", conv_w_mem);
        $readmemh("/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_Full_mamba_Branch/conv_bias.mem", conv_b_mem);

        conv_w_packed = 0;
        conv_b_packed = 0;
        for (g = 0; g < D_INNER * 4; g = g + 1)
            conv_w_packed[g*DATA_WIDTH +: DATA_WIDTH] = conv_w_mem[g];
        for (g = 0; g < D_INNER; g = g + 1)
            conv_b_packed[g*DATA_WIDTH +: DATA_WIDTH] = conv_b_mem[g];

        #30;
        reset = 0;
        #20;
        start = 1;
        @(posedge clk);
        start = 0;

        for (t = 0; t < NUM_TOKENS; t = t + 1) begin
            token_idx = t;
            for (beat = 0; beat < FRAMES_PER_TOKEN; beat = beat + 1) begin
                path_x  = ~beat[0];
                grp_idx = beat[0] ? (4'd8 + beat[3:1]) : {1'b0, beat[3:1]};
                load_frame_input(t, grp_idx);
                valid_in = 1;
                @(posedge clk);
                while (ready_in !== 1'b1)
                    @(posedge clk);
                valid_in = 0;
                repeat (BEAT_CLK - 1) @(posedge clk);
            end
        end

        repeat (800) @(posedge clk);

        fp = $fopen("rtl_x_stream.mem", "w");
        for (g = 0; g < x_cap_idx * LANES; g = g + 1)
            $fwrite(fp, "%04x\n", x_cap_mem[g]);
        $fclose(fp);

        fp = $fopen("rtl_z_stream.mem", "w");
        for (g = 0; g < z_cap_idx * LANES; g = g + 1)
            $fwrite(fp, "%04x\n", z_cap_mem[g]);
        $fclose(fp);

        $display("=== Conv stream continuous N=%0d ===", NUM_TOKENS);
        $display("  x_captures=%0d (expect %0d)", x_cap_idx, NUM_TOKENS * 8);
        $display("  z_captures=%0d (expect %0d)", z_cap_idx, NUM_TOKENS * 8);
        $display("  x_valid_in=%0d x_valid_out=%0d", x_valid_in_cnt, x_valid_out_cnt);

        if (x_cap_idx != NUM_TOKENS * 8 || z_cap_idx != NUM_TOKENS * 8)
            $display("FAIL: incomplete capture");
        else
            $display("SUCCESS: capture counts OK");

        $finish;
    end
endmodule
