`timescale 1ns/1ps

module tb_inception_conv19;
    localparam integer TOKENS_CHECK = 10;
    localparam integer LOOKAHEAD_DELAY = 19;
    localparam integer TOKENS_FEED = TOKENS_CHECK + LOOKAHEAD_DELAY;
    localparam integer CHANNELS_IN = 16;
    localparam integer CHANNELS_OUT = 16;

    reg clk, rst_n, valid_in;
    reg [255:0] token_in_packed;
    wire [255:0] token_out_packed;
    wire valid_out;

    integer fd_out, token_count, out_count, ch, offset, timeout;
    reg [15:0] input_mem [0:15999];

    Inception_Conv19_Stage dut (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(token_in_packed),
        .valid_in(valid_in),
        .token_out(token_out_packed),
        .valid_out(valid_out)
    );

    always #5 clk = ~clk;

    task load_input_token;
        input integer token_idx;
        integer seq_len;
        begin
            seq_len = 1000;
            for (ch = 0; ch < CHANNELS_IN; ch = ch + 1) begin
                offset = ch * 16;
                token_in_packed[offset +: 16] = input_mem[ch * seq_len + token_idx];
            end
        end
    endtask

    task unpack_output;
        integer oc;
        reg [15:0] out_val;
        begin
            for (oc = 0; oc < CHANNELS_OUT; oc = oc + 1) begin
                out_val = token_out_packed[oc*16 +: 16];
                $fwrite(fd_out, "%04x\n", out_val);
            end
        end
    endtask

    always @(posedge clk) begin
        if (valid_out && (out_count < TOKENS_CHECK)) begin
            unpack_output();
            out_count = out_count + 1;
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        valid_in = 0;
        token_in_packed = 256'h0;
        $readmemh("../../../ITMN/golden_vectors/rtl_mem/inception_stage/tensors/05_bottleneck_out_q312.mem", input_mem);

        fd_out = $fopen("rtl_output.mem", "w");
        if (fd_out == 0) begin
            $display("[ERROR] Cannot open rtl_output.mem");
            $finish;
        end

        $readmemh("../test_BaseInceptionBlock_Full/weights_and_io/inception_conv3_k19_weight_q312.mem", dut.dut.weights_c);

        repeat (3) @(posedge clk);
        rst_n = 1;

        token_count = 0;
        out_count = 0;
        while (token_count < TOKENS_FEED) begin
            @(posedge clk);
            load_input_token(token_count);
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            token_count = token_count + 1;
        end

        timeout = 0;
        while ((out_count < TOKENS_CHECK) && (timeout < 200)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        $fclose(fd_out);
        $finish;
    end

endmodule