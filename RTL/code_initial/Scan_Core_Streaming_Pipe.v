`include "_parameter.v"
`include "Scan_Pipe_Types.vh"

// Pipeline Scan: ingress queue + NUM_EXEC parallel channel engines (stage overlap).
module Scan_Core_Streaming_Pipe #(
    parameter DATA_WIDTH  = 16,
    parameter FRAC_BITS   = 12,
    parameter LANES       = 16,
    parameter D_STATE     = 16,
    parameter D_INNER     = 128,
    parameter MAX_TOKENS  = 1000,
    parameter NUM_GRP     = 8,
    parameter NUM_EXEC    = 6,
    parameter INGRESS_DEP = `SCAN_INGRESS_DEPTH,
    parameter SEQ_STRIDE  = MAX_TOKENS,
    parameter H_INIT_ON_RESET = 1,
    parameter H_STORE_FULL_HISTORY = 0,
    parameter INIT_WEIGHT_MEM = 1
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
    input  wire signed [LANES*DATA_WIDTH-1:0] delta_beat_vec,

    input  wire signed [D_STATE*DATA_WIDTH-1:0] B_row,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] C_row,
    input  wire signed [D_STATE*DATA_WIDTH-1:0] A_row_ch,
    input  wire signed [DATA_WIDTH-1:0] D_ch,
    input  wire signed [DATA_WIDTH-1:0] delta_ch,
    input  wire signed [DATA_WIDTH-1:0] x_ch,

    output wire       scan_ready,
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
    output wire signed [D_STATE*DATA_WIDTH-1:0] dbg_ch_h_new,

    output wire signed [LANES*DATA_WIDTH-1:0] y_pre_rd_vec,
    output wire [NUM_GRP-1:0]                   ypre_ready_mask,
    output wire                                 z_beat_ready
);

    localparam H_WORDS        = MAX_TOKENS * D_INNER * D_STATE;
    localparam CH_PER_TOKEN   = D_INNER * D_STATE;
    localparam H_VIVADO_MAX_BITS = 1000000;
    localparam H_BITS            = H_WORDS * DATA_WIDTH;
    localparam H_NSUB            = (H_BITS + H_VIVADO_MAX_BITS - 1) / H_VIVADO_MAX_BITS;
    localparam H_SUB_WORDS       = (H_WORDS + H_NSUB - 1) / H_NSUB;

    wire reset = ~rst_n;

    reg [31:0] h_rd_lin;
    wire signed [DATA_WIDTH-1:0] h_rd_data;
    reg        h_wr16_start;
    reg [31:0] h_wr16_base;
    reg signed [D_STATE*DATA_WIDTH-1:0] h_wr16_vec;
    wire       h_wr16_busy;
    reg [4:0]  h_wr_pick;
    reg        h_wr_pick_valid;
    reg [4:0]  h_wr_slot;
    reg [31:0] h_wr16_base_n;
    reg signed [D_STATE*DATA_WIDTH-1:0] h_wr16_vec_n;
    reg        ex_h_wr_pend [0:NUM_EXEC-1];
    reg        h_wr16_busy_d;
    reg        hpf_active;
    reg [4:0]  hpf_ex;
    reg [4:0]  hpf_set_j;
    reg [4:0]  hpf_cap_j;
    reg [15:0] hpf_token;
    reg [7:0]  hpf_ch;
    reg [2:0]  hpf_grp;
    reg [3:0]  hpf_lane;
    reg signed [DATA_WIDTH-1:0] hpf_delta;
    reg signed [DATA_WIDTH-1:0] hpf_x;
    reg signed [DATA_WIDTH-1:0] hpf_D;
    reg signed [D_STATE*DATA_WIDTH-1:0] hpf_A;
    reg signed [D_STATE*DATA_WIDTH-1:0] hpf_B;
    reg signed [D_STATE*DATA_WIDTH-1:0] hpf_C;

    localparam [4:0] HP_J_IDLE = 5'd31;

    generate
        if (H_STORE_FULL_HISTORY) begin : gen_h_hist
            Scan_HMem_Banked #(
                .DATA_WIDTH(DATA_WIDTH),
                .D_STATE(D_STATE),
                .MAX_TOKENS(MAX_TOKENS),
                .D_INNER(D_INNER),
                .H_INIT_ON_RESET(H_INIT_ON_RESET)
            ) u_hmem (
                .clk(clk),
                .rst_n(rst_n),
                .clear_h(clear_h),
                .wr16_start(h_wr16_start),
                .wr16_lin_base(h_wr16_base),
                .wr16_vec(h_wr16_vec),
                .wr16_busy(h_wr16_busy),
                .rd_lin(h_rd_lin),
                .rd_data(h_rd_data)
            );
        end else begin : gen_h_live
            Scan_HState_Live #(
                .DATA_WIDTH(DATA_WIDTH),
                .D_STATE(D_STATE),
                .D_INNER(D_INNER),
                .H_INIT_ON_RESET(H_INIT_ON_RESET)
            ) u_hlive (
                .clk(clk),
                .rst_n(rst_n),
                .clear_h(clear_h),
                .wr16_start(h_wr16_start),
                .wr16_lin_base(h_wr16_base),
                .wr16_vec(h_wr16_vec),
                .wr16_busy(h_wr16_busy),
                .rd_lin(h_rd_lin),
                .rd_data(h_rd_data)
            );
        end
    endgenerate

    localparam DELTA_DEPTH  = D_INNER * SEQ_STRIDE;
    localparam DELTA_ADDR_W = 17;
    localparam A_ADDR_W     = 7;
    localparam BC_ADDR_W    = 10;
    localparam D_ADDR_W       = 7;

    reg [DELTA_ADDR_W-1:0] rom_delta_addr;
    reg [D_ADDR_W-1:0]     rom_d_addr;
    reg [A_ADDR_W-1:0]     rom_a_addr;
    reg [BC_ADDR_W-1:0]    rom_bc_addr;

    wire signed [DATA_WIDTH-1:0]       rom_delta_rd;
    wire signed [DATA_WIDTH-1:0]       rom_d_rd;
    wire signed [D_STATE*DATA_WIDTH-1:0] rom_a_row;
    wire signed [D_STATE*DATA_WIDTH-1:0] rom_b_row;
    wire signed [D_STATE*DATA_WIDTH-1:0] rom_c_row;

    generate
        if (INIT_WEIGHT_MEM) begin : gen_wrom_init
            Scan_Sync_Rom16 #(
                .DEPTH(DELTA_DEPTH), .ADDR_W(DELTA_ADDR_W),
                .INIT_FILE("delta_before_softplus.mem")
            ) u_rom_delta (
                .clk(clk), .addr(rom_delta_addr), .dout(rom_delta_rd));
            Scan_Sync_Rom16 #(
                .DEPTH(D_INNER), .ADDR_W(D_ADDR_W), .INIT_FILE("D_vec.mem")
            ) u_rom_d (
                .clk(clk), .addr(rom_d_addr), .dout(rom_d_rd));
            Scan_Wide_Rom256 #(
                .DEPTH(D_INNER), .ADDR_W(A_ADDR_W), .LANES(D_STATE),
                .INIT_FILE("A_vec.mem")
            ) u_rom_a (
                .clk(clk), .addr(rom_a_addr), .dout(rom_a_row));
            Scan_Wide_Rom256 #(
                .DEPTH(SEQ_STRIDE), .ADDR_W(BC_ADDR_W), .LANES(D_STATE),
                .INIT_FILE("B_vec.mem")
            ) u_rom_b (
                .clk(clk), .addr(rom_bc_addr), .dout(rom_b_row));
            Scan_Wide_Rom256 #(
                .DEPTH(SEQ_STRIDE), .ADDR_W(BC_ADDR_W), .LANES(D_STATE),
                .INIT_FILE("C_vec.mem")
            ) u_rom_c (
                .clk(clk), .addr(rom_bc_addr), .dout(rom_c_row));
        end else begin : gen_wrom_empty
            Scan_Sync_Rom16 #(
                .DEPTH(DELTA_DEPTH), .ADDR_W(DELTA_ADDR_W), .INIT_FILE("")
            ) u_rom_delta (
                .clk(clk), .addr(rom_delta_addr), .dout(rom_delta_rd));
            Scan_Sync_Rom16 #(
                .DEPTH(D_INNER), .ADDR_W(D_ADDR_W), .INIT_FILE("")
            ) u_rom_d (
                .clk(clk), .addr(rom_d_addr), .dout(rom_d_rd));
            Scan_Wide_Rom256 #(
                .DEPTH(D_INNER), .ADDR_W(A_ADDR_W), .LANES(D_STATE), .INIT_FILE("")
            ) u_rom_a (
                .clk(clk), .addr(rom_a_addr), .dout(rom_a_row));
            Scan_Wide_Rom256 #(
                .DEPTH(SEQ_STRIDE), .ADDR_W(BC_ADDR_W), .LANES(D_STATE), .INIT_FILE("")
            ) u_rom_b (
                .clk(clk), .addr(rom_bc_addr), .dout(rom_b_row));
            Scan_Wide_Rom256 #(
                .DEPTH(SEQ_STRIDE), .ADDR_W(BC_ADDR_W), .LANES(D_STATE), .INIT_FILE("")
            ) u_rom_c (
                .clk(clk), .addr(rom_bc_addr), .dout(rom_c_row));
        end
    endgenerate

    reg        disp_coeff_wait;
    reg [4:0]  disp_ex_hold;
    reg [15:0] disp_tok_hold;
    reg [7:0]  disp_ch_hold;
    reg [2:0]  disp_grp_hold;
    reg [3:0]  disp_lane_hold;
    reg signed [DATA_WIDTH-1:0] disp_x_hold;

    function integer h_addr_fn;
        input [15:0] tok;
        input [7:0]  ch;
        input integer st;
        begin
            h_addr_fn = tok * CH_PER_TOKEN + ch * D_STATE + st;
        end
    endfunction

    function integer idx_ch_tok_fn;
        input [7:0] ch;
        input [15:0] t;
        begin
            idx_ch_tok_fn = ch * SEQ_STRIDE + t;
        end
    endfunction

    function integer h_live_addr_fn;
        input [7:0] ch;
        input integer st;
        begin
            h_live_addr_fn = ch * D_STATE + st;
        end
    endfunction

    // Ingress queue
    reg        x_beat_pending;
    reg [15:0] pend_token;
    reg [2:0]  pend_grp;
    reg [3:0]  pend_lane_push;
    reg signed [LANES*DATA_WIDTH-1:0] pend_x_vec;
    localparam ING_PTR_W = (INGRESS_DEP <= 64)  ? 6 :
                           (INGRESS_DEP <= 128) ? 7 :
                           (INGRESS_DEP <= 256) ? 8 : 9;
    localparam ING_CNT_W = ING_PTR_W + 1;
    localparam [ING_PTR_W-1:0] ING_LAST = INGRESS_DEP - 1;

    reg [ING_CNT_W-1:0] ing_count;
    reg [ING_PTR_W-1:0]   ing_wr_ptr;
    reg [ING_PTR_W-1:0]   ing_rd_ptr;
    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] ing_x [0:INGRESS_DEP-1];
    (* ram_style = "block" *) reg [15:0] ing_token [0:INGRESS_DEP-1];
    (* ram_style = "block" *) reg [2:0]  ing_grp   [0:INGRESS_DEP-1];
    (* ram_style = "block" *) reg [3:0]  ing_lane  [0:INGRESS_DEP-1];

    // Per-exec context
    reg        ex_busy    [0:NUM_EXEC-1];
    reg [15:0] ex_token   [0:NUM_EXEC-1];
    reg [2:0]  ex_grp     [0:NUM_EXEC-1];
    reg [3:0]  ex_lane    [0:NUM_EXEC-1];
    reg [7:0]  ex_ch      [0:NUM_EXEC-1];
    reg        ex_armed   [0:NUM_EXEC-1];
    reg        ex_start   [0:NUM_EXEC-1];
    wire       ex_done    [0:NUM_EXEC-1];
    wire signed [DATA_WIDTH-1:0] ex_y_pre [0:NUM_EXEC-1];
    wire signed [D_STATE*DATA_WIDTH-1:0] ex_h_new [0:NUM_EXEC-1];
    reg signed [D_STATE*DATA_WIDTH-1:0] ex_h_new_hold [0:NUM_EXEC-1];
    reg        ex_done_d    [0:NUM_EXEC-1];

    reg signed [DATA_WIDTH-1:0] y_pre_accum [0:NUM_GRP-1][0:LANES-1];
    reg signed [DATA_WIDTH-1:0] y_pack_block [0:LANES-1];
    reg [15:0] lane_done_mask [0:NUM_GRP-1];
    reg [15:0] grp_lane_mask [0:NUM_GRP-1];
    reg signed [LANES*DATA_WIDTH-1:0] y_pre_pack_flat;
    reg [2:0]  ypre_wr_grp;
    reg        wr_ypre;

    reg [2:0]  z_grp_hold;
    reg [15:0] z_token_hold;
    reg signed [LANES*DATA_WIDTH-1:0] z_vec_hold;
    reg        rd_ypre;
    reg [1:0]  z_state;
    reg        z_pend_valid;
    reg [2:0]  z_pend_grp;
    reg [15:0] z_pend_token;
    reg signed [LANES*DATA_WIDTH-1:0] z_pend_vec;
    localparam Z_IDLE = 2'd0;
    localparam Z_RD   = 2'd1;
    localparam Z_GATE = 2'd2;

    wire signed [LANES*DATA_WIDTH-1:0] y_pre_rd_vec_w;
    wire                               ypre_rd_valid;
    wire gate_en;
    wire signed [LANES*DATA_WIDTH-1:0] y_gated_vec;

    assign y_pre_rd_vec = y_pre_rd_vec_w;
    assign ypre_ready_mask = u_ypre.slot_valid_mask;
    assign z_beat_ready    = (z_state == Z_IDLE) && !z_pend_valid;

    wire [2:0] ypre_rd_grp = (z_state != Z_IDLE) ? z_grp_hold : beat_grp;

    Scan_YPre_Slot #(
        .DATA_WIDTH(DATA_WIDTH), .LANES(LANES), .NUM_GRP(NUM_GRP)
    ) u_ypre (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_ypre), .wr_grp(ypre_wr_grp), .wr_data(y_pre_pack_flat),
        .rd_en(rd_ypre), .rd_grp(ypre_rd_grp), .rd_data(y_pre_rd_vec_w),
        .rd_valid(ypre_rd_valid)
    );

    Scan_XZ_Engine #(
        .DATA_WIDTH(DATA_WIDTH), .LANES(LANES), .FRAC_BITS(FRAC_BITS)
    ) u_xz (
        .gate_en(gate_en), .y_pre_vec(y_pre_rd_vec_w),
        .z_act_vec(z_vec_hold), .y_out_vec(y_gated_vec)
    );

    wire [1:0] pe_op_mode [0:NUM_EXEC-1];
    wire       pe_clear   [0:NUM_EXEC-1];
    wire signed [D_STATE*DATA_WIDTH-1:0] pe_a [0:NUM_EXEC-1];
    wire signed [D_STATE*DATA_WIDTH-1:0] pe_b [0:NUM_EXEC-1];
    wire signed [D_STATE*DATA_WIDTH-1:0] pe_r [0:NUM_EXEC-1];

    reg signed [D_STATE*DATA_WIDTH-1:0] ex_A    [0:NUM_EXEC-1];
    reg signed [D_STATE*DATA_WIDTH-1:0] ex_B    [0:NUM_EXEC-1];
    reg signed [D_STATE*DATA_WIDTH-1:0] ex_C    [0:NUM_EXEC-1];
    reg signed [D_STATE*DATA_WIDTH-1:0] ex_hprev[0:NUM_EXEC-1];
    reg signed [DATA_WIDTH-1:0] ex_delta [0:NUM_EXEC-1];
    reg signed [DATA_WIDTH-1:0] ex_x     [0:NUM_EXEC-1];
    reg signed [DATA_WIDTH-1:0] ex_D     [0:NUM_EXEC-1];

    reg        dbg_done_pulse;
    reg [15:0] dbg_tok_r;
    reg [2:0]  dbg_grp_r;
    reg [3:0]  dbg_lane_r;
    reg signed [D_STATE*DATA_WIDTH-1:0] dbg_h_pack;

    assign dbg_active_token = dbg_tok_r;
    assign dbg_active_grp   = dbg_grp_r;
    assign dbg_lane_idx     = dbg_lane_r;
    assign dbg_ch_done      = dbg_done_pulse;
    assign dbg_ch_h_new     = dbg_h_pack;
    assign gate_en = (z_state == Z_GATE);

    integer ex, j, hi, h_lin, pi, lane_i, grp_i;

    always @(*) begin
        h_wr_pick = 5'h1f;
        h_wr_pick_valid = 1'b0;
        for (pi = 0; pi < NUM_EXEC; pi = pi + 1) begin
            if (!h_wr_pick_valid && ex_h_wr_pend[pi]) begin
                h_wr_pick = pi[4:0];
                h_wr_pick_valid = 1'b1;
            end
        end
    end

    always @(*) begin
        h_wr16_base_n = 32'd0;
        h_wr16_vec_n = {D_STATE*DATA_WIDTH{1'b0}};
        for (pi = 0; pi < NUM_EXEC; pi = pi + 1) begin
            if (h_wr_pick == pi[4:0]) begin
                if (H_STORE_FULL_HISTORY)
                    h_wr16_base_n = h_addr_fn(ex_token[pi], ex_ch[pi], 0);
                else
                    h_wr16_base_n = h_live_addr_fn(ex_ch[pi], 0);
                h_wr16_vec_n = ex_h_new_hold[pi];
            end
        end
    end
    reg [7:0] cur_ch;
    reg [15:0] lane_done_set [0:NUM_GRP-1];
    reg [15:0] lane_new_mask;
    reg       any_ex_busy;
    reg       did_dispatch;
    reg [3:0] free_ex;

    genvar gx, gp;
    generate
        for (gx = 0; gx < NUM_EXEC; gx = gx + 1) begin : exec_gen
            Scan_Channel_Exec #(
                .DATA_WIDTH(DATA_WIDTH), .FRAC_BITS(FRAC_BITS), .D_STATE(D_STATE),
                .DONE_HOLD_CYCLES(3)
            ) u_ch (
                .clk(clk), .reset(reset),
                .start(ex_start[gx]), .en(en), .done(ex_done[gx]),
                .delta_raw(ex_delta[gx]), .x_val(ex_x[gx]), .D_val(ex_D[gx]),
                .A_vec(ex_A[gx]), .B_vec(ex_B[gx]), .C_vec(ex_C[gx]),
                .h_prev_vec(ex_hprev[gx]),
                .y_pre_out(ex_y_pre[gx]), .h_new_vec(ex_h_new[gx]),
                .pe_op_mode_out(pe_op_mode[gx]), .pe_clear_acc_out(pe_clear[gx]),
                .pe_in_a_vec(pe_a[gx]), .pe_in_b_vec(pe_b[gx]), .pe_result_vec(pe_r[gx])
            );
            for (gp = 0; gp < D_STATE; gp = gp + 1) begin : pe_gen
                Unified_PE u_pe (
                    .clk(clk), .reset(reset),
                    .op_mode(pe_op_mode[gx]), .clear_acc(pe_clear[gx]),
                    .in_A(pe_a[gx][gp*DATA_WIDTH +: DATA_WIDTH]),
                    .in_B(pe_b[gx][gp*DATA_WIDTH +: DATA_WIDTH]),
                    .out_val(pe_r[gx][gp*DATA_WIDTH +: DATA_WIDTH])
                );
            end
        end
    endgenerate

    always @(*) begin
        any_ex_busy = 1'b0;
        for (ex = 0; ex < NUM_EXEC; ex = ex + 1)
            if (ex_busy[ex]) any_ex_busy = 1'b1;
    end

    always @(*) begin
        for (grp_i = 0; grp_i < NUM_GRP; grp_i = grp_i + 1)
            lane_done_set[grp_i] = 16'd0;
        for (ex = 0; ex < NUM_EXEC; ex = ex + 1)
            if (ex_busy[ex] && ex_done[ex] && !ex_done_d[ex])
                lane_done_set[ex_grp[ex]] =
                    lane_done_set[ex_grp[ex]] | (16'd1 << ex_lane[ex]);
    end

    reg       all_exec_full;
    always @(*) begin
        all_exec_full = 1'b1;
        for (ex = 0; ex < NUM_EXEC; ex = ex + 1)
            if (!ex_busy[ex]) all_exec_full = 1'b0;
    end

    assign scan_ready = en && !x_beat_pending &&
                        (ing_count <= INGRESS_DEP - LANES) && !all_exec_full;

    reg [4:0] free_exec_idx;
    always @(*) begin
        free_exec_idx = 5'h1f;
        for (ex = 0; ex < NUM_EXEC; ex = ex + 1)
            if (!ex_busy[ex]) free_exec_idx = ex[4:0];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ing_count <= {ING_CNT_W{1'b0}};
            ing_wr_ptr <= {ING_PTR_W{1'b0}};
            ing_rd_ptr <= {ING_PTR_W{1'b0}};
            x_beat_pending <= 1'b0;
            pend_lane_push <= 4'd0;
            busy <= 1'b0;
            scan_valid <= 1'b0;
            token_done <= 1'b0;
            wr_ypre <= 1'b0;
            rd_ypre <= 1'b0;
            z_state <= Z_IDLE;
            z_pend_valid <= 1'b0;
            dbg_done_pulse <= 1'b0;
            h_wr16_start <= 1'b0;
            h_wr_slot <= 5'h1f;
            hpf_active <= 1'b0;
            hpf_cap_j  <= HP_J_IDLE;
            disp_coeff_wait <= 1'b0;
            disp_ex_hold    <= 5'h1f;
            rom_delta_addr  <= {DELTA_ADDR_W{1'b0}};
            rom_d_addr      <= {D_ADDR_W{1'b0}};
            rom_a_addr      <= {A_ADDR_W{1'b0}};
            rom_bc_addr     <= {BC_ADDR_W{1'b0}};
            for (ex = 0; ex < NUM_EXEC; ex = ex + 1) begin
                ex_busy[ex] <= 1'b0;
                ex_h_wr_pend[ex] <= 1'b0;
                ex_start[ex] <= 1'b0;
                ex_armed[ex] <= 1'b0;
                ex_done_d[ex]    <= 1'b0;
            end
            for (hi = 0; hi < NUM_GRP; hi = hi + 1)
                lane_done_mask[hi] <= 16'd0;
            for (hi = 0; hi < NUM_GRP; hi = hi + 1)
                for (j = 0; j < LANES; j = j + 1)
                    y_pre_accum[hi][j] <= 16'sd0;
        end else begin
            scan_valid <= 1'b0;
            token_done <= 1'b0;
            wr_ypre <= 1'b0;
            rd_ypre <= 1'b0;
            dbg_done_pulse <= 1'b0;
            h_wr16_start <= 1'b0;
            h_wr16_busy_d <= h_wr16_busy;
            for (ex = 0; ex < NUM_EXEC; ex = ex + 1) begin
                ex_start[ex] <= 1'b0;
                if (ex_armed[ex]) begin
                    ex_start[ex] <= 1'b1;
                    ex_armed[ex] <= 1'b0;
                end
            end

            busy <= x_beat_pending || (ing_count != {ING_CNT_W{1'b0}}) || any_ex_busy ||
                    h_wr16_busy || hpf_active || disp_coeff_wait ||
                    (z_state != Z_IDLE) || z_pend_valid;

            did_dispatch = 1'b0;
            if (hpf_active) begin
                if (hpf_cap_j != HP_J_IDLE)
                    ex_hprev[hpf_ex][hpf_cap_j[3:0]*DATA_WIDTH +: DATA_WIDTH] <= h_rd_data;
                if (hpf_set_j < D_STATE) begin
                    if (H_STORE_FULL_HISTORY)
                        h_rd_lin <= h_addr_fn(hpf_token - 16'd1, hpf_ch, hpf_set_j[3:0]);
                    else
                        h_rd_lin <= h_live_addr_fn(hpf_ch, hpf_set_j[3:0]);
                    hpf_set_j <= hpf_set_j + 5'd1;
                end
                if (hpf_cap_j == D_STATE - 1) begin
                    hpf_active        <= 1'b0;
                    ex_token[hpf_ex]  <= hpf_token;
                    ex_grp[hpf_ex]    <= hpf_grp;
                    ex_lane[hpf_ex]   <= hpf_lane;
                    ex_ch[hpf_ex]     <= hpf_ch;
                    ex_delta[hpf_ex]  <= hpf_delta;
                    ex_x[hpf_ex]      <= hpf_x;
                    ex_D[hpf_ex]      <= hpf_D;
                    ex_A[hpf_ex]      <= hpf_A;
                    ex_B[hpf_ex]      <= hpf_B;
                    ex_C[hpf_ex]      <= hpf_C;
                    ex_armed[hpf_ex]  <= 1'b1;
                end else if (hpf_cap_j != HP_J_IDLE)
                    hpf_cap_j <= hpf_cap_j + 5'd1;
                else
                    hpf_cap_j <= 5'd0;
            end else if (disp_coeff_wait) begin
                disp_coeff_wait <= 1'b0;
                if (disp_tok_hold != 16'd0) begin
                    hpf_active        <= 1'b1;
                    hpf_ex            <= disp_ex_hold;
                    hpf_token         <= disp_tok_hold;
                    hpf_ch            <= disp_ch_hold;
                    hpf_grp           <= disp_grp_hold;
                    hpf_lane          <= disp_lane_hold;
                    hpf_delta         <= rom_delta_rd;
                    hpf_x             <= disp_x_hold;
                    hpf_D             <= rom_d_rd;
                    hpf_A             <= rom_a_row;
                    hpf_B             <= rom_b_row;
                    hpf_C             <= rom_c_row;
                    hpf_set_j         <= 5'd1;
                    hpf_cap_j         <= HP_J_IDLE;
                    if (H_STORE_FULL_HISTORY)
                        h_rd_lin <= h_addr_fn(disp_tok_hold - 16'd1, disp_ch_hold, 0);
                    else
                        h_rd_lin <= h_live_addr_fn(disp_ch_hold, 0);
                end else begin
                    ex_token[disp_ex_hold] <= disp_tok_hold;
                    ex_grp[disp_ex_hold]   <= disp_grp_hold;
                    ex_lane[disp_ex_hold]  <= disp_lane_hold;
                    ex_ch[disp_ex_hold]    <= disp_ch_hold;
                    ex_delta[disp_ex_hold] <= rom_delta_rd;
                    ex_x[disp_ex_hold]     <= disp_x_hold;
                    ex_D[disp_ex_hold]     <= rom_d_rd;
                    ex_A[disp_ex_hold]     <= rom_a_row;
                    ex_B[disp_ex_hold]     <= rom_b_row;
                    ex_C[disp_ex_hold]     <= rom_c_row;
                    for (j = 0; j < D_STATE; j = j + 1)
                        ex_hprev[disp_ex_hold][j*DATA_WIDTH +: DATA_WIDTH] <= 16'sd0;
                    ex_armed[disp_ex_hold] <= 1'b1;
                end
            end else if (ing_count > 0 && (free_exec_idx != 5'h1f) && en) begin
                did_dispatch = 1'b1;
                free_ex = free_exec_idx;
                cur_ch = ing_grp[ing_rd_ptr] * LANES + ing_lane[ing_rd_ptr];
                ex_busy[free_ex] <= 1'b1;
                disp_ex_hold    <= free_ex;
                disp_tok_hold   <= ing_token[ing_rd_ptr];
                disp_ch_hold    <= cur_ch[7:0];
                disp_grp_hold   <= ing_grp[ing_rd_ptr];
                disp_lane_hold  <= ing_lane[ing_rd_ptr];
                disp_x_hold     <= ing_x[ing_rd_ptr];
                rom_delta_addr  <= idx_ch_tok_fn(cur_ch[7:0], ing_token[ing_rd_ptr]);
                rom_d_addr      <= cur_ch[D_ADDR_W-1:0];
                rom_a_addr      <= cur_ch[A_ADDR_W-1:0];
                rom_bc_addr     <= ing_token[ing_rd_ptr][BC_ADDR_W-1:0];
                disp_coeff_wait <= 1'b1;
                ing_rd_ptr <= (ing_rd_ptr == ING_LAST) ? {ING_PTR_W{1'b0}} : ing_rd_ptr + 1'b1;
                ing_count  <= ing_count - {{(ING_CNT_W-1){1'b0}}, 1'b1};
            end

            if (beat_valid && en && beat_path_x && !x_beat_pending) begin
                x_beat_pending <= 1'b1;
                pend_token <= beat_token;
                pend_grp   <= beat_grp;
                pend_x_vec <= beat_vec;
                pend_lane_push <= 4'd0;
            end

            if (x_beat_pending && !did_dispatch && (ing_count < INGRESS_DEP)) begin
                ing_token[ing_wr_ptr] <= pend_token;
                ing_grp[ing_wr_ptr]   <= pend_grp;
                ing_lane[ing_wr_ptr]  <= pend_lane_push;
                ing_x[ing_wr_ptr]     <= pend_x_vec[pend_lane_push*DATA_WIDTH +: DATA_WIDTH];
                ing_wr_ptr <= (ing_wr_ptr == ING_LAST) ? {ING_PTR_W{1'b0}} : ing_wr_ptr + 1'b1;
                ing_count  <= ing_count + {{(ING_CNT_W-1){1'b0}}, 1'b1};
                if (pend_lane_push == LANES - 1) begin
                    x_beat_pending <= 1'b0;
                    pend_lane_push <= 4'd0;
                end else
                    pend_lane_push <= pend_lane_push + 4'd1;
            end

            if (z_pend_valid && (z_state == Z_IDLE) && en &&
                ypre_ready_mask[z_pend_grp]) begin
                z_grp_hold   <= z_pend_grp;
                z_token_hold <= z_pend_token;
                z_vec_hold   <= z_pend_vec;
                z_state      <= Z_RD;
                z_pend_valid <= 1'b0;
            end else if (beat_valid && en && !beat_path_x &&
                         (z_state == Z_IDLE) && !z_pend_valid) begin
                if (ypre_ready_mask[beat_grp]) begin
                    z_grp_hold   <= beat_grp;
                    z_token_hold <= beat_token;
                    z_vec_hold   <= beat_vec;
                    z_state      <= Z_RD;
                end else begin
                    z_pend_valid <= 1'b1;
                    z_pend_grp   <= beat_grp;
                    z_pend_token <= beat_token;
                    z_pend_vec   <= beat_vec;
                end
            end

            case (z_state)
                Z_IDLE: ;
                Z_RD: begin
                    rd_ypre <= 1'b1;
                    if (ypre_rd_valid)
                        z_state <= Z_GATE;
                end
                Z_GATE: begin
                    y_out_vec  <= y_gated_vec;
                    scan_valid <= 1'b1;
                    scan_token <= z_token_hold;
                    scan_grp   <= z_grp_hold;
                    z_state    <= Z_IDLE;
                    if (z_grp_hold == NUM_GRP - 1) begin
                        token_done     <= 1'b1;
                        token_done_idx <= z_token_hold;
                    end
                end
                default: z_state <= Z_IDLE;
            endcase

            for (ex = 0; ex < NUM_EXEC; ex = ex + 1)
                ex_done_d[ex] <= ex_done[ex];

            for (hi = 0; hi < NUM_GRP; hi = hi + 1)
                grp_lane_mask[hi] = lane_done_mask[hi];

            for (ex = 0; ex < NUM_EXEC; ex = ex + 1) begin
                if (ex_busy[ex] && ex_done[ex] && !ex_done_d[ex]) begin
                    ex_h_new_hold[ex] <= ex_h_new[ex];
                    ex_h_wr_pend[ex] <= 1'b1;

                    dbg_done_pulse <= 1'b1;
                    dbg_tok_r  <= ex_token[ex];
                    dbg_grp_r  <= ex_grp[ex];
                    dbg_lane_r <= ex_lane[ex];
                    for (j = 0; j < D_STATE; j = j + 1)
                        dbg_h_pack[j*DATA_WIDTH +: DATA_WIDTH] <=
                            ex_h_new[ex][j*DATA_WIDTH +: DATA_WIDTH];

                    y_pre_accum[ex_grp[ex]][ex_lane[ex]] <= ex_y_pre[ex];
                    grp_lane_mask[ex_grp[ex]] =
                        grp_lane_mask[ex_grp[ex]] | (16'd1 << ex_lane[ex]);
                end
            end

            for (hi = 0; hi < NUM_GRP; hi = hi + 1) begin
                for (j = 0; j < LANES; j = j + 1)
                    y_pack_block[j] = y_pre_accum[hi][j];
                for (ex = 0; ex < NUM_EXEC; ex = ex + 1)
                    if (ex_busy[ex] && ex_done[ex] && !ex_done_d[ex] &&
                        (ex_grp[ex] == hi[2:0]))
                        y_pack_block[ex_lane[ex]] = ex_y_pre[ex];

                if (grp_lane_mask[hi] == 16'hFFFF) begin
                    for (j = 0; j < LANES; j = j + 1)
                        y_pre_pack_flat[j*DATA_WIDTH +: DATA_WIDTH] <= y_pack_block[j];
                    ypre_wr_grp <= hi[2:0];
                    wr_ypre     <= 1'b1;
                    lane_done_mask[hi] <= 16'd0;
                    for (j = 0; j < LANES; j = j + 1)
                        y_pre_accum[hi][j] <= 16'sd0;
                end else
                    lane_done_mask[hi] <= grp_lane_mask[hi];
            end

            if (h_wr16_busy_d && !h_wr16_busy && (h_wr_slot != 5'h1f)) begin
                ex_busy[h_wr_slot[4:0]] <= 1'b0;
                ex_h_wr_pend[h_wr_slot[4:0]] <= 1'b0;
                h_wr_slot <= 5'h1f;
            end

            if (!h_wr16_busy && (h_wr_slot == 5'h1f) && h_wr_pick_valid) begin
                h_wr16_base <= h_wr16_base_n;
                h_wr16_vec  <= h_wr16_vec_n;
                h_wr16_start <= 1'b1;
                h_wr_slot <= h_wr_pick;
            end
        end
    end

endmodule
