`timescale 1ns/1ps

module tb_mamba_fullbranch_chain;
    localparam DATA_WIDTH = 16;
    localparam FRAC_BITS  = 12;
    localparam SEQ_LEN    = 1000;
    localparam D_MODEL    = 64;
    localparam D_INNER    = 128;
    localparam D_STATE    = 16;

    reg clk;
    reg reset;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg signed [DATA_WIDTH-1:0] mamba_input_mem    [0:SEQ_LEN*D_MODEL-1];
    reg signed [DATA_WIDTH-1:0] rms_weight_mem     [0:D_MODEL-1];
    reg signed [DATA_WIDTH-1:0] inproj_weight_mem  [0:D_INNER*D_MODEL-1];
    reg signed [DATA_WIDTH-1:0] conv_weight_mem    [0:D_INNER*4-1];
    reg signed [DATA_WIDTH-1:0] conv_bias_mem      [0:D_INNER-1];
    reg signed [DATA_WIDTH-1:0] outproj_weight_mem [0:D_MODEL*D_INNER-1];
    reg signed [DATA_WIDTH-1:0] delta_mem          [0:SEQ_LEN*D_INNER-1];
    reg signed [DATA_WIDTH-1:0] B_raw_mem          [0:SEQ_LEN*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] C_raw_mem          [0:SEQ_LEN*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] A_vec_mem          [0:D_INNER*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] D_vec_mem          [0:D_INNER-1];
    reg signed [DATA_WIDTH-1:0] gate_mem           [0:SEQ_LEN*D_INNER-1];

    reg  [D_MODEL*DATA_WIDTH-1:0] x_vec_packed;
    reg  [D_MODEL*DATA_WIDTH-1:0] gamma_packed;
    wire [D_MODEL*DATA_WIDTH-1:0] rms_out_packed;
    reg  rms_start;
    reg  rms_en;
    wire rms_done;

    reg  [D_INNER*D_MODEL*DATA_WIDTH-1:0] inproj_w_packed;
    wire [D_INNER*DATA_WIDTH-1:0] inproj_out_packed;
    reg  inproj_start;
    reg  inproj_en;
    wire inproj_done;

    reg conv_start;
    reg conv_en;
    reg conv_valid_in;
    wire all_conv_valid;

    wire [D_INNER*DATA_WIDTH-1:0] x_activated_token_packed;
    reg  [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] conv_b_packed;

    reg  [D_INNER*DATA_WIDTH-1:0] delta_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] gate_packed;
    reg  [D_STATE*DATA_WIDTH-1:0] B_packed;
    reg  [D_STATE*DATA_WIDTH-1:0] C_packed;
    reg  [D_INNER*D_STATE*DATA_WIDTH-1:0] A_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] D_packed;

    wire [D_INNER*DATA_WIDTH-1:0] y_scan_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] y_gated_packed;

    reg  [D_MODEL*D_INNER*DATA_WIDTH-1:0] outproj_w_packed;
    wire [D_MODEL*DATA_WIDTH-1:0] final_out_packed;
    reg  outproj_start;
    reg  outproj_en;
    wire outproj_done;

    reg scan_start;
    reg scan_en;
    reg scan_clear_h;
    wire all_scan_done;

    wire [D_INNER*4-1:0] scan_state_dbg_packed;
    wire [D_INNER*DATA_WIDTH-1:0] scan_discA0_dbg_packed;
    wire [D_INNER*DATA_WIDTH-1:0] scan_deltaB0_dbg_packed;
    wire [D_INNER*DATA_WIDTH-1:0] scan_deltaBx0_dbg_packed;
    wire [D_INNER*DATA_WIDTH-1:0] scan_hnew0_dbg_packed;
    wire [D_INNER*DATA_WIDTH-1:0] scan_h0_dbg_packed;
    wire [D_INNER*32-1:0] scan_ywithd_dbg_packed;
    wire [D_INNER*32-1:0] scan_yfinal_dbg_packed;
    wire [D_INNER*DATA_WIDTH-1:0] scan_gateact_dbg_packed;

    Mamba_Block_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .D_STATE(D_STATE)
    ) u_mamba_wrapper (
        .clk(clk),
        .reset(reset),
        .rms_start(rms_start),
        .rms_en(rms_en),
        .inproj_start(inproj_start),
        .inproj_en(inproj_en),
        .conv_start(conv_start),
        .conv_en(conv_en),
        .conv_valid_in(conv_valid_in),
        .scan_start(scan_start),
        .scan_en(scan_en),
        .scan_clear_h(scan_clear_h),
        .outproj_start(outproj_start),
        .outproj_en(outproj_en),
        .x_vec_packed(x_vec_packed),
        .gamma_packed(gamma_packed),
        .inproj_w_packed(inproj_w_packed),
        .conv_w_packed(conv_w_packed),
        .conv_b_packed(conv_b_packed),
        .delta_packed(delta_packed),
        .gate_packed(gate_packed),
        .B_packed(B_packed),
        .C_packed(C_packed),
        .A_packed(A_packed),
        .D_packed(D_packed),
        .outproj_w_packed(outproj_w_packed),
        .rms_done(rms_done),
        .inproj_done(inproj_done),
        .all_conv_valid(all_conv_valid),
        .all_scan_done(all_scan_done),
        .outproj_done(outproj_done),
        .rms_out_packed(rms_out_packed),
        .inproj_out_packed(inproj_out_packed),
        .x_activated_packed(x_activated_token_packed),
        .y_scan_packed(y_scan_packed),
        .final_out_packed(final_out_packed),
        .scan_state_dbg_packed(scan_state_dbg_packed),
        .scan_discA0_dbg_packed(scan_discA0_dbg_packed),
        .scan_deltaB0_dbg_packed(scan_deltaB0_dbg_packed),
        .scan_deltaBx0_dbg_packed(scan_deltaBx0_dbg_packed),
        .scan_hnew0_dbg_packed(scan_hnew0_dbg_packed),
        .scan_h0_dbg_packed(scan_h0_dbg_packed),
        .scan_ywithd_dbg_packed(scan_ywithd_dbg_packed),
        .scan_yfinal_dbg_packed(scan_yfinal_dbg_packed),
        .scan_gateact_dbg_packed(scan_gateact_dbg_packed)
    );

    integer t;
    integer i;
    integer j;
    integer sim_tokens;
    integer trace_mode;
    integer trace_ch;
    integer trace_token;
    integer scan_dbg_cycle;
    integer fd_rms;
    integer fd_inproj;
    integer fd_silu;
    integer fd_ygated;
    integer fd_final;

    task load_static_weights;
        begin
            for (i = 0; i < D_MODEL; i = i + 1) begin
                gamma_packed[i*DATA_WIDTH +: DATA_WIDTH] = rms_weight_mem[i];
            end
            for (i = 0; i < D_INNER*D_MODEL; i = i + 1) begin
                inproj_w_packed[i*DATA_WIDTH +: DATA_WIDTH] = inproj_weight_mem[i];
            end
            for (i = 0; i < D_INNER*4; i = i + 1) begin
                conv_w_packed[i*DATA_WIDTH +: DATA_WIDTH] = conv_weight_mem[i];
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                conv_b_packed[i*DATA_WIDTH +: DATA_WIDTH] = conv_bias_mem[i];
            end
            for (i = 0; i < D_MODEL*D_INNER; i = i + 1) begin
                outproj_w_packed[i*DATA_WIDTH +: DATA_WIDTH] = outproj_weight_mem[i];
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                D_packed[i*DATA_WIDTH +: DATA_WIDTH] = D_vec_mem[i];
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                for (j = 0; j < D_STATE; j = j + 1) begin
                    A_packed[(i*D_STATE + j)*DATA_WIDTH +: DATA_WIDTH] = A_vec_mem[i*D_STATE + j];
                end
            end
        end
    endtask

    task load_token_inputs;
        input integer tok;
        begin
            for (i = 0; i < D_MODEL; i = i + 1) begin
                x_vec_packed[i*DATA_WIDTH +: DATA_WIDTH] = mamba_input_mem[tok*D_MODEL + i];
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                delta_packed[i*DATA_WIDTH +: DATA_WIDTH] = delta_mem[tok*D_INNER + i];
                gate_packed[i*DATA_WIDTH +: DATA_WIDTH]  = gate_mem[tok*D_INNER + i];
            end
            for (i = 0; i < D_STATE; i = i + 1) begin
                B_packed[i*DATA_WIDTH +: DATA_WIDTH] = B_raw_mem[tok*D_STATE + i];
                C_packed[i*DATA_WIDTH +: DATA_WIDTH] = C_raw_mem[tok*D_STATE + i];
            end
        end
    endtask

    task dump_token_outputs;
        input integer tok;
        begin
            for (i = 0; i < D_MODEL; i = i + 1) begin
                $fdisplay(fd_rms, "%04h", rms_out_packed[i*DATA_WIDTH +: DATA_WIDTH]);
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                $fdisplay(fd_inproj, "%04h", inproj_out_packed[i*DATA_WIDTH +: DATA_WIDTH]);
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                $fdisplay(fd_silu, "%04h", x_activated_token_packed[i*DATA_WIDTH +: DATA_WIDTH]);
            end
            for (i = 0; i < D_INNER; i = i + 1) begin
                $fdisplay(fd_ygated, "%04h", y_gated_packed[i*DATA_WIDTH +: DATA_WIDTH]);
            end
            for (i = 0; i < D_MODEL; i = i + 1) begin
                $fdisplay(fd_final, "%04h", final_out_packed[i*DATA_WIDTH +: DATA_WIDTH]);
            end
        end
    endtask

    initial begin
        $readmemh("mamba_input.mem", mamba_input_mem);
        $readmemh("rms_weight.mem", rms_weight_mem);
        $readmemh("inproj_weight.mem", inproj_weight_mem);
        $readmemh("conv_weight.mem", conv_weight_mem);
        $readmemh("conv_bias.mem", conv_bias_mem);
        $readmemh("outproj_weight.mem", outproj_weight_mem);
        $readmemh("delta.mem", delta_mem);
        $readmemh("B_raw.mem", B_raw_mem);
        $readmemh("C_raw.mem", C_raw_mem);
        $readmemh("A_vec.mem", A_vec_mem);
        $readmemh("D_vec.mem", D_vec_mem);
        $readmemh("gate.mem", gate_mem);

        fd_rms = $fopen("rtl_rms.mem", "w");
        fd_inproj = $fopen("rtl_inproj.mem", "w");
        fd_silu = $fopen("rtl_silu.mem", "w");
        fd_ygated = $fopen("rtl_ygated.mem", "w");
        fd_final = $fopen("rtl_final.mem", "w");

        rms_start = 1'b0;
        rms_en = 1'b1;
        inproj_start = 1'b0;
        inproj_en = 1'b1;
        conv_start = 1'b0;
        conv_en = 1'b1;
        conv_valid_in = 1'b0;
        scan_start = 1'b0;
        scan_en = 1'b1;
        scan_clear_h = 1'b0;
        outproj_start = 1'b0;
        outproj_en = 1'b1;

        if (!$value$plusargs("TOKENS=%d", sim_tokens)) begin
            sim_tokens = SEQ_LEN;
        end
        if (!$value$plusargs("TRACE=%d", trace_mode)) begin
            trace_mode = 0;
        end
        if (!$value$plusargs("TRACE_CH=%d", trace_ch)) begin
            trace_ch = 0;
        end
        if (!$value$plusargs("TRACE_TOKEN=%d", trace_token)) begin
            trace_token = 0;
        end
        if (sim_tokens < 1) sim_tokens = 1;
        if (sim_tokens > SEQ_LEN) sim_tokens = SEQ_LEN;
        if (trace_ch < 0) trace_ch = 0;
        if (trace_ch >= D_INNER) trace_ch = D_INNER-1;
        if (trace_token < 0) trace_token = 0;
        if (trace_token >= sim_tokens) trace_token = sim_tokens-1;

        load_static_weights();

        reset = 1'b1;
        #40;
        reset = 1'b0;

        scan_clear_h = 1'b1;
        @(posedge clk);
        scan_clear_h = 1'b0;

        conv_start = 1'b1;
        @(posedge clk);
        conv_start = 1'b0;
        #20;

        for (t = 0; t < sim_tokens; t = t + 1) begin
            load_token_inputs(t);

            @(posedge clk);
            rms_start = 1'b1;
            @(posedge clk);
            rms_start = 1'b0;
            wait (rms_done == 1'b1);
            @(posedge clk);

            inproj_start = 1'b1;
            @(posedge clk);
            inproj_start = 1'b0;
            wait (inproj_done == 1'b1);
            @(posedge clk);

            conv_valid_in = 1'b1;
            @(posedge clk);
            conv_valid_in = 1'b0;
            wait (all_conv_valid == 1'b1);
            @(posedge clk);

            scan_start = 1'b1;
            @(posedge clk);
            scan_start = 1'b0;

            if (t == 0) begin
                #1;
                $display("SILU_TRACE token0 ch0 conv_in=%0h silu_out=%0h",
                         inproj_out_packed[15:0],
                         x_activated_token_packed[15:0]);
                $display("SILU_TRACE_CHANNELS token0 conv_in[0:15]:");
                for (scan_dbg_cycle = 0; scan_dbg_cycle < 16; scan_dbg_cycle = scan_dbg_cycle + 1) begin
                    $display("  ch%0d: conv_in=%0h silu=%0h",
                             scan_dbg_cycle,
                             inproj_out_packed[scan_dbg_cycle*DATA_WIDTH +: DATA_WIDTH],
                             x_activated_token_packed[scan_dbg_cycle*DATA_WIDTH +: DATA_WIDTH]);
                end
            end

            if (trace_mode && t == trace_token) begin
                $display("TRACE_CONFIG token=%0d trace_ch=%0d", trace_token, trace_ch);
                for (scan_dbg_cycle = 0; scan_dbg_cycle < 12; scan_dbg_cycle = scan_dbg_cycle + 1) begin
                    @(posedge clk);
                    #1;
                    $display("TRACE token%0d ch%0d cycle=%0d state=%0d discA0=%0d deltaB0=%0d deltaBx0=%0d hnew0=%0d h0=%0d y_with_D=%0d y_final_raw=%0d gate_act=%0d y_scan=%0h x_act=%0h delta=%0h gate_in=%0h",
                             trace_token,
                             trace_ch,
                             scan_dbg_cycle,
                             scan_state_dbg_packed[trace_ch*4 +: 4],
                             $signed(scan_discA0_dbg_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]),
                             $signed(scan_deltaB0_dbg_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]),
                             $signed(scan_deltaBx0_dbg_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]),
                             $signed(scan_hnew0_dbg_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]),
                             $signed(scan_h0_dbg_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]),
                             $signed(scan_ywithd_dbg_packed[trace_ch*32 +: 32]),
                             $signed(scan_yfinal_dbg_packed[trace_ch*32 +: 32]),
                             $signed(scan_gateact_dbg_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]),
                             y_scan_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH],
                             x_activated_token_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH],
                             delta_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH],
                             gate_packed[trace_ch*DATA_WIDTH +: DATA_WIDTH]);
                end
            end

            wait (all_scan_done == 1'b1);
            @(posedge clk);

            y_gated_packed = y_scan_packed;

            outproj_start = 1'b1;
            @(posedge clk);
            outproj_start = 1'b0;
            @(posedge clk);

            dump_token_outputs(t);

            if ((t % 100) == 0) begin
                $display("Processed token %0d", t);
            end
        end

        $fclose(fd_rms);
        $fclose(fd_inproj);
        $fclose(fd_silu);
        $fclose(fd_ygated);
        $fclose(fd_final);

        $display("Full-branch chain simulation done. tokens=%0d", sim_tokens);
        $finish;
    end

endmodule
