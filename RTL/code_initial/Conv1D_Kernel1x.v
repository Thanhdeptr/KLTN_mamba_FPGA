/*
Conv1D_Kernel1x.v
"Branch 1 path: MaxPool input → Conv(d_model, d_model/4, k=1)"
Input: 64 channels, Output: 16 channels, Kernel: 1x1
Used in BaseInceptionBlock for the MaxPool branch.
*/

`include "_parameter.v"

module Conv1D_Kernel1x #(
    parameter DATA_WIDTH = 16,
    parameter IN_CHANNELS = 64,
    parameter OUT_CHANNELS = 16,
    parameter KERNEL_SIZE = 1,
    parameter SEQ_LEN = 1000
)(
    input clk,
    input rst_n,
    input [IN_CHANNELS-1:0][DATA_WIDTH-1:0] x_in,  // 64 channels in
    input [`WEIGHT_DEPTH-1:0][DATA_WIDTH-1:0] weight_mem,  // flattened weights: 64*16 = 1024
    input valid_in,
    output reg [OUT_CHANNELS-1:0][DATA_WIDTH-1:0] y_out,  // 16 channels out
    output reg valid_out
);

    // For k=1, each output channel is simply a weighted sum across input channels
    // No convolution window needed
    
    integer i, j;
    reg [31:0] sum;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            for (i = 0; i < OUT_CHANNELS; i = i + 1) begin
                y_out[i] <= {DATA_WIDTH{1'b0}};
            end
        end else if (valid_in) begin
            valid_out <= 1'b1;
            
            // For each output channel
            for (i = 0; i < OUT_CHANNELS; i = i + 1) begin
                sum = 0;
                // Compute weighted sum across all input channels
                for (j = 0; j < IN_CHANNELS; j = j + 1) begin
                    sum = sum + ({{16{x_in[j][DATA_WIDTH-1]}}, x_in[j]} * 
                                 {{16{weight_mem[i*IN_CHANNELS + j][DATA_WIDTH-1]}}, weight_mem[i*IN_CHANNELS + j]});
                end
                // Truncate to DATA_WIDTH (Q3.12)
                y_out[i] <= sum[DATA_WIDTH+11:12];
            end
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
