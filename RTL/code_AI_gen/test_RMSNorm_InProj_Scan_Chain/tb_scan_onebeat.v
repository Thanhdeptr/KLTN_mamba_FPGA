`timescale 1ns/1ps
// One-beat smoke: conv_x only then finish.
module tb_scan_onebeat;
    localparam LANES=16, DATA_WIDTH=16;
    reg clk=0, rst_n=0, en=0;
    reg conv_x_valid=0, conv_z_valid=0;
    reg [2:0] conv_x_grp=0, conv_z_grp=0;
    reg [15:0] conv_x_token=0, conv_z_token=0;
    reg signed [LANES*DATA_WIDTH-1:0] conv_x_vec=0, conv_z_vec=0;
    wire scan_busy, scan_ready, conv_beat_ready, scan_valid;
    integer cyc;

    Scan_Chain_Wrapper #(.MAX_TOKENS(1000)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .clear_h(1'b0),
        .conv_x_valid(conv_x_valid), .conv_z_valid(conv_z_valid),
        .conv_x_grp(conv_x_grp), .conv_x_token(conv_x_token),
        .conv_z_grp(conv_z_grp), .conv_z_token(conv_z_token),
        .conv_x_vec(conv_x_vec), .conv_z_vec(conv_z_vec),
        .conv_beat_ready(conv_beat_ready),
        .scan_valid(scan_valid), .scan_token(), .scan_grp(), .scan_y_vec(),
        .scan_busy(scan_busy), .scan_ready(scan_ready),
        .mon_q_count(), .mon_q_head_x(), .mon_q_head_grp(), .mon_q_head_tok(),
        .mon_inj_valid(), .mon_z_slot_mask(), .mon_x_skid_mask(), .mon_await_z_mask(),
        .mon_beat_valid(), .mon_ing_count(), .mon_x_beat_pend(),
        .mon_ex_busy_mask(), .mon_z_state()
    );
    always #5 clk=~clk;
    initial begin
        cyc=0;
        $display("[1BEAT] init");
        repeat(4) @(posedge clk);
        $display("[1BEAT] post-reset-wait");
        rst_n<=1; en<=1;
        @(posedge clk);
        $display("[1BEAT] pulse x");
        conv_x_valid=1;
        @(posedge clk);
        conv_x_valid=0;
        $display("[1BEAT] post-x");
        conv_z_valid=1; conv_z_grp=0; conv_z_token=0;
        @(posedge clk);
        conv_z_valid=0;
        $display("[1BEAT] post-z");
        for (cyc=0; cyc<500; cyc=cyc+1) begin
            @(posedge clk);
            if (cyc==100 || cyc==500 || cyc==2000)
                $display("[1BEAT] cyc=%0d busy=%b rdy=%b q=%0d beat=%b ing=%0d xpend=%b",
                         cyc, scan_busy, scan_ready, dut.mon_q_count, dut.mon_beat_valid,
                         dut.mon_ing_count, dut.mon_x_beat_pend);
        end
        $display("[1BEAT] done"); $finish;
    end
endmodule
