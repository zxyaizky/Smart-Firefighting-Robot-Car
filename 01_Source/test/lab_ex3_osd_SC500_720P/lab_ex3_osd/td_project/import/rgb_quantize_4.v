// -----------------------------------------------------------------------------
// File   : rgb_quantize_4.v
// Author : unknown
// Date   : 2026-10-01
// -----------------------------------------------------------------------------
// Description:
//   Cartoon processing: median, shadow lift, six colour bands and dark contours.
//   Contour gradients and RGB share one window and three arithmetic stages.
// -----------------------------------------------------------------------------
// Change Log:
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
wire [9:0] luma_sum;
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
wire [23:0] color_p11;
wire [23:0] color_p12;
wire [23:0] color_p13;
wire [23:0] color_p21;
wire [23:0] color_p22;
wire [23:0] color_p23;
wire [23:0] color_p31;
wire [23:0] color_p32;
wire [23:0] color_p33;
wire [9:0] horizontal_abs;
wire [9:0] vertical_abs;
wire [9:0] neighbor_luma_sum;
wire [7:0] center_luma;
wire contour_active;

reg [23:0] rgb_aligned_d0;
reg [23:0] rgb_aligned_d1;
reg [23:0] rgb_aligned_d2;
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
reg [23:0] center_rgb_d0_reg;
reg [23:0] center_rgb_d1_reg;
reg [23:0] center_rgb_d2_reg;
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
    reg   [8:0] delta;
    reg   [8:0] expanded;
    begin
        delta = 9'd0;
        expanded = 9'd0;
        if (colour >= neutral) begin
            delta    = {1'b0, colour} - {1'b0, neutral};
            expanded = {1'b0, colour} + ((delta + 9'd2) >> 2);
            saturate_5_over_4 = expanded[8] ? 8'hff : expanded[7:0];
        end else begin
            delta = {1'b0, neutral} - {1'b0, colour};
            if ({1'b0, colour} <= ((delta + 9'd2) >> 2)) begin
                saturate_5_over_4 = 8'h00;
            end else begin
                expanded = {1'b0, colour} - ((delta + 9'd2) >> 2);
                saturate_5_over_4 = expanded[7:0];
            end
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
        lifted_r_reg <= 8'd0;
        lifted_g_reg <= 8'd0;
        lifted_b_reg <= 8'd0;
        lifted_vsync_reg <= 1'b0;
        lifted_href_reg <= 1'b0;
        lifted_clken_reg <= 1'b0;
    end else begin
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
        Matrix_Generate_3X3_8Bit #(
            .IMG_HDISP    (IMG_HDISP),
            .DATA_WIDTH   (24)
        ) color_window_inst (
            .clk                (S_hdmi_pixel_clk),
            .rst_n              (S_hdmi_rst_n),
            .per_frame_vsync    (lifted_vsync_reg),
            .per_frame_href     (lifted_href_reg),
            .per_frame_clken    (lifted_clken_reg),
            .per_img_Y          ({lifted_r_reg, lifted_g_reg, lifted_b_reg}),
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
        assign color_p11 = 24'd0;
        assign color_p12 = 24'd0;
        assign color_p13 = 24'd0;
        assign color_p21 = 24'd0;
        assign color_p22 = {lifted_r_reg, lifted_g_reg, lifted_b_reg};
        assign color_p23 = 24'd0;
        assign color_p31 = 24'd0;
        assign color_p32 = 24'd0;
        assign color_p33 = 24'd0;
    end
endgenerate

assign horizontal_abs = (right_sum_reg >= left_sum_reg) ?
                        right_sum_reg - left_sum_reg : left_sum_reg - right_sum_reg;
assign vertical_abs = (bottom_sum_reg >= top_sum_reg) ?
                      bottom_sum_reg - top_sum_reg : top_sum_reg - bottom_sum_reg;
assign neighbor_luma_sum = {2'd0, luma_p12_reg} + {2'd0, luma_p21_reg} +
                           {2'd0, luma_p23_reg} + {2'd0, luma_p32_reg} + 10'd2;
assign center_luma = rgb_luma(center_rgb_d0_reg);
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
        center_rgb_d0_reg <= 24'd0;
        center_rgb_d1_reg <= 24'd0;
        center_rgb_d2_reg <= 24'd0;
        color_vsync_pipe_reg <= 3'd0;
        color_href_pipe_reg <= 3'd0;
        color_clken_pipe_reg <= 3'd0;
    end else begin
        luma_p11_reg <= rgb_luma(color_p11);
        luma_p12_reg <= rgb_luma(color_p12);
        luma_p13_reg <= rgb_luma(color_p13);
        luma_p21_reg <= rgb_luma(color_p21);
        luma_p23_reg <= rgb_luma(color_p23);
        luma_p31_reg <= rgb_luma(color_p31);
        luma_p32_reg <= rgb_luma(color_p32);
        luma_p33_reg <= rgb_luma(color_p33);
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

assign luma_sum = {2'b00, center_rgb_d2_reg[23:16]} +
                  {1'b0, center_rgb_d2_reg[15:8], 1'b0} +
                  {2'b00, center_rgb_d2_reg[7:0]} + 10'd2;
assign luma = luma_sum[9:2];

assign saturated_r = saturate_5_over_4(center_rgb_d2_reg[23:16], luma);
assign saturated_g = saturate_5_over_4(center_rgb_d2_reg[15:8], luma);
assign saturated_b = saturate_5_over_4(center_rgb_d2_reg[7:0], luma);

assign quantized_r = (COLOR_LEVELS == 8) ? quantize_8_level(saturated_r) :
                    quantize_6_level(saturated_r);
assign quantized_g = (COLOR_LEVELS == 8) ? quantize_8_level(saturated_g) :
                    quantize_6_level(saturated_g);
assign quantized_b = (COLOR_LEVELS == 8) ? quantize_8_level(saturated_b) :
                    quantize_6_level(saturated_b);

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
