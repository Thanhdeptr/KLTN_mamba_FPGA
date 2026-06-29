`timescale 1ns/1ps
// Minimal tap: drive conv beats, dump scan wrapper state on stall.
module tb_scan_chain_tap;
    localparam DATA_WIDTH = 16;
    localparam LANES      = 16;
    localparam D_INNER    = 128;
    localparam SEQ_STRIDE = 1000;
`ifndef NUM_TOKENS
    localparam NUM_TOKENS = 1;
`else
    localparam NUM_TOKENS = `NUM_TOKENS;
`endif

    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    reg conv_x_valid = 0;
    reg conv_z_valid = 0;
    reg [2:0] conv_x_grp = 0;
    reg [2:0] conv_z_grp = 0;
    reg [15:0] conv_x_token = 0;
    reg [15:0] conv_z_token = 0;
    reg signed [LANES*DATA_WIDTH-1:0] conv_x_vec = 0;
    reg signed [LANES*DATA_WIDTH-1:0] conv_z_vec = 0;

    wire scan_valid, scan_busy, scan_ready, conv_beat_ready;
    wire [15:0] scan_token;
    wire [2:0]  scan_grp;
    wire signed [LANES*DATA_WIDTH-1:0] scan_y_vec;

    reg signed [DATA_WIDTH-1:0] x_mem [0:D_INNER*SEQ_STRIDE-1];
    reg signed [DATA_WIDTH-1:0] z_mem [0:D_INNER*SEQ_STRIDE-1];

    integer tok, grp, lane, ycnt, cyc, stall;

    Scan_Chain_Wrapper #(.MAX_TOKENS(1000), .NUM_EXEC(1)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .clear_h(1'b0), .stream_done(1'b1),
        .conv_x_valid(conv_x_valid), .conv_z_valid(conv_z_valid),
        .conv_x_grp(conv_x_grp), .conv_x_token(conv_x_token),
        .conv_z_grp(conv_z_grp), .conv_z_token(conv_z_token),
        .conv_x_vec(conv_x_vec), .conv_z_vec(conv_z_vec),
        .conv_beat_ready(conv_beat_ready),
        .scan_valid(scan_valid), .scan_token(scan_token), .scan_grp(scan_grp),
        .scan_y_vec(scan_y_vec), .scan_busy(scan_busy), .scan_ready(scan_ready),
        .mon_q_count(), .mon_q_head_x(), .mon_q_head_grp(), .mon_q_head_tok(),
        .mon_inj_valid(), .mon_z_slot_mask(), .mon_x_skid_mask(), .mon_await_z_mask(),
        .mon_beat_valid(), .mon_ing_count(), .mon_x_beat_pend(),
        .mon_ex_busy_mask(), .mon_z_state()
    );

    always #5 clk = ~clk;

    function integer idx_ch_tok;
        input [7:0] ch;
        input [15:0] t;
        begin idx_ch_tok = ch * SEQ_STRIDE + t; end
    endfunction

    task pulse_conv;
        input path_x;
        input [2:0] grp;
        input [15:0] token;
        integer w;
        begin
            if (path_x) begin
                w = 0;
                while (!scan_ready) begin
                    w = w + 1;
                    if (w == 300) begin
                        $display("[TAP] wait scan_ready timeout busy=%b ing=%0d xpend=%b",
                                 scan_busy, dut.mon_ing_count, dut.mon_x_beat_pend);
                        w = 0;
                    end
                    @(posedge clk);
                end
            end
            // Z may arrive before matching X is popped; do not wait for !scan_busy.
            if (path_x) begin
                conv_x_valid = 1'b1; conv_z_valid = 1'b0;
                conv_x_grp = grp; conv_x_token = token;
            end else begin
                conv_x_valid = 1'b0; conv_z_valid = 1'b1;
                conv_z_grp = grp; conv_z_token = token;
            end
            @(posedge clk);
            conv_x_valid = 1'b0; conv_z_valid = 1'b0;
            if (!path_x) repeat (2) @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (scan_valid) ycnt <= ycnt + LANES;
        if (rst_n && en) begin
            cyc <= cyc + 1;
            if (scan_busy)
                stall <= stall + 1;
            else
                stall <= 0;
            if (stall == 200) begin
                $display("[TAP-STALL] cyc=%0d busy=%b rdy=%b q=%0d head=%b inj=%b z=%b await=%b ing=%0d xpend=%b ex=%b zst=%0d",
                         cyc, scan_busy, scan_ready, dut.mon_q_count, dut.mon_q_head_x,
                         dut.mon_inj_valid, dut.mon_z_slot_mask, dut.mon_await_z_mask,
                         dut.mon_ing_count, dut.mon_x_beat_pend, dut.mon_ex_busy_mask, dut.mon_z_state);
                stall <= 0;
            end
        end
    end

    initial begin
        $readmemh("x_activated.mem", x_mem);
        $readmemh("silu_z_golden.mem", z_mem);
        cyc = 0; stall = 0; ycnt = 0;
        repeat (4) @(posedge clk);
        rst_n <= 1'b1; en <= 1'b1;
        @(posedge clk);
        $display("[TAP] start rdy=%b busy=%b", scan_ready, scan_busy);

        for (tok = 0; tok < NUM_TOKENS; tok = tok + 1) begin
            for (grp = 0; grp < 8; grp = grp + 1) begin
                conv_x_vec = 0; conv_z_vec = 0;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    conv_x_vec[lane*DATA_WIDTH +: DATA_WIDTH] =
                        x_mem[idx_ch_tok(grp*LANES+lane, tok)];
                    conv_z_vec[lane*DATA_WIDTH +: DATA_WIDTH] =
                        z_mem[idx_ch_tok(grp*LANES+lane, tok)];
                end
                $display("[TAP] pulse Z g%0d (conv order)", grp);
                pulse_conv(1'b0, grp[2:0], tok[15:0]);
                $display("[TAP] pulse X g%0d busy=%b", grp, scan_busy);
                pulse_conv(1'b1, grp[2:0], tok[15:0]);
            end
        end
        while (scan_busy || (ycnt < NUM_TOKENS * D_INNER))
            @(posedge clk);
        repeat (64) @(posedge clk);
        $display("[TAP] DONE y=%0d expect=%0d", ycnt, NUM_TOKENS*D_INNER);
        $finish;
    end
endmodule
