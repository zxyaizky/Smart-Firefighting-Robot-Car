// -----------------------------------------------------------------------------
// File   : servo_test_controller.v
// Author : Codex
// Date   : 2026-10-06
// -----------------------------------------------------------------------------
// Description:
//   Independent servo diagnostic angle sequence. Hold 90 degrees for one dwell
//   after reset, then repeat 60, 90, 120, 90 degrees. No detector input is needed.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-06  Codex  v1.0  Add deterministic synchronous angle diagnostic
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module servo_test_controller #
(
    // Frequency of the actual clock connected to this diagnostic branch.
    parameter integer CLK_FREQ_HZ = 50000000,
    // Duration of each position in milliseconds; two seconds at the default.
    parameter integer DWELL_MS = 2000
)
(
    input  wire       clk,
    input  wire       rst,
    output wire [7:0] servo_angle_o
);

    // Calculate on 64-bit constants so neither the product nor count overflows.
    // Round upwards: each position is held for at least DWELL_MS milliseconds.
    localparam [63:0] DWELL_CYCLES =
        (64'd1 * CLK_FREQ_HZ * DWELL_MS + 64'd999) / 64'd1000;
    localparam integer TIMER_WIDTH = (DWELL_CYCLES > 64'd1) ? $clog2(DWELL_CYCLES) : 1;
    localparam [TIMER_WIDTH-1:0] DWELL_LAST = DWELL_CYCLES - 64'd1;
    localparam [7:0] ANGLE_LEFT = 8'd60;
    localparam [7:0] ANGLE_CENTER = 8'd90;
    localparam [7:0] ANGLE_RIGHT = 8'd120;

    // One-hot encoding for this FPGA-local four-position sequence. Reset starts
    // at the last centre position so the first transition goes to 60 degrees.
    localparam [3:0] STATE_LEFT = 4'b0001;
    localparam [3:0] STATE_CENTER_AFTER_LEFT = 4'b0010;
    localparam [3:0] STATE_RIGHT = 4'b0100;
    localparam [3:0] STATE_CENTER_AFTER_RIGHT = 4'b1000;

    reg [TIMER_WIDTH-1:0] dwell_count_reg = {TIMER_WIDTH{1'b0}},
        dwell_count_next = {TIMER_WIDTH{1'b0}};
    reg [3:0] state_reg = STATE_CENTER_AFTER_RIGHT, state_next = STATE_CENTER_AFTER_RIGHT;
    reg [7:0] angle_reg = ANGLE_CENTER, angle_next = ANGLE_CENTER;

    assign servo_angle_o = angle_reg;

    always @* begin
        dwell_count_next = dwell_count_reg + {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
        state_next = state_reg;
        angle_next = angle_reg;

        if (dwell_count_reg == DWELL_LAST) begin
            dwell_count_next = {TIMER_WIDTH{1'b0}};
            case (state_reg)
                STATE_LEFT: begin
                    state_next = STATE_CENTER_AFTER_LEFT;
                    angle_next = ANGLE_CENTER;
                end
                STATE_CENTER_AFTER_LEFT: begin
                    state_next = STATE_RIGHT;
                    angle_next = ANGLE_RIGHT;
                end
                STATE_RIGHT: begin
                    state_next = STATE_CENTER_AFTER_RIGHT;
                    angle_next = ANGLE_CENTER;
                end
                STATE_CENTER_AFTER_RIGHT: begin
                    state_next = STATE_LEFT;
                    angle_next = ANGLE_LEFT;
                end
                default: begin
                    state_next = STATE_CENTER_AFTER_RIGHT;
                    angle_next = ANGLE_CENTER;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        dwell_count_reg <= dwell_count_next;
        state_reg <= state_next;
        angle_reg <= angle_next;

        if (rst) begin
            dwell_count_reg <= {TIMER_WIDTH{1'b0}};
            state_reg <= STATE_CENTER_AFTER_RIGHT;
            angle_reg <= ANGLE_CENTER;
        end
    end

    // Parameter validation only; no simulation tasks enter synthesized logic.
    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 32'd1 || DWELL_MS < 32'd1 || DWELL_CYCLES < 64'd1) begin
            $display("FAIL servo_test_controller invalid parameters (instance %m)");
            $finish;
        end
    end
    // synthesis translate_on

endmodule

`resetall
