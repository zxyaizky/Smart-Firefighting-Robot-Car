// Six servo PWM outputs share one 20 ms timebase to limit FPGA logic usage.
// Pulse widths are in microseconds, from 500 to 2500. Update at frame boundary.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module servo_pwm6 #(
    parameter integer CLK_HZ = 50000000,
    // Packed channel order is {5, 4, 3, 2, 1, 0}.
    parameter [71:0] RESET_PULSES_US = {6{12'd500}}
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [71:0] pulse_us_i, // channel 0 in bits [11:0]
    output wire [5:0]  pwm_o,
    output wire [71:0] active_pulse_us_o // frame-latched widths for command telemetry
);
    localparam integer TICKS_PER_US = CLK_HZ / 1000000;
    localparam integer DIV_W = (TICKS_PER_US <= 2) ? 1 : $clog2(TICKS_PER_US);
    localparam [DIV_W-1:0] DIV_LAST = TICKS_PER_US - 1;
    localparam [14:0] FRAME_LAST = 15'd19999;

    reg [DIV_W-1:0] us_div;
    reg [14:0] frame_us;
    reg [11:0] active_us [0:5];
    wire frame_start = (us_div == DIV_LAST) && (frame_us == FRAME_LAST);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            us_div <= {DIV_W{1'b0}};
            frame_us <= 15'd0;
        end else if (us_div == DIV_LAST) begin
            us_div <= {DIV_W{1'b0}};
            frame_us <= (frame_us == FRAME_LAST) ? 15'd0 : frame_us + 1'b1;
        end else begin
            us_div <= us_div + 1'b1;
        end
    end

    genvar channel;
    generate for (channel = 0; channel < 6; channel = channel + 1) begin: g_servo
        wire [11:0] requested_us = pulse_us_i[channel*12 +: 12];
        wire [11:0] limited_us = (requested_us < 12'd500)  ? 12'd500 :
                                 (requested_us > 12'd2500) ? 12'd2500 : requested_us;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                active_us[channel] <= RESET_PULSES_US[channel*12 +: 12];
            else if (frame_start)
                active_us[channel] <= limited_us;
        end
        assign pwm_o[channel] = rst_n && (frame_us < {3'b0, active_us[channel]});
        assign active_pulse_us_o[channel*12 +: 12] = active_us[channel];
    end endgenerate
endmodule

`resetall
