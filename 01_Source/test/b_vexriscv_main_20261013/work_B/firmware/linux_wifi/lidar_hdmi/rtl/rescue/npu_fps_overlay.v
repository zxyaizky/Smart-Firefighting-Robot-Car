// -----------------------------------------------------------------------------
// File   : npu_fps_overlay.v
// Author : Codex
// Date   : 2026-10-31
// -----------------------------------------------------------------------------
// Description:
//   Count completed remote NPU result IDs per second, including negative results.
//   Draw frame-stable NPU FPS text without adding latency to RGB, DE or VS.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-31  Codex  v1.0  Result-ID meter and final HDMI overlay.
//   2026-11-01  Codex  Uniform 10x14 glyphs and red FPS text.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module npu_fps_overlay #
(
    // Incoming HDMI pixel-clock frequency.
    parameter integer CLK_HZ = 75000000,
    // Active video dimensions used by the raster counter.
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    // Text sits between the algorithm label and the health panel.
    parameter integer TEXT_X = 1080,
    parameter integer TEXT_Y = 56
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        result_frame_end_i,
    input  wire        result_bad_i,
    input  wire        result_source_valid_i,
    input  wire [15:0] result_id_i,
    input  wire        video_vsync_i,
    input  wire        video_de_i,
    input  wire [23:0] video_rgb_i,
    output wire [23:0] video_rgb_o
);
    localparam integer TIMER_W = CLK_HZ < 2 ? 1 : $clog2(CLK_HZ);
    localparam [TIMER_W-1:0] SECOND_LAST = CLK_HZ - 1;
    reg [TIMER_W-1:0] timer_reg;
    reg [15:0] last_id_reg;
    reg seen_reg;
    reg [9:0] count_reg;
    reg [9:0] binary_reg;
    reg [11:0] bcd_reg;
    reg [11:0] fps_bcd_reg;
    reg [11:0] fps_show_reg;
    reg [3:0] convert_left_reg;
    reg [11:0] bcd_adjusted;
    wire second_tick = timer_reg == SECOND_LAST;
    wire packet_valid = result_frame_end_i && !result_bad_i && result_source_valid_i;
    wire [15:0] delta = result_id_i - last_id_reg;
    wire new_result = packet_valid && (!seen_reg || delta != 0);
    // Reject backwards/restart jumps. A one-second result gap clears the baseline.
    wire forward = delta != 0 && delta <= 16'd255;
    wire discontinuity = new_result && seen_reg && !forward;
    wire [8:0] increment = !seen_reg ? 9'd1 : forward ? {1'b0, delta[7:0]} : 9'd0;
    wire [10:0] total = discontinuity ? 11'd0 :
        {1'b0, count_reg} + (new_result ? {2'd0, increment} : 11'd0);
    wire [9:0] limited_total = total > 11'd999 ? 10'd999 : total[9:0];
    wire [11:0] bcd_next = {bcd_adjusted[10:0], binary_reg[9]};

    reg [10:0] x_reg;
    reg [9:0] y_reg;
    reg de_previous_reg;
    wire [10:0] text_x = x_reg - TEXT_X;
    wire [9:0] text_y = y_reg - TEXT_Y;
    wire in_text = video_de_i && x_reg >= TEXT_X && x_reg < TEXT_X + 176 &&
                   y_reg >= TEXT_Y && y_reg < TEXT_Y + 16;
    reg [7:0] character;
    wire [3:0] glyph_column = 4'd15 - text_x[3:0];
    wire [15:0] glyph_bits = fps_font_row(character, text_y[3:0]);
    assign video_rgb_o = !rst && in_text && glyph_bits[glyph_column] ?
                         24'hff0000 : video_rgb_i;

    // Every letter and digit uses the same 5x7 face, doubled and centred
    // inside its existing 16x16 character cell.
    function [15:0] fps_font_row;
        input [7:0] ascii;
        input [3:0] row;
        reg [34:0] bitmap;
        reg [4:0] dots;
        begin
            case (ascii)
                8'h30: bitmap = 35'b01110_10001_10011_10101_11001_10001_01110;
                8'h31: bitmap = 35'b00100_01100_00100_00100_00100_00100_01110;
                8'h32: bitmap = 35'b01110_10001_00001_00010_00100_01000_11111;
                8'h33: bitmap = 35'b11110_00001_00001_01110_00001_00001_11110;
                8'h34: bitmap = 35'b00010_00110_01010_10010_11111_00010_00010;
                8'h35: bitmap = 35'b11111_10000_10000_11110_00001_00001_11110;
                8'h36: bitmap = 35'b01110_10000_10000_11110_10001_10001_01110;
                8'h37: bitmap = 35'b11111_00001_00010_00100_01000_01000_01000;
                8'h38: bitmap = 35'b01110_10001_10001_01110_10001_10001_01110;
                8'h39: bitmap = 35'b01110_10001_10001_01111_00001_00001_01110;
                8'h46: bitmap = 35'b11111_10000_10000_11110_10000_10000_10000;
                8'h4e: bitmap = 35'b10001_11001_10101_10011_10001_10001_10001;
                8'h50: bitmap = 35'b11110_10001_10001_11110_10000_10000_10000;
                8'h53: bitmap = 35'b01111_10000_10000_01110_00001_00001_11110;
                8'h55: bitmap = 35'b10001_10001_10001_10001_10001_10001_01110;
                8'h3a: bitmap = 35'b00000_00100_00100_00000_00100_00100_00000;
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
            fps_font_row = {3'd0, {2{dots[4]}}, {2{dots[3]}},
                {2{dots[2]}}, {2{dots[1]}}, {2{dots[0]}}, 3'd0};
        end
    endfunction

    always @* begin
        bcd_adjusted = bcd_reg;
        if (bcd_reg[3:0] >= 5) bcd_adjusted[3:0] = bcd_reg[3:0] + 4'd3;
        if (bcd_reg[7:4] >= 5) bcd_adjusted[7:4] = bcd_reg[7:4] + 4'd3;
        if (bcd_reg[11:8] >= 5) bcd_adjusted[11:8] = bcd_reg[11:8] + 4'd3;
        character = 8'h20;
        case (text_x[7:4])
            4'd0: character = 8'h4e; // N
            4'd1: character = 8'h50; // P
            4'd2: character = 8'h55; // U
            4'd4: character = 8'h46; // F
            4'd5: character = 8'h50; // P
            4'd6: character = 8'h53; // S
            4'd7: character = 8'h3a;
            4'd8: character = {4'h3, fps_show_reg[11:8]};
            4'd9: character = {4'h3, fps_show_reg[7:4]};
            4'd10: character = {4'h3, fps_show_reg[3:0]};
            default: character = 8'h20;
        endcase
    end

    always @(posedge clk) begin
        timer_reg <= timer_reg + 1'b1;
        count_reg <= limited_total;
        if (new_result) begin
            last_id_reg <= result_id_i;
            seen_reg <= 1'b1;
        end
        if (result_frame_end_i && !result_bad_i && !result_source_valid_i) begin
            seen_reg <= 1'b0;
            count_reg <= 0;
        end
        if (second_tick) begin
            timer_reg <= 0;
            count_reg <= 0;
            binary_reg <= limited_total;
            bcd_reg <= 0;
            convert_left_reg <= 10;
            if (limited_total == 0) seen_reg <= 1'b0;
        end else if (convert_left_reg != 0) begin
            binary_reg <= {binary_reg[8:0], 1'b0};
            bcd_reg <= bcd_next;
            convert_left_reg <= convert_left_reg - 1'b1;
            if (convert_left_reg == 1) fps_bcd_reg <= bcd_next;
        end

        de_previous_reg <= video_de_i;
        if (video_vsync_i) begin
            x_reg <= 0;
            y_reg <= 0;
            fps_show_reg <= fps_bcd_reg;
        end else if (video_de_i) begin
            if (x_reg < H_ACTIVE - 1) x_reg <= x_reg + 1'b1;
        end else begin
            x_reg <= 0;
            if (de_previous_reg && y_reg < V_ACTIVE - 1) y_reg <= y_reg + 1'b1;
        end
        if (rst) begin
            timer_reg <= 0;
            last_id_reg <= 0;
            seen_reg <= 0;
            count_reg <= 0;
            binary_reg <= 0;
            bcd_reg <= 0;
            fps_bcd_reg <= 0;
            fps_show_reg <= 0;
            convert_left_reg <= 0;
            x_reg <= 0;
            y_reg <= 0;
            de_previous_reg <= 0;
        end
    end
endmodule

`resetall
