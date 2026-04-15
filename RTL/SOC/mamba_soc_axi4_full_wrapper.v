`include "_parameter.v"

// AXI4-Full SoC wrapper for Mamba_Top (ITM-focused flow).
// - 32-bit data bus, INCR burst
// - packed lane mapping: one 32-bit beat = two 16-bit lanes
// - safe start gate: ready_to_start && !busy
// - byte-accurate WSTRB merge
// - output snapshot on itm_done to avoid tear-off

module mamba_soc_axi4_full_wrapper
(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Full write address channel
    input  wire [15:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire [2:0]  s_axi_awsize,
    input  wire [1:0]  s_axi_awburst,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    // AXI4-Full write data channel
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    // AXI4-Full write response channel
    output reg [1:0]   s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // AXI4-Full read address channel
    input  wire [15:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,
    input  wire [2:0]  s_axi_arsize,
    input  wire [1:0]  s_axi_arburst,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    // AXI4-Full read data channel
    output reg [31:0]  s_axi_rdata,
    output reg [1:0]   s_axi_rresp,
    output reg         s_axi_rlast,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);

    localparam [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;

    localparam [1:0] BURST_FIXED = 2'b00;
    localparam [1:0] BURST_INCR  = 2'b01;

    localparam [15:0] ADDR_CTRL         = 16'h0000;
    localparam [15:0] ADDR_MODE         = 16'h0004;
    localparam [15:0] ADDR_STATUS       = 16'h0008;
    localparam [15:0] ADDR_ITM_EN       = 16'h000C;
    localparam [15:0] ADDR_ERR_CODE     = 16'h0010;
    localparam [15:0] ADDR_VALID_LO     = 16'h0014;
    localparam [15:0] ADDR_VALID_HI     = 16'h0018;
    localparam [15:0] ADDR_VALID_HI2    = 16'h001C;

    localparam [15:0] BASE_FEAT         = 16'h0100; // 8 beats
    localparam [15:0] BASE_CONV_W       = 16'h0120; // 32 beats
    localparam [15:0] BASE_CONV_B       = 16'h01A0; // 8 beats
    localparam [15:0] BASE_SCAN_SCALAR  = 16'h01C0; // 2 beats
    localparam [15:0] BASE_SCAN_A       = 16'h01D0; // 8 beats
    localparam [15:0] BASE_SCAN_B       = 16'h01F0; // 8 beats
    localparam [15:0] BASE_SCAN_C       = 16'h0210; // 8 beats
    localparam [15:0] BASE_SCAN_CLEAR_H = 16'h0230; // 1 beat
    localparam [15:0] BASE_OUT_SHADOW   = 16'h0300; // 8 beats

    localparam [15:0] END_FEAT          = 16'h011F;
    localparam [15:0] END_CONV_W        = 16'h019F;
    localparam [15:0] END_CONV_B        = 16'h01BF;
    localparam [15:0] END_SCAN_SCALAR   = 16'h01C7;
    localparam [15:0] END_SCAN_A        = 16'h01EF;
    localparam [15:0] END_SCAN_B        = 16'h020F;
    localparam [15:0] END_SCAN_C        = 16'h022F;
    localparam [15:0] END_SCAN_CLEAR_H  = 16'h0233;
    localparam [15:0] END_OUT_SHADOW    = 16'h031F;

    localparam [31:0] ERR_NONE          = 32'h0000_0000;
    localparam [31:0] ERR_START_NOT_RDY = 32'h0000_0001;
    localparam [31:0] ERR_START_BUSY    = 32'h0000_0002;
    localparam [31:0] ERR_WRITE_BUSY    = 32'h0000_0003;
    localparam [31:0] ERR_BAD_ADDR      = 32'h0000_0004;
    localparam [31:0] ERR_BURST_CROSS   = 32'h0000_0005;

    localparam [6:0] REQUIRED_BEATS = 7'd74;

    reg [2:0] mode_select_reg;
    reg       itm_en_reg;

    reg       itm_done_sticky;
    reg       itm_valid_sticky;
    reg       start_reject_sticky;
    reg       error_sticky;
    reg       output_snapshot_valid;
    reg [31:0] err_code_reg;

    reg       busy_reg;
    reg       itm_start_pulse;

    reg [31:0] feat_mem [0:7];
    reg [31:0] conv_w_mem [0:31];
    reg [31:0] conv_b_mem [0:7];
    reg [31:0] scan_scalar_mem [0:1];
    reg [31:0] scan_A_mem [0:7];
    reg [31:0] scan_B_mem [0:7];
    reg [31:0] scan_C_mem [0:7];
    reg [31:0] out_shadow_mem [0:7];

    reg [73:0] input_valid_bits;

    reg [15:0] wr_addr_cur;
    reg [7:0]  wr_beats_left;
    reg [1:0]  wr_burst_type;
    reg        wr_active;
    reg        wr_error;
    reg [1:0]  wr_resp_latched;

    reg [15:0] rd_addr_cur;
    reg [7:0]  rd_beats_left;
    reg [1:0]  rd_burst_type;
    reg        rd_active;
    reg        rd_error;

    wire rst = ~aresetn;

    wire ready_to_start = (&input_valid_bits) && itm_en_reg;
    wire locked_inputs = busy_reg;

    wire itm_done_w;
    wire itm_valid_out_w;
    wire signed [16 * `DATA_WIDTH - 1 : 0] itm_out_vec_w;

    wire signed [16 * `DATA_WIDTH - 1 : 0] itm_feat_vec_w = {
        feat_mem[7], feat_mem[6], feat_mem[5], feat_mem[4],
        feat_mem[3], feat_mem[2], feat_mem[1], feat_mem[0]
    };

    wire signed [16 * 4 * `DATA_WIDTH - 1 : 0] itm_conv_w_vec_w = {
        conv_w_mem[31], conv_w_mem[30], conv_w_mem[29], conv_w_mem[28],
        conv_w_mem[27], conv_w_mem[26], conv_w_mem[25], conv_w_mem[24],
        conv_w_mem[23], conv_w_mem[22], conv_w_mem[21], conv_w_mem[20],
        conv_w_mem[19], conv_w_mem[18], conv_w_mem[17], conv_w_mem[16],
        conv_w_mem[15], conv_w_mem[14], conv_w_mem[13], conv_w_mem[12],
        conv_w_mem[11], conv_w_mem[10], conv_w_mem[9], conv_w_mem[8],
        conv_w_mem[7], conv_w_mem[6], conv_w_mem[5], conv_w_mem[4],
        conv_w_mem[3], conv_w_mem[2], conv_w_mem[1], conv_w_mem[0]
    };

    wire signed [16 * `DATA_WIDTH - 1 : 0] itm_conv_b_vec_w = {
        conv_b_mem[7], conv_b_mem[6], conv_b_mem[5], conv_b_mem[4],
        conv_b_mem[3], conv_b_mem[2], conv_b_mem[1], conv_b_mem[0]
    };

    wire signed [`DATA_WIDTH-1:0] itm_scan_delta_val_w = scan_scalar_mem[0][15:0];
    wire signed [`DATA_WIDTH-1:0] itm_scan_x_val_w     = scan_scalar_mem[0][31:16];
    wire signed [`DATA_WIDTH-1:0] itm_scan_D_val_w     = scan_scalar_mem[1][15:0];
    wire signed [`DATA_WIDTH-1:0] itm_scan_gate_val_w  = scan_scalar_mem[1][31:16];

    wire signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_A_vec_w = {
        scan_A_mem[7], scan_A_mem[6], scan_A_mem[5], scan_A_mem[4],
        scan_A_mem[3], scan_A_mem[2], scan_A_mem[1], scan_A_mem[0]
    };
    wire signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_B_vec_w = {
        scan_B_mem[7], scan_B_mem[6], scan_B_mem[5], scan_B_mem[4],
        scan_B_mem[3], scan_B_mem[2], scan_B_mem[1], scan_B_mem[0]
    };
    wire signed [16 * `DATA_WIDTH - 1 : 0] itm_scan_C_vec_w = {
        scan_C_mem[7], scan_C_mem[6], scan_C_mem[5], scan_C_mem[4],
        scan_C_mem[3], scan_C_mem[2], scan_C_mem[1], scan_C_mem[0]
    };

    reg  scan_clear_h_reg;
    wire itm_scan_clear_h_w = scan_clear_h_reg;

    // Unused mode signals tied off in this ITM-focused wrapper.
    wire        lin_done_w;
    wire        conv_valid_out_w;
    wire        conv_ready_in_w;
    wire        scan_done_w;
    wire signed [16 * `DATA_WIDTH - 1 : 0] lin_y_out_w;
    wire signed [16 * `DATA_WIDTH - 1 : 0] conv_y_vec_w;
    wire signed [`DATA_WIDTH-1:0] scan_y_out_w;
    wire signed [`DATA_WIDTH-1:0] softplus_out_w;

    function [31:0] apply_wstrb;
        input [31:0] old_word;
        input [31:0] new_word;
        input [3:0]  strb;
        reg [31:0] merged;
        begin
            merged = old_word;
            if (strb[0]) merged[7:0]   = new_word[7:0];
            if (strb[1]) merged[15:8]  = new_word[15:8];
            if (strb[2]) merged[23:16] = new_word[23:16];
            if (strb[3]) merged[31:24] = new_word[31:24];
            apply_wstrb = merged;
        end
    endfunction

    function in_input_region;
        input [15:0] addr;
        begin
            in_input_region =
                ((addr >= BASE_FEAT)        && (addr <= END_FEAT)) ||
                ((addr >= BASE_CONV_W)      && (addr <= END_CONV_W)) ||
                ((addr >= BASE_CONV_B)      && (addr <= END_CONV_B)) ||
                ((addr >= BASE_SCAN_SCALAR) && (addr <= END_SCAN_SCALAR)) ||
                ((addr >= BASE_SCAN_A)      && (addr <= END_SCAN_A)) ||
                ((addr >= BASE_SCAN_B)      && (addr <= END_SCAN_B)) ||
                ((addr >= BASE_SCAN_C)      && (addr <= END_SCAN_C)) ||
                ((addr >= BASE_SCAN_CLEAR_H)&& (addr <= END_SCAN_CLEAR_H));
        end
    endfunction

    function in_read_region;
        input [15:0] addr;
        begin
            in_read_region =
                (addr == ADDR_MODE) ||
                (addr == ADDR_STATUS) ||
                (addr == ADDR_ITM_EN) ||
                (addr == ADDR_ERR_CODE) ||
                (addr == ADDR_VALID_LO) ||
                (addr == ADDR_VALID_HI) ||
                (addr == ADDR_VALID_HI2) ||
                ((addr >= BASE_OUT_SHADOW) && (addr <= END_OUT_SHADOW));
        end
    endfunction

    function burst_crosses_region;
        input [15:0] start_addr;
        input [7:0]  len;
        reg [15:0] end_addr;
        begin
            end_addr = start_addr + ({8'd0, len} << 2) + 16'd3;
            burst_crosses_region = 1'b0;

            if ((start_addr >= BASE_FEAT) && (start_addr <= END_FEAT))
                burst_crosses_region = (end_addr > END_FEAT);
            else if ((start_addr >= BASE_CONV_W) && (start_addr <= END_CONV_W))
                burst_crosses_region = (end_addr > END_CONV_W);
            else if ((start_addr >= BASE_CONV_B) && (start_addr <= END_CONV_B))
                burst_crosses_region = (end_addr > END_CONV_B);
            else if ((start_addr == ADDR_CTRL) || (start_addr == ADDR_MODE) ||
                     (start_addr == ADDR_STATUS) || (start_addr == ADDR_ITM_EN) ||
                     (start_addr == ADDR_ERR_CODE) || (start_addr == ADDR_VALID_LO) ||
                     (start_addr == ADDR_VALID_HI) || (start_addr == ADDR_VALID_HI2))
                // CSR registers are single-beat only.
                burst_crosses_region = (len != 8'd0);
            else if ((start_addr >= BASE_SCAN_SCALAR) && (start_addr <= END_SCAN_SCALAR))
                burst_crosses_region = (end_addr > END_SCAN_SCALAR);
            else if ((start_addr >= BASE_SCAN_A) && (start_addr <= END_SCAN_A))
                burst_crosses_region = (end_addr > END_SCAN_A);
            else if ((start_addr >= BASE_SCAN_B) && (start_addr <= END_SCAN_B))
                burst_crosses_region = (end_addr > END_SCAN_B);
            else if ((start_addr >= BASE_SCAN_C) && (start_addr <= END_SCAN_C))
                burst_crosses_region = (end_addr > END_SCAN_C);
            else if ((start_addr >= BASE_SCAN_CLEAR_H) && (start_addr <= END_SCAN_CLEAR_H))
                burst_crosses_region = (end_addr > END_SCAN_CLEAR_H);
            else if ((start_addr >= BASE_OUT_SHADOW) && (start_addr <= END_OUT_SHADOW))
                burst_crosses_region = (end_addr > END_OUT_SHADOW);
            else
                burst_crosses_region = 1'b1;
        end
    endfunction

    task mark_input_valid;
        input [15:0] addr;
        begin
            if ((addr >= BASE_FEAT) && (addr <= END_FEAT))
                input_valid_bits[(addr - BASE_FEAT) >> 2] <= 1'b1;
            else if ((addr >= BASE_CONV_W) && (addr <= END_CONV_W))
                input_valid_bits[8 + ((addr - BASE_CONV_W) >> 2)] <= 1'b1;
            else if ((addr >= BASE_CONV_B) && (addr <= END_CONV_B))
                input_valid_bits[40 + ((addr - BASE_CONV_B) >> 2)] <= 1'b1;
            else if ((addr >= BASE_SCAN_SCALAR) && (addr <= END_SCAN_SCALAR))
                input_valid_bits[48 + ((addr - BASE_SCAN_SCALAR) >> 2)] <= 1'b1;
            else if ((addr >= BASE_SCAN_A) && (addr <= END_SCAN_A))
                input_valid_bits[50 + ((addr - BASE_SCAN_A) >> 2)] <= 1'b1;
            else if ((addr >= BASE_SCAN_B) && (addr <= END_SCAN_B))
                input_valid_bits[58 + ((addr - BASE_SCAN_B) >> 2)] <= 1'b1;
            else if ((addr >= BASE_SCAN_C) && (addr <= END_SCAN_C))
                input_valid_bits[66 + ((addr - BASE_SCAN_C) >> 2)] <= 1'b1;
        end
    endtask

    task write_data_word;
        input [15:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        integer idx;
        begin
            if ((addr >= BASE_FEAT) && (addr <= END_FEAT)) begin
                idx = (addr - BASE_FEAT) >> 2;
                feat_mem[idx] <= apply_wstrb(feat_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if ((addr >= BASE_CONV_W) && (addr <= END_CONV_W)) begin
                idx = (addr - BASE_CONV_W) >> 2;
                conv_w_mem[idx] <= apply_wstrb(conv_w_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if ((addr >= BASE_CONV_B) && (addr <= END_CONV_B)) begin
                idx = (addr - BASE_CONV_B) >> 2;
                conv_b_mem[idx] <= apply_wstrb(conv_b_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if ((addr >= BASE_SCAN_SCALAR) && (addr <= END_SCAN_SCALAR)) begin
                idx = (addr - BASE_SCAN_SCALAR) >> 2;
                scan_scalar_mem[idx] <= apply_wstrb(scan_scalar_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if ((addr >= BASE_SCAN_A) && (addr <= END_SCAN_A)) begin
                idx = (addr - BASE_SCAN_A) >> 2;
                scan_A_mem[idx] <= apply_wstrb(scan_A_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if ((addr >= BASE_SCAN_B) && (addr <= END_SCAN_B)) begin
                idx = (addr - BASE_SCAN_B) >> 2;
                scan_B_mem[idx] <= apply_wstrb(scan_B_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if ((addr >= BASE_SCAN_C) && (addr <= END_SCAN_C)) begin
                idx = (addr - BASE_SCAN_C) >> 2;
                scan_C_mem[idx] <= apply_wstrb(scan_C_mem[idx], data, strb);
                if (strb != 4'b0000) mark_input_valid(addr);
            end else if (addr == BASE_SCAN_CLEAR_H) begin
                // scan_clear_h is a 1-bit control; update only when byte lane 0 is enabled.
                if (strb[0])
                    scan_clear_h_reg <= data[0];
            end else if (addr == ADDR_MODE) begin
                if (strb[0]) mode_select_reg <= data[2:0];
            end else if (addr == ADDR_ITM_EN) begin
                if (strb[0]) itm_en_reg <= data[0];
            end else if (addr == ADDR_CTRL) begin
                if (strb[0] && data[1]) itm_done_sticky <= 1'b0;
                if (strb[0] && data[2]) itm_valid_sticky <= 1'b0;
                if (strb[0] && data[3]) begin
                    error_sticky <= 1'b0;
                    start_reject_sticky <= 1'b0;
                    err_code_reg <= ERR_NONE;
                end
                if (strb[0] && data[4]) begin
                    input_valid_bits <= {REQUIRED_BEATS{1'b0}};
                end
                if (strb[0] && data[0]) begin
                    if (!ready_to_start) begin
                        start_reject_sticky <= 1'b1;
                        error_sticky <= 1'b1;
                        err_code_reg <= ERR_START_NOT_RDY;
                    end else if (busy_reg) begin
                        start_reject_sticky <= 1'b1;
                        error_sticky <= 1'b1;
                        err_code_reg <= ERR_START_BUSY;
                    end else begin
                        itm_start_pulse <= 1'b1;
                        itm_done_sticky <= 1'b0;
                        itm_valid_sticky <= 1'b0;
                        output_snapshot_valid <= 1'b0;
                    end
                end
            end else begin
                // unmapped write ignored, response set by channel logic
            end
        end
    endtask

    function [31:0] read_data_word;
        input [15:0] addr;
        integer idx;
        begin
            read_data_word = 32'd0;
            if (addr == ADDR_MODE)
                read_data_word = {29'd0, mode_select_reg};
            else if (addr == ADDR_STATUS)
                read_data_word = {
                    24'd0,
                    output_snapshot_valid,
                    error_sticky,
                    start_reject_sticky,
                    locked_inputs,
                    ready_to_start,
                    busy_reg,
                    itm_valid_sticky,
                    itm_done_sticky
                };
            else if (addr == ADDR_ITM_EN)
                read_data_word = {31'd0, itm_en_reg};
            else if (addr == ADDR_ERR_CODE)
                read_data_word = err_code_reg;
            else if (addr == ADDR_VALID_LO)
                read_data_word = input_valid_bits[31:0];
            else if (addr == ADDR_VALID_HI)
                read_data_word = input_valid_bits[63:32];
            else if (addr == ADDR_VALID_HI2)
                read_data_word = {22'd0, input_valid_bits[73:64]};
            else if ((addr >= BASE_OUT_SHADOW) && (addr <= END_OUT_SHADOW)) begin
                idx = (addr - BASE_OUT_SHADOW) >> 2;
                read_data_word = out_shadow_mem[idx];
            end
        end
    endfunction

    Mamba_Top u_mamba (
        .clk(aclk),
        .reset(rst),
        .mode_select(mode_select_reg),

        .lin_start(1'b0),
        .lin_en(1'b0),
        .lin_len(16'd0),
        .lin_done(lin_done_w),
        .lin_x_val(16'sd0),
        .lin_W_vals({(16*`DATA_WIDTH){1'b0}}),
        .lin_bias_vals({(16*`DATA_WIDTH){1'b0}}),
        .lin_y_out(lin_y_out_w),

        .conv_start(1'b0),
        .conv_valid_in(1'b0),
        .conv_en(1'b0),
        .conv_valid_out(conv_valid_out_w),
        .conv_ready_in(conv_ready_in_w),
        .conv_x_vec({(16*`DATA_WIDTH){1'b0}}),
        .conv_w_vec({(16*4*`DATA_WIDTH){1'b0}}),
        .conv_b_vec({(16*`DATA_WIDTH){1'b0}}),
        .conv_y_vec(conv_y_vec_w),

        .scan_start(1'b0),
        .scan_en(1'b0),
        .scan_clear_h(1'b0),
        .scan_done(scan_done_w),
        .scan_delta_val(16'sd0),
        .scan_x_val(16'sd0),
        .scan_D_val(16'sd0),
        .scan_gate_val(16'sd0),
        .scan_A_vec({(16*`DATA_WIDTH){1'b0}}),
        .scan_B_vec({(16*`DATA_WIDTH){1'b0}}),
        .scan_C_vec({(16*`DATA_WIDTH){1'b0}}),
        .scan_y_out(scan_y_out_w),

        .softplus_in_val(16'sd0),
        .softplus_out_val(softplus_out_w),

        .itm_start(itm_start_pulse),
        .itm_en(itm_en_reg),
        .itm_done(itm_done_w),
        .itm_valid_out(itm_valid_out_w),
        .itm_out_vec(itm_out_vec_w),
        .itm_feat_vec(itm_feat_vec_w),
        .itm_conv_w_vec(itm_conv_w_vec_w),
        .itm_conv_b_vec(itm_conv_b_vec_w),
        .itm_scan_delta_val(itm_scan_delta_val_w),
        .itm_scan_x_val(itm_scan_x_val_w),
        .itm_scan_D_val(itm_scan_D_val_w),
        .itm_scan_gate_val(itm_scan_gate_val_w),
        .itm_scan_A_vec(itm_scan_A_vec_w),
        .itm_scan_B_vec(itm_scan_B_vec_w),
        .itm_scan_C_vec(itm_scan_C_vec_w),
        .itm_scan_clear_h(itm_scan_clear_h_w)
    );

    integer i;

    always @(posedge aclk or posedge rst) begin
        if (rst) begin
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b0;
            s_axi_bresp   <= AXI_RESP_OKAY;
            s_axi_bvalid  <= 1'b0;

            s_axi_arready <= 1'b1;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= AXI_RESP_OKAY;
            s_axi_rlast   <= 1'b0;
            s_axi_rdata   <= 32'd0;

            wr_addr_cur    <= 16'd0;
            wr_beats_left  <= 8'd0;
            wr_burst_type  <= BURST_INCR;
            wr_active      <= 1'b0;
            wr_error       <= 1'b0;
            wr_resp_latched<= AXI_RESP_OKAY;

            rd_addr_cur   <= 16'd0;
            rd_beats_left <= 8'd0;
            rd_burst_type <= BURST_INCR;
            rd_active     <= 1'b0;
            rd_error      <= 1'b0;

            mode_select_reg <= 3'd0;
            itm_en_reg      <= 1'b1;

            itm_done_sticky     <= 1'b0;
            itm_valid_sticky    <= 1'b0;
            start_reject_sticky <= 1'b0;
            error_sticky        <= 1'b0;
            output_snapshot_valid<= 1'b0;
            err_code_reg        <= ERR_NONE;

            busy_reg        <= 1'b0;
            itm_start_pulse <= 1'b0;
            scan_clear_h_reg <= 1'b0;

            input_valid_bits <= {REQUIRED_BEATS{1'b0}};

            for (i = 0; i < 8; i = i + 1) begin
                feat_mem[i] <= 32'd0;
                conv_b_mem[i] <= 32'd0;
                scan_A_mem[i] <= 32'd0;
                scan_B_mem[i] <= 32'd0;
                scan_C_mem[i] <= 32'd0;
                out_shadow_mem[i] <= 32'd0;
            end
            for (i = 0; i < 32; i = i + 1) begin
                conv_w_mem[i] <= 32'd0;
            end
            scan_scalar_mem[0] <= 32'd0;
            scan_scalar_mem[1] <= 32'd0;
        end else begin
            itm_start_pulse <= 1'b0;

            if (itm_done_w) begin
                itm_done_sticky <= 1'b1;
                busy_reg <= 1'b0;
                output_snapshot_valid <= 1'b1;
                for (i = 0; i < 8; i = i + 1)
                    out_shadow_mem[i] <= itm_out_vec_w[i*32 +: 32];
            end
            if (itm_valid_out_w)
                itm_valid_sticky <= 1'b1;

            // Write address handshake
            if (s_axi_awready && s_axi_awvalid) begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b1;
                wr_active     <= 1'b1;
                wr_addr_cur   <= s_axi_awaddr;
                wr_beats_left <= s_axi_awlen;
                wr_burst_type <= s_axi_awburst;
                wr_error      <= 1'b0;
                wr_resp_latched <= AXI_RESP_OKAY;

                if ((s_axi_awsize != 3'd2) || (s_axi_awburst != BURST_INCR && s_axi_awburst != BURST_FIXED)) begin
                    wr_error <= 1'b1;
                    wr_resp_latched <= AXI_RESP_SLVERR;
                    err_code_reg <= ERR_BAD_ADDR;
                    error_sticky <= 1'b1;
                end else if (burst_crosses_region(s_axi_awaddr, s_axi_awlen)) begin
                    wr_error <= 1'b1;
                    wr_resp_latched <= AXI_RESP_SLVERR;
                    err_code_reg <= ERR_BURST_CROSS;
                    error_sticky <= 1'b1;
                end
            end

            // Write data handshake
            if (wr_active && s_axi_wready && s_axi_wvalid) begin
                if (locked_inputs && in_input_region(wr_addr_cur)) begin
                    wr_error <= 1'b1;
                    wr_resp_latched <= AXI_RESP_SLVERR;
                    err_code_reg <= ERR_WRITE_BUSY;
                    error_sticky <= 1'b1;
                end else if (!wr_error) begin
                    write_data_word(wr_addr_cur, s_axi_wdata, s_axi_wstrb);
                    if ((wr_addr_cur == ADDR_CTRL) && s_axi_wstrb[0] && s_axi_wdata[0] && ready_to_start && !busy_reg)
                        busy_reg <= 1'b1;
                end

                if ((wr_beats_left == 0) || s_axi_wlast) begin
                    wr_active <= 1'b0;
                    s_axi_wready <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    if (wr_error || (locked_inputs && in_input_region(wr_addr_cur)))
                        s_axi_bresp <= AXI_RESP_SLVERR;
                    else
                        s_axi_bresp <= wr_resp_latched;
                end else begin
                    wr_beats_left <= wr_beats_left - 1'b1;
                    if (wr_burst_type == BURST_INCR)
                        wr_addr_cur <= wr_addr_cur + 16'd4;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                s_axi_awready <= 1'b1;
            end

            // Read address handshake
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b0;
                rd_active <= 1'b1;
                rd_addr_cur <= s_axi_araddr;
                rd_beats_left <= s_axi_arlen;
                rd_burst_type <= s_axi_arburst;
                rd_error <= 1'b0;

                if ((s_axi_arsize != 3'd2) || (s_axi_arburst != BURST_INCR && s_axi_arburst != BURST_FIXED)) begin
                    rd_error <= 1'b1;
                    s_axi_rresp <= AXI_RESP_SLVERR;
                end else if (burst_crosses_region(s_axi_araddr, s_axi_arlen)) begin
                    rd_error <= 1'b1;
                    s_axi_rresp <= AXI_RESP_SLVERR;
                end else begin
                    s_axi_rresp <= AXI_RESP_OKAY;
                end

                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= (in_read_region(s_axi_araddr) ? read_data_word(s_axi_araddr) : 32'd0);
                s_axi_rlast  <= (s_axi_arlen == 0);
            end else if (rd_active && s_axi_rvalid && s_axi_rready) begin
                if (rd_beats_left == 0) begin
                    rd_active <= 1'b0;
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast <= 1'b0;
                    s_axi_arready <= 1'b1;
                end else begin
                    rd_beats_left <= rd_beats_left - 1'b1;
                    if (rd_burst_type == BURST_INCR)
                        rd_addr_cur <= rd_addr_cur + 16'd4;

                    s_axi_rdata <= (in_read_region((rd_burst_type == BURST_INCR) ? (rd_addr_cur + 16'd4) : rd_addr_cur) ?
                                   read_data_word((rd_burst_type == BURST_INCR) ? (rd_addr_cur + 16'd4) : rd_addr_cur) : 32'd0);
                    s_axi_rlast <= (rd_beats_left == 1);
                end
            end
        end
    end

endmodule
