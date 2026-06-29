`timescale 1ns/1ps
`include "_parameter.v"

(* keep_hierarchy = "yes", use_dsp = "no" *)
module IntMul16x16 (
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output wire signed [31:0] prod
);
    assign prod = a * b;
endmodule

(* keep_hierarchy = "yes" *)
module IntMul32x32 (
    input  wire signed [31:0] a,
    input  wire signed [31:0] b,
    output wire signed [63:0] prod
);
    assign prod = a * b;
endmodule

// CLZ LUT seed + 1 NR iteration; uses external shared 32x32 multiplier.
module FastRsqrt_CLZ_LUT (
    input  wire               clk,
    input  wire               reset,
    input  wire               start,
    input  wire signed [31:0] x_in,
    input  wire signed [63:0] mul_prod,
    output wire signed [31:0] mul_op_a,
    output wire signed [31:0] mul_op_b,
    output wire               mul_active,
    output reg                valid,
    output reg signed [31:0]  y_out
);
    localparam signed [31:0] ONE_POINT_FIVE_Q312 = 32'sd6144;
    localparam integer NR_ITERS = 2;

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_Y_SQ  = 3'd1;
    localparam [2:0] S_X_YSQ = 3'd2;
    localparam [2:0] S_CORR  = 3'd3;
    localparam [2:0] S_Y_UPD = 3'd4;

    (* rom_style = "distributed" *) reg [31:0] rsqrt_rom [0:63];

    reg [2:0] state;
    reg [2:0] iter_cnt;

    reg signed [31:0] x_reg;
    reg signed [31:0] y_reg;
    reg signed [31:0] y_sq_q312;
    reg signed [31:0] x_y_sq_q312;
    reg signed [31:0] corr_q312;

    wire [31:0] x_abs_w   = (x_in <= 32'sd0) ? 32'd1 : x_in[31:0];
    wire [4:0]  msb_w     = x_abs_w[31] ? 5'd31 :
                            x_abs_w[30] ? 5'd30 :
                            x_abs_w[29] ? 5'd29 :
                            x_abs_w[28] ? 5'd28 :
                            x_abs_w[27] ? 5'd27 :
                            x_abs_w[26] ? 5'd26 :
                            x_abs_w[25] ? 5'd25 :
                            x_abs_w[24] ? 5'd24 :
                            x_abs_w[23] ? 5'd23 :
                            x_abs_w[22] ? 5'd22 :
                            x_abs_w[21] ? 5'd21 :
                            x_abs_w[20] ? 5'd20 :
                            x_abs_w[19] ? 5'd19 :
                            x_abs_w[18] ? 5'd18 :
                            x_abs_w[17] ? 5'd17 :
                            x_abs_w[16] ? 5'd16 :
                            x_abs_w[15] ? 5'd15 :
                            x_abs_w[14] ? 5'd14 :
                            x_abs_w[13] ? 5'd13 :
                            x_abs_w[12] ? 5'd12 :
                            x_abs_w[11] ? 5'd11 :
                            x_abs_w[10] ? 5'd10 :
                            x_abs_w[ 9] ? 5'd9  :
                            x_abs_w[ 8] ? 5'd8  :
                            x_abs_w[ 7] ? 5'd7  :
                            x_abs_w[ 6] ? 5'd6  :
                            x_abs_w[ 5] ? 5'd5  :
                            x_abs_w[ 4] ? 5'd4  :
                            x_abs_w[ 3] ? 5'd3  :
                            x_abs_w[ 2] ? 5'd2  :
                            x_abs_w[ 1] ? 5'd1  :
                            5'd0;
    wire [31:0] x_norm_w  = (msb_w >= 5'd14) ? (x_abs_w >> (msb_w - 5'd14))
                                             : (x_abs_w << (5'd14 - msb_w));
    wire [5:0]  seed_addr_w = {msb_w[3:0], x_norm_w[13:12]};

    assign mul_active = (state == S_Y_SQ) || (state == S_X_YSQ) || (state == S_Y_UPD);

    assign mul_op_a = (state == S_Y_SQ)   ? y_reg :
                      (state == S_X_YSQ) ? x_reg :
                      (state == S_Y_UPD) ? y_reg : 32'sd0;

    assign mul_op_b = (state == S_Y_SQ)   ? y_reg :
                      (state == S_X_YSQ) ? y_sq_q312 :
                      (state == S_Y_UPD) ? corr_q312 : 32'sd0;

    initial begin
        $readmemh("rmsnorm_rsqrt_coeffs.mem", rsqrt_rom);
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= S_IDLE;
            iter_cnt     <= 3'd0;
            x_reg        <= 32'sd0;
            y_reg        <= 32'sd0;
            y_sq_q312    <= 32'sd0;
            x_y_sq_q312  <= 32'sd0;
            corr_q312    <= 32'sd0;
            y_out        <= 32'sd0;
            valid        <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        x_reg <= $signed(x_abs_w);
                        y_reg <= $signed(rsqrt_rom[seed_addr_w]);
                        iter_cnt <= 3'd0;
                        state <= S_Y_SQ;
                    end
                end

                S_Y_SQ: begin
                    y_sq_q312 <= mul_prod >>> `FRAC_BITS;
                    state     <= S_X_YSQ;
                end

                S_X_YSQ: begin
                    x_y_sq_q312 <= mul_prod >>> `FRAC_BITS;
                    state       <= S_CORR;
                end

                S_CORR: begin
                    corr_q312 <= ONE_POINT_FIVE_Q312 - (x_y_sq_q312 >>> 1);
                    state     <= S_Y_UPD;
                end

                S_Y_UPD: begin
                    y_reg <= mul_prod >>> `FRAC_BITS;

                    if (iter_cnt == NR_ITERS - 1) begin
                        y_out <= mul_prod >>> `FRAC_BITS;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        iter_cnt <= iter_cnt + 3'd1;
                        state    <= S_Y_SQ;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// 2-way parallel RMSNorm with 2 shared 32x32 multipliers (rsqrt + norm X/GW).
module RMSNorm_Unit_IntSqrt
(
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          start,
    input  wire                          en,
    output reg                           done,

    input  wire [64*`DATA_WIDTH-1:0]     x_vec,
    input  wire [64*`DATA_WIDTH-1:0]     gamma_vec,

    output reg  [64*`DATA_WIDTH-1:0]     y_vec
);

    localparam integer NUM_PAIRS = 32;

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_SUM     = 3'd1;
    localparam [2:0] ST_SUM_FIN = 3'd2;
    localparam [2:0] ST_INV     = 3'd3;
    localparam [2:0] ST_NORM_X  = 3'd4;
    localparam [2:0] ST_NORM_GW = 3'd5;

    reg [2:0] state;
    reg [5:0] pair_idx;

    reg signed [47:0] sum_sq_acc;
    reg signed [31:0] mean_sq_q312;
    reg               rsqrt_start;
    reg               rsqrt_kicked;
    wire              rsqrt_valid;
    wire signed [31:0] inv_rms_q32;

    wire [6:0] lane0_idx = {pair_idx, 1'b0};
    wire [6:0] lane1_idx = {pair_idx, 1'b1};
    wire [5:0] next_pair_idx = pair_idx + 6'd1;
    wire [6:0] next_lane0_idx = {next_pair_idx, 1'b0};
    wire [6:0] next_lane1_idx = {next_pair_idx, 1'b1};

    wire signed [15:0] x0_w = $signed(x_vec[lane0_idx*`DATA_WIDTH +: `DATA_WIDTH]);
    wire signed [15:0] x1_w = $signed(x_vec[lane1_idx*`DATA_WIDTH +: `DATA_WIDTH]);
    wire signed [15:0] g0_w = $signed(gamma_vec[lane0_idx*`DATA_WIDTH +: `DATA_WIDTH]);
    wire signed [15:0] g1_w = $signed(gamma_vec[lane1_idx*`DATA_WIDTH +: `DATA_WIDTH]);

    wire signed [15:0] nx0_w = $signed(x_vec[next_lane0_idx*`DATA_WIDTH +: `DATA_WIDTH]);
    wire signed [15:0] nx1_w = $signed(x_vec[next_lane1_idx*`DATA_WIDTH +: `DATA_WIDTH]);
    wire signed [15:0] ng0_w = $signed(gamma_vec[next_lane0_idx*`DATA_WIDTH +: `DATA_WIDTH]);
    wire signed [15:0] ng1_w = $signed(gamma_vec[next_lane1_idx*`DATA_WIDTH +: `DATA_WIDTH]);

    wire signed [31:0] x0_ext = {{16{x0_w[15]}}, x0_w};
    wire signed [31:0] x1_ext = {{16{x1_w[15]}}, x1_w};
    wire signed [31:0] g0_ext = {{16{g0_w[15]}}, g0_w};
    wire signed [31:0] g1_ext = {{16{g1_w[15]}}, g1_w};
    wire signed [31:0] nx0_ext = {{16{nx0_w[15]}}, nx0_w};
    wire signed [31:0] nx1_ext = {{16{nx1_w[15]}}, nx1_w};
    wire signed [31:0] ng0_ext = {{16{ng0_w[15]}}, ng0_w};
    wire signed [31:0] ng1_ext = {{16{ng1_w[15]}}, ng1_w};

    (* keep = "true" *) reg signed [31:0] x_lane_r0;
    (* keep = "true" *) reg signed [31:0] x_lane_r1;
    (* keep = "true" *) reg signed [31:0] gamma_lane_r0;
    (* keep = "true" *) reg signed [31:0] gamma_lane_r1;
    (* keep = "true" *) reg signed [31:0] norm_q0;
    (* keep = "true" *) reg signed [31:0] norm_q1;

    wire signed [31:0] sum_sq_prod0;
    wire signed [31:0] sum_sq_prod1;
    wire signed [31:0] sum_sq_lane0;
    wire signed [31:0] sum_sq_lane1;

    reg signed [31:0] sh_mul_a0;
    reg signed [31:0] sh_mul_b0;
    reg signed [31:0] sh_mul_a1;
    reg signed [31:0] sh_mul_b1;
    wire signed [63:0] sh_mul_prod0;
    wire signed [63:0] sh_mul_prod1;

    wire signed [63:0] norm_x_prod0;
    wire signed [63:0] norm_x_prod1;
    wire signed [63:0] norm_gw_prod0;
    wire signed [63:0] norm_gw_prod1;

    wire signed [31:0] out_calc0;
    wire signed [31:0] out_calc1;

    wire signed [31:0] rsq_mul_a;
    wire signed [31:0] rsq_mul_b;
    wire               rsq_mul_active;

    IntMul16x16 u_sum_mul0 (.a(x0_w), .b(x0_w), .prod(sum_sq_prod0));
    IntMul16x16 u_sum_mul1 (.a(x1_w), .b(x1_w), .prod(sum_sq_prod1));

    assign sum_sq_lane0 = sum_sq_prod0 >>> `FRAC_BITS;
    assign sum_sq_lane1 = sum_sq_prod1 >>> `FRAC_BITS;

  IntMul32x32 u_sh_mul0 (.a(sh_mul_a0), .b(sh_mul_b0), .prod(sh_mul_prod0));
  IntMul32x32 u_sh_mul1 (.a(sh_mul_a1), .b(sh_mul_b1), .prod(sh_mul_prod1));

    assign norm_x_prod0  = sh_mul_prod0;
    assign norm_x_prod1  = sh_mul_prod1;
    assign norm_gw_prod0   = sh_mul_prod0;
    assign norm_gw_prod1   = sh_mul_prod1;

    assign out_calc0 = norm_gw_prod0 >>> `FRAC_BITS;
    assign out_calc1 = norm_gw_prod1 >>> `FRAC_BITS;

    always @(*) begin
        sh_mul_a0 = 32'sd0;
        sh_mul_b0 = 32'sd0;
        sh_mul_a1 = 32'sd0;
        sh_mul_b1 = 32'sd0;

        if (state == ST_NORM_X) begin
            sh_mul_a0 = x_lane_r0;
            sh_mul_b0 = inv_rms_q32;
            sh_mul_a1 = x_lane_r1;
            sh_mul_b1 = inv_rms_q32;
        end else if (state == ST_NORM_GW) begin
            sh_mul_a0 = norm_q0;
            sh_mul_b0 = gamma_lane_r0;
            sh_mul_a1 = norm_q1;
            sh_mul_b1 = gamma_lane_r1;
        end else if (rsq_mul_active) begin
            sh_mul_a0 = rsq_mul_a;
            sh_mul_b0 = rsq_mul_b;
        end
    end

    FastRsqrt_CLZ_LUT u_fast_rsqrt (
        .clk(clk),
        .reset(reset),
        .start(rsqrt_start),
        .x_in(mean_sq_q312),
        .mul_prod(sh_mul_prod0),
        .mul_op_a(rsq_mul_a),
        .mul_op_b(rsq_mul_b),
        .mul_active(rsq_mul_active),
        .valid(rsqrt_valid),
        .y_out(inv_rms_q32)
    );

    function automatic [15:0] sat16;
        input signed [31:0] val;
        begin
            if (val > SAT_MAX)
                sat16 = 16'sh7fff;
            else if (val < SAT_MIN)
                sat16 = 16'sh8000;
            else
                sat16 = val[15:0];
        end
    endfunction

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;
            pair_idx <= 6'd0;
            sum_sq_acc <= 48'sd0;
            mean_sq_q312 <= 32'sd0;
            rsqrt_start <= 1'b0;
            rsqrt_kicked <= 1'b0;
            done <= 1'b0;
            y_vec <= {64*`DATA_WIDTH{1'b0}};
            x_lane_r0 <= 32'sd0;
            x_lane_r1 <= 32'sd0;
            gamma_lane_r0 <= 32'sd0;
            gamma_lane_r1 <= 32'sd0;
            norm_q0 <= 32'sd0;
            norm_q1 <= 32'sd0;
        end else begin
            done <= 1'b0;
            rsqrt_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    pair_idx <= 6'd0;
                    sum_sq_acc <= 48'sd0;
                    rsqrt_kicked <= 1'b0;
                    if (start && en) begin
                        state <= ST_SUM;
                    end
                end

                ST_SUM: begin
                    sum_sq_acc <= sum_sq_acc + sum_sq_lane0 + sum_sq_lane1;

                    if (pair_idx == NUM_PAIRS - 1) begin
                        rsqrt_kicked <= 1'b0;
                        state <= ST_SUM_FIN;
                    end else begin
                        pair_idx <= pair_idx + 6'd1;
                    end
                end

                ST_SUM_FIN: begin
                    mean_sq_q312 <= (sum_sq_acc >>> 6) + 32'sd1;
                    pair_idx <= 6'd0;
                    state <= ST_INV;
                end

                ST_INV: begin
                    if (!rsqrt_kicked) begin
                        rsqrt_start <= 1'b1;
                        rsqrt_kicked <= 1'b1;
                    end
                    if (rsqrt_valid) begin
                        pair_idx <= 6'd0;
                        rsqrt_kicked <= 1'b0;
                        x_lane_r0 <= x0_ext;
                        x_lane_r1 <= x1_ext;
                        gamma_lane_r0 <= g0_ext;
                        gamma_lane_r1 <= g1_ext;
                        state <= ST_NORM_X;
                    end
                end

                ST_NORM_X: begin
                    norm_q0 <= norm_x_prod0 >>> `FRAC_BITS;
                    norm_q1 <= norm_x_prod1 >>> `FRAC_BITS;
                    state <= ST_NORM_GW;
                end

                ST_NORM_GW: begin
                    y_vec[lane0_idx*`DATA_WIDTH +: `DATA_WIDTH] <= sat16(out_calc0);
                    y_vec[lane1_idx*`DATA_WIDTH +: `DATA_WIDTH] <= sat16(out_calc1);

                    if (pair_idx == NUM_PAIRS - 1) begin
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        pair_idx <= next_pair_idx;
                        x_lane_r0 <= nx0_ext;
                        x_lane_r1 <= nx1_ext;
                        gamma_lane_r0 <= ng0_ext;
                        gamma_lane_r1 <= ng1_ext;
                        state <= ST_NORM_X;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
