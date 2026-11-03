// -----------------------------------------------------------------------------
// File   : Sobel_Edge_Detector.v
// Author : unknown
// Date   : 2026-10-01
// -----------------------------------------------------------------------------
// Description:
//   Sobel L1 gradient with directional nonmaximum suppression. Keep the original
//   threshold scale and ports; suppress plateaus deterministically to thin edges.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-01  unknown  v2.0  Frame-safe windows and directional edge thinning.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module Sobel_Edge_Detector #
(
    // Complete line width.
    parameter [10:0] IMG_HDISP = 11'd1280,
    // Compatibility with continuous and pixel-enabled input streams.
    parameter SPARSE_INPUT = 1'b0,
    // Threshold for |Gx| + |Gy|, range 0..2040.
    parameter [10:0] FIXED_THRESHOLD = 11'd80,
    // Disable to compare against unthinned Sobel using the same corrected window.
    parameter NMS_ENABLE = 1'b1
)
(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       per_frame_vsync,
    input  wire       per_frame_href,
    input  wire       per_frame_clken,
    input  wire [7:0] per_img_Y,
    output wire       post_frame_vsync,
    output wire       post_frame_href,
    output wire       post_frame_clken,
    output wire       post_img_Bit
);

wire rst;
wire matrix_vsync;
wire matrix_href;
wire matrix_clken;
wire [7:0] pixel_p11;
wire [7:0] pixel_p12;
wire [7:0] pixel_p13;
wire [7:0] pixel_p21;
wire [7:0] pixel_p22;
wire [7:0] pixel_p23;
wire [7:0] pixel_p31;
wire [7:0] pixel_p32;
wire [7:0] pixel_p33;
wire [9:0] horizontal_abs;
wire [9:0] vertical_abs;
wire [12:0] gradient_pixel;
wire nms_vsync;
wire nms_href;
wire nms_clken;
wire [12:0] gradient_p11;
wire [12:0] gradient_p12;
wire [12:0] gradient_p13;
wire [12:0] gradient_p21;
wire [12:0] gradient_p22;
wire [12:0] gradient_p23;
wire [12:0] gradient_p31;
wire [12:0] gradient_p32;
wire [12:0] gradient_p33;

reg [9:0] right_sum_reg = 10'd0;
reg [9:0] left_sum_reg = 10'd0;
reg [9:0] bottom_sum_reg = 10'd0;
reg [9:0] top_sum_reg = 10'd0;
reg [9:0] horizontal_abs_reg = 10'd0;
reg [9:0] vertical_abs_reg = 10'd0;
reg same_sign_reg = 1'b0;
reg [10:0] magnitude_reg = 11'd0;
reg [1:0] direction_reg = 2'd0;
reg [2:0] vsync_pipe_reg = 3'd0;
reg [2:0] href_pipe_reg = 3'd0;
reg [2:0] clken_pipe_reg = 3'd0;
reg [10:0] forward_neighbor;
reg [10:0] backward_neighbor;
reg output_vsync_reg = 1'b0;
reg output_href_reg = 1'b0;
reg output_clken_reg = 1'b0;
reg edge_reg = 1'b0;

