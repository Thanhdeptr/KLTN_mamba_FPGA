`timescale 1ns/1ps
`include "_parameter.v"

// Fast reciprocal square-root using LUT seed + 2 Newton-Raphson iterations.
// x_in  : Q3.12
// y_out : Q3.12 (approx 1/sqrt(x_in))
module FastRsqrt_NR (
    input  wire              clk,
    input  wire              reset,
    input  wire              start,
    input  wire signed [31:0] x_in,
    output reg               valid,
    output reg  signed [15:0] y_out
);
    localparam signed [31:0] ONE_POINT_FIVE_Q312 = 32'sd6144; // 1.5 * 2^12

    (* rom_style = "distributed" *) reg [15:0] rsqrt_rom [0:63];
    reg [1:0] state;
    reg signed [31:0] x_reg;
    reg signed [15:0] y_reg;

    reg signed [63:0] mul64_a;
    reg signed [63:0] mul64_b;
    reg signed [31:0] y_sq_q312;
    reg signed [31:0] x_y_sq_q312;
    reg signed [31:0] correction_q312;
    reg signed [31:0] y_next_q312;
    reg [5:0] seed_addr;

    initial begin
        $readmemh("rmsnorm_rsqrt_coeffs.mem", rsqrt_rom);
    end

    function signed [15:0] sat16;
        input signed [31:0] v;
        begin
            if (v > 32'sd32767) sat16 = 16'sh7fff;
            else if (v < -32'sd32768) sat16 = 16'sh8000;
            else sat16 = v[15:0];
        end
    endfunction

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= 2'd0;
            x_reg <= 32'sd0;
            y_reg <= 16'sd0;
            y_sq_q312 <= 32'sd0;
            x_y_sq_q312 <= 32'sd0;
            correction_q312 <= 32'sd0;
            y_next_q312 <= 32'sd0;
            mul64_a <= 64'sd0;
            mul64_b <= 64'sd0;
            y_out <= 16'sd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (state)
                2'd0: begin
                    if (start) begin
                        x_reg <= (x_in <= 32'sd0) ? 32'sd1 : x_in;
                        seed_addr = (x_in <= 32'sd0) ? 6'd0 : x_in[15:10];
                        y_reg <= rsqrt_rom[seed_addr];
                        state <= 2'd1;
                    end
                end

                // NR iteration 1: y1 = y0 * (1.5 - 0.5*x*y0^2)
                2'd1: begin
                    mul64_a = $signed(y_reg) * $signed(y_reg);
                    y_sq_q312 <= mul64_a >>> `FRAC_BITS;

                    mul64_b = $signed(x_reg) * $signed(mul64_a >>> `FRAC_BITS);
                    x_y_sq_q312 <= mul64_b >>> `FRAC_BITS;

                    correction_q312 <= ONE_POINT_FIVE_Q312 - ((mul64_b >>> `FRAC_BITS) >>> 1);
                    y_next_q312 <= ($signed(y_reg) * $signed(ONE_POINT_FIVE_Q312 - ((mul64_b >>> `FRAC_BITS) >>> 1))) >>> `FRAC_BITS;
                    y_reg <= sat16(($signed(y_reg) * $signed(ONE_POINT_FIVE_Q312 - ((mul64_b >>> `FRAC_BITS) >>> 1))) >>> `FRAC_BITS);
                    state <= 2'd2;
                end

                // NR iteration 2 (improves RMS precision significantly)
                2'd2: begin
                    mul64_a = $signed(y_reg) * $signed(y_reg);
                    y_sq_q312 <= mul64_a >>> `FRAC_BITS;

                    mul64_b = $signed(x_reg) * $signed(mul64_a >>> `FRAC_BITS);
                    x_y_sq_q312 <= mul64_b >>> `FRAC_BITS;

                    correction_q312 <= ONE_POINT_FIVE_Q312 - ((mul64_b >>> `FRAC_BITS) >>> 1);
                    y_next_q312 <= ($signed(y_reg) * $signed(ONE_POINT_FIVE_Q312 - ((mul64_b >>> `FRAC_BITS) >>> 1))) >>> `FRAC_BITS;
                    y_out <= sat16(($signed(y_reg) * $signed(ONE_POINT_FIVE_Q312 - ((mul64_b >>> `FRAC_BITS) >>> 1))) >>> `FRAC_BITS);
                    valid <= 1'b1;
                    state <= 2'd0;
                end

                default: begin
                    state <= 2'd0;
                end
            endcase
        end
    end
endmodule

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

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_SUM  = 3'd1;
    localparam [2:0] ST_INV  = 3'd2;
    localparam [2:0] ST_NORM = 3'd3;

    reg [2:0] state;
    reg [6:0] lane_idx;

    reg signed [47:0] sum_sq_acc;
    reg signed [31:0] mean_sq_q312;
    reg               nr_start;
    reg               nr_kicked;
    wire              nr_valid;
    wire signed [15:0] inv_rms_q12;

    reg signed [15:0] x_lane;
    reg signed [15:0] gamma_lane;
    reg signed [31:0] sq_lane;
    reg signed [31:0] norm_tmp;
    reg signed [31:0] out_tmp;
    reg signed [31:0] norm_calc;
    reg signed [31:0] out_calc;

    FastRsqrt_NR u_fast_rsqrt (
        .clk(clk),
        .reset(reset),
        .start(nr_start),
        .x_in(mean_sq_q312),
        .valid(nr_valid),
        .y_out(inv_rms_q12)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;
            lane_idx <= 7'd0;
            sum_sq_acc <= 48'sd0;
            mean_sq_q312 <= 32'sd0;
            nr_start <= 1'b0;
            nr_kicked <= 1'b0;
            done <= 1'b0;
            y_vec <= {64*`DATA_WIDTH{1'b0}};
            x_lane <= 16'sd0;
            gamma_lane <= 16'sd0;
            sq_lane <= 32'sd0;
            norm_tmp <= 32'sd0;
            out_tmp <= 32'sd0;
        end else begin
            done <= 1'b0;
            nr_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    lane_idx <= 7'd0;
                    sum_sq_acc <= 48'sd0;
                    nr_kicked <= 1'b0;
                    if (start && en) begin
                        state <= ST_SUM;
                    end
                end

                ST_SUM: begin
                    x_lane = $signed(x_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH]);
                    sq_lane = ($signed(x_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH]) *
                               $signed(x_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH])) >>> `FRAC_BITS;

                    if (lane_idx == 7'd63) begin
                        sum_sq_acc <= sum_sq_acc + sq_lane;
                        mean_sq_q312 <= ((sum_sq_acc + sq_lane) >>> 6) + 32'sd1;
                        nr_kicked <= 1'b0;
                        lane_idx <= 7'd0;
                        state <= ST_INV;
                    end else begin
                        sum_sq_acc <= sum_sq_acc + sq_lane;
                        lane_idx <= lane_idx + 7'd1;
                    end
                end

                ST_INV: begin
                    if (!nr_kicked) begin
                        nr_start <= 1'b1;
                        nr_kicked <= 1'b1;
                    end
                    if (nr_valid) begin
                        lane_idx <= 7'd0;
                        nr_kicked <= 1'b0;
                        state <= ST_NORM;
                    end
                end

                ST_NORM: begin
                    x_lane = $signed(x_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH]);
                    gamma_lane = $signed(gamma_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH]);

                    // inv_rms_q12 is Q3.12, so keep standard fixed-point scaling.
                    norm_calc = (x_lane * inv_rms_q12) >>> `FRAC_BITS;
                    out_calc = (norm_calc * gamma_lane) >>> `FRAC_BITS;

                    norm_tmp <= norm_calc;
                    out_tmp <= out_calc;

                    if (out_calc > SAT_MAX)
                        y_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH] <= 16'sh7fff;
                    else if (out_calc < SAT_MIN)
                        y_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH] <= 16'sh8000;
                    else
                        y_vec[lane_idx*`DATA_WIDTH +: `DATA_WIDTH] <= out_calc[15:0];

                    if (lane_idx == 7'd63) begin
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        lane_idx <= lane_idx + 7'd1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
