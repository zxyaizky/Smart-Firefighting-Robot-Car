// -----------------------------------------------------------------------------
// File   : hsv_red_pixel_counter.v
// Author : Codex
// Date   : 2026-10-10
// -----------------------------------------------------------------------------
// Description:
//   Count validated HSV red/green/yellow pixels in one ordered parameterized frame, without RAM.
//   Working counters and the committed result have separate register boundaries.
//   EOF commits only after exactly IMAGE_WIDTH*IMAGE_HEIGHT ordered pixels. Abort takes priority.
//   START+first pixel and END+last pixel are supported with next-state arithmetic.
//   A valid result is a one-clock pulse, including a complete non-red count of 0.
//   The committed count holds through invalid frames until a new result or reset.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-16  Codex  v2.2  Add yellow counters with shared ordered-frame commit.
//   2026-10-14  Codex  v2.1  Count green independently with the shared frame validator.
//   2026-10-11  Codex  v2.0  Parameterized ordered counts; complete-frame top-row count.
//   2026-10-10  Codex  v1.0  Lightweight HSV per-frame red pixel count.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module hsv_red_pixel_counter #
(
    // Legacy defaults; the B-board overrides all dimensions for 720P.
    parameter integer IMAGE_WIDTH = 160,
    parameter integer IMAGE_HEIGHT = 90,
    parameter integer X_WIDTH = 8,
    parameter integer Y_WIDTH = 7,
    parameter integer COUNT_WIDTH = 14,
    // Disabled legacy diagnostic is removed by constant propagation.
    parameter integer TOP_ROWS = 0
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        red_mask_i,
    input  wire        green_mask_i,
    input  wire        yellow_mask_i,
    input  wire        pixel_valid_i,
    input  wire [X_WIDTH-1:0]  pixel_x_i,
    input  wire [Y_WIDTH-1:0]  pixel_y_i,
    input  wire        frame_start_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    output wire [COUNT_WIDTH-1:0] red_pixel_count_o,
    output wire [COUNT_WIDTH-1:0] green_pixel_count_o,
    output wire [COUNT_WIDTH-1:0] yellow_pixel_count_o,
    output wire        frame_result_valid_o,
    output wire [13:0] top_red_pixel_count_o
);
    localparam [COUNT_WIDTH-1:0] FRAME_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam [X_WIDTH-1:0] LAST_X = IMAGE_WIDTH - 1;
    localparam [Y_WIDTH-1:0] END_Y = IMAGE_HEIGHT;
    reg [13:0] top_count_reg = 14'd0, top_count_next;
    reg [13:0] top_result_reg = 14'd0, top_result_next;
    reg active_reg = 1'b0, active_next;
    reg [COUNT_WIDTH-1:0] sample_count_reg = {COUNT_WIDTH{1'b0}}, sample_count_next;
    reg [COUNT_WIDTH-1:0] red_count_reg = {COUNT_WIDTH{1'b0}}, red_count_next;
    reg [X_WIDTH-1:0] expected_x_reg = {X_WIDTH{1'b0}}, expected_x_next;
    reg [Y_WIDTH-1:0] expected_y_reg = {Y_WIDTH{1'b0}}, expected_y_next;
    reg [COUNT_WIDTH-1:0] result_reg = {COUNT_WIDTH{1'b0}}, result_next;
    reg result_valid_reg = 1'b0, result_valid_next;
    reg [COUNT_WIDTH-1:0] green_count_reg = {COUNT_WIDTH{1'b0}}, green_count_next;
    reg [COUNT_WIDTH-1:0] yellow_count_reg = {COUNT_WIDTH{1'b0}}, yellow_count_next;
    reg [COUNT_WIDTH-1:0] green_result_reg = {COUNT_WIDTH{1'b0}}, green_result_next;
    reg [COUNT_WIDTH-1:0] yellow_result_reg = {COUNT_WIDTH{1'b0}}, yellow_result_next;
    reg reject_frame = 1'b0;

    assign top_red_pixel_count_o = top_result_reg;
    assign red_pixel_count_o    = result_reg;
    assign green_pixel_count_o  = green_result_reg;
    assign yellow_pixel_count_o  = yellow_result_reg;
    assign frame_result_valid_o = result_valid_reg;

    always @* begin
        top_count_next = top_count_reg;
        top_result_next = top_result_reg;
        active_next = active_reg;
        sample_count_next = sample_count_reg;
        red_count_next = red_count_reg;
        green_count_next = green_count_reg;
        yellow_count_next = yellow_count_reg;
        green_result_next = green_result_reg;
        yellow_result_next = yellow_result_reg;
        expected_x_next = expected_x_reg;
        expected_y_next = expected_y_reg;
        result_next = result_reg;
        result_valid_next = 1'b0;
        reject_frame = frame_abort_i;
        if (frame_start_i && !reject_frame) begin
            if (active_reg) begin
                reject_frame = 1'b1;
            end else begin
                active_next = 1'b1;
                sample_count_next = {COUNT_WIDTH{1'b0}};
                red_count_next = {COUNT_WIDTH{1'b0}};
                green_count_next = {COUNT_WIDTH{1'b0}};
                yellow_count_next = {COUNT_WIDTH{1'b0}};
                top_count_next = 14'd0;
                expected_x_next = {X_WIDTH{1'b0}};
                expected_y_next = {Y_WIDTH{1'b0}};
            end
        end
        if (active_next && !reject_frame) begin
            if (pixel_valid_i) begin
                if (sample_count_next >= FRAME_PIXELS || pixel_x_i != expected_x_next ||
                    pixel_y_i != expected_y_next) begin
                    reject_frame = 1'b1;
                end else begin
                    sample_count_next = sample_count_next + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    if (red_mask_i) begin
                        red_count_next = red_count_next + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                        if (TOP_ROWS != 0 && pixel_y_i < TOP_ROWS)
                            top_count_next = top_count_next + 14'd1;
                    end
                    if (green_mask_i) begin
                        green_count_next = green_count_next + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                    if (yellow_mask_i) begin
                        yellow_count_next = yellow_count_next + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                    if (expected_x_next == LAST_X) begin
                        expected_x_next = {X_WIDTH{1'b0}};
                        expected_y_next = expected_y_next + {{(Y_WIDTH-1){1'b0}}, 1'b1};
                    end else begin
                        expected_x_next = expected_x_next + {{(X_WIDTH-1){1'b0}}, 1'b1};
                    end
                end
            end
            if (frame_end_i) begin
                if (!reject_frame && sample_count_next == FRAME_PIXELS &&
                    expected_x_next == {X_WIDTH{1'b0}} && expected_y_next == END_Y) begin
                    result_next = red_count_next;
                    green_result_next = green_count_next;
                    yellow_result_next = yellow_count_next;
                    top_result_next = top_count_next;
                    result_valid_next = 1'b1;
                end
                active_next = 1'b0;
            end
        end
        if (reject_frame) begin
            top_count_next = 14'd0;
            active_next = 1'b0;
            sample_count_next = {COUNT_WIDTH{1'b0}};
            red_count_next = {COUNT_WIDTH{1'b0}};
            green_count_next = {COUNT_WIDTH{1'b0}};
            yellow_count_next = {COUNT_WIDTH{1'b0}};
            expected_x_next = {X_WIDTH{1'b0}};
            expected_y_next = {Y_WIDTH{1'b0}};
            result_valid_next = 1'b0;
        end
    end

    always @(posedge clk) begin
        top_count_reg <= top_count_next;
        top_result_reg <= top_result_next;
        active_reg <= active_next;
        sample_count_reg <= sample_count_next;
        red_count_reg <= red_count_next;
        green_count_reg <= green_count_next;
        yellow_count_reg <= yellow_count_next;
        green_result_reg <= green_result_next;
        yellow_result_reg <= yellow_result_next;
        expected_x_reg <= expected_x_next;
        expected_y_reg <= expected_y_next;
        result_reg <= result_next;
        result_valid_reg <= result_valid_next;
        if (rst) begin
            top_count_reg <= 14'd0;
            top_result_reg <= 14'd0;
            active_reg <= 1'b0;
            sample_count_reg <= {COUNT_WIDTH{1'b0}};
            red_count_reg <= {COUNT_WIDTH{1'b0}};
            green_count_reg <= {COUNT_WIDTH{1'b0}};
            yellow_count_reg <= {COUNT_WIDTH{1'b0}};
            green_result_reg <= {COUNT_WIDTH{1'b0}};
            yellow_result_reg <= {COUNT_WIDTH{1'b0}};
            expected_x_reg <= {X_WIDTH{1'b0}};
            expected_y_reg <= {Y_WIDTH{1'b0}};
            result_reg <= {COUNT_WIDTH{1'b0}};
            result_valid_reg <= 1'b0;
        end
    end
endmodule
`resetall
