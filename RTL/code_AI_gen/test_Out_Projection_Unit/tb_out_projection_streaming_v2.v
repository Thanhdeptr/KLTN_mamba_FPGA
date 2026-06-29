`timescale 1ns/1ps

// Compare Out_Projection_Streaming_v2 (NUM_MAC beats) vs batch golden.
// Usage: xelab ... +define+NUM_MAC=8
module tb_out_projection_streaming_v2;

    localparam DATA_WIDTH = 16;
    localparam FRAC_BITS  = 12;
    localparam LANES      = 16;
    localparam D_IN       = 128;
    localparam D_OUT      = 64;
    localparam NUM_GRP    = 8;

    `ifndef NUM_MAC
        localparam NUM_MAC = 16;
    `else
        localparam NUM_MAC = `NUM_MAC;
    `endif

    reg clk, rst_n, en;
    reg beat_valid;
    reg [15:0] beat_token;
    reg [2:0] beat_grp;
    reg signed [LANES*DATA_WIDTH-1:0] beat_vec;
    wire beat_ready;

    wire out_valid;
    wire [15:0] out_token;
    wire signed [D_OUT*DATA_WIDTH-1:0] out_vec;
    wire busy;

    Out_Projection_Streaming_v2 #(
        .DATA_WIDTH (DATA_WIDTH),
        .FRAC_BITS  (FRAC_BITS),
        .LANES      (LANES),
        .D_IN       (D_IN),
        .D_OUT      (D_OUT),
        .NUM_GRP    (NUM_GRP),
        .NUM_MAC    (NUM_MAC)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .beat_valid (beat_valid),
        .beat_token (beat_token),
        .beat_grp   (beat_grp),
        .beat_vec   (beat_vec),
        .beat_ready (beat_ready),
        .out_valid  (out_valid),
        .out_token  (out_token),
        .out_vec    (out_vec),
        .busy       (busy)
    );

    localparam signed [31:0] SAT_MAX = 32'sd32767;
    localparam signed [31:0] SAT_MIN = -32'sd32768;

    integer i, j, g, t;
    integer mismatch_count;
    integer max_error;
    integer abs_error;
    integer cycles_per_row;
    integer cycles_per_beat;
    integer beat_cycles;
    integer total_beats;

    reg signed [15:0] x_mem [0:D_IN-1];
    reg signed [15:0] w_mem [0:D_OUT-1][0:D_IN-1];
    reg got_out;
    reg signed [15:0] y_cap [0:D_OUT-1];

    reg [2:0] grp_order [0:NUM_GRP-1];
    reg signed [15:0] y_rtl;
    reg signed [47:0] acc;
    reg signed [31:0] scaled;

    reg signed [15:0] y_golden [0:D_OUT-1];

    task automatic send_beat;
        input [15:0] tok;
        input [2:0]  grp;
        begin
            while (!beat_ready) @(posedge clk);
            beat_token = tok;
            beat_grp   = grp;
            for (j = 0; j < LANES; j = j + 1)
                beat_vec[j*DATA_WIDTH +: DATA_WIDTH] = x_mem[grp*LANES + j];
            beat_valid = 1'b1;
            @(posedge clk);
            beat_valid = 1'b0;
            beat_cycles = 0;
            while (busy) begin
                @(posedge clk);
                beat_cycles = beat_cycles + 1;
            end
            total_beats = total_beats + 1;
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        en = 0;
        beat_valid = 0;
        beat_token = 0;
        beat_grp = 0;
        beat_vec = 0;
        mismatch_count = 0;
        max_error = 0;
        total_beats = 0;

        got_out = 0;

        cycles_per_row  = (LANES + NUM_MAC - 1) / NUM_MAC;
        cycles_per_beat = D_OUT * cycles_per_row;

        for (j = 0; j < D_IN; j = j + 1) begin
            x_mem[j] = $signed((j % 11) * 64 - 320);
        end

        for (i = 0; i < D_OUT; i = i + 1) begin
            for (j = 0; j < D_IN; j = j + 1) begin
                w_mem[i][j] = $signed(((i + j) % 9) * 48 - 192);
                dut.w_bram[i * D_IN + j] = w_mem[i][j];
            end
        end

        for (i = 0; i < D_OUT; i = i + 1) begin
            acc = 0;
            for (j = 0; j < D_IN; j = j + 1)
                acc = acc + (x_mem[j] * w_mem[i][j]);
            scaled = acc >>> FRAC_BITS;
            if (scaled > SAT_MAX)
                y_golden[i] = 16'sh7fff;
            else if (scaled < SAT_MIN)
                y_golden[i] = 16'sh8000;
            else
                y_golden[i] = scaled[15:0];
        end

        // Scrambled grp order to mimic Scan out-of-order groups
        grp_order[0] = 3'd3;
        grp_order[1] = 3'd7;
        grp_order[2] = 3'd0;
        grp_order[3] = 3'd5;
        grp_order[4] = 3'd2;
        grp_order[5] = 3'd6;
        grp_order[6] = 3'd1;
        grp_order[7] = 3'd4;

        #50 rst_n = 1;
        #20 en = 1;

        for (g = 0; g < NUM_GRP; g = g + 1)
            send_beat(16'd0, grp_order[g]);

        while (!got_out) @(posedge clk);

        for (i = 0; i < D_OUT; i = i + 1) begin
            y_rtl = y_cap[i];
            abs_error = (y_rtl >= y_golden[i]) ? (y_rtl - y_golden[i]) : (y_golden[i] - y_rtl);
            if (abs_error > 0) begin
                mismatch_count = mismatch_count + 1;
                if (abs_error > max_error) max_error = abs_error;
                if (mismatch_count <= 5)
                    $display("MISMATCH lane=%0d got=%04x exp=%04x err=%0d", i, y_rtl, y_golden[i], abs_error);
            end
        end

        $display("\n=== OUT_PROJECTION_STREAMING_V2 TEST ===");
        $display("NUM_MAC=%0d  cycles/row=%0d  cycles/beat=%0d", NUM_MAC, cycles_per_row, cycles_per_beat);
        $display("Beats fed: %0d  out_token=%0d  last_beat_cycles=%0d", total_beats, out_token, beat_cycles);
        $display("Mismatches: %0d", mismatch_count);
        if (mismatch_count == 0)
            $display("PASS: streaming matches batch golden.");
        else
            $display("FAIL: max error = %0d", max_error);
        $display("========================================\n");

        #20 $finish;
    end

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (out_valid) begin
            got_out <= 1'b1;
            for (i = 0; i < D_OUT; i = i + 1)
                y_cap[i] <= out_vec[i*DATA_WIDTH +: DATA_WIDTH];
        end
    end

endmodule
