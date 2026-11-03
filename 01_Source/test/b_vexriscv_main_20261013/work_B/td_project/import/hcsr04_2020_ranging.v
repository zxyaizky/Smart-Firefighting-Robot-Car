// -----------------------------------------------------------------------------
// File   : hcsr04_2020_ranging.v
// Author : Codex
// Date   : 2026-10-11
// -----------------------------------------------------------------------------
// Description:
//   HC-SR04 2020 default GPIO mode: a 20 us trigger and synchronized Echo
//   pulse measurement. Rounded millimetres, timeout and range validation.
//   Constant cycles-per-mm conversion uses counters, no runtime divider.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-11  Codex  v1.0  GPIO replacement for the retained US-100 UART
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module hcsr04_2020_ranging #
(
    // Actual B-board HDMI pixel clock frequency.
    parameter integer CLK_FREQ_HZ = 75000000,
    // 2020 datasheet requires at least 200 ms between measurements.
    parameter integer POLL_INTERVAL_MS = 200,
    // Bounds the entire Echo wait and high pulse after Trig goes low.
    parameter integer RESPONSE_TIMEOUT_MS = 100,
    // Datasheet requires a pulse greater than 10 us.
    parameter integer TRIGGER_US = 20,
    // Datasheet sound speed at 20 degrees C, in millimetres per second.
    parameter integer SOUND_SPEED_MM_PER_S = 342620,
    // Values outside the specified usable range become invalid, not clamped.
    parameter [15:0] MIN_DISTANCE_MM = 16'd20,
    parameter [15:0] MAX_DISTANCE_MM = 16'd4500
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        echo_i,
    output wire        trig_o,
    output wire [15:0] distance_mm_o,
    output wire        distance_valid_o,
    output wire        result_update_o
);
    localparam [63:0] POLL_CYCLES =
        (64'd1 * CLK_FREQ_HZ * POLL_INTERVAL_MS + 64'd999) / 64'd1000;
    localparam [63:0] TIMEOUT_CYCLES =
        (64'd1 * CLK_FREQ_HZ * RESPONSE_TIMEOUT_MS + 64'd999) / 64'd1000;
    localparam [63:0] TRIGGER_CYCLES =
        (64'd1 * CLK_FREQ_HZ * TRIGGER_US + 64'd999999) / 64'd1000000;
    // Echo is a round trip: cycles/mm = clock_hz * 2 / sound_speed_mm_per_s.
    localparam [63:0] CYCLES_PER_MM =
        (64'd2 * CLK_FREQ_HZ + SOUND_SPEED_MM_PER_S / 2) / SOUND_SPEED_MM_PER_S;
    localparam integer POLL_WIDTH = POLL_CYCLES > 1 ? $clog2(POLL_CYCLES) : 1;
    localparam integer TIMEOUT_WIDTH = TIMEOUT_CYCLES > 1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam integer TRIGGER_WIDTH = TRIGGER_CYCLES > 1 ? $clog2(TRIGGER_CYCLES) : 1;
    localparam integer FRACTION_WIDTH = CYCLES_PER_MM > 1 ? $clog2(CYCLES_PER_MM) : 1;
    localparam [POLL_WIDTH-1:0] POLL_LAST = POLL_CYCLES - 64'd1;
    localparam [TIMEOUT_WIDTH-1:0] TIMEOUT_LAST = TIMEOUT_CYCLES - 64'd1;
    localparam [TRIGGER_WIDTH-1:0] TRIGGER_LAST = TRIGGER_CYCLES - 64'd1;
    localparam [FRACTION_WIDTH-1:0] FRACTION_LAST = CYCLES_PER_MM - 64'd1;
    localparam [FRACTION_WIDTH-1:0] ROUND_HALF = CYCLES_PER_MM / 64'd2;
    localparam [FRACTION_WIDTH-1:0] FIRST_FRACTION = ROUND_HALF + 1'b1;
    // One-hot FPGA FSM. All data and display outputs stay in the pixel domain.
    localparam [4:0] STATE_POLL = 5'b00001, STATE_TRIGGER = 5'b00010,
        STATE_WAIT_ECHO = 5'b00100, STATE_MEASURE = 5'b01000, STATE_QUIET = 5'b10000;

    reg [4:0] state_reg = STATE_POLL, state_next;
    reg [POLL_WIDTH-1:0] poll_reg = {POLL_WIDTH{1'b0}}, poll_next;
    reg [TIMEOUT_WIDTH-1:0] timeout_reg = {TIMEOUT_WIDTH{1'b0}}, timeout_next;
    reg [TRIGGER_WIDTH-1:0] trigger_reg = {TRIGGER_WIDTH{1'b0}}, trigger_next;
    reg [FRACTION_WIDTH-1:0] fraction_reg = {FRACTION_WIDTH{1'b0}}, fraction_next;
    reg [15:0] millimetres_reg = 16'd0, millimetres_next;
    reg [15:0] distance_reg = 16'd0, distance_next;
    reg trig_reg = 1'b0, trig_next;
    reg distance_valid_reg = 1'b0, distance_valid_next;
    reg result_update_reg = 1'b0, result_update_next;
    // CDC: asynchronous sensor Echo -> 75 MHz pixel clock, two-flop synchronizer.
    (* ASYNC_REG = "TRUE" *) reg [1:0] echo_sync_reg = 2'b00;
    reg previous_echo_reg = 1'b0;
    wire echo_rising;

    assign echo_rising       = echo_sync_reg[1] && !previous_echo_reg;
    assign trig_o            = trig_reg && !rst;
    assign distance_mm_o     = distance_reg;
    assign distance_valid_o  = distance_valid_reg && !rst;
    assign result_update_o   = result_update_reg && !rst;

    always @* begin
        state_next = state_reg;
        poll_next = poll_reg;
        timeout_next = timeout_reg;
        trigger_next = trigger_reg;
        fraction_next = fraction_reg;
        millimetres_next = millimetres_reg;
        distance_next = distance_reg;
        trig_next = trig_reg;
        distance_valid_next = distance_valid_reg;
        result_update_next = 1'b0;
        if (poll_reg != POLL_LAST) poll_next = poll_reg + 1'b1;
        case (state_reg)
            STATE_POLL: begin
                if (poll_reg == POLL_LAST) begin
                    poll_next = {POLL_WIDTH{1'b0}};
                    if (!echo_sync_reg[1]) begin
                        trig_next = 1'b1;
                        trigger_next = TRIGGER_LAST;
                        state_next = STATE_TRIGGER;
                    end else begin
                        // A stuck/pre-existing Echo is not a fresh measurement.
                        distance_next = 16'd0;
                        distance_valid_next = 1'b0;
                        result_update_next = 1'b1;
                    end
                end
            end
            STATE_TRIGGER: begin
                if (trigger_reg == 0) begin
                    trig_next = 1'b0;
                    timeout_next = {TIMEOUT_WIDTH{1'b0}};
                    state_next = STATE_WAIT_ECHO;
                end else trigger_next = trigger_reg - 1'b1;
            end
            STATE_WAIT_ECHO: begin
                timeout_next = timeout_reg + 1'b1;
                if (echo_rising) begin
                    // Count the first high sample, with half-mm rounding bias.
                    fraction_next = FIRST_FRACTION;
                    millimetres_next = 16'd0;
                    state_next = STATE_MEASURE;
                end
                if (timeout_reg == TIMEOUT_LAST) begin
                    distance_next = 16'd0;
                    distance_valid_next = 1'b0;
                    result_update_next = 1'b1;
                    state_next = STATE_QUIET;
                end
            end
            STATE_MEASURE: begin
                timeout_next = timeout_reg + 1'b1;
                if (echo_sync_reg[1]) begin
                    if (fraction_reg == FRACTION_LAST) begin
                        fraction_next = {FRACTION_WIDTH{1'b0}};
                        millimetres_next = millimetres_reg + 16'd1;
                    end else fraction_next = fraction_reg + 1'b1;
                end else begin
                    // Publish only after a complete high pulse, never a partial count.
                    distance_valid_next = millimetres_reg >= MIN_DISTANCE_MM &&
                        millimetres_reg <= MAX_DISTANCE_MM;
                    distance_next = distance_valid_next ? millimetres_reg : 16'd0;
                    result_update_next = 1'b1;
                    state_next = STATE_QUIET;
                end
                if (timeout_reg == TIMEOUT_LAST || millimetres_reg == 16'hffff) begin
                    distance_next = 16'd0;
                    distance_valid_next = 1'b0;
                    result_update_next = 1'b1;
                    state_next = STATE_QUIET;
                end
            end
            STATE_QUIET: begin
                // Late/unsolicited pulses cannot publish a new distance.
                if (poll_reg == POLL_LAST) state_next = STATE_POLL;
            end
            default: begin
                state_next = STATE_POLL;
                trig_next = 1'b0;
                distance_next = 16'd0;
                distance_valid_next = 1'b0;
            end
        endcase
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        poll_reg <= poll_next;
        timeout_reg <= timeout_next;
        trigger_reg <= trigger_next;
        fraction_reg <= fraction_next;
        millimetres_reg <= millimetres_next;
        distance_reg <= distance_next;
        trig_reg <= trig_next;
        distance_valid_reg <= distance_valid_next;
        result_update_reg <= result_update_next;
        echo_sync_reg <= {echo_sync_reg[0], echo_i};
        previous_echo_reg <= echo_sync_reg[1];
        if (rst) begin
            state_reg <= STATE_POLL;
            poll_reg <= {POLL_WIDTH{1'b0}};
            timeout_reg <= {TIMEOUT_WIDTH{1'b0}};
            trigger_reg <= {TRIGGER_WIDTH{1'b0}};
            fraction_reg <= {FRACTION_WIDTH{1'b0}};
            millimetres_reg <= 16'd0;
            distance_reg <= 16'd0;
            trig_reg <= 1'b0;
            distance_valid_reg <= 1'b0;
            result_update_reg <= 1'b0;
            echo_sync_reg <= 2'b00;
            previous_echo_reg <= 1'b0;
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || SOUND_SPEED_MM_PER_S < 1 || CYCLES_PER_MM < 3 ||
            TRIGGER_US <= 10 || RESPONSE_TIMEOUT_MS < 1 ||
            POLL_CYCLES <= TIMEOUT_CYCLES + TRIGGER_CYCLES ||
            MIN_DISTANCE_MM > MAX_DISTANCE_MM) begin
            $error("Invalid hcsr04_2020_ranging parameters");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`resetall
