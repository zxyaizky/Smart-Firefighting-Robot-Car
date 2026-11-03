// -----------------------------------------------------------------------------
// File   : rgb_quantize_4.v
// Author : unknown
// Date   : 2026-10-01
// -----------------------------------------------------------------------------
// Description:
//   Cartoon processing: median, shadow lift, six colour bands and dark contours.
//   Contours store 8-bit luma; colour uses three exact 3-bit palette indices.
//   One 25-bit line word replaces the previous 48-bit pair of RGB lines.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-13  Codex  v4.0  Exact compact colour/luma window, same pixel timing.
//   2026-10-01  unknown  v2.0  Preserve dim skin tones instead of crushing to black.
//   2026-10-01  unknown  v3.0  Stronger colour blocks and aligned dark outlines.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module rgb_quantize_4 #
(
    // Active pixels per line; the display uses 1280.
    parameter [10:0] IMG_HDISP = 11'd1280,
    // Six merges middle colour bands; eight reproduces the brighter palette.
    parameter COLOR_LEVELS = 6,
    // Only strong boundaries are inked, retaining face shading and flat areas.
    parameter OUTLINE_ENABLE = 1'b1,
    parameter [10:0] OUTLINE_THRESHOLD = 11'd180
)
(
    input  wire        S_hdmi_pixel_clk,
    input  wire        S_hdmi_rst_n,
    input  wire [23:0] rgb_in,
    input  wire        S_ycbcr_vsync,
    input  wire        S_ycbcr_de,
    output wire [23:0] S_quant4_center_d3,
    output wire        S_quant4_vsync,
    output wire        S_quant4_de
);

wire [7:0] median_r;
wire [7:0] median_g;
wire [7:0] median_b;
wire       median_vsync;
wire       median_href;
wire       median_clken;

// A low-cost luma estimate used only as the neutral axis for saturation.
// Y ~= (R + 2G + B) / 4; the addition of two implements rounding.
wire [7:0] luma;
wire [7:0] saturated_r;
wire [7:0] saturated_g;
wire [7:0] saturated_b;
wire [7:0] quantized_r;
wire [7:0] quantized_g;
wire [7:0] quantized_b;
wire color_vsync;
wire color_href;
wire color_clken;
wire [7:0] color_p11;
wire [7:0] color_p12;
wire [7:0] color_p13;
wire [7:0] color_p21;
wire [16:0] color_p22;
wire [16:0] compact_pixel;
wire [7:0] color_p23;
wire [7:0] color_p31;
wire [7:0] color_p32;
wire [7:0] color_p33;
wire [9:0] horizontal_abs;
wire [9:0] vertical_abs;
wire [9:0] neighbor_luma_sum;
wire [7:0] center_luma;
wire contour_active;

reg [23:0] rgb_aligned_d0;
reg [23:0] rgb_aligned_d1;
reg [23:0] rgb_aligned_d2;
reg [7:0] luma_lifted_reg;
wire [9:0] luma_lifted_next;
reg [7:0] lifted_r_reg;
reg [7:0] lifted_g_reg;
reg [7:0] lifted_b_reg;
reg lifted_vsync_reg;
reg lifted_href_reg;
reg lifted_clken_reg;
reg [23:0] output_rgb_reg;
reg median_vsync_d;
reg median_href_d;
reg median_clken_d;
reg [7:0] luma_p11_reg;
reg [7:0] luma_p12_reg;
reg [7:0] luma_p13_reg;
reg [7:0] luma_p21_reg;
reg [7:0] luma_p23_reg;
reg [7:0] luma_p31_reg;
reg [7:0] luma_p32_reg;
reg [7:0] luma_p33_reg;
reg [9:0] right_sum_reg;
reg [9:0] left_sum_reg;
reg [9:0] top_sum_reg;
reg [9:0] bottom_sum_reg;
reg [10:0] gradient_reg;
reg dark_side_reg;
reg dark_side_pipe_reg;
reg [16:0] center_rgb_d0_reg;
reg [16:0] center_rgb_d1_reg;
reg [16:0] center_rgb_d2_reg;
reg [2:0] color_vsync_pipe_reg;
reg [2:0] color_href_pipe_reg;
reg [2:0] color_clken_pipe_reg;

