// Pipeline monitor: conv -> Scan_Chain_Wrapper q -> scan pipe -> y
// Included inside tb_rmsnorm_inproj_conv_scan_chain.
// Outputs: chain_debug_events.log, chain_monitor_summary.txt

    integer mon_fp;
    integer mon_sum_fp;
    integer mon_q_count_max;
    integer mon_q_pop_total;
    integer mon_conv_reject_cnt;
    integer mon_z_solo_enq_cnt;
    integer mon_feed_done_clk;
    integer mon_y_stall_clk;
    integer mon_first_gap_tok;
    integer mon_last_hb_clk;

    reg [13:0] mon_q_count_prev;
    reg        mon_feed_complete_d;
    reg        mon_scan_stream_done_d;
    reg        mon_y_stall_logged;

    reg [7:0]  mon_conv_grps [0:NUM_VECTORS-1];
    reg [7:0]  mon_beat_grps  [0:NUM_VECTORS-1];
    reg [7:0]  mon_y_grps     [0:NUM_VECTORS-1];
    reg [7:0]  mon_pair_grps  [0:NUM_VECTORS-1];
    reg        mon_conv_full  [0:NUM_VECTORS-1];
    reg        mon_beat_full   [0:NUM_VECTORS-1];
    reg        mon_y_full      [0:NUM_VECTORS-1];

    integer mon_feed_abort_tok;
    integer mon_feed_abort_beat;
    integer mon_beat_q_drop_cnt;
    integer mon_feed_beatq_wait_max;
    integer mon_feed_frm_wait_max;
    integer mon_feed_tok_wait_max;
    reg        beat_q_drop_d;

    function integer mon_popcount8;
        input [7:0] v;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < GRPS; i = i + 1)
                if (v[i])
                    c = c + 1;
            mon_popcount8 = c;
        end
    endfunction

    task automatic mon_open_logs;
        begin
            if (mon_fp != 0)
                return;
            mon_fp = $fopen("chain_debug_events.log", "w");
            mon_sum_fp = $fopen("chain_monitor_summary.txt", "w");
            if (mon_fp == 0)
                $display("[MON] WARN: cannot open chain_debug_events.log");
            else
                $fwrite(mon_fp,
                    "# cycle event conv_x conv_z pair_enq beat_x beat_z scan_valid y q_count scan_rdy conv_rdy stream_done feed_done\n");
            mon_q_count_max = 0;
            mon_q_pop_total = 0;
            mon_conv_reject_cnt = 0;
            mon_z_solo_enq_cnt = 0;
            mon_feed_done_clk = -1;
            mon_y_stall_clk = -1;
            mon_first_gap_tok = -1;
            mon_last_hb_clk = 0;
            mon_feed_abort_tok = -1;
            mon_feed_abort_beat = -1;
            mon_beat_q_drop_cnt = 0;
            mon_feed_beatq_wait_max = 0;
            mon_feed_frm_wait_max = 0;
            mon_feed_tok_wait_max = 0;
            feed_abort = 1'b0;
            beat_q_drop_d = 1'b0;
            mon_q_count_prev = 14'd0;
            mon_feed_complete_d = 1'b0;
            mon_scan_stream_done_d = 1'b0;
            mon_y_stall_logged = 1'b0;
            for (t = 0; t < NUM_VECTORS; t = t + 1) begin
                mon_conv_grps[t] = 8'd0;
                mon_beat_grps[t]  = 8'd0;
                mon_y_grps[t]     = 8'd0;
                mon_pair_grps[t]  = 8'd0;
                mon_conv_full[t]  = 1'b0;
                mon_beat_full[t]  = 1'b0;
                mon_y_full[t]     = 1'b0;
            end
        end
    endtask

    task automatic mon_log_line;
        input [8*64-1:0] tag;
        begin
            if (mon_fp != 0)
                $fwrite(mon_fp,
                    "@%0d %s conv=%0d/%0d pair_enq=%0d beat=%0d/%0d scan_valid=%0d y=%0d q=%0d scan_rdy=%b conv_rdy=%b stream_done=%b feed_done=%b\n",
                    global_clk, tag,
                    conv_x_capture_cnt, conv_z_capture_cnt,
                    pair_enq_cnt, beat_x_cnt, beat_z_cnt,
                    scan_valid_cnt, y_samples, u_scan.q_count,
                    scan_ready, conv_beat_ready,
                    scan_stream_done, feed_complete);
        end
    endtask

    task automatic mon_log_token_milestone;
        input [15:0] tok;
        input [8*32-1:0] stage;
        input [2:0]  grp;
        begin
            if (mon_fp != 0)
                $fwrite(mon_fp,
                    "@%0d TOKEN_%0d %s grp=%0d conv_g=%0d beat_g=%0d y_g=%0d pair_g=%0d q=%0d\n",
                    global_clk, tok, stage, grp,
                    mon_popcount8(mon_conv_grps[tok]),
                    mon_popcount8(mon_beat_grps[tok]),
                    mon_popcount8(mon_y_grps[tok]),
                    mon_popcount8(mon_pair_grps[tok]),
                    u_scan.q_count);
        end
    endtask

    task automatic mon_on_conv_x;
        input [15:0] tok;
        input [2:0]  grp;
        begin
            if (!mon_conv_grps[tok][grp[2:0]]) begin
                mon_conv_grps[tok][grp[2:0]] = 1'b1;
                if (mon_popcount8(mon_conv_grps[tok]) == GRPS && !mon_conv_full[tok]) begin
                    mon_conv_full[tok] = 1'b1;
                    mon_log_token_milestone(tok, "CONV8", grp);
                end
            end
        end
    endtask

    task automatic mon_on_pair_enq;
        input [15:0] tok;
        input [2:0]  grp;
        begin
            mon_pair_grps[tok][grp[2:0]] = 1'b1;
        end
    endtask

    task automatic mon_on_beat_x;
        input [15:0] tok;
        input [2:0]  grp;
        begin
            if (!mon_beat_grps[tok][grp[2:0]]) begin
                mon_beat_grps[tok][grp[2:0]] = 1'b1;
                if (mon_popcount8(mon_beat_grps[tok]) == GRPS && !mon_beat_full[tok]) begin
                    mon_beat_full[tok] = 1'b1;
                    mon_log_token_milestone(tok, "BEAT8", grp);
                end
            end
        end
    endtask

    task automatic mon_on_scan_y;
        input [15:0] tok;
        input [2:0]  grp;
        begin
            if (!mon_y_grps[tok][grp[2:0]]) begin
                mon_y_grps[tok][grp[2:0]] = 1'b1;
                if (mon_popcount8(mon_y_grps[tok]) == GRPS && !mon_y_full[tok]) begin
                    mon_y_full[tok] = 1'b1;
                    mon_log_token_milestone(tok, "Y8", grp);
                end
            end
        end
    endtask

    task automatic mon_scan_first_gaps;
        integer cg, bg, yg;
        begin
            for (t = 0; t < NUM_VECTORS; t = t + 1) begin
                cg = mon_popcount8(mon_conv_grps[t]);
                bg = mon_popcount8(mon_beat_grps[t]);
                yg = mon_popcount8(mon_y_grps[t]);
                if (mon_first_gap_tok < 0 && cg == GRPS && bg < GRPS) begin
                    mon_first_gap_tok = t;
                    if (mon_fp != 0)
                        $fwrite(mon_fp,
                            "@%0d FIRST_GAP tok=%0d conv_g=%0d beat_g=%0d y_g=%0d pair_g=%0d q=%0d\n",
                            global_clk, t, cg, bg, yg,
                            mon_popcount8(mon_pair_grps[t]), u_scan.q_count);
                    $display("[MON] FIRST_GAP tok=%0d @clk=%0d: conv_g=%0d beat_g=%0d y_g=%0d",
                             t, global_clk, cg, bg, yg);
                end
            end
        end
    endtask

    task automatic mon_tick;
        reg [13:0] q_now;
        reg [13:0] q_delta;
        begin
            if (!rst_n || !en)
                return;
            q_now = u_scan.q_count;
            if (q_now > mon_q_count_max)
                mon_q_count_max = q_now;
            if (q_now < mon_q_count_prev) begin
                q_delta = mon_q_count_prev - q_now;
                mon_q_pop_total = mon_q_pop_total + q_delta;
            end
            mon_q_count_prev = q_now;

            if (beat_q_drop && !beat_q_drop_d)
                mon_beat_q_drop_cnt = mon_beat_q_drop_cnt + 1;
            beat_q_drop_d = beat_q_drop;

            if ((conv_x_valid_out || conv_z_valid_out) && !conv_beat_ready)
                mon_conv_reject_cnt = mon_conv_reject_cnt + 1;

            if (u_scan.do_z_solo)
                mon_z_solo_enq_cnt = mon_z_solo_enq_cnt + 1;

            if (feed_complete && !mon_feed_complete_d) begin
                mon_feed_done_clk = global_clk;
                mon_log_line("FEED_DONE");
                $display("[MON] FEED_DONE @clk=%0d: conv=%0d pair_enq=%0d beat=%0d/%0d y=%0d q_max=%0d q_now=%0d",
                         global_clk, conv_x_capture_cnt, pair_enq_cnt,
                         beat_x_cnt, beat_z_cnt, y_samples, mon_q_count_max, q_now);
            end
            mon_feed_complete_d = feed_complete;

            if (scan_stream_done && !mon_scan_stream_done_d)
                mon_log_line("STREAM_DONE_ASSERT");
            mon_scan_stream_done_d = scan_stream_done;

            if (conv_x_valid_out)
                mon_on_conv_x(dut.u_conv.x_out_token, dut.u_conv.x_out_grp);

            if (u_scan.do_x && u_scan.do_z_pair)
                mon_on_pair_enq(u_scan.enq_tok, u_scan.enq_grp);

            if (mon_beat_valid && u_scan.beat_path_x_r)
                mon_on_beat_x(u_scan.beat_token_r, u_scan.beat_grp_r);

            if (scan_valid)
                mon_on_scan_y(scan_token, scan_grp);

            if ((global_clk - mon_last_hb_clk) >= 100_000) begin
                mon_last_hb_clk = global_clk;
                mon_log_line("HEARTBEAT");
            end

            if (!mon_y_stall_logged && feed_complete &&
                (y_unique_grps > 0) && (y_unique_grps < NUM_VECTORS * GRPS) &&
                (q_now == 14'd0) && !scan_busy &&
                ((global_clk - y_last_clk) > 1000)) begin
                mon_y_stall_logged = 1'b1;
                mon_y_stall_clk = global_clk;
                mon_log_line("Y_STALL");
                mon_scan_first_gaps();
                $display("[MON] Y_STALL @clk=%0d: y=%0d/%0d beat=%0d pair_enq=%0d conv=%0d q=0",
                         global_clk, y_samples, NUM_VECTORS * D_INNER,
                         beat_x_cnt, pair_enq_cnt, conv_x_capture_cnt);
                dump_wedge_state();
            end
        end
    endtask

    task automatic mon_print_summary;
        integer full_conv, full_beat, full_y;
        begin
            mon_first_gap_tok = -1;
            mon_scan_first_gaps();
            full_conv = 0;
            full_beat = 0;
            full_y    = 0;
            if (mon_sum_fp == 0)
                mon_sum_fp = $fopen("chain_monitor_summary.txt", "w");
            $display("");
            $display("[MON] === PIPELINE MONITOR SUMMARY (N=%0d) ===", NUM_VECTORS);
            $fwrite(mon_sum_fp, "=== chain monitor N=%0d ===\n", NUM_VECTORS);
            $fwrite(mon_sum_fp,
                "lifecycle: conv_x=%0d conv_z=%0d pair_enq=%0d beat_x=%0d beat_z=%0d scan_valid=%0d y=%0d\n",
                conv_x_capture_cnt, conv_z_capture_cnt, pair_enq_cnt,
                beat_x_cnt, beat_z_cnt, scan_valid_cnt, y_samples);
            $fwrite(mon_sum_fp,
                "queue: q_max=%0d q_pop_total=%0d conv_reject=%0d z_solo_enq=%0d\n",
                mon_q_count_max, mon_q_pop_total, mon_conv_reject_cnt, mon_z_solo_enq_cnt);
            $fwrite(mon_sum_fp, "feed_done_clk=%0d y_stall_clk=%0d first_gap_tok=%0d\n",
                    mon_feed_done_clk, mon_y_stall_clk, mon_first_gap_tok);
            $fwrite(mon_sum_fp,
                "feed_guard: abort=%0d abort_tok=%0d beatq_wait_max=%0d frm_wait_max=%0d tok_wait_max=%0d beat_q_drop=%0d\n",
                feed_abort, mon_feed_abort_tok, mon_feed_beatq_wait_max,
                mon_feed_frm_wait_max, mon_feed_tok_wait_max, mon_beat_q_drop_cnt);
            $display("  lifecycle: conv=%0d pair_enq=%0d beat=%0d/%0d scan_valid=%0d y=%0d",
                     conv_x_capture_cnt, pair_enq_cnt, beat_x_cnt, beat_z_cnt,
                     scan_valid_cnt, y_samples);
            $display("  queue: q_max=%0d q_pop_total=%0d conv_backpressure=%0d",
                     mon_q_count_max, mon_q_pop_total, mon_conv_reject_cnt);
            $display("  first_gap_tok=%0d feed_done@%0d y_stall@%0d feed_abort=%0d beat_q_drop=%0d",
                     mon_first_gap_tok, mon_feed_done_clk, mon_y_stall_clk,
                     feed_abort, mon_beat_q_drop_cnt);
            $fwrite(mon_sum_fp, "\n# tok conv_g beat_g y_g pair_g\n");
            for (t = 0; t < NUM_VECTORS; t = t + 1) begin
                if (mon_popcount8(mon_conv_grps[t]) == GRPS) full_conv = full_conv + 1;
                if (mon_popcount8(mon_beat_grps[t]) == GRPS)  full_beat = full_beat + 1;
                if (mon_popcount8(mon_y_grps[t]) == GRPS)     full_y    = full_y + 1;
                if (mon_popcount8(mon_conv_grps[t]) != GRPS ||
                    mon_popcount8(mon_beat_grps[t]) != GRPS ||
                    mon_popcount8(mon_y_grps[t]) != GRPS ||
                    t < 20 || t >= NUM_VECTORS - 5) begin
                    $fwrite(mon_sum_fp, "%0d %0d %0d %0d %0d\n",
                            t,
                            mon_popcount8(mon_conv_grps[t]),
                            mon_popcount8(mon_beat_grps[t]),
                            mon_popcount8(mon_y_grps[t]),
                            mon_popcount8(mon_pair_grps[t]));
                end
            end
            $fwrite(mon_sum_fp, "tokens_full: conv=%0d beat=%0d y=%0d / %0d\n",
                    full_conv, full_beat, full_y, NUM_VECTORS);
            $display("  tokens full (8 grp): conv=%0d beat=%0d y=%0d / %0d",
                     full_conv, full_beat, full_y, NUM_VECTORS);
            $display("[MON] logs: chain_debug_events.log chain_monitor_summary.txt");
            $display("[MON] === END MONITOR ===");
            if (mon_fp != 0)
                $fclose(mon_fp);
            if (mon_sum_fp != 0)
                $fclose(mon_sum_fp);
        end
    endtask
