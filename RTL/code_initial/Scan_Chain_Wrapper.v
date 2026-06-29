`timescale 1ns/1ps
`include "Scan_Pipe_Types.vh"

// Conv may emit Z before X per group. Per-grp Z FIFO (depth Z_FIFO_DEPTH); pair on X arrival.
module Scan_Chain_Wrapper #(
    parameter DATA_WIDTH = 16,
    parameter LANES      = 16,
    parameter D_STATE    = 16,
    parameter D_INNER    = 128,
    parameter MAX_TOKENS = 1000,
    parameter NUM_GRP    = 8,
    parameter CHAIN_Q_DEPTH = 256,
    parameter Z_FIFO_DEPTH  = 256,
    parameter XP_OVF_DEPTH  = 32,
    parameter ZP_OVF_DEPTH  = 32,
    parameter TOKEN_PIPE    = 1,
    parameter NUM_EXEC   = 6,
    parameter H_STORE_FULL_HISTORY = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire clear_h,
    input  wire stream_done,

    input  wire conv_x_valid,
    input  wire conv_z_valid,
    input  wire [2:0] conv_x_grp,
    input  wire [15:0] conv_x_token,
    input  wire [2:0] conv_z_grp,
    input  wire [15:0] conv_z_token,
    input  wire signed [LANES*DATA_WIDTH-1:0] conv_x_vec,
    input  wire signed [LANES*DATA_WIDTH-1:0] conv_z_vec,

    input  wire [15:0] bx_min_token_0,
    input  wire [15:0] bx_min_token_1,
    input  wire [15:0] bx_min_token_2,
    input  wire [15:0] bx_min_token_3,
    input  wire [15:0] bx_min_token_4,
    input  wire [15:0] bx_min_token_5,
    input  wire [15:0] bx_min_token_6,
    input  wire [15:0] bx_min_token_7,

    output wire        conv_beat_ready,
    output wire        conv_x_out_ready,
    output wire        conv_z_out_ready,
    output wire        scan_x_ready_out,
    output wire        scan_z_ready_out,
    output wire        scan_valid,
    output wire [15:0] scan_token,
    output wire [2:0]  scan_grp,
    output wire signed [LANES*DATA_WIDTH-1:0] scan_y_vec,
    output wire        scan_busy,
    output wire        scan_ready,

    output wire [13:0] mon_q_count,
    output wire        mon_q_head_x,
    output wire [2:0]  mon_q_head_grp,
    output wire [15:0] mon_q_head_tok,
    output wire        mon_inj_valid,
    output wire [7:0]  mon_z_slot_mask,
    output wire [7:0]  mon_x_skid_mask,
    output wire [7:0]  mon_await_z_mask,
    output wire        mon_beat_valid,
    output wire [6:0]  mon_ing_count,
    output wire        mon_x_beat_pend,
    output wire [7:0]  mon_ex_busy_mask,
    output wire [2:0]  mon_z_state,
    output wire [7:0]  scan_x_grp_ready,
    output wire [7:0]  scan_z_grp_ready
);

    localparam CHAIN_Q_PTR_W = (CHAIN_Q_DEPTH <= 256)  ? 8  :
                               (CHAIN_Q_DEPTH <= 512)  ? 9  :
                               (CHAIN_Q_DEPTH <= 1024) ? 10 :
                               (CHAIN_Q_DEPTH <= 2048) ? 11 :
                               (CHAIN_Q_DEPTH <= 4096) ? 12 :
                               (CHAIN_Q_DEPTH <= 8192) ? 13 : 14;
    localparam Q_COUNT_W     = CHAIN_Q_PTR_W + 1;

    localparam Z_FIFO_PTR_W = (Z_FIFO_DEPTH <= 16) ? 4 :
                              (Z_FIFO_DEPTH <= 32) ? 5 :
                              (Z_FIFO_DEPTH <= 64) ? 6 :
                              (Z_FIFO_DEPTH <= 128) ? 7 :
                              (Z_FIFO_DEPTH <= 256) ? 8 :
                              (Z_FIFO_DEPTH <= 512) ? 9 : 10;
    localparam Z_FIFO_CNT_W = Z_FIFO_PTR_W + 1;

    localparam XP_PTR_W     = (XP_OVF_DEPTH <= 16) ? 4 :
                              (XP_OVF_DEPTH <= 32) ? 5 :
                              (XP_OVF_DEPTH <= 64) ? 6 : 7;
    localparam XP_CNT_W     = XP_PTR_W + 1;

    localparam ZP_PTR_W     = (ZP_OVF_DEPTH <= 16) ? 4 :
                              (ZP_OVF_DEPTH <= 32) ? 5 :
                              (ZP_OVF_DEPTH <= 64) ? 6 : 7;
    localparam ZP_CNT_W     = ZP_PTR_W + 1;

    wire [15:0] bx_min_token [0:NUM_GRP-1];
    assign bx_min_token[0] = bx_min_token_0;
    assign bx_min_token[1] = bx_min_token_1;
    assign bx_min_token[2] = bx_min_token_2;
    assign bx_min_token[3] = bx_min_token_3;
    assign bx_min_token[4] = bx_min_token_4;
    assign bx_min_token[5] = bx_min_token_5;
    assign bx_min_token[6] = bx_min_token_6;
    assign bx_min_token[7] = bx_min_token_7;

    function [15:0] min_u16;
        input [15:0] a, b;
        begin
            min_u16 = (a < b) ? a : b;
        end
    endfunction

    reg [CHAIN_Q_PTR_W-1:0] q_wr, q_rd;
    reg [Q_COUNT_W-1:0]     q_count;
    reg        q_path_x [0:CHAIN_Q_DEPTH-1];
    reg [2:0]  q_grp    [0:CHAIN_Q_DEPTH-1];
    reg [15:0] q_token  [0:CHAIN_Q_DEPTH-1];

    reg [Z_FIFO_PTR_W-1:0]           zq_wr   [0:NUM_GRP-1];
    reg [Z_FIFO_PTR_W-1:0]           zq_rd   [0:NUM_GRP-1];
    reg [Z_FIFO_CNT_W:0]             zq_cnt  [0:NUM_GRP-1];
    reg [15:0]                       zq_token [0:NUM_GRP-1][0:Z_FIFO_DEPTH-1];

    reg        x_skid_valid [0:NUM_GRP-1];
    reg [15:0] x_skid_token [0:NUM_GRP-1];
    reg signed [LANES*DATA_WIDTH-1:0] x_skid_vec [0:NUM_GRP-1];
    // Drop duplicate conv X pulse after (grp,token) already paired (Z consumed).
    reg        last_paired_v  [0:NUM_GRP-1];
    reg [15:0] last_paired_tok [0:NUM_GRP-1];

    reg        xin_hold_v, zin_hold_v;
    reg [2:0]  xin_hold_g, zin_hold_g;
    reg [15:0] xin_hold_t, zin_hold_t;
    reg signed [LANES*DATA_WIDTH-1:0] xin_hold_vec, zin_hold_vec;

    // Per-grp X pulse overflow when global xin_hold blocks live conv (baseline hold unchanged).
    reg [XP_PTR_W-1:0]           xp_wr   [0:NUM_GRP-1];
    reg [XP_PTR_W-1:0]           xp_rd   [0:NUM_GRP-1];
    reg [XP_CNT_W:0]             xp_cnt  [0:NUM_GRP-1];
    reg [15:0]                   xp_token [0:NUM_GRP-1][0:XP_OVF_DEPTH-1];
    reg [2:0] xp_rr;

    reg [ZP_PTR_W-1:0]           zp_wr   [0:NUM_GRP-1];
    reg [ZP_PTR_W-1:0]           zp_rd   [0:NUM_GRP-1];
    reg [ZP_CNT_W:0]             zp_cnt  [0:NUM_GRP-1];
    reg [15:0]                   zp_token [0:NUM_GRP-1][0:ZP_OVF_DEPTH-1];
    reg [2:0] zp_rr;

    wire signed [LANES*DATA_WIDTH-1:0] zq_vec_rd [0:NUM_GRP-1];
    wire signed [LANES*DATA_WIDTH-1:0] xp_vec_rd [0:NUM_GRP-1];
    wire signed [LANES*DATA_WIDTH-1:0] zp_vec_rd [0:NUM_GRP-1];
    wire signed [LANES*DATA_WIDTH-1:0] q_vec_rd_wide;

    wire [15:0] xp_min_token [0:NUM_GRP-1];
    wire [15:0] hold_min_token [0:NUM_GRP-1];
    wire [15:0] conv_min_token [0:NUM_GRP-1];
    wire [15:0] pending_x_min [0:NUM_GRP-1];
    genvar xm, pm, hm, cm;
    generate
        for (xm = 0; xm < NUM_GRP; xm = xm + 1) begin : xp_min_gen
            assign xp_min_token[xm] = (xp_cnt[xm] != {XP_CNT_W{1'b0}}) ?
                                      xp_token[xm][xp_rd[xm]] : 16'hffff;
        end
        for (hm = 0; hm < NUM_GRP; hm = hm + 1) begin : hold_min_gen
            assign hold_min_token[hm] = (xin_hold_v && (xin_hold_g == hm[2:0])) ?
                                        xin_hold_t : 16'hffff;
        end
        for (cm = 0; cm < NUM_GRP; cm = cm + 1) begin : conv_min_gen
            assign conv_min_token[cm] = (conv_x_valid && (conv_x_grp == cm[2:0])) ?
                                          conv_x_token : 16'hffff;
        end
        for (pm = 0; pm < NUM_GRP; pm = pm + 1) begin : pend_min_gen
            wire [15:0] pm_a = min_u16(bx_min_token[pm], xp_min_token[pm]);
            wire [15:0] pm_b = min_u16(hold_min_token[pm], conv_min_token[pm]);
            assign pending_x_min[pm] = min_u16(pm_a, pm_b);
        end
    endgenerate

    assign conv_x_out_ready = 1'b1;
    assign conv_z_out_ready = 1'b1;

    reg        hold_valid;
    reg        hold_x;
    reg [2:0]  hold_grp;
    reg [15:0] hold_tok;
    reg signed [LANES*DATA_WIDTH-1:0] hold_vec;

    reg        beat_valid_r;
    reg        beat_path_x_r;
    reg [2:0]  beat_grp_r;
    reg [15:0] beat_token_r;
    reg signed [LANES*DATA_WIDTH-1:0] beat_vec_r;

    wire [NUM_GRP-1:0] ypre_ready_mask;

    reg stream_done_d;

    reg [Z_FIFO_CNT_W:0] zq_delta [0:NUM_GRP-1];

    integer lane_i, gi, pair_gi, zqi, xp_pi, zp_pi, zfi;
    reg [7:0] z_slot_pack;
    reg [7:0] x_skid_pack;
    reg [Z_FIFO_PTR_W-1:0] zq_idx;
    reg [2:0] xp_drain_g;
    reg       xp_drain_valid;
    reg [2:0] xp_pick;
    reg [2:0] zp_drain_g;
    reg       zp_drain_valid;
    reg [2:0] zp_pick;

    wire        scan_token_done;
    wire [15:0] scan_token_done_idx;

    wire q_full    = (q_count >= CHAIN_Q_DEPTH);
    wire q_empty   = (q_count == {Q_COUNT_W{1'b0}});
    wire q_pair_ok = (q_count <= CHAIN_Q_DEPTH - 2);

    wire pop_is_x    = !q_empty && q_path_x[q_rd];
    wire pop_is_z    = !q_empty && !q_path_x[q_rd];
    wire pipe_z_ok   = u_scan.z_beat_ready;

    always @(*) begin
        xp_drain_valid = 1'b0;
        xp_drain_g     = 3'd0;
        for (xp_pi = 0; xp_pi < NUM_GRP; xp_pi = xp_pi + 1) begin
            xp_pick = xp_rr + xp_pi[2:0];
            if (!xp_drain_valid && (xp_cnt[xp_pick] != {XP_CNT_W{1'b0}})) begin
                xp_drain_valid = 1'b1;
                xp_drain_g     = xp_pick;
            end
        end
    end

    wire mux_x_valid = xin_hold_v || conv_x_valid;
    wire mux_z_valid = zin_hold_v || conv_z_valid;
    wire [2:0]  mux_x_grp   = xin_hold_v ? xin_hold_g   : conv_x_grp;
    wire [15:0] mux_x_token = xin_hold_v ? xin_hold_t   : conv_x_token;
    wire signed [LANES*DATA_WIDTH-1:0] mux_x_vec = xin_hold_v ? xin_hold_vec : conv_x_vec;
    wire [2:0]  mux_z_grp   = zin_hold_v ? zin_hold_g   : conv_z_grp;
    wire [15:0] mux_z_token = zin_hold_v ? zin_hold_t   : conv_z_token;
    wire signed [LANES*DATA_WIDTH-1:0] mux_z_vec = zin_hold_v ? zin_hold_vec : conv_z_vec;

    wire z_skid_hit = mux_z_valid &&
                      x_skid_valid[mux_z_grp] &&
                      (x_skid_token[mux_z_grp] == mux_z_token);

    wire [Z_FIFO_CNT_W:0] zq_cnt_z = zq_cnt[mux_z_grp];
    wire [Z_FIFO_CNT_W:0] zq_cnt_x = zq_cnt[mux_x_grp];
    wire [Z_FIFO_PTR_W-1:0] zq_rd_x = zq_rd[mux_x_grp];
    wire z_fifo_full = (zq_cnt_z == Z_FIFO_DEPTH[Z_FIFO_CNT_W:0]);
    wire z_fifo_empty_x = (zq_cnt_x == {Z_FIFO_CNT_W{1'b0}});

    wire z_fifo_empty_z = (zq_cnt_z == {Z_FIFO_CNT_W{1'b0}});

    wire z_fifo_head_hit = !z_fifo_empty_x &&
                           (zq_token[mux_x_grp][zq_rd_x] == mux_x_token);
    wire z_cotag_hit = mux_z_valid && mux_x_valid &&
                       (mux_z_grp == mux_x_grp) &&
                       (mux_z_token == mux_x_token);

    wire [Z_FIFO_PTR_W-1:0] zq_rd_mux = zq_rd[mux_z_grp];
    wire [15:0] z_head_tok = zq_token[mux_z_grp][zq_rd_mux];
    // Do not auto-evict Z fifo head: x_skid can hold token N+1 while X(N) is still
    // in the Conv MAC/SiLU pipeline (Z path is faster). Evicting Z(N) loses the pair.
    wire z_head_stale = 1'b0;
    wire z_q_bypass   = 1'b0; // never solo-enqueue Z: breaks X/Z pairing when X arrives later
    wire z_evict_head = mux_z_valid && en && z_fifo_full && !z_cotag_hit && !z_skid_hit &&
                        !z_q_bypass && z_head_stale;
    wire z_store_ok   = !mux_z_valid || (zq_cnt_z < Z_FIFO_DEPTH[Z_FIFO_CNT_W:0]) || z_evict_head;
    wire z_store_fire = mux_z_valid && z_store_ok && !z_skid_hit && !z_q_bypass;

    wire x_arrive = mux_x_valid && en;
    wire x_pair_ok = x_arrive && !q_full && q_pair_ok;
    wire z_match = z_fifo_head_hit || z_cotag_hit;

    wire x_can_pair  = z_match && x_pair_ok;
    // One X skid per grp; spill to xp fifo when a second X arrives for the same grp.
    wire x_can_skid  = !z_match && !x_skid_valid[mux_x_grp];
    wire x_hold_spill_xp = xin_hold_v && en && !z_match && x_skid_valid[mux_x_grp] &&
                           (xp_cnt[mux_x_grp] < XP_OVF_DEPTH[XP_CNT_W:0]);
    wire x_dup_skid_drop = conv_x_valid && en && !xin_hold_v &&
                           x_skid_valid[conv_x_grp] &&
                           (conv_x_token == x_skid_token[conv_x_grp]);
    wire x_repair_dup = conv_x_valid && en && !xin_hold_v &&
                        last_paired_v[conv_x_grp] &&
                        (conv_x_token == last_paired_tok[conv_x_grp]);
    wire x_dup_drop = x_dup_skid_drop || x_repair_dup;
    wire x_mux_done  = x_can_pair || x_can_skid || x_hold_spill_xp || x_dup_drop;
    wire z_mux_done  = z_skid_hit || z_store_fire || z_q_bypass || (x_can_pair && z_cotag_hit);

    // Capture conv X pulse when hold or x_skid blocks the live beat (never drop).
    wire xp_push_skid = conv_x_valid && en && x_skid_valid[conv_x_grp] &&
                        (conv_x_token != x_skid_token[conv_x_grp]);
    wire xp_push_hold = conv_x_valid && en && xin_hold_v && !x_mux_done &&
                        (conv_x_grp != xin_hold_g || conv_x_token != xin_hold_t);
    wire xp_push = xp_push_skid || xp_push_hold;
    wire xp_push_full = (xp_cnt[conv_x_grp] >= XP_OVF_DEPTH[XP_CNT_W:0]);
    wire xp_push_fire = xp_push && !xp_push_full;
    wire xp_stall = xp_push && xp_push_full;
    wire x_skid_xp_cap = conv_x_valid && en && !xp_push_full &&
                         x_skid_valid[conv_x_grp] &&
                         (conv_x_token != x_skid_token[conv_x_grp]) &&
                         !xin_hold_v && (conv_x_grp == mux_x_grp);

    // Z overflow when global zin_hold blocks live conv Z pulse.
    wire zp_push_hold = conv_z_valid && en && zin_hold_v && !z_mux_done &&
                        (conv_z_grp != zin_hold_g || conv_z_token != zin_hold_t);
    wire zp_push_full = (zp_cnt[conv_z_grp] >= ZP_OVF_DEPTH[ZP_CNT_W:0]);
    wire zp_push_fire = zp_push_hold && !zp_push_full;
    wire zp_stall = zp_push_hold && zp_push_full;

    always @(*) begin
        zp_drain_valid = 1'b0;
        zp_drain_g     = 3'd0;
        for (zp_pi = 0; zp_pi < NUM_GRP; zp_pi = zp_pi + 1) begin
            zp_pick = zp_rr + zp_pi[2:0];
            if (!zp_drain_valid && (zp_cnt[zp_pick] != {ZP_CNT_W{1'b0}})) begin
                zp_drain_valid = 1'b1;
                zp_drain_g     = zp_pick;
            end
        end
    end

    // Backpressure: never drop beats when skid/q/hold/overflow cannot absorb.
    wire x_stall_hold = mux_x_valid && en && xin_hold_v && !x_mux_done;
    wire x_stall_skid = conv_x_valid && en && !xin_hold_v && !z_match &&
                        x_skid_valid[conv_x_grp] && (conv_x_grp == mux_x_grp) &&
                        !x_skid_xp_cap && !x_dup_drop;
    wire x_stall_q    = mux_x_valid && en && z_match && !x_pair_ok;
    wire z_stall_hold = mux_z_valid && en && zin_hold_v && !z_mux_done;
    wire z_stall_slot = mux_z_valid && en && !z_mux_done && !z_store_ok && !z_skid_hit &&
                        !zp_push_fire;

    wire scan_x_ready = en &&
        !x_stall_hold && !x_stall_skid && !x_stall_q && !xp_stall;
    wire scan_z_ready = en &&
        !z_stall_hold && !z_stall_slot && !zp_stall;

    // Pair enqueue needs 2 free slots (q_pair_ok). Stall Conv when pegged at DEPTH-1
    // so drain can open headroom instead of losing beats at q=DEPTH-1.
    wire q_drain_reserve = (q_count > CHAIN_Q_DEPTH - 2);

    assign conv_beat_ready = scan_x_ready && scan_z_ready && !q_drain_reserve;
    assign scan_x_ready_out = scan_x_ready;
    assign scan_z_ready_out = scan_z_ready;
    assign mon_await_z_mask = 8'd0;

    always @(*) begin
        z_slot_pack = 8'd0;
        x_skid_pack = 8'd0;
        for (gi = 0; gi < NUM_GRP; gi = gi + 1) begin
            z_slot_pack[gi] = |zq_cnt[gi];
            x_skid_pack[gi] = x_skid_valid[gi];
        end
    end

    generate
        if (Q_COUNT_W >= 14)
            assign mon_q_count = q_count[13:0];
        else
            assign mon_q_count = {{(14-Q_COUNT_W){1'b0}}, q_count};
    endgenerate
    assign mon_q_head_x     = q_empty ? 1'b0 : q_path_x[q_rd];
    assign mon_q_head_grp   = q_empty ? 3'd0 : q_grp[q_rd];
    assign mon_q_head_tok   = q_empty ? 16'd0 : q_token[q_rd];
    assign mon_inj_valid    = 1'b0;
    assign mon_z_slot_mask  = z_slot_pack;
    assign mon_x_skid_mask  = x_skid_pack;
    assign mon_beat_valid   = beat_valid_r;
    assign mon_ing_count    = u_scan.ing_count;
    assign mon_x_beat_pend  = u_scan.x_beat_pending;
    genvar exm;
    generate
        for (exm = 0; exm < 8; exm = exm + 1) begin : mon_ex_busy_gen
            if (exm < NUM_EXEC)
                assign mon_ex_busy_mask[exm] = u_scan.ex_busy[exm];
            else
                assign mon_ex_busy_mask[exm] = 1'b0;
        end
    endgenerate
    assign mon_z_state      = u_scan.z_state;

    genvar gx_rdy;
    generate
        for (gx_rdy = 0; gx_rdy < NUM_GRP; gx_rdy = gx_rdy + 1) begin : grp_rdy_gen
            // Chain may keep dispatching X while scan absorbs overflow (xp fifo).
            assign scan_x_grp_ready[gx_rdy] = en &&
                (xp_cnt[gx_rdy] < XP_OVF_DEPTH[XP_CNT_W:0]);
            assign scan_z_grp_ready[gx_rdy] = en &&
                ((zq_cnt[gx_rdy] < Z_FIFO_DEPTH[Z_FIFO_CNT_W:0]) || !q_full ||
                 x_skid_valid[gx_rdy]);
        end
    endgenerate

    reg [Q_COUNT_W-1:0] count_delta;
    reg       z_stale_pop;
    reg [2:0] z_stale_gi;
    reg [Z_FIFO_PTR_W-1:0] z_stale_rd;
    integer stale_gi;
    integer orphan_gi;

    reg [2:0] skid_zslot_gi;
    reg       skid_zslot_hit;
    reg [Z_FIFO_PTR_W-1:0] skid_zslot_rd;

    wire z_skid_pair = en && z_skid_hit && x_pair_ok;
    wire x_z_pair    = en && x_pair_ok && z_match;

    always @(*) begin
        skid_zslot_hit = 1'b0;
        skid_zslot_gi  = 3'd0;
        skid_zslot_rd  = {Z_FIFO_PTR_W{1'b0}};
        for (pair_gi = NUM_GRP - 1; pair_gi >= 0; pair_gi = pair_gi - 1) begin
            if (x_skid_valid[pair_gi] && (zq_cnt[pair_gi] != {Z_FIFO_CNT_W{1'b0}}) &&
                (zq_token[pair_gi][zq_rd[pair_gi]] == x_skid_token[pair_gi])) begin
                skid_zslot_hit = 1'b1;
                skid_zslot_gi  = pair_gi[2:0];
                skid_zslot_rd  = zq_rd[pair_gi];
            end
        end
    end

    wire skid_zslot_pair = en && !q_full && q_pair_ok && skid_zslot_hit;
    wire pair_enq_pre = skid_zslot_pair || z_skid_pair || x_z_pair;
    wire flush_zslot_pair = en && stream_done && !q_full && q_pair_ok &&
                            skid_zslot_hit && !pair_enq_pre;
    wire pair_enq = pair_enq_pre || flush_zslot_pair;
    wire z_solo_enq = z_q_bypass && !pair_enq_pre && !flush_zslot_pair;
    wire q_enq_any = pair_enq || z_solo_enq;
    wire drain_ok = (q_count != {Q_COUNT_W{1'b0}}) && !q_enq_any;

    wire x_mux_stall = en && mux_x_valid && !x_mux_done;
    wire z_mux_stall = en && mux_z_valid && !z_mux_done;

    wire x_skid_store = x_arrive && !z_match && x_can_skid;

    wire take_x_pop  = drain_ok && !hold_valid && !q_empty && en && pop_is_x;
    wire take_x_fire = hold_valid && hold_x && scan_ready;
    wire take_z_fire = drain_ok && !hold_valid && !q_empty && en && pop_is_z &&
                       pipe_z_ok;
    wire fire_x_hold = take_x_fire;

    reg do_x;
    reg do_z_pair;
    reg do_z_solo;
    reg [2:0] enq_grp;
    reg [2:0] pair_grp;
    reg [15:0] enq_tok;
    reg [15:0] pair_tok;
    reg signed [LANES*DATA_WIDTH-1:0] enq_vec;
    reg signed [LANES*DATA_WIDTH-1:0] pair_vec;
    wire [CHAIN_Q_PTR_W-1:0] nwr;
    reg z_pop_req;
    reg [2:0] z_pop_gi;
    reg [Z_FIFO_PTR_W-1:0] z_pop_rd;
    reg [Q_COUNT_W-1:0] count_delta_enq;
    reg clear_skid_zslot;
    reg [2:0] clear_skid_grp;
    reg clear_skid_mux_z;

    assign nwr = (q_wr == CHAIN_Q_DEPTH - 1) ? {CHAIN_Q_PTR_W{1'b0}} :
                 q_wr + {{(CHAIN_Q_PTR_W-1){1'b0}}, 1'b1};

    always @(*) begin
        do_x            = 1'b0;
        do_z_pair       = 1'b0;
        do_z_solo       = 1'b0;
        enq_grp         = 3'd0;
        enq_tok         = 16'd0;
        enq_vec         = {(LANES*DATA_WIDTH){1'b0}};
        pair_grp        = 3'd0;
        pair_tok        = 16'd0;
        pair_vec        = {(LANES*DATA_WIDTH){1'b0}};
        z_pop_req       = 1'b0;
        z_pop_gi        = 3'd0;
        z_pop_rd        = {Z_FIFO_PTR_W{1'b0}};
        count_delta_enq = {Q_COUNT_W{1'b0}};
        clear_skid_zslot = 1'b0;
        clear_skid_grp   = 3'd0;
        clear_skid_mux_z = 1'b0;

        if (skid_zslot_pair || flush_zslot_pair) begin
            do_x             = 1'b1;
            do_z_pair        = 1'b1;
            enq_grp          = skid_zslot_gi;
            enq_tok          = x_skid_token[skid_zslot_gi];
            enq_vec          = x_skid_vec[skid_zslot_gi];
            pair_grp         = skid_zslot_gi;
            pair_tok         = zq_token[skid_zslot_gi][skid_zslot_rd];
            pair_vec         = zq_vec_rd[skid_zslot_gi];
            z_pop_req        = 1'b1;
            z_pop_gi         = skid_zslot_gi;
            z_pop_rd         = skid_zslot_rd;
            count_delta_enq  = {{(Q_COUNT_W-1){1'b0}}, 2'd2};
            clear_skid_zslot = 1'b1;
            clear_skid_grp   = skid_zslot_gi;
        end else if (z_skid_pair) begin
            do_x            = 1'b1;
            do_z_pair       = 1'b1;
            enq_grp         = mux_z_grp;
            enq_tok         = mux_z_token;
            enq_vec         = x_skid_vec[mux_z_grp];
            pair_grp        = mux_z_grp;
            pair_tok        = mux_z_token;
            pair_vec        = mux_z_vec;
            clear_skid_mux_z = 1'b1;
            count_delta_enq = {{(Q_COUNT_W-1){1'b0}}, 2'd2};
        end else if (x_z_pair) begin
            do_x            = 1'b1;
            do_z_pair       = 1'b1;
            enq_grp         = mux_x_grp;
            enq_tok         = mux_x_token;
            enq_vec         = mux_x_vec;
            pair_grp        = mux_x_grp;
            pair_tok        = mux_x_token;
            pair_vec        = z_fifo_head_hit ? zq_vec_rd[mux_x_grp] : mux_z_vec;
            if (z_fifo_head_hit) begin
                z_pop_req = 1'b1;
                z_pop_gi  = mux_x_grp;
                z_pop_rd  = zq_rd_x;
            end
            count_delta_enq = {{(Q_COUNT_W-1){1'b0}}, 2'd2};
        end else if (z_solo_enq) begin
            do_z_solo       = 1'b1;
            pair_grp        = mux_z_grp;
            pair_tok        = mux_z_token;
            pair_vec        = mux_z_vec;
            count_delta_enq = {{(Q_COUNT_W-1){1'b0}}, 1'b1};
        end
    end

    genvar qv_i, zq_gi, xp_gi, zp_gi;
    generate
        for (zq_gi = 0; zq_gi < NUM_GRP; zq_gi = zq_gi + 1) begin : zq_vec_bram
            (* ram_style = "block" *)
            reg signed [LANES*DATA_WIDTH-1:0] mem [0:Z_FIFO_DEPTH-1];

            always @(posedge clk) begin
                if (mux_z_valid && en && z_store_fire && (mux_z_grp == zq_gi))
                    mem[zq_wr[zq_gi]] <= mux_z_vec;
            end

            assign zq_vec_rd[zq_gi] = mem[zq_rd[zq_gi]];
        end

        for (xp_gi = 0; xp_gi < NUM_GRP; xp_gi = xp_gi + 1) begin : xp_vec_bram
            (* ram_style = "block" *)
            reg signed [LANES*DATA_WIDTH-1:0] mem [0:XP_OVF_DEPTH-1];

            always @(posedge clk) begin
                if (xp_push_fire && (conv_x_grp == xp_gi))
                    mem[xp_wr[xp_gi]] <= conv_x_vec;
                else if (x_hold_spill_xp && (mux_x_grp == xp_gi))
                    mem[xp_wr[xp_gi]] <= xin_hold_vec;
            end

            assign xp_vec_rd[xp_gi] = mem[xp_rd[xp_gi]];
        end

        for (zp_gi = 0; zp_gi < NUM_GRP; zp_gi = zp_gi + 1) begin : zp_vec_bram
            (* ram_style = "block" *)
            reg signed [LANES*DATA_WIDTH-1:0] mem [0:ZP_OVF_DEPTH-1];

            always @(posedge clk) begin
                if (zp_push_fire && (conv_z_grp == zp_gi))
                    mem[zp_wr[zp_gi]] <= conv_z_vec;
            end

            assign zp_vec_rd[zp_gi] = mem[zp_rd[zp_gi]];
        end

        for (qv_i = 0; qv_i < LANES; qv_i = qv_i + 1) begin : q_vec_bram
            (* ram_style = "block" *)
            reg signed [DATA_WIDTH-1:0] mem [0:CHAIN_Q_DEPTH-1];

            always @(posedge clk) begin
                if (do_x) begin
                    mem[q_wr] <= enq_vec[qv_i*DATA_WIDTH +: DATA_WIDTH];
                    if (do_z_pair)
                        mem[nwr] <= pair_vec[qv_i*DATA_WIDTH +: DATA_WIDTH];
                end else if (do_z_solo) begin
                    mem[q_wr] <= pair_vec[qv_i*DATA_WIDTH +: DATA_WIDTH];
                end
            end

            assign q_vec_rd_wide[qv_i*DATA_WIDTH +: DATA_WIDTH] = mem[q_rd];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wr <= {CHAIN_Q_PTR_W{1'b0}};
            q_rd <= {CHAIN_Q_PTR_W{1'b0}};
            q_count <= {Q_COUNT_W{1'b0}};
            hold_valid <= 1'b0;
            beat_valid_r <= 1'b0;
            beat_path_x_r <= 1'b0;
            beat_grp_r <= 3'd0;
            beat_token_r <= 16'd0;
            beat_vec_r <= {(LANES*DATA_WIDTH){1'b0}};
            for (gi = 0; gi < NUM_GRP; gi = gi + 1) begin
                x_skid_valid[gi] <= 1'b0;
                last_paired_v[gi] <= 1'b0;
                last_paired_tok[gi] <= 16'd0;
                zq_wr[gi]   <= {Z_FIFO_PTR_W{1'b0}};
                zq_rd[gi]   <= {Z_FIFO_PTR_W{1'b0}};
                zq_cnt[gi]  <= {(Z_FIFO_CNT_W+1){1'b0}};
                xp_wr[gi]   <= {XP_PTR_W{1'b0}};
                xp_rd[gi]   <= {XP_PTR_W{1'b0}};
                xp_cnt[gi]  <= {(XP_CNT_W+1){1'b0}};
                zp_wr[gi]   <= {ZP_PTR_W{1'b0}};
                zp_rd[gi]   <= {ZP_PTR_W{1'b0}};
                zp_cnt[gi]  <= {(ZP_CNT_W+1){1'b0}};
            end
            xin_hold_v <= 1'b0;
            zin_hold_v <= 1'b0;
            xp_rr <= 3'd0;
            zp_rr <= 3'd0;
            stream_done_d <= 1'b0;
        end else begin
            stream_done_d <= stream_done;
            beat_valid_r <= 1'b0;
            count_delta  = count_delta_enq;

            z_stale_pop = 1'b0;
            z_stale_gi  = 3'd0;
            z_stale_rd  = {Z_FIFO_PTR_W{1'b0}};

            // z_stale_pop disabled — see z_head_stale comment above.

            if (clear_skid_zslot)
                x_skid_valid[clear_skid_grp] <= 1'b0;
            if (clear_skid_mux_z)
                x_skid_valid[mux_z_grp] <= 1'b0;
            if (x_skid_store) begin
                x_skid_valid[mux_x_grp] <= 1'b1;
                x_skid_token[mux_x_grp] <= mux_x_token;
                x_skid_vec[mux_x_grp]   <= mux_x_vec;
            end

            if (do_x && do_z_pair) begin
                last_paired_tok[pair_grp] <= pair_tok;
                last_paired_v[pair_grp]   <= 1'b1;
            end

            // End-of-stream: only drop x_skid when z fifo for that grp is empty.
            for (orphan_gi = 0; orphan_gi < NUM_GRP; orphan_gi = orphan_gi + 1) begin
                if (stream_done && en && x_skid_valid[orphan_gi] &&
                    (zq_cnt[orphan_gi] == {Z_FIFO_CNT_W{1'b0}}))
                    x_skid_valid[orphan_gi] <= 1'b0;
            end

            // Pop+store same grp same cycle: merge zq_cnt delta (avoid NBA overwrite).
            for (zfi = 0; zfi < NUM_GRP; zfi = zfi + 1)
                zq_delta[zfi] = {(Z_FIFO_CNT_W+1){1'b0}};

            if (mux_z_valid && en && z_store_fire) begin
                zq_token[mux_z_grp][zq_wr[mux_z_grp]] <= mux_z_token;
                zq_wr[mux_z_grp] <= (zq_wr[mux_z_grp] == Z_FIFO_DEPTH - 1) ?
                                    {Z_FIFO_PTR_W{1'b0}} : zq_wr[mux_z_grp] + 1'b1;
                zq_delta[mux_z_grp] = zq_delta[mux_z_grp] + 1'b1;
            end

            if (z_pop_req && (z_pop_rd == zq_rd[z_pop_gi])) begin
                zq_rd[z_pop_gi] <= (zq_rd[z_pop_gi] == Z_FIFO_DEPTH - 1) ?
                                   {Z_FIFO_PTR_W{1'b0}} : zq_rd[z_pop_gi] + 1'b1;
                zq_delta[z_pop_gi] = zq_delta[z_pop_gi] - 1'b1;
            end

            for (zfi = 0; zfi < NUM_GRP; zfi = zfi + 1) begin
                if (zq_delta[zfi] != {(Z_FIFO_CNT_W+1){1'b0}})
                    zq_cnt[zfi] <= zq_cnt[zfi] + zq_delta[zfi];
            end

            if (xp_push_fire) begin
                xp_token[conv_x_grp][xp_wr[conv_x_grp]] <= conv_x_token;
                xp_wr[conv_x_grp] <= (xp_wr[conv_x_grp] == XP_OVF_DEPTH - 1) ?
                                       {XP_PTR_W{1'b0}} : xp_wr[conv_x_grp] + 1'b1;
                xp_cnt[conv_x_grp] <= xp_cnt[conv_x_grp] + 1'b1;
            end else if (x_hold_spill_xp) begin
                xp_token[mux_x_grp][xp_wr[mux_x_grp]] <= xin_hold_t;
                xp_wr[mux_x_grp] <= (xp_wr[mux_x_grp] == XP_OVF_DEPTH - 1) ?
                                    {XP_PTR_W{1'b0}} : xp_wr[mux_x_grp] + 1'b1;
                xp_cnt[mux_x_grp] <= xp_cnt[mux_x_grp] + 1'b1;
            end

            if (zp_push_fire) begin
                zp_token[conv_z_grp][zp_wr[conv_z_grp]] <= conv_z_token;
                zp_wr[conv_z_grp] <= (zp_wr[conv_z_grp] == ZP_OVF_DEPTH - 1) ?
                                       {ZP_PTR_W{1'b0}} : zp_wr[conv_z_grp] + 1'b1;
                zp_cnt[conv_z_grp] <= zp_cnt[conv_z_grp] + 1'b1;
            end

            if (xin_hold_v && (x_mux_done || x_hold_spill_xp))
                xin_hold_v <= 1'b0;
            else if (!xin_hold_v && x_mux_stall && conv_x_valid) begin
                xin_hold_v   <= 1'b1;
                xin_hold_g   <= conv_x_grp;
                xin_hold_t   <= conv_x_token;
                xin_hold_vec <= conv_x_vec;
            end else if (!xin_hold_v && !conv_x_valid && xp_drain_valid) begin
                xin_hold_v   <= 1'b1;
                xin_hold_g   <= xp_drain_g;
                xin_hold_t   <= xp_token[xp_drain_g][xp_rd[xp_drain_g]];
                xin_hold_vec <= xp_vec_rd[xp_drain_g];
                xp_rd[xp_drain_g] <= (xp_rd[xp_drain_g] == XP_OVF_DEPTH - 1) ?
                                     {XP_PTR_W{1'b0}} : xp_rd[xp_drain_g] + 1'b1;
                xp_cnt[xp_drain_g] <= xp_cnt[xp_drain_g] - 1'b1;
                xp_rr <= xp_drain_g + 3'd1;
            end

            if (zin_hold_v && z_mux_done)
                zin_hold_v <= 1'b0;
            else if (!zin_hold_v && z_mux_stall && conv_z_valid) begin
                zin_hold_v   <= 1'b1;
                zin_hold_g   <= conv_z_grp;
                zin_hold_t   <= conv_z_token;
                zin_hold_vec <= conv_z_vec;
            end else if (!zin_hold_v && !conv_z_valid && zp_drain_valid) begin
                zin_hold_v   <= 1'b1;
                zin_hold_g   <= zp_drain_g;
                zin_hold_t   <= zp_token[zp_drain_g][zp_rd[zp_drain_g]];
                zin_hold_vec <= zp_vec_rd[zp_drain_g];
                zp_rd[zp_drain_g] <= (zp_rd[zp_drain_g] == ZP_OVF_DEPTH - 1) ?
                                     {ZP_PTR_W{1'b0}} : zp_rd[zp_drain_g] + 1'b1;
                zp_cnt[zp_drain_g] <= zp_cnt[zp_drain_g] - 1'b1;
                zp_rr <= zp_drain_g + 3'd1;
            end

            if (do_x) begin
                if (q_count == {Q_COUNT_W{1'b0}})
                    q_rd <= q_wr;
                q_path_x[q_wr] <= 1'b1;
                q_grp[q_wr]    <= enq_grp;
                q_token[q_wr]  <= enq_tok;
                if (do_z_pair) begin
                    q_path_x[nwr] <= 1'b0;
                    q_grp[nwr]    <= pair_grp;
                    q_token[nwr]  <= pair_tok;
                    q_wr <= (nwr == CHAIN_Q_DEPTH - 1) ? {CHAIN_Q_PTR_W{1'b0}} : nwr + 1'b1;
                end else
                    q_wr <= nwr;
            end else if (do_z_solo) begin
                if (q_count == {Q_COUNT_W{1'b0}})
                    q_rd <= q_wr;
                q_path_x[q_wr] <= 1'b0;
                q_grp[q_wr]    <= pair_grp;
                q_token[q_wr]  <= pair_tok;
                q_wr <= (q_wr == CHAIN_Q_DEPTH - 1) ? {CHAIN_Q_PTR_W{1'b0}} : q_wr + 1'b1;
            end

            if (fire_x_hold) begin
                beat_valid_r  <= 1'b1;
                beat_path_x_r <= 1'b1;
                beat_grp_r    <= hold_grp;
                beat_token_r  <= hold_tok;
                beat_vec_r    <= hold_vec;
                hold_valid    <= 1'b0;
            end else if (take_z_fire) begin
                beat_valid_r  <= 1'b1;
                beat_path_x_r <= 1'b0;
                beat_grp_r    <= q_grp[q_rd];
                beat_token_r  <= q_token[q_rd];
                beat_vec_r    <= q_vec_rd_wide;
                q_rd <= (q_rd == CHAIN_Q_DEPTH - 1) ? {CHAIN_Q_PTR_W{1'b0}} : q_rd + 1'b1;
                count_delta = count_delta - 9'd1;
            end else if (take_x_pop) begin
                hold_valid <= 1'b1;
                hold_x     <= 1'b1;
                hold_grp   <= q_grp[q_rd];
                hold_tok   <= q_token[q_rd];
                hold_vec   <= q_vec_rd_wide;
                q_rd <= (q_rd == CHAIN_Q_DEPTH - 1) ? {CHAIN_Q_PTR_W{1'b0}} : q_rd + 1'b1;
                count_delta = count_delta - 9'd1;
            end

            q_count <= q_count + count_delta;
        end
    end

    Scan_Core_Streaming_Pipe #(
        .MAX_TOKENS(MAX_TOKENS),
        .NUM_GRP(NUM_GRP),
        .NUM_EXEC(NUM_EXEC),
        .H_STORE_FULL_HISTORY(H_STORE_FULL_HISTORY)
    ) u_scan (
        .clk(clk), .rst_n(rst_n), .en(en), .clear_h(clear_h),
        .beat_valid(beat_valid_r), .beat_path_x(beat_path_x_r),
        .beat_grp(beat_grp_r), .beat_token(beat_token_r), .beat_vec(beat_vec_r),
        .delta_beat_vec({(LANES*DATA_WIDTH){1'b0}}),
        .B_row({(D_STATE*DATA_WIDTH){1'b0}}),
        .C_row({(D_STATE*DATA_WIDTH){1'b0}}),
        .A_row_ch({(D_STATE*DATA_WIDTH){1'b0}}),
        .D_ch(16'sd0), .delta_ch(16'sd0), .x_ch(16'sd0),
        .scan_ready(scan_ready), .busy(scan_busy),
        .scan_valid(scan_valid), .scan_token(scan_token), .scan_grp(scan_grp),
        .y_out_vec(scan_y_vec),
        .token_done(scan_token_done),
        .token_done_idx(scan_token_done_idx),
        .dbg_active_token(),
        .dbg_lane_idx(), .dbg_active_grp(),
        .dbg_ch_done(), .dbg_ch_h_new(), .y_pre_rd_vec(),
        .ypre_ready_mask(ypre_ready_mask),
        .z_beat_ready()
    );

endmodule
