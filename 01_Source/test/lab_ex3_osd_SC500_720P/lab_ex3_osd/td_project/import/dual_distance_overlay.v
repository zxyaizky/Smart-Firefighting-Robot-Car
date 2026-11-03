// -----------------------------------------------------------------------------
// File   : dual_distance_overlay.v
// Author : Codex
// Date   : 2026-10-08
// -----------------------------------------------------------------------------
// Description:
//   Two independent millimetre readings in a small bottom-left panel. Serial
//   BCD conversion and vertical-blank publication avoid mixed digits per frame.
//   RGB is combinational: no additional video, sync or DE latency.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-12  Codex  v1.3  Transparent background; draw glyph pixels only
//   2026-10-08  Codex  v1.0  Stereo and US-100 comparison display
//   2026-10-12  Codex  v1.2  Uniform 10x14 glyphs in both 16x16 text rows
//   2026-10-11  Codex  v1.1  Parameterized ultrasonic label for HC-SR04 trial
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module dual_distance_overlay #
(
    // Fits below the picture without covering the existing corner indicators.
    parameter [10:0] PANEL_X = 11'd16,
    parameter [9:0] PANEL_Y = 10'd648,
    // Text colours distinguish the independent sensors.
    parameter [23:0] STEREO_COLOR = 24'h00ff00,
    parameter [23:0] ULTRASONIC_COLOR = 24'h00ffff,
    // Seven ASCII characters; retain the original US-100 label by default.
    parameter [55:0] ULTRASONIC_LABEL = "US100: "
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start_i,
    input  wire [10:0] pixel_x_i,
    input  wire [9:0]  pixel_y_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] rgb_i,
    input  wire        stereo_valid_i,
    input  wire [15:0] stereo_mm_i,
    input  wire        ultrasonic_valid_i,
    input  wire [15:0] ultrasonic_mm_i,
    output wire [23:0] rgb_o
);
    wire [33:0] incoming;
    reg [33:0] job_reg = 34'd0, job_next;
    reg [33:0] display_reg = 34'd0, display_next;
    reg [33:0] pending_tuple_reg = 34'd0, pending_tuple_next;
    reg [35:0] convert_reg = 36'd0, convert_next;
    reg [19:0] stereo_work_reg = 20'd0, stereo_work_next;
    reg [39:0] pending_bcd_reg = 40'd0, pending_bcd_next;
    reg [39:0] display_bcd_reg = 40'd0, display_bcd_next;
    reg [5:0] cycles_reg = 6'd0, cycles_next;
    reg pending_reg = 1'b0, pending_next;
    reg [35:0] adjusted = 36'd0;
    reg [35:0] shifted = 36'd0;
    integer digit_index;
    wire first_line;
    wire second_line;
    wire panel;
    wire [10:0] text_x;
    wire [9:0] text_y;
    wire [3:0] column;
    wire [19:0] selected_bcd;
    wire selected_valid;
    wire [15:0] font_bits;
    wire glyph;
    reg [7:0] character = 8'h20;

    assign incoming = {stereo_valid_i, stereo_mm_i, ultrasonic_valid_i, ultrasonic_mm_i};
    assign first_line = pixel_y_i >= PANEL_Y && pixel_y_i < PANEL_Y + 10'd16;
    assign second_line = pixel_y_i >= PANEL_Y + 10'd24 && pixel_y_i < PANEL_Y + 10'd40;
    assign panel = pixel_x_i >= PANEL_X && pixel_x_i < PANEL_X + 11'd240 &&
        (first_line || second_line);
    assign text_x = pixel_x_i - PANEL_X;
    assign text_y = first_line ? pixel_y_i - PANEL_Y : pixel_y_i - PANEL_Y - 10'd24;
    assign column = text_x[7:4];
    assign selected_bcd = first_line ? display_bcd_reg[39:20] : display_bcd_reg[19:0];
    assign selected_valid = first_line ? display_reg[33] : display_reg[16];
    assign glyph = font_bits[4'd15 - text_x[3:0]];
    // Preserve the underlying video between glyph strokes and in text padding.
    assign rgb_o = pixel_valid_i && !rst && panel && glyph ?
        (first_line ? STEREO_COLOR : ULTRASONIC_COLOR) : rgb_i;

    // Both sensor names, digits and units share one fixed-size bitmap face.
    // 5x7 source pixels expand 2x into a centred 10x14 glyph, inside 16x16.
    // Combinational lookup only: no ROM instance or extra video latency.
    function [15:0] distance_font_row;
        input [7:0] ascii;
        input [3:0] row;
        reg [34:0] bitmap;
        reg [4:0] dots;
        begin
            bitmap = 35'd0;
            dots = 5'd0;
            case (ascii)
                8'h30: bitmap = 35'b01110_10001_10011_10101_11001_10001_01110; // 0
                8'h31: bitmap = 35'b00100_01100_00100_00100_00100_00100_01110; // 1
                8'h32: bitmap = 35'b01110_10001_00001_00010_00100_01000_11111; // 2
                8'h33: bitmap = 35'b11110_00001_00001_01110_00001_00001_11110; // 3
                8'h34: bitmap = 35'b00010_00110_01010_10010_11111_00010_00010; // 4
                8'h35: bitmap = 35'b11111_10000_10000_11110_00001_00001_11110; // 5
                8'h36: bitmap = 35'b01110_10000_10000_11110_10001_10001_01110; // 6
                8'h37: bitmap = 35'b11111_00001_00010_00100_01000_01000_01000; // 7
                8'h38: bitmap = 35'b01110_10001_10001_01110_10001_10001_01110; // 8
                8'h39: bitmap = 35'b01110_10001_10001_01111_00001_00001_01110; // 9
                8'h43: bitmap = 35'b01111_10000_10000_10000_10000_10000_01111; // C
                8'h45: bitmap = 35'b11111_10000_10000_11110_10000_10000_11111; // E
                8'h48: bitmap = 35'b10001_10001_10001_11111_10001_10001_10001; // H
                8'h4d: bitmap = 35'b10001_11011_10101_10101_10001_10001_10001; // M
                8'h4f: bitmap = 35'b01110_10001_10001_10001_10001_10001_01110; // O
                8'h52: bitmap = 35'b11110_10001_10001_11110_10100_10010_10001; // R
                8'h53: bitmap = 35'b01111_10000_10000_01110_00001_00001_11110; // S
                8'h54: bitmap = 35'b11111_00100_00100_00100_00100_00100_00100; // T
                8'h55: bitmap = 35'b10001_10001_10001_10001_10001_10001_01110; // U
                8'h2d: bitmap = 35'b00000_00000_00000_11111_00000_00000_00000; // -
                8'h3a: bitmap = 35'b00000_00100_00100_00000_00100_00100_00000; // :
                default: bitmap = 35'd0;
            endcase
            case (row)
                4'd1, 4'd2: dots = bitmap[34:30];
                4'd3, 4'd4: dots = bitmap[29:25];
                4'd5, 4'd6: dots = bitmap[24:20];
                4'd7, 4'd8: dots = bitmap[19:15];
                4'd9, 4'd10: dots = bitmap[14:10];
                4'd11, 4'd12: dots = bitmap[9:5];
                4'd13, 4'd14: dots = bitmap[4:0];
                default: dots = 5'd0;
            endcase
            distance_font_row = {3'd0, {2{dots[4]}}, {2{dots[3]}},
                {2{dots[2]}}, {2{dots[1]}}, {2{dots[0]}}, 3'd0};
        end
    endfunction
    assign font_bits = distance_font_row(character, text_y[3:0]);

    always @* begin
        job_next = job_reg;
        display_next = display_reg;
        pending_tuple_next = pending_tuple_reg;
        convert_next = convert_reg;
        stereo_work_next = stereo_work_reg;
        pending_bcd_next = pending_bcd_reg;
        display_bcd_next = display_bcd_reg;
        cycles_next = cycles_reg;
        pending_next = pending_reg;
        adjusted = convert_reg;
        shifted = 36'd0;
        if (frame_start_i && pending_reg) begin
            display_next = pending_tuple_reg;
            display_bcd_next = pending_bcd_reg;
            pending_next = 1'b0;
        end
        if (cycles_reg == 0) begin
            if (incoming != display_reg && (!pending_reg || incoming != pending_tuple_reg)) begin
                job_next = incoming;
                convert_next = {20'd0, stereo_mm_i};
                cycles_next = 6'd32;
            end
        end else begin
            for (digit_index = 0; digit_index < 5; digit_index = digit_index + 1) begin
                if (convert_reg[16 + digit_index * 4 +: 4] >= 4'd5)
                    adjusted[16 + digit_index * 4 +: 4] =
                        convert_reg[16 + digit_index * 4 +: 4] + 4'd3;
            end
            shifted = {adjusted[34:0], 1'b0};
            convert_next = shifted;
            cycles_next = cycles_reg - 6'd1;
            if (cycles_reg == 6'd17) begin
                stereo_work_next = shifted[35:16];
                convert_next = {20'd0, job_reg[15:0]};
            end
            if (cycles_reg == 6'd1) begin
                pending_tuple_next = job_reg;
                pending_bcd_next = {stereo_work_reg, shifted[35:16]};
                pending_next = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        job_reg <= job_next;
        display_reg <= display_next;
        pending_tuple_reg <= pending_tuple_next;
        convert_reg <= convert_next;
        stereo_work_reg <= stereo_work_next;
        pending_bcd_reg <= pending_bcd_next;
        display_bcd_reg <= display_bcd_next;
        cycles_reg <= cycles_next;
        pending_reg <= pending_next;
        if (rst) begin
            job_reg <= 34'd0;
            display_reg <= 34'd0;
            pending_tuple_reg <= 34'd0;
            convert_reg <= 36'd0;
            stereo_work_reg <= 20'd0;
            pending_bcd_reg <= 40'd0;
            display_bcd_reg <= 40'd0;
            cycles_reg <= 6'd0;
            pending_reg <= 1'b0;
        end
    end

    always @* begin
        character = 8'h20;
        case (column)
            4'd0: character = first_line ? 8'h53 : ULTRASONIC_LABEL[55:48];
            4'd1: character = first_line ? 8'h54 : ULTRASONIC_LABEL[47:40];
            4'd2: character = first_line ? 8'h45 : ULTRASONIC_LABEL[39:32];
            4'd3: character = first_line ? 8'h52 : ULTRASONIC_LABEL[31:24];
            4'd4: character = first_line ? 8'h45 : ULTRASONIC_LABEL[23:16];
            4'd5: character = first_line ? 8'h4f : ULTRASONIC_LABEL[15:8];
            4'd6: character = first_line ? 8'h3a : ULTRASONIC_LABEL[7:0];
            4'd8: character = selected_valid ? 8'h30 + {4'd0, selected_bcd[19:16]} : 8'h2d;
            4'd9: character = selected_valid ? 8'h30 + {4'd0, selected_bcd[15:12]} : 8'h2d;
            4'd10: character = selected_valid ? 8'h30 + {4'd0, selected_bcd[11:8]} : 8'h2d;
            4'd11: character = selected_valid ? 8'h30 + {4'd0, selected_bcd[7:4]} : 8'h2d;
            4'd12: character = selected_valid ? 8'h30 + {4'd0, selected_bcd[3:0]} : 8'h2d;
            4'd13, 4'd14: character = 8'h4d;
            default: character = 8'h20;
        endcase
    end

    // synthesis translate_off
    initial begin
        if (PANEL_X > 11'd1040 || PANEL_Y > 10'd680) begin
            $error("dual_distance_overlay panel exceeds the 1280x720 image");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`resetall
