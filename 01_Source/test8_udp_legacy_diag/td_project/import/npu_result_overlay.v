// -----------------------------------------------------------------------------
// File   : npu_result_overlay.v
// Author : Project team
// Date   : 2026-09-13
// Description: Latch the reduced NPU detection, cross it to the HDMI clock and
//              draw the detection box and raw person scores on displayed video.
// Change Log:
//   2026-10-16  Codex  v1.4  Display completed winner OBJ/PERSON even below gates.
//   2026-09-14  Codex  v1.1  Send one CDC event per completed inference.
//   2026-09-14  Codex  v1.2  Activate received results without waiting for VSYNC.
//   2026-09-14  Codex  v1.3  Remove the redundant pending-result copy.
//   2026-09-18  Fix bbox decode: combined-numerator single division with
//               round-to-nearest replaces multi-stage truncation that shrank
//               detection boxes by 1-2 pixels.
//   2026-09-18  Area: factor the exact integer terms out of the rounding so the
//               per-edge divider collapses to a 10-bit adder plus three
//               comparators. Removes four wide signed dividers that pushed
//               slice usage over the device limit. Numerically identical.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_result_overlay #(
    parameter integer NPU_CLK_HZ = 100000000,
    parameter integer ENABLE_BOARD_DEBUG = 0
) (
    input  wire        clk_npu,
    input  wire        rst_n_npu,
    input  wire        i_model_ready,
    input  wire        i_error,
    input  wire        i_tensor_valid,
    input  wire [63:0] i_tensor_data,
    input  wire        i_inference_done,
    // Independent sticky milestones, observation only. No inference feedback.
    input  wire [7:0]  i_debug_flags,

    input  wire        clk_video,
    input  wire        rst_n_video,
    input  wire        i_video_vsync,
    input  wire        i_video_de,
    input  wire [23:0] i_video_data,
    output reg         o_video_vsync,
    output reg         o_video_de,
    output reg  [23:0] o_video_data
);
    // The final descriptor enables REDUCE_MAX_GRID, so this interface receives
    // one stable winner per inference: {gy,gx,person,h,w,dy,dx,obj}.
    reg [63:0] result_npu_reg;
    reg result_toggle_npu;
    reg result_seen_npu;

    // Count completed inferences in one-second windows in the NPU clock
    // domain. BCD avoids a binary-to-decimal divider in the pixel path.
    reg [31:0] fps_second_counter;
    reg [11:0] fps_count_npu;
    reg [11:0] fps_snapshot_npu;
    reg fps_toggle_npu;
    wire [11:0] fps_count_next =
        (!i_inference_done || fps_count_npu == 12'h999) ? fps_count_npu :
        (fps_count_npu[3:0] != 4'd9) ?
            {fps_count_npu[11:4], fps_count_npu[3:0] + 4'd1} :
        (fps_count_npu[7:4] != 4'd9) ?
            {fps_count_npu[11:8], fps_count_npu[7:4] + 4'd1, 4'd0} :
            {fps_count_npu[11:8] + 4'd1, 8'd0};

    wire [7:0] winner_dx = result_npu_reg[15:8];
    wire [7:0] winner_dy = result_npu_reg[23:16];
    wire [7:0] winner_w = result_npu_reg[31:24];
    wire [7:0] winner_h = result_npu_reg[39:32];
    wire [7:0] winner_gx = result_npu_reg[55:48];
    wire [7:0] winner_gy = result_npu_reg[63:56];

    // ========================================================================
    // Bbox decode.
    //
    // Python reference (exact rational arithmetic, a single rounding at the end):
    //   cx = (gx + dx/255) / 20            cy = (gy + dy/255) / 15
    //   x1 = (cx - w/510) * 160 * 8        x2 = (cx + w/510) * 160 * 8
    //   y1 = (cy - h/510) * 120 * 8 - 120  y2 = (cy + h/510) * 120 * 8 - 120
    //
    // 64*gx and 64*gy-120 are exact integers, so they factor straight out of the
    // final rounding and each edge keeps only a small numerator:
    //   x1 = 64*gx       + round(64*(dx - 10*w) / 255)
    //   x2 = 64*gx       + round(64*(dx + 10*w) / 255)
    //   y1 = 64*gy - 120 + round(32*(2*dy - 15*h) / 255)
    //   y2 = 64*gy - 120 + round(32*(2*dy + 15*h) / 255)
    //
    // round(n/255) = floor((|n|+127)/255). 255 is odd, so n/255 can never be an
    // exact half and half-away vs half-to-even rounding agree.
    //
    // floor(u/255) needs no divider. With a = u>>8 and b = u[7:0]:
    //   u/255 = (256*a + b)/255 = a + (a+b)/255
    //   floor(u/255) = a + [a+b>=255] + [a+b>=510] + [a+b>=765]
    // |n| <= 179520 so u <= 179647 and a+b <= 892, i.e. three comparators
    // suffice. This is exact, needs only a 10-bit adder, and replaces four wide
    // signed dividers that dominated slice usage.
    // ========================================================================

    // --- x span terms: 10*w (= w<<3 + w<<1), then dx +/- 10*w ---
    wire [11:0] w_x10 = ({4'd0, winner_w} << 3) + ({4'd0, winner_w} << 1);
    wire [11:0] x_t_pos = {4'd0, winner_dx} + w_x10;
    wire signed [12:0] x_t_neg = $signed({5'd0, winner_dx}) - $signed({1'b0, w_x10});
    wire [12:0] x_t_neg_abs = x_t_neg[12] ? -x_t_neg : x_t_neg;

    // --- x numerators: 64*t and 64*|t|, then +127 for round-to-nearest ---
    wire [17:0] x_n_pos = {6'd0, x_t_pos} << 6;
    wire [17:0] x_n_neg = {5'd0, x_t_neg_abs} << 6;

    // --- y span terms: 15*h (= h<<4 - h), 2*dy, then 2*dy +/- 15*h ---
    wire [11:0] h_x15 = ({4'd0, winner_h} << 4) - {4'd0, winner_h};
    wire [9:0]  dy_x2 = {2'd0, winner_dy} << 1;
    wire [12:0] y_s_pos = {3'd0, dy_x2} + {1'b0, h_x15};
    wire signed [13:0] y_s_neg = $signed({4'd0, dy_x2}) - $signed({2'd0, h_x15});
    wire [13:0] y_s_neg_abs = y_s_neg[13] ? -y_s_neg : y_s_neg;

    // --- y numerators: 32*s and 32*|s|, then +127 for round-to-nearest ---
    wire [17:0] y_n_pos = {5'd0, y_s_pos} << 5;
    wire [17:0] y_n_neg = {4'd0, y_s_neg_abs} << 5;

    // --- exact floor(u/255) for u < 2^18 ---
    function [10:0] div255_floor;
        input [17:0] u;
        reg [9:0] a;
        reg [10:0] s;
        begin
            a = u[17:8];
            s = {1'b0, a} + {3'd0, u[7:0]};
            div255_floor = {1'b0, a}
                         + (s >= 11'd255) + (s >= 11'd510) + (s >= 11'd765);
        end
    endfunction

    wire [10:0] x_r_pos = div255_floor(x_n_pos + 18'd127);
    wire [10:0] x_r_neg = div255_floor(x_n_neg + 18'd127);
    wire [10:0] y_r_pos = div255_floor(y_n_pos + 18'd127);
    wire [10:0] y_r_neg = div255_floor(y_n_neg + 18'd127);

    // --- reassemble each edge: exact integer base plus rounded span ---
    wire [14:0] x_base = {1'b0, winner_gx} << 6;
    wire [14:0] y_base = {1'b0, winner_gy} << 6;

    wire signed [15:0] x1_r = $signed({1'b0, x_base}) - $signed({5'd0, x_r_neg});
    wire signed [15:0] x2_r = $signed({1'b0, x_base}) + $signed({5'd0, x_r_pos});
    wire signed [15:0] y1_r = $signed({1'b0, y_base}) - 16'sd120 - $signed({5'd0, y_r_neg});
    wire signed [15:0] y2_r = $signed({1'b0, y_base}) - 16'sd120 + $signed({5'd0, y_r_pos});

    // --- Clip to display range: x in [0,1279], y in [0,719] ---
    wire [10:0] winner_x0 = (x1_r < 16'sd0) ? 11'd0 :
                             (x1_r > 16'sd1279) ? 11'd1279 : x1_r[10:0];
    wire [10:0] winner_x1 = (x2_r < 16'sd0) ? 11'd0 :
                             (x2_r > 16'sd1279) ? 11'd1279 : x2_r[10:0];
    wire [9:0] winner_y0 = (y1_r < 16'sd0) ? 10'd0 :
                            (y1_r > 16'sd719) ? 10'd719 : y1_r[9:0];
    wire [9:0] winner_y1 = (y2_r < 16'sd0) ? 10'd0 :
                            (y2_r > 16'sd719) ? 10'd719 : y2_r[9:0];

    always @(posedge clk_npu or negedge rst_n_npu) begin
        if (!rst_n_npu) begin
            result_npu_reg <= 64'd0;
            result_toggle_npu <= 1'b0;
            result_seen_npu <= 1'b0;
            fps_second_counter <= 32'd0;
            fps_count_npu <= 12'd0;
            fps_snapshot_npu <= 12'd0;
            fps_toggle_npu <= 1'b0;
        end else begin
            // Keep the data bus stable after the final tensor word. Toggling
            // for every word can alias an even or fast burst in clk_video.
            if (i_tensor_valid) begin
                result_npu_reg <= i_tensor_data;
            end
            if (i_inference_done) begin
                result_toggle_npu <= ~result_toggle_npu;
                result_seen_npu <= 1'b1;
            end
            if (fps_second_counter == NPU_CLK_HZ - 1) begin
                fps_second_counter <= 32'd0;
                fps_snapshot_npu <= fps_count_next;
                fps_toggle_npu <= ~fps_toggle_npu;
                fps_count_npu <= 12'd0;
            end else begin
                fps_second_counter <= fps_second_counter + 32'd1;
                fps_count_npu <= fps_count_next;
            end
        end
    end

    reg [1:0] toggle_sync_reg;
    reg toggle_seen_reg;
    reg [1:0] ready_sync_reg, error_sync_reg, result_seen_sync_reg;
    reg [1:0] fps_toggle_sync_reg;
    reg fps_toggle_seen_reg;
    reg [11:0] fps_digits_video;
    reg [63:0] active_result_reg;
    reg [10:0] x_reg;
    reg [9:0] y_reg;
    (* async_reg = "true" *) reg [7:0] debug_flags_meta, debug_flags_sync;
    wire debug_progress_pixel = ENABLE_BOARD_DEBUG && i_video_de &&
        x_reg >= 11'd1136 && x_reg < 11'd1264 &&
        y_reg >= 10'd36 && y_reg < 10'd46;
    wire debug_color_pixel = ENABLE_BOARD_DEBUG && i_video_de &&
        x_reg >= 11'd1136 && x_reg < 11'd1264 &&
        y_reg >= 10'd50 && y_reg < 10'd62;
    wire [10:0] debug_local_x = x_reg - 11'd1136;
    wire [2:0] debug_flag_index = debug_local_x[6:4];
    wire [23:0] debug_progress_color = debug_local_x[3:0] >= 4'd12 ?
        24'h101820 : (debug_flags_sync[debug_flag_index] ? 24'hffffff : 24'h303030);
    wire [23:0] debug_reference_color = debug_local_x[6:5] == 2'd0 ? 24'hff0000 :
        debug_local_x[6:5] == 2'd1 ? 24'h00ff00 :
        debug_local_x[6:5] == 2'd2 ? 24'h0000ff : 24'hffffff;
    reg active_detect_reg;
    reg vsync_d_reg, de_d_reg, result_seen_d_reg;

    wire new_result = toggle_sync_reg[1] != toggle_seen_reg;
    wire first_result = result_seen_sync_reg[1] && !result_seen_d_reg;
    wire [7:0] active_obj = active_result_reg[7:0];
    wire fire_detect = (result_npu_reg[7:0] >= 8'd128) &&
                       (result_npu_reg[47:40] >= 8'd128);
    wire [7:0] active_dx = active_result_reg[15:8];
    wire [7:0] active_dy = active_result_reg[23:16];
    wire [7:0] active_w = active_result_reg[31:24];
    wire [7:0] active_h = active_result_reg[39:32];
    wire [7:0] active_fire = active_result_reg[47:40];
    wire [7:0] active_gx = active_result_reg[55:48];
    wire [7:0] active_gy = active_result_reg[63:56];

    reg [10:0] box_x0, box_x1;
    reg [9:0] box_y0, box_y1;
    wire [23:0] fire_color = 24'hff2020;
    reg box_pixel, status_pixel, fps_panel_pixel, fps_text_pixel;
    reg [23:0] status_color;
    reg [7:0] fps_char;
    reg [7:0] fps_local_x;
    reg [4:0] fps_row_bits;
    reg [11:0] obj_digits_video, person_digits_video;
    reg scores_seen_video;
    reg score_panel_pixel, score_text_pixel;
    reg [7:0] score_char, score_local_x;
    reg [4:0] score_row_bits;
    reg [3:0] score_font_row;
    reg [11:0] score_digits;
    wire score_person_line = y_reg >= 10'd88;

    // Eight-bit double dabble; no divider in the video pixel path.
    function [11:0] score_to_bcd;
        input [7:0] value;
        reg [11:0] digits;
        integer bit_index;
        begin
            digits = 12'd0;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                if (digits[3:0] >= 4'd5) digits[3:0] = digits[3:0] + 4'd3;
                if (digits[7:4] >= 4'd5) digits[7:4] = digits[7:4] + 4'd3;
                if (digits[11:8] >= 4'd5) digits[11:8] = digits[11:8] + 4'd3;
                digits = {digits[10:0], value[bit_index]};
            end
            score_to_bcd = digits;
        end
    endfunction

    // Five-by-seven font, doubled to 10x14 pixels per character.
    function [4:0] fps_font_row;
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] glyph;
        begin
            case (ch)
                "O": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "B": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "J": glyph = {5'b00111,5'b00010,5'b00010,5'b00010,5'b10010,5'b10010,5'b01100};
                "E": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "R": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "-": glyph = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                "N": glyph = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "P": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "U": glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "F": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "S": glyph = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "0": glyph = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": glyph = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3": glyph = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4": glyph = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6": glyph = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7": glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8": glyph = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9": glyph = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                default: glyph = 35'd0;
            endcase
            fps_font_row = glyph[34 - row * 5 -: 5];
        end
    endfunction

    // ========================================================================
    // Debug observables -- compiled ONLY for the golden self-check TestBench
    // (`+define+BBOX_DECODE_TRACE`). Synthesis without that define sees no part
    // of this block, so the wide combined numerators, the Q16/Q8 scalings and
    // the two constant dividers below can never consume slices on the board.
    //
    // Placed after every net it reads (including new_result/first_result) so it
    // also compiles under `default_nettype none` where forward references are
    // not allowed.
    // ========================================================================
`ifdef BBOX_DECODE_TRACE
    // Combined numerators in the un-factored form. These are exactly 255x the
    // display-space edge, so they stay directly comparable with the Python
    // reference even though the synthesised datapath factors the integer terms
    // out. Debug only.
    wire signed [31:0] cx_num = 32'sd64 * ({24'd0,winner_gx} * 32'd255 + {24'd0,winner_dx});
    wire signed [31:0] cy_num = 32'sd64 * ({24'd0,winner_gy} * 32'd255 + {24'd0,winner_dy});
    wire signed [31:0] x1_num = cx_num - 32'sd640 * {24'd0,winner_w};
    wire signed [31:0] x2_num = cx_num + 32'sd640 * {24'd0,winner_w};
    wire signed [31:0] y1_num = cy_num - 32'sd480 * {24'd0,winner_h};
    wire signed [31:0] y2_num = cy_num + 32'sd480 * {24'd0,winner_h};

    // Round-to-nearest division by 255, un-factored form (debug reference).
    function signed [31:0] div255_round;
        input signed [31:0] v;
        begin
            div255_round = (v >= 32'sd0) ? (v + 32'sd127) / 32'sd255
                                          : -((-v + 32'sd127) / 32'sd255);
        end
    endfunction

    // cx/cy as Q16: cx*65536 = (gx*255+dx)*65536/5100, cy likewise over 3825.
    wire [31:0] cx_q16_num = ({24'd0,winner_gx} * 32'd255 + {24'd0,winner_dx}) * 32'd65536;
    wire signed [31:0] cx_q16 = $signed(cx_q16_num + 32'd2550) / 32'sd5100;
    wire [31:0] cy_q16_num = ({24'd0,winner_gy} * 32'd255 + {24'd0,winner_dy}) * 32'd65536;
    wire signed [31:0] cy_q16 = $signed(cy_q16_num + 32'd1912) / 32'sd3825;

    // Network-space Q8, i.e. the same 160x120 padded space Python reports for
    // x1_npu/y1_npu/x2_npu/y2_npu.
    // x has no padding: x_npu_q8 = x_display * 32 (= x_display/8 * 256).
    wire signed [31:0] x1_npu_q8 = div255_round(x1_num * 32'sd32);
    wire signed [31:0] x2_npu_q8 = div255_round(x2_num * 32'sd32);
    // y_display = (y_npu - 15) * 8, so y_npu = y_display/8 + 15. Strip the
    // display-space padding offset (-120*255 = -30600), scale to Q8, then add
    // the 15 padded rows back (15*256 = 3840).
    wire signed [31:0] y1_npu_q8 = div255_round((y1_num - 32'sd30600) * 32'sd32) + 32'sd3840;
    wire signed [31:0] y2_npu_q8 = div255_round((y2_num - 32'sd30600) * 32'sd32) + 32'sd3840;

    always @(posedge clk_video) begin
        if (new_result || first_result) begin
            $display("[BBOX_TRACE] cx=%0d cy=%0d x1n=%0d y1n=%0d x2n=%0d y2n=%0d box=(%0d,%0d,%0d,%0d)",
                     cx_q16, cy_q16,
                     x1_npu_q8, y1_npu_q8, x2_npu_q8, y2_npu_q8,
                     winner_x0, winner_y0, winner_x1, winner_y1);
        end
    end
`endif

    always @(*) begin
        box_pixel = 1'b0;
        if (active_detect_reg && i_video_de &&
            x_reg >= box_x0 && x_reg <= box_x1 &&
            y_reg >= box_y0 && y_reg <= box_y1) begin
            if (x_reg < box_x0 + 11'd3 || x_reg + 11'd3 > box_x1 ||
                y_reg < box_y0 + 10'd3 || y_reg + 10'd3 > box_y1)
                box_pixel = 1'b1;
        end

        // Top-right status strip: orange=loading, blue=ready/no completed frame,
        // green=inference completed, red=sticky NPU/DDR/load error.
        status_pixel = i_video_de && x_reg >= 11'd1248 && y_reg < 10'd10;
        if (error_sync_reg[1]) status_color = 24'hff0000;
        else if (!ready_sync_reg[1]) status_color = 24'hff8000;
        else if (!result_seen_sync_reg[1]) status_color = 24'h0080ff;
        else status_color = 24'h00ff00;

        // Right-aligned label: "NPU 000 FPS" at x=1136..1267, y=16..29.
        // Leave the existing status strip at y=0..9 visible above it.
        fps_panel_pixel = i_video_de && x_reg >= 11'd1134 &&
                          x_reg < 11'd1272 && y_reg >= 10'd13 && y_reg < 10'd33;
        fps_text_pixel = 1'b0;
        fps_char = " ";
        fps_local_x = 8'd0;
        fps_row_bits = 5'd0;
        if (fps_panel_pixel && x_reg >= 11'd1136 && x_reg < 11'd1268 &&
            y_reg >= 10'd16 && y_reg < 10'd30) begin
            if      (x_reg < 11'd1148) begin fps_char = "N"; fps_local_x = x_reg - 11'd1136; end
            else if (x_reg < 11'd1160) begin fps_char = "P"; fps_local_x = x_reg - 11'd1148; end
            else if (x_reg < 11'd1172) begin fps_char = "U"; fps_local_x = x_reg - 11'd1160; end
            else if (x_reg < 11'd1184) begin fps_char = " "; fps_local_x = x_reg - 11'd1172; end
            else if (x_reg < 11'd1196) begin fps_char = 8'h30 + {4'd0, fps_digits_video[11:8]}; fps_local_x = x_reg - 11'd1184; end
            else if (x_reg < 11'd1208) begin fps_char = 8'h30 + {4'd0, fps_digits_video[7:4]}; fps_local_x = x_reg - 11'd1196; end
            else if (x_reg < 11'd1220) begin fps_char = 8'h30 + {4'd0, fps_digits_video[3:0]}; fps_local_x = x_reg - 11'd1208; end
            else if (x_reg < 11'd1232) begin fps_char = " "; fps_local_x = x_reg - 11'd1220; end
            else if (x_reg < 11'd1244) begin fps_char = "F"; fps_local_x = x_reg - 11'd1232; end
            else if (x_reg < 11'd1256) begin fps_char = "P"; fps_local_x = x_reg - 11'd1244; end
            else begin fps_char = "S"; fps_local_x = x_reg - 11'd1256; end
            fps_row_bits = fps_font_row(fps_char, (y_reg - 10'd16) >> 1);
            if (fps_local_x < 8'd10)
                fps_text_pixel = fps_row_bits[4 - (fps_local_x >> 1)];
        end

        // Below the existing debug bars: "OBJ    000" / "PERSON 000".
        // These are the SAME completed winner used by the HDMI box, not PC
        // inference or a maximum taken independently from each output channel.
        score_panel_pixel = i_video_de && x_reg >= 11'd1134 &&
            x_reg < 11'd1272 && y_reg >= 10'd65 && y_reg < 10'd105;
        score_text_pixel = 1'b0;
        score_char = " ";
        score_local_x = 8'd0;
        score_row_bits = 5'd0;
        score_font_row = 4'd0;
        score_digits = score_person_line ? person_digits_video : obj_digits_video;
        if (score_panel_pixel && x_reg >= 11'd1136 && x_reg < 11'd1256 &&
            ((!score_person_line && y_reg >= 10'd68 && y_reg < 10'd82) ||
             (score_person_line && y_reg < 10'd102))) begin
            if (x_reg < 11'd1148) begin
                score_char = score_person_line ? "P" : "O";
                score_local_x = x_reg - 11'd1136;
            end else if (x_reg < 11'd1160) begin
                score_char = score_person_line ? "E" : "B";
                score_local_x = x_reg - 11'd1148;
            end else if (x_reg < 11'd1172) begin
                score_char = score_person_line ? "R" : "J";
                score_local_x = x_reg - 11'd1160;
            end else if (x_reg < 11'd1184) begin
                score_char = score_person_line ? "S" : " ";
                score_local_x = x_reg - 11'd1172;
            end else if (x_reg < 11'd1196) begin
                score_char = score_person_line ? "O" : " ";
                score_local_x = x_reg - 11'd1184;
            end else if (x_reg < 11'd1208) begin
                score_char = score_person_line ? "N" : " ";
                score_local_x = x_reg - 11'd1196;
            end else if (x_reg < 11'd1220) begin
                score_local_x = x_reg - 11'd1208;
            end else if (x_reg < 11'd1232) begin
                score_char = scores_seen_video ? 8'h30 + {4'd0, score_digits[11:8]} : "-";
                score_local_x = x_reg - 11'd1220;
            end else if (x_reg < 11'd1244) begin
                score_char = scores_seen_video ? 8'h30 + {4'd0, score_digits[7:4]} : "-";
                score_local_x = x_reg - 11'd1232;
            end else begin
                score_char = scores_seen_video ? 8'h30 + {4'd0, score_digits[3:0]} : "-";
                score_local_x = x_reg - 11'd1244;
            end
            score_font_row = score_person_line ? (y_reg - 10'd88) >> 1 :
                                                (y_reg - 10'd68) >> 1;
            score_row_bits = fps_font_row(score_char, score_font_row[2:0]);
            if (score_local_x < 8'd10)
                score_text_pixel = score_row_bits[4 - (score_local_x >> 1)];
        end
    end

    always @(posedge clk_video or negedge rst_n_video) begin
        if (!rst_n_video) begin
            toggle_sync_reg <= 2'b00;
            toggle_seen_reg <= 1'b0;
            ready_sync_reg <= 2'b00;
            error_sync_reg <= 2'b00;
            result_seen_sync_reg <= 2'b00;
            fps_toggle_sync_reg <= 2'b00;
            fps_toggle_seen_reg <= 1'b0;
            fps_digits_video <= 12'd0;
            obj_digits_video <= 12'd0;
            person_digits_video <= 12'd0;
            scores_seen_video <= 1'b0;
            debug_flags_meta <= 8'd0;
            debug_flags_sync <= 8'd0;
            active_result_reg <= 64'd0;
            active_detect_reg <= 1'b0;
            box_x0 <= 0; box_x1 <= 0;
            box_y0 <= 0; box_y1 <= 0;
            vsync_d_reg <= 1'b0;
            de_d_reg <= 1'b0;
            result_seen_d_reg <= 1'b0;
            x_reg <= 11'd0;
            y_reg <= 10'd0;
            o_video_vsync <= 1'b0;
            o_video_de <= 1'b0;
            o_video_data <= 24'd0;
        end else begin
            debug_flags_meta <= i_debug_flags;
            debug_flags_sync <= debug_flags_meta;
            toggle_sync_reg <= {toggle_sync_reg[0], result_toggle_npu};
            ready_sync_reg <= {ready_sync_reg[0], i_model_ready};
            error_sync_reg <= {error_sync_reg[0], i_error};
            result_seen_sync_reg <= {result_seen_sync_reg[0], result_seen_npu};
            fps_toggle_sync_reg <= {fps_toggle_sync_reg[0], fps_toggle_npu};
            if (fps_toggle_sync_reg[1] != fps_toggle_seen_reg) begin
                fps_toggle_seen_reg <= fps_toggle_sync_reg[1];
                fps_digits_video <= fps_snapshot_npu;
            end
            toggle_seen_reg <= toggle_sync_reg[1];
            vsync_d_reg <= i_video_vsync;
            de_d_reg <= i_video_de;
            result_seen_d_reg <= result_seen_sync_reg[1];

            if (i_video_vsync && !vsync_d_reg) begin
                x_reg <= 11'd0;
                y_reg <= 10'd0;
            end else if (i_video_de) begin
                x_reg <= x_reg + 11'd1;
            end else if (de_d_reg) begin
                x_reg <= 11'd0;
                if (y_reg != 10'd719) y_reg <= y_reg + 10'd1;
            end

            // Activate a complete result as soon as its synchronized event is
            // visible. The first-result level edge is a fallback if the toggle
            // is missed during reset release.
            if (new_result || first_result) begin
                active_result_reg <= result_npu_reg;
                obj_digits_video <= score_to_bcd(result_npu_reg[7:0]);
                person_digits_video <= score_to_bcd(result_npu_reg[47:40]);
                scores_seen_video <= 1'b1;
                active_detect_reg <= fire_detect;
                box_x0 <= winner_x0;
                box_x1 <= winner_x1;
                box_y0 <= winner_y0;
                box_y1 <= winner_y1;
            end

            o_video_vsync <= i_video_vsync;
            o_video_de <= i_video_de;
            if (!i_video_de) o_video_data <= 24'd0;
            else if (status_pixel) o_video_data <= status_color;
            else if (fps_text_pixel) o_video_data <= 24'hffffff;
            else if (fps_panel_pixel) o_video_data <= 24'h101820;
            else if (score_text_pixel) o_video_data <= 24'hffffff;
            else if (score_panel_pixel) o_video_data <= 24'h101820;
            else if (debug_progress_pixel) o_video_data <= debug_progress_color;
            else if (debug_color_pixel) o_video_data <= debug_reference_color;
            else if (box_pixel) o_video_data <= fire_color;
            else o_video_data <= i_video_data;
        end
    end
endmodule
`resetall