// A continuous piecewise tone curve: 1.5x below 64, then taper the boost to
// zero at 128. Preserve true black and leave bright inputs unchanged.
function [7:0] lift_shadows;
    input [7:0] colour;
    reg [8:0] lifted;
    reg [8:0] headroom;
    begin
        lifted = {1'b0, colour};
        headroom = 9'd0;
        if (colour < 8'd64) begin
            lifted = {1'b0, colour} + {2'd0, colour[7:1]};
        end else if (colour < 8'd128) begin
            headroom = 9'd128 - {1'b0, colour};
            lifted = {1'b0, colour} + (headroom >> 1);
        end
        lift_shadows = lifted[7:0];
    end
endfunction

// 1.25x saturation is gentler on skin tones and shadow colour channels.
// Add/subtract/shift only; clip rather than wrap at either endpoint.
function [7:0] saturate_5_over_4;
    input [7:0] colour;
    input [7:0] neutral;
    reg signed [8:0] delta;
    reg signed [11:0] expanded;
    begin
        // Match the original symmetric rounding with one shared signed difference.
        delta = $signed({1'b0, colour}) - $signed({1'b0, neutral});
        expanded = $signed({2'b00, colour, 2'b00}) +
                   $signed({{3{delta[8]}}, delta}) +
                   (delta[8] ? 12'sd1 : 12'sd2);
        if (expanded[11]) begin
            saturate_5_over_4 = 8'h00;
        end else if (expanded >= 12'sd1024) begin
            saturate_5_over_4 = 8'hff;
        end else begin
            saturate_5_over_4 = expanded[9:2];
        end
    end
endfunction

// Round to the nearest of 0,36,73,109,146,182,219,255. The balanced comparison
// tree avoids the old truncation of every channel below 64 to zero.
function [7:0] quantize_8_level;
    input [7:0] colour;
    begin
        if (colour < 8'd128) begin
            if (colour < 8'd55) begin
                quantize_8_level = (colour < 8'd18) ? 8'd0 : 8'd36;
            end else begin
                quantize_8_level = (colour < 8'd91) ? 8'd73 : 8'd109;
            end
        end else begin
            if (colour < 8'd201) begin
                quantize_8_level = (colour < 8'd164) ? 8'd146 : 8'd182;
            end else begin
                quantize_8_level = (colour < 8'd237) ? 8'd219 : 8'd255;
            end
        end
    end
endfunction

// Keep the two darkest and two brightest levels; merge only the middle pairs.
// This increases flat colour regions without returning to the old black cutoff.
function [7:0] quantize_6_level;
    input [7:0] colour;
    begin
        if (colour < 8'd128) begin
            if (colour < 8'd55) begin
                quantize_6_level = (colour < 8'd18) ? 8'd0 : 8'd36;
            end else begin
                quantize_6_level = 8'd96;
            end
        end else begin
            if (colour < 8'd201) begin
                quantize_6_level = 8'd168;
            end else begin
                quantize_6_level = (colour < 8'd237) ? 8'd219 : 8'd255;
            end
        end
    end
endfunction

// Palette codes carry exactly the existing 6/8-level output colours.
function [2:0] encode_channel;
    input [7:0] colour;
    begin
        if (COLOR_LEVELS == 8) begin
            if (colour < 8'd128) begin
                if (colour < 8'd55)
                    encode_channel = (colour < 8'd18) ? 3'd0 : 3'd1;
                else
                    encode_channel = (colour < 8'd91) ? 3'd2 : 3'd3;
            end else begin
                if (colour < 8'd201)
                    encode_channel = (colour < 8'd164) ? 3'd4 : 3'd5;
                else
                    encode_channel = (colour < 8'd237) ? 3'd6 : 3'd7;
            end
        end else begin
            if (colour < 8'd55)
                encode_channel = (colour < 8'd18) ? 3'd0 : 3'd1;
            else if (colour < 8'd128) encode_channel = 3'd2;
            else if (colour < 8'd201) encode_channel = 3'd3;
            else encode_channel = (colour < 8'd237) ? 3'd4 : 3'd5;
        end
    end
endfunction

function [7:0] decode_channel;
    input [2:0] code;
    begin
        if (COLOR_LEVELS == 8) begin
            case (code)
                3'd0: decode_channel = 8'd0;
                3'd1: decode_channel = 8'd36;
                3'd2: decode_channel = 8'd73;
                3'd3: decode_channel = 8'd109;
                3'd4: decode_channel = 8'd146;
                3'd5: decode_channel = 8'd182;
                3'd6: decode_channel = 8'd219;
                default: decode_channel = 8'd255;
            endcase
        end else begin
            case (code)
                3'd0: decode_channel = 8'd0;
                3'd1: decode_channel = 8'd36;
                3'd2: decode_channel = 8'd96;
                3'd3: decode_channel = 8'd168;
                3'd4: decode_channel = 8'd219;
                default: decode_channel = 8'd255;
            endcase
        end
    end
endfunction

function [7:0] rgb_luma;
    input [23:0] colour;
    reg [9:0] sum;
    begin
        sum = {2'd0, colour[23:16]} + {1'b0, colour[15:8], 1'b0} +
              {2'd0, colour[7:0]} + 10'd2;
        rgb_luma = sum[9:2];
    end
endfunction

// S_ycbcr_vsync/S_ycbcr_de have passed through the three-stage rgb2ycbcr
// pipeline. Delay the original RGB by the same amount before windowing.
always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
    if (!S_hdmi_rst_n) begin
        rgb_aligned_d0 <= 24'd0;
        rgb_aligned_d1 <= 24'd0;
        rgb_aligned_d2 <= 24'd0;
    end else begin
        rgb_aligned_d0 <= rgb_in;
        rgb_aligned_d1 <= rgb_aligned_d0;
        rgb_aligned_d2 <= rgb_aligned_d1;
    end
end

// The three instances use the same control stream, so the timing from the R
// channel also represents G and B. Each channel is filtered independently to
// remove isolated colour noise before the cartoon quantisation.
VIP_Gray_Median_Filter_720p #(
    .IMG_HDISP    (IMG_HDISP),
    .SPARSE_INPUT (1'b0)
) u_cartoon_median_r (
    .clk             (S_hdmi_pixel_clk),
    .rst_n           (S_hdmi_rst_n),
    .pe_frame_vsync  (S_ycbcr_vsync),
    .pe_frame_href   (S_ycbcr_de),
    .pe_frame_clken  (S_ycbcr_de),
    .pe_img_Y        (rgb_aligned_d2[23:16]),
    .pos_frame_vsync (median_vsync),
    .pos_frame_href  (median_href),
    .pos_frame_clken (median_clken),
    .pos_img_Y       (median_r)
);

VIP_Gray_Median_Filter_720p #(
    .IMG_HDISP    (IMG_HDISP),
    .SPARSE_INPUT (1'b0)
) u_cartoon_median_g (
    .clk             (S_hdmi_pixel_clk),
    .rst_n           (S_hdmi_rst_n),
    .pe_frame_vsync  (S_ycbcr_vsync),
    .pe_frame_href   (S_ycbcr_de),
    .pe_frame_clken  (S_ycbcr_de),
    .pe_img_Y        (rgb_aligned_d2[15:8]),
    .pos_frame_vsync (),
    .pos_frame_href  (),
    .pos_frame_clken (),
    .pos_img_Y       (median_g)
);

VIP_Gray_Median_Filter_720p #(
    .IMG_HDISP    (IMG_HDISP),
    .SPARSE_INPUT (1'b0)
) u_cartoon_median_b (
    .clk             (S_hdmi_pixel_clk),
    .rst_n           (S_hdmi_rst_n),
    .pe_frame_vsync  (S_ycbcr_vsync),
    .pe_frame_href   (S_ycbcr_de),
    .pe_frame_clken  (S_ycbcr_de),
    .pe_img_Y        (rgb_aligned_d2[7:0]),
    .pos_frame_vsync (),
    .pos_frame_href  (),
    .pos_frame_clken (),
    .pos_img_Y       (median_b)
);

// Register the tone curve before saturation and quantisation to keep the
// additional processing out of the original single-clock critical path.
always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
    if (!S_hdmi_rst_n) begin
        luma_lifted_reg <= 8'd0;
        lifted_r_reg <= 8'd0;
        lifted_g_reg <= 8'd0;
        lifted_b_reg <= 8'd0;
        lifted_vsync_reg <= 1'b0;
        lifted_href_reg <= 1'b0;
        lifted_clken_reg <= 1'b0;
    end else begin
        luma_lifted_reg <= luma_lifted_next[9:2];
        lifted_r_reg <= lift_shadows(median_r);
        lifted_g_reg <= lift_shadows(median_g);
        lifted_b_reg <= lift_shadows(median_b);
        lifted_vsync_reg <= median_vsync;
        lifted_href_reg <= median_href;
        lifted_clken_reg <= median_clken;
    end
end

// Derive gradients before colour quantisation. Posterised colour bands must
// not create spurious outlines through otherwise smooth face shading.
generate
    if (OUTLINE_ENABLE) begin : g_contour_window
        cartoon_compact_window #(
            .IMG_HDISP    (IMG_HDISP)
        ) color_window_inst (
            .clk                (S_hdmi_pixel_clk),
            .rst_n              (S_hdmi_rst_n),
            .per_frame_vsync    (lifted_vsync_reg),
            .per_frame_href     (lifted_href_reg),
            .per_frame_clken    (lifted_clken_reg),
            .per_img_Y          (compact_pixel),
            .matrix_frame_vsync (color_vsync),
            .matrix_frame_href  (color_href),
            .matrix_frame_clken (color_clken),
            .matrix_p11         (color_p11),
            .matrix_p12         (color_p12),
            .matrix_p13         (color_p13),
            .matrix_p21         (color_p21),
            .matrix_p22         (color_p22),
            .matrix_p23         (color_p23),
            .matrix_p31         (color_p31),
            .matrix_p32         (color_p32),
            .matrix_p33         (color_p33)
        );
    end else begin : g_no_contour_window
        assign color_vsync = lifted_vsync_reg;
        assign color_href  = lifted_href_reg;
        assign color_clken = lifted_clken_reg;
        assign color_p11 = 8'd0;
        assign color_p12 = 8'd0;
        assign color_p13 = 8'd0;
        assign color_p21 = 8'd0;
        assign color_p22 = compact_pixel;
        assign color_p23 = 8'd0;
        assign color_p31 = 8'd0;
        assign color_p32 = 8'd0;
        assign color_p33 = 8'd0;
    end
endgenerate

wire [10:0] h_delta = {1'b0,right_sum_reg} - {1'b0,left_sum_reg};
wire [10:0] v_delta = {1'b0,bottom_sum_reg} - {1'b0,top_sum_reg};
assign horizontal_abs = h_delta[10] ? (~h_delta[9:0] + 10'd1) : h_delta[9:0];
assign vertical_abs = v_delta[10] ? (~v_delta[9:0] + 10'd1) : v_delta[9:0];
assign neighbor_luma_sum = {2'd0, luma_p12_reg} + {2'd0, luma_p21_reg} +
                           {2'd0, luma_p23_reg} + {2'd0, luma_p32_reg} + 10'd2;
assign center_luma = center_rgb_d0_reg[16:9];
// Ink only the darker side of a strong boundary. This avoids double-width
// strokes darkening the whole picture while preserving a clear cartoon contour.
assign contour_active = OUTLINE_ENABLE && (gradient_reg >= OUTLINE_THRESHOLD) &&
                        dark_side_pipe_reg;

// Three arithmetic stages, with exactly the same RGB and control history.
always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
    if (!S_hdmi_rst_n) begin
        luma_p11_reg <= 8'd0;
        luma_p12_reg <= 8'd0;
        luma_p13_reg <= 8'd0;
        luma_p21_reg <= 8'd0;
        luma_p23_reg <= 8'd0;
        luma_p31_reg <= 8'd0;
        luma_p32_reg <= 8'd0;
        luma_p33_reg <= 8'd0;
        right_sum_reg <= 10'd0;
        left_sum_reg <= 10'd0;
        top_sum_reg <= 10'd0;
        bottom_sum_reg <= 10'd0;
        gradient_reg <= 11'd0;
        dark_side_reg <= 1'b0;
        dark_side_pipe_reg <= 1'b0;
        center_rgb_d0_reg <= 17'd0;
        center_rgb_d1_reg <= 17'd0;
        center_rgb_d2_reg <= 17'd0;
        color_vsync_pipe_reg <= 3'd0;
        color_href_pipe_reg <= 3'd0;
        color_clken_pipe_reg <= 3'd0;
    end else begin
        luma_p11_reg <= color_p11;
        luma_p12_reg <= color_p12;
        luma_p13_reg <= color_p13;
        luma_p21_reg <= color_p21;
        luma_p23_reg <= color_p23;
        luma_p31_reg <= color_p31;
        luma_p32_reg <= color_p32;
        luma_p33_reg <= color_p33;
        right_sum_reg <= {2'd0, luma_p13_reg} + {1'b0, luma_p23_reg, 1'b0} +
                         {2'd0, luma_p33_reg};
        left_sum_reg <= {2'd0, luma_p11_reg} + {1'b0, luma_p21_reg, 1'b0} +
                        {2'd0, luma_p31_reg};
        top_sum_reg <= {2'd0, luma_p11_reg} + {1'b0, luma_p12_reg, 1'b0} +
                       {2'd0, luma_p13_reg};
        bottom_sum_reg <= {2'd0, luma_p31_reg} + {1'b0, luma_p32_reg, 1'b0} +
                          {2'd0, luma_p33_reg};
        gradient_reg <= {1'b0, horizontal_abs} + {1'b0, vertical_abs};
        dark_side_reg <= (center_luma < neighbor_luma_sum[9:2]);
        dark_side_pipe_reg <= dark_side_reg;
        center_rgb_d0_reg <= color_p22;
        center_rgb_d1_reg <= center_rgb_d0_reg;
        center_rgb_d2_reg <= center_rgb_d1_reg;
        color_vsync_pipe_reg <= {color_vsync_pipe_reg[1:0], color_vsync};
        color_href_pipe_reg <= {color_href_pipe_reg[1:0], color_href};
        color_clken_pipe_reg <= {color_clken_pipe_reg[1:0], color_clken};
    end
end

// Quantise before storing the window: a pointwise operation commutes with
// its pixel selection and replicated borders. Luma stays unquantised for edges.
assign luma_lifted_next = {2'b00, lift_shadows(median_r)} +
                           {1'b0, lift_shadows(median_g), 1'b0} +
                           {2'b00, lift_shadows(median_b)} + 10'd2;
assign luma = luma_lifted_reg;
assign saturated_r = saturate_5_over_4(lifted_r_reg, luma);
assign saturated_g = saturate_5_over_4(lifted_g_reg, luma);
assign saturated_b = saturate_5_over_4(lifted_b_reg, luma);
assign compact_pixel = {luma, encode_channel(saturated_r),
                       encode_channel(saturated_g), encode_channel(saturated_b)};
assign quantized_r = decode_channel(center_rgb_d2_reg[8:6]);
assign quantized_g = decode_channel(center_rgb_d2_reg[5:3]);
assign quantized_b = decode_channel(center_rgb_d2_reg[2:0]);

// One output register keeps the processed RGB and video controls aligned.
always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
    if (!S_hdmi_rst_n) begin
        output_rgb_reg    <= 24'd0;
        median_vsync_d     <= 1'b0;
        median_href_d      <= 1'b0;
        median_clken_d     <= 1'b0;
    end else begin
        if (color_href_pipe_reg[2] && color_clken_pipe_reg[2]) begin
            // Quarter-strength colour on strong contours, rather than replacing
            // an entire shadow region with pure black.
            output_rgb_reg <= contour_active ?
                              {2'd0, quantized_r[7:2], 2'd0, quantized_g[7:2],
                               2'd0, quantized_b[7:2]} :
                              {quantized_r, quantized_g, quantized_b};
        end else begin
            output_rgb_reg <= 24'd0;
        end
        median_vsync_d     <= color_vsync_pipe_reg[2];
        median_href_d      <= color_href_pipe_reg[2];
        median_clken_d     <= color_clken_pipe_reg[2];
    end
end

assign S_quant4_vsync = median_vsync_d;
assign S_quant4_de    = median_href_d && median_clken_d;
assign S_quant4_center_d3 = output_rgb_reg;

endmodule
`resetall

// Compact contour history: 25 bits/column, identical control and borders.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module cartoon_compact_window #
(
    // Active pixels per complete input line.
    parameter [10:0] IMG_HDISP = 11'd1280,
    parameter DATA_WIDTH = 17
)
(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  per_frame_vsync,
    input  wire                  per_frame_href,
    input  wire                  per_frame_clken,
    input  wire [DATA_WIDTH-1:0] per_img_Y,
    output wire                  matrix_frame_vsync,
    output wire                  matrix_frame_href,
    output wire                  matrix_frame_clken,
    output wire [7:0] matrix_p11,
    output wire [7:0] matrix_p12,
    output wire [7:0] matrix_p13,
    output wire [7:0] matrix_p21,
    output wire [DATA_WIDTH-1:0] matrix_p22,
    output wire [7:0] matrix_p23,
    output wire [7:0] matrix_p31,
    output wire [7:0] matrix_p32,
    output wire [7:0] matrix_p33
);

wire rst;
wire input_valid;
wire frame_start;
wire [7:0] top_sample;
wire [DATA_WIDTH-1:0] middle_sample;

reg [DATA_WIDTH+7:0] line_memory [0:IMG_HDISP-1];
reg [DATA_WIDTH+7:0] line_read_pipe_reg;
reg [DATA_WIDTH-1:0] pixel_pipe_reg = {DATA_WIDTH{1'b0}};
reg [10:0] column_reg = 11'd0;
reg [1:0] history_rows_reg = 2'd0;
reg vsync_reg = 1'b0;
reg [1:0] vsync_pipe_reg = 2'd0;
reg valid_pipe_reg = 1'b0;
reg [10:0] column_pipe_reg = 11'd0;
reg [1:0] history_rows_pipe_reg = 2'd0;
reg tail_pending_reg = 1'b0;
reg line_active_reg = 1'b0;
reg window_vsync_reg = 1'b0;
reg window_href_reg = 1'b0;
reg window_clken_reg = 1'b0;
reg [7:0] top_left_reg = 8'd0;
reg [7:0] top_center_reg = 8'd0;
reg [7:0] middle_left_reg = 8'd0;
reg [DATA_WIDTH-1:0] middle_center_reg = {DATA_WIDTH{1'b0}};
reg [7:0] bottom_left_reg = 8'd0;
reg [7:0] bottom_center_reg = 8'd0;
reg [7:0] window_p11_reg = 8'd0;
reg [7:0] window_p12_reg = 8'd0;
reg [7:0] window_p13_reg = 8'd0;
reg [7:0] window_p21_reg = 8'd0;
reg [DATA_WIDTH-1:0] window_p22_reg = {DATA_WIDTH{1'b0}};
reg [7:0] window_p23_reg = 8'd0;
reg [7:0] window_p31_reg = 8'd0;
reg [7:0] window_p32_reg = 8'd0;
reg [7:0] window_p33_reg = 8'd0;

assign rst = !rst_n;
assign input_valid = per_frame_href && per_frame_clken && !per_frame_vsync;
assign frame_start = per_frame_vsync && !vsync_reg;
// RAM is deliberately not reset. Row metadata hides all unwritten/stale words.
assign middle_sample = (history_rows_pipe_reg == 2'd0) ?
                       pixel_pipe_reg : line_read_pipe_reg[DATA_WIDTH-1:0];
assign top_sample = (history_rows_pipe_reg < 2'd2) ?
                    middle_sample[16:9] : line_read_pipe_reg[DATA_WIDTH+7:DATA_WIDTH];
assign matrix_frame_vsync = window_vsync_reg;
assign matrix_frame_href  = window_href_reg;
assign matrix_frame_clken = window_clken_reg;
assign matrix_p11 = window_p11_reg;
assign matrix_p12 = window_p12_reg;
assign matrix_p13 = window_p13_reg;
assign matrix_p21 = window_p21_reg;
assign matrix_p22 = window_p22_reg;
assign matrix_p23 = window_p23_reg;
assign matrix_p31 = window_p31_reg;
assign matrix_p32 = window_p32_reg;
assign matrix_p33 = window_p33_reg;

// Single synchronous read and delayed write; consecutive pixels use different
// addresses. The packed word stores the previous two lines in inferred block RAM.
always @(posedge clk) begin
    if (!rst && input_valid) begin
        line_read_pipe_reg <= line_memory[column_reg];
    end
    if (!rst && valid_pipe_reg) begin
        line_memory[column_pipe_reg] <= {middle_sample[16:9], pixel_pipe_reg};
    end
end

always @(posedge clk) begin
    vsync_reg <= per_frame_vsync;
    vsync_pipe_reg <= {vsync_pipe_reg[0], per_frame_vsync};
    valid_pipe_reg <= input_valid;
    if (input_valid) begin
        pixel_pipe_reg <= per_img_Y;
        column_pipe_reg <= column_reg;
        history_rows_pipe_reg <= history_rows_reg;
        if (column_reg == IMG_HDISP - 11'd1) begin
            column_reg <= 11'd0;
            if (history_rows_reg < 2'd2) begin
                history_rows_reg <= history_rows_reg + 2'd1;
            end
        end else begin
            column_reg <= column_reg + 11'd1;
        end
    end
    if (frame_start) begin
        column_reg <= 11'd0;
        history_rows_reg <= 2'd0;
    end
    if (rst) begin
        vsync_reg <= 1'b0;
        vsync_pipe_reg <= 2'd0;
        valid_pipe_reg <= 1'b0;
        pixel_pipe_reg <= {DATA_WIDTH{1'b0}};
        column_pipe_reg <= 11'd0;
        history_rows_pipe_reg <= 2'd0;
        column_reg <= 11'd0;
        history_rows_reg <= 2'd0;
    end
end

// A pixel of lookahead centers the horizontal window. Emit the final column
// explicitly, using the held last pixel rather than speculative blanking reads.
always @(posedge clk) begin
    window_vsync_reg <= vsync_pipe_reg[1];
    window_href_reg <= line_active_reg;
    window_clken_reg <= 1'b0;
    tail_pending_reg <= 1'b0;
    if (tail_pending_reg) begin
        window_href_reg <= 1'b1;
        window_clken_reg <= 1'b1;
        line_active_reg <= 1'b0;
        window_p11_reg <= top_left_reg;
        window_p12_reg <= top_center_reg;
        window_p13_reg <= top_center_reg;
        window_p21_reg <= middle_left_reg;
        window_p22_reg <= middle_center_reg;
        window_p23_reg <= middle_center_reg[16:9];
        window_p31_reg <= bottom_left_reg;
        window_p32_reg <= bottom_center_reg;
        window_p33_reg <= bottom_center_reg;
    end else if (valid_pipe_reg) begin
        if (column_pipe_reg == 11'd0) begin
            top_left_reg <= top_sample;
            top_center_reg <= top_sample;
            middle_left_reg <= middle_sample[16:9];
            middle_center_reg <= middle_sample;
            bottom_left_reg <= pixel_pipe_reg[16:9];
            bottom_center_reg <= pixel_pipe_reg[16:9];
        end else begin
            window_href_reg <= 1'b1;
            window_clken_reg <= 1'b1;
            line_active_reg <= 1'b1;
            window_p11_reg <= top_left_reg;
            window_p12_reg <= top_center_reg;
            window_p13_reg <= top_sample;
            top_left_reg <= top_center_reg;
            top_center_reg <= top_sample;
            window_p21_reg <= middle_left_reg;
            window_p22_reg <= middle_center_reg;
            window_p23_reg <= middle_sample[16:9];
            middle_left_reg <= middle_center_reg[16:9];
            middle_center_reg <= middle_sample;
            window_p31_reg <= bottom_left_reg;
            window_p32_reg <= bottom_center_reg;
            window_p33_reg <= pixel_pipe_reg[16:9];
            bottom_left_reg <= bottom_center_reg;
            bottom_center_reg <= pixel_pipe_reg[16:9];
            if (column_pipe_reg == IMG_HDISP - 11'd1) begin
                tail_pending_reg <= 1'b1;
            end
        end
    end
    if (rst) begin
        window_vsync_reg <= 1'b0;
        window_href_reg <= 1'b0;
        window_clken_reg <= 1'b0;
        line_active_reg <= 1'b0;
        tail_pending_reg <= 1'b0;
        top_left_reg <= 8'd0;
        top_center_reg <= 8'd0;
        middle_left_reg <= 8'd0;
        middle_center_reg <= {DATA_WIDTH{1'b0}};
        bottom_left_reg <= 8'd0;
        bottom_center_reg <= 8'd0;
        window_p11_reg <= 8'd0;
        window_p12_reg <= 8'd0;
        window_p13_reg <= 8'd0;
        window_p21_reg <= 8'd0;
        window_p22_reg <= {DATA_WIDTH{1'b0}};
        window_p23_reg <= 8'd0;
        window_p31_reg <= 8'd0;
        window_p32_reg <= 8'd0;
        window_p33_reg <= 8'd0;
    end
end

endmodule
`resetall
