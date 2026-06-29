// Per-channel recurrent h state: D_INNER x D_STATE words (~2 BRAM @ 16b).
// Address layout matches lower bits of full h_mem: lin = ch * D_STATE + st.
// Inference forward pass only needs h(t-1,ch) -> updated to h(t,ch) after each job.
module Scan_HState_Live #(
    parameter DATA_WIDTH      = 16,
    parameter D_STATE         = 16,
    parameter D_INNER         = 128,
    parameter H_INIT_ON_RESET = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire clear_h,
    input  wire wr16_start,
    input  wire [31:0] wr16_lin_base,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] wr16_vec,
    output wire wr16_busy,
    input  wire [31:0] rd_lin,
    output wire signed [DATA_WIDTH-1:0] rd_data
);
    localparam LIVE_WORDS = D_INNER * D_STATE;
    localparam ADDR_W     = 11;

    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] ram [0:LIVE_WORDS-1];

    reg        wr_bsy;
    reg [3:0]  wr_idx;
    reg [ADDR_W-1:0] wr_base;

    assign wr16_busy = wr_bsy;

    wire wr_en = wr_bsy;
    wire [ADDR_W-1:0] wr_addr = wr_base + {{(ADDR_W-4){1'b0}}, wr_idx};
    wire signed [DATA_WIDTH-1:0] wr_data_w = wr16_vec[wr_idx*DATA_WIDTH +: DATA_WIDTH];

    reg signed [DATA_WIDTH-1:0] rd_data_r;
    assign rd_data = rd_data_r;

    wire [ADDR_W-1:0] rd_addr = rd_lin[ADDR_W-1:0];

    always @(posedge clk) begin
        if (wr_en)
            ram[wr_addr] <= wr_data_w;
        rd_data_r <= ram[rd_addr];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_bsy <= 1'b0;
            wr_idx <= 4'd0;
        end else if (clear_h) begin
            wr_bsy <= 1'b0;
        end else begin
            if (wr16_start && !wr_bsy) begin
                wr_bsy  <= 1'b1;
                wr_idx  <= 4'd0;
                wr_base <= wr16_lin_base[ADDR_W-1:0];
            end else if (wr_bsy) begin
                if (wr_idx == D_STATE - 1)
                    wr_bsy <= 1'b0;
                wr_idx <= wr_idx + 4'd1;
            end
        end
    end

endmodule
