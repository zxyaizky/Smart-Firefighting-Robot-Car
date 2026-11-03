`timescale 1ns/1ps
module tb_red_control_priority;
    reg clk=0, rst=1, switch_n=1;
    reg [3:0] updates=0, flags=0;
    reg [15:0] mm=300;
    reg range_valid=1;
    wire [2:0] cmd;
    wire cmd_valid, enabled, fire_allowed, arm_request;
    wire [15:0] pickup;
    wire [3:0] voice;
    always #5 clk=~clk;
    rescue_control #(.CLK_HZ(1000), .FRESH_MS(100),
        .DETECTION_TIMEOUT_MS(500)) dut (
        .clk(clk), .rst(rst), .switch_ni(switch_n),
        .updates_i(updates), .flags_i(flags), .green_clear_i(1'b0),
        .distance_mm_i(mm), .distance_valid_i(range_valid),
        .arm_done_i(1'b0), .arm_owns_pwm_i(1'b0),
        .arm_home_i(1'b0), .cmd_ready_i(1'b1),
        .cmd_code_o(cmd), .cmd_valid_o(cmd_valid),
        .enabled_o(enabled), .fire_allowed_o(fire_allowed),
        .arm_request_o(arm_request), .pickup_mm_o(pickup),
        .voice_flags_o(voice));
    initial begin
        repeat(3) @(negedge clk); rst=0; switch_n=0;
        repeat(25) @(negedge clk);
        if (!enabled) $fatal(1,"auto switch failed to enable");
        updates=4'b0101; flags=4'b0110; // green and red display, valid range
        @(negedge clk); updates=0;
        if (dut.green_state_reg !== 0 || voice[0] !== 1'b1)
            $fatal(1,"red display did not suppress green pickup");
        updates=4'b0100; flags=4'b0010; // green alone
        @(negedge clk); updates=0;
        repeat(2) @(negedge clk);
        if (dut.green_state_reg !== 1 || cmd !== 3'd1)
            $fatal(1,"green approach baseline failed");
        updates=4'b0110; flags=4'b0111; // red fire + red/green display
        @(negedge clk); updates=0;
        repeat(2) @(negedge clk);
        if (!fire_allowed || cmd !== 0 || dut.green_state_reg !== 0)
            $fatal(1,"red did not stop and preempt green");
        $display("PASS tb_red_control_priority"); $finish;
    end
endmodule
