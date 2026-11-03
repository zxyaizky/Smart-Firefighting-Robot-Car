// -----------------------------------------------------------------------------
// File   : fire_aim_controller.v
// Author : OpenAI Codex
// Date   : 2026-10-05
// -----------------------------------------------------------------------------
// Description:
//   Horizontal incremental tracking, distinct-result lock qualification and
//   fail-closed pump permission. Inputs must be coherent in this clock domain.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-05  OpenAI Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module fire_aim_controller #
(
    // B board pixel-domain clock, independently configurable for simulation.
    parameter integer CLK_FREQ_HZ = 75000000,
    // Minimum interval between physical angle commands.
    parameter integer UPDATE_INTERVAL_MS = 50,
    // Existing detector coordinate width is 160 pixels.
    parameter integer IMAGE_WIDTH = 160,
    // Inclusive centre tolerance in pixels.
    parameter integer DEAD_ZONE = 5,
    // Number of distinct, consecutive centred detection results to lock.
    parameter integer STABLE_SAMPLES = 3,
    // Maximum angle change per new result and control interval.
    parameter [7:0] ANGLE_STEP = 8'd1,
    // Mechanical travel limits and power-on centre.
    parameter [7:0] MIN_ANGLE = 8'd10,
    parameter [7:0] MAX_ANGLE = 8'd170,
    parameter [7:0] RESET_ANGLE = 8'd90,
    // Set to one when increasing pulse width turns the mechanism the other way.
    parameter REVERSE_DIRECTION = 1'b0
)
(
    input  wire       clk,
    input  wire       rst,
    input  wire       fire_sample_i,
    input  wire       fire_valid_i,
    input  wire [7:0] fire_center_x_i,
    input  wire       distance_valid_i,
    output wire [7:0] servo_angle_o,
    output wire       aim_locked_o,
    output wire       pump_enable_o,
    output wire [3:0] state_o
);

    localparam [63:0] UPDATE_CYCLES =
        (64'd1 * CLK_FREQ_HZ * UPDATE_INTERVAL_MS + 64'd999) / 64'd1000;
    localparam integer TIMER_WIDTH = (UPDATE_CYCLES > 64'd1) ? $clog2(UPDATE_CYCLES) : 1;
    localparam integer STABLE_WIDTH = (STABLE_SAMPLES > 1)
        ? $clog2(STABLE_SAMPLES + 1) : 1;
    localparam [TIMER_WIDTH-1:0] UPDATE_LAST = UPDATE_CYCLES - 64'd1;
    localparam [STABLE_WIDTH-1:0] STABLE_LIMIT = STABLE_SAMPLES;
    localparam signed [8:0] CENTRE_X = IMAGE_WIDTH / 2;
    localparam signed [8:0] POSITIVE_DEAD_ZONE = DEAD_ZONE;
    localparam signed [8:0] NEGATIVE_DEAD_ZONE = -DEAD_ZONE;
    localparam [8:0] IMAGE_LIMIT = IMAGE_WIDTH;
    localparam [7:0] CLAMPED_RESET_ANGLE = (RESET_ANGLE < MIN_ANGLE) ? MIN_ANGLE
        : ((RESET_ANGLE > MAX_ANGLE) ? MAX_ANGLE : RESET_ANGLE);
    // One-hot encoding, all states remain in the pixel clock domain.
    localparam [3:0] STATE_IDLE = 4'b0001, STATE_TRACK = 4'b0010,
        STATE_LOCK = 4'b0100, STATE_SPRAY = 4'b1000;

    reg [TIMER_WIDTH-1:0] update_timer_reg = {TIMER_WIDTH{1'b0}}, update_timer_next;
    reg [STABLE_WIDTH-1:0] stable_count_reg = {STABLE_WIDTH{1'b0}}, stable_count_next;
    reg [7:0] angle_reg = CLAMPED_RESET_ANGLE, angle_next;
    reg sample_pending_reg = 1'b0, sample_pending_next;
    reg [3:0] state_reg = STATE_IDLE, state_next;
    wire signed [8:0] error_x;
    wire coordinate_valid;
    wire in_dead_zone;
    wire control_tick;
    wire move_increasing;
    wire [8:0] increased_angle;
    wire [8:0] minimum_plus_step;

    assign error_x           = $signed({1'b0, fire_center_x_i}) - CENTRE_X;
    assign coordinate_valid = {1'b0, fire_center_x_i} < IMAGE_LIMIT;
    assign in_dead_zone     = coordinate_valid && error_x <= POSITIVE_DEAD_ZONE
        && error_x >= NEGATIVE_DEAD_ZONE;
    assign control_tick     = update_timer_reg == UPDATE_LAST;
    assign move_increasing  = (error_x > POSITIVE_DEAD_ZONE) ^ REVERSE_DIRECTION;
    assign increased_angle  = {1'b0, angle_reg} + {1'b0, ANGLE_STEP};
    assign minimum_plus_step = {1'b0, MIN_ANGLE} + {1'b0, ANGLE_STEP};
    assign servo_angle_o    = angle_reg;
    assign aim_locked_o     = !rst && fire_valid_i && in_dead_zone
        && stable_count_reg == STABLE_LIMIT;
    // The combinational interlock removes permission immediately, without
    // waiting for the 50 ms tick or a subsequent FSM state transition.
    assign pump_enable_o    = !rst && state_reg == STATE_SPRAY && aim_locked_o
        && distance_valid_i;
    assign state_o          = state_reg;

    always @* begin
        update_timer_next = update_timer_reg + {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
        stable_count_next = stable_count_reg;
        angle_next = angle_reg;
        sample_pending_next = sample_pending_reg;
        state_next = state_reg;

        if (control_tick) update_timer_next = {TIMER_WIDTH{1'b0}};

        if (fire_sample_i) begin
            sample_pending_next = fire_valid_i && coordinate_valid;
            if (fire_valid_i && in_dead_zone) begin
                if (stable_count_reg < STABLE_LIMIT) begin
                    stable_count_next = stable_count_reg
                        + {{(STABLE_WIDTH-1){1'b0}}, 1'b1};
                end
            end else begin
                stable_count_next = {STABLE_WIDTH{1'b0}};
            end
        end

        if (!fire_valid_i || !in_dead_zone) stable_count_next = {STABLE_WIDTH{1'b0}};
        if (!fire_valid_i || !coordinate_valid) sample_pending_next = 1'b0;

        // Consume at most one pending distinct detection per tick. Holding an
        // old result cannot make the servo walk repeatedly across the picture.
        if (control_tick && sample_pending_next) begin
            sample_pending_next = 1'b0;
            if (fire_valid_i && coordinate_valid && !in_dead_zone) begin
                if (move_increasing) begin
                    angle_next = (increased_angle > {1'b0, MAX_ANGLE})
                        ? MAX_ANGLE : increased_angle[7:0];
                end else begin
                    angle_next = ({1'b0, angle_reg} < minimum_plus_step)
                        ? MIN_ANGLE : angle_reg - ANGLE_STEP;
                end
            end
        end

        case (state_reg)
            STATE_IDLE: begin
                if (fire_valid_i && coordinate_valid) state_next = STATE_TRACK;
            end
            STATE_TRACK: begin
                if (fire_valid_i && in_dead_zone && stable_count_next == STABLE_LIMIT) begin
                    state_next = STATE_LOCK;
                end
            end
            STATE_LOCK: begin
                if (distance_valid_i && aim_locked_o) state_next = STATE_SPRAY;
            end
            STATE_SPRAY: begin
                if (!distance_valid_i) state_next = STATE_LOCK;
            end
            default: state_next = STATE_IDLE;
        endcase

        if (!fire_valid_i || !coordinate_valid) begin
            state_next = STATE_IDLE;
        end else if (!in_dead_zone) begin
            state_next = STATE_TRACK;
        end
    end

    always @(posedge clk) begin
        update_timer_reg <= update_timer_next;
        stable_count_reg <= stable_count_next;
        angle_reg <= angle_next;
        sample_pending_reg <= sample_pending_next;
        if (rst) begin
            update_timer_reg <= {TIMER_WIDTH{1'b0}};
            stable_count_reg <= {STABLE_WIDTH{1'b0}};
            angle_reg <= CLAMPED_RESET_ANGLE;
            sample_pending_reg <= 1'b0;
        end
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        if (rst) state_reg <= STATE_IDLE;
    end

    // Parameter validation only; no simulation tasks are synthesized.
    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || UPDATE_INTERVAL_MS < 1 || UPDATE_CYCLES < 64'd1 ||
            IMAGE_WIDTH < 1 || IMAGE_WIDTH > 256 || DEAD_ZONE < 0 || DEAD_ZONE > 127 ||
            STABLE_SAMPLES < 1 || MIN_ANGLE > MAX_ANGLE || MAX_ANGLE > 8'd180 ||
            ANGLE_STEP < 8'd1 || ANGLE_STEP > 8'd180) begin
            $display("FAIL fire_aim_controller invalid parameters");
            $finish;
        end
    end
    // synthesis translate_on

endmodule

`resetall
