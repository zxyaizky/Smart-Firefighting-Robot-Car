// 1280x720 grayscale 3x3 median filter.
// The window generator is shared with Sobel_Edge_Detector so that both
// algorithms use exactly the same line-buffer and border handling.
module VIP_Gray_Median_Filter_720p #(
    parameter [10:0] IMG_HDISP    = 11'd1280,
    parameter        SPARSE_INPUT = 1'b0
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       pe_frame_vsync,
    input  wire       pe_frame_href,
    input  wire       pe_frame_clken,
    input  wire [7:0] pe_img_Y,

    output wire       pos_frame_vsync,
    output wire       pos_frame_href,
    output wire       pos_frame_clken,
    output wire [7:0] pos_img_Y
);

wire       matrix_frame_vsync;
wire       matrix_frame_href;
wire       matrix_frame_clken;
wire [7:0] matrix_p11;
wire [7:0] matrix_p12;
wire [7:0] matrix_p13;
wire [7:0] matrix_p21;
wire [7:0] matrix_p22;
wire [7:0] matrix_p23;
wire [7:0] matrix_p31;
wire [7:0] matrix_p32;
wire [7:0] matrix_p33;

// Reuse the 3x3 matrix generator instantiated by the Sobel edge detector.
// A 3x3 window only needs the horizontal resolution; 720 lines are carried
// transparently by the frame timing signals.
Matrix_Generate_3X3_8Bit #(
    .IMG_HDISP   (IMG_HDISP),
    .SPARSE_INPUT(SPARSE_INPUT)
) u_Matrix_Generate_3X3_8Bit_median (
    .clk                (clk),
    .rst_n              (rst_n),
    .per_frame_vsync    (pe_frame_vsync),
    .per_frame_href     (pe_frame_href),
    .per_frame_clken    (pe_frame_clken),
    .per_img_Y          (pe_img_Y),
    .matrix_frame_vsync (matrix_frame_vsync),
    .matrix_frame_href  (matrix_frame_href),
    .matrix_frame_clken (matrix_frame_clken),
    .matrix_p11         (matrix_p11),
    .matrix_p12         (matrix_p12),
    .matrix_p13         (matrix_p13),
    .matrix_p21         (matrix_p21),
    .matrix_p22         (matrix_p22),
    .matrix_p23         (matrix_p23),
    .matrix_p31         (matrix_p31),
    .matrix_p32         (matrix_p32),
    .matrix_p33         (matrix_p33)
);

median_3x3_8bit_core u_core (
    .clk(clk),
    .rst_n(rst_n),
    .matrix_frame_vsync(matrix_frame_vsync),
    .matrix_frame_href(matrix_frame_href),
    .matrix_frame_clken(matrix_frame_clken),
    .matrix_p11(matrix_p11),
    .matrix_p12(matrix_p12),
    .matrix_p13(matrix_p13),
    .matrix_p21(matrix_p21),
    .matrix_p22(matrix_p22),
    .matrix_p23(matrix_p23),
    .matrix_p31(matrix_p31),
    .matrix_p32(matrix_p32),
    .matrix_p33(matrix_p33),
    .pos_frame_vsync(pos_frame_vsync),
    .pos_frame_href(pos_frame_href),
    .pos_frame_clken(pos_frame_clken),
    .pos_img_Y(pos_img_Y)
);
endmodule

module median_3x3_8bit_core (
    input wire clk, rst_n,
    input wire matrix_frame_vsync, matrix_frame_href, matrix_frame_clken,
    input wire [7:0] matrix_p11,
    input wire [7:0] matrix_p12,
    input wire [7:0] matrix_p13,
    input wire [7:0] matrix_p21,
    input wire [7:0] matrix_p22,
    input wire [7:0] matrix_p23,
    input wire [7:0] matrix_p31,
    input wire [7:0] matrix_p32,
    input wire [7:0] matrix_p33,
    output wire pos_frame_vsync, pos_frame_href, pos_frame_clken,
    output wire [7:0] pos_img_Y
);
reg [2:0] frame_vsync_d;
reg [2:0] frame_href_d;
reg [2:0] frame_clken_d;

// Pipeline stage 1: sort each row into low/middle/high values.
reg [7:0] row1_low;
reg [7:0] row1_mid;
reg [7:0] row1_high;
reg [7:0] row2_low;
reg [7:0] row2_mid;
reg [7:0] row2_high;
reg [7:0] row3_low;
reg [7:0] row3_mid;
reg [7:0] row3_high;

// Pipeline stage 2: reduce the three sorted rows to three candidates.
reg [7:0] low_max;
reg [7:0] mid_median;
reg [7:0] high_min;

// Pipeline stage 3: median of the three candidates is the median of all 9.
reg [7:0] median_value;

// Use the SAME strict comparisons for low/middle/high. Equal inputs
// have equal output values, so this also preserves all tie cases exactly.
function [7:0] min3;
    input [7:0] a;
    input [7:0] b;
    input [7:0] c;
    reg ab, ac, bc;
    begin
        ab = a > b;
        ac = a > c;
        bc = b > c;
        min3 = ab ? (bc ? c : b) : (ac ? c : a);
    end
endfunction

// Use the SAME strict comparisons for low/middle/high. Equal inputs
// have equal output values, so this also preserves all tie cases exactly.
function [7:0] max3;
    input [7:0] a;
    input [7:0] b;
    input [7:0] c;
    reg ab, ac, bc;
    begin
        ab = a > b;
        ac = a > c;
        bc = b > c;
        max3 = ab ? (ac ? a : c) : (bc ? b : c);
    end
