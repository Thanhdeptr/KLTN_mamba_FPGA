`timescale 1ns/1ps
`include "_parameter.v"

// Streaming OutProj v2: Scan y_gated beats (16 lanes / grp) -> 64-dim token output.
// NUM_MAC = sole parallelism knob (1..16 parallel Q3.12 multipliers per cycle).
//   cycles/row = ceil(16 / NUM_MAC),  cycles/beat = 64 * cycles/row.
// Elaboration override: xelab ... --define NUM_MAC=8
// Weight layout matches Out_Projection_Unit: w_matrix[row*128 + col], row-major 64x128 Q3.12.
module Out_Projection_Streaming_v2 #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS  = 12,
    parameter LANES      = 16,
    parameter D_IN       = 128,
    parameter D_OUT      = 64,
    parameter NUM_GRP    = 8,
    parameter NUM_MAC    = 16,
    parameter WEIGHT_INIT_FILE  = "outproj_weight.mem"
) (
    input  wire clk,
    input  wire rst_n,
    input  wire en,

    input  wire                               beat_valid,
    input  wire [15:0]                        beat_token,
    input  wire [2:0]                         beat_grp,
    input  wire signed [LANES*DATA_WIDTH-1:0] beat_vec,
    output wire                               beat_ready,

    output reg                                out_valid,
    output reg  [15:0]                        out_token,
    output reg  signed [D_OUT*DATA_WIDTH-1:0] out_vec,
    output reg                                busy
);

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;
    localparam ACC_W = 48;

    localparam S_IDLE  = 2'd0;
    localparam S_MAC   = 2'd1;
    localparam S_FINAL = 2'd2;

    reg [1:0] state;
    reg [15:0] active_token;
    reg [2:0]  lat_grp;
    reg signed [LANES*DATA_WIDTH-1:0] lat_vec;
    reg [NUM_GRP-1:0] grp_mask;

    reg [5:0] row_idx;
    reg [3:0] lane_start;

    reg signed [ACC_W-1:0] acc [0:D_OUT-1];

    localparam integer EFF_MAC = (NUM_MAC >= LANES) ? LANES : NUM_MAC;
    localparam integer W_WORDS = D_OUT * D_IN;

    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] w_bram [0:W_WORDS-1];

    integer gi, mi, wi;
    reg signed [ACC_W-1:0] partial_sum;
    reg [3:0] lane_idx;
    reg [6:0] col_idx;
    reg signed [DATA_WIDTH-1:0] x_lane, w_val;
    (* use_dsp = "yes" *) reg signed [31:0] prod;
    reg signed [47:0] scaled;
    reg signed [15:0] sat_out;

    assign beat_ready = en && (state == S_IDLE);

    initial begin
        $readmemh(WEIGHT_INIT_FILE, w_bram);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            active_token <= 16'd0;
            lat_grp      <= 3'd0;
            lat_vec      <= {(LANES*DATA_WIDTH){1'b0}};
            grp_mask     <= {NUM_GRP{1'b0}};
            row_idx      <= 6'd0;
            lane_start   <= 4'd0;
            out_valid    <= 1'b0;
            out_token    <= 16'd0;
            out_vec      <= {(D_OUT*DATA_WIDTH){1'b0}};
            busy         <= 1'b0;
            for (gi = 0; gi < D_OUT; gi = gi + 1)
                acc[gi] <= {ACC_W{1'b0}};
        end else begin
            out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (en && beat_valid && beat_ready) begin
                        if (beat_token != active_token) begin
                            active_token <= beat_token;
                            grp_mask     <= {NUM_GRP{1'b0}};
                            for (gi = 0; gi < D_OUT; gi = gi + 1)
                                acc[gi] <= {ACC_W{1'b0}};
                        end
                        lat_grp    <= beat_grp;
                        lat_vec    <= beat_vec;
                        row_idx    <= 6'd0;
                        lane_start <= 4'd0;
                        state      <= S_MAC;
                        busy       <= 1'b1;
                    end
                end

                S_MAC: begin
                    partial_sum = {ACC_W{1'b0}};
                    for (mi = 0; mi < EFF_MAC; mi = mi + 1) begin
                        lane_idx = lane_start + mi[3:0];
                        if (lane_idx < LANES) begin
                            col_idx = lat_grp * LANES + lane_idx;
                            x_lane  = lat_vec[lane_idx*DATA_WIDTH +: DATA_WIDTH];
                            w_val   = w_bram[row_idx * D_IN + col_idx];
                            prod    = x_lane * w_val;
                            partial_sum = partial_sum + $signed(prod);
                        end
                    end
                    acc[row_idx] <= acc[row_idx] + partial_sum;

                    if (lane_start + EFF_MAC >= LANES) begin
                        lane_start <= 4'd0;
                        if (row_idx == D_OUT - 1) begin
                            grp_mask[lat_grp] <= 1'b1;
                            if (&(grp_mask | (8'd1 << lat_grp))) begin
                                state <= S_FINAL;
                            end else begin
                                state <= S_IDLE;
                                busy  <= 1'b0;
                            end
                        end else begin
                            row_idx <= row_idx + 6'd1;
                        end
                    end else begin
                        lane_start <= lane_start + EFF_MAC[3:0];
                    end
                end

                S_FINAL: begin
                    for (gi = 0; gi < D_OUT; gi = gi + 1) begin
                        scaled = acc[gi] >>> FRAC_BITS;
                        if (scaled > SAT_MAX)
                            sat_out = 16'sh7fff;
                        else if (scaled < SAT_MIN)
                            sat_out = 16'sh8000;
                        else
                            sat_out = scaled[15:0];
                        out_vec[gi*DATA_WIDTH +: DATA_WIDTH] <= sat_out;
                    end
                    out_valid <= 1'b1;
                    out_token <= active_token;
                    grp_mask  <= {NUM_GRP{1'b0}};
                    for (gi = 0; gi < D_OUT; gi = gi + 1)
                        acc[gi] <= {ACC_W{1'b0}};
                    state <= S_IDLE;
                    busy  <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
