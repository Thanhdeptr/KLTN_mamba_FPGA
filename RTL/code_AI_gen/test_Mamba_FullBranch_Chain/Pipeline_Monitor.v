`timescale 1ns/1ps

module Pipeline_Monitor #(
    parameter D_INNER = 128,
    parameter NUM_STATES = 10
) (
    input  wire clk,
    input  wire reset,
    input  wire monitor_en,

    // Module probe signals
    input  wire rms_start,
    input  wire rms_done,
    input  wire inproj_start,
    input  wire inproj_done,
    input  wire conv_valid_in,
    input  wire all_conv_valid,
    input  wire scan_start,
    input  wire all_scan_done,
    input  wire outproj_done,

    // Packed scan state: D_INNER channels x 4 bits
    input  wire [D_INNER*4-1:0] scan_state_dbg_packed
);

    // Cycle counter
    reg [63:0] cycle_cnt;

    // Previous values for edge detection
    reg prev_rms_start, prev_rms_done;
    reg prev_inproj_start, prev_inproj_done;
    reg prev_conv_valid_in, prev_all_conv_valid;
    reg prev_scan_start, prev_all_scan_done;
    reg prev_outproj_done;

    // Current transaction id (increment on rms_start)
    reg [15:0] tx_id;

    // Per-module start cycles (current tx)
    reg [63:0] start_rms;
    reg [63:0] start_inproj;
    reg [63:0] start_conv;
    reg [15:0] conv_tx_id;
    reg [63:0] start_scan;
    reg [63:0] start_total; // same as start_rms

    // State counters for current tx
    integer s;
    reg [63:0] state_counters [0:NUM_STATES-1];

    integer fd_lat, fd_state;

    integer i,j;

    initial begin
        cycle_cnt = 0;
        prev_rms_start = 0;
        prev_rms_done = 0;
        prev_inproj_start = 0;
        prev_inproj_done = 0;
        prev_conv_valid_in = 0;
        prev_all_conv_valid = 0;
        prev_scan_start = 0;
        prev_all_scan_done = 0;
        prev_outproj_done = 0;
        tx_id = 0;
        for (s = 0; s < NUM_STATES; s = s + 1) state_counters[s] = 0;

        fd_lat   = $fopen("latency_report.csv", "w");
        fd_state = $fopen("state_cycles.csv", "w");
        if (fd_lat) $fdisplay(fd_lat, "tx_id,module,start_cycle,done_cycle,latency_cycles");
        if (fd_state) $fdisplay(fd_state, "tx_id,state_id,cycles");
    end

    // Main sampling
    always @(posedge clk) begin
        if (reset) begin
            cycle_cnt <= 0;
            prev_rms_start <= 0;
            prev_rms_done <= 0;
            prev_inproj_start <= 0;
            prev_inproj_done <= 0;
            prev_conv_valid_in <= 0;
            prev_all_conv_valid <= 0;
            prev_scan_start <= 0;
            prev_all_scan_done <= 0;
            prev_outproj_done <= 0;
            tx_id <= 0;
            for (s = 0; s < NUM_STATES; s = s + 1) state_counters[s] <= 0;
        end else begin
            cycle_cnt <= cycle_cnt + 1;

            // Per-clock sample of scan_state_dbg_packed into state counters
            if (monitor_en) begin
                // iterate channels
                for (i = 0; i < D_INNER; i = i + 1) begin
                    j = scan_state_dbg_packed[i*4 +: 4];
                    if (j >= 0 && j < NUM_STATES) begin
                        state_counters[j] <= state_counters[j] + 1;
                    end
                end
            end

            // Edge detections and captures (only when enabled)
            if (monitor_en) begin
                // RMS
                if (rms_start && !prev_rms_start) begin
                    tx_id <= tx_id + 1;
                    start_rms <= cycle_cnt;
                    start_total <= cycle_cnt;
                end
                if (rms_done && !prev_rms_done) begin
                    if (fd_lat) $fdisplay(fd_lat, "%0d,RMSNorm,%0d,%0d,%0d", tx_id, start_rms, cycle_cnt, cycle_cnt - start_rms);
                end

                // InProj
                if (inproj_start && !prev_inproj_start) begin
                    start_inproj <= cycle_cnt;
                end
                if (inproj_done && !prev_inproj_done) begin
                    if (fd_lat) $fdisplay(fd_lat, "%0d,InProj,%0d,%0d,%0d", tx_id, start_inproj, cycle_cnt, cycle_cnt - start_inproj);
                end

                // Conv (conv_valid_in -> all_conv_valid): use per-token valid as start
                if (conv_valid_in && !prev_conv_valid_in) begin
                    start_conv <= cycle_cnt;
                    conv_tx_id <= tx_id;
                end
                if (all_conv_valid && !prev_all_conv_valid) begin
                    if (fd_lat) $fdisplay(fd_lat, "%0d,Conv,%0d,%0d,%0d", conv_tx_id, start_conv, cycle_cnt, cycle_cnt - start_conv);
                end

                // Scan (start -> all_scan_done)
                if (scan_start && !prev_scan_start) begin
                    start_scan <= cycle_cnt;
                end
                if (all_scan_done && !prev_all_scan_done) begin
                    if (fd_lat) $fdisplay(fd_lat, "%0d,Scan,%0d,%0d,%0d", tx_id, start_scan, cycle_cnt, cycle_cnt - start_scan);
                end

                // Total (rms_start -> outproj_done)
                if (outproj_done && !prev_outproj_done) begin
                    if (fd_lat) $fdisplay(fd_lat, "%0d,Total,%0d,%0d,%0d", tx_id, start_total, cycle_cnt, cycle_cnt - start_total);

                    // Dump per-state counters for this tx
                    for (s = 0; s < NUM_STATES; s = s + 1) begin
                        if (fd_state) $fdisplay(fd_state, "%0d,%0d,%0d", tx_id, s, state_counters[s]);
                        // reset counters for next tx
                        state_counters[s] <= 0;
                    end
                end
            end

            // store previous values
            prev_rms_start <= rms_start;
            prev_rms_done <= rms_done;
            prev_inproj_start <= inproj_start;
            prev_inproj_done <= inproj_done;
            prev_conv_valid_in <= conv_valid_in;
            prev_all_conv_valid <= all_conv_valid;
            prev_scan_start <= scan_start;
            prev_all_scan_done <= all_scan_done;
            prev_outproj_done <= outproj_done;
        end
    end

endmodule
