// Empirical distance positioning using the nine measured 98..204 mm points.
// Prepare J1=15, J2=5 and J3=180 slowly, then move J3 alone to the
// measured/interpolated target (140..180 degrees, no offset).
// After the active PWM frame
// contains that pose, wait 2 seconds, close J5 from 0 to 180. Then command J1=75,
// J0=45, J3=175, J2=45 in that order, release J5 to zero, return home slowly,
// then wait there for a new manual/auto mode cycle before capturing another range.
// Manual selection opens the gripper slowly before returning to original home.
`resetall
`timescale 1ns / 1ps
`default_nettype none
module arm_distance_position_auto #(
    parameter integer CLK_HZ = 50000000,
    parameter integer STEP_MS = 100,
    parameter integer GRIP_WAIT_MS = 2000
) (
    input wire clk, input wire rst_n, input wire auto_mode_i,
    input wire [71:0] manual_pulse_us_i,
    input wire [71:0] active_pulse_us_i,
    input wire [15:0] distance_mm_i,
    input wire distance_valid_i, input wire distance_update_i,
    output wire [71:0] pulse_us_o, output wire owns_pwm_o,
    output wire cycle_done_o
);
    localparam [71:0] HOME = {
        12'd500,12'd1500,12'd2500,12'd500,12'd1500,12'd1500
    };
    localparam integer STEP_CYCLES = CLK_HZ / 1000 * STEP_MS;
    localparam integer TIMER_W = STEP_CYCLES <= 2 ? 1 : $clog2(STEP_CYCLES);
    localparam [TIMER_W-1:0] TIMER_LAST = STEP_CYCLES - 1;
    localparam integer WAIT_CYCLES = CLK_HZ / 1000 * GRIP_WAIT_MS;
    localparam integer WAIT_W = WAIT_CYCLES <= 2 ? 1 : $clog2(WAIT_CYCLES);
    localparam [WAIT_W-1:0] WAIT_LAST = WAIT_CYCLES - 1;
    localparam [4:0] IDLE=0, WAIT_RANGE=1, SELECT_RANGE=2, FETCH_TARGET=3,
        SET_TARGET=4, PREPARE=5, MOVE_WRIST=6, WAIT_GRIP=7, RETURN_HOME=8,
        LOCKED=9, CLOSE_GRIP=10, GRIP_READY=11, OPEN_GRIP=12,
        LIFT=13, ROTATE_BASE=14, WRIST_UP=15, RELEASE=16, DONE=17,
        POSITION_ELBOW=19, AUTO_RETURN=20;
    localparam [7:0] GRIP_MAX_DEG = 8'd180;
    reg [4:0] state;
    reg [15:0] locked_distance_mm;
    reg [7:0] target_addr;
    reg [6:0] shoulder;
    reg [5:0] elbow;
    reg [7:0] elbow_target, wrist, wrist_target, grip;
    reg [7:0] base;
    reg [TIMER_W-1:0] timer;
    reg [WAIT_W-1:0] grip_wait_timer;
    wire [7:0] mapped_angle;
    arm_distance_j3_rom u_distance_rom (
        .clk(clk), .addr_i(target_addr), .angle_o(mapped_angle)
    );
    // Exact constant bit planes replace repeated angle arithmetic.
    function [11:0] pulse_for_deg;
        input [7:0] degree;
        reg [63:0] p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11;
        begin
            case (degree[7:6])
                2'd0: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'h0000000000000000ffff0000000000000000fffffffffffc0000fffffe000003f800fff001ffe00307e0fc0fc1f81f83c71ce38e39c71c73a492db4925b6d24b3649b26d93649b265ad296b4a5ad296b3198cc6633198cc652a954aa552a954a;
                2'd1: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'h0000000000000000ffffffffffffffffffffffffc0000000ffe000003fffff80001ffe003ffc007ffc1f81f83f03f07ee31c71c638e38c7192db4925b6d24b6d49b26d93649b26d9d296b4a5ad296b4a98cc6633198cc663a954aa552a954aa5;
                2'd2: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'hfffffffffffff0000000000000000ffffc00000000000fff03fffff800000fff03ffc007ff800fff03f03e07e07c0fc0e38e39c71c738e38db4925b6d24b6da4b26d93649b26d93696b4a5ad296b4a5acc6633198cc6633154aa552a954aa552;
                2'd3: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'hffffffffffffffffffffff0000000000000000ffffffffff800000fffffe00007ff800fff001ffe07e07c0fc0f81f81f71c638e38c71c71c4925b6d24b6da4926d93649b26d93649b4a5ad296b4a5ad26633198cc6633198aa552a954aa552a9;
                default: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'd0;
            endcase
            pulse_for_deg = {p11[degree[5:0]],p10[degree[5:0]],p9[degree[5:0]],p8[degree[5:0]],p7[degree[5:0]],p6[degree[5:0]],p5[degree[5:0]],p4[degree[5:0]],p3[degree[5:0]],p2[degree[5:0]],p1[degree[5:0]],p0[degree[5:0]]};
        end
    endfunction
    function [11:0] pulse_for_base;
        input [8:0] degree;
        reg [63:0] p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11;
        begin
            case (degree[8:6])
                3'd0: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'h00000000000000000000000000000000fffffffffffffffcffffffe000000003ffc0001ffff80003803fe01ff007f8037c3c1e1f0f0787c37333999ccce666336aab5552aa9555aac07e03f80fc07f01c78e1c38f1c3871ec9b26cd9364d9b26;
                3'd1: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'h0000000000000000ffffffffffffff80000000000000007ffffffc000000007ff80003ffff00007f07fc03fe00ff007f8783c3e1e0f0f8786663331998ccc666555aaad554aaa55507f01f80fe03f01f3871e3870e3c70e1d9b26c9b364d9366;
                3'd2: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'h0000000000000000fffffffffffffffffffffffffffff000ffff800000000fff00007fffc0000fffff807fc03fe00ff0f078783c3e1e0f0fcc6667333999ccceaa5556aab5552aa93f01fc07e03f80fcc70e1c78e1c38f1cd9366c9b26cd9364;
                3'd3: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'hfffffffffffe0000000000000001ffff000000000001fffffff000000001ffff000ffff80001ffffe00ff807fc01fe001f0f0787c3c1e1f09ccce6663331998c52aa9555aaad554af80fc07f01f80fe038f1c3871e3870e3d9364d9b26c9b364;
                3'd4: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'hffffffffffffffff0000000000000000ffffffffff800000fe000000007fffff01ffff00007fffe001ff00ff807fc01fe1e0f0f8787c3c1e1998ccc666733399d554aaa5556aab5580fe03f01fc07e03871e3c70e1c78e1c9b264d9366c9b26c;
                3'd5: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'hfffffffffffffffffffffffff0000000000000000fffffffc00000000fffffff3fffe0000ffffc003fc01ff00ff803fc3c3e1e0f0f8783c3333999ccce666333aab5552aa9555aaa07e03f80fc07f01f78e1c78f1c38f1e39b26c99364d9326c;
                3'd6: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'hfffffffffffffffffffffffffffffffffffffffe0000000000000001fffffffffffc0001ffff8000f803fe01ff007f8087c3c1e1f0f07878663331998ccc666755aaad554aaa55567f01f80fe03f01fc8f1e3871e3c70e3c9326c9b264d9364c;
                3'd7: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'h0000003fffffffff0000003fffffffff0000003fffffffff0000003ffffffff8ff80003fffe00007007f803fe01ff007f8787c3c1e1f0f07c6667333999ccce6a5556aab5552aa95f01fc07e03f80fc070e3c78e1c78f1c39364c9b26c99364d;
                default: {p11,p10,p9,p8,p7,p6,p5,p4,p3,p2,p1,p0} = 768'd0;
            endcase
            pulse_for_base = {p11[degree[5:0]],p10[degree[5:0]],p9[degree[5:0]],p8[degree[5:0]],p7[degree[5:0]],p6[degree[5:0]],p5[degree[5:0]],p4[degree[5:0]],p3[degree[5:0]],p2[degree[5:0]],p1[degree[5:0]],p0[degree[5:0]]};
        end
    endfunction
    function [8:0] next_base;
        input [8:0] current_deg, target_deg;
        begin
            next_base = current_deg < target_deg ? current_deg + 1'b1 :
                        current_deg > target_deg ? current_deg - 1'b1 : current_deg;
        end
    endfunction
    function [7:0] next_degree;
        input [7:0] current_deg, target_deg;
        begin
            next_degree = current_deg < target_deg ? current_deg + 1'b1 :
                          current_deg > target_deg ? current_deg - 1'b1 : current_deg;
        end
    endfunction
    function [7:0] next_grip_close;
        input [7:0] current_deg;
        begin
            next_grip_close = current_deg < GRIP_MAX_DEG - 8'd5 ? current_deg + 8'd5 : GRIP_MAX_DEG;
        end
    endfunction
    function [7:0] next_grip_open;
        input [7:0] current_deg;
        begin
            next_grip_open = current_deg > 8'd5 ? current_deg - 8'd5 : 8'd0;
        end
    endfunction
    wire [71:0] auto_pulses = {
        pulse_for_deg(grip),12'd1500,pulse_for_deg(wrist),pulse_for_deg(elbow),
        pulse_for_deg(shoulder),pulse_for_base(base)
    };
    // Same 50 MHz clock domain as the PWM frame registers. This establishes
    // command publication, not measured mechanical arrival (no angle feedback).
    wire pose_active = active_pulse_us_i[11:0] == 12'd1500 &&
                       active_pulse_us_i[23:12] == pulse_for_deg(8'd15) &&
                       active_pulse_us_i[35:24] == pulse_for_deg(elbow_target) &&
                       active_pulse_us_i[47:36] == pulse_for_deg(wrist_target) &&
                       active_pulse_us_i[59:48] == 12'd1500 &&
                       active_pulse_us_i[71:60] == 12'd500;
    assign owns_pwm_o = state != IDLE && state != LOCKED;
    assign cycle_done_o = state == DONE;
    assign pulse_us_o = owns_pwm_o ? auto_pulses : manual_pulse_us_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; locked_distance_mm <= 0; target_addr <= 0;
            shoulder <= 90; elbow <= 0; elbow_target <= 5;
            wrist <= 180; wrist_target <= 180;
            base <= 9'd135;
            timer <= 0; grip <= 0; grip_wait_timer <= 0;
        end else begin
            case (state)
                IDLE: begin
                    shoulder <= 90; elbow <= 0; wrist <= 180; timer <= 0;
                    base <= 9'd135;
                    grip <= 0; grip_wait_timer <= 0;
                    if (auto_mode_i) begin
                        if (manual_pulse_us_i != HOME) state <= LOCKED;
                        else if (distance_valid_i) begin
                            locked_distance_mm <= distance_mm_i;
                            state <= SELECT_RANGE;
                        end else state <= WAIT_RANGE;
                    end
                end
                WAIT_RANGE: begin
                    if (!auto_mode_i) state <= IDLE;
                    else if (distance_update_i) begin
                        if (distance_valid_i) begin
                            locked_distance_mm <= distance_mm_i;
                            state <= SELECT_RANGE;
                        end else state <= LOCKED;
                    end
                end
                SELECT_RANGE: begin
                    if (!auto_mode_i) state <= IDLE;
                    else if (locked_distance_mm < 16'd98 || locked_distance_mm > 16'd204)
                        state <= LOCKED;
                    else begin
                        target_addr <= locked_distance_mm[7:0] - 8'd98;
                        state <= FETCH_TARGET;
                    end
                end
                FETCH_TARGET: state <= !auto_mode_i ? IDLE : SET_TARGET;
                SET_TARGET: begin
                    if (!auto_mode_i) state <= IDLE;
                    else begin
                        elbow_target <= 8'd5;
                        wrist_target <= mapped_angle < 8'd140 ? 8'd140 :
                                        mapped_angle > 8'd180 ? 8'd180 : mapped_angle;
                        timer <= 0;
                        state <= PREPARE;
                    end
                end
                PREPARE: begin
                    if (!auto_mode_i) begin state <= RETURN_HOME; timer <= 0; end
                    else if (shoulder == 8'd15 && elbow == elbow_target && wrist == 8'd180)
                        state <= MOVE_WRIST;
                    else if (timer == TIMER_LAST) begin
                        shoulder <= next_degree(shoulder,8'd15);
                        elbow <= next_degree(elbow,elbow_target);
                        wrist <= next_degree(wrist,8'd180);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                MOVE_WRIST: begin
                    if (!auto_mode_i) begin state <= RETURN_HOME; timer <= 0; end
                    else if (wrist == wrist_target) begin
                        state <= WAIT_GRIP; grip_wait_timer <= 0;
                    end
                    else if (timer == TIMER_LAST) begin
                        wrist <= next_degree(wrist,wrist_target);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                WAIT_GRIP: begin
                    if (!auto_mode_i) begin state <= RETURN_HOME; timer <= 0; end
                    else if (!pose_active) grip_wait_timer <= 0;
                    else if (grip_wait_timer == WAIT_LAST) begin
                        grip <= 8'd5;
                        timer <= 0;
                        state <= CLOSE_GRIP;
                    end else grip_wait_timer <= grip_wait_timer + 1'b1;
                end
                CLOSE_GRIP: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (grip == GRIP_MAX_DEG) begin state <= GRIP_READY; timer <= 0; end
                    else if (timer == TIMER_LAST) begin
                        grip <= next_grip_close(grip);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                GRIP_READY: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (active_pulse_us_i[71:60] == pulse_for_deg(GRIP_MAX_DEG)) begin
                        state <= LIFT; timer <= 0;
                    end
                end
                LIFT: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (shoulder == 8'd75 && active_pulse_us_i[23:12] == pulse_for_deg(8'd75)) begin
                        state <= ROTATE_BASE; timer <= 0;
                    end else if (timer == TIMER_LAST) begin
                        shoulder <= next_degree(shoulder,8'd75);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                POSITION_ELBOW: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (elbow == 8'd45 && active_pulse_us_i[35:24] == pulse_for_deg(8'd45)) begin
                        state <= RELEASE; timer <= 0;
                    end else if (timer == TIMER_LAST) begin
                        elbow <= next_degree(elbow,8'd45);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                ROTATE_BASE: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (base == 9'd45 && active_pulse_us_i[11:0] == pulse_for_base(9'd45)) begin
                        state <= WRIST_UP; timer <= 0;
                    end else if (timer == TIMER_LAST) begin
                        base <= next_base(base,9'd45);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                WRIST_UP: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (wrist == 8'd175 && active_pulse_us_i[47:36] == pulse_for_deg(8'd175)) begin
                        state <= POSITION_ELBOW; timer <= 0;
                    end else if (timer == TIMER_LAST) begin
                        wrist <= next_degree(wrist,8'd175);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                RELEASE: begin
                    if (!auto_mode_i) begin state <= OPEN_GRIP; timer <= 0; end
                    else if (grip == 8'd0 && active_pulse_us_i[71:60] == 12'd500) begin
                        state <= AUTO_RETURN; timer <= 0;
                    end else if (timer == TIMER_LAST) begin
                        grip <= next_grip_open(grip);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                // Successful cycles retain automatic ownership while parked.
                // A new manual/auto switch cycle starts the next pickup.
                DONE: if (!auto_mode_i) state <= IDLE;
                OPEN_GRIP: begin
                    if (grip == 8'd0) begin state <= RETURN_HOME; timer <= 0; end
                    else if (timer == TIMER_LAST) begin
                        grip <= next_grip_open(grip);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                RETURN_HOME, AUTO_RETURN: begin
                    if (base == 9'd135 && shoulder == 8'd90 && elbow == 8'd0 && wrist == 8'd180 &&
                        grip == 8'd0 && active_pulse_us_i == HOME)
                        state <= !auto_mode_i ? IDLE : state == AUTO_RETURN ? DONE : LOCKED;
                    else if (timer == TIMER_LAST) begin
                        shoulder <= next_degree(shoulder,8'd90);
                        elbow <= next_degree(elbow,8'd0);
                        wrist <= next_degree(wrist,8'd180);
                        base <= next_base(base,9'd135);
                        timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                LOCKED: if (!auto_mode_i) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`resetall
