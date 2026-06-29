`include "_parameter.v"

// Single-port synchronous ROM (1-cycle read latency) -> BRAM inference.
module Scan_Sync_Rom16 #(
    parameter integer DEPTH     = 1024,
    parameter integer ADDR_W    = 10,
    parameter        INIT_FILE = ""
) (
    input  wire                    clk,
    input  wire [ADDR_W-1:0]       addr,
    output reg  signed [15:0]      dout
);
    (* ram_style = "block" *) reg signed [15:0] mem [0:DEPTH-1];

    integer i;

    initial begin
        if (INIT_FILE != "") begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] = 16'sd0;
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk)
        dout <= mem[addr];

endmodule
