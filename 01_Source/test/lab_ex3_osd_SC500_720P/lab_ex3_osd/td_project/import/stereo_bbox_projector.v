// -----------------------------------------------------------------------------
// File   : stereo_bbox_projector.v
// Author : Codex
// Date   : 2026-10-06
// -----------------------------------------------------------------------------
// Description:
//   Combinational RIGHT-to-LEFT display bbox projection at 160x90 resolution.
//   Legacy mapping is the default. Optional bounded padding and signed offsets
//   enlarge only display geometry; fully off-screen rectangles stay invisible.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-06  Codex  v1.0  Add independent display-only bbox coverage projection
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_bbox_projector #
(
    // Zero preserves the original endpoint saturation without padding or offsets.
    parameter integer COVERAGE_ENABLE = 0,
    // Minimum padding on each side, in native 160x90 pixels.
    parameter integer PADDING_BASE_PIXELS = 2,
    // Add ceil(inclusive dimension / 2**shift) padding independently on each axis.
    parameter integer PADDING_REL_SHIFT = 4,
    // Maximum combined base and relative padding on each side, in native pixels.
    parameter integer PADDING_MAX_PIXELS = 8,
    // Signed horizontal display correction, in native pixels.
    parameter integer OFFSET_X_PIXELS = 0,
    // Signed vertical display correction, in native pixels.
    parameter integer OFFSET_Y_PIXELS = 0
)
(
    input  wire        bbox_valid_i,
    input  wire [7:0]  bbox_x1_i,
    input  wire [6:0]  bbox_y1_i,
    input  wire [7:0]  bbox_x2_i,
    input  wire [6:0]  bbox_y2_i,
    input  wire [5:0]  disparity_i,
    output wire        bbox_visible_o,
    output wire [10:0] hdmi_x1_o,
    output wire [9:0]  hdmi_y1_o,
    output wire [10:0] hdmi_x2_o,
    output wire [9:0]  hdmi_y2_o
);

    wire bbox_ordered;

    assign bbox_ordered = bbox_x1_i <= bbox_x2_i && bbox_y1_i <= bbox_y2_i;

    generate
        if (COVERAGE_ENABLE == 0) begin : gen_legacy_mapping
            wire [8:0] sum_x1;
            wire [8:0] sum_x2;
            wire [7:0] left_x1;
            wire [7:0] left_x2;
            wire [6:0] left_y1;
            wire [6:0] left_y2;

            assign sum_x1 = {1'b0, bbox_x1_i} + {3'd0, disparity_i};
            assign sum_x2 = {1'b0, bbox_x2_i} + {3'd0, disparity_i};
            assign left_x1 = sum_x1 > 9'd159 ? 8'd159 : sum_x1[7:0];
            assign left_x2 = sum_x2 > 9'd159 ? 8'd159 : sum_x2[7:0];
            assign left_y1 = bbox_y1_i > 7'd89 ? 7'd89 : bbox_y1_i;
            assign left_y2 = bbox_y2_i > 7'd89 ? 7'd89 : bbox_y2_i;

            assign bbox_visible_o = bbox_valid_i && bbox_ordered;
            assign hdmi_x1_o = {left_x1, 3'b000};
            assign hdmi_x2_o = {left_x2, 3'b111};
            assign hdmi_y1_o = {left_y1, 3'b000};
            assign hdmi_y2_o = {left_y2, 3'b111};
        end else begin : gen_coverage_mapping
            // Integer offsets and padding may reach their signed 32-bit limits.
            // Explicit 35-bit arithmetic also preserves offset +/- padding carry.
            localparam signed [34:0] OFFSET_X_EXTENDED =
                {{3{OFFSET_X_PIXELS[31]}}, OFFSET_X_PIXELS};
            localparam signed [34:0] OFFSET_Y_EXTENDED =
                {{3{OFFSET_Y_PIXELS[31]}}, OFFSET_Y_PIXELS};
            localparam signed [34:0] BASE_PADDING_EXTENDED =
                {{3{PADDING_BASE_PIXELS[31]}}, PADDING_BASE_PIXELS};
            localparam signed [34:0] MAX_PADDING_EXTENDED =
                {{3{PADDING_MAX_PIXELS[31]}}, PADDING_MAX_PIXELS};

            wire source_legal;
            wire [8:0] inclusive_width;
            wire [7:0] inclusive_height;
            wire [8:0] relative_padding_x;
            wire [7:0] relative_padding_y;
            wire signed [34:0] requested_padding_x;
            wire signed [34:0] requested_padding_y;
            wire signed [34:0] padding_x;
            wire signed [34:0] padding_y;
            wire signed [34:0] projected_x1;
            wire signed [34:0] projected_x2;
            wire signed [34:0] projected_y1;
            wire signed [34:0] projected_y2;
            wire intersects_image;
            wire [7:0] clipped_x1;
            wire [7:0] clipped_x2;
            wire [6:0] clipped_y1;
            wire [6:0] clipped_y2;
            wire visible;

            assign source_legal = bbox_ordered && bbox_x2_i <= 8'd159 &&
                                  bbox_y2_i <= 7'd89;
            assign inclusive_width = {1'b0, bbox_x2_i} - {1'b0, bbox_x1_i} + 9'd1;
            assign inclusive_height = {1'b0, bbox_y2_i} - {1'b0, bbox_y1_i} + 8'd1;
            // For positive dimensions, ceil(n / 2**shift) == ((n - 1) >> shift) + 1.
            assign relative_padding_x = ((inclusive_width - 9'd1) >> PADDING_REL_SHIFT) +
                                        9'd1;
            assign relative_padding_y = ((inclusive_height - 8'd1) >> PADDING_REL_SHIFT) +
                                        8'd1;
            assign requested_padding_x = BASE_PADDING_EXTENDED +
                                         $signed({26'd0, relative_padding_x});
            assign requested_padding_y = BASE_PADDING_EXTENDED +
                                         $signed({27'd0, relative_padding_y});
            assign padding_x = requested_padding_x > MAX_PADDING_EXTENDED ?
                               MAX_PADDING_EXTENDED : requested_padding_x;
            assign padding_y = requested_padding_y > MAX_PADDING_EXTENDED ?
                               MAX_PADDING_EXTENDED : requested_padding_y;

            assign projected_x1 = $signed({27'd0, bbox_x1_i}) +
                                  $signed({29'd0, disparity_i}) + OFFSET_X_EXTENDED - padding_x;
            assign projected_x2 = $signed({27'd0, bbox_x2_i}) +
                                  $signed({29'd0, disparity_i}) + OFFSET_X_EXTENDED + padding_x;
            assign projected_y1 = $signed({28'd0, bbox_y1_i}) + OFFSET_Y_EXTENDED - padding_y;
            assign projected_y2 = $signed({28'd0, bbox_y2_i}) + OFFSET_Y_EXTENDED + padding_y;

            // Intersection is checked BEFORE clipping, so disjoint rectangles
            // cannot turn into a narrow false bbox at the nearest image edge.
            assign intersects_image = projected_x2 >= 35'sd0 && projected_x1 <= 35'sd159 &&
                                      projected_y2 >= 35'sd0 && projected_y1 <= 35'sd89;
            assign clipped_x1 = projected_x1 < 35'sd0 ? 8'd0 :
                                projected_x1 > 35'sd159 ? 8'd159 : projected_x1[7:0];
            assign clipped_x2 = projected_x2 < 35'sd0 ? 8'd0 :
                                projected_x2 > 35'sd159 ? 8'd159 : projected_x2[7:0];
            assign clipped_y1 = projected_y1 < 35'sd0 ? 7'd0 :
                                projected_y1 > 35'sd89 ? 7'd89 : projected_y1[6:0];
            assign clipped_y2 = projected_y2 < 35'sd0 ? 7'd0 :
                                projected_y2 > 35'sd89 ? 7'd89 : projected_y2[6:0];
            assign visible = bbox_valid_i && source_legal && intersects_image;

            assign bbox_visible_o = visible;
            assign hdmi_x1_o = visible ? {clipped_x1, 3'b000} : 11'd0;
            assign hdmi_x2_o = visible ? {clipped_x2, 3'b111} : 11'd0;
            assign hdmi_y1_o = visible ? {clipped_y1, 3'b000} : 10'd0;
            assign hdmi_y2_o = visible ? {clipped_y2, 3'b111} : 10'd0;
        end
    endgenerate

    // Parameter checks are simulation-only; the datapath has no clock or storage.
    // synthesis translate_off
    initial begin
        if ((COVERAGE_ENABLE != 0 && COVERAGE_ENABLE != 1) ||
            PADDING_BASE_PIXELS < 0 || PADDING_MAX_PIXELS < 0 ||
            PADDING_REL_SHIFT < 0 || PADDING_REL_SHIFT > 31) begin
            $display("FAIL stereo_bbox_projector invalid parameters (instance %m)");
            $finish;
        end
    end
    // synthesis translate_on

endmodule

`resetall
