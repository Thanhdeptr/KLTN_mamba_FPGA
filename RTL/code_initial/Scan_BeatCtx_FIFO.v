`include "_parameter.v"

// Ring FIFO for beat tags (token, grp) between delta-front and XZ stages.
module Scan_BeatCtx_FIFO #(
    parameter DEPTH = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire push,
    input  wire [15:0] push_token,
    input  wire [2:0]  push_grp,
    input  wire pop,
    output reg  [15:0] pop_token,
    output reg  [2:0]  pop_grp,
    output wire        empty,
    output wire        full
);

    reg [15:0] tok_mem [0:DEPTH-1];
    reg [2:0]  grp_mem [0:DEPTH-1];
    reg [3:0]  count;
    reg [2:0]  wr_ptr;
    reg [2:0]  rd_ptr;

    assign empty = (count == 4'd0);
    assign full  = (count >= DEPTH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count    <= 4'd0;
            wr_ptr   <= 3'd0;
            rd_ptr   <= 3'd0;
            pop_token <= 16'd0;
            pop_grp   <= 3'd0;
        end else begin
            if (push && !full) begin
                tok_mem[wr_ptr] <= push_token;
                grp_mem[wr_ptr] <= push_grp;
                wr_ptr <= (wr_ptr == DEPTH-1) ? 3'd0 : wr_ptr + 3'd1;
            end
            if (pop && !empty) begin
                pop_token <= tok_mem[rd_ptr];
                pop_grp   <= grp_mem[rd_ptr];
                rd_ptr <= (rd_ptr == DEPTH-1) ? 3'd0 : rd_ptr + 3'd1;
            end
            case ({push && !full, pop && !empty})
                2'b10: count <= count + 4'd1;
                2'b01: count <= count - 4'd1;
                default: ;
            endcase
        end
    end

endmodule
