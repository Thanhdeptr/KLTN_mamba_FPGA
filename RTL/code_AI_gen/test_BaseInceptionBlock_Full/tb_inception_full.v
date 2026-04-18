`timescale 1ns/1ps

module tb_inception_full;
    localparam integer TOKENS_CHECK = 10;
    localparam integer LOOKAHEAD_DELAY = 19;
    localparam integer TOKENS_FEED = TOKENS_CHECK + LOOKAHEAD_DELAY;

    reg clk, rst_n, valid_in;
    reg [1023:0] token_in_packed;
    wire [1023:0] token_out_packed;
    wire valid_out;
    
    integer fd_out, fd_log, token_count, out_count, i, j, timeout;
    integer fd_c1, fd_c9, fd_c19, fd_c39;
    
    // DUT instantiation
    BaseInceptionBlock_Full dut (
        .clk(clk),
        .rst_n(rst_n),
        .token_in(token_in_packed),
        .valid_in(valid_in),
        .token_out(token_out_packed),
        .valid_out(valid_out)
    );
    
    // Clock
    always #5 clk = ~clk;

    // Unpack and write output
    task unpack_output;
        integer ch, offset;
        reg [15:0] out_val;
        begin
            for (ch = 0; ch < 64; ch = ch + 1) begin
                offset = ch * 16;
                out_val = token_out_packed[offset +: 16];
                $fwrite(fd_out, "%04x\n", out_val);
            end
        end
    endtask

    // Dump internal branch outputs (pre-BN) for strict debug
    task dump_internal_branches;
        integer oc;
        reg [15:0] v;
        begin
            for (oc = 0; oc < 16; oc = oc + 1) begin
                v = dut.conv1_out[oc][15:0];
                $fwrite(fd_c1, "%04x\n", v);

                v = dut.conv9_out[oc][15:0];
                $fwrite(fd_c9, "%04x\n", v);

                v = dut.conv19_out[oc][15:0];
                $fwrite(fd_c19, "%04x\n", v);

                v = dut.conv39_out[oc][15:0];
                $fwrite(fd_c39, "%04x\n", v);
            end
        end
    endtask

    // Capture output exactly on valid_out pulses.
    always @(posedge clk) begin
        if (valid_out && (out_count < TOKENS_CHECK)) begin
            $fwrite(fd_log, "[SIM] Output captured at %0t (idx=%0d)\n", $time, out_count);
            dump_internal_branches();
            unpack_output();
            out_count = out_count + 1;
        end
    end
    
    // Load weights from memory files
    task load_weights;
        begin
            $readmemh("weights_and_io_folded/inception_bottleneck_weight_folded_q312.mem", dut.weights_bn);
            $readmemh("weights_and_io_folded/inception_conv1_k1_weight_folded_q312.mem", dut.weights_c1);
            $readmemh("weights_and_io_folded/inception_conv2_k9_weight_folded_q312.mem", dut.weights_c9);
            $readmemh("weights_and_io_folded/inception_conv3_k19_weight_folded_q312.mem", dut.weights_c19);
            $readmemh("weights_and_io_folded/inception_conv4_k39_weight_folded_q312.mem", dut.weights_c39);
            $readmemh("weights_and_io_folded/inception_folded_bias_q312.mem", dut.fold_bias);
            $display("[TB] Weights loaded");
        end
    endtask
    
    // Load input token from memory
    task load_input_token;
        input integer token_idx;
        integer ch, offset;
        integer seq_len;
        reg [15:0] input_mem [0:63999];
        begin
            $readmemh("weights_and_io/inception_golden_input_q312.mem", input_mem);

            // inception_golden_input_q312.mem is flattened from tensor [C, T]
            // (channel-major): linear_idx = ch * seq_len + token_idx.
            seq_len = 1000;
            for (ch = 0; ch < 64; ch = ch + 1) begin
                offset = ch * 16;
                token_in_packed[offset +: 16] = input_mem[ch * seq_len + token_idx];
            end
        end
    endtask
    
    initial begin
        clk = 0;
        rst_n = 0;
        valid_in = 0;
        token_in_packed = 1024'h0;
        
        fd_out = $fopen("rtl_output.mem", "w");
        if (fd_out == 0) begin
            $display("[ERROR] Cannot open rtl_output.mem");
            $finish;
        end
        
        fd_log = $fopen("rtl_sim.log", "w");
        if (fd_log == 0) begin
            $display("[ERROR] Cannot open rtl_sim.log");
            $finish;
        end

        fd_c1 = $fopen("rtl_conv1_prebn.mem", "w");
        fd_c9 = $fopen("rtl_conv9_prebn.mem", "w");
        fd_c19 = $fopen("rtl_conv19_prebn.mem", "w");
        fd_c39 = $fopen("rtl_conv39_prebn.mem", "w");
        if ((fd_c1 == 0) || (fd_c9 == 0) || (fd_c19 == 0) || (fd_c39 == 0)) begin
            $display("[ERROR] Cannot open one of internal branch dump files");
            $finish;
        end
        
        load_weights();
        
        repeat (3) @(posedge clk);
        rst_n = 1;
        $fwrite(fd_log, "[SIM] Reset released at %0t\n", $time);
        
        token_count = 0;
        out_count = 0;
        while (token_count < TOKENS_FEED) begin
            @(posedge clk);
            load_input_token(token_count);
            valid_in = 1;
            $fwrite(fd_log, "[SIM] Token %0d applied at %0t\n", token_count, $time);
            
            @(posedge clk);
            valid_in = 0;
            token_count = token_count + 1;

        end

        // Drain any remaining delayed outputs if needed.
        timeout = 0;
        while ((out_count < TOKENS_CHECK) && (timeout < 200)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        
        $fwrite(fd_log, "[SIM] Completed %0d feed tokens (delay=%0d), captured %0d outputs\n", token_count, LOOKAHEAD_DELAY, out_count);
        $display("[TB] Completed %0d feed tokens (delay=%0d), captured %0d outputs", token_count, LOOKAHEAD_DELAY, out_count);
        
        $fclose(fd_out);
        $fclose(fd_log);
        $fclose(fd_c1);
        $fclose(fd_c9);
        $fclose(fd_c19);
        $fclose(fd_c39);
        $finish;
    end

endmodule