assign rst = !rst_n;
wire [10:0] h_delta = {1'b0,right_sum_reg} - {1'b0,left_sum_reg};
wire [10:0] v_delta = {1'b0,bottom_sum_reg} - {1'b0,top_sum_reg};
assign horizontal_abs = h_delta[10] ? (~h_delta[9:0] + 10'd1) : h_delta[9:0];
assign vertical_abs = v_delta[10] ? (~v_delta[9:0] + 10'd1) : v_delta[9:0];
assign gradient_pixel = {direction_reg, magnitude_reg};
assign post_frame_vsync = output_vsync_reg;
assign post_frame_href  = output_href_reg;
assign post_frame_clken = output_clken_reg;
assign post_img_Bit = output_href_reg && output_clken_reg && edge_reg;

Matrix_Generate_3X3_8Bit #(
    .IMG_HDISP    (IMG_HDISP),
    .SPARSE_INPUT (SPARSE_INPUT)
) pixel_window_inst (
    .clk                (clk),
    .rst_n              (rst_n),
    .per_frame_vsync    (per_frame_vsync),
    .per_frame_href     (per_frame_href),
    .per_frame_clken    (per_frame_clken),
    .per_img_Y          (per_img_Y),
    .matrix_frame_vsync (matrix_vsync),
    .matrix_frame_href  (matrix_href),
    .matrix_frame_clken (matrix_clken),
    .matrix_p11         (pixel_p11),
    .matrix_p12         (pixel_p12),
    .matrix_p13         (pixel_p13),
    .matrix_p21         (pixel_p21),
    .matrix_p22         (pixel_p22),
    .matrix_p23         (pixel_p23),
    .matrix_p31         (pixel_p31),
    .matrix_p32         (pixel_p32),
    .matrix_p33         (pixel_p33)
);

// Three arithmetic stages. Control always advances in clocks, including gaps.
always @(posedge clk) begin
    right_sum_reg <= {2'd0, pixel_p13} + {1'b0, pixel_p23, 1'b0} +
                     {2'd0, pixel_p33};
    left_sum_reg <= {2'd0, pixel_p11} + {1'b0, pixel_p21, 1'b0} +
                    {2'd0, pixel_p31};
    bottom_sum_reg <= {2'd0, pixel_p31} + {1'b0, pixel_p32, 1'b0} +
                      {2'd0, pixel_p33};
    top_sum_reg <= {2'd0, pixel_p11} + {1'b0, pixel_p12, 1'b0} +
                   {2'd0, pixel_p13};
    horizontal_abs_reg <= horizontal_abs;
    vertical_abs_reg <= vertical_abs;
    same_sign_reg <= (!h_delta[10]) ==
                     (!v_delta[10]);
    magnitude_reg <= {1'b0, horizontal_abs_reg} + {1'b0, vertical_abs_reg};
    // Four gradient sectors; avoid division and signed-width ambiguity.
    if (vertical_abs_reg <= (horizontal_abs_reg >> 1)) begin
        direction_reg <= 2'd0;
    end else if (horizontal_abs_reg <= (vertical_abs_reg >> 1)) begin
        direction_reg <= 2'd1;
    end else begin
        direction_reg <= same_sign_reg ? 2'd2 : 2'd3;
    end
    vsync_pipe_reg <= {vsync_pipe_reg[1:0], matrix_vsync};
    href_pipe_reg <= {href_pipe_reg[1:0], matrix_href};
    clken_pipe_reg <= {clken_pipe_reg[1:0], matrix_clken};
    if (rst) begin
        right_sum_reg <= 10'd0;
        left_sum_reg <= 10'd0;
        bottom_sum_reg <= 10'd0;
        top_sum_reg <= 10'd0;
        horizontal_abs_reg <= 10'd0;
        vertical_abs_reg <= 10'd0;
        same_sign_reg <= 1'b0;
        magnitude_reg <= 11'd0;
        direction_reg <= 2'd0;
        vsync_pipe_reg <= 3'd0;
        href_pipe_reg <= 3'd0;
        clken_pipe_reg <= 3'd0;
    end
end

generate
    if (NMS_ENABLE) begin : g_thinned_edges
        Matrix_Generate_3X3_8Bit #(
            .IMG_HDISP    (IMG_HDISP),
            .SPARSE_INPUT (SPARSE_INPUT),
            .DATA_WIDTH   (13)
        ) gradient_window_inst (
            .clk                (clk),
            .rst_n              (rst_n),
            .per_frame_vsync    (vsync_pipe_reg[2]),
            .per_frame_href     (href_pipe_reg[2]),
            .per_frame_clken    (clken_pipe_reg[2]),
            .per_img_Y          (gradient_pixel),
            .matrix_frame_vsync (nms_vsync),
            .matrix_frame_href  (nms_href),
            .matrix_frame_clken (nms_clken),
            .matrix_p11         (gradient_p11),
            .matrix_p12         (gradient_p12),
            .matrix_p13         (gradient_p13),
            .matrix_p21         (gradient_p21),
            .matrix_p22         (gradient_p22),
            .matrix_p23         (gradient_p23),
            .matrix_p31         (gradient_p31),
            .matrix_p32         (gradient_p32),
            .matrix_p33         (gradient_p33)
        );
    end else begin : g_unthinned_edges
        assign nms_vsync = vsync_pipe_reg[2];
        assign nms_href  = href_pipe_reg[2];
        assign nms_clken = clken_pipe_reg[2];
        assign gradient_p11 = 13'd0;
        assign gradient_p12 = 13'd0;
        assign gradient_p13 = 13'd0;
        assign gradient_p21 = 13'd0;
        assign gradient_p22 = gradient_pixel;
        assign gradient_p23 = 13'd0;
        assign gradient_p31 = 13'd0;
        assign gradient_p32 = 13'd0;
        assign gradient_p33 = 13'd0;
    end
endgenerate

always @* begin
    forward_neighbor = 11'd0;
    backward_neighbor = 11'd0;
    case (gradient_p22[12:11])
        2'd0: begin
            forward_neighbor = gradient_p23[10:0];
            backward_neighbor = gradient_p21[10:0];
        end
        2'd1: begin
            forward_neighbor = gradient_p32[10:0];
            backward_neighbor = gradient_p12[10:0];
        end
        2'd2: begin
            forward_neighbor = gradient_p33[10:0];
            backward_neighbor = gradient_p11[10:0];
        end
        2'd3: begin
            forward_neighbor = gradient_p31[10:0];
            backward_neighbor = gradient_p13[10:0];
        end
        default: begin
            forward_neighbor = 11'd0;
            backward_neighbor = 11'd0;
        end
    endcase
end

// One strict comparison breaks equal-gradient plateaus in a fixed direction.
always @(posedge clk) begin
    output_vsync_reg <= nms_vsync;
    output_href_reg <= nms_href;
    output_clken_reg <= nms_clken;
    edge_reg <= (gradient_p22[10:0] >= FIXED_THRESHOLD) &&
                ((NMS_ENABLE == 1'b0) ||
                 ((gradient_p22[10:0] > forward_neighbor) &&
                  (gradient_p22[10:0] >= backward_neighbor)));
    if (rst) begin
        output_vsync_reg <= 1'b0;
        output_href_reg <= 1'b0;
        output_clken_reg <= 1'b0;
        edge_reg <= 1'b0;
    end
end

endmodule
`resetall
