`timescale 1ns/1ps
`include "_parameter.v"

// Time-multiplexed In-Projection Unit
// - Uses 16 physical lanes and reuses them across 8 groups to compute all 128 outputs
// - Processes X first, then Z, to match the Mamba in-projection split
// - Keeps a packed y_vec output for existing testbenches

module In_Projection_Unit_Pipelined
(
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          start,
    input  wire                          en,
    output reg                           done_x,
    output reg                           done_z,

    input  wire [64*`DATA_WIDTH-1:0]     x_vec,
    input  wire [128*64*`DATA_WIDTH-1:0]  w_matrix,

    output wire [128*`DATA_WIDTH-1:0]    y_vec,
    output wire [64*`DATA_WIDTH-1:0]      y_x_vec,
    output wire [64*`DATA_WIDTH-1:0]      y_z_vec
);

    localparam integer X_LANES   = 64;
    localparam integer Z_LANES   = 64;
    localparam integer LANES_PAR = 16;
    localparam integer X_GROUPS  = X_LANES / LANES_PAR;  // 4
    localparam integer Z_GROUPS  = Z_LANES / LANES_PAR;  // 4

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_X    = 2'd1;
    localparam [1:0] S_Z    = 2'd2;

    reg [1:0] state;
    integer group_idx;

    reg signed [`DATA_WIDTH-1:0] y_x_buf [0:X_LANES-1];
    reg signed [`DATA_WIDTH-1:0] y_z_buf [0:Z_LANES-1];

    integer i;

    function automatic signed [`DATA_WIDTH-1:0] sat_q312;
        input signed [31:0] value;
        begin
            if (value > SAT_MAX) begin
                sat_q312 = SAT_MAX[`DATA_WIDTH-1:0];
            end else if (value < SAT_MIN) begin
                sat_q312 = SAT_MIN[`DATA_WIDTH-1:0];
            end else begin
                sat_q312 = value[`DATA_WIDTH-1:0];
            end
        end
    endfunction

    // Current 16-lane compute block
    wire signed [`DATA_WIDTH-1:0] lane_out [0:LANES_PAR-1];

    genvar lane, tap;
    generate
        for (lane = 0; lane < LANES_PAR; lane = lane + 1) begin : G_LANE
            wire signed [31:0] partial [0:63];
            wire signed [31:0] s1 [0:31];
            wire signed [31:0] s2 [0:15];
            wire signed [31:0] s3 [0:7];
            wire signed [31:0] s4 [0:3];
            wire signed [31:0] s5 [0:1];
            wire signed [31:0] acc;
            wire signed [31:0] scaled;

            for (tap = 0; tap < 64; tap = tap + 1) begin : G_MUL
                wire signed [`DATA_WIDTH-1:0] x_val = x_vec[tap*`DATA_WIDTH +: `DATA_WIDTH];
                wire signed [`DATA_WIDTH-1:0] w_val_x = w_matrix[((group_idx*LANES_PAR + lane)*64 + tap)*`DATA_WIDTH +: `DATA_WIDTH];
                wire signed [`DATA_WIDTH-1:0] w_val_z = w_matrix[((64 + group_idx*LANES_PAR + lane)*64 + tap)*`DATA_WIDTH +: `DATA_WIDTH];
                assign partial[tap] = x_val * ((state == S_X) ? w_val_x : w_val_z);
            end

            for (tap = 0; tap < 32; tap = tap + 1) begin : G_S1
                assign s1[tap] = partial[2*tap] + partial[2*tap + 1];
            end
            for (tap = 0; tap < 16; tap = tap + 1) begin : G_S2
                assign s2[tap] = s1[2*tap] + s1[2*tap + 1];
            end
            for (tap = 0; tap < 8; tap = tap + 1) begin : G_S3
                assign s3[tap] = s2[2*tap] + s2[2*tap + 1];
            end
            for (tap = 0; tap < 4; tap = tap + 1) begin : G_S4
                assign s4[tap] = s3[2*tap] + s3[2*tap + 1];
            end
            assign s5[0] = s4[0] + s4[1];
            assign s5[1] = s4[2] + s4[3];
            assign acc = s5[0] + s5[1];
            assign scaled = acc >>> `FRAC_BITS;
            assign lane_out[lane] = sat_q312(scaled);
        end
    endgenerate

    // Pack outputs from buffers
    genvar og;
    generate
        for (og = 0; og < X_LANES; og = og + 1) begin : G_PACK_X
            assign y_x_vec[og*`DATA_WIDTH +: `DATA_WIDTH] = y_x_buf[og];
        end
        for (og = 0; og < Z_LANES; og = og + 1) begin : G_PACK_Z
            assign y_z_vec[og*`DATA_WIDTH +: `DATA_WIDTH] = y_z_buf[og];
        end
    endgenerate

    assign y_vec = {y_z_vec, y_x_vec};

    // Time-mux scheduler: X groups first, then Z groups
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            group_idx <= 0;
            done_x <= 1'b0;
            done_z <= 1'b0;
            for (i = 0; i < X_LANES; i = i + 1) begin
                y_x_buf[i] <= '0;
            end
            for (i = 0; i < Z_LANES; i = i + 1) begin
                y_z_buf[i] <= '0;
            end
        end else begin
            done_x <= 1'b0;
            done_z <= 1'b0;

            if (start && en && (state == S_IDLE)) begin
                // Start a new transaction
                state <= S_X;
                group_idx <= 0;
                for (i = 0; i < X_LANES; i = i + 1) begin
                    y_x_buf[i] <= '0;
                end
                for (i = 0; i < Z_LANES; i = i + 1) begin
                    y_z_buf[i] <= '0;
                end
            end else begin
                case (state)
                    S_IDLE: begin
                        // Wait for start
                    end

                    S_X: begin
                        // Write one 16-lane X group per cycle
                        for (i = 0; i < LANES_PAR; i = i + 1) begin
                            y_x_buf[group_idx*LANES_PAR + i] <= lane_out[i];
                        end

                        if (group_idx == X_GROUPS-1) begin
                            done_x <= 1'b1;
                            state <= S_Z;
                            group_idx <= 0;
                        end else begin
                            group_idx <= group_idx + 1;
                        end
                    end

                    S_Z: begin
                        // Write one 16-lane Z group per cycle
                        for (i = 0; i < LANES_PAR; i = i + 1) begin
                            y_z_buf[group_idx*LANES_PAR + i] <= lane_out[i];
                        end

                        if (group_idx == Z_GROUPS-1) begin
                            done_z <= 1'b1;
                            state <= S_IDLE;
                            group_idx <= 0;
                        end else begin
                            group_idx <= group_idx + 1;
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                        group_idx <= 0;
                    end
                endcase
            end
        end
    end

endmodule
