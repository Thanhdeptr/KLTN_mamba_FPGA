`timescale 1ns/1ps

module Mamba_Control_Unit #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
) (
    input  wire                      clk,
    input  wire                      reset,

    // Simple register interface (adapter can be AXI4-Lite -> this iface)
    input  wire                      reg_wr,
    input  wire                      reg_rd,
    input  wire [ADDR_WIDTH-1:0]     reg_addr,
    input  wire [DATA_WIDTH-1:0]     reg_wdata,
    output reg  [DATA_WIDTH-1:0]     reg_rdata,
    output reg                       reg_ready,

    // Control outputs to Mamba block
    output reg                       rms_start,
    output reg                       rms_en,
    output reg                       inproj_start,
    output reg                       inproj_en,
    output reg                       conv_start,
    output reg                       conv_en,
    output reg                       conv_valid_in,
    output reg                       scan_start,
    output reg                       scan_en,
    output reg                       scan_clear_h,
    output reg                       outproj_start,
    output reg                       outproj_en,

    // Inputs: done/valid flags from Mamba
    input  wire                      rms_done,
    input  wire                      inproj_done,
    input  wire                      all_conv_valid,
    input  wire                      all_scan_done,
    input  wire                      outproj_done,

    // Status/interrupt
    output reg                       busy,
    output reg                       done,
    output reg                       irq
);

// Register map (word addresses)
localparam REG_CTRL    = 8'h00; // bit0: start, bit1: step, bit2: clear
localparam REG_STATUS  = 8'h04; // read-only: bit0 busy, bit1 done
localparam REG_TOKENS  = 8'h08; // tokens (not used internally by CU yet)
localparam REG_TRACE   = 8'h0C; // trace flags: bit0 TRACE, bit8 TRACE_CH, bit16 TRACE_TOKEN

// Internal registers
reg [31:0] r_tokens;
reg [31:0] r_trace;
reg        r_clear;
reg        r_start_req;
reg [1:0]  r_reg_ready_cnt;
// latched/synchronized done flags from datapath
reg        r_rms_done;
reg        r_inproj_done;
reg        r_all_conv_valid;
reg        r_all_scan_done;
reg        r_outproj_done;
// one-cycle delayed start request latches (pulse actual starts one cycle after state entry)
reg        r_rms_start_req;
reg        r_inproj_start_req;
reg        r_conv_start_req;
// one-cycle delayed copy for valid pulse (conv needs valid_in one cycle after start)
reg        r_conv_start_req_d1;
reg        r_scan_start_req;
reg        r_outproj_start_req;

// Simple FSM phases matching TB sequence
localparam S_IDLE   = 4'd0;
localparam S_RMS    = 4'd1;
localparam S_INPROJ = 4'd2;
localparam S_CONV   = 4'd3;
localparam S_SCAN   = 4'd4;
localparam S_OUT    = 4'd5;
localparam S_DONE   = 4'd6;

reg [3:0] state, next_state;
reg [3:0] prev_state;

always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE;
    end else begin
        state <= next_state;
    end
end

// FSM next-state
always @(*) begin
    next_state = state;
    // if a clear was requested via register write, force to IDLE
    if (r_clear) begin
        next_state = S_IDLE;
    end
    case (state)
        S_IDLE: begin
            if (r_start_req) next_state = S_RMS;
        end
        S_RMS: begin
            if (r_rms_done) next_state = S_INPROJ;
        end
        S_INPROJ: begin
            if (r_inproj_done) next_state = S_CONV;
        end
        S_CONV: begin
            if (r_all_conv_valid) next_state = S_SCAN;
        end
        S_SCAN: begin
            if (r_all_scan_done) next_state = S_OUT;
        end
        S_OUT: begin
            if (r_outproj_done) next_state = S_DONE;
        end
        S_DONE: begin
            next_state = S_IDLE;
        end
    endcase
end

// Outputs and control signals
always @(posedge clk) begin
    if (reset) begin
        // clear regs
        r_tokens <= 32'd0;
        r_trace  <= 32'd0;
        r_clear  <= 1'b0;
        r_start_req <= 1'b0;
        r_reg_ready_cnt <= 2'd0;
        r_rms_done <= 1'b0;
        r_inproj_done <= 1'b0;
        r_all_conv_valid <= 1'b0;
        r_all_scan_done <= 1'b0;
        r_outproj_done <= 1'b0;

        rms_start <= 1'b0;
        rms_en    <= 1'b0;
        inproj_start <= 1'b0;
        inproj_en    <= 1'b0;
        conv_start <= 1'b0;
        conv_en    <= 1'b0;
        conv_valid_in <= 1'b0;
        scan_start <= 1'b0;
        scan_en    <= 1'b0;
        scan_clear_h <= 1'b0;
        outproj_start <= 1'b0;
        outproj_en    <= 1'b0;

        busy <= 1'b0;
        done <= 1'b0;
        irq  <= 1'b0;
        reg_rdata <= 32'd0;
        reg_ready <= 1'b0;
    end else begin
        // Default ready managed by small counter to extend visibility
        if (r_reg_ready_cnt != 2'd0) begin
            reg_ready <= 1'b1;
            r_reg_ready_cnt <= r_reg_ready_cnt - 1'b1;
        end else begin
            reg_ready <= 1'b0;
        end

        // Register interface (simple, single-cycle response)
        if (reg_wr) begin
            // extend reg_ready for a couple cycles so TB won't miss it
            r_reg_ready_cnt <= 2'd2;
            $display("CU: reg_wr addr=0x%0h data=0x%0h time=%0t", reg_addr, reg_wdata, $time);
            $display("CU: reg_ready (start) addr=0x%0h time=%0t", reg_addr, $time);
            case (reg_addr)
                REG_CTRL: begin
                    // start bit triggers run
                    if (reg_wdata[0]) begin
                        // latch a start request so FSM can pick it reliably
                        r_start_req <= 1'b1;
                        busy <= 1'b1;
                        done <= 1'b0;
                        irq  <= 1'b0;
                    end
                    // clear bit
                    if (reg_wdata[2]) begin
                        // request FSM clear; do not assign `state` here (avoid multiple drivers)
                        busy <= 1'b0;
                        done <= 1'b0;
                        irq  <= 1'b0;
                        r_clear <= 1'b1;
                    end
                end
                REG_TOKENS: begin
                    r_tokens <= reg_wdata;
                end
                REG_TRACE: begin
                    r_trace <= reg_wdata;
                end
                default: begin
                end
            endcase
        end else if (reg_rd) begin
            // extend reg_ready similarly for reads
            r_reg_ready_cnt <= 2'd2;
            $display("CU: reg_rd addr=0x%0h time=%0t", reg_addr, $time);
            $display("CU: reg_ready (read) addr=0x%0h time=%0t", reg_addr, $time);
            case (reg_addr)
                REG_CTRL: begin
                    reg_rdata <= {31'd0, busy};
                end
                REG_STATUS: begin
                    reg_rdata <= {30'd0, done, busy};
                end
                REG_TOKENS: begin
                    reg_rdata <= r_tokens;
                end
                REG_TRACE: begin
                    reg_rdata <= r_trace;
                end
                default: reg_rdata <= 32'd0;
            endcase
        end

        // sample/synchronize done flags from datapath to avoid missing 1-cycle pulses
        r_rms_done <= rms_done;
        r_inproj_done <= inproj_done;
        r_all_conv_valid <= all_conv_valid;
        r_all_scan_done <= all_scan_done;
        r_outproj_done <= outproj_done;

        // generate one-cycle-delayed start requests on state entry
        r_rms_start_req <= (state == S_RMS    && prev_state != S_RMS)    ? 1'b1 : 1'b0;
        r_inproj_start_req <= (state == S_INPROJ && prev_state != S_INPROJ) ? 1'b1 : 1'b0;
        r_conv_start_req <= (state == S_CONV   && prev_state != S_CONV)   ? 1'b1 : 1'b0;
        r_scan_start_req <= (state == S_SCAN   && prev_state != S_SCAN)   ? 1'b1 : 1'b0;
        r_outproj_start_req <= (state == S_OUT   && prev_state != S_OUT)   ? 1'b1 : 1'b0;

        // Clear control pulses by default
        // default: deassert starts; actual pulses come from delayed request latches
        rms_start <= r_rms_start_req;
        inproj_start <= r_inproj_start_req;
        conv_start <= r_conv_start_req;
        scan_start <= r_scan_start_req;
        outproj_start <= r_outproj_start_req;

        // Drive enables and valid signals based on state
        case (state)
            S_IDLE: begin
                // enables are managed globally below (driven by `busy`)
                conv_valid_in <= 1'b0;
                scan_clear_h <= 1'b0;
                busy <= busy; // unchanged
            end
            S_RMS: begin
                // initial scan_clear on entry to S_RMS (happens immediately)
                if (prev_state != S_RMS) begin
                    scan_clear_h <= 1'b1;
                end else begin
                    scan_clear_h <= 1'b0;
                end
                $display("CU: enter S_RMS time=%0t", $time);
            end
            S_INPROJ: begin
                // actual inproj_start is delayed one cycle via r_inproj_start_req
                $display("CU: enter S_INPROJ time=%0t", $time);
            end
            S_CONV: begin
                // conv_start is a one-cycle pulse on state entry; many conv units expect
                // a separate `valid_in` in the following cycle (start resets internal FSM).
                // Create a one-cycle delayed copy so `conv_valid_in` arrives one cycle
                // after `conv_start`.
                    r_conv_start_req_d1 <= r_conv_start_req;
                    conv_valid_in <= r_conv_start_req_d1;
                $display("CU: enter S_CONV time=%0t", $time);
            end
            S_SCAN: begin
                // scan_start is delayed one cycle via r_scan_start_req
                // scan_clear_h is generated at S_RMS entry (initial clear)
                $display("CU: enter S_SCAN time=%0t", $time);
            end
            S_OUT: begin
                // outproj_start is delayed one cycle via r_outproj_start_req
                $display("CU: enter S_OUT time=%0t", $time);
            end
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                irq  <= 1'b1;
                // on completion, also clear any pending clear request
                r_clear <= 1'b0;
                // ensure start request cleared on completion
                r_start_req <= 1'b0;
                $display("CU: enter S_DONE time=%0t", $time);
            end
            default: begin end
        endcase
        // Keep enable signals asserted early: while busy OR when start request is pending
        // Also include the one-cycle delayed start request so `start && en` can be sampled
        // in the same cycle the delayed start pulse occurs.
        // Ensure enables are asserted on state entry so datapath sees `en`
        // one cycle before the delayed `start` pulse. This guarantees
        // the datapath samples `start && en` in the same cycle the
        // delayed `start` arrives.
        rms_en <= busy | r_start_req | (state == S_RMS) | r_rms_start_req;
        inproj_en <= busy | r_start_req | (state == S_INPROJ) | r_inproj_start_req;
        conv_en <= busy | r_start_req | (state == S_CONV) | r_conv_start_req;
        scan_en <= busy | r_start_req | (state == S_SCAN) | r_scan_start_req;
        outproj_en <= busy | r_start_req | (state == S_OUT) | r_outproj_start_req;
        // debug: if a delayed start request is active this cycle, print enable status
        if (r_rms_start_req) begin
            $display("CU-DBG: rms_start pulse: rms_en=%b busy=%b r_start_req=%b time=%0t", rms_en, busy, r_start_req, $time);
        end
        if (r_inproj_start_req) begin
            $display("CU-DBG: inproj_start pulse: inproj_en=%b busy=%b r_start_req=%b time=%0t", inproj_en, busy, r_start_req, $time);
        end
        if (r_conv_start_req) begin
            $display("CU-DBG: conv_start pulse: conv_en=%b busy=%b r_start_req=%b time=%0t", conv_en, busy, r_start_req, $time);
        end
        if (r_conv_start_req_d1) begin
            $display("CU-DBG: conv_valid_in delayed pulse time=%0t", $time);
        end
        // update prev_state for next-cycle edge detection
        prev_state <= state;
    end
end

endmodule
