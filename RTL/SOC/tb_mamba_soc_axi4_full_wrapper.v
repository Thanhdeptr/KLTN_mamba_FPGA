`timescale 1ns/1ps

module tb_mamba_soc_axi4_full_wrapper;
    reg aclk;
    reg aresetn;

    reg [15:0] s_axi_awaddr;
    reg [7:0]  s_axi_awlen;
    reg [2:0]  s_axi_awsize;
    reg [1:0]  s_axi_awburst;
    reg        s_axi_awvalid;
    wire       s_axi_awready;

    reg [31:0] s_axi_wdata;
    reg [3:0]  s_axi_wstrb;
    reg        s_axi_wlast;
    reg        s_axi_wvalid;
    wire       s_axi_wready;

    wire [1:0] s_axi_bresp;
    wire       s_axi_bvalid;
    reg        s_axi_bready;

    reg [15:0] s_axi_araddr;
    reg [7:0]  s_axi_arlen;
    reg [2:0]  s_axi_arsize;
    reg [1:0]  s_axi_arburst;
    reg        s_axi_arvalid;
    wire       s_axi_arready;

    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rlast;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    integer i;
    integer pass_count;
    integer fail_count;
    reg [31:0] rd;
    reg [31:0] status;
    reg [31:0] bresp_cap;

    localparam [15:0] ADDR_CTRL       = 16'h0000;
    localparam [15:0] ADDR_MODE       = 16'h0004;
    localparam [15:0] ADDR_STATUS     = 16'h0008;
    localparam [15:0] ADDR_ITM_EN     = 16'h000C;

    localparam [15:0] BASE_FEAT       = 16'h0100;
    localparam [15:0] BASE_CONV_W     = 16'h0120;
    localparam [15:0] BASE_CONV_B     = 16'h01A0;
    localparam [15:0] BASE_SCAN_SC    = 16'h01C0;
    localparam [15:0] BASE_SCAN_A     = 16'h01D0;
    localparam [15:0] BASE_SCAN_B     = 16'h01F0;
    localparam [15:0] BASE_SCAN_C     = 16'h0210;
    localparam [15:0] BASE_OUT_SHADOW = 16'h0300;

    mamba_soc_axi4_full_wrapper dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready)
    );

    always #5 aclk = ~aclk;

    task check_eq32;
        input [255:0] name;
        input [31:0] got;
        input [31:0] exp;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s got=%08h exp=%08h", name, got, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[PASS] %0s = %08h", name, got);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task axi_write_single;
        input [15:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        output [1:0] bresp_o;
        begin
            @(posedge aclk);
            s_axi_awaddr  <= addr;
            s_axi_awlen   <= 8'd0;
            s_axi_awsize  <= 3'd2;
            s_axi_awburst <= 2'b01;
            s_axi_awvalid <= 1'b1;

            while (!s_axi_awready) @(posedge aclk);
            @(posedge aclk);
            s_axi_awvalid <= 1'b0;

            s_axi_wdata  <= data;
            s_axi_wstrb  <= strb;
            s_axi_wlast  <= 1'b1;
            s_axi_wvalid <= 1'b1;
            while (!s_axi_wready) @(posedge aclk);
            $display("[AXI-W] addr=%04h beat=0 data=%08h strb=%01h", addr, data, strb);
            @(posedge aclk);
            s_axi_wvalid <= 1'b0;
            s_axi_wlast  <= 1'b0;

            s_axi_bready <= 1'b1;
            while (!s_axi_bvalid) @(posedge aclk);
            bresp_o = s_axi_bresp;
            $display("[AXI-B] addr=%04h bresp=%0d", addr, s_axi_bresp);
            @(posedge aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_write_burst;
        input [15:0] addr;
        input integer beats;
        input [31:0] seed;
        output [1:0] bresp_o;
        integer k;
        reg [31:0] data;
        begin
            @(posedge aclk);
            s_axi_awaddr  <= addr;
            s_axi_awlen   <= beats - 1;
            s_axi_awsize  <= 3'd2;
            s_axi_awburst <= 2'b01;
            s_axi_awvalid <= 1'b1;
            while (!s_axi_awready) @(posedge aclk);
            @(posedge aclk);
            s_axi_awvalid <= 1'b0;

            for (k = 0; k < beats; k = k + 1) begin
                data = seed + k;
                s_axi_wdata  <= data;
                s_axi_wstrb  <= 4'hF;
                s_axi_wlast  <= (k == beats-1);
                s_axi_wvalid <= 1'b1;
                while (!s_axi_wready) @(posedge aclk);
                $display("[AXI-W] addr=%04h beat=%0d data=%08h strb=%01h", (addr + (k*4)), k, data, 4'hF);
                @(posedge aclk);
                s_axi_wvalid <= 1'b0;
                s_axi_wlast  <= 1'b0;
            end

            s_axi_bready <= 1'b1;
            while (!s_axi_bvalid) @(posedge aclk);
            bresp_o = s_axi_bresp;
            $display("[AXI-B] addr=%04h beats=%0d bresp=%0d", addr, beats, s_axi_bresp);
            @(posedge aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_read_single;
        input [15:0] addr;
        output [31:0] data;
        begin
            @(posedge aclk);
            s_axi_araddr  <= addr;
            s_axi_arlen   <= 8'd0;
            s_axi_arsize  <= 3'd2;
            s_axi_arburst <= 2'b01;
            s_axi_arvalid <= 1'b1;
            while (!s_axi_arready) @(posedge aclk);
            @(posedge aclk);
            s_axi_arvalid <= 1'b0;

            while (!s_axi_rvalid) @(posedge aclk);
            data = s_axi_rdata;
            $display("[AXI-R] addr=%04h beat=0 data=%08h rresp=%0d rlast=%0d", addr, data, s_axi_rresp, s_axi_rlast);
            s_axi_rready <= 1'b1;
            @(posedge aclk);
            s_axi_rready <= 1'b0;
        end
    endtask

    task fill_all_required_inputs;
        begin
            axi_write_burst(BASE_FEAT,    8, 32'h1000_0000, bresp_cap);
            axi_write_burst(BASE_CONV_W, 32, 32'h2000_0000, bresp_cap);
            axi_write_burst(BASE_CONV_B,  8, 32'h3000_0000, bresp_cap);
            axi_write_burst(BASE_SCAN_SC, 2, 32'h4000_0000, bresp_cap);
            axi_write_burst(BASE_SCAN_A,  8, 32'h5000_0000, bresp_cap);
            axi_write_burst(BASE_SCAN_B,  8, 32'h6000_0000, bresp_cap);
            axi_write_burst(BASE_SCAN_C,  8, 32'h7000_0000, bresp_cap);
        end
    endtask

    initial begin
        aclk = 1'b0;
        aresetn = 1'b0;
        pass_count = 0;
        fail_count = 0;

        s_axi_awaddr = 0;
        s_axi_awlen = 0;
        s_axi_awsize = 0;
        s_axi_awburst = 0;
        s_axi_awvalid = 0;

        s_axi_wdata = 0;
        s_axi_wstrb = 0;
        s_axi_wlast = 0;
        s_axi_wvalid = 0;

        s_axi_bready = 0;

        s_axi_araddr = 0;
        s_axi_arlen = 0;
        s_axi_arsize = 0;
        s_axi_arburst = 0;
        s_axi_arvalid = 0;

        s_axi_rready = 0;

        repeat (4) @(posedge aclk);
        aresetn <= 1'b1;
        @(posedge aclk);

        axi_read_single(ADDR_STATUS, status);
        check_eq32("status.ready_to_start after reset", status[3], 32'd0);

        axi_write_single(ADDR_MODE, 32'd5, 4'h1, bresp_cap);
        check_eq32("bresp mode write", bresp_cap, 32'd0);

        // Partial write then start request: must reject because not ready_to_start.
        axi_write_burst(BASE_FEAT, 4, 32'hA000_0000, bresp_cap);
        check_eq32("bresp partial write", bresp_cap, 32'd0);

        axi_write_single(ADDR_CTRL, 32'h0000_0001, 4'h1, bresp_cap);
        check_eq32("bresp start before ready", bresp_cap, 32'd0);
        axi_read_single(ADDR_STATUS, status);
        check_eq32("start_reject_sticky set", status[5], 32'd1);
        check_eq32("busy remains 0", status[2], 32'd0);

        // Clear errors and reset input valid map.
        axi_write_single(ADDR_CTRL, 32'h0000_0018, 4'h1, bresp_cap); // clr_error + soft_reset_buf

        // WSTRB merge check on one beat (directly inspect internal memory lane).
        axi_write_single(BASE_FEAT, 32'hA1B2_C3D4, 4'hF, bresp_cap);
        axi_write_single(BASE_FEAT, 32'h5566_7788, 4'h3, bresp_cap);
        check_eq32("WSTRB merge feat_mem[0]", dut.feat_mem[0], 32'hA1B2_7788);

        // Fill complete input map and verify ready_to_start.
        fill_all_required_inputs();
        axi_read_single(ADDR_STATUS, status);
        check_eq32("ready_to_start after full writes", status[3], 32'd1);

        // Start accepted -> busy should rise.
        axi_write_single(ADDR_CTRL, 32'h0000_0001, 4'h1, bresp_cap);
        axi_read_single(ADDR_STATUS, status);
        check_eq32("busy after start", status[2], 32'd1);

        // While busy, write to input must return SLVERR.
        axi_write_single(BASE_FEAT + 16'h0004, 32'hDEAD_BEEF, 4'hF, bresp_cap);
        check_eq32("write-while-busy bresp", bresp_cap, 32'd2);

        // Wait done with timeout.
        for (i = 0; i < 20000; i = i + 1) begin
            axi_read_single(ADDR_STATUS, status);
            if (status[0]) begin
                i = 20000;
            end
        end

        axi_read_single(ADDR_STATUS, status);
        check_eq32("done_sticky", status[0], 32'd1);
        check_eq32("busy cleared", status[2], 32'd0);
        check_eq32("output_snapshot_valid", status[7], 32'd1);

        // Read one output beat from snapshot window for protocol/log visibility.
        axi_read_single(BASE_OUT_SHADOW, rd);
        $display("[INFO] output beat0 shadow=%08h", rd);

        $display("TB SUMMARY: pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count != 0) begin
            $display("FAIL: tb_mamba_soc_axi4_full_wrapper");
            $finish;
        end

        $display("PASS: tb_mamba_soc_axi4_full_wrapper");
        $finish;
    end
endmodule
