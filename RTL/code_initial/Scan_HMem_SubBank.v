// One h_mem sub-bank (<= 1M Vivado array limit). Sync read + write for BRAM infer.
module Scan_HMem_SubBank #(
    parameter DATA_WIDTH  = 16,
    parameter SUB_WORDS   = 51200,
    parameter ADDR_W      = 17,
    parameter INIT_ON_RST = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire clear_h,
    input  wire wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire signed [DATA_WIDTH-1:0] wr_data,
    input  wire [ADDR_W-1:0] rd_addr,
    output wire signed [DATA_WIDTH-1:0] rd_data
);
    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] ram [0:SUB_WORDS-1];
    reg signed [DATA_WIDTH-1:0] rd_data_r;

    assign rd_data = rd_data_r;

    always @(posedge clk) begin
        if (wr_en)
            ram[wr_addr] <= wr_data;
        rd_data_r <= ram[rd_addr];
    end
endmodule
