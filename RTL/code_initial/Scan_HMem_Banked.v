// Banked hidden-state memory: splits linear h_mem into Vivado-safe sub-arrays.
module Scan_HMem_Banked #(
    parameter DATA_WIDTH      = 16,
    parameter D_STATE         = 16,
    parameter MAX_TOKENS      = 1000,
    parameter D_INNER         = 128,
    parameter H_INIT_ON_RESET = 1
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
    localparam H_WORDS           = MAX_TOKENS * D_INNER * D_STATE;
    localparam H_VIVADO_MAX_BITS = 1000000;
    localparam H_BITS            = H_WORDS * DATA_WIDTH;
    localparam H_NSUB            = (H_BITS + H_VIVADO_MAX_BITS - 1) / H_VIVADO_MAX_BITS;
    localparam H_SUB_WORDS       = (H_WORDS + H_NSUB - 1) / H_NSUB;
    localparam H_ADDR_W          = (H_SUB_WORDS <= 1) ? 1 :
                                   (H_SUB_WORDS <= 2) ? 2 :
                                   (H_SUB_WORDS <= 4) ? 3 :
                                   (H_SUB_WORDS <= 8) ? 4 :
                                   (H_SUB_WORDS <= 16) ? 5 :
                                   (H_SUB_WORDS <= 32) ? 6 :
                                   (H_SUB_WORDS <= 64) ? 7 :
                                   (H_SUB_WORDS <= 128) ? 8 :
                                   (H_SUB_WORDS <= 256) ? 9 :
                                   (H_SUB_WORDS <= 512) ? 10 :
                                   (H_SUB_WORDS <= 1024) ? 11 :
                                   (H_SUB_WORDS <= 2048) ? 12 :
                                   (H_SUB_WORDS <= 4096) ? 13 :
                                   (H_SUB_WORDS <= 8192) ? 14 :
                                   (H_SUB_WORDS <= 16384) ? 15 :
                                   (H_SUB_WORDS <= 32768) ? 16 : 17;

    wire [5:0] rd_bank = rd_lin / H_SUB_WORDS;
    wire [H_ADDR_W-1:0] rd_off = rd_lin % H_SUB_WORDS;

    reg        wr_bsy;
    reg [3:0]  wr_idx;
    reg [5:0]  wr_bank;
    reg [H_ADDR_W-1:0] wr_base;
    reg signed [D_STATE*DATA_WIDTH-1:0] wr_vec;

    assign wr16_busy = wr_bsy;

    wire wr_en = wr_bsy;
    wire [5:0] wr_bank_w = wr_bank;
    wire [H_ADDR_W-1:0] wr_addr = wr_base + {{(H_ADDR_W-4){1'b0}}, wr_idx};
    wire signed [DATA_WIDTH-1:0] wr_data = wr_vec[wr_idx*DATA_WIDTH +: DATA_WIDTH];

    wire signed [DATA_WIDTH-1:0] bank_rdata [0:H_NSUB-1];
    wire [H_NSUB-1:0] bank_wr_en;

    genvar hb;
    generate
        for (hb = 0; hb < H_NSUB; hb = hb + 1) begin : h_bank
            assign bank_wr_en[hb] = wr_en && (wr_bank_w == hb);
            Scan_HMem_SubBank #(
                .DATA_WIDTH(DATA_WIDTH),
                .SUB_WORDS(H_SUB_WORDS),
                .ADDR_W(H_ADDR_W),
                .INIT_ON_RST(H_INIT_ON_RESET)
            ) u_sub (
                .clk(clk),
                .rst_n(rst_n),
                .clear_h(clear_h),
                .wr_en(bank_wr_en[hb]),
                .wr_addr(wr_addr),
                .wr_data(wr_data),
                .rd_addr(rd_off),
                .rd_data(bank_rdata[hb])
            );
        end
    endgenerate

    assign rd_data = bank_rdata[rd_bank];

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_bsy  <= 1'b0;
            wr_idx  <= 4'd0;
        end else if (clear_h) begin
            wr_bsy <= 1'b0;
        end else begin
            if (wr16_start && !wr_bsy) begin
                wr_bsy  <= 1'b1;
                wr_idx  <= 4'd0;
                wr_bank <= wr16_lin_base / H_SUB_WORDS;
                wr_base <= wr16_lin_base % H_SUB_WORDS;
                wr_vec  <= wr16_vec;
            end else if (wr_bsy) begin
                if (wr_idx == D_STATE - 1)
                    wr_bsy <= 1'b0;
                wr_idx <= wr_idx + 4'd1;
            end
        end
    end
endmodule
