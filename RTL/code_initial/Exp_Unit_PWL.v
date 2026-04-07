`include "_parameter.v"

module Exp_Unit_PWL
(
    input clk,
    input signed [`DATA_WIDTH-1:0] in_data, // Q3.12
    output reg signed [`DATA_WIDTH-1:0] out_data
);

    // ROM: 64 segments + 4 knee sub-segments (addr 8: x in [2, 2.25]) = 68 entries
    (* rom_style = "distributed" *) reg [31:0] rom [0:67];

    initial begin
        $readmemh("exp_pwl_coeffs.mem", rom);
    end

    // Address: when addr==8 use 4 sub-segments indexed by in_data[9:8]
    wire [5:0] addr;
    assign addr = in_data[15:10];
    wire [6:0] rom_addr = (addr == 6'd8) ? (7'd64 + {5'b0, in_data[9:8]}) : {1'b0, addr};

    // Fetch Coefficients
    wire signed [15:0] slope_comb;
    wire signed [15:0] intercept_comb;
    assign {slope_comb, intercept_comb} = rom[rom_addr];
    
    // Calculation
    reg signed [31:0] prod;
    reg signed [31:0] res;
    
    // Constants
    localparam signed [31:0] MAX_VAL = 32'd32767;

    always @(posedge clk) begin
        // y = slope * x + intercept
        prod = slope_comb * in_data;
        res = (prod >>> `FRAC_BITS) + intercept_comb;
        
        // SATURATION 
        if (res > MAX_VAL) begin
            out_data <= MAX_VAL[15:0];      // Overflow (x > 2.08) -> 7.999
        end 
        else if (res < 0) begin
            out_data <= 16'd0;         
        end 
        else begin
            out_data <= res[15:0];      
        end
    end

endmodule