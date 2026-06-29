`timescale 1ns/1ps

module tb_scan_core_streaming;
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_STATE    = 16;
    localparam D_INNER    = 128;
    localparam NUM_GRP    = 8;
`ifndef NUM_TOKENS
    localparam NUM_TOKENS = 1;
`else
    localparam NUM_TOKENS = `NUM_TOKENS;
`endif
    // Exported vectors are channel-major with full SEQ stride (see extract_RTL_inital_mem.py).
    localparam SEQ_STRIDE = 1000;

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg clear_h = 0;
    reg beat_valid = 0;
    reg beat_path_x = 0;
    reg [2:0] beat_grp = 0;
    reg [15:0] beat_token = 0;
    reg signed [LANES*DATA_WIDTH-1:0] beat_vec = 0;
`ifdef SCAN_PIPE
    reg signed [LANES*DATA_WIDTH-1:0] delta_beat_vec = 0;
    wire scan_ready;
`endif
    // Drive beat controls with blocking assigns so path_x updates before beat_valid.

    reg signed [D_STATE*DATA_WIDTH-1:0] B_row;
    reg signed [D_STATE*DATA_WIDTH-1:0] C_row;
    reg signed [D_STATE*DATA_WIDTH-1:0] A_row_ch;
    reg signed [DATA_WIDTH-1:0] D_ch;
    reg signed [DATA_WIDTH-1:0] delta_ch;
    reg signed [DATA_WIDTH-1:0] x_ch;

    wire busy;
    wire scan_valid;
    wire [15:0] scan_token;
    wire [2:0] scan_grp;
    wire signed [LANES*DATA_WIDTH-1:0] y_out_vec;
    wire token_done;
    wire [15:0] token_done_idx;
    wire [15:0] dbg_active_token;
    wire [3:0] dbg_lane_idx;
    wire [2:0] dbg_active_grp;
    wire dbg_ch_done;
    wire signed [D_STATE*DATA_WIDTH-1:0] dbg_ch_h_new;

    reg signed [DATA_WIDTH-1:0] delta_mem [0:D_INNER*SEQ_STRIDE-1];
    reg signed [DATA_WIDTH-1:0] x_mem [0:D_INNER*SEQ_STRIDE-1];
    reg signed [DATA_WIDTH-1:0] z_mem [0:D_INNER*SEQ_STRIDE-1];
    reg signed [DATA_WIDTH-1:0] A_mem [0:D_INNER*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] B_mem [0:SEQ_STRIDE*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] C_mem [0:SEQ_STRIDE*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] D_mem [0:D_INNER-1];
    reg signed [DATA_WIDTH-1:0] h_gold [0:NUM_TOKENS*D_INNER*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] y_gold [0:D_INNER*SEQ_STRIDE-1];

    reg signed [DATA_WIDTH-1:0] rtl_h [0:NUM_TOKENS*D_INNER*D_STATE-1];
    reg signed [DATA_WIDTH-1:0] rtl_y [0:D_INNER*SEQ_STRIDE-1];
    reg signed [DATA_WIDTH-1:0] rtl_y_pre [0:D_INNER*SEQ_STRIDE-1];

    integer tok, grp, lane, st, fd, tout;
    reg [31:0] ycnt;
    reg [7:0] cur_ch;

    always @(posedge clk) begin
        if (dbg_ch_done) begin
            cur_ch = dbg_active_grp * LANES + dbg_lane_idx;
            for (st = 0; st < D_STATE; st = st + 1)
                rtl_h[idx_h(dbg_active_token, cur_ch[7:0], st)] =
                    dbg_ch_h_new[st*DATA_WIDTH +: DATA_WIDTH];
        end
        if (scan_valid) begin
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                cur_ch = scan_grp * LANES + lane;
                rtl_y[idx_ch_tok(cur_ch[7:0], scan_token)] =
                    y_out_vec[lane*DATA_WIDTH +: DATA_WIDTH];
                rtl_y_pre[idx_ch_tok(cur_ch[7:0], scan_token)] =
                    dut.y_pre_rd_vec[lane*DATA_WIDTH +: DATA_WIDTH];
            end
            ycnt <= ycnt + LANES;
        end
    end

`ifdef SCAN_PIPE
    Scan_Core_Streaming_Pipe #(
        .MAX_TOKENS(1000),
        .NUM_GRP(NUM_GRP)
`ifdef SCAN_H_LIVE
        ,.H_STORE_FULL_HISTORY(0)
`else
        ,.H_STORE_FULL_HISTORY(1)
`endif
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear_h(clear_h),
        .beat_valid(beat_valid),
        .beat_path_x(beat_path_x),
        .beat_grp(beat_grp),
        .beat_token(beat_token),
        .beat_vec(beat_vec),
        .delta_beat_vec(delta_beat_vec),
        .B_row(B_row),
        .C_row(C_row),
        .A_row_ch(A_row_ch),
        .D_ch(D_ch),
        .delta_ch(delta_ch),
        .x_ch(x_ch),
        .scan_ready(scan_ready),
        .busy(busy),
        .scan_valid(scan_valid),
        .scan_token(scan_token),
        .scan_grp(scan_grp),
        .y_out_vec(y_out_vec),
        .token_done(token_done),
        .token_done_idx(token_done_idx),
        .dbg_active_token(dbg_active_token),
        .dbg_lane_idx(dbg_lane_idx),
        .dbg_active_grp(dbg_active_grp),
        .dbg_ch_done(dbg_ch_done),
        .dbg_ch_h_new(dbg_ch_h_new)
    );
`else
    Scan_Core_Streaming #(
        .MAX_TOKENS(1000),
        .NUM_GRP(NUM_GRP)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear_h(clear_h),
        .beat_valid(beat_valid),
        .beat_path_x(beat_path_x),
        .beat_grp(beat_grp),
        .beat_token(beat_token),
        .beat_vec(beat_vec),
        .B_row(B_row),
        .C_row(C_row),
        .A_row_ch(A_row_ch),
        .D_ch(D_ch),
        .delta_ch(delta_ch),
        .x_ch(x_ch),
        .busy(busy),
        .scan_valid(scan_valid),
        .scan_token(scan_token),
        .scan_grp(scan_grp),
        .y_out_vec(y_out_vec),
        .token_done(token_done),
        .token_done_idx(token_done_idx),
        .dbg_active_token(dbg_active_token),
        .dbg_lane_idx(dbg_lane_idx),
        .dbg_active_grp(dbg_active_grp),
        .dbg_ch_done(dbg_ch_done),
        .dbg_ch_h_new(dbg_ch_h_new)
    );
`endif

    always #5 clk = ~clk;

    function integer idx_ch_tok;
        input [7:0] ch;
        input [15:0] t;
        begin
            idx_ch_tok = ch * SEQ_STRIDE + t;
        end
    endfunction

    function integer idx_h;
        input [15:0] t;
        input [7:0] ch;
        input integer s;
        begin
            idx_h = t * D_INNER * D_STATE + ch * D_STATE + s;
        end
    endfunction

    always @(*) begin
        cur_ch = dbg_active_grp * LANES + dbg_lane_idx;
        delta_ch = delta_mem[idx_ch_tok(cur_ch, dbg_active_token)];
        x_ch     = x_mem[idx_ch_tok(cur_ch, dbg_active_token)];
        D_ch     = D_mem[cur_ch];
        for (st = 0; st < D_STATE; st = st + 1) begin
            A_row_ch[st*DATA_WIDTH +: DATA_WIDTH] = A_mem[cur_ch * D_STATE + st];
            B_row[st*DATA_WIDTH +: DATA_WIDTH]    =
                B_mem[dbg_active_token * D_STATE + st]; // token-major: t*16+s
            C_row[st*DATA_WIDTH +: DATA_WIDTH]    =
                C_mem[dbg_active_token * D_STATE + st];
        end
    end

    task automatic pulse_beat;
        input path_x;
        input [2:0] grp;
        input [15:0] token;
        input signed [LANES*DATA_WIDTH-1:0] vec;
        begin
`ifdef SCAN_PIPE
            if (path_x) begin
                while (!scan_ready)
                    @(posedge clk);
            end else begin
                while (busy)
                    @(posedge clk);
            end
`else
            while (busy || dut.main_state != 4'd0)
                @(posedge clk);
`endif
            beat_path_x = path_x;
            beat_grp    = grp;
            beat_token  = token;
            beat_vec    = vec;
            beat_valid  = 1'b1;
            @(posedge clk);
            beat_valid  = 1'b0;
