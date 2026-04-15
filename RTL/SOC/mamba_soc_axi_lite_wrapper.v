`include "_parameter.v"

// Minimal SoC wrapper: AXI4-Lite CSR + Mamba_Top dataports on the boundary.
// CSR map (byte address, 32-bit):
//   0x000  CTRL     W: bit0 pulses itm_start for one cycle when write beats complete
//   0x004  MODE     RW: [2:0] mode_select
//   0x008  STATUS   RO: [0]=itm_done sticky [1]=itm_valid sticky (latched until next CTRL start pulse)
//   0x00C  ITM_EN   RW: bit0 itm_en (default 1)

module mamba_soc_axi_lite_wrapper
(
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output reg [1:0]   s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg [31:0]  s_axi_rdata,
    output reg [1:0]   s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire signed [16 * `DATA_WIDTH - 1 : 0] lin_W_vals,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] lin_bias_vals,
    output wire signed [16 * `DATA_WIDTH - 1 : 0] lin_y_out,

    input  wire signed [16 * `DATA_WIDTH - 1 : 0] conv_x_vec,
    input  wire signed [16 * 4 * `DATA_WIDTH - 1 : 0] conv_w_vec,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] conv_b_vec,
    output wire signed [16 * `DATA_WIDTH - 1 : 0] conv_y_vec,

    input  wire signed [`DATA_WIDTH-1:0] scan_delta_val,
    input  wire signed [`DATA_WIDTH-1:0] scan_x_val,
    input  wire signed [`DATA_WIDTH-1:0] scan_D_val,
    input  wire signed [`DATA_WIDTH-1:0] scan_gate_val,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] scan_A_vec,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] scan_B_vec,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] scan_C_vec,
    output wire signed [`DATA_WIDTH-1:0] scan_y_out,

    input  wire signed [`DATA_WIDTH-1:0] softplus_in_val,
    output wire signed [`DATA_WIDTH-1:0] softplus_out_val,

    input  wire signed [16 * `DATA_WIDTH - 1 : 0] itm_feat_vec,
    input  wire signed [16 * 4 * `DATA_WIDTH - 1 : 0] itm_conv_w_vec,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] itm_conv_b_vec,
    input  wire signed [`DATA_WIDTH-1:0] itm_scan_delta_val,
    input  wire signed [`DATA_WIDTH-1:0] itm_scan_x_val,
    input  wire signed [`DATA_WIDTH-1:0] itm_scan_D_val,
    input  wire signed [`DATA_WIDTH-1:0] itm_scan_gate_val,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_A_vec,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_B_vec,
    input  wire signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_C_vec,
    input  wire        itm_scan_clear_h,
    output wire signed [16 * `DATA_WIDTH - 1 : 0] itm_out_vec
);

    localparam [11:0] ADDR_CTRL   = 12'h000;
    localparam [11:0] ADDR_MODE   = 12'h004;
    localparam [11:0] ADDR_STATUS = 12'h008;
    localparam [11:0] ADDR_ITM_EN = 12'h00C;

    wire rst = ~aresetn;

    reg [2:0] mode_select_reg;
    reg       itm_en_reg;
    reg       itm_start_pulse;

    wire        lin_done_w;
    wire        conv_valid_out_w;
    wire        conv_ready_in_w;
    wire        scan_done_w;
    wire        itm_done_w;
    wire        itm_valid_out_w;

    // Sticky status bits (ITM pulses done/valid for one cycle; CPU polls AXI slowly)
    reg itm_done_sticky;
    reg itm_valid_sticky;

    wire        lin_start_w = 1'b0;
    wire        lin_en_w    = 1'b0;
    wire [15:0] lin_len_w   = 16'd0;
    wire signed [`DATA_WIDTH-1:0] lin_x_val_w = 16'sd0;

    wire        conv_start_w    = 1'b0;
    wire        conv_valid_in_w = 1'b0;
    wire        conv_en_w       = 1'b0;

    wire        scan_start_w   = 1'b0;
    wire        scan_en_w      = 1'b0;
    wire        scan_clear_h_w = 1'b0;

    Mamba_Top u_mamba (
        .clk(aclk),
        .reset(rst),
        .mode_select(mode_select_reg),
        .lin_start(lin_start_w),
        .lin_en(lin_en_w),
        .lin_len(lin_len_w),
        .lin_done(lin_done_w),
        .lin_x_val(lin_x_val_w),
        .lin_W_vals(lin_W_vals),
        .lin_bias_vals(lin_bias_vals),
        .lin_y_out(lin_y_out),
        .conv_start(conv_start_w),
        .conv_valid_in(conv_valid_in_w),
        .conv_en(conv_en_w),
        .conv_valid_out(conv_valid_out_w),
        .conv_ready_in(conv_ready_in_w),
        .conv_x_vec(conv_x_vec),
        .conv_w_vec(conv_w_vec),
        .conv_b_vec(conv_b_vec),
        .conv_y_vec(conv_y_vec),
        .scan_start(scan_start_w),
        .scan_en(scan_en_w),
        .scan_clear_h(scan_clear_h_w),
        .scan_done(scan_done_w),
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
        .itm_start(itm_start_pulse),
        .itm_en(itm_en_reg),
        .itm_done(itm_done_w),
        .itm_valid_out(itm_valid_out_w),
        .itm_out_vec(itm_out_vec),
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
        .itm_scan_clear_h(itm_scan_clear_h)
    );

    // Write response channel: accept AW+W when B idle
    wire wr_accept = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_accept;
    assign s_axi_wready  = wr_accept;

    always @(posedge aclk or posedge rst) begin
        if (rst) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp   <= 2'b00;
        end else begin
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
            else if (wr_accept)
                s_axi_bvalid <= 1'b1;
        end
    end

    // CSR update + ITM start pulse + sticky done/valid for software polling
    always @(posedge aclk or posedge rst) begin
        if (rst) begin
            mode_select_reg   <= 3'd0;
            itm_en_reg        <= 1'b1;
            itm_start_pulse   <= 1'b0;
            itm_done_sticky    <= 1'b0;
            itm_valid_sticky  <= 1'b0;
        end else begin
            itm_start_pulse <= 1'b0;
            if (itm_done_w)
                itm_done_sticky <= 1'b1;
            if (itm_valid_out_w)
                itm_valid_sticky <= 1'b1;
            if (wr_accept) begin
                case (s_axi_awaddr)
                    ADDR_CTRL: begin
                        if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
                            itm_start_pulse   <= 1'b1;
                            itm_done_sticky   <= 1'b0;
                            itm_valid_sticky  <= 1'b0;
                        end
                    end
                    ADDR_MODE: begin
                        if (s_axi_wstrb[0])
                            mode_select_reg <= s_axi_wdata[2:0];
                    end
                    ADDR_ITM_EN: begin
                        if (s_axi_wstrb[0])
                            itm_en_reg <= s_axi_wdata[0];
                    end
                    default: ;
                endcase
            end
        end
    end

    // AXI read: when arready&&arvalid, same cycle assert rvalid+rdata (combinational addr)
    always @(posedge aclk or posedge rst) begin
        if (rst) begin
            s_axi_arready <= 1'b1;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid  <= 1'b0;
                s_axi_arready <= 1'b1;
            end else if (s_axi_arready && s_axi_arvalid) begin
                s_axi_arready  <= 1'b0;
                s_axi_rvalid   <= 1'b1;
                s_axi_rresp    <= 2'b00;
                case (s_axi_araddr)
                    ADDR_MODE:   s_axi_rdata <= {29'd0, mode_select_reg};
                    ADDR_STATUS: s_axi_rdata <= {30'd0, itm_valid_sticky, itm_done_sticky};
                    ADDR_ITM_EN: s_axi_rdata <= {31'd0, itm_en_reg};
                    default:     s_axi_rdata <= 32'd0;
                endcase
            end
        end
    end

endmodule
