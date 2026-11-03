// -----------------------------------------------------------------------------
// File   : fire_servo_position.v
// Author : Codex
// Date   : 2026-10-06
// -----------------------------------------------------------------------------
// Description:
//   Fixed-camera X-to-angle commands with a three-result median, bounded slew
//   and a command-settling interlock. No servo position feedback is available.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-06  Codex  v1.0  Stop at a positional target instead of integrating X
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module fire_servo_position #
(
    // Clock connected by the actual B-board top.
    parameter integer CLK_FREQ_HZ = 75000000,
    // Minimum time between angle commands.
    parameter integer UPDATE_INTERVAL_MS = 100,
    // Detector image width and central pixel tolerance.
    parameter integer IMAGE_WIDTH = 160,
    parameter integer DEAD_ZONE = 5,
    // A constant power-of-two scale avoids a hardware multiplier or divider.
    // Default 2 means four pixels per degree, an initial calibration estimate.
    parameter integer PIXELS_PER_DEGREE_SHIFT = 2,
    // Software settling time after the final angle command, without an encoder.
    parameter integer SETTLE_MS = 200,
    // Maximum change per update, travel limits and centre calibration.
    parameter [7:0] ANGLE_STEP = 8'd1,
    parameter [7:0] MIN_ANGLE = 8'd10,
    parameter [7:0] MAX_ANGLE = 8'd170,
    parameter [7:0] RESET_ANGLE = 8'd90,
    // Reverse the pixel-to-angle direction without changing wiring or code.
    parameter REVERSE_DIRECTION = 1'b0
)
(
    input  wire       clk,
    input  wire       rst,
    input  wire       fire_sample_i,
    input  wire       fire_valid_i,
    input  wire [7:0] fire_center_x_i,
    output wire [7:0] servo_angle_o,
    output wire [7:0] target_angle_o,
    output wire       position_ready_o
);
    localparam [63:0] UPDATE_CYCLES =
        (64'd1 * CLK_FREQ_HZ * UPDATE_INTERVAL_MS + 64'd999) / 64'd1000;
    localparam [63:0] SETTLE_CYCLES =
        (64'd1 * CLK_FREQ_HZ * SETTLE_MS + 64'd999) / 64'd1000;
    localparam integer TIMER_WIDTH = UPDATE_CYCLES > 1 ? $clog2(UPDATE_CYCLES) : 1;
    localparam integer SETTLE_WIDTH = SETTLE_CYCLES > 0 ? $clog2(SETTLE_CYCLES + 1) : 1;
    localparam [TIMER_WIDTH-1:0] UPDATE_LAST = UPDATE_CYCLES - 64'd1;
    localparam [SETTLE_WIDTH-1:0] SETTLE_LAST = SETTLE_CYCLES;
    localparam [8:0] IMAGE_LIMIT = IMAGE_WIDTH;
    localparam signed [8:0] CENTRE_X = IMAGE_WIDTH / 2;
    localparam [8:0] DEAD_ZONE_VALUE = DEAD_ZONE;
    localparam [8:0] SCALE_ROUND = PIXELS_PER_DEGREE_SHIFT > 0 ?
        (9'd1 << (PIXELS_PER_DEGREE_SHIFT - 1)) : 9'd0;
    localparam [7:0] CENTRE_ANGLE = RESET_ANGLE < MIN_ANGLE ? MIN_ANGLE :
        (RESET_ANGLE > MAX_ANGLE ? MAX_ANGLE : RESET_ANGLE);
    localparam [8:0] DECREASE_LIMIT = {1'b0, CENTRE_ANGLE} - {1'b0, MIN_ANGLE};

    reg [TIMER_WIDTH-1:0] timer_reg = {TIMER_WIDTH{1'b0}}, timer_next;
    reg [SETTLE_WIDTH-1:0] settle_reg = SETTLE_LAST, settle_next;
    reg [7:0] angle_reg = CENTRE_ANGLE, angle_next;
    reg [7:0] target_reg = CENTRE_ANGLE, target_next;
    reg target_valid_reg = 1'b0, target_valid_next;
    reg history_valid_reg = 1'b0, history_valid_next;
    reg [7:0] previous_x_reg = 8'd0, previous_x_next;
    reg [7:0] older_x_reg = 8'd0, older_x_next;
    reg [7:0] requested_target = CENTRE_ANGLE;
    wire coordinate_valid;
    wire control_tick;
    wire [7:0] filtered_x;
    wire signed [8:0] error_x;
    wire [8:0] absolute_error;
    wire [8:0] angular_offset;
    wire increase_target;
    wire [8:0] positive_target;
    wire [8:0] increase_angle;
    wire [8:0] angle_above_target;
    wire [8:0] target_above_angle;

    function [7:0] median_of_three;
        input [7:0] a, b, c;
        begin
            if (a <= b) begin
                if (b <= c) median_of_three = b;
                else if (a <= c) median_of_three = c;
                else median_of_three = a;
            end else begin
                if (a <= c) median_of_three = a;
                else if (b <= c) median_of_three = c;
                else median_of_three = b;
            end
        end
    endfunction

    assign coordinate_valid = {1'b0, fire_center_x_i} < IMAGE_LIMIT;
    assign control_tick = timer_reg == UPDATE_LAST;
    assign filtered_x = history_valid_reg ?
        median_of_three(fire_center_x_i, previous_x_reg, older_x_reg) : fire_center_x_i;
    assign error_x = $signed({1'b0, filtered_x}) - CENTRE_X;
    assign absolute_error = error_x[8] ? -error_x : error_x;
    assign angular_offset = (absolute_error + SCALE_ROUND) >> PIXELS_PER_DEGREE_SHIFT;
    assign increase_target = (!error_x[8]) ^ REVERSE_DIRECTION;
    assign positive_target = {1'b0, CENTRE_ANGLE} + angular_offset;
    assign increase_angle = {1'b0, angle_reg} + {1'b0, ANGLE_STEP};
    assign angle_above_target = {1'b0, angle_reg} - {1'b0, target_next};
    assign target_above_angle = {1'b0, target_next} - {1'b0, angle_reg};
    assign servo_angle_o = angle_reg;
    assign target_angle_o = target_reg;
    // This is a settled COMMAND, not confirmation from a physical encoder.
    assign position_ready_o = !rst && fire_valid_i && coordinate_valid &&
        target_valid_reg && angle_reg == target_reg && settle_reg == 0 &&
        (!fire_sample_i || requested_target == target_reg);

    always @* begin
        requested_target = CENTRE_ANGLE;
        if (absolute_error > DEAD_ZONE_VALUE) begin
            if (increase_target) begin
                requested_target = positive_target > {1'b0, MAX_ANGLE} ?
                    MAX_ANGLE : positive_target[7:0];
            end else begin
                requested_target = angular_offset > DECREASE_LIMIT ? MIN_ANGLE :
                    CENTRE_ANGLE - angular_offset[7:0];
            end
        end
    end

    always @* begin
        timer_next = timer_reg + {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
        settle_next = settle_reg;
        angle_next = angle_reg;
        target_next = target_reg;
        target_valid_next = target_valid_reg;
        history_valid_next = history_valid_reg;
        previous_x_next = previous_x_reg;
        older_x_next = older_x_reg;
        if (control_tick) timer_next = {TIMER_WIDTH{1'b0}};

        if (fire_sample_i && fire_valid_i && coordinate_valid) begin
            target_next = requested_target;
            target_valid_next = 1'b1;
            history_valid_next = 1'b1;
            previous_x_next = fire_center_x_i;
            older_x_next = history_valid_reg ? previous_x_reg : fire_center_x_i;
        end
        if (!fire_valid_i || !coordinate_valid) begin
            target_valid_next = 1'b0;
            history_valid_next = 1'b0;
        end

        // An accepted target may take many steps, but it can never drive beyond
        // that target. Repeated identical detections do not accumulate an angle.
        if (control_tick && target_valid_next) begin
            if (angle_reg < target_next) begin
                angle_next = target_above_angle <= {1'b0, ANGLE_STEP} ?
                    target_next : increase_angle[7:0];
            end else if (angle_reg > target_next) begin
                angle_next = angle_above_target <= {1'b0, ANGLE_STEP} ?
                    target_next : angle_reg - ANGLE_STEP;
            end
        end

        if (!target_valid_reg || !target_valid_next || angle_next != angle_reg || target_next != target_reg ||
            angle_next != target_next) begin
            settle_next = SETTLE_LAST;
        end else if (settle_reg != 0) begin
            settle_next = settle_reg - {{(SETTLE_WIDTH-1){1'b0}}, 1'b1};
        end
    end

    always @(posedge clk) begin
        timer_reg <= timer_next;
        settle_reg <= settle_next;
        angle_reg <= angle_next;
        target_reg <= target_next;
        target_valid_reg <= target_valid_next;
        history_valid_reg <= history_valid_next;
        previous_x_reg <= previous_x_next;
        older_x_reg <= older_x_next;
        if (rst) begin
            timer_reg <= {TIMER_WIDTH{1'b0}};
            settle_reg <= SETTLE_LAST;
            angle_reg <= CENTRE_ANGLE;
            target_reg <= CENTRE_ANGLE;
            target_valid_reg <= 1'b0;
            history_valid_reg <= 1'b0;
            previous_x_reg <= 8'd0;
            older_x_reg <= 8'd0;
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || UPDATE_INTERVAL_MS < 1 || SETTLE_MS < 0 ||
            IMAGE_WIDTH < 1 || IMAGE_WIDTH > 256 || DEAD_ZONE < 0 || DEAD_ZONE > 127 ||
            PIXELS_PER_DEGREE_SHIFT < 0 || PIXELS_PER_DEGREE_SHIFT > 7 ||
            MIN_ANGLE > MAX_ANGLE || MAX_ANGLE > 180 || RESET_ANGLE > 180 ||
            ANGLE_STEP < 1 || ANGLE_STEP > 180) begin
            $error("Invalid fire_servo_position parameters");
            $finish;
        end
    end
    // synthesis translate_on
endmodule

`resetall