`ifdef SCAN_PIPE
            if (!path_x)
                repeat (2) @(posedge clk);
`else
            if (path_x) begin
                while (busy || dut.main_state != 4'd0)
                    @(posedge clk);
            end else begin
                repeat (4)
                    @(posedge clk);
            end
`endif
        end
    endtask

    initial begin
`ifdef USE_DELTA_FINAL
        $readmemh("delta_final.mem", delta_mem);
`else
        $readmemh("delta_before_softplus.mem", delta_mem);
`endif
        $readmemh("x_activated.mem", x_mem);
        $readmemh("silu_z_golden.mem", z_mem);
        $readmemh("A_vec.mem", A_mem);
        $readmemh("B_vec.mem", B_mem);
        $readmemh("C_vec.mem", C_mem);
        $readmemh("D_vec.mem", D_mem);
        $readmemh("h_state.mem", h_gold);
        $readmemh("golden_y_gated.mem", y_gold);

        // Weight ROMs load inside Scan_Core_Streaming_Pipe (Scan_Sync_Rom16 / Scan_Wide_Rom256).
`ifdef SCAN_PIPE
`ifdef USE_DELTA_FINAL
        $display("[TB] WARN: USE_DELTA_FINAL needs pipe DELTA_INIT_FILE param; using default delta mem");
`endif
`endif

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        en    <= 1'b1;
        @(posedge clk);

        ycnt = 0;
        for (tok = 0; tok < NUM_TOKENS; tok = tok + 1) begin
            for (grp = 0; grp < NUM_GRP; grp = grp + 1) begin
                beat_vec = 0;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    cur_ch = grp * LANES + lane;
                    beat_vec[lane*DATA_WIDTH +: DATA_WIDTH] =
                        x_mem[idx_ch_tok(cur_ch[7:0], tok[15:0])];
`ifdef SCAN_PIPE
                    delta_beat_vec[lane*DATA_WIDTH +: DATA_WIDTH] =
                        delta_mem[idx_ch_tok(cur_ch[7:0], tok[15:0])];
`endif
                end
                pulse_beat(1'b1, grp[2:0], tok[15:0], beat_vec);

                beat_vec = 0;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    cur_ch = grp * LANES + lane;
                    beat_vec[lane*DATA_WIDTH +: DATA_WIDTH] =
                        z_mem[idx_ch_tok(cur_ch[7:0], tok[15:0])];
                end
                pulse_beat(1'b0, grp[2:0], tok[15:0], beat_vec);
            end
        end

`ifdef SCAN_PIPE
        while (busy)
            @(posedge clk);
        repeat (64) @(posedge clk);
`endif

        fd = $fopen("rtl_h_state_stream.mem", "w");
`ifdef SCAN_PIPE
`ifdef SCAN_H_LIVE
        for (st = 0; st < NUM_TOKENS * D_INNER * D_STATE; st = st + 1)
            $fdisplay(fd, "%04x", rtl_h[st] & 16'hFFFF);
`else
        for (st = 0; st < NUM_TOKENS * D_INNER * D_STATE; st = st + 1) begin
            dut.h_rd_lin = st;
            #1;
            $fdisplay(fd, "%04x", dut.h_rd_data & 16'hFFFF);
        end
`endif
`else
        for (st = 0; st < NUM_TOKENS * D_INNER * D_STATE; st = st + 1)
            $fdisplay(fd, "%04x", rtl_h[st] & 16'hFFFF);
`endif
        $fclose(fd);
        fd = $fopen("rtl_h_bram_dump.mem", "w");
`ifdef SCAN_PIPE
`ifdef SCAN_H_LIVE
        for (st = 0; st < D_INNER * D_STATE; st = st + 1) begin
            dut.h_rd_lin = st;
            #1;
            $fdisplay(fd, "%04x", dut.h_rd_data & 16'hFFFF);
        end
`else
        for (st = 0; st < NUM_TOKENS * D_INNER * D_STATE; st = st + 1) begin
            dut.h_rd_lin = st;
            #1;
            $fdisplay(fd, "%04x", dut.h_rd_data & 16'hFFFF);
        end
`endif
`else
        for (st = 0; st < NUM_TOKENS * D_INNER * D_STATE; st = st + 1)
            $fdisplay(fd, "%04x", rtl_h[st] & 16'hFFFF);
`endif
        $fclose(fd);

        fd = $fopen("rtl_y_gated_stream.mem", "w");
        for (tok = 0; tok < NUM_TOKENS; tok = tok + 1)
            for (st = 0; st < D_INNER; st = st + 1)
                $fdisplay(fd, "%04x", rtl_y[idx_ch_tok(st[7:0], tok[15:0])] & 16'hFFFF);
        $fclose(fd);

        fd = $fopen("rtl_y_pre_stream.mem", "w");
        for (tok = 0; tok < NUM_TOKENS; tok = tok + 1)
            for (st = 0; st < D_INNER; st = st + 1)
                $fdisplay(fd, "%04x", rtl_y_pre[idx_ch_tok(st[7:0], tok[15:0])] & 16'hFFFF);
        $fclose(fd);

        $display("[TB] tokens=%0d y_captures=%0d", NUM_TOKENS, ycnt);
        $finish;
    end

    initial begin
        tout = 0;
        forever begin
            @(posedge clk);
            tout = tout + 1;
            if (tout > 100000000) begin
                $display("TIMEOUT");
                $finish;
            end
        end
    end
endmodule
