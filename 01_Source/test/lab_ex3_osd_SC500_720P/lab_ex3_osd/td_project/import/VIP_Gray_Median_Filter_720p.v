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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row1_low  <= 8'd0;
        row1_mid  <= 8'd0;
        row1_high <= 8'd0;
        row2_low  <= 8'd0;
        row2_mid  <= 8'd0;
        row2_high <= 8'd0;
        row3_low  <= 8'd0;
        row3_mid  <= 8'd0;
        row3_high <= 8'd0;
    end else begin
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
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        low_max    <= 8'd0;
        mid_median <= 8'd0;
        high_min   <= 8'd0;
    end else begin
        low_max    <= max3(row1_low, row2_low, row3_low);
        mid_median <= median3(row1_mid, row2_mid, row3_mid);
        high_min   <= min3(row1_high, row2_high, row3_high);
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        median_value <= 8'd0;
    else
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