endfunction

// Use the SAME strict comparisons for low/middle/high. Equal inputs
// have equal output values, so this also preserves all tie cases exactly.
function [7:0] median3;
    input [7:0] a;
    input [7:0] b;
    input [7:0] c;
    reg ab, ac, bc;
    begin
        ab = a > b;
        ac = a > c;
        bc = b > c;
        median3 = ab ? (bc ? b : (ac ? c : a)) : (ac ? a : (bc ? c : b));
    end
endfunction

assign pos_frame_vsync = frame_vsync_d[2];
assign pos_frame_href  = frame_href_d[2];
assign pos_frame_clken = frame_clken_d[2];
assign pos_img_Y = (pos_frame_href && pos_frame_clken) ?
                   median_value : 8'd0;

// Data advances on every clock, independent of reset. Reset clears all three
// valid stages below, so uninitialized/interrupted arithmetic is never exposed.
// This lets data FFs pack without a reset control shared with adjacent FFs.
always @(posedge clk) begin
        row1_low  <= min3(matrix_p11, matrix_p12, matrix_p13);
        row1_mid  <= median3(matrix_p11, matrix_p12, matrix_p13);
        row1_high <= max3(matrix_p11, matrix_p12, matrix_p13);
        row2_low  <= min3(matrix_p21, matrix_p22, matrix_p23);
        row2_mid  <= median3(matrix_p21, matrix_p22, matrix_p23);
        row2_high <= max3(matrix_p21, matrix_p22, matrix_p23);
        row3_low  <= min3(matrix_p31, matrix_p32, matrix_p33);
        row3_mid  <= median3(matrix_p31, matrix_p32, matrix_p33);
        row3_high <= max3(matrix_p31, matrix_p32, matrix_p33);
end

always @(posedge clk) begin
        low_max    <= max3(row1_low, row2_low, row3_low);
        mid_median <= median3(row1_mid, row2_mid, row3_mid);
        high_min   <= min3(row1_high, row2_high, row3_high);
end

always @(posedge clk) begin
    median_value <= median3(low_max, mid_median, high_min);
end

// Align the video timing with the three median-filter pipeline stages.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_vsync_d <= 3'd0;
        frame_href_d  <= 3'd0;
        frame_clken_d <= 3'd0;
    end else begin
        frame_vsync_d <= {frame_vsync_d[1:0], matrix_frame_vsync};
        frame_href_d  <= {frame_href_d[1:0], matrix_frame_href};
        frame_clken_d <= {frame_clken_d[1:0], matrix_frame_clken};
    end
end

endmodule

// One RGB window shares row addresses, frame history and horizontal controls.
// Each channel keeps the exact original three-stage median arithmetic.
module rgb_median_filter_3x3 #(
    parameter [10:0] IMG_HDISP = 11'd1280
)(
    input wire clk, rst_n, pe_frame_vsync, pe_frame_href, pe_frame_clken,
    input wire [23:0] pe_img_rgb,
    output wire pos_frame_vsync, pos_frame_href, pos_frame_clken,
    output wire [23:0] pos_img_rgb
);
    wire matrix_frame_vsync, matrix_frame_href, matrix_frame_clken;
    wire [23:0] p11;
    wire [23:0] p12;
    wire [23:0] p13;
    wire [23:0] p21;
    wire [23:0] p22;
    wire [23:0] p23;
    wire [23:0] p31;
    wire [23:0] p32;
    wire [23:0] p33;

    wire [2:0] channel_vs, channel_href, channel_clken;
    assign pos_frame_vsync = channel_vs[0];
    assign pos_frame_href = channel_href[0];
    assign pos_frame_clken = channel_clken[0];
    Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .DATA_WIDTH(24)) u_rgb_window (
        .clk(clk), .rst_n(rst_n), .per_frame_vsync(pe_frame_vsync),
        .per_frame_href(pe_frame_href), .per_frame_clken(pe_frame_clken),
        .per_img_Y(pe_img_rgb), .matrix_frame_vsync(matrix_frame_vsync),
        .matrix_frame_href(matrix_frame_href), .matrix_frame_clken(matrix_frame_clken),
        .matrix_p11(p11),
        .matrix_p12(p12),
        .matrix_p13(p13),
        .matrix_p21(p21),
        .matrix_p22(p22),
        .matrix_p23(p23),
        .matrix_p31(p31),
        .matrix_p32(p32),
        .matrix_p33(p33)
    );
    genvar c;
    generate for(c=0;c<3;c=c+1) begin : g_channel
        median_3x3_8bit_core u_core (
            .clk(clk), .rst_n(rst_n), .matrix_frame_vsync(matrix_frame_vsync),
            .matrix_frame_href(matrix_frame_href), .matrix_frame_clken(matrix_frame_clken),
            .matrix_p11(p11[c*8 +: 8]),
            .matrix_p12(p12[c*8 +: 8]),
            .matrix_p13(p13[c*8 +: 8]),
            .matrix_p21(p21[c*8 +: 8]),
            .matrix_p22(p22[c*8 +: 8]),
            .matrix_p23(p23[c*8 +: 8]),
            .matrix_p31(p31[c*8 +: 8]),
            .matrix_p32(p32[c*8 +: 8]),
            .matrix_p33(p33[c*8 +: 8]),
            .pos_frame_vsync(channel_vs[c]), .pos_frame_href(channel_href[c]),
            .pos_frame_clken(channel_clken[c]), .pos_img_Y(pos_img_rgb[c*8 +: 8])
        );
    end endgenerate
endmodule
