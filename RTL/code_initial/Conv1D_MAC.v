`include "_parameter.v"

// Single MAC cell for Conv1D time-multiplexed core.
// bias_init_en: acc <= saturate(bias + A*B)  (zero-overhead bias at tap 0)
// else:          acc <= saturate(acc + A*B)
module Conv1D_MAC #(
    parameter DATA_WIDTH = `DATA_WIDTH,
    parameter FRAC_BITS  = `FRAC_BITS
) (
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          clear_acc,
    input  wire                          compute_en,
    input  wire                          bias_init_en,
    input  wire signed [DATA_WIDTH-1:0]  in_A,
    input  wire signed [DATA_WIDTH-1:0]  in_B,
    input  wire signed [DATA_WIDTH-1:0]  in_bias,
    output reg  signed [DATA_WIDTH-1:0]  out_val
);

    localparam signed [DATA_WIDTH-1:0] MAX_POS = 16'sh7FFF;
    localparam signed [DATA_WIDTH-1:0] MIN_NEG = 16'sh8000;

    (* use_dsp = "yes" *) wire signed [2*DATA_WIDTH-1:0] mult_raw;
    wire signed [2*DATA_WIDTH-1:0] mult_shifted;

    reg signed [31:0] temp_result;
    reg signed [DATA_WIDTH-1:0] acc_reg;

    assign mult_raw     = in_A * in_B;
    assign mult_shifted = mult_raw >>> FRAC_BITS;

    function signed [DATA_WIDTH-1:0] sat32;
        input signed [31:0] v;
        begin
            if (v > 32767)
                sat32 = MAX_POS;
            else if (v < -32768)
                sat32 = MIN_NEG;
            else
                sat32 = v[DATA_WIDTH-1:0];
        end
    endfunction

    always @(*) begin
        if (bias_init_en)
            temp_result = in_bias + mult_shifted;
        else
            temp_result = acc_reg + mult_shifted;
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            acc_reg <= 0;
            out_val <= 0;
        end else if (clear_acc) begin
            acc_reg <= 0;
            out_val <= 0;
        end else if (compute_en) begin
            acc_reg <= sat32(temp_result);
            out_val <= sat32(temp_result);
        end
    end

endmodule
