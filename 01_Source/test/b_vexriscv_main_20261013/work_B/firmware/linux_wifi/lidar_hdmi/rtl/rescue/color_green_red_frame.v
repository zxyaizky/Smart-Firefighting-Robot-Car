`resetall
`timescale 1ns/1ps
`default_nettype none

// Frame-qualified green/red recognition on the validated full-resolution
// RGB branch imported from lab_ex3_osd. 0=none, 1=green, 2=red.
// Independent green and red acquisition; both require two consecutive frames.
// Display/voice retain 5 missing frames; strict fire stops on the first miss.
// Majority + opening precede recognition for both colours. Reject same-colour
// horizontal runs shorter than four adjacent denoised pixels.
// Sampling still controls the area count; qualifying run endpoints set the box.
module color_green_red_frame #(
    parameter integer IMG_HDISP = 1280,
    parameter integer IMG_VDISP = 720,
    parameter integer DENOISE_ENABLE = 1,
    parameter integer CLK_FREQ_HZ = 75000000,
    parameter integer RESULT_TIMEOUT_MS = 5000,
    parameter integer DYNAMIC_GREEN_S = 0,
    parameter integer DYNAMIC_GREEN_V = 0,
    parameter integer ROI_X1 = 0,
    parameter integer ROI_X2 = 1279,
    parameter integer ROI_Y1 = 0,
    parameter integer ROI_Y2 = 719,
    parameter integer MIN_PIXELS = 300,
    parameter integer SAMPLE_SHIFT = 2,
    // Ignore edge movement of at most 3 pixels; otherwise move one quarter
    // of the remaining distance per confirmed frame.
    parameter integer BBOX_DEAD_ZONE_PX = 3,
    parameter integer BBOX_FILTER_SHIFT = 2,
    // Same division-free HSV rules as the red binary debug path.
    parameter [8:0] RED_H_MIN = 9'd340,
    parameter [8:0] RED_H_MAX = 9'd20,
    parameter [7:0] RED_S_MIN = 8'd100,
    parameter [7:0] RED_V_MIN = 8'd50,
    parameter [8:0] GREEN_H_MIN = 9'd85,
    parameter [8:0] GREEN_H_MAX = 9'd125,
    parameter [7:0] GREEN_S_MIN = 8'd55,
    parameter [7:0] GREEN_S_MAX = 8'd255,
    parameter [7:0] GREEN_V_MIN = 8'd70,
    parameter [7:0] GREEN_V_MAX = 8'd255
) (
    input wire clk,
    input wire rst,
    input wire [23:0] pixel_rgb_i,
    input wire pixel_valid_i,
    input wire [10:0] pixel_x_i,
    input wire [9:0] pixel_y_i,
    input wire frame_start_i,
    input wire frame_end_i,
    input wire frame_abort_i,
    input wire [7:0] green_s_min_i, green_s_max_i,
    input wire [7:0] green_v_min_i, green_v_max_i,
    output reg [1:0] color_o,
    output reg result_update_o,
    output wire bbox_valid_o,
    output reg [10:0] bbox_x1_o, bbox_x2_o,
    output reg [9:0] bbox_y1_o, bbox_y2_o,
    output reg green_valid_o, red_valid_o,
    output reg [10:0] green_x1_o, green_x2_o, red_x1_o, red_x2_o,
    output reg [9:0] green_y1_o, green_y2_o, red_y1_o, red_y2_o,
    output wire red_fire_valid_o, red_fire_sample_o
);
    reg green_hit, red_hit;
    reg [2:0] green_increment, red_increment;
    reg [2:0] green_run, red_run;
    reg [2:0] green_pending, red_pending;
    reg previous_valid;
    reg [10:0] previous_x;
    reg [9:0] previous_y;
    reg frame_start_d, frame_end_d, frame_abort_d;
    reg [15:0] green_count, red_count;
    reg green_streak;
    reg red_streak;
    reg [2:0] green_missing, red_missing;
    reg red_fire;
    localparam [63:0] TIMEOUT_CYCLES = (64'd1 * CLK_FREQ_HZ * RESULT_TIMEOUT_MS + 999) / 1000;
    localparam integer TIMEOUT_W = TIMEOUT_CYCLES < 2 ? 1 : $clog2(TIMEOUT_CYCLES + 1);
    localparam [TIMEOUT_W-1:0] TIMEOUT_LAST = TIMEOUT_CYCLES;
    reg [TIMEOUT_W-1:0] result_age;
    assign red_fire_valid_o = red_fire && !rst && !frame_abort_i && result_age < TIMEOUT_LAST;
    assign red_fire_sample_o = result_update_o && red_fire_valid_o;
    reg [1:0] candidate_now;
    reg [2:0] missing_frames;
    reg [10:0] hit_x;
    reg [10:0] green_left, red_left;
    reg [9:0] hit_y;
    reg [10:0] gx1, gx2, yx1, yx2;
    reg [9:0] gy1, gy2, yy1, yy2;
    wire [16:0] green_total = {1'b0, green_count} + {14'd0, green_increment};
    wire [16:0] red_total = {1'b0, red_count} + {14'd0, red_increment};
    wire [10:0] gx1_next = green_hit && green_left < gx1 ? green_left : gx1;
    wire [10:0] gx2_next = green_hit && hit_x > gx2 ? hit_x : gx2;
    wire [9:0] gy1_next = green_hit && hit_y < gy1 ? hit_y : gy1;
    wire [9:0] gy2_next = green_hit && hit_y > gy2 ? hit_y : gy2;
    wire [10:0] yx1_next = red_hit && red_left < yx1 ? red_left : yx1;
    wire [10:0] yx2_next = red_hit && hit_x > yx2 ? hit_x : yx2;
    wire [9:0] yy1_next = red_hit && hit_y < yy1 ? hit_y : yy1;
    wire [9:0] yy2_next = red_hit && hit_y > yy2 ? hit_y : yy2;

    // Signed difference shares the add/subtract hardware for either direction.
    function [10:0] smooth_edge;
        input [10:0] previous;
        input [10:0] target;
        reg signed [11:0] difference;
        reg signed [11:0] rounded;
        reg signed [11:0] step_size;
        reg signed [11:0] moved;
        begin
            difference = $signed({1'b0,target}) - $signed({1'b0,previous});
            rounded = difference + (difference[11] ? 12'sd0 :
                ((12'sd1 << BBOX_FILTER_SHIFT) - 12'sd1));
            step_size = rounded >>> BBOX_FILTER_SHIFT;
            moved = $signed({1'b0,previous}) + step_size;
            smooth_edge = difference >= -BBOX_DEAD_ZONE_PX &&
                          difference <= BBOX_DEAD_ZONE_PX ? previous : moved[10:0];
        end
    endfunction
    // Select the winning box before smoothing: four smoothers, not eight.
    wire [10:0] selected_x1 = candidate_now == 2'd1 ? gx1_next : yx1_next;
    wire [10:0] selected_x2 = candidate_now == 2'd1 ? gx2_next : yx2_next;
    wire [9:0] selected_y1 = candidate_now == 2'd1 ? gy1_next : yy1_next;
    wire [9:0] selected_y2 = candidate_now == 2'd1 ? gy2_next : yy2_next;
    assign bbox_valid_o = color_o != 2'd0;
    wire green_pixel, red_pixel, hsv_valid, hsv_start, hsv_end, hsv_abort;
    wire raw_green, raw_red, raw_valid, raw_start, raw_end, raw_abort;
    wire [10:0] raw_x;
    wire [9:0] raw_y;
    wire [10:0] hsv_x;
    wire [9:0] hsv_y;
    color_hsv_pixel #(
        .META_WIDTH(24),
        .DYNAMIC_GREEN_S(DYNAMIC_GREEN_S),
        .DYNAMIC_GREEN_V(DYNAMIC_GREEN_V),
        .RED_H_MIN(RED_H_MIN), .RED_H_MAX(RED_H_MAX),
        .RED_S_MIN(RED_S_MIN), .RED_V_MIN(RED_V_MIN),
        .GREEN_H_MIN(GREEN_H_MIN), .GREEN_H_MAX(GREEN_H_MAX),
        .GREEN_S_MIN(GREEN_S_MIN), .GREEN_S_MAX(GREEN_S_MAX),
        .GREEN_V_MIN(GREEN_V_MIN), .GREEN_V_MAX(GREEN_V_MAX)
    ) u_hsv_threshold (
        .clk(clk), .rst(rst), .rgb_i(pixel_rgb_i), .valid_i(pixel_valid_i),
        .green_s_min_i(green_s_min_i), .green_s_max_i(green_s_max_i),
        .green_v_min_i(green_v_min_i), .green_v_max_i(green_v_max_i),
        .metadata_i({frame_abort_i, frame_end_i, frame_start_i, pixel_y_i, pixel_x_i}),
        .green_o(raw_green), .red_o(raw_red), .valid_o(raw_valid),
        .metadata_o({raw_abort, raw_end, raw_start, raw_y, raw_x})
    );
    generate if (DENOISE_ENABLE != 0) begin : g_mask_denoise
        color_bbox_denoise #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP)) u_denoise (
            .clk(clk), .rst(rst), .mask_i({raw_red, raw_green}),
            .valid_i(raw_valid), .x_i(raw_x), .start_i(raw_start),
            .end_i(raw_end), .abort_i(raw_abort),
            .mask_o({red_pixel, green_pixel}), .valid_o(hsv_valid),
            .x_o(hsv_x), .y_o(hsv_y), .start_o(hsv_start),
            .end_o(hsv_end), .abort_o(hsv_abort));
    end else begin : g_raw_mask
        assign {red_pixel, green_pixel, hsv_valid} = {raw_red, raw_green, raw_valid};
        assign {hsv_abort, hsv_end, hsv_start, hsv_y, hsv_x} =
               {raw_abort, raw_end, raw_start, raw_y, raw_x};
    end endgenerate
    wire in_roi = hsv_valid &&
                    hsv_x >= ROI_X1 && hsv_x <= ROI_X2 &&
                    hsv_y >= ROI_Y1 && hsv_y <= ROI_Y2;
    wire selected_row = (hsv_y & ((1 << SAMPLE_SHIFT) - 1)) == 0;
    wire selected = in_roi && selected_row &&
                    (hsv_x & ((1 << SAMPLE_SHIFT) - 1)) == 0;
    // A row change, missing pixel, blank cycle, SOF or abort breaks the run.
    // Test adjacent mask pixels before decimation, never spaced sample points.
    wire adjacent = previous_valid && !hsv_start &&
                    previous_x != 11'h7ff && hsv_x == previous_x + 11'd1 &&
                    hsv_y == previous_y;
    wire [2:0] green_before = adjacent ? green_run : 3'd0;
    wire [2:0] red_before = adjacent ? red_run : 3'd0;
    wire green_qualified = in_roi && green_pixel && green_before >= 3'd3;
    wire red_qualified = in_roi && red_pixel && red_before >= 3'd3;

    wire green_positive = green_total >= MIN_PIXELS;
    wire red_positive = red_total >= MIN_PIXELS;
    wire green_ready = green_positive && (green_valid_o || green_streak);
    wire red_streak_current = result_age < TIMEOUT_LAST && red_streak;
    wire red_ready = red_positive && red_streak_current;
    always @* begin
        candidate_now = 2'd0;
        if (red_ready)
            candidate_now = 2'd2;
        else if (green_ready)
            candidate_now = 2'd1;
    end

    always @(posedge clk) begin
        green_hit <= green_qualified && selected_row && !hsv_abort;
        red_hit <= red_qualified && selected_row && !hsv_abort;
        // At pixel four, recover the samples among all first four
        // pixels. Later pixels each contribute at most one sample. No prefix
        // of an unqualified run can affect the area count or the box.
        green_increment <= green_qualified && selected_row && !hsv_abort ?
            (green_before == 3'd3 ? green_pending + {2'd0, selected} : {2'd0, selected}) : 3'd0;
        red_increment <= red_qualified && selected_row && !hsv_abort ?
            (red_before == 3'd3 ? red_pending + {2'd0, selected} : {2'd0, selected}) : 3'd0;
        green_left <= green_before == 3'd3 ? hsv_x - 11'd3 : hsv_x;
        red_left <= red_before == 3'd3 ? hsv_x - 11'd3 : hsv_x;
        previous_valid <= in_roi;
        previous_x <= hsv_x;
        previous_y <= hsv_y;
        green_run <= in_roi && green_pixel ?
                     (green_before < 3'd4 ? green_before + 3'd1 : 3'd4) : 3'd0;
        red_run <= in_roi && red_pixel ?
                      (red_before < 3'd4 ? red_before + 3'd1 : 3'd4) : 3'd0;
        green_pending <= in_roi && green_pixel && green_before < 3'd3 ?
            (green_before == 0 ? 3'd0 : green_pending) + {2'd0, selected} : 3'd0;
        red_pending <= in_roi && red_pixel && red_before < 3'd3 ?
            (red_before == 0 ? 3'd0 : red_pending) + {2'd0, selected} : 3'd0;
        // EOF may share the final qualifying pixel: keep that registered hit,
        // but never carry its run state into the next frame.
        if (rst || hsv_abort || hsv_end) begin
            previous_valid <= 1'b0;
            green_run <= 0; red_run <= 0;
            green_pending <= 0; red_pending <= 0;
        end
        frame_start_d <= hsv_start;
        frame_end_d <= hsv_end;
        frame_abort_d <= hsv_abort;
        hit_x <= hsv_x;
        hit_y <= hsv_y;
        result_update_o <= 1'b0;
        if (result_age < TIMEOUT_LAST) result_age <= result_age + 1'b1;
        else begin red_streak <= 0; red_fire <= 0; end
        if (rst) begin
            green_hit <= 1'b0;
            red_hit <= 1'b0;
            green_increment <= 0; red_increment <= 0;
            green_left <= 0; red_left <= 0;
            previous_x <= 0; previous_y <= 0;
            frame_start_d <= 1'b0;
            frame_end_d <= 1'b0;
            frame_abort_d <= 1'b0;
            green_count <= 16'd0;
            red_count <= 16'd0;
            green_streak <= 0; red_streak <= 0;
            green_missing <= 0; red_missing <= 0;
            red_fire <= 0;
            result_age <= TIMEOUT_LAST;
            green_valid_o <= 0; red_valid_o <= 0;
            green_x1_o <= 0; green_x2_o <= 0; green_y1_o <= 0; green_y2_o <= 0;
            red_x1_o <= 0; red_x2_o <= 0; red_y1_o <= 0; red_y2_o <= 0;
            missing_frames <= 3'd0;
            color_o <= 2'd0;
            result_update_o <= 1'b0;
            hit_x <= 0; hit_y <= 0;
            gx1 <= 11'h7ff; gx2 <= 0; gy1 <= 10'h3ff; gy2 <= 0;
            yx1 <= 11'h7ff; yx2 <= 0; yy1 <= 10'h3ff; yy2 <= 0;
            bbox_x1_o <= 0; bbox_x2_o <= 0;
            bbox_y1_o <= 0; bbox_y2_o <= 0;
        end else if (frame_abort_d) begin
            green_count <= 16'd0;
            red_count <= 16'd0;
            green_streak <= 0; red_streak <= 0; red_fire <= 0;
            if (green_missing == 4) begin green_valid_o <= 0; green_missing <= 0; end
            else green_missing <= green_missing + 1'b1;
            if (red_missing == 4) begin red_valid_o <= 0; red_missing <= 0; end
            else red_missing <= red_missing + 1'b1;
            // One aborted source frame counts as one miss and breaks the
            // two-frame acquisition sequence, without immediately clearing.
            if (color_o != 2'd0) begin
                if (missing_frames == 3'd4) begin
                    color_o <= 2'd0;
                    missing_frames <= 3'd0;
                end else missing_frames <= missing_frames + 1'b1;
            end else missing_frames <= 3'd0;
            result_update_o <= 1'b1;
        end else if (frame_start_d) begin
            green_count <= {13'd0, green_increment};
            red_count <= {13'd0, red_increment};
            gx1 <= green_hit ? green_left : 11'h7ff;
            gx2 <= green_hit ? hit_x : 11'd0;
            gy1 <= green_hit ? hit_y : 10'h3ff;
            gy2 <= green_hit ? hit_y : 10'd0;
            yx1 <= red_hit ? red_left : 11'h7ff;
            yx2 <= red_hit ? hit_x : 11'd0;
            yy1 <= red_hit ? hit_y : 10'h3ff;
            yy2 <= red_hit ? hit_y : 10'd0;
        end else begin
            gx1 <= gx1_next; gx2 <= gx2_next;
            gy1 <= gy1_next; gy2 <= gy2_next;
            yx1 <= yx1_next; yx2 <= yx2_next;
            yy1 <= yy1_next; yy2 <= yy2_next;
            green_count <= green_total >= 17'h0ffff ? 16'hffff : green_total[15:0];
            red_count <= red_total >= 17'h0ffff ? 16'hffff : red_total[15:0];
            if (frame_end_d) begin
                result_update_o <= 1'b1;
                result_age <= 0;
                green_streak <= green_positive;
                red_streak <= red_positive;
                red_fire <= red_ready;
                if (green_positive) green_missing <= 0;
                else if (green_missing == 4) begin green_valid_o <= 0; green_missing <= 0; end
                else green_missing <= green_missing + 1'b1;
                if (red_positive) red_missing <= 0;
                else if (red_missing == 4) begin red_valid_o <= 0; red_missing <= 0; end
                else red_missing <= red_missing + 1'b1;
                if (green_ready) begin
                    green_valid_o <= 1;
                    green_x1_o <= green_valid_o ? smooth_edge(green_x1_o,gx1_next) : gx1_next;
                    green_x2_o <= green_valid_o ? smooth_edge(green_x2_o,gx2_next) : gx2_next;
                    green_y1_o <= green_valid_o ? smooth_edge({1'b0,green_y1_o},{1'b0,gy1_next}) : gy1_next;
                    green_y2_o <= green_valid_o ? smooth_edge({1'b0,green_y2_o},{1'b0,gy2_next}) : gy2_next;
                end
                if (red_ready) begin
                    red_valid_o <= 1;
                    red_x1_o <= red_valid_o ? smooth_edge(red_x1_o,yx1_next) : yx1_next;
                    red_x2_o <= red_valid_o ? smooth_edge(red_x2_o,yx2_next) : yx2_next;
                    red_y1_o <= red_valid_o ? smooth_edge({1'b0,red_y1_o},{1'b0,yy1_next}) : yy1_next;
                    red_y2_o <= red_valid_o ? smooth_edge({1'b0,red_y2_o},{1'b0,yy2_next}) : yy2_next;
                end
                if (candidate_now != 2'd0) begin
                    color_o <= candidate_now;
                    missing_frames <= 3'd0;
                    // Keep colour and geometry together; an unconfirmed new
                    // colour must not replace the retained old target's box.
                    if (candidate_now == color_o) begin
                        bbox_x1_o <= smooth_edge(bbox_x1_o, selected_x1);
                        bbox_x2_o <= smooth_edge(bbox_x2_o, selected_x2);
                        bbox_y1_o <= smooth_edge({1'b0,bbox_y1_o}, {1'b0,selected_y1});
                        bbox_y2_o <= smooth_edge({1'b0,bbox_y2_o}, {1'b0,selected_y2});
                    end else begin
                        bbox_x1_o <= selected_x1; bbox_x2_o <= selected_x2;
                        bbox_y1_o <= selected_y1; bbox_y2_o <= selected_y2;
                    end
                end else if (color_o != 2'd0) begin
                    if (missing_frames == 3'd4) begin
                        color_o <= 2'd0;
                        missing_frames <= 3'd0;
                    end else missing_frames <= missing_frames + 1'b1;
                end else missing_frames <= 3'd0;
            end
        end
    end
endmodule

// Apply the debug view's 3x3 majority/erosion/dilation to both masks. A pass
// looks back one row: discard three startup rows and replay the final source
// row three times, so output coordinates remain in the original image and the
// bottom edge is not lost. Only one packed 2-bit line is retained for replay.
module color_bbox_denoise #(
    parameter integer IMG_HDISP = 1280,
    parameter integer IMG_VDISP = 720
) (
    input wire clk, rst,
    input wire [1:0] mask_i,
    input wire valid_i,
    input wire [10:0] x_i,
    input wire start_i, end_i, abort_i,
    output wire [1:0] mask_o,
    output wire valid_o,
    output wire [10:0] x_o,
    output wire [9:0] y_o,
    output wire start_o, end_o, abort_o
);
    reg [1:0] last_line [0:IMG_HDISP-1];
    reg [1:0] replay_mask;
    reg replay_valid = 0;
    reg replay_active = 0;
    reg replay_gap = 0;
    reg [1:0] replay_row = 0;
    reg [10:0] replay_x = 0;
    reg [1:0] feed_mask = 0;
    reg feed_valid = 0;
    wire restart = start_i && (replay_active || replay_gap || replay_valid);
    wire filter_reset = rst || abort_i || restart;
    wire [1:0] filtered_mask, filtered_de, filtered_vs;
    genvar lane;
    generate for (lane = 0; lane < 2; lane = lane + 1) begin : g_color
        wire majority_mask, majority_de, majority_vs;
        wire eroded_mask, eroded_de, eroded_vs;
        binary_filter3x3 #(.IMG_HDISP(IMG_HDISP), .MODE(0)) u_majority (
            .clk(clk), .rst(filter_reset), .pixel_i(feed_mask[lane]),
            .de_i(feed_valid), .vsync_i(start_i), .pixel_o(majority_mask),
            .de_o(majority_de), .vsync_o(majority_vs));
        binary_filter3x3 #(.IMG_HDISP(IMG_HDISP), .MODE(1)) u_erosion (
            .clk(clk), .rst(filter_reset), .pixel_i(majority_mask),
            .de_i(majority_de), .vsync_i(majority_vs), .pixel_o(eroded_mask),
            .de_o(eroded_de), .vsync_o(eroded_vs));
        binary_filter3x3 #(.IMG_HDISP(IMG_HDISP), .MODE(2)) u_dilation (
            .clk(clk), .rst(filter_reset), .pixel_i(eroded_mask),
            .de_i(eroded_de), .vsync_i(eroded_vs), .pixel_o(filtered_mask[lane]),
            .de_o(filtered_de[lane]), .vsync_o(filtered_vs[lane]));
    end endgenerate

    always @(posedge clk) begin
        // One cycle before the first pixel, start_i resets each line window.
        feed_mask <= replay_valid ? replay_mask : mask_i;
        feed_valid <= replay_valid || valid_i;
        replay_valid <= replay_active;
        if (!rst && valid_i && x_i < IMG_HDISP)
            last_line[x_i] <= mask_i;
        if (replay_active) begin
            replay_mask <= last_line[replay_x];
            if (replay_x == IMG_HDISP - 1) begin
                replay_x <= 0;
                replay_active <= 0;
                if (replay_row != 2) begin
                    replay_row <= replay_row + 1'b1;
                    replay_gap <= 1;
                end
            end else replay_x <= replay_x + 1'b1;
        end
        if (replay_gap) begin
            replay_gap <= 0;
            replay_active <= 1;
        end
        if (end_i) begin
            replay_active <= 1;
            replay_x <= 0;
            replay_row <= 0;
            replay_gap <= 0;
        end
        if (start_i || rst || abort_i) begin
            replay_active <= 0;
            replay_valid <= 0;
            replay_gap <= 0;
            replay_x <= 0;
            replay_row <= 0;
        end
        if (rst || abort_i) begin feed_valid <= 0; feed_mask <= 0; end
    end

    reg previous_vs = 0;
    reg frame_active = 0;
    reg [10:0] output_x = 0;
    reg [10:0] output_row = 0;
    assign mask_o = filtered_mask;
    assign valid_o = frame_active && filtered_de[0] && !abort_o &&
                     output_row >= 3 && output_row < IMG_VDISP + 3;
    assign x_o = output_x;
    assign y_o = output_row >= 3 ? output_row - 11'd3 : 10'd0;
    assign start_o = valid_o && output_x == 0 && output_row == 3;
    assign end_o = valid_o && output_x == IMG_HDISP - 1 &&
                   output_row == IMG_VDISP + 2;
    assign abort_o = abort_i || restart;
    always @(posedge clk) begin
        previous_vs <= filtered_vs[0];
        if (filtered_vs[0] && !previous_vs) begin
            output_x <= 0;
            output_row <= 0;
            frame_active <= 1;
        end else if (frame_active && filtered_de[0]) begin
            if (output_x == IMG_HDISP - 1) begin
                output_x <= 0;
                output_row <= output_row + 1'b1;
            end else output_x <= output_x + 1'b1;
            if (end_o) frame_active <= 0;
        end
        if (filter_reset) begin
            previous_vs <= 0;
            frame_active <= 0;
            output_x <= 0;
            output_row <= 0;
        end
    end
endmodule
`resetall
