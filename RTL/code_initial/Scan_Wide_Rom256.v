`include "_parameter.v"

// Packed row ROM: one BRAM read returns D_STATE x 16-bit coefficients.
// INIT_FILE layout: linear scalar words row-major [addr*LANES + lane].
module Scan_Wide_Rom256 #(
    parameter integer DEPTH      = 128,
    parameter integer ADDR_W     = 7,
    parameter integer LANES        = 16,
    parameter         INIT_FILE  = ""
) (
    input  wire                    clk,
    input  wire [ADDR_W-1:0]       addr,
    output reg  signed [LANES*16-1:0] dout
);
    localparam integer ROW_W = LANES * 16;

    (* ram_style = "block" *) reg signed [ROW_W-1:0] mem [0:DEPTH-1];

    integer i, j;
    reg signed [15:0] scalar [0:DEPTH*LANES-1];

    initial begin
        if (INIT_FILE != "") begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] = {ROW_W{1'b0}};
            $readmemh(INIT_FILE, scalar);
            for (i = 0; i < DEPTH; i = i + 1)
                for (j = 0; j < LANES; j = j + 1)
                    mem[i][j*16 +: 16] = scalar[i*LANES + j];
        end
    end

    always @(posedge clk)
        dout <= mem[addr];

endmodule
