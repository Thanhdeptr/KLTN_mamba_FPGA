`timescale 1ns/1ps
`include "_parameter.v"

// OOC synth: USE_BRAM_WEIGHTS=1 avoids 131k-bit port + flat-bus dynamic mux.
module Out_Projection_Streaming_v2_ooc_top #(
    parameter NUM_MAC = 4
) (
    input  wire clk,
    input  wire signed [16*`DATA_WIDTH-1:0] beat_vec,
    output wire signed [64*`DATA_WIDTH-1:0] out_vec,
    output wire                              out_valid,
    output wire                              busy
);
    reg [9:0] tick;
    reg       beat_valid_r;
    reg [2:0] beat_grp_r;

    always @(posedge clk) begin
        tick         <= tick + 10'd1;
        beat_valid_r <= tick[0];
        beat_grp_r   <= tick[4:2];
    end

    Out_Projection_Streaming_v2 #(
        .NUM_MAC(NUM_MAC)
    ) u_out (
        .clk(clk),
        .rst_n(1'b1),
        .en(1'b1),
        .beat_valid(beat_valid_r),
        .beat_token({6'd0, tick[9:4]}),
        .beat_grp(beat_grp_r),
        .beat_vec(beat_vec),
        .beat_ready(),
        .out_valid(out_valid),
        .out_token(),
        .out_vec(out_vec),
        .busy(busy)
    );
endmodule
