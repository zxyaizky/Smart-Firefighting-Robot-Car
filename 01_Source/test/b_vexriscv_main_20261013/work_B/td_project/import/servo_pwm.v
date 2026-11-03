// -----------------------------------------------------------------------------
// File   : servo_pwm.v
// Author : Codex
// Date   : 2026-10-05
// -----------------------------------------------------------------------------
// Description:
//   Registered 180-degree servo PWM with mechanical angle limits. All pulse
//   widths are calculated at elaboration, and latched only at a frame boundary.
//   The first frame after synchronous reset uses RESET_ANGLE regardless of input.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-05  Codex  v1.0  Add configurable clock, safe clamp and atomic frames
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module servo_pwm #
(
    // Frequency of the clock actually connected to this module.
    parameter integer CLK_FREQ_HZ = 75000000,
    // Nominal 50 Hz servo frame length.
    parameter integer PWM_PERIOD_US = 20000,
    // Safe minimum angle in degrees; use zero only for unrestricted bench tests.
    parameter integer MIN_ANGLE = 10,
    // Safe maximum angle in degrees; use 180 only for unrestricted bench tests.
    parameter integer MAX_ANGLE = 170,
    // Position commanded during the first PWM frame after reset.
    parameter integer RESET_ANGLE = 90
)
(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] servo_angle_i,
    output wire       servo_pwm_o
);

    // These functions run on constants, never on a run-time angle. Using a
    // 64-bit intermediate prevents overflow of CLK_FREQ_HZ * microseconds.
    function [63:0] angle_to_cycles;
        input integer angle_degrees;
        reg [63:0] cycles;
        begin
            cycles = CLK_FREQ_HZ;
            cycles = cycles * (64'd90000 + 64'd2000 * angle_degrees);
            angle_to_cycles = (cycles + 64'd90000000) / 64'd180000000;
        end
    endfunction

    function [63:0] period_to_cycles;
        input integer period_us;
        reg [63:0] cycles;
        begin
            cycles = CLK_FREQ_HZ;
            cycles = cycles * period_us;
            period_to_cycles = (cycles + 64'd500000) / 64'd1000000;
        end
    endfunction

    function integer counter_width;
        input [63:0] maximum_count;
        reg [63:0] remainder;
        begin
            remainder = maximum_count;
            counter_width = 32'd0;
            while (remainder != 64'd0) begin
                counter_width = counter_width + 32'd1;
                remainder = remainder >> 32'd1;
            end
            if (counter_width == 32'd0) counter_width = 32'd1;
        end
    endfunction

    localparam [63:0] PERIOD_CYCLES = period_to_cycles(PWM_PERIOD_US);
    localparam integer COUNT_WIDTH = counter_width(PERIOD_CYCLES - 64'd1);
    localparam integer PULSE_WIDTH = counter_width(angle_to_cycles(180));
    localparam [COUNT_WIDTH-1:0] PERIOD_LAST = PERIOD_CYCLES - 64'd1;
    localparam [7:0] MIN_ANGLE_VALUE = MIN_ANGLE;
    localparam [7:0] MAX_ANGLE_VALUE = MAX_ANGLE;
    localparam integer CLAMPED_RESET_ANGLE = (RESET_ANGLE < MIN_ANGLE) ? MIN_ANGLE :
        ((RESET_ANGLE > MAX_ANGLE) ? MAX_ANGLE : RESET_ANGLE);
    localparam [PULSE_WIDTH-1:0] RESET_PULSE_CYCLES =
        angle_to_cycles(CLAMPED_RESET_ANGLE);

    wire [7:0] clamped_angle;
    wire [PULSE_WIDTH-1:0] pulse_cycle_table [0:180];
    wire [PULSE_WIDTH-1:0] requested_pulse_cycles;

    reg [COUNT_WIDTH-1:0] period_count_reg = {COUNT_WIDTH{1'b0}},
        period_count_next = {COUNT_WIDTH{1'b0}};
    reg [PULSE_WIDTH-1:0] pulse_cycles_reg = RESET_PULSE_CYCLES,
        pulse_cycles_next = RESET_PULSE_CYCLES;
    reg frame_started_reg = 1'b0, frame_started_next = 1'b0;
    reg servo_pwm_reg = 1'b0, servo_pwm_next = 1'b0;

    assign clamped_angle = (servo_angle_i < MIN_ANGLE_VALUE) ? MIN_ANGLE_VALUE :
        ((servo_angle_i > MAX_ANGLE_VALUE) ? MAX_ANGLE_VALUE : servo_angle_i);
    assign requested_pulse_cycles = pulse_cycle_table[clamped_angle];
    assign servo_pwm_o            = servo_pwm_reg;

    // An immutable constant table replaces a run-time multiplier/divider.
    // Each entry is round(CLK_FREQ_HZ * (500 + angle * 2000 / 180) / 1e6).
    generate
        genvar angle_index;
        for (angle_index = 0; angle_index <= 180; angle_index = angle_index + 1) begin : angles
            localparam [PULSE_WIDTH-1:0] PULSE_CYCLES = angle_to_cycles(angle_index);
            assign pulse_cycle_table[angle_index] = PULSE_CYCLES;
        end
    endgenerate

    always @* begin
        period_count_next = period_count_reg;
        pulse_cycles_next = pulse_cycles_reg;
        frame_started_next = frame_started_reg;
        servo_pwm_next = servo_pwm_reg;

        if (!frame_started_reg) begin
            period_count_next = {COUNT_WIDTH{1'b0}};
            pulse_cycles_next = RESET_PULSE_CYCLES;
            frame_started_next = 1'b1;
            servo_pwm_next = 1'b1;
        end else if (period_count_reg == PERIOD_LAST) begin
            period_count_next = {COUNT_WIDTH{1'b0}};
            pulse_cycles_next = requested_pulse_cycles;
            servo_pwm_next = 1'b1;
        end else begin
            period_count_next = period_count_reg + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
            servo_pwm_next = (period_count_next < pulse_cycles_reg);
        end
    end

    always @(posedge clk) begin
        period_count_reg <= period_count_next;
        pulse_cycles_reg <= pulse_cycles_next;
        frame_started_reg <= frame_started_next;
        servo_pwm_reg <= servo_pwm_next;

        if (rst) begin
            period_count_reg <= {COUNT_WIDTH{1'b0}};
            pulse_cycles_reg <= RESET_PULSE_CYCLES;
            frame_started_reg <= 1'b0;
            servo_pwm_reg <= 1'b0;
        end
    end

    // Parameter validation only; excluded from hardware synthesis.
    // synthesis translate_off
    initial begin
        if ((CLK_FREQ_HZ <= 0) || (PWM_PERIOD_US <= 2500) ||
            (MIN_ANGLE < 0) || (MAX_ANGLE > 180) || (MIN_ANGLE > MAX_ANGLE) ||
            (RESET_ANGLE < 0) || (RESET_ANGLE > 180) ||
            (angle_to_cycles(0) == 64'd0)) begin
            $display("FAIL servo_pwm invalid parameters (instance %m)");
            $finish;
        end
    end
    // synthesis translate_on

endmodule

`resetall
