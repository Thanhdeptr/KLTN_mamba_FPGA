`timescale 1ns/1ps

// TB: AXI4-Lite register access + ITM mode-5 zero-vector check (same golden as test_ITM_Block zero case).
module tb_mamba_soc_axi_lite_wrapper;
    reg aclk;
    reg aresetn;

    reg [11:0] s_axi_awaddr;
    reg        s_axi_awvalid;
    wire       s_axi_awready;
    reg [31:0] s_axi_wdata;
    reg [3:0]  s_axi_wstrb;
    reg        s_axi_wvalid;
    wire       s_axi_wready;
    wire [1:0] s_axi_bresp;
    wire       s_axi_bvalid;
    reg        s_axi_bready;

    reg [11:0] s_axi_araddr;
    reg        s_axi_arvalid;
    wire       s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire       s_axi_rvalid;
    reg        s_axi_rready;

    reg signed [16*16-1:0] lin_W_vals;
    reg signed [16*16-1:0] lin_bias_vals;
    wire signed [16*16-1:0] lin_y_out;

    reg signed [16*16-1:0] conv_x_vec;
    reg signed [16*4*16-1:0] conv_w_vec;
    reg signed [16*16-1:0] conv_b_vec;
    wire signed [16*16-1:0] conv_y_vec;

    reg signed [15:0] scan_delta_val;
    reg signed [15:0] scan_x_val;
    reg signed [15:0] scan_D_val;
    reg signed [15:0] scan_gate_val;
    reg signed [16*16-1:0] scan_A_vec;
    reg signed [16*16-1:0] scan_B_vec;
    reg signed [16*16-1:0] scan_C_vec;
    wire signed [15:0] scan_y_out;

    reg signed [15:0] softplus_in_val;
    wire signed [15:0] softplus_out_val;

    reg signed [16*16-1:0] itm_feat_vec;
    reg signed [16*4*16-1:0] itm_conv_w_vec;
    reg signed [16*16-1:0] itm_conv_b_vec;
    reg signed [15:0] itm_scan_delta_val;
    reg signed [15:0] itm_scan_x_val;
    reg signed [15:0] itm_scan_D_val;
    reg signed [15:0] itm_scan_gate_val;
    reg signed [16*16-1:0] itm_scan_A_vec;
    reg signed [16*16-1:0] itm_scan_B_vec;
    reg signed [16*16-1:0] itm_scan_C_vec;
    reg itm_scan_clear_h;
    wire signed [16*16-1:0] itm_out_vec;

    integer i;
    integer fd;
    integer timeout_cnt;
    reg done_wait;

    localparam [11:0] ADDR_CTRL   = 12'h000;
    localparam [11:0] ADDR_MODE   = 12'h004;
    localparam [11:0] ADDR_STATUS = 12'h008;
    localparam [11:0] ADDR_ITM_EN = 12'h00C;

    mamba_soc_axi_lite_wrapper dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .lin_W_vals(lin_W_vals),
        .lin_bias_vals(lin_bias_vals),
        .lin_y_out(lin_y_out),
        .conv_x_vec(conv_x_vec),
        .conv_w_vec(conv_w_vec),
        .conv_b_vec(conv_b_vec),
        .conv_y_vec(conv_y_vec),
        .scan_delta_val(scan_delta_val),
        .scan_x_val(scan_x_val),
        .scan_D_val(scan_D_val),
        .scan_gate_val(scan_gate_val),
        .scan_A_vec(scan_A_vec),
        .scan_B_vec(scan_B_vec),
        .scan_C_vec(scan_C_vec),
        .scan_y_out(scan_y_out),
        .softplus_in_val(softplus_in_val),
        .softplus_out_val(softplus_out_val),
        .itm_feat_vec(itm_feat_vec),
        .itm_conv_w_vec(itm_conv_w_vec),
        .itm_conv_b_vec(itm_conv_b_vec),
        .itm_scan_delta_val(itm_scan_delta_val),
        .itm_scan_x_val(itm_scan_x_val),
        .itm_scan_D_val(itm_scan_D_val),
        .itm_scan_gate_val(itm_scan_gate_val),
        .itm_scan_A_vec(itm_scan_A_vec),
        .itm_scan_B_vec(itm_scan_B_vec),
        .itm_scan_C_vec(itm_scan_C_vec),
        .itm_scan_clear_h(itm_scan_clear_h),
        .itm_out_vec(itm_out_vec)
    );

    always #5 aclk = ~aclk;

    task axi_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge aclk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            while (!(s_axi_awready && s_axi_wready))
                @(posedge aclk);
            @(posedge aclk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
            s_axi_bready  <= 1'b1;
            while (!s_axi_bvalid)
                @(posedge aclk);
            @(posedge aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_read(input [11:0] addr, output [31:0] data);
        begin
            @(posedge aclk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            while (!s_axi_arready)
                @(posedge aclk);
            @(posedge aclk);
            s_axi_arvalid <= 1'b0;
            while (!s_axi_rvalid)
                @(posedge aclk);
            data = s_axi_rdata;
            s_axi_rready <= 1'b1;
            @(posedge aclk);
            s_axi_rready <= 1'b0;
        end
    endtask

    reg [31:0] rd_val;

    initial begin
        aclk = 0;
        aresetn = 0;
        s_axi_awaddr = 0;
        s_axi_awvalid = 0;
        s_axi_wdata = 0;
        s_axi_wstrb = 0;
        s_axi_wvalid = 0;
        s_axi_bready = 0;
        s_axi_araddr = 0;
        s_axi_arvalid = 0;
        s_axi_rready = 0;

        lin_W_vals = 0;
        lin_bias_vals = 0;
        conv_x_vec = 0;
        conv_w_vec = 0;
        conv_b_vec = 0;
        scan_delta_val = 0;
        scan_x_val = 0;
        scan_D_val = 0;
        scan_gate_val = 0;
        scan_A_vec = 0;
        scan_B_vec = 0;
        scan_C_vec = 0;
        softplus_in_val = 0;
        itm_feat_vec = 0;
        itm_conv_w_vec = 0;
        itm_conv_b_vec = 0;
        itm_scan_delta_val = 0;
        itm_scan_x_val = 0;
        itm_scan_D_val = 0;
        itm_scan_gate_val = 0;
        itm_scan_A_vec = 0;
        itm_scan_B_vec = 0;
        itm_scan_C_vec = 0;
        itm_scan_clear_h = 0;

        repeat (4) @(posedge aclk);
        aresetn <= 1'b1;
        @(posedge aclk);

        // Optional: verify MODE read default
        axi_read(ADDR_MODE, rd_val);
        if (rd_val[2:0] !== 3'd0) begin
            $display("FAIL: MODE after reset unexpected %h", rd_val);
            $finish;
        end

        // ITM mode 5
        axi_write(ADDR_MODE, 32'd5);
        axi_read(ADDR_MODE, rd_val);
        if (rd_val[2:0] !== 3'd5) begin
            $display("FAIL: MODE readback");
            $finish;
        end

        // Pulse ITM start via CTRL
        axi_write(ADDR_CTRL, 32'd1);

        begin : wait_itm_done
            done_wait = 0;
            for (timeout_cnt = 0; timeout_cnt < 2000 && !done_wait; timeout_cnt = timeout_cnt + 1) begin
                @(posedge aclk);
                axi_read(ADDR_STATUS, rd_val);
                if (rd_val[0])
                    done_wait = 1'b1;
            end
            if (!done_wait) begin
                $display("FAIL: timeout waiting itm_done in STATUS");
                $finish;
            end
        end

        fd = $fopen("rtl_output.mem", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open rtl_output.mem");
            $finish;
        end
        #1;
        for (i = 0; i < 16; i = i + 1) begin
            $fdisplay(fd, "%04h", itm_out_vec[i*16 +: 16]);
        end
        $fclose(fd);
        $display("PASS: tb_mamba_soc_axi_lite_wrapper ITM zero case (check rtl_output.mem vs golden)");
        $finish;
    end
endmodule
