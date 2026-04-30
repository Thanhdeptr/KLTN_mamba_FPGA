`timescale 1ns/1ps

module tb_mamba_cu_demo();
    reg clk = 0;
    always #5 clk = ~clk; // 100MHz

    reg reset = 1;

    // reg interface signals
    reg reg_wr;
    reg reg_rd;
    reg [7:0] reg_addr;
    reg [31:0] reg_wdata;
    wire [31:0] reg_rdata;
    wire reg_ready;

    // CU control outputs
    wire rms_start, rms_en, inproj_start, inproj_en;
    wire conv_start, conv_en, conv_valid_in;
    wire scan_start, scan_en, scan_clear_h;
    wire outproj_start, outproj_en;

    // done signals (driven by TB to simulate progression)
    reg rms_done = 0;
    reg inproj_done = 0;
    reg all_conv_valid = 0;
    reg all_scan_done = 0;
    reg outproj_done = 0;

    wire busy, done, irq;

    Mamba_Control_Unit #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) cu (
        .clk(clk), .reset(reset),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata), .reg_ready(reg_ready),
        .rms_start(rms_start), .rms_en(rms_en), .inproj_start(inproj_start), .inproj_en(inproj_en),
        .conv_start(conv_start), .conv_en(conv_en), .conv_valid_in(conv_valid_in),
        .scan_start(scan_start), .scan_en(scan_en), .scan_clear_h(scan_clear_h),
        .outproj_start(outproj_start), .outproj_en(outproj_en),
        .rms_done(rms_done), .inproj_done(inproj_done), .all_conv_valid(all_conv_valid), .all_scan_done(all_scan_done), .outproj_done(outproj_done),
        .busy(busy), .done(done), .irq(irq)
    );

    initial begin
        $display("=== CU demo TB start ===");
        #20;
        reset = 0;

        // write TOKENS (0x08)
        @(posedge clk);
        reg_wr <= 1; reg_addr <= 8'h08; reg_wdata <= 32'd100; @(posedge clk);
        reg_wr <= 0; reg_wdata <= 32'd0; @(posedge clk);

        // start via REG_CTRL (0x00) bit0
        @(posedge clk);
        reg_wr <= 1; reg_addr <= 8'h00; reg_wdata <= 32'h1; @(posedge clk);
        reg_wr <= 0; @(posedge clk);

        // simulate progression: after a few cycles assert rms_done
        repeat (10) @(posedge clk);
        $display("TB: asserting rms_done");
        rms_done <= 1; @(posedge clk); rms_done <= 0;

        // after another few cycles assert inproj_done
        repeat (10) @(posedge clk);
        $display("TB: asserting inproj_done");
        inproj_done <= 1; @(posedge clk); inproj_done <= 0;

        // conv stage complete
        repeat (10) @(posedge clk);
        $display("TB: asserting all_conv_valid");
        all_conv_valid <= 1; @(posedge clk); all_conv_valid <= 0;

        // scan stage complete
        repeat (10) @(posedge clk);
        $display("TB: asserting all_scan_done");
        all_scan_done <= 1; @(posedge clk); all_scan_done <= 0;

        // outproj done
        repeat (10) @(posedge clk);
        $display("TB: asserting outproj_done");
        outproj_done <= 1; @(posedge clk); outproj_done <= 0;

        // wait for CU to set done
        repeat (5) @(posedge clk);

        // read status
        @(posedge clk);
        reg_rd <= 1; reg_addr <= 8'h04; @(posedge clk);
        reg_rd <= 0; @(posedge clk);
        $display("REG_STATUS = 0x%08x", reg_rdata);

        $display("=== CU demo TB finished ===");
        #20 $finish;
    end

    // clear reg pulses
    always @(posedge clk) begin
        if (reg_ready) begin
            // consume ready immediately
        end
    end

endmodule
