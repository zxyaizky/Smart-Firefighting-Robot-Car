// -----------------------------------------------------------------------------
// File   : hsv_red_threshold.v
// Author : Codex
// Date   : 2026-10-10
// -----------------------------------------------------------------------------
// Description:
//   RGB888 red classification equivalent to continuous HSV thresholds:
//   H in [0, 20] or [340, 360] degrees, S >= S_MIN/255, V >= V_MIN/255.
//   No division, multiplier operator, pixel memory, or image scaling.
//   One input sample per clock. Synchronous active-high reset clears all stages.
//   A sample captured at edge E0 is available after edge E4: four clock periods.
//   Coordinates and all frame markers have the same fixed latency, even in gaps.
//   Frame abort is forwarded as a marker; it does not flush earlier samples.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-11  Codex  v2.0  Parameterize coordinate metadata; keep color equations and latency.
//   2026-10-10  Codex  v1.0  Standalone pipelined HSV red threshold classifier.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module hsv_red_threshold #
(
    // Saturation threshold on the 0..255 scale; legal values are 0..255.
    parameter [7:0] S_MIN = 8'd100,
    // Value threshold on the 0..255 scale; legal values are 0..255.
    parameter [7:0] V_MIN = 8'd50,
    // Legacy defaults; B-board full-resolution branch overrides to 11/10.
    parameter integer X_WIDTH = 8,
    parameter integer Y_WIDTH = 7
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] pixel_rgb_i,
    input  wire        pixel_valid_i,
    input  wire [X_WIDTH-1:0] pixel_x_i,
    input  wire [Y_WIDTH-1:0] pixel_y_i,
    input  wire        frame_start_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    output wire        red_mask_o,
    output wire        pixel_valid_o,
    output wire [X_WIDTH-1:0] pixel_x_o,
    output wire [Y_WIDTH-1:0] pixel_y_o,
    output wire        frame_start_o,
    output wire        frame_end_o,
    output wire        frame_abort_o
);

    // Metadata: {abort, end, start, valid, y, x}; color arithmetic is unchanged.
    localparam integer XY_WIDTH = X_WIDTH + Y_WIDTH;
    localparam integer META_WIDTH = XY_WIDTH + 4;
    // It advances on EVERY clock, without qualifying frame markers by valid.
    wire [META_WIDTH-1:0] metadata_input;
    reg [META_WIDTH-1:0] metadata_input_pipe_reg = {META_WIDTH{1'b0}};
    reg [META_WIDTH-1:0] metadata_extrema_pipe_reg = {META_WIDTH{1'b0}};
    reg [META_WIDTH-1:0] metadata_scale_pipe_reg = {META_WIDTH{1'b0}};
    reg [META_WIDTH-1:0] metadata_compare_pipe_reg = {META_WIDTH{1'b0}};
    reg [META_WIDTH-1:0] metadata_output_pipe_reg = {META_WIDTH{1'b0}};

    // Stage 0: input boundary registers.
    reg [23:0] rgb_input_pipe_reg = 24'd0;
    wire [7:0] red_input;
    wire [7:0] green_input;
    wire [7:0] blue_input;

    // Stage 1: unsigned extrema and ordered subtraction for abs(G-B).
    wire [7:0] max_red_green;
    wire [7:0] min_red_green;
    wire [7:0] max_input;
    wire [7:0] min_input;
    wire [7:0] green_blue_abs;
    wire red_is_max;
    reg [7:0] max_extrema_pipe_reg = 8'd0;
    reg [7:0] min_extrema_pipe_reg = 8'd0;
    reg [7:0] abs_extrema_pipe_reg = 8'd0;
    reg red_max_extrema_pipe_reg = 1'b0;

    // Stage 2: DELTA, 3*abs(G-B), and two halves of S_MIN*MAX.
    // All shifts are performed AFTER extension, so high bits are retained.
    wire [9:0] abs_extended;
    wire [11:0] max_low_extended;
    wire [15:0] max_high_extended;
    wire [11:0] saturation_bit_zero;
    wire [11:0] saturation_bit_one;
    wire [11:0] saturation_bit_two;
    wire [11:0] saturation_bit_three;
    wire [15:0] saturation_bit_four;
    wire [15:0] saturation_bit_five;
    wire [15:0] saturation_bit_six;
    wire [15:0] saturation_bit_seven;
    wire [11:0] saturation_low_sum;
    wire [15:0] saturation_high_sum;
    wire [7:0] delta_scale_next;
    wire [9:0] hue_scale_next;
    wire candidate_scale_next;
    reg [7:0] delta_scale_pipe_reg = 8'd0;
    reg [9:0] hue_scale_pipe_reg = 10'd0;
    reg [11:0] saturation_low_pipe_reg = 12'd0;
    reg [15:0] saturation_high_pipe_reg = 16'd0;
    reg candidate_scale_pipe_reg = 1'b0;

    // Stage 3: complete saturation operands and the hue/non-gray predicate.
    // DELTA*255 and S_MIN*MAX are <= 65025, and fit in 16 unsigned bits.
    wire [15:0] delta_extended;
    wire [15:0] saturation_delta_next;
    wire [15:0] saturation_limit_next;
    wire candidate_compare_next;
    reg [15:0] saturation_delta_pipe_reg = 16'd0;
    reg [15:0] saturation_limit_pipe_reg = 16'd0;
    reg candidate_compare_pipe_reg = 1'b0;

    // Stage 4: registered output classification, forced low for invalid pixels.
    wire red_mask_next;
    reg red_mask_pipe_reg = 1'b0;

    assign metadata_input = {frame_abort_i, frame_end_i, frame_start_i,
                             pixel_valid_i, pixel_y_i, pixel_x_i};
    assign red_input      = rgb_input_pipe_reg[23:16];
    assign green_input    = rgb_input_pipe_reg[15:8];
    assign blue_input     = rgb_input_pipe_reg[7:0];

    assign max_red_green  = red_input >= green_input ? red_input : green_input;
    assign min_red_green  = red_input <= green_input ? red_input : green_input;
    assign max_input      = max_red_green >= blue_input ? max_red_green : blue_input;
    assign min_input      = min_red_green <= blue_input ? min_red_green : blue_input;
    assign green_blue_abs = green_input >= blue_input ?
                            green_input - blue_input : blue_input - green_input;
    assign red_is_max     = (red_input >= green_input) && (red_input >= blue_input);

    assign abs_extended      = {2'd0, abs_extrema_pipe_reg};
    assign max_low_extended  = {4'd0, max_extrema_pipe_reg};
    assign max_high_extended = {8'd0, max_extrema_pipe_reg};
    assign saturation_bit_zero  = S_MIN[0] ? max_low_extended : 12'd0;
    assign saturation_bit_one   = S_MIN[1] ? (max_low_extended << 4'd1) : 12'd0;
    assign saturation_bit_two   = S_MIN[2] ? (max_low_extended << 4'd2) : 12'd0;
    assign saturation_bit_three = S_MIN[3] ? (max_low_extended << 4'd3) : 12'd0;
    assign saturation_bit_four  = S_MIN[4] ? (max_high_extended << 4'd4) : 16'd0;
    assign saturation_bit_five  = S_MIN[5] ? (max_high_extended << 4'd5) : 16'd0;
    assign saturation_bit_six   = S_MIN[6] ? (max_high_extended << 4'd6) : 16'd0;
    assign saturation_bit_seven = S_MIN[7] ? (max_high_extended << 4'd7) : 16'd0;
    assign saturation_low_sum   = (saturation_bit_zero + saturation_bit_one) +
                                  (saturation_bit_two + saturation_bit_three);
    assign saturation_high_sum  = (saturation_bit_four + saturation_bit_five) +
                                  (saturation_bit_six + saturation_bit_seven);
    assign delta_scale_next     = max_extrema_pipe_reg - min_extrema_pipe_reg;
    assign hue_scale_next       = (abs_extended << 4'd1) + abs_extended;
    assign candidate_scale_next = red_max_extrema_pipe_reg && (max_extrema_pipe_reg >= V_MIN);

    assign delta_extended         = {8'd0, delta_scale_pipe_reg};
    assign saturation_delta_next  = (delta_extended << 4'd8) - delta_extended;
    assign saturation_limit_next  = {4'd0, saturation_low_pipe_reg} + saturation_high_pipe_reg;
    assign candidate_compare_next = candidate_scale_pipe_reg && (delta_scale_pipe_reg != 8'd0) &&
                                    (hue_scale_pipe_reg <= {2'd0, delta_scale_pipe_reg});
    assign red_mask_next          = metadata_compare_pipe_reg[XY_WIDTH] && candidate_compare_pipe_reg &&
                                    (saturation_delta_pipe_reg >= saturation_limit_pipe_reg);

    assign red_mask_o    = red_mask_pipe_reg;
    assign pixel_valid_o = metadata_output_pipe_reg[XY_WIDTH];
    assign pixel_x_o     = metadata_output_pipe_reg[X_WIDTH-1:0];
    assign pixel_y_o     = metadata_output_pipe_reg[XY_WIDTH-1:X_WIDTH];
    assign frame_start_o = metadata_output_pipe_reg[XY_WIDTH+1];
    assign frame_end_o   = metadata_output_pipe_reg[XY_WIDTH+2];
    assign frame_abort_o = metadata_output_pipe_reg[XY_WIDTH+3];

    always @(posedge clk) begin
        rgb_input_pipe_reg      <= pixel_rgb_i;
        metadata_input_pipe_reg <= metadata_input;
        if (rst) begin
            rgb_input_pipe_reg      <= 24'd0;
            metadata_input_pipe_reg <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        max_extrema_pipe_reg      <= max_input;
        min_extrema_pipe_reg      <= min_input;
        abs_extrema_pipe_reg      <= green_blue_abs;
        red_max_extrema_pipe_reg  <= red_is_max;
        metadata_extrema_pipe_reg <= metadata_input_pipe_reg;
        if (rst) begin
            max_extrema_pipe_reg      <= 8'd0;
            min_extrema_pipe_reg      <= 8'd0;
            abs_extrema_pipe_reg      <= 8'd0;
            red_max_extrema_pipe_reg  <= 1'b0;
            metadata_extrema_pipe_reg <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        delta_scale_pipe_reg     <= delta_scale_next;
        hue_scale_pipe_reg       <= hue_scale_next;
        saturation_low_pipe_reg  <= saturation_low_sum;
        saturation_high_pipe_reg <= saturation_high_sum;
        candidate_scale_pipe_reg <= candidate_scale_next;
        metadata_scale_pipe_reg  <= metadata_extrema_pipe_reg;
        if (rst) begin
            delta_scale_pipe_reg     <= 8'd0;
            hue_scale_pipe_reg       <= 10'd0;
            saturation_low_pipe_reg  <= 12'd0;
            saturation_high_pipe_reg <= 16'd0;
            candidate_scale_pipe_reg <= 1'b0;
            metadata_scale_pipe_reg  <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        saturation_delta_pipe_reg  <= saturation_delta_next;
        saturation_limit_pipe_reg  <= saturation_limit_next;
        candidate_compare_pipe_reg <= candidate_compare_next;
        metadata_compare_pipe_reg  <= metadata_scale_pipe_reg;
        if (rst) begin
            saturation_delta_pipe_reg  <= 16'd0;
            saturation_limit_pipe_reg  <= 16'd0;
            candidate_compare_pipe_reg <= 1'b0;
            metadata_compare_pipe_reg  <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        red_mask_pipe_reg        <= red_mask_next;
        metadata_output_pipe_reg <= metadata_compare_pipe_reg;
        if (rst) begin
            red_mask_pipe_reg        <= 1'b0;
            metadata_output_pipe_reg <= {META_WIDTH{1'b0}};
        end
    end

endmodule

`resetall
