`timescale 1ns/1ps

module tb_global_controller_full_flow;
    reg clk;
    reg reset;
    reg start_system;
    wire done_system;

    wire [14:0] core_read_addr;
    reg  [255:0] core_read_data;
    wire [14:0] weight_read_addr;
    reg  [255:0] weight_read_data;
    wire [14:0] const_read_addr;
    reg  [255:0] const_read_data;

    wire core_write_en;
    wire [14:0] core_write_addr;
    wire [255:0] core_write_data;
    wire bank_sel;

    wire [2:0] mode_select;

    wire lin_start;
    wire [15:0] lin_len;
    reg lin_done;
    wire signed [15:0] lin_x_val;
    wire signed [255:0] lin_W_vals;
    wire [255:0] lin_bias_vals;
    wire lin_en;
    reg signed [255:0] lin_y_out_in;

    wire conv_start;
    wire conv_valid_in;
    wire conv_en;
    reg conv_ready_in;
    reg conv_valid_out;
    wire signed [255:0] conv_x_vec;
    wire signed [1023:0] conv_w_vec;
    wire signed [255:0] conv_b_vec;
    reg signed [255:0] conv_y_vec;

    wire scan_start;
    wire scan_en;
    wire scan_clear_h;
    reg scan_done;
    wire signed [15:0] scan_delta_val;
    wire signed [15:0] scan_x_val;
    wire signed [15:0] scan_D_val;
    wire signed [15:0] scan_gate_val;
    wire signed [255:0] scan_A_vec;
    wire signed [255:0] scan_B_vec;
    wire signed [255:0] scan_C_vec;
    reg signed [15:0] scan_y_out;

    wire signed [15:0] softplus_in;
    reg  signed [15:0] softplus_out;

    Global_Controller_Full_Flow dut (
        .clk(clk),
        .reset(reset),
        .start_system(start_system),
        .done_system(done_system),
        .core_read_addr(core_read_addr),
        .core_read_data(core_read_data),
        .weight_read_addr(weight_read_addr),
        .weight_read_data(weight_read_data),
        .const_read_addr(const_read_addr),
        .const_read_data(const_read_data),
        .core_write_en(core_write_en),
        .core_write_addr(core_write_addr),
        .core_write_data(core_write_data),
        .bank_sel(bank_sel),
        .mode_select(mode_select),
        .lin_start(lin_start),
        .lin_len(lin_len),
        .lin_done(lin_done),
        .lin_x_val(lin_x_val),
        .lin_W_vals(lin_W_vals),
        .lin_bias_vals(lin_bias_vals),
        .lin_en(lin_en),
        .lin_y_out_in(lin_y_out_in),
        .conv_start(conv_start),
        .conv_valid_in(conv_valid_in),
        .conv_en(conv_en),
        .conv_ready_in(conv_ready_in),
        .conv_valid_out(conv_valid_out),
        .conv_x_vec(conv_x_vec),
        .conv_w_vec(conv_w_vec),
        .conv_b_vec(conv_b_vec),
        .conv_y_vec(conv_y_vec),
        .scan_start(scan_start),
        .scan_en(scan_en),
        .scan_clear_h(scan_clear_h),
        .scan_done(scan_done),
        .scan_delta_val(scan_delta_val),
        .scan_x_val(scan_x_val),
        .scan_D_val(scan_D_val),
        .scan_gate_val(scan_gate_val),
        .scan_A_vec(scan_A_vec),
        .scan_B_vec(scan_B_vec),
        .scan_C_vec(scan_C_vec),
        .scan_y_out(scan_y_out),
        .softplus_in(softplus_in),
        .softplus_out(softplus_out)
    );

    localparam [6:0] S_SCAN_WRITE   = 7'd61;
    localparam [6:0] S_SCAN_LOAD_STATIC = 7'd51;
    localparam [6:0] S_SCAN_LOAD_DYN_1  = 7'd54;
    localparam [6:0] S_PHASE5_SETUP = 7'd80;
    localparam [6:0] S_OUTPROJ_SETUP = 7'd81;
    localparam [6:0] S_OUTPROJ_WAIT_L = 7'd85;
    localparam [6:0] S_OUTPROJ_WRITE = 7'd86;
    localparam [6:0] S_DONE = 7'd99;

    always #5 clk = ~clk;

    task expect_next_state;
        input [6:0] expected;
        input [255:0] msg;
        begin
            @(posedge clk);
            #1;
            if (dut.state !== expected) begin
                $display("FAIL: %0s. expected=%0d got=%0d", msg, expected, dut.state);
                $finish(1);
            end
            $display("PASS: %0s -> state=%0d", msg, dut.state);
        end
    endtask

    task wait_state_with_timeout;
        input [6:0] expected;
        input integer max_cycles;
        input [255:0] msg;
        integer k;
        begin
            for (k = 0; k < max_cycles; k = k + 1) begin
                @(posedge clk);
                #1;
                if (dut.state === expected) begin
                    $display("PASS: %0s -> state=%0d after %0d cycles", msg, dut.state, k + 1);
                    disable wait_state_with_timeout;
                end
            end
            $display("FAIL: %0s timeout. expected=%0d got=%0d", msg, expected, dut.state);
            $finish(1);
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        start_system = 1'b0;

        core_read_data = 256'd0;
        weight_read_data = 256'd0;
        const_read_data = 256'd0;
        lin_done = 1'b0;
        lin_y_out_in = 256'sd0;
        conv_ready_in = 1'b0;
        conv_valid_out = 1'b0;
        conv_y_vec = 256'sd0;
        scan_done = 1'b0;
        scan_y_out = 16'sd0;
        softplus_out = 16'sd0;

        repeat (2) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        // Keep lin_done high so controller can leave WAIT_L states in smoke path.
        lin_done = 1'b1;

        // Case 1: End of final scan channel must go to Phase 5 setup.
        @(negedge clk);
        dut.state = S_SCAN_WRITE;
        dut.token_cnt = 16'd999;
        dut.scan_ch_cnt = 8'd127;
        expect_next_state(S_PHASE5_SETUP, "scan final channel enters phase5");

        // Case 2: End of token on non-final channel keeps scan flow.
        @(negedge clk);
        dut.state = S_SCAN_WRITE;
        dut.token_cnt = 16'd999;
        dut.scan_ch_cnt = 8'd5;
        expect_next_state(S_SCAN_LOAD_STATIC, "scan next channel path");

        // Case 3: Mid-token keeps dynamic scan loop.
        @(negedge clk);
        dut.state = S_SCAN_WRITE;
        dut.token_cnt = 16'd100;
        dut.scan_ch_cnt = 8'd127;
        expect_next_state(S_SCAN_LOAD_DYN_1, "scan continue token path");

        // Case 4 (smoke): from final scan write, run through Phase5 and finish at DONE.
        @(negedge clk);
        dut.state = S_SCAN_WRITE;
        dut.token_cnt = 16'd999;
        dut.scan_ch_cnt = 8'd127;
        expect_next_state(S_PHASE5_SETUP, "smoke enters phase5 from scan tail");
        expect_next_state(S_OUTPROJ_SETUP, "smoke enters outproj setup");

        // Wait until phase5 reaches WAIT_L naturally after feed loop.
        wait_state_with_timeout(S_OUTPROJ_WAIT_L, 1200, "smoke reaches outproj wait_l");

        // Force final token/chunk before write so one write cycle can terminate to DONE.
        @(negedge clk);
        dut.token_cnt = 16'd999;
        dut.chunk_cnt = 4'd3;

        expect_next_state(S_OUTPROJ_WRITE, "smoke enters outproj write");
        expect_next_state(S_DONE, "smoke terminates at done");

        @(posedge clk);
        #1;
        if (!done_system) begin
            $display("FAIL: done_system not asserted in S_DONE");
            $finish(1);
        end
        $display("PASS: done_system asserted");

        $display("TEST RESULT: PASS");
        $finish;
    end
endmodule
