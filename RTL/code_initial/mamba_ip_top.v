`timescale 1ns/1ps

module mamba_ip_top #(
    parameter DATA_WIDTH = 16,
    parameter D_MODEL    = 64,
    parameter D_INNER    = 128,
    parameter D_STATE    = 16,
    parameter ADDR_WIDTH = 8,
    parameter REG_DATA_WIDTH = 32
) (
    input  wire                              clk,
    input  wire                              reset,

    // Simple register interface (to be adapted by AXI4-Lite adapter)
    input  wire                              reg_wr,
    input  wire                              reg_rd,
    input  wire [ADDR_WIDTH-1:0]             reg_addr,
    input  wire [REG_DATA_WIDTH-1:0]         reg_wdata,
    output wire [REG_DATA_WIDTH-1:0]         reg_rdata,
    output wire                              reg_ready,

    // Optional override for scan_clear (TB can pulse this)
    input  wire                              scan_clear_override,

    // Packed data interfaces (pass-through)
    input  wire [D_MODEL*DATA_WIDTH-1:0]     x_vec_packed,
    input  wire [D_MODEL*DATA_WIDTH-1:0]     gamma_packed,
    input  wire [D_INNER*D_MODEL*DATA_WIDTH-1:0] inproj_w_packed,
    input  wire [D_INNER*4*DATA_WIDTH-1:0]   conv_w_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     conv_b_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     delta_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     gate_packed,
    input  wire [D_STATE*DATA_WIDTH-1:0]     B_packed,
    input  wire [D_STATE*DATA_WIDTH-1:0]     C_packed,
    input  wire [D_INNER*D_STATE*DATA_WIDTH-1:0] A_packed,
    input  wire [D_INNER*DATA_WIDTH-1:0]     D_packed,
    input  wire [D_MODEL*D_INNER*DATA_WIDTH-1:0] outproj_w_packed,

    output wire                              rms_done,
    output wire                              inproj_done,
    output wire                              all_conv_valid,
    output wire                              all_scan_done,
    output wire                              outproj_done,

    output wire [D_MODEL*DATA_WIDTH-1:0]     rms_out_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     inproj_out_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     x_activated_packed,
    output wire [D_INNER*DATA_WIDTH-1:0]     y_scan_packed,
    output wire [D_MODEL*DATA_WIDTH-1:0]     final_out_packed,

    // CU status exported for TB/SoC
    output wire                              cu_busy,
    output wire                              cu_done,
    output wire                              cu_irq,
    // For convenience expose a packed `status_reg` output matching REG_STATUS format
    // (bits [1]=done, [0]=busy) so external adapters can sample status directly.
    output wire [31:0]                        status_reg
);

    // Register map (driven/implemented inside Mamba_Control_Unit):
    // - REG_CTRL   0x00 : write bits: [0]=start, [1]=step (optional), [2]=clear
    // - REG_STATUS 0x04 : read-only: [0]=busy, [1]=done
    // - REG_TOKENS 0x08 : write token count for test harness (optional)
    // - REG_TRACE  0x0C : trace control word (TRACE flags)

    // CU signals
    wire cu_rms_start;
    wire cu_rms_en;
    wire cu_inproj_start;
    wire cu_inproj_en;
    wire cu_conv_start;
    wire cu_conv_en;
    wire cu_conv_valid_in;
    wire cu_scan_start;
    wire cu_scan_en;
    wire cu_scan_clear_h;
    wire cu_outproj_start;
    wire cu_outproj_en;

    Mamba_Control_Unit #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(REG_DATA_WIDTH)) cu (
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
        .scan_clear_h(cu_scan_clear_h | scan_clear_override),
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
        .final_out_packed(final_out_packed)
    );

    // expose status_reg matching Mamba_Control_Unit REG_STATUS layout
    // {30'd0, done, busy}
    assign status_reg = {30'd0, cu_done, cu_busy};

endmodule
