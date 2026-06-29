`include "_parameter.v"

module Scan_Core_Streaming #(
    parameter DATA_WIDTH  = 16,
    parameter FRAC_BITS   = 12,
    parameter LANES       = 16,
    parameter D_STATE     = 16,
    parameter D_INNER     = 128,
    parameter MAX_TOKENS  = 1000,
    parameter NUM_GRP     = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire clear_h,

    input  wire beat_valid,
    input  wire beat_path_x,
    input  wire [2:0] beat_grp,
    input  wire [15:0] beat_token,
    input  wire signed [LANES*DATA_WIDTH-1:0] beat_vec,

    input  wire signed [D_STATE*DATA_WIDTH-1:0] B_row,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] C_row,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] A_row_ch,
    input  wire signed [DATA_WIDTH-1:0] D_ch,
    input  wire signed [DATA_WIDTH-1:0] delta_ch,
    input  wire signed [DATA_WIDTH-1:0] x_ch,

    output reg        busy,
    output reg        scan_valid,
    output reg [15:0] scan_token,
    output reg [2:0]  scan_grp,
    output reg signed [LANES*DATA_WIDTH-1:0] y_out_vec,

    output reg        token_done,
    output reg [15:0] token_done_idx,

    output wire [15:0] dbg_active_token,
    output wire [3:0]  dbg_lane_idx,
    output wire [2:0]  dbg_active_grp,

    output wire        dbg_ch_done,
    output wire signed [D_STATE*DATA_WIDTH-1:0] dbg_ch_h_new
);

    localparam H_WORDS = MAX_TOKENS * D_INNER * D_STATE;
    localparam CH_PER_TOKEN = D_INNER * D_STATE;

    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] h_mem [0:H_WORDS-1];
    reg signed [DATA_WIDTH-1:0] y_pre_accum [0:LANES-1];

    reg [3:0] lane_idx;
    reg [15:0] active_token;
    reg [2:0]  active_grp;

    wire reset = ~rst_n;
    reg        ch_start;
    wire       ch_done;
    wire signed [DATA_WIDTH-1:0] ch_y_pre;
    wire signed [D_STATE*DATA_WIDTH-1:0] ch_h_new;

    wire [1:0] pe_op_mode;
    wire       pe_clear_acc;
    wire [D_STATE*DATA_WIDTH-1:0] pe_in_a;
    wire [D_STATE*DATA_WIDTH-1:0] pe_in_b;
    wire [D_STATE*DATA_WIDTH-1:0] pe_result;
    reg signed [D_STATE*DATA_WIDTH-1:0] h_prev_pack;

    reg [3:0] main_state;
    localparam MS_IDLE   = 4'd0;
    localparam MS_START  = 4'd1;
    localparam MS_WAIT   = 4'd2;
    localparam MS_YPACK  = 4'd3;
    localparam MS_Z_RD   = 4'd4;
    localparam MS_Z_GATE = 4'd5;

    reg [2:0]  z_grp_hold;
    reg [15:0] z_token_hold;
    reg signed [LANES*DATA_WIDTH-1:0] z_vec_hold;

    reg wr_ypre;
    reg rd_ypre;
    reg signed [LANES*DATA_WIDTH-1:0] y_pre_pack_flat;
    wire signed [LANES*DATA_WIDTH-1:0] y_pre_rd_vec;

    integer hi, hj;
    reg [7:0] cur_ch;

    assign dbg_active_token = active_token;
    assign dbg_lane_idx     = lane_idx;
    assign dbg_active_grp   = active_grp;
    assign dbg_ch_done      = ch_done;
    assign dbg_ch_h_new     = ch_h_new;

    Scan_YPre_Slot #(
        .DATA_WIDTH(DATA_WIDTH),
        .LANES(LANES),
        .NUM_GRP(NUM_GRP)
    ) u_ypre (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_ypre),
        .wr_grp(active_grp),
        .wr_data(y_pre_pack_flat),
        .rd_en(rd_ypre),
        .rd_grp(beat_grp),
        .rd_data(y_pre_rd_vec),
        .rd_valid()
    );

    Scan_Channel_Exec #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS(FRAC_BITS),
        .D_STATE(D_STATE)
    ) u_ch (
        .clk(clk),
        .reset(reset),
        .start(ch_start),
        .en(en),
        .done(ch_done),
        .delta_raw(delta_ch),
        .x_val(x_ch),
        .D_val(D_ch),
        .A_vec(A_row_ch),
        .B_vec(B_row),
        .C_vec(C_row),
        .h_prev_vec(h_prev_pack),
        .y_pre_out(ch_y_pre),
        .h_new_vec(ch_h_new),
        .pe_op_mode_out(pe_op_mode),
        .pe_clear_acc_out(pe_clear_acc),
        .pe_in_a_vec(pe_in_a),
        .pe_in_b_vec(pe_in_b),
        .pe_result_vec(pe_result)
    );

    genvar gp;
    generate
        for (gp = 0; gp < D_STATE; gp = gp + 1) begin : pe_gen
            Unified_PE u_pe (
                .clk(clk),
                .reset(reset),
                .op_mode(pe_op_mode),
                .clear_acc(pe_clear_acc),
                .in_A(pe_in_a[gp*DATA_WIDTH +: DATA_WIDTH]),
                .in_B(pe_in_b[gp*DATA_WIDTH +: DATA_WIDTH]),
                .out_val(pe_result[gp*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

    function integer h_addr;
        input [15:0] tok;
        input [7:0]  ch;
        input integer st;
        begin
            h_addr = tok * CH_PER_TOKEN + ch * D_STATE + st;
        end
    endfunction

    wire gate_en;
    wire signed [LANES*DATA_WIDTH-1:0] y_gated_vec;

    Scan_XZ_Engine #(
        .DATA_WIDTH(DATA_WIDTH),
        .LANES(LANES),
        .FRAC_BITS(FRAC_BITS)
    ) u_xz (
        .gate_en(gate_en),
        .y_pre_vec(y_pre_rd_vec),
        .z_act_vec(z_vec_hold),
        .y_out_vec(y_gated_vec)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_state <= MS_IDLE;
            lane_idx <= 4'd0;
            busy <= 1'b0;
            ch_start <= 1'b0;
            scan_valid <= 1'b0;
            token_done <= 1'b0;
            token_done_idx <= 16'd0;
            wr_ypre <= 1'b0;
            rd_ypre <= 1'b0;
            y_pre_pack_flat <= {(LANES*DATA_WIDTH){1'b0}};
            y_out_vec <= {(LANES*DATA_WIDTH){1'b0}};
            for (hi = 0; hi < H_WORDS; hi = hi + 1)
                h_mem[hi] <= 16'sd0;
        end else begin
            ch_start <= 1'b0;
            scan_valid <= 1'b0;
            token_done <= 1'b0;
            wr_ypre <= 1'b0;
            rd_ypre <= 1'b0;

            if (clear_h) begin
                for (hi = 0; hi < H_WORDS; hi = hi + 1)
                    h_mem[hi] <= 16'sd0;
            end

            case (main_state)
                MS_IDLE: begin
                    busy <= 1'b0;
                    if (beat_valid && en) begin
                        busy <= 1'b1;
                        if (beat_path_x) begin
                            active_token <= beat_token;
                            active_grp     <= beat_grp;
                            lane_idx       <= 4'd0;
                            main_state     <= MS_START;
                        end else begin
                            z_grp_hold   <= beat_grp;
                            z_token_hold <= beat_token;
                            z_vec_hold   <= beat_vec;
                            rd_ypre      <= 1'b1;
                            main_state   <= MS_Z_RD;
                        end
                    end
                end

                MS_START: begin
                    ch_start   <= 1'b1;
                    main_state <= MS_WAIT;
                end

                MS_WAIT: begin
                    if (ch_done) begin
                        y_pre_accum[lane_idx] <= ch_y_pre;
                        cur_ch = active_grp * LANES + lane_idx;
                        for (hj = 0; hj < D_STATE; hj = hj + 1)
                            h_mem[h_addr(active_token, cur_ch, hj)] <=
                                ch_h_new[hj*DATA_WIDTH +: DATA_WIDTH];
                        if (lane_idx == LANES - 1) begin
                            for (hj = 0; hj < LANES - 1; hj = hj + 1)
                                y_pre_pack_flat[hj*DATA_WIDTH +: DATA_WIDTH] <= y_pre_accum[hj];
                            y_pre_pack_flat[(LANES-1)*DATA_WIDTH +: DATA_WIDTH] <= ch_y_pre;
                            main_state <= MS_YPACK;
                        end else begin
                            lane_idx <= lane_idx + 4'd1;
                            main_state <= MS_START;
                        end
                    end
                end

                MS_YPACK: begin
                    wr_ypre <= 1'b1;
                    main_state <= MS_IDLE;
                    if (active_grp == NUM_GRP - 1) begin
                        token_done <= 1'b1;
                        token_done_idx <= active_token;
                    end
                end

                MS_Z_RD: begin
                    main_state <= MS_Z_GATE;
                end

                MS_Z_GATE: begin
                    y_out_vec  <= y_gated_vec;
                    scan_valid <= 1'b1;
                    scan_token <= z_token_hold;
                    scan_grp   <= z_grp_hold;
                    main_state <= MS_IDLE;
                end

                default: main_state <= MS_IDLE;
            endcase
        end
    end

    assign gate_en = (main_state == MS_Z_GATE);

    always @(*) begin
        h_prev_pack = {(D_STATE*DATA_WIDTH){1'b0}};
        cur_ch = active_grp * LANES + lane_idx;
        if (active_token != 16'd0) begin
            for (hj = 0; hj < D_STATE; hj = hj + 1)
                h_prev_pack[hj*DATA_WIDTH +: DATA_WIDTH] =
                    h_mem[h_addr(active_token - 16'd1, cur_ch, hj)];
        end
    end

endmodule
