// -----------------------------------------------------------------------------
// File   : max30102_status_osd.v
// Author : Codex
// Date   : 2026-09-29
// -----------------------------------------------------------------------------
// Description:
//   Draw a compact HR / SpO2 card in the upper-right active picture.
//   Inputs are pixel-clock domain BCD values and persistent valid levels.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-12  Codex  v1.3  Transparent text; retain existing glyphs and colours
//   2026-09-29  Codex  v1.0  Initial implementation
//   2026-09-29  Codex  v1.1  Compact aligned card with distinct value colors
//   2026-10-01  Codex  v1.2  Allow placement below the existing algorithm panel
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_status_osd #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer PANEL_TOP = 16
)(
    input  wire        video_de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [11:0] heart_rate_bcd,
    input  wire        heart_rate_display_valid,
    input  wire [11:0] spo2_bcd,
    input  wire        spo2_display_valid,
    output wire        overlay_enable,
    output wire [23:0] overlay_rgb
);
    localparam [11:0] H_LIMIT = H_ACTIVE[11:0];
    localparam [11:0] V_LIMIT = V_ACTIVE[11:0];
    localparam [11:0] PANEL_X = H_LIMIT - 12'd200;
    localparam [11:0] PANEL_Y = PANEL_TOP[11:0];
    localparam [11:0] PANEL_W = 12'd184;
    localparam [11:0] PANEL_H = 12'd56;
    localparam [11:0] LABEL_X = PANEL_X + 12'd14;
    localparam [11:0] VALUE_X = PANEL_X + 12'd80;
    localparam [11:0] UNIT_X = PANEL_X + 12'd136;
    localparam [11:0] HR_Y = PANEL_Y + 12'd9;
    localparam [11:0] SPO2_Y = PANEL_Y + 12'd33;
    localparam [11:0] SUB2_X = LABEL_X + 12'd28;
    localparam [11:0] SUB2_Y = SPO2_Y + 12'd8;
    localparam [23:0] COLOR_BACKGROUND = 24'h0d1c27;
    localparam [23:0] COLOR_BORDER = 24'h3b5964;
    localparam [23:0] COLOR_DIVIDER = 24'h27424d;
    localparam [23:0] COLOR_LABEL = 24'ha8c0c9;
    localparam [23:0] COLOR_VALUE = 24'hf7fbff;
    localparam [23:0] COLOR_HR = 24'hff8d78;
    localparam [23:0] COLOR_SPO2 = 24'h57dec7;
    localparam [7:0] CHAR_DASH = 8'h2d;
    localparam [7:0] CHAR_ZERO = 8'h30;
    localparam [7:0] CHAR_PERCENT = 8'h25;
    reg [7:0] char_code;
    reg [3:0] char_column;
    reg [3:0] char_row;
    reg [1:0] text_style;
    reg text_active;
    reg [4:0] subscript_row_bits;
    wire [15:0] glyph_row_bits;
    wire inside_picture;
    wire inside_panel;
    wire glyph_hit;
    wire subscript_hit;
    wire panel_border;
    wire panel_divider;
    wire hr_accent;
    wire spo2_accent;
    wire [2:0] subscript_column;

    assign inside_picture = video_de && (pixel_x < H_LIMIT) &&
                            (pixel_y < V_LIMIT);
    assign inside_panel = (pixel_x >= PANEL_X) &&
                          (pixel_x < PANEL_X + PANEL_W) &&
                          (pixel_y >= PANEL_Y) &&
                          (pixel_y < PANEL_Y + PANEL_H);
    // Only letters, digits, units and the subscript overwrite video pixels.
    assign overlay_enable = inside_picture && inside_panel &&
                            (glyph_hit || subscript_hit);
    assign glyph_hit = text_active && glyph_row_bits[4'd15 - char_column];
    assign subscript_column = pixel_x - SUB2_X;
    assign subscript_hit = (pixel_x >= SUB2_X) &&
                           (pixel_x < SUB2_X + 12'd5) &&
                           (pixel_y >= SUB2_Y) &&
                           (pixel_y < SUB2_Y + 12'd7) &&
                           subscript_row_bits[3'd4 - subscript_column];
    assign panel_border = (pixel_x == PANEL_X) ||
                          (pixel_x == PANEL_X + PANEL_W - 12'd1) ||
                          (pixel_y == PANEL_Y) ||
                          (pixel_y == PANEL_Y + PANEL_H - 12'd1);
    assign panel_divider = (pixel_y == PANEL_Y + 12'd28) &&
                           (pixel_x >= PANEL_X + 12'd12) &&
                           (pixel_x < PANEL_X + PANEL_W - 12'd12);
    assign hr_accent = (pixel_x >= PANEL_X + 12'd6) &&
                       (pixel_x < PANEL_X + 12'd9) &&
                       (pixel_y >= HR_Y + 12'd1) &&
                       (pixel_y < HR_Y + 12'd13);
    assign spo2_accent = (pixel_x >= PANEL_X + 12'd6) &&
                         (pixel_x < PANEL_X + 12'd9) &&
                         (pixel_y >= SPO2_Y + 12'd1) &&
                         (pixel_y < SPO2_Y + 12'd13);

    assign overlay_rgb = glyph_hit ?
                         ((text_style == 2'd0) ? COLOR_LABEL :
                          (text_style == 2'd1) ? COLOR_VALUE :
                          (text_style == 2'd2) ? COLOR_HR : COLOR_SPO2) :
                         subscript_hit ? COLOR_LABEL :
                         panel_border ? COLOR_BORDER :
                         hr_accent ? COLOR_HR :
                         spo2_accent ? COLOR_SPO2 :
                         panel_divider ? COLOR_DIVIDER : COLOR_BACKGROUND;

    osd_char_lib font_inst (
        .I_char     (char_code),
        .I_row      (char_row),
        .O_row_bits (glyph_row_bits)
    );

    always @* begin
        case (pixel_y - SUB2_Y)
            12'd0: subscript_row_bits = 5'b01110;
            12'd1: subscript_row_bits = 5'b10001;
            12'd2: subscript_row_bits = 5'b00001;
            12'd3: subscript_row_bits = 5'b00010;
            12'd4: subscript_row_bits = 5'b00100;
            12'd5: subscript_row_bits = 5'b01000;
            12'd6: subscript_row_bits = 5'b11111;
            default: subscript_row_bits = 5'b00000;
        endcase
    end

    always @* begin
        text_active = 1'b0;
        text_style = 2'd0;
        char_column = 4'd0;
        char_row = 4'd0;
        char_code = 8'h20;

        // The letters occupy only about six columns in osd_char_lib; a
        // nine-pixel pitch removes the large gaps visible in the old OSD.
        if ((pixel_y >= HR_Y + 12'd3) &&
            (pixel_y < HR_Y + 12'd19)) begin
            char_row = pixel_y - (HR_Y + 12'd3);
            if (pixel_x >= LABEL_X && pixel_x < LABEL_X + 12'd9) begin
                text_active = 1'b1;
                char_code = "H";
                char_column = pixel_x - LABEL_X;
            end else if (pixel_x >= LABEL_X + 12'd9 &&
                         pixel_x < LABEL_X + 12'd18) begin
                text_active = 1'b1;
                char_code = "R";
                char_column = pixel_x - (LABEL_X + 12'd9);
            end else if (pixel_x >= UNIT_X &&
                         pixel_x < UNIT_X + 12'd9) begin
                text_active = 1'b1;
                text_style = 2'd2;
                char_code = "B";
                char_column = pixel_x - UNIT_X;
            end else if (pixel_x >= UNIT_X + 12'd9 &&
                         pixel_x < UNIT_X + 12'd18) begin
                text_active = 1'b1;
                text_style = 2'd2;
                char_code = "P";
                char_column = pixel_x - (UNIT_X + 12'd9);
            end else if (pixel_x >= UNIT_X + 12'd18 &&
                         pixel_x < UNIT_X + 12'd27) begin
                text_active = 1'b1;
                text_style = 2'd2;
                char_code = "M";
                char_column = pixel_x - (UNIT_X + 12'd18);
            end
        end
        if ((pixel_y >= SPO2_Y + 12'd3) &&
            (pixel_y < SPO2_Y + 12'd19)) begin
            char_row = pixel_y - (SPO2_Y + 12'd3);
            if (pixel_x >= LABEL_X && pixel_x < LABEL_X + 12'd9) begin
                text_active = 1'b1;
                char_code = "S";
                char_column = pixel_x - LABEL_X;
            end else if (pixel_x >= LABEL_X + 12'd9 &&
                         pixel_x < LABEL_X + 12'd18) begin
                text_active = 1'b1;
                char_code = "P";
                char_column = pixel_x - (LABEL_X + 12'd9);
            end else if (pixel_x >= LABEL_X + 12'd18 &&
                         pixel_x < LABEL_X + 12'd27) begin
                text_active = 1'b1;
                char_code = "O";
                char_column = pixel_x - (LABEL_X + 12'd18);
            end
        end

        // Numeric glyphs occupy about twelve columns, so retain fourteen
        // pixels per digit for a compact but legible three-digit result.
        if (((pixel_y >= HR_Y) && (pixel_y < HR_Y + 12'd16)) ||
            ((pixel_y >= SPO2_Y) && (pixel_y < SPO2_Y + 12'd16))) begin
            char_row = (pixel_y >= SPO2_Y) ? pixel_y - SPO2_Y :
                                               pixel_y - HR_Y;
            if (pixel_x >= VALUE_X && pixel_x < VALUE_X + 12'd14) begin
                text_active = 1'b1;
                text_style = 2'd1;
                char_code = (pixel_y >= SPO2_Y) ?
                    (spo2_display_valid ?
                     CHAR_ZERO + {4'd0, spo2_bcd[11:8]} : CHAR_DASH) :
                    (heart_rate_display_valid ?
                     CHAR_ZERO + {4'd0, heart_rate_bcd[11:8]} : CHAR_DASH);
                char_column = pixel_x - VALUE_X;
            end else if (pixel_x >= VALUE_X + 12'd14 &&
                         pixel_x < VALUE_X + 12'd28) begin
                text_active = 1'b1;
                text_style = 2'd1;
                char_code = (pixel_y >= SPO2_Y) ?
                    (spo2_display_valid ?
                     CHAR_ZERO + {4'd0, spo2_bcd[7:4]} : CHAR_DASH) :
                    (heart_rate_display_valid ?
                     CHAR_ZERO + {4'd0, heart_rate_bcd[7:4]} : CHAR_DASH);
                char_column = pixel_x - (VALUE_X + 12'd14);
            end else if (pixel_x >= VALUE_X + 12'd28 &&
                         pixel_x < VALUE_X + 12'd42) begin
                text_active = 1'b1;
                text_style = 2'd1;
                char_code = (pixel_y >= SPO2_Y) ?
                    (spo2_display_valid ?
                     CHAR_ZERO + {4'd0, spo2_bcd[3:0]} : CHAR_DASH) :
                    (heart_rate_display_valid ?
                     CHAR_ZERO + {4'd0, heart_rate_bcd[3:0]} : CHAR_DASH);
                char_column = pixel_x - (VALUE_X + 12'd28);
            end
        end
        if ((pixel_y >= SPO2_Y + 12'd1) &&
            (pixel_y < SPO2_Y + 12'd17) &&
            (pixel_x >= UNIT_X) &&
            (pixel_x < UNIT_X + 12'd16)) begin
            text_active = 1'b1;
            text_style = 2'd3;
            char_code = CHAR_PERCENT;
            char_row = pixel_y - (SPO2_Y + 12'd1);
            char_column = pixel_x - UNIT_X;
        end
    end
endmodule

`resetall
