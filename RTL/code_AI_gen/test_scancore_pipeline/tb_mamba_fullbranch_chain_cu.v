`timescale 1ns/1ps

module tb_mamba_fullbranch_chain_cu;
    localparam DATA_WIDTH = 16;
    localparam FRAC_BITS  = 12;
    localparam SEQ_LEN    = 1;
    localparam D_MODEL    = 64;
    localparam D_INNER    = 128;
    localparam D_STATE    = 16;

    reg clk;
    reg reset;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // memories and packed regs (same as original TB)
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
    wire rms_done;


    reg  [D_INNER*D_MODEL*DATA_WIDTH-1:0] inproj_w_packed;
    wire [D_INNER*DATA_WIDTH-1:0] inproj_out_packed;

    reg  [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] conv_b_packed;

    reg  [D_INNER*DATA_WIDTH-1:0] delta_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] gate_packed;
    reg  [D_STATE*DATA_WIDTH-1:0] B_packed;
    reg  [D_STATE*DATA_WIDTH-1:0] C_packed;
    reg  [D_INNER*D_STATE*DATA_WIDTH-1:0] A_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] D_packed;

    wire [D_INNER*DATA_WIDTH-1:0] y_scan_packed;
    wire [D_INNER*DATA_WIDTH-1:0] x_activated_packed;
    wire inproj_done;
    wire all_conv_valid;
    wire all_scan_done;
    wire outproj_done;
    reg  [D_INNER*DATA_WIDTH-1:0] y_gated_packed;

    reg  [D_MODEL*D_INNER*DATA_WIDTH-1:0] outproj_w_packed;
    wire [D_MODEL*DATA_WIDTH-1:0] final_out_packed;

    integer t;
    integer i;
    integer j;
    integer sim_tokens;
    integer trace_mode;
    integer trace_ch;
    integer trace_token;
    integer wait_cnt;
    integer ack_wait;
    integer scan_dbg_cycle;
    integer fd_rms;
    integer fd_inproj;
    integer fd_silu;
    integer fd_ygated;
    integer fd_final;

    // simple reg interface signals
    reg reg_wr;
    reg reg_rd;
    reg [7:0] reg_addr;
    reg [31:0] reg_wdata;
    wire [31:0] reg_rdata;
    wire reg_ready;

    wire cu_busy;
    wire cu_done;
    wire cu_irq;

    // scan_clear override to match previous TB behaviour
    reg scan_clear_override = 0;

    mamba_ip_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .D_STATE(D_STATE)
    ) u_top (
        .clk(clk),
        .reset(reset),
        .reg_wr(reg_wr),
        .reg_rd(reg_rd),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata),
        .reg_ready(reg_ready),
        .scan_clear_override(scan_clear_override),
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
        .x_activated_packed(x_activated_packed),
        .y_scan_packed(y_scan_packed),
        .final_out_packed(final_out_packed),
        .cu_busy(cu_busy),
        .cu_done(cu_done),
        .cu_irq(cu_irq)
    );

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
                $fdisplay(fd_silu, "%04h", x_activated_packed[i*DATA_WIDTH +: DATA_WIDTH]);
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

        // pulse scan_clear via override to mimic original TB
        scan_clear_override = 1'b1;
        @(posedge clk);
        scan_clear_override = 1'b0;

        // prepare reg signals
        reg_wr = 0; reg_rd = 0; reg_addr = 8'd0; reg_wdata = 32'd0;

        // conv_start is handled by CU; loop tokens and use reg writes to start each token
        for (t = 0; t < sim_tokens; t = t + 1) begin
            load_token_inputs(t);

            // write TOKENS into REG_TOKENS (0x08) once per run (optional)
            if (t == 0) begin
                @(posedge clk);
                reg_wr <= 1; reg_addr <= 8'h08; reg_wdata <= sim_tokens; @(posedge clk);
                reg_wr <= 0; reg_wdata <= 32'd0; @(posedge clk);
            end

            // start sequence via REG_CTRL (0x00) bit0
            @(posedge clk);
            $display("TB: token %0d - write REG_CTRL start (before)", t);
            reg_wr <= 1; reg_addr <= 8'h00; reg_wdata <= 32'h1;
            // wait for ack (reg_ready) from CU, with short timeout
            ack_wait = 0;
            @(posedge clk);
            while (reg_ready == 1'b0 && ack_wait < 10) begin
                @(posedge clk);
                ack_wait = ack_wait + 1;
            end
            if (reg_ready) begin
                $display("TB: token %0d - reg_ready observed after %0d cycles", t, ack_wait);
            end else begin
                $display("TB: token %0d - WARNING: reg_ready NOT observed after %0d cycles", t, ack_wait);
            end
            // deassert write
            reg_wr <= 0; reg_wdata <= 32'd0;
            $display("TB: token %0d - wrote REG_CTRL start (after). cu_busy=%0b cu_done=%0b", t, cu_busy, cu_done);

            // --- read REG_STATUS (0x04) to sample CU status after write ack ---
            @(posedge clk);
            reg_rd <= 1; reg_addr <= 8'h04;
            // wait for read ready
            ack_wait = 0;
            @(posedge clk);
            while (reg_ready == 1'b0 && ack_wait < 10) begin
                @(posedge clk);
                ack_wait = ack_wait + 1;
            end
            if (reg_ready) begin
                $display("TB: token %0d - reg_rd REG_STATUS observed after %0d cycles, reg_rdata=0x%08h", t, ack_wait, reg_rdata);
            end else begin
                $display("TB: token %0d - WARNING: reg_rd REG_STATUS NOT observed after %0d cycles", t, ack_wait);
            end
            // deassert read
            reg_rd <= 0; reg_addr <= 8'h00;

            // wait for CU to indicate done, with timeout to avoid infinite hang
            wait_cnt = 0;
            $display("TB: token %0d - waiting for cu_done...", t);
            while (cu_done == 1'b0 && wait_cnt < 200000) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
                if ((wait_cnt & 1023) == 0) begin
                    $display("TB: token %0d - still waiting at cycle %0d, cu_busy=%0b", t, $time, cu_busy);
                end
            end
            if (cu_done == 1'b0) begin
                $display("TB: token %0d - TIMEOUT waiting cu_done after %0d cycles", t, wait_cnt);
            end else begin
                $display("TB: token %0d - cu_done observed after %0d cycles, time=%0t", t, wait_cnt, $time);
            end
            @(posedge clk);

            // read outputs from top (y_scan is directly exposed)
            y_gated_packed = y_scan_packed;

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

        $display("Full-branch chain (via CU) simulation done. tokens=%0d", sim_tokens);
        $finish;
    end

endmodule
