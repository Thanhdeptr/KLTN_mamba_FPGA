// FEED_SER watchdog + stall monitors (included in tb_rmsnorm_inproj_conv_scan_chain).
// Abort only on true deadlock (no pipeline progress), not cumulative backpressure wait.

    localparam PROGRESS_STALL_LIMIT = (NUM_VECTORS <= 10) ? 25_000 :
                                      (NUM_VECTORS * 2_000);
    localparam TOKEN_WAIT_LIMIT = (NUM_VECTORS <= 10) ? 25_000 :
                                  (NUM_VECTORS * 5_000);

    task automatic feed_guard_log;
        input [8*40-1:0] tag;
        input [15:0]     tok;
        input integer    beat_k;
        input integer    wait_cyc;
        begin
            $display("[FEED] %s tok=%0d beat=%0d wait=%0d cy | bq_rdy=%b conv_rdy=%b feed_rdy=%b scan_q=%0d drop=%b conv=%0d y_grp=%0d",
                     tag, tok, beat_k, wait_cyc,
                     beat_q_ready, conv_beat_ready, feed_ready,
                     scan_q_count_dbg, beat_q_drop,
                     conv_x_capture_cnt, y_unique_grps);
            if (mon_fp != 0)
                $fwrite(mon_fp,
                    "@%0d FEED_%s tok=%0d beat=%0d wait=%0d bq=%b conv_rdy=%b feed_rdy=%b q=%0d conv=%0d y_grp=%0d\n",
                    global_clk, tag, tok, beat_k, wait_cyc,
                    beat_q_ready, conv_beat_ready, feed_ready,
                    scan_q_count_dbg, conv_x_capture_cnt, y_unique_grps);
            dump_wedge_state();
        end
    endtask

    task automatic feed_progress_snap;
        output integer snap_conv;
        output integer snap_beats;
        output integer snap_ygrp;
        output integer snap_q;
        begin
            snap_conv  = conv_x_capture_cnt;
            snap_beats = beat_q_count_dbg;
            snap_ygrp  = y_unique_grps;
            snap_q     = scan_q_count_dbg;
        end
    endtask

    function automatic feed_progress_moved;
        input integer snap_conv;
        input integer snap_beats;
        input integer snap_ygrp;
        input integer snap_q;
        begin
            feed_progress_moved =
                (conv_x_capture_cnt != snap_conv) ||
                (beat_q_count_dbg != snap_beats) ||
                (y_unique_grps != snap_ygrp) ||
                (scan_q_count_dbg != snap_q);
        end
    endfunction

    task automatic feed_wait_beat_q;
        input [15:0]  tok;
        input integer beat_k;
        output        timed_out;
        integer       wc;
        integer       snap_conv, snap_beats, snap_ygrp, snap_q;
        begin
            timed_out = 1'b0;
            wc = 0;
            feed_progress_snap(snap_conv, snap_beats, snap_ygrp, snap_q);
            while (!beat_q_ready && !timed_out) begin
                @(posedge clk);
                wc = wc + 1;
                if (wc > mon_feed_beatq_wait_max)
                    mon_feed_beatq_wait_max = wc;
                if (feed_progress_moved(snap_conv, snap_beats, snap_ygrp, snap_q)) begin
                    feed_progress_snap(snap_conv, snap_beats, snap_ygrp, snap_q);
                    wc = 0;
                end
                if ((wc % 50000) == 0)
                    $display("[FEED] beat_q wait tok=%0d beat=%0d stall_cy=%0d bq=%b conv_rdy=%b q=%0d y_grp=%0d",
                             tok, beat_k, wc, beat_q_ready, conv_beat_ready,
                             scan_q_count_dbg, y_unique_grps);
                if (wc >= PROGRESS_STALL_LIMIT) begin
                    timed_out = 1'b1;
                    mon_feed_abort_tok  = tok;
                    mon_feed_abort_beat = beat_k;
                    feed_abort = 1'b1;
                    feed_stall = 1'b1;
                    feed_guard_log("BEATQ_DEADLOCK", tok, beat_k, wc);
                end
            end
        end
    endtask

    task automatic feed_wait_frame_ready;
        input [15:0]  tok;
        output        timed_out;
        integer       wc;
        integer       snap_conv, snap_beats, snap_ygrp, snap_q;
        begin
            timed_out = 1'b0;
            wc = 0;
            feed_progress_snap(snap_conv, snap_beats, snap_ygrp, snap_q);
            while (!feed_ready && !timed_out) begin
                @(posedge clk);
                wc = wc + 1;
                if (wc > mon_feed_frm_wait_max)
                    mon_feed_frm_wait_max = wc;
                if (feed_progress_moved(snap_conv, snap_beats, snap_ygrp, snap_q)) begin
                    feed_progress_snap(snap_conv, snap_beats, snap_ygrp, snap_q);
                    wc = 0;
                end
                if ((wc % 50000) == 0)
                    $display("[FEED] feed_ready wait tok=%0d stall_cy=%0d feed_rdy=%b bq=%b q=%0d",
                             tok, wc, feed_ready, beat_q_ready, scan_q_count_dbg);
                if (wc >= PROGRESS_STALL_LIMIT) begin
                    timed_out = 1'b1;
                    mon_feed_abort_tok = tok;
                    feed_abort = 1'b1;
                    feed_stall = 1'b1;
                    feed_guard_log("FEED_READY_DEADLOCK", tok, -1, wc);
                end
            end
        end
    endtask

    task automatic feed_wait_stream_token;
        input [15:0]  expect_tok;
        output        timed_out;
        integer       wc;
        begin
            timed_out = 1'b0;
            wc = 0;
            while ((stream_token_idx != expect_tok) && !timed_out) begin
                @(posedge clk);
                wc = wc + 1;
                if (wc > mon_feed_tok_wait_max)
                    mon_feed_tok_wait_max = wc;
                if ((wc % 10000) == 0)
                    $display("[FEED] stream_token wait expect=%0d got=%0d cy=%0d",
                             expect_tok, stream_token_idx, wc);
                if (wc >= TOKEN_WAIT_LIMIT) begin
                    timed_out = 1'b1;
                    mon_feed_abort_tok = expect_tok;
                    feed_abort = 1'b1;
                    feed_stall = 1'b1;
                    feed_guard_log("TOKEN_TIMEOUT", expect_tok, -1, wc);
                end
            end
        end
    endtask
