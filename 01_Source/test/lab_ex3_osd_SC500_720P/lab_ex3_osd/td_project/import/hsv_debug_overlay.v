// -----------------------------------------------------------------------------
// File   : hsv_debug_overlay.v
// Author : Codex
// Date   : 2026-10-11
// -----------------------------------------------------------------------------
// Description:
//   Small passive HEX panel: BUILD, COMMIT, ABORT, RED, BBOX, ACTIVE, DRAW.
//   Fixed 5x7 labels and seven-segment HEX digits; no general font instance.
//   No pixel registers. Counters saturate and display snapshots follow safe VS.
//   DRAW covers the last complete ordered raster before downstream overlays.
// Change Log:
//   2026-10-11 Codex v2.2 Optional WORDS row reuses RED display snapshot.
//   2026-10-11 Codex v2.1 Optional WHY row updates even without frame commit.
//   2026-10-11 Codex v2.0 Five-digit 720P RED and optional TOP diagnostic.
//   2026-10-10  Codex  v1.0  Full diagnostic panel.
//   2026-10-11  Codex  v1.1  Remove extended statistics; compact fixed renderer.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module hsv_debug_overlay #(
    parameter [15:0] BUILD_ID = 16'h0102,
    // 14-bit legacy count or 20-bit full-resolution count.
    parameter integer RED_WIDTH = 14,
    parameter integer ENABLE_TOP_COUNT = 0,
    // Reuse the optional TOP row to show an already-latched abort code.
    parameter integer ENABLE_ABORT_DIAG = 0,
    // Temporary diagnostic: show prior DDR capture words in the RED row.
    // Requires RED_WIDTH=20 for five HEX digits; real red_count_o is unchanged.
    parameter integer ENABLE_CAPTURE_DIAG = 0,
    parameter integer COUNT_WIDTH = 12, // 1..16; default saturates at 0FFF.
    parameter [10:0] PANEL_X = 11'd16,
    parameter [9:0] PANEL_Y = 10'd512,
    parameter integer DISPLAY_WIDTH = 1280,
    parameter integer DISPLAY_HEIGHT = 720
)(
    input wire clk,
    input wire rst,
    input wire [23:0] rgb_i,
    input wire de_i,
    input wire hsync_i,
    input wire vsync_i,
    input wire [10:0] pixel_x_i,
    input wire [9:0] pixel_y_i,
    input wire sample_abort_i,
    input wire frame_commit_i,
    input wire [RED_WIDTH-1:0] red_count_i,
    input wire [13:0] top_red_count_i,
    input wire [17:0] capture_word_count_i,
    input wire bbox_result_valid_i,
    input wire bbox_valid_i,
    input wire active_valid_i,
    input wire draw_hit_i,
    output wire [23:0] rgb_o,
    output wire de_o,
    output wire hsync_o,
    output wire vsync_o,
    output wire [15:0] commit_count_o,
    output wire [15:0] abort_count_o,
    output wire [RED_WIDTH-1:0] red_count_o,
    output wire bbox_valid_o,
    output wire draw_o
);
    localparam [COUNT_WIDTH-1:0] COUNT_MAX = {COUNT_WIDTH{1'b1}};
    localparam [10:0] LAST_X = DISPLAY_WIDTH - 1;
    localparam [9:0] LAST_Y = DISPLAY_HEIGHT - 1;
    reg [COUNT_WIDTH-1:0] commit_reg = 0, commit_next;
    reg [COUNT_WIDTH-1:0] abort_reg = 0, abort_next;
    reg [RED_WIDTH-1:0] red_reg = 0, red_next;
    reg [13:0] top_reg = 0;
    wire [13:0] show_top;
    reg bbox_reg = 0, bbox_next;
    reg vsync_d_reg = 0;
    reg publish_pending_reg = 0;
    reg tracking_reg = 0;
    reg [10:0] expected_x_reg = 0;
    reg [9:0] expected_y_reg = 0;
    reg draw_work_reg = 0;
    reg draw_last_reg = 0;
    reg [2*COUNT_WIDTH+RED_WIDTH+16:0] display_reg = 0;
    wire [COUNT_WIDTH-1:0] show_commit_core, show_abort_core;
    wire [15:0] show_commit, show_abort;
    wire [RED_WIDTH-1:0] show_red;
    wire [RED_WIDTH-1:0] capture_hex;
    wire show_bbox, show_active, show_draw;
    wire safe_boundary;
    wire panel;
    wire [10:0] local_x;
    wire [9:0] local_y;
    wire [3:0] column;
    wire [2:0] row, font_row;
    wire [47:0] label_bits;
    wire [23:0] hex_bits;
    wire [5:0] label_index;
    wire [4:0] hex_index;
    reg [19:0] value_hex;
    reg [3:0] nibble;
    wire label_hit, number_hit, hex_hit, glyph_hit;

    function [15:0] extend_count;
        input [COUNT_WIDTH-1:0] value;
        begin extend_count = {{(16-COUNT_WIDTH){1'b0}}, value}; end
    endfunction
    // Only seven immutable labels, doubled to 16x16 cells. No ASCII/ROM interface.
    function [47:0] fixed_label;
        input [2:0] text_row;
        input [2:0] scan_row;
        begin
            fixed_label = 48'd0;
            case ({text_row, scan_row})
                6'd0: fixed_label = 48'h784438407800;
                6'd1: fixed_label = 48'h444410404400;
                6'd2: fixed_label = 48'h444410404400;
                6'd3: fixed_label = 48'h784410404400;
                6'd4: fixed_label = 48'h444410404400;
                6'd5: fixed_label = 48'h444410404400;
                6'd6: fixed_label = 48'h7838387c7800;
                6'd8: fixed_label = 48'h38384444387c;
                6'd9: fixed_label = 48'h44446c6c1010;
                6'd10: fixed_label = 48'h404454541010;
                6'd11: fixed_label = 48'h404454541010;
                6'd12: fixed_label = 48'h404444441010;
                6'd13: fixed_label = 48'h444444441010;
                6'd14: fixed_label = 48'h383844443810;
                6'd16: fixed_label = 48'h387838787c00;
                6'd17: fixed_label = 48'h444444441000;
                6'd18: fixed_label = 48'h444444441000;
                6'd19: fixed_label = 48'h7c7844781000;
                6'd20: fixed_label = 48'h444444501000;
                6'd21: fixed_label = 48'h444444481000;
                6'd22: fixed_label = 48'h447838441000;
                6'd24: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h443878783c00 : 48'h787c78000000;
                6'd25: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h444444444000 : 48'h444044000000;
                6'd26: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h444444444000 : 48'h444044000000;
                6'd27: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h544478443800 : 48'h787844000000;
                6'd28: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h544450440400 : 48'h504044000000;
                6'd29: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h544448440400 : 48'h484044000000;
                6'd30: fixed_label = (ENABLE_CAPTURE_DIAG != 0) ? 48'h283844787800 : 48'h447c78000000;
                6'd32: fixed_label = 48'h787838440000;
                6'd33: fixed_label = 48'h444444440000;
                6'd34: fixed_label = 48'h444444280000;
                6'd35: fixed_label = 48'h787844100000;
                6'd36: fixed_label = 48'h444444280000;
                6'd37: fixed_label = 48'h444444440000;
                6'd38: fixed_label = 48'h787838440000;
                6'd40: fixed_label = 48'h38387c38447c;
                6'd41: fixed_label = 48'h444410104440;
                6'd42: fixed_label = 48'h444010104440;
                6'd43: fixed_label = 48'h7c4010104478;
                6'd44: fixed_label = 48'h444010104440;
                6'd45: fixed_label = 48'h444410102840;
                6'd46: fixed_label = 48'h44381038107c;
                6'd48: fixed_label = 48'h787838440000;
                6'd49: fixed_label = 48'h444444440000;
                6'd50: fixed_label = 48'h444444440000;
                6'd51: fixed_label = 48'h44787c540000;
                6'd52: fixed_label = 48'h445044540000;
                6'd53: fixed_label = 48'h444844540000;
                6'd54: fixed_label = 48'h784444280000;
                6'd56: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h444444000000 : 48'h7c3878000000; // TOP
                6'd57: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h444444000000 : 48'h104444000000;
                6'd58: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h444428000000 : 48'h104444000000;
                6'd59: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h547c10000000 : 48'h104478000000;
                6'd60: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h544410000000 : 48'h104440000000;
                6'd61: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h544410000000 : 48'h104440000000;
                6'd62: fixed_label = (ENABLE_ABORT_DIAG != 0) ? 48'h284410000000 : 48'h103840000000;
                default: fixed_label = 48'd0;
            endcase
        end
    endfunction
    function [23:0] hex_label;
        input [2:0] scan_row;
        begin
            hex_label = 24'd0;
            case (scan_row)
                3'd0: hex_label = 24'h447c44;
                3'd1: hex_label = 24'h444044;
                3'd2: hex_label = 24'h444028;
                3'd3: hex_label = 24'h7c7810;
                3'd4: hex_label = 24'h444028;
                3'd5: hex_label = 24'h444044;
                3'd6: hex_label = 24'h447c44;
                default: hex_label = 24'd0;
            endcase
        end
    endfunction
    function digit_pixel;
        input [3:0] digit;
        input [3:0] xx, yy;
        reg [6:0] segments;
        begin
            // a,b,c,d,e,f,g: B/D use the conventional lowercase seven-segment shape.
            case (digit)
                4'h0: segments = 7'b1111110;
                4'h1: segments = 7'b0110000;
                4'h2: segments = 7'b1101101;
                4'h3: segments = 7'b1111001;
                4'h4: segments = 7'b0110011;
                4'h5: segments = 7'b1011011;
                4'h6: segments = 7'b1011111;
                4'h7: segments = 7'b1110000;
                4'h8: segments = 7'b1111111;
                4'h9: segments = 7'b1111011;
                4'ha: segments = 7'b1110111;
                4'hb: segments = 7'b0011111;
                4'hc: segments = 7'b1001110;
                4'hd: segments = 7'b0111101;
                4'he: segments = 7'b1001111;
                4'hf: segments = 7'b1000111;
                default: segments = 7'd0;
            endcase
            digit_pixel =
                (xx >= 4'd4 && xx <= 4'd11 &&
                 ((segments[6] && (yy == 4'd1 || yy == 4'd2)) ||
                  (segments[0] && (yy == 4'd7 || yy == 4'd8)) ||
                  (segments[3] && (yy == 4'd13 || yy == 4'd14)))) ||
                ((xx == 4'd2 || xx == 4'd3) &&
                 ((segments[1] && yy >= 4'd3 && yy <= 4'd6) ||
                  (segments[2] && yy >= 4'd9 && yy <= 4'd12))) ||
                ((xx == 4'd12 || xx == 4'd13) &&
                 ((segments[5] && yy >= 4'd3 && yy <= 4'd6) ||
                  (segments[4] && yy >= 4'd9 && yy <= 4'd12)));
        end
    endfunction

    assign safe_boundary = vsync_i && !vsync_d_reg && !de_i;
    assign commit_count_o = extend_count(commit_reg);
    assign abort_count_o = extend_count(abort_reg);
    assign red_count_o = red_reg;
    assign capture_hex = capture_word_count_i;
    assign bbox_valid_o = bbox_reg;
    assign draw_o = draw_last_reg;
    assign {show_commit_core, show_abort_core, show_red, show_top,
            show_bbox, show_active, show_draw} = display_reg;
    assign show_commit = extend_count(show_commit_core);
    assign show_abort = extend_count(show_abort_core);
    assign local_x = pixel_x_i - PANEL_X;
    assign local_y = pixel_y_i - PANEL_Y;
    assign panel = pixel_x_i >= PANEL_X && local_x < 11'd256 &&
                   pixel_y_i >= PANEL_Y &&
                   local_y < (ENABLE_TOP_COUNT != 0 ? 10'd128 : 10'd112);
    assign column = local_x[7:4];
    assign row = local_y[6:4];
    assign font_row = local_y[3:1];
    assign label_bits = fixed_label(row, font_row);
    assign hex_bits = hex_label(font_row);
    assign label_index = 6'd47 - local_x[6:1];
    assign hex_index = 5'd31 - local_x[5:1];
    assign label_hit = local_x < 11'd96 && label_bits[label_index];
    // 208 is not aligned to 64: subtract the 16 logical-pixel offset within that bank.
    assign hex_hit = row == 3'd0 && local_x >= 11'd208 &&
                     hex_bits[hex_index];
    assign number_hit = column >= 4'd8 &&
                        column <= ((row == 3'd3 && RED_WIDTH > 16) ? 4'd12 : 4'd11) &&
                        (row < 3'd4 || row == 3'd7 || column == 4'd8) &&
                        digit_pixel(nibble, local_x[3:0], local_y[3:0]);
    assign glyph_hit = label_hit || hex_hit || number_hit;
    assign rgb_o = de_i && !rst && panel ?
                   (glyph_hit ? 24'h80ffff : 24'h101820) : rgb_i;
    assign de_o = de_i;
    assign hsync_o = hsync_i;
    assign vsync_o = vsync_i;

    always @* begin
        commit_next = commit_reg;
        abort_next = abort_reg;
        red_next = red_reg;
        bbox_next = bbox_reg;
        if (frame_commit_i) begin
            if (commit_reg != COUNT_MAX) commit_next = commit_reg + 1'b1;
            red_next = red_count_i;
        end
        if (sample_abort_i && abort_reg != COUNT_MAX) abort_next = abort_reg + 1'b1;
        if (bbox_result_valid_i) bbox_next = bbox_valid_i;
    end
    always @(posedge clk) begin
        commit_reg <= commit_next;
        abort_reg <= abort_next;
        red_reg <= red_next;
        if (ENABLE_ABORT_DIAG != 0) top_reg <= top_red_count_i;
        else if (ENABLE_TOP_COUNT != 0 && frame_commit_i) top_reg <= top_red_count_i;
        bbox_reg <= bbox_next;
        vsync_d_reg <= vsync_i;
        publish_pending_reg <= safe_boundary;
        if (publish_pending_reg)
            display_reg <= {commit_next, abort_next,
                            (ENABLE_CAPTURE_DIAG != 0 ? capture_hex : red_next),
                            (ENABLE_TOP_COUNT != 0 ?
                             ((ENABLE_ABORT_DIAG != 0 || frame_commit_i) ? top_red_count_i : top_reg) : 14'd0),
                            bbox_next, active_valid_i, draw_last_reg};
        if (safe_boundary) begin
            tracking_reg <= 1'b1;
            expected_x_reg <= 11'd0;
            expected_y_reg <= 10'd0;
            draw_work_reg <= 1'b0;
        end else if (tracking_reg && de_i) begin
            if (pixel_x_i != expected_x_reg || pixel_y_i != expected_y_reg) begin
                tracking_reg <= 1'b0;
            end else begin
                draw_work_reg <= draw_work_reg | draw_hit_i;
                if (expected_x_reg == LAST_X) begin
                    expected_x_reg <= 11'd0;
                    if (expected_y_reg == LAST_Y) begin
                        tracking_reg <= 1'b0;
                        draw_last_reg <= draw_work_reg | draw_hit_i;
                    end else expected_y_reg <= expected_y_reg + 10'd1;
                end else expected_x_reg <= expected_x_reg + 11'd1;
            end
        end
        if (rst) begin
            commit_reg <= 0;
            abort_reg <= 0;
            red_reg <= 0;
            top_reg <= 0;
            bbox_reg <= 0;
            vsync_d_reg <= 0;
            publish_pending_reg <= 0;
            display_reg <= 0;
            tracking_reg <= 0;
            expected_x_reg <= 0;
            expected_y_reg <= 0;
            draw_work_reg <= 0;
            draw_last_reg <= 0;
        end
    end
    always @* begin
        value_hex = 20'd0;
        case (row)
            3'd0: value_hex = BUILD_ID;
            3'd1: value_hex = show_commit;
            3'd2: value_hex = show_abort;
            3'd3: value_hex = {{(20-RED_WIDTH){1'b0}}, show_red};
            3'd4: value_hex = {15'd0, show_bbox};
            3'd5: value_hex = {15'd0, show_active};
            3'd6: value_hex = {15'd0, show_draw};
            3'd7: value_hex = {6'd0, show_top};
            default: value_hex = 20'd0;
        endcase
        nibble = 4'd0;
        if (row >= 3'd4 && row != 3'd7) nibble = value_hex[3:0];
        else if (row == 3'd3 && RED_WIDTH > 16) begin
            case (column)
                4'd8: nibble = value_hex[19:16];
                4'd9: nibble = value_hex[15:12];
                4'd10: nibble = value_hex[11:8];
                4'd11: nibble = value_hex[7:4];
                4'd12: nibble = value_hex[3:0];
                default: nibble = 4'd0;
            endcase
        end else begin
            case (column)
                4'd8: nibble = value_hex[15:12];
                4'd9: nibble = value_hex[11:8];
                4'd10: nibble = value_hex[7:4];
                4'd11: nibble = value_hex[3:0];
                default: nibble = 4'd0;
            endcase
        end
    end
endmodule
`resetall

