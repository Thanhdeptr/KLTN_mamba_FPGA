// RMSNorm -> In_Projection v2 continuous chain wrapper.
// Scheduler: bootstrap RMS on token 0, overlap RMS(N+1) while feeding token N.
// Single norm_buf + next_buf (depth-1 rate matcher, no deep FIFO).

`timescale 1ns/1ps

module RMSNorm_InProj_Chain_Wrapper #(
    parameter DATA_WIDTH      = 16,
    parameter D_MODEL         = 64,
    parameter TAPS            = 8,
    parameter LANES           = 16,
    parameter BEATS_PER_VEC   = 128,
    parameter FRAC_BITS       = 12,
    parameter NUM_TOKENS      = 1000
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              en,
    input  wire                              start,
    input  wire                              frame_done,
    input  wire                              feed_idle,

    input  wire [D_MODEL*DATA_WIDTH-1:0]     x_vec_in,
    input  wire [D_MODEL*DATA_WIDTH-1:0]     gamma_vec,
    input  wire signed [TAPS*DATA_WIDTH-1:0] x_sub_vec_in,

    output reg  [15:0]                       rms_sample_idx,
    output reg                               rms_arm_pulse,

    output wire signed [LANES*DATA_WIDTH-1:0] y_out,
    output wire                              done_x,
    output wire                              done_z,

    output reg                               chain_busy,
    output reg  [15:0]                       stream_token_idx,
    output reg                               inproj_streaming,
    output reg                               feed_active,
    output reg                               feed_complete,
    output wire                              feed_ready
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_BOOT_ARM  = 3'd1;
    localparam [2:0] ST_BOOT_WAIT = 3'd2;
    localparam [2:0] ST_STREAM    = 3'd3;
    localparam [2:0] ST_DONE      = 3'd4;

    reg [2:0] state;

    wire reset = ~rst_n;

    reg        rms_start;
    reg        rms_en;
    wire       rms_done;
    wire [D_MODEL*DATA_WIDTH-1:0] rms_y_vec;
    reg  [D_MODEL*DATA_WIDTH-1:0] rms_x_hold;

    RMSNorm_Unit_IntSqrt u_rms (
        .clk(clk),
        .reset(reset),
        .start(rms_start),
        .en(rms_en),
        .done(rms_done),
        .x_vec(rms_x_hold),
        .gamma_vec(gamma_vec),
        .y_vec(rms_y_vec)
    );

    reg        inproj_start;
    reg        inproj_en;
    reg        token_swap_pending;

    wire       inproj_hold   = feed_idle | token_swap_pending;
    wire       inproj_en_eff = inproj_en & ~inproj_hold;

    reg signed [DATA_WIDTH-1:0] norm_buf [0:D_MODEL-1];
    reg signed [DATA_WIDTH-1:0] next_buf [0:D_MODEL-1];
    reg                         next_valid;

    assign     feed_ready    = inproj_streaming & next_valid;

    reg [15:0] rms_token_idx;
    reg [15:0] next_rms_idx;
    reg        rms_busy;
    reg        rms_arm_pending;
    reg [15:0] rms_arm_idx;
    reg        rms_done_d;
    reg        rms_done_capture;
    reg        frame_done_d;

    integer li;

    In_Projection_Unit_Streaming_v2 #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS(FRAC_BITS),
        .LANES(LANES),
        .TAPS(TAPS)
    ) u_inproj (
        .clk(clk),
        .rst_n(rst_n),
        .en(inproj_en_eff),
        .start(inproj_start),
        .x_sub_vec_in(x_sub_vec_in),
        .y_out(y_out),
        .done_x(done_x),
        .done_z(done_z)
    );

    task automatic arm_rms;
        input [15:0] idx;
        begin
            if (!rms_arm_pending && !rms_busy) begin
                rms_sample_idx  <= idx;
                rms_arm_idx     <= idx;
                rms_arm_pending <= 1'b1;
                rms_arm_pulse   <= 1'b1;
            end
        end
    endtask

    task automatic schedule_rms_if_ready;
        begin
            if (!rms_busy && !next_valid && !rms_arm_pending &&
                (next_rms_idx < NUM_TOKENS))
                arm_rms(next_rms_idx);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            rms_start          <= 1'b0;
            rms_en             <= 1'b0;
            rms_sample_idx     <= 16'd0;
            rms_arm_pulse      <= 1'b0;
            rms_token_idx      <= 16'd0;
            next_rms_idx       <= 16'd0;
            rms_busy           <= 1'b0;
            rms_arm_pending    <= 1'b0;
            rms_arm_idx        <= 16'd0;
            rms_x_hold         <= {D_MODEL*DATA_WIDTH{1'b0}};
            rms_done_d         <= 1'b0;
            rms_done_capture   <= 1'b0;
            frame_done_d       <= 1'b0;
            inproj_start       <= 1'b0;
            inproj_en          <= 1'b0;
            token_swap_pending <= 1'b0;
            inproj_streaming   <= 1'b0;
            chain_busy         <= 1'b0;
            stream_token_idx   <= 16'd0;
            feed_active        <= 1'b0;
            feed_complete      <= 1'b0;
            next_valid         <= 1'b0;
        end else begin
            rms_start        <= 1'b0;
            rms_arm_pulse    <= 1'b0;
            rms_done_d       <= rms_done;
            rms_done_capture <= rms_done && !rms_done_d;
            frame_done_d     <= frame_done;

            if (!en) begin
                state              <= ST_IDLE;
                chain_busy         <= 1'b0;
                feed_active        <= 1'b0;
                feed_complete      <= 1'b0;
                inproj_streaming   <= 1'b0;
                inproj_start       <= 1'b0;
                inproj_en          <= 1'b0;
                token_swap_pending <= 1'b0;
                rms_en             <= 1'b0;
            end else begin
                rms_en    <= 1'b1;
                inproj_en <= 1'b1;

                if (rms_arm_pending && !rms_busy) begin
                    rms_x_hold      <= x_vec_in;
                    rms_start       <= 1'b1;
                    rms_token_idx   <= rms_arm_idx;
                    rms_busy        <= 1'b1;
                    rms_arm_pending <= 1'b0;
                end

                if (rms_done_capture && (state != ST_BOOT_WAIT)) begin
                    for (li = 0; li < D_MODEL; li = li + 1)
                        next_buf[li] <= $signed(rms_y_vec[li*DATA_WIDTH +: DATA_WIDTH]);
                    next_valid   <= 1'b1;
                    rms_busy     <= 1'b0;
                    next_rms_idx <= rms_token_idx + 16'd1;
                end

                if (token_swap_pending && next_valid) begin
                    for (li = 0; li < D_MODEL; li = li + 1)
                        norm_buf[li] <= next_buf[li];
                    next_valid         <= 1'b0;
                    token_swap_pending <= 1'b0;
                    stream_token_idx   <= stream_token_idx + 16'd1;
                    schedule_rms_if_ready();
                end

                if (frame_done && !frame_done_d && (state == ST_STREAM)) begin
                    if (stream_token_idx + 16'd1 >= NUM_TOKENS) begin
                        feed_active        <= 1'b0;
                        inproj_start       <= 1'b0;
                        token_swap_pending <= 1'b0;
                        state              <= ST_DONE;
                    end else if (next_valid) begin
                        for (li = 0; li < D_MODEL; li = li + 1)
                            norm_buf[li] <= next_buf[li];
                        next_valid         <= 1'b0;
                        token_swap_pending <= 1'b0;
                        stream_token_idx   <= stream_token_idx + 16'd1;
                        schedule_rms_if_ready();
                    end else begin
                        token_swap_pending <= 1'b1;
                    end
                end

                case (state)
                    ST_IDLE: begin
                        chain_busy       <= 1'b0;
                        feed_active      <= 1'b0;
                        inproj_streaming <= 1'b0;
                        inproj_start     <= 1'b0;
                        if (start) begin
                            chain_busy       <= 1'b1;
                            stream_token_idx <= 16'd0;
                            rms_token_idx    <= 16'd0;
                            next_rms_idx     <= 16'd0;
                            next_valid       <= 1'b0;
                            state            <= ST_BOOT_ARM;
                        end
                    end

                    ST_BOOT_ARM: begin
                        arm_rms(16'd0);
                        next_rms_idx <= 16'd1;
                        state        <= ST_BOOT_WAIT;
                    end

                    ST_BOOT_WAIT: begin
                        if (rms_done_capture) begin
                            for (li = 0; li < D_MODEL; li = li + 1)
                                norm_buf[li] <= $signed(rms_y_vec[li*DATA_WIDTH +: DATA_WIDTH]);
                            rms_busy         <= 1'b0;
                            stream_token_idx <= 16'd0;
                            inproj_start     <= 1'b1;
                            inproj_streaming <= 1'b1;
                            feed_active      <= 1'b1;
                            schedule_rms_if_ready();
                            state            <= ST_STREAM;
                        end
                    end

                    ST_STREAM: begin
                        schedule_rms_if_ready();
                    end

                    ST_DONE: begin
                        feed_active      <= 1'b0;
                        inproj_streaming <= 1'b0;
                        feed_complete    <= 1'b1;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
