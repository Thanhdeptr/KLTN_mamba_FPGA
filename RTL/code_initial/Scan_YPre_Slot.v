`include "_parameter.v"

// Per-grp y_pre buffer (depth 8) for interleaved X then Z beats.
module Scan_YPre_Slot #(
    parameter DATA_WIDTH = 16,
    parameter LANES      = 16,
    parameter NUM_GRP    = 8
) (
    input  wire clk,
    input  wire rst_n,

    input  wire wr_en,
    input  wire [2:0] wr_grp,
    input  wire signed [LANES*DATA_WIDTH-1:0] wr_data,

    input  wire rd_en,
    input  wire [2:0] rd_grp,
    output reg  signed [LANES*DATA_WIDTH-1:0] rd_data,
    output reg        rd_valid,
    output wire [NUM_GRP-1:0] slot_valid_mask
);

    reg signed [DATA_WIDTH-1:0] slot [0:NUM_GRP-1][0:LANES-1];
    reg       valid [0:NUM_GRP-1];

    integer g, l;

    genvar gv;
    generate
        for (gv = 0; gv < NUM_GRP; gv = gv + 1) begin : valid_out
            assign slot_valid_mask[gv] = valid[gv];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            rd_data  <= {(LANES*DATA_WIDTH){1'b0}};
            for (g = 0; g < NUM_GRP; g = g + 1) begin
                valid[g] <= 1'b0;
                for (l = 0; l < LANES; l = l + 1)
                    slot[g][l] <= 16'sd0;
            end
        end else begin
            rd_valid <= 1'b0;
            if (wr_en) begin
                valid[wr_grp] <= 1'b1;
                for (l = 0; l < LANES; l = l + 1)
                    slot[wr_grp][l] <= wr_data[l*DATA_WIDTH +: DATA_WIDTH];
            end
            if (rd_en && valid[rd_grp]) begin
                rd_valid <= 1'b1;
                for (l = 0; l < LANES; l = l + 1)
                    rd_data[l*DATA_WIDTH +: DATA_WIDTH] <= slot[rd_grp][l];
                valid[rd_grp] <= 1'b0;
            end
        end
    end

endmodule
