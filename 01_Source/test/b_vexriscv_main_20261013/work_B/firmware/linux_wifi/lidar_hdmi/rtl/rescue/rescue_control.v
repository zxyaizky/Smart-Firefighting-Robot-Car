// File: rescue_control.v
// Author: Codex
// Date: 2026-10-27
// Description: Fresh sensor results arbitrate stop, fire and one-shot pickup.
// Change Log: 2026-10-27 v1.0 B-board rescue integration.
// Change Log: 2026-10-29 v1.1 Green-first positioning and timed pickup departure.
// Change Log: 2026-10-29 v1.2 3150 ms turns and 5000 ms green departure.
// Change Log: 2026-10-29 v1.3 Retreat to 550 mm, then five continuous seconds forward.
// Change Log: 2026-11-01 Fire requires a currently valid <=450 mm range.
// Change Log: 2026-11-01 Red fire preempts green approach and stops the car.
// Change Log: 2026-10-30 Yellow fire, person <=350 mm, no detour or ordinary avoidance.
`resetall
`timescale 1ns / 1ps
`default_nettype none
module rescue_control #
(
    // System clock; the imported car controller uses the same clock.
    parameter integer CLK_HZ = 50000000,
    // Detection and ultrasonic results expire independently.
    parameter integer FRESH_MS = 600,
    parameter integer DETECTION_TIMEOUT_MS = 5000
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        switch_ni,
    // updates: {person, green/red display, strict red fire, ultrasonic}.
    input  wire [3:0]  updates_i,
    // flags: {person, red display, green, strict red fire}.
    input  wire [3:0]  flags_i,
    // Only a completed, non-faulting absent result can rearm pickup.
    input  wire        green_clear_i,
    input  wire [15:0] distance_mm_i,
    input  wire        distance_valid_i,
    input  wire        arm_done_i,
    input  wire        arm_owns_pwm_i,
    input  wire        arm_home_i,
    input  wire        cmd_ready_i,
    output wire [2:0]  cmd_code_o,
    output wire        cmd_valid_o,
    output wire        enabled_o,
    output wire        fire_allowed_o,
    output wire        arm_request_o,
    output wire [15:0] pickup_mm_o,
    output wire [3:0]  voice_flags_o
);
    localparam integer MS_CYCLES = CLK_HZ / 1000;
    localparam integer MS_W = MS_CYCLES < 2 ? 1 : $clog2(MS_CYCLES);
    localparam integer AGE_W = $clog2(DETECTION_TIMEOUT_MS + 1);
    localparam [MS_W-1:0] MS_LAST = MS_CYCLES - 1;
    localparam [AGE_W-1:0] AGE_LIMIT = FRESH_MS;
    localparam [AGE_W-1:0] DETECTION_LIMIT = DETECTION_TIMEOUT_MS;
    localparam [2:0] GREEN_IDLE = 3'd0, GREEN_APPROACH = 3'd1,
        GREEN_PICKUP = 3'd2, GREEN_RELEASE_WAIT = 3'd3, GREEN_REVERSE = 3'd4,
        GREEN_RIGHT = 3'd5, GREEN_FORWARD = 3'd6, GREEN_LEFT = 3'd7;
    localparam [12:0] GREEN_TURN_LAST_MS = 13'd3149;
    localparam [12:0] GREEN_FORWARD_LAST_MS = 13'd4999;
    reg [MS_W-1:0] ms_reg = {MS_W{1'b0}}, ms_next;
    reg [AGE_W-1:0] range_age_reg = AGE_LIMIT, range_age_next;
    reg [AGE_W-1:0] fire_age_reg = DETECTION_LIMIT, fire_age_next;
    reg [AGE_W-1:0] color_age_reg = DETECTION_LIMIT, color_age_next;
    reg [AGE_W-1:0] person_age_reg = DETECTION_LIMIT, person_age_next;
    reg [3:0] flags_reg = 4'd0, flags_next;
    reg [15:0] distance_reg = 16'd0, distance_next;
    reg distance_valid_reg = 1'b0, distance_valid_next;
    reg arm_request_reg = 1'b0, arm_request_next;
    reg green_armed_reg = 1'b1, green_armed_next;
    reg [15:0] pickup_reg = 16'd0, pickup_next;
    reg [2:0] green_state_reg = GREEN_IDLE, green_state_next;
    reg [12:0] green_time_reg = 13'd0, green_time_next;
    reg [2:0] green_cmd;
    reg [2:0] cmd_reg = 3'd0;
    reg cmd_valid_reg = 1'b1;
    wire ms_tick = ms_reg == MS_LAST;
    // Consume a newly delivered packet before making this cycle's decision.
    // Otherwise a new person/invalid range could lose to the previous green result.
    wire [15:0] current_mm = updates_i[0] ? distance_mm_i : distance_reg;
    wire range_fresh = updates_i[0] ? distance_valid_i :
        distance_valid_reg && range_age_reg < AGE_LIMIT;
    wire fire_target = updates_i[1] ? flags_i[0] : flags_reg[0] && fire_age_reg < DETECTION_LIMIT;
    wire green = updates_i[2] ? flags_i[1] : flags_reg[1] && color_age_reg < AGE_LIMIT;
    wire red = updates_i[2] ? flags_i[2] : flags_reg[2] && color_age_reg < DETECTION_LIMIT;
    wire person = updates_i[3] ? flags_i[3] : flags_reg[3] && person_age_reg < DETECTION_LIMIT;
    wire person_close = person && range_fresh && current_mm <= 16'd350;
    // A new invalid reading or an expired reading removes fire permission.
    wire red_fire_close = fire_target && range_fresh && current_mm <= 16'd450;
    wire enabled;
    wire arm_busy = arm_request_reg || arm_owns_pwm_i;
    wire green_start = enabled && green && !red && !red_fire_close &&
        green_armed_reg && !arm_busy &&
        green_state_reg == GREEN_IDLE;
    wire green_active = green_state_reg != GREEN_IDLE || green_start;
    wire stop_hold = person_close || red_fire_close || arm_busy || green_active;
    wire [2:0] normal_cmd;
    wire [2:0] desired_cmd = !enabled || red_fire_close ? 3'd0 :
                             green_active ? green_cmd : normal_cmd;
    // A running pickup keeps the car stopped even if ranging becomes invalid.
    // No location association is implied by a camera flag plus front range.
    assign fire_allowed_o = enabled && red_fire_close;
    assign cmd_code_o = cmd_reg;
    assign cmd_valid_o = cmd_valid_reg;
    assign arm_request_o = arm_request_reg;
    assign pickup_mm_o = pickup_reg;
    assign enabled_o = enabled;
    assign voice_flags_o = {person, 1'b0, green, red};

    car_auto_motion #(.CLK_HZ(CLK_HZ)) u_car_auto (
        .clk(clk), .rst_n(!rst), .switch_n_i(switch_ni), .hold_i(stop_hold),
        .cmd_ready_i(1'b1), .cmd_code_o(normal_cmd), .cmd_valid_o(), .enabled_o(enabled)
    );

    always @* begin
        ms_next = ms_reg + 1'b1;
        range_age_next = range_age_reg;
        fire_age_next = fire_age_reg;
        color_age_next = color_age_reg;
        person_age_next = person_age_reg;
        flags_next = flags_reg;
        distance_next = distance_reg;
        distance_valid_next = distance_valid_reg;
        arm_request_next = arm_request_reg;
        green_armed_next = green_armed_reg;
        pickup_next = pickup_reg;
        green_state_next = green_state_reg;
        green_time_next = green_time_reg;
        green_cmd = 3'd0;
        if (ms_tick) begin
            ms_next = {MS_W{1'b0}};
            if (range_age_reg < AGE_LIMIT) range_age_next = range_age_reg + 1'b1;
            if (fire_age_reg < DETECTION_LIMIT) fire_age_next = fire_age_reg + 1'b1;
            if (color_age_reg < DETECTION_LIMIT) color_age_next = color_age_reg + 1'b1;
            if (person_age_reg < DETECTION_LIMIT) person_age_next = person_age_reg + 1'b1;
        end
        if (updates_i[0]) begin
            distance_next = distance_mm_i;
            distance_valid_next = distance_valid_i;
            range_age_next = {AGE_W{1'b0}};
        end
        if (updates_i[1]) begin
            flags_next[0] = flags_i[0];
            fire_age_next = {AGE_W{1'b0}};
        end
        if (updates_i[2]) begin
            flags_next[2:1] = flags_i[2:1];
            color_age_next = {AGE_W{1'b0}};
        end
        if (updates_i[3]) begin
            flags_next[3] = flags_i[3];
            person_age_next = {AGE_W{1'b0}};
        end
        // A missing/stale frame is not proof that the collected target disappeared.
        if (green_state_reg == GREEN_IDLE && updates_i[2] && !flags_i[1] && green_clear_i)
            green_armed_next = 1'b1;
        if (green_start) begin
            green_state_next = GREEN_APPROACH;
            green_time_next = 13'd0;
        end
        case (green_state_reg)
            GREEN_IDLE: green_time_next = 13'd0;
            GREEN_APPROACH: begin
                if (!green) green_state_next = GREEN_IDLE;
                else if (range_fresh) begin
                    if (current_mm >= 16'd200) green_cmd = 3'd1;
                    else if (current_mm < 16'd98) green_cmd = 3'd2;
                    else if (!arm_busy && arm_home_i) begin
                        pickup_next = current_mm;
                        arm_request_next = 1'b1;
                        green_armed_next = 1'b0;
                        green_state_next = GREEN_PICKUP;
                    end
                end
            end
            GREEN_PICKUP: begin
                if (arm_done_i) begin
                    arm_request_next = 1'b0;
                    green_state_next = GREEN_RELEASE_WAIT;
                end
            end
            GREEN_RELEASE_WAIT: begin
                if (!arm_busy) green_state_next = GREEN_REVERSE;
            end
            GREEN_REVERSE: begin
                if (range_fresh) begin
                    if (current_mm >= 16'd550) begin
                        green_state_next = GREEN_RIGHT;
                        green_time_next = 13'd0;
                    end else green_cmd = 3'd2;
                end
            end
            GREEN_RIGHT, GREEN_LEFT: begin
                green_cmd = green_state_reg == GREEN_RIGHT ? 3'd4 : 3'd3;
                if (ms_tick) begin
                    if (green_time_reg == GREEN_TURN_LAST_MS) begin
                        green_time_next = 13'd0;
                        green_state_next = green_state_reg == GREEN_RIGHT ? GREEN_FORWARD : GREEN_IDLE;
                    end else green_time_next = green_time_reg + 1'b1;
                end
            end
            GREEN_FORWARD: begin
                // Timed departure ignores range; E11 still cancels the whole route.
                green_cmd = 3'd1;
                if (ms_tick) begin
                    if (green_time_reg == GREEN_FORWARD_LAST_MS) begin
                        green_time_next = 13'd0;
                        green_state_next = GREEN_LEFT;
                    end else green_time_next = green_time_reg + 1'b1;
                end
            end
            default: begin
                green_state_next = GREEN_IDLE;
                green_time_next = 13'd0;
                arm_request_next = 1'b0;
            end
        endcase
        if (red_fire_close && !arm_busy) begin
            green_state_next = GREEN_IDLE;
            green_time_next = 13'd0;
            arm_request_next = 1'b0;
        end
        if (!enabled) begin
            green_state_next = GREEN_IDLE;
            green_time_next = 13'd0;
            arm_request_next = 1'b0;
        end
    end

    always @(posedge clk) begin
        ms_reg <= ms_next;
        range_age_reg <= range_age_next;
        fire_age_reg <= fire_age_next;
        color_age_reg <= color_age_next;
        person_age_reg <= person_age_next;
        flags_reg <= flags_next;
        distance_reg <= distance_next;
        distance_valid_reg <= distance_valid_next;
        arm_request_reg <= arm_request_next;
        green_armed_reg <= green_armed_next;
        pickup_reg <= pickup_next;
        green_state_reg <= green_state_next;
        green_time_reg <= green_time_next;
        if (cmd_reg != desired_cmd) begin
            cmd_reg <= desired_cmd;
            cmd_valid_reg <= 1'b1;
        end else if (cmd_valid_reg && cmd_ready_i) cmd_valid_reg <= 1'b0;
        if (rst) begin
            ms_reg <= {MS_W{1'b0}};
            range_age_reg <= AGE_LIMIT;
            fire_age_reg <= DETECTION_LIMIT;
            color_age_reg <= DETECTION_LIMIT;
            person_age_reg <= DETECTION_LIMIT;
            flags_reg <= 4'd0;
            distance_reg <= 16'd0;
            distance_valid_reg <= 1'b0;
            arm_request_reg <= 1'b0;
            green_armed_reg <= 1'b1;
            pickup_reg <= 16'd0;
            green_state_reg <= GREEN_IDLE;
            green_time_reg <= 13'd0;
            cmd_reg <= 3'd0;
            cmd_valid_reg <= 1'b1;
        end
    end
endmodule
`resetall
