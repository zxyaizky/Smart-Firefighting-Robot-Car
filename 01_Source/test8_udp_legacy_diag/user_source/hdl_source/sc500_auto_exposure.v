// -----------------------------------------------------------------------------
// File   : sc500_auto_exposure.v
// Author : Codex
// Date   : 2026-10-03
// -----------------------------------------------------------------------------
// Description:
//   Passive RAW10 brightness statistics and bounded SC500 exposure/gain control.
//   Statistics use a held req/ack mailbox; sensor settings stay stable throughout
//   all five I2C writes. This module does not delay or backpressure video pixels.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-03  Codex  v1.0  Default-on A camera automatic exposure
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module sc500_auto_exposure #
(
    // Brightness settings match B's existing automatic controller.
    parameter [7:0] TARGET_LEVEL = 8'd110,
    parameter [7:0] TARGET_HYSTERESIS = 8'd8,
    // SC500 720p60 integration bounds, in sensor exposure register units.
    parameter [15:0] EXPOSURE_MIN = 16'd32,
    parameter [15:0] EXPOSURE_MAX = 16'd1990,
    parameter [15:0] EXPOSURE_INIT = 16'd1990,
    // Gain index includes the existing configuration driver's offset of 16.
    parameter [15:0] GAIN_MIN = 16'd16,
    parameter [15:0] GAIN_MAX = 16'd143,
    // 136 maps to A's existing startup sensor gain 16'h1f38.
    parameter [15:0] GAIN_INIT = 16'd136,
    // Take one four-pixel beat in sixteen, without an image buffer.
    parameter integer SAMPLE_LOG2 = 4,
    // Ignore empty or substantially truncated frames.
    parameter [15:0] MIN_SAMPLES = 16'd256
)
(
    input  wire        clk_pixel,
    input  wire        clk_config,
    input  wire        rst,
    input  wire        frame_start_i,
    input  wire        pixel_valid_i,
    input  wire [39:0] pixel_data_i,
    input  wire        camera_config_done_i,
    input  wire        ae_config_done_i,
    output wire        ae_request_o,
    output wire [15:0] exposure_o,
    output wire [15:0] gain_o
);
    localparam [7:0] LEVEL_LOW = TARGET_LEVEL - TARGET_HYSTERESIS;
    localparam [7:0] LEVEL_HIGH = TARGET_LEVEL + TARGET_HYSTERESIS;
    // One-hot configuration FSM; no state bus crosses clock domains.
    localparam [2:0] CONFIG_IDLE = 3'b001;
    localparam [2:0] CONFIG_WAIT_BUSY = 3'b010;
    localparam [2:0] CONFIG_WAIT_DONE = 3'b100;

    wire [9:0] sample_value;
    wire [24:0] sample_sum;
    wire mailbox_available;
    wire statistics_event;
    wire [25:0] low_limit;
    wire [25:0] high_limit;
    wire image_dark;
    wire image_bright;

    reg [SAMPLE_LOG2-1:0] sample_phase_reg = {SAMPLE_LOG2{1'b0}}, sample_phase_next;
    reg [23:0] frame_sum_reg = 24'd0, frame_sum_next;
    reg [15:0] frame_samples_reg = 16'd0, frame_samples_next;
    reg frame_open_reg = 1'b0, frame_open_next;
    reg overflow_reg = 1'b0, overflow_next;
    reg [23:0] held_sum_reg = 24'd0, held_sum_next;
    reg [15:0] held_samples_reg = 16'd0, held_samples_next;
    reg request_toggle_reg = 1'b0, request_toggle_next;
    (* async_reg = "true" *) reg [1:0] acknowledge_sync_reg = 2'b00;
    (* async_reg = "true" *) reg [2:0] request_sync_reg = 3'b000;
    reg acknowledge_reg = 1'b0, acknowledge_next;
    reg [2:0] config_state_reg = CONFIG_IDLE, config_state_next;
    reg boot_pending_reg = 1'b1, boot_pending_next;
    reg ae_request_reg = 1'b0, ae_request_next;
    reg [15:0] exposure_reg = EXPOSURE_INIT, exposure_next;
    reg [15:0] gain_reg = GAIN_INIT, gain_next;

    assign sample_value = {2'd0, pixel_data_i[9:2]} +
                          {2'd0, pixel_data_i[19:12]} +
                          {2'd0, pixel_data_i[29:22]} +
                          {2'd0, pixel_data_i[39:32]};
    assign sample_sum = {1'b0, frame_sum_reg} + {15'd0, sample_value};
    assign mailbox_available = request_toggle_reg == acknowledge_sync_reg[1];
    assign statistics_event = request_sync_reg[2] != acknowledge_reg;
    assign low_limit = {10'd0, held_samples_reg} * {16'd0, LEVEL_LOW, 2'b00};
    assign high_limit = {10'd0, held_samples_reg} * {16'd0, LEVEL_HIGH, 2'b00};
    assign image_dark = {2'd0, held_sum_reg} < low_limit;
    assign image_bright = {2'd0, held_sum_reg} > high_limit;
    assign ae_request_o = ae_request_reg;
    assign exposure_o = exposure_reg;
    assign gain_o = gain_reg;

    always @* begin
        sample_phase_next = sample_phase_reg;
        frame_sum_next = frame_sum_reg;
        frame_samples_next = frame_samples_reg;
        frame_open_next = frame_open_reg;
        overflow_next = overflow_reg;
        held_sum_next = held_sum_reg;
        held_samples_next = held_samples_reg;
        request_toggle_next = request_toggle_reg;
        if (frame_start_i) begin
            // Publish the previous frame only if its mailbox is free.
            if (frame_open_reg && !overflow_reg &&
                frame_samples_reg >= MIN_SAMPLES && mailbox_available) begin
                held_sum_next = frame_sum_reg;
                held_samples_next = frame_samples_reg;
                request_toggle_next = ~request_toggle_reg;
            end
            frame_open_next = 1'b1;
            overflow_next = 1'b0;
            sample_phase_next = {SAMPLE_LOG2{1'b0}};
            frame_sum_next = 24'd0;
            frame_samples_next = 16'd0;
            // Include a valid first beat coincident with frame-start.
            if (pixel_valid_i) begin
                frame_sum_next = {14'd0, sample_value};
                frame_samples_next = 16'd1;
                sample_phase_next = {{(SAMPLE_LOG2-1){1'b0}}, 1'b1};
            end
        end else if (frame_open_reg && pixel_valid_i) begin
            sample_phase_next = sample_phase_reg + 1'b1;
            if (sample_phase_reg == {SAMPLE_LOG2{1'b0}} && !overflow_reg) begin
                if (sample_sum[24] || frame_samples_reg == 16'hffff) begin
                    overflow_next = 1'b1;
                end else begin
                    frame_sum_next = sample_sum[23:0];
                    frame_samples_next = frame_samples_reg + 16'd1;
                end
            end
        end
    end

    // CDC: configuration acknowledge -> pixel clock, through two flops.
    always @(posedge clk_pixel) begin
        acknowledge_sync_reg <= {acknowledge_sync_reg[0], acknowledge_reg};
        sample_phase_reg <= sample_phase_next;
        frame_sum_reg <= frame_sum_next;
        frame_samples_reg <= frame_samples_next;
        frame_open_reg <= frame_open_next;
        overflow_reg <= overflow_next;
        held_sum_reg <= held_sum_next;
        held_samples_reg <= held_samples_next;
        request_toggle_reg <= request_toggle_next;
        if (rst) begin
            acknowledge_sync_reg <= 2'b00;
            sample_phase_reg <= {SAMPLE_LOG2{1'b0}};
            frame_sum_reg <= 24'd0;
            frame_samples_reg <= 16'd0;
            frame_open_reg <= 1'b0;
            overflow_reg <= 1'b0;
            held_sum_reg <= 24'd0;
            held_samples_reg <= 16'd0;
            request_toggle_reg <= 1'b0;
        end
    end

    always @* begin
        acknowledge_next = acknowledge_reg;
        config_state_next = config_state_reg;
        boot_pending_next = boot_pending_reg;
        ae_request_next = 1'b0;
        exposure_next = exposure_reg;
        gain_next = gain_reg;
        // Consume/discard stats while an I2C update is in flight, never replay them.
        if (statistics_event) acknowledge_next = request_sync_reg[2];
        case (config_state_reg)
            CONFIG_IDLE: begin
                if (camera_config_done_i && ae_config_done_i) begin
                    if (boot_pending_reg) begin
                        boot_pending_next = 1'b0;
                        ae_request_next = 1'b1;
                        config_state_next = CONFIG_WAIT_BUSY;
                    end else if (statistics_event) begin
                        if (image_dark) begin
                            if (exposure_reg < EXPOSURE_MAX) begin
                                exposure_next = exposure_reg > EXPOSURE_MAX - 16'd32 ?
                                                EXPOSURE_MAX : exposure_reg + 16'd32;
                            end else if (gain_reg < GAIN_MAX) begin
                                gain_next = gain_reg + 16'd1;
                            end
                        end else if (image_bright) begin
                            if (gain_reg > GAIN_MIN) begin
                                gain_next = gain_reg - 16'd1;
                            end else if (exposure_reg > EXPOSURE_MIN) begin
                                exposure_next = exposure_reg < EXPOSURE_MIN + 16'd32 ?
                                                EXPOSURE_MIN : exposure_reg - 16'd32;
                            end
                        end
                        if (exposure_next != exposure_reg || gain_next != gain_reg) begin
                            ae_request_next = 1'b1;
                            config_state_next = CONFIG_WAIT_BUSY;
                        end
                    end
                end
            end
            CONFIG_WAIT_BUSY: begin
                if (!ae_config_done_i) config_state_next = CONFIG_WAIT_DONE;
            end
            CONFIG_WAIT_DONE: begin
                if (ae_config_done_i) config_state_next = CONFIG_IDLE;
            end
            default: config_state_next = CONFIG_IDLE;
        endcase
    end

    // CDC: pixel request -> configuration clock, through three flops. held_sum
    // and held_samples stay unchanged until the acknowledge returns to pixel.
    always @(posedge clk_config) begin
        request_sync_reg <= {request_sync_reg[1:0], request_toggle_reg};
        acknowledge_reg <= acknowledge_next;
        config_state_reg <= config_state_next;
        boot_pending_reg <= boot_pending_next;
        ae_request_reg <= ae_request_next;
        exposure_reg <= exposure_next;
        gain_reg <= gain_next;
        if (rst) begin
            request_sync_reg <= 3'b000;
            acknowledge_reg <= 1'b0;
            config_state_reg <= CONFIG_IDLE;
            boot_pending_reg <= 1'b1;
            ae_request_reg <= 1'b0;
            exposure_reg <= EXPOSURE_INIT;
            gain_reg <= GAIN_INIT;
        end
    end
endmodule
`resetall
