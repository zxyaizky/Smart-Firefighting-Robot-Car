// -----------------------------------------------------------------------------
// File   : hsv_red_threshold.v
// Author : Codex
// Date   : 2026-10-10
// -----------------------------------------------------------------------------
// Description:
//   RGB888 red/green/yellow classification equivalent to continuous HSV thresholds:
//   H in [0, 20] or [340, 360] degrees, S >= S_MIN/255, V >= V_MIN/255.
//   No division, multiplier operator, pixel memory, or image scaling.
//   One input sample per clock. Synchronous active-high reset clears all stages.
//   A sample captured at edge E0 is available after edge E4: four clock periods.
//   Coordinates and all frame markers have the same fixed latency, even in gaps.
//   Frame abort is forwarded as a marker; it does not flush earlier samples.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-16  Codex  v2.3  Add shared yellow H=40..80, red S/V floors.
//   2026-10-14  Codex  v2.2  Independent green saturation/value; retain red thresholds.
//   2026-10-14  Codex  v2.1  Share extrema/saturation and metadata with green hue mask.
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
    parameter integer Y_WIDTH = 7,
    // Default to legacy shared floors unless the board explicitly overrides them.
    parameter [7:0] GREEN_S_MIN = S_MIN,
    parameter [7:0] GREEN_V_MIN = V_MIN,
    // Green hue is 120 +/- 20*scale degrees; legal scale is 1, 2 or 3.
    parameter integer GREEN_HUE_DELTA_SCALE = 2
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
    output wire        green_mask_o,
    output wire        yellow_mask_o,
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
    wire [7:0] max_input;
    wire [7:0] min_input;
    wire [7:0] green_blue_abs;
    wire red_is_max;
    wire green_is_max;
    wire [7:0] red_blue_abs;
    wire [7:0] red_green_abs;
    wire blue_is_min;
    reg [7:0] yellow_abs_extrema_pipe_reg = 8'd0;
    reg yellow_min_extrema_pipe_reg = 1'b0;
    reg [7:0] green_abs_extrema_pipe_reg = 8'd0;
    reg green_max_extrema_pipe_reg = 1'b0;
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
    wire [9:0] green_abs_extended;
    wire [9:0] green_hue_scale_next;
    wire green_candidate_scale_next;
    reg [9:0] green_hue_scale_pipe_reg = 10'd0;
    reg green_candidate_scale_pipe_reg = 1'b0;
    wire [9:0] yellow_abs_extended;
    wire [9:0] yellow_hue_scale_next;
    wire yellow_candidate_scale_next;
    reg [9:0] yellow_hue_scale_pipe_reg = 10'd0;
    reg yellow_candidate_scale_pipe_reg = 1'b0;

    // Stage 3: complete saturation operands and the hue/non-gray predicate.
    // DELTA*255 and S_MIN*MAX are <= 65025, and fit in 16 unsigned bits.
    wire [15:0] delta_extended;
    wire [15:0] saturation_delta_next;
    wire [15:0] saturation_limit_next;
    wire candidate_compare_next;
    reg [15:0] saturation_delta_pipe_reg = 16'd0;
    reg [15:0] saturation_limit_pipe_reg = 16'd0;
    reg candidate_compare_pipe_reg = 1'b0;
    wire [9:0] green_delta_limit;
    wire green_candidate_compare_next;
    reg green_candidate_compare_pipe_reg = 1'b0;
    wire yellow_candidate_compare_next;
    reg yellow_candidate_compare_pipe_reg = 1'b0;

    // Stage 4: registered output classification, forced low for invalid pixels.
    wire red_mask_next;
    reg red_mask_pipe_reg = 1'b0;
    wire [15:0] green_saturation_limit;
    wire green_mask_next;
    reg green_mask_pipe_reg = 1'b0;
    wire yellow_mask_next;
    reg yellow_mask_pipe_reg = 1'b0;

    assign metadata_input = {frame_abort_i, frame_end_i, frame_start_i,
                             pixel_valid_i, pixel_y_i, pixel_x_i};
    assign red_input      = rgb_input_pipe_reg[23:16];
    assign green_input    = rgb_input_pipe_reg[15:8];
    assign blue_input     = rgb_input_pipe_reg[7:0];

    wire [8:0] green_blue_delta = {1'b0,green_input} - {1'b0,blue_input};
    wire [8:0] red_blue_delta = {1'b0,red_input} - {1'b0,blue_input};
    wire [8:0] red_green_delta = {1'b0,red_input} - {1'b0,green_input};
    assign max_input      = !red_green_delta[8] ? (!red_blue_delta[8] ? red_input : blue_input) : (!green_blue_delta[8] ? green_input : blue_input);
    assign min_input      = red_green_delta[8] ? (red_blue_delta[8] ? red_input : blue_input) : (green_blue_delta[8] ? green_input : blue_input);
    assign green_blue_abs = green_blue_delta[8] ? (~green_blue_delta[7:0] + 8'd1) : green_blue_delta[7:0];
    assign red_is_max     = (!red_green_delta[8]) && (!red_blue_delta[8]);
    assign green_is_max   = (red_green_delta[8] || red_green_delta == 9'd0) && (!green_blue_delta[8]);
    assign red_blue_abs = red_blue_delta[8] ? (~red_blue_delta[7:0] + 8'd1) : red_blue_delta[7:0];

    // Blue minimum and close R/G select H=40..80 about the yellow centre 60.
    assign red_green_abs = red_green_delta[8] ? (~red_green_delta[7:0] + 8'd1) : red_green_delta[7:0];
    assign blue_is_min = !red_blue_delta[8] && !green_blue_delta[8];

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

    assign green_abs_extended = {2'd0, green_abs_extrema_pipe_reg};
    assign green_hue_scale_next = (green_abs_extended << 4'd1) + green_abs_extended;
    assign green_candidate_scale_next = green_max_extrema_pipe_reg &&
                                        (max_extrema_pipe_reg >= GREEN_V_MIN);
    assign green_delta_limit = GREEN_HUE_DELTA_SCALE == 1 ?
        {2'd0, delta_scale_pipe_reg} : (GREEN_HUE_DELTA_SCALE == 2 ?
        ({2'd0, delta_scale_pipe_reg} << 4'd1) :
        (({2'd0, delta_scale_pipe_reg} << 4'd1) + {2'd0, delta_scale_pipe_reg}));
    assign green_candidate_compare_next = green_candidate_scale_pipe_reg &&
        (delta_scale_pipe_reg != 8'd0) && (green_hue_scale_pipe_reg <= green_delta_limit);

    assign yellow_abs_extended = {2'd0, yellow_abs_extrema_pipe_reg};
    assign yellow_hue_scale_next = (yellow_abs_extended << 4'd1) +
                                   yellow_abs_extended;
    assign yellow_candidate_scale_next = yellow_min_extrema_pipe_reg &&
                                         (max_extrema_pipe_reg >= V_MIN);
    assign yellow_candidate_compare_next = yellow_candidate_scale_pipe_reg &&
        (delta_scale_pipe_reg != 8'd0) &&
        (yellow_hue_scale_pipe_reg <= {2'd0, delta_scale_pipe_reg});

    assign delta_extended         = {8'd0, delta_scale_pipe_reg};
    assign saturation_delta_next  = (delta_extended << 4'd8) - delta_extended;
    assign saturation_limit_next  = {4'd0, saturation_low_pipe_reg} + saturation_high_pipe_reg;
    assign candidate_compare_next = candidate_scale_pipe_reg && (delta_scale_pipe_reg != 8'd0) &&
                                    (hue_scale_pipe_reg <= {2'd0, delta_scale_pipe_reg});
    assign red_mask_next          = metadata_compare_pipe_reg[XY_WIDTH] && candidate_compare_pipe_reg &&
                                    (saturation_delta_pipe_reg >= saturation_limit_pipe_reg);

    assign green_mask_next = metadata_compare_pipe_reg[XY_WIDTH] &&
        green_candidate_compare_pipe_reg &&
        (saturation_delta_pipe_reg >= green_saturation_limit);

    // Reuse both registered saturation operands from the red path.
    assign yellow_mask_next = metadata_compare_pipe_reg[XY_WIDTH] &&
        yellow_candidate_compare_pipe_reg &&
        (saturation_delta_pipe_reg >= saturation_limit_pipe_reg);

    assign yellow_mask_o = yellow_mask_pipe_reg;
    assign red_mask_o    = red_mask_pipe_reg;
    assign green_mask_o  = green_mask_pipe_reg;
    assign pixel_valid_o = metadata_output_pipe_reg[XY_WIDTH];
    assign pixel_x_o     = metadata_output_pipe_reg[X_WIDTH-1:0];
    assign pixel_y_o     = metadata_output_pipe_reg[XY_WIDTH-1:X_WIDTH];
    assign frame_start_o = metadata_output_pipe_reg[XY_WIDTH+1];
    assign frame_end_o   = metadata_output_pipe_reg[XY_WIDTH+2];
    assign frame_abort_o = metadata_output_pipe_reg[XY_WIDTH+3];

    // Equal green/red floors share the operand; half floors reuse a shift.
    // Other green floors use the constant shift/add pipeline below.
    generate
        if (GREEN_S_MIN == S_MIN) begin : green_saturation_shared
            assign green_saturation_limit = saturation_limit_pipe_reg;
        end else if (({1'b0, GREEN_S_MIN} << 4'd1) == {1'b0, S_MIN}) begin : green_saturation_half
            assign green_saturation_limit = {1'b0, saturation_limit_pipe_reg[15:1]};
        end else begin : green_saturation_independent
            wire [15:0] maximum_extended;
            wire [15:0] low_sum, high_sum;
            reg [15:0] low_pipe_reg = 16'd0;
            reg [15:0] high_pipe_reg = 16'd0;
            reg [15:0] limit_pipe_reg = 16'd0;
            assign maximum_extended = {8'd0, max_extrema_pipe_reg};
            assign low_sum =
                ((GREEN_S_MIN[0] ? maximum_extended : 16'd0) +
                 (GREEN_S_MIN[1] ? (maximum_extended << 4'd1) : 16'd0)) +
                ((GREEN_S_MIN[2] ? (maximum_extended << 4'd2) : 16'd0) +
                 (GREEN_S_MIN[3] ? (maximum_extended << 4'd3) : 16'd0));
            assign high_sum =
                ((GREEN_S_MIN[4] ? (maximum_extended << 4'd4) : 16'd0) +
                 (GREEN_S_MIN[5] ? (maximum_extended << 4'd5) : 16'd0)) +
                ((GREEN_S_MIN[6] ? (maximum_extended << 4'd6) : 16'd0) +
                 (GREEN_S_MIN[7] ? (maximum_extended << 4'd7) : 16'd0));
            assign green_saturation_limit = limit_pipe_reg;
            always @(posedge clk) begin
                low_pipe_reg <= low_sum;
                high_pipe_reg <= high_sum;
                limit_pipe_reg <= low_pipe_reg + high_pipe_reg;
                if (rst) begin
                    low_pipe_reg <= 16'd0;
                    high_pipe_reg <= 16'd0;
                    limit_pipe_reg <= 16'd0;
                end
            end
        end
    endgenerate

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
        green_max_extrema_pipe_reg <= green_is_max;
        green_abs_extrema_pipe_reg <= red_blue_abs;
        yellow_abs_extrema_pipe_reg <= red_green_abs;
        yellow_min_extrema_pipe_reg <= blue_is_min;
        metadata_extrema_pipe_reg <= metadata_input_pipe_reg;
        if (rst) begin
            max_extrema_pipe_reg      <= 8'd0;
            min_extrema_pipe_reg      <= 8'd0;
            abs_extrema_pipe_reg      <= 8'd0;
            red_max_extrema_pipe_reg  <= 1'b0;
            green_max_extrema_pipe_reg <= 1'b0;
            green_abs_extrema_pipe_reg <= 8'd0;
            yellow_abs_extrema_pipe_reg <= 8'd0;
            yellow_min_extrema_pipe_reg <= 1'b0;
            metadata_extrema_pipe_reg <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        delta_scale_pipe_reg     <= delta_scale_next;
        hue_scale_pipe_reg       <= hue_scale_next;
        saturation_low_pipe_reg  <= saturation_low_sum;
        saturation_high_pipe_reg <= saturation_high_sum;
        candidate_scale_pipe_reg <= candidate_scale_next;
        green_hue_scale_pipe_reg <= green_hue_scale_next;
        green_candidate_scale_pipe_reg <= green_candidate_scale_next;
        yellow_hue_scale_pipe_reg <= yellow_hue_scale_next;
        yellow_candidate_scale_pipe_reg <= yellow_candidate_scale_next;
        metadata_scale_pipe_reg  <= metadata_extrema_pipe_reg;
        if (rst) begin
            delta_scale_pipe_reg     <= 8'd0;
            hue_scale_pipe_reg       <= 10'd0;
            saturation_low_pipe_reg  <= 12'd0;
            saturation_high_pipe_reg <= 16'd0;
            candidate_scale_pipe_reg <= 1'b0;
            green_hue_scale_pipe_reg <= 10'd0;
            green_candidate_scale_pipe_reg <= 1'b0;
            yellow_hue_scale_pipe_reg <= 10'd0;
            yellow_candidate_scale_pipe_reg <= 1'b0;
            metadata_scale_pipe_reg  <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        saturation_delta_pipe_reg  <= saturation_delta_next;
        saturation_limit_pipe_reg  <= saturation_limit_next;
        candidate_compare_pipe_reg <= candidate_compare_next;
        green_candidate_compare_pipe_reg <= green_candidate_compare_next;
        yellow_candidate_compare_pipe_reg <= yellow_candidate_compare_next;
        metadata_compare_pipe_reg  <= metadata_scale_pipe_reg;
        if (rst) begin
            saturation_delta_pipe_reg  <= 16'd0;
            saturation_limit_pipe_reg  <= 16'd0;
            candidate_compare_pipe_reg <= 1'b0;
            green_candidate_compare_pipe_reg <= 1'b0;
            yellow_candidate_compare_pipe_reg <= 1'b0;
            metadata_compare_pipe_reg  <= {META_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        red_mask_pipe_reg        <= red_mask_next;
        green_mask_pipe_reg <= green_mask_next;
        yellow_mask_pipe_reg <= yellow_mask_next;
        metadata_output_pipe_reg <= metadata_compare_pipe_reg;
        if (rst) begin
            red_mask_pipe_reg        <= 1'b0;
            green_mask_pipe_reg <= 1'b0;
            yellow_mask_pipe_reg <= 1'b0;
            metadata_output_pipe_reg <= {META_WIDTH{1'b0}};
        end
    end

endmodule

`resetall
