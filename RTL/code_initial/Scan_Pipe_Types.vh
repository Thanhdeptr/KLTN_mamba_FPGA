// Pipeline constants for Scan_Core_Streaming_Pipe
`ifndef SCAN_PIPE_TYPES_VH
`define SCAN_PIPE_TYPES_VH

`define SCAN_PIPE_SLOTS      8
`define SCAN_INGRESS_DEPTH  256

// Slot micro-FSM (extends Scan_Core_Engine + softplus front)
`define SP_IDLE      4'd0
`define SP_SOFTPLUS  4'd1
`define SP_S1        4'd2
`define SP_S2        4'd3
`define SP_S2W       4'd4
`define SP_S3        4'd5
`define SP_S3W       4'd6
`define SP_S3W2      4'd7
`define SP_S4        4'd8
`define SP_S5        4'd9
`define SP_S5W       4'd10
`define SP_S6        4'd11
`define SP_S6W       4'd12
`define SP_S7        4'd13
`define SP_S8        4'd14
`define SP_S9        4'd15

`endif
