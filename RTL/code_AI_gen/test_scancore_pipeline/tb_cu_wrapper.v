`timescale 1ns/1ps

module tb_cu_wrapper;
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

    // packed interfaces (we'll load mems like original TB)
    reg  [D_MODEL*DATA_WIDTH-1:0] x_vec_packed;
    reg  [D_MODEL*DATA_WIDTH-1:0] gamma_packed;
    reg  [D_INNER*D_MODEL*DATA_WIDTH-1:0] inproj_w_packed;
    reg  [D_INNER*4*DATA_WIDTH-1:0] conv_w_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] conv_b_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] delta_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] gate_packed;
    reg  [D_STATE*DATA_WIDTH-1:0] B_packed;
    reg  [D_STATE*DATA_WIDTH-1:0] C_packed;
    reg  [D_INNER*D_STATE*DATA_WIDTH-1:0] A_packed;
    reg  [D_INNER*DATA_WIDTH-1:0] D_packed;
    reg  [D_MODEL*D_INNER*DATA_WIDTH-1:0] outproj_w_packed;

    // outputs
    wire [D_MODEL*DATA_WIDTH-1:0] rms_out_packed;
    wire [D_INNER*DATA_WIDTH-1:0] inproj_out_packed;
    wire [D_INNER*DATA_WIDTH-1:0] x_activated_packed;
    wire [D_INNER*DATA_WIDTH-1:0] y_scan_packed;
    wire [D_MODEL*DATA_WIDTH-1:0] final_out_packed;

    // stage flags
    wire rms_done;
    wire inproj_done;
    wire all_conv_valid;
    wire all_scan_done;
    wire outproj_done;

    // simple reg interface
    reg reg_wr;
    reg reg_rd;
    reg [7:0] reg_addr;
    reg [31:0] reg_wdata;
    wire [31:0] reg_rdata;
    wire reg_ready;

    wire cu_busy;
    wire cu_done;
    wire cu_irq;

    // mems used to load real data
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

    integer i, t;
    integer ack_wait;
    integer wait_cnt;

    // single CU instance used only for reg interface observations

    // Instantiate wrapper and connect control signals from CU via explicit wires
    wire cu_rms_start, cu_rms_en, cu_inproj_start, cu_inproj_en;
    wire cu_conv_start, cu_conv_en, cu_conv_valid_in;
    wire cu_scan_start, cu_scan_en, cu_scan_clear_h;
    wire cu_outproj_start, cu_outproj_en;

    // Rebind CU outputs by re-instantiating CU with named outputs (above we left them unconnected),
    // so instead instantiate CU again properly. Simpler: instantiate a second CU instance named cu2

    Mamba_Control_Unit #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) cu2 (
        .clk(clk),
        .reset(reset),
        .reg_wr(reg_wr),
        .reg_rd(reg_rd),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata),
        .reg_ready(reg_ready),
        .rms_start(cu_rms_start),
        .rms_en(cu_rms_en),
        .inproj_start(cu_inproj_start),
        .inproj_en(cu_inproj_en),
        .conv_start(cu_conv_start),
        .conv_en(cu_conv_en),
        .conv_valid_in(cu_conv_valid_in),
        .scan_start(cu_scan_start),
        .scan_en(cu_scan_en),
        .scan_clear_h(cu_scan_clear_h),
        .outproj_start(cu_outproj_start),
        .outproj_en(cu_outproj_en),
        .rms_done(rms_done),
        .inproj_done(inproj_done),
        .all_conv_valid(all_conv_valid),
        .all_scan_done(all_scan_done),
        .outproj_done(outproj_done),
        .busy(cu_busy),
        .done(cu_done),
        .irq(cu_irq)
    );

    // Note: the above duplicates CU instance for control signals. To ensure reg interface works,
    // drive reg signals into both instances; we use cu2 outputs to the wrapper.

    Mamba_Block_Wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .D_MODEL(D_MODEL),
        .D_INNER(D_INNER),
        .D_STATE(D_STATE)
    ) mamba (
        .clk(clk),
        .reset(reset),
        .rms_start(cu_rms_start),
        .rms_en(cu_rms_en),
        .inproj_start(cu_inproj_start),
        .inproj_en(cu_inproj_en),
        .conv_start(cu_conv_start),
        .conv_en(cu_conv_en),
        .conv_valid_in(cu_conv_valid_in),
        .scan_start(cu_scan_start),
        .scan_en(cu_scan_en),
        .scan_clear_h(cu_scan_clear_h),
        .outproj_start(cu_outproj_start),
        .outproj_en(cu_outproj_en),
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
        .scan_state_dbg_packed(),
        .scan_discA0_dbg_packed(),
        .scan_deltaB0_dbg_packed(),
        .scan_deltaBx0_dbg_packed(),
        .scan_hnew0_dbg_packed(),
        .scan_h0_dbg_packed(),
        .scan_ywithd_dbg_packed(),
        .scan_yfinal_dbg_packed(),
        .scan_gateact_dbg_packed()
    );

    // load mems (reuse file names from original TB)
    initial begin
        $display("TB_CU_WRAPPER: starting");
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

        // simple packing: take token 0 inputs into packed buses
        for (i = 0; i < D_MODEL; i = i + 1) begin
            x_vec_packed[i*DATA_WIDTH +: DATA_WIDTH] = mamba_input_mem[i];
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
            D_packed[i*DATA_WIDTH +: DATA_WIDTH] = D_vec_mem[i];
            outproj_w_packed[i*DATA_WIDTH +: DATA_WIDTH] = outproj_weight_mem[i];
        end
        for (i = 0; i < D_INNER; i = i + 1) begin
            delta_packed[i*DATA_WIDTH +: DATA_WIDTH] = delta_mem[i];
            gate_packed[i*DATA_WIDTH +: DATA_WIDTH]  = gate_mem[i];
        end
        for (i = 0; i < D_STATE; i = i + 1) begin
            B_packed[i*DATA_WIDTH +: DATA_WIDTH] = B_raw_mem[i];
            C_packed[i*DATA_WIDTH +: DATA_WIDTH] = C_raw_mem[i];
        end
        for (i = 0; i < D_INNER*D_STATE; i = i + 1) begin
            A_packed[i*DATA_WIDTH +: DATA_WIDTH] = A_vec_mem[i];
        end

        // init regs
        reg_wr = 0; reg_rd = 0; reg_addr = 8'd0; reg_wdata = 32'd0;
        reset = 1'b1;
        #40;
        reset = 1'b0;

        // optionally pulse scan_clear via wrapper input directly
        @(posedge clk);

        // write REG_CTRL start
        @(posedge clk);
        $display("TB_CU_WRAPPER: writing REG_CTRL start at time=%0t", $time);
        reg_wr <= 1; reg_addr <= 8'h00; reg_wdata <= 32'h1;
        @(posedge clk);
        // wait for reg_ready (with timeout)
        ack_wait = 0;
        while (reg_ready == 1'b0 && ack_wait < 20) begin
            @(posedge clk);
            ack_wait = ack_wait + 1;
        end
        if (reg_ready) $display("TB_CU_WRAPPER: reg_ready seen after %0d cycles", ack_wait);
        else $display("TB_CU_WRAPPER: WARNING reg_ready NOT seen");
        reg_wr <= 0; reg_wdata <= 32'd0;

        // wait for cu_done
        wait_cnt = 0;
        $display("TB_CU_WRAPPER: waiting for cu_done at time=%0t", $time);
        while (cu_done == 1'b0 && wait_cnt < 500000) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end
        if (cu_done) $display("TB_CU_WRAPPER: cu_done observed at time=%0t after %0d cycles", $time, wait_cnt);
        else $display("TB_CU_WRAPPER: TIMEOUT waiting for cu_done");

        // dump a few outputs for inspection
        $display("rms_out_packed[0]=%0h inproj_out_packed[0]=%0h final_out_packed[0]=%0h", rms_out_packed[0 +: DATA_WIDTH], inproj_out_packed[0 +: DATA_WIDTH], final_out_packed[0 +: DATA_WIDTH]);

        $display("TB_CU_WRAPPER: done, finishing simulation");
        #20 $finish;
    end

endmodule
