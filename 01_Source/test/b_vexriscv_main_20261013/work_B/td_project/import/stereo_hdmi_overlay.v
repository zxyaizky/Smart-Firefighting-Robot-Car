// -----------------------------------------------------------------------------
// File   : stereo_hdmi_overlay.v
// Author : Codex
// Date   : 2026-10-02
// -----------------------------------------------------------------------------
// Description:
//   RIGHT-to-LEFT projected bbox with a compact distance label at its upper-left.
//   Reuses combinational osd_char_lib; serial binary-to-BCD uses only registers.
//   RGB is combinational with zero pixel latency. Sync/DE stay outside this block.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-02  Codex  v1.0  Latest-result HDMI debug overlay
//   2026-10-02  Codex  v1.1  Transparent lower-left status and actual progress counters
//   2026-10-03  Codex  v1.2  Last valid sync identities above the existing panel
//   2026-10-03  Codex  v1.3  Remove debug panel; attach D and Z to moving bbox
//   2026-10-05  Codex  v1.4  Separate stable label disparity from raw bbox projection
//   2026-10-06  Codex  v1.5  Bounded coverage padding and frame-coherent geometry
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_hdmi_overlay #
(
    // Inward border width in HDMI pixels.
    parameter [10:0] BOX_THICKNESS = 11'd3,
    // RGB888 bbox colour.
    parameter [23:0] BOX_COLOR = 24'h00ff00,
    parameter [23:0] TEXT_COLOR = 24'hffffff,
    parameter LABEL_DISPARITY_SEPARATE = 0,
    // Optional display-only coverage correction; legacy geometry is the default.
    parameter BOX_COVERAGE_ENABLE = 0,
    // Padding units are original 160x90 pixels, before the eightfold scale.
    parameter integer BOX_PAD_BASE_PIXELS = 2,
    parameter integer BOX_PAD_REL_SHIFT = 4,
    parameter integer BOX_PAD_MAX_PIXELS = 8,
    // Installation compensation only; defaults do not invent a calibration.
    parameter integer BOX_OFFSET_X_PIXELS = 0,
    parameter integer BOX_OFFSET_Y_PIXELS = 0,
    // Publish a whole converted result during vertical sync, never mid-frame.
    parameter FRAME_ATOMIC_UPDATE = 0
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire [10:0] pixel_x_i,
    input  wire [9:0]  pixel_y_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] rgb_i,
    input  wire        bbox_valid_i,
    input  wire [7:0]  bbox_x1_i,
    input  wire [6:0]  bbox_y1_i,
    input  wire [7:0]  bbox_x2_i,
    input  wire [6:0]  bbox_y2_i,
    input  wire        range_valid_i,
    input  wire [5:0]  disparity_i,
    input  wire [15:0] distance_mm_i,
    input  wire        result_seen_i,
    input  wire [15:0] update_count_i,
    input  wire [15:0] pair_sync_id_i,
    output wire [23:0] rgb_o,
    input  wire [5:0]  label_disparity_i,
    input  wire        frame_start_i
);
    // Publish metadata and its digits together after a 16-cycle conversion.
    wire [92:0] incoming;
    reg [92:0] job_reg = 93'd0, job_next;
    reg [92:0] display_reg = 93'd0, display_next;
    reg [42:0] geometry_reg = 43'd0, geometry_next;
    reg pending_reg = 1'b0, pending_next;
    reg [92:0] pending_tuple_reg = 93'd0, pending_tuple_next;
    reg [42:0] pending_geometry_reg = 43'd0, pending_geometry_next;
    reg [19:0] pending_bcd_reg = 20'd0, pending_bcd_next;
    reg [35:0] convert_reg = 36'd0, convert_next;
    reg [19:0] distance_bcd_reg = 20'd0, distance_bcd_next;
    reg [4:0] cycles_reg = 5'd0, cycles_next;
    reg [35:0] adjusted = 36'd0;
    reg [35:0] shifted = 36'd0;
    integer digit_index;
    wire range_valid;
    wire projected_visible;
    wire [42:0] job_geometry;
    wire result_seen;
    wire protected_osd;
    wire [3:0] text_column;
    wire [7:0] disparity_digits;
    wire label_visible;
    wire [2:0] number_digits;
    wire [7:0] label_width;
    wire [10:0] label_x;
    wire [9:0] label_y;
    wire [10:0] hdmi_x1;
    wire [10:0] hdmi_x2;
    wire [9:0] hdmi_y1;
    wire [9:0] hdmi_y2;
    wire inside_box;
    wire border;
    wire panel;
    wire [3:0] font_row;
    wire [10:0] text_x;
    wire [9:0] text_y;
    reg [7:0] character = 8'h20;
    wire [15:0] font_bits;
    wire glyph;
    reg [23:0] rgb_next = 24'd0;

    function [7:0] disparity_bcd;
        input [5:0] value;
        reg [3:0] tens;
        reg [5:0] units;
        begin
            tens = 4'd0;
            units = value;
            if (value >= 6'd60) begin tens = 4'd6; units = value - 6'd60; end
            else if (value >= 6'd50) begin tens = 4'd5; units = value - 6'd50; end
            else if (value >= 6'd40) begin tens = 4'd4; units = value - 6'd40; end
            else if (value >= 6'd30) begin tens = 4'd3; units = value - 6'd30; end
            else if (value >= 6'd20) begin tens = 4'd2; units = value - 6'd20; end
            else if (value >= 6'd10) begin tens = 4'd1; units = value - 6'd10; end
            disparity_bcd = {tens, units[3:0]};
        end
    endfunction

    assign disparity_digits = disparity_bcd(LABEL_DISPARITY_SEPARATE != 0 ?
                                            display_reg[92:87] : display_reg[21:16]);

    assign incoming = {LABEL_DISPARITY_SEPARATE != 0 ? label_disparity_i : disparity_i,
                       result_seen_i, update_count_i, pair_sync_id_i,
                       bbox_valid_i, bbox_x1_i, bbox_y1_i, bbox_x2_i, bbox_y2_i,
                       range_valid_i, disparity_i, distance_mm_i};
    assign result_seen = display_reg[86];
    assign range_valid = display_reg[22];
    // Geometry is calculated from the same job as the digits and registered
    // before pixel comparisons. There is no padding arithmetic in the RGB path.
    assign {projected_visible, hdmi_x1, hdmi_x2, hdmi_y1, hdmi_y2} = geometry_reg;
    assign inside_box = result_seen && projected_visible && range_valid &&
                        pixel_x_i >= hdmi_x1 &&
                        pixel_x_i <= hdmi_x2 && pixel_y_i >= hdmi_y1 && pixel_y_i <= hdmi_y2;
    // Unsigned differences are used only inside the inclusive rectangle.
    assign border = inside_box && ((pixel_x_i - hdmi_x1 < BOX_THICKNESS) ||
                    (hdmi_x2 - pixel_x_i < BOX_THICKNESS) ||
                    ({1'b0, pixel_y_i} - {1'b0, hdmi_y1} < BOX_THICKNESS) ||
                    ({1'b0, hdmi_y2} - {1'b0, pixel_y_i} < BOX_THICKNESS));
    // Existing UI keeps priority even if a projected bbox crosses it.
    assign protected_osd =
        (pixel_x_i < 11'd160 && pixel_y_i < 10'd160) ||
        (pixel_x_i >= 11'd1080 && pixel_x_i < 11'd1260 &&
         pixel_y_i >= 10'd24 && pixel_y_i < 10'd55) ||
        (pixel_x_i >= 11'd1080 && pixel_x_i < 11'd1264 &&
         pixel_y_i >= 10'd80 && pixel_y_i < 10'd136) ||
        (pixel_x_i >= 11'd1088 && pixel_x_i < 11'd1264 &&
         pixel_y_i >= 10'd642 && pixel_y_i < 10'd704) ||
        (pixel_x_i >= 11'd375 && pixel_x_i < 11'd575 &&
         pixel_y_i >= 10'd120 && pixel_y_i < 10'd144);
    // One transparent label: D:08 Z:892MM. Z has no leading zeroes.
    // Put it just above the upper-left corner, or inside when the box touches top.
    assign number_digits = distance_bcd_reg[19:16] != 4'd0 ? 3'd5 :
                           distance_bcd_reg[15:12] != 4'd0 ? 3'd4 :
                           distance_bcd_reg[11:8] != 4'd0 ? 3'd3 :
                           distance_bcd_reg[7:4] != 4'd0 ? 3'd2 : 3'd1;
    assign label_width = {1'b0, number_digits, 4'b0000} + 8'd144;
    assign label_x = hdmi_x1 <= 11'd1280 - {3'd0, label_width} ?
                     hdmi_x1 : 11'd1280 - {3'd0, label_width};
    assign label_y = hdmi_y1 >= 10'd18 ? hdmi_y1 - 10'd18 : hdmi_y1 + 10'd4;
    assign label_visible = result_seen && projected_visible && range_valid;
    assign panel = label_visible && pixel_x_i >= label_x &&
                   pixel_x_i < label_x + {3'd0, label_width} &&
                   pixel_y_i >= label_y && pixel_y_i < label_y + 10'd16;
    assign text_x = pixel_x_i - label_x;
    assign text_y = pixel_y_i - label_y;
    assign font_row = text_y[3:0];
    assign text_column = text_x[7:4];
    assign glyph = font_bits[4'd15 - text_x[3:0]];
    assign rgb_o = rgb_next;

    stereo_bbox_projector #(
        .COVERAGE_ENABLE      (BOX_COVERAGE_ENABLE),
        .PADDING_BASE_PIXELS  (BOX_PAD_BASE_PIXELS),
        .PADDING_REL_SHIFT    (BOX_PAD_REL_SHIFT),
        .PADDING_MAX_PIXELS   (BOX_PAD_MAX_PIXELS),
        .OFFSET_X_PIXELS      (BOX_OFFSET_X_PIXELS),
        .OFFSET_Y_PIXELS      (BOX_OFFSET_Y_PIXELS)
    ) stereo_bbox_projector_inst (
        .bbox_valid_i   (job_reg[53]),
        .bbox_x1_i      (job_reg[52:45]),
        .bbox_y1_i      (job_reg[44:38]),
        .bbox_x2_i      (job_reg[37:30]),
        .bbox_y2_i      (job_reg[29:23]),
        .disparity_i    (job_reg[21:16]),
        .bbox_visible_o (job_geometry[42]),
        .hdmi_x1_o      (job_geometry[41:31]),
        .hdmi_x2_o      (job_geometry[30:20]),
        .hdmi_y1_o      (job_geometry[19:10]),
        .hdmi_y2_o      (job_geometry[9:0])
    );

    osd_char_lib stereo_font_inst (
        .I_char     (character),
        .I_row      (font_row),
        .O_row_bits (font_bits)
    );

    always @* begin
        job_next = job_reg;
        display_next = display_reg;
        geometry_next = geometry_reg;
        pending_next = pending_reg;
        pending_tuple_next = pending_tuple_reg;
        pending_geometry_next = pending_geometry_reg;
        pending_bcd_next = pending_bcd_reg;
        convert_next = convert_reg;
        distance_bcd_next = distance_bcd_reg;
        cycles_next = cycles_reg;
        adjusted = convert_reg;
        shifted = 36'd0;
        if (FRAME_ATOMIC_UPDATE != 0 && frame_start_i && pending_reg) begin
            display_next = pending_tuple_reg;
            geometry_next = pending_geometry_reg;
            distance_bcd_next = pending_bcd_reg;
            pending_next = 1'b0;
        end
        if (cycles_reg == 5'd0) begin
            if (incoming != display_reg && (FRAME_ATOMIC_UPDATE == 0 ||
                !pending_reg || incoming != pending_tuple_reg)) begin
                job_next = incoming;
                convert_next = {20'd0, distance_mm_i};
                cycles_next = 5'd16;
            end
        end else begin
            for (digit_index = 0; digit_index < 5; digit_index = digit_index + 1) begin
                if (convert_reg[16 + digit_index * 4 +: 4] >= 4'd5)
                    adjusted[16 + digit_index * 4 +: 4] =
                        convert_reg[16 + digit_index * 4 +: 4] + 4'd3;
            end
            shifted = {adjusted[34:0], 1'b0};
            convert_next = shifted;
            cycles_next = cycles_reg - 5'd1;
            if (cycles_reg == 5'd1) begin
                if (FRAME_ATOMIC_UPDATE != 0 && !frame_start_i) begin
                    pending_tuple_next = job_reg;
                    pending_geometry_next = job_geometry;
                    pending_bcd_next = job_reg[86] && job_reg[22] ? shifted[35:16] : 20'd0;
                    pending_next = 1'b1;
                end else begin
                    display_next = job_reg;
                    geometry_next = job_geometry;
                    distance_bcd_next = job_reg[86] && job_reg[22] ? shifted[35:16] : 20'd0;
                    pending_next = 1'b0;
                end
            end
        end
    end

    always @(posedge clk) begin
        job_reg <= job_next;
        display_reg <= display_next;
        geometry_reg <= geometry_next;
        pending_reg <= pending_next;
        pending_tuple_reg <= pending_tuple_next;
        pending_geometry_reg <= pending_geometry_next;
        pending_bcd_reg <= pending_bcd_next;
        convert_reg <= convert_next;
        distance_bcd_reg <= distance_bcd_next;
        cycles_reg <= cycles_next;
        if (rst) begin
            job_reg <= 93'd0;
            display_reg <= 93'd0;
            geometry_reg <= 43'd0;
            pending_reg <= 1'b0;
            pending_tuple_reg <= 93'd0;
            pending_geometry_reg <= 43'd0;
            pending_bcd_reg <= 20'd0;
            convert_reg <= 36'd0;
            distance_bcd_reg <= 20'd0;
            cycles_reg <= 5'd0;
        end
    end

    // Digit selection is bounded; the pixel path has no runtime division.
    always @* begin
        character = 8'h20;
        if (panel) begin
            case (text_column)
                4'd0: character = 8'h44;
                4'd1, 4'd6: character = 8'h3a;
                4'd2: character = 8'h30 + {4'd0, disparity_digits[7:4]};
                4'd3: character = 8'h30 + {4'd0, disparity_digits[3:0]};
                4'd4: character = 8'h20;
                4'd5: character = 8'h5a;
                default: begin
                    if (text_column < {1'b0, number_digits} + 4'd7) begin
                        case ({1'b0, number_digits} + 4'd7 - text_column)
                            4'd5: character = 8'h30 + {4'd0, distance_bcd_reg[19:16]};
                            4'd4: character = 8'h30 + {4'd0, distance_bcd_reg[15:12]};
                            4'd3: character = 8'h30 + {4'd0, distance_bcd_reg[11:8]};
                            4'd2: character = 8'h30 + {4'd0, distance_bcd_reg[7:4]};
                            4'd1: character = 8'h30 + {4'd0, distance_bcd_reg[3:0]};
                            default: character = 8'h20;
                        endcase
                    end else if (text_column < {1'b0, number_digits} + 4'd9) begin
                        character = 8'h4d;
                    end
                end
            endcase
        end
    end

    always @* begin
        rgb_next = rgb_i;
        if (pixel_valid_i && !rst && !protected_osd) begin
            if (border) rgb_next = BOX_COLOR;
            if (panel && glyph) rgb_next = TEXT_COLOR;
        end
    end
endmodule
`resetall
