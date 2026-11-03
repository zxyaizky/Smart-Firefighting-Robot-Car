    // BEGIN LOCAL_DISPLAY_EFFECTS
    wire [7:0] S_median_y;
    wire S_median_vsync, S_median_href, S_median_clken, S_median_de;
    wire S_sobel_vsync, S_sobel_href, S_sobel_clken, S_sobel_de, S_sobel_bit;
    wire [23:0] S_sobel_rgb, S_quant4_center_out;
    wire S_quant4_vsync, S_quant4_de;
    wire [23:0] S_clean_camera_rgb;
    wire S_clean_camera_de, S_clean_camera_vs;

    // Repair original display only. Recognition still receives pre-OSD RGB.
    rgb_green_impulse_filter u_rgb_green_impulse_filter (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .rgb_i(S_hdmi_out_data), .de_i(S_hdmi_out_de), .vsync_i(S_hdmi_out_vsync),
        .rgb_o(S_clean_camera_rgb), .de_o(S_clean_camera_de), .vsync_o(S_clean_camera_vs)
    );

//=========================================================
// 720P灰度3x3中值滤波：位于灰度转换之后、Sobel之前
//=========================================================
VIP_Gray_Median_Filter_720p #(
    .IMG_HDISP    (11'd1280),
    .SPARSE_INPUT (1'b0)
) u_VIP_Gray_Median_Filter_720p (
    .clk              (S_hdmi_pixel_clk),
    .rst_n            (S_hdmi_rst_n),

    .pe_frame_vsync   (S_ycbcr_vsync),
    .pe_frame_href    (S_ycbcr_de),
    .pe_frame_clken   (S_ycbcr_de),
    .pe_img_Y         (S_img_y),

    .pos_frame_vsync  (S_median_vsync),
    .pos_frame_href   (S_median_href),
    .pos_frame_clken  (S_median_clken),
    .pos_img_Y        (S_median_y)
);

assign S_median_de = S_median_href && S_median_clken;

//=========================================================
// Sobel边缘检测：中值去噪 + 梯度方向非极大值抑制，输出细轮廓
//=========================================================
Sobel_Edge_Detector #(
    .IMG_HDISP       (11'd1280),
    .SPARSE_INPUT    (1'b0),
    .FIXED_THRESHOLD (11'd60),
    .NMS_ENABLE      (1'b1)
) u_Sobel_Edge_Detector (
    .clk              (S_hdmi_pixel_clk),
    .rst_n            (S_hdmi_rst_n),

    .per_frame_vsync  (S_median_vsync),
    .per_frame_href   (S_median_href),
    .per_frame_clken  (S_median_clken),
    .per_img_Y        (S_median_y),

    .post_frame_vsync (S_sobel_vsync),
    .post_frame_href  (S_sobel_href),
    .post_frame_clken (S_sobel_clken),
    .post_img_Bit     (S_sobel_bit)
);

assign S_sobel_de = S_sobel_href && S_sobel_clken;

// 1位边缘转换成RGB888：白色边缘、黑色背景
assign S_sobel_rgb = S_sobel_bit ? 24'hFFFFFF : 24'h000000;

//卡通风格：保留暗部提亮、6级色块分层、强轮廓深色描边
 rgb_quantize_4 #(
    .COLOR_LEVELS      (6),
    .OUTLINE_ENABLE    (1'b1),
    .OUTLINE_THRESHOLD (11'd180)
 ) u_rgb_quantize_8
(
    .rgb_in                 (S_hdmi_out_data)       ,
    .S_hdmi_pixel_clk       (S_hdmi_pixel_clk)       ,
    .S_hdmi_rst_n           (S_hdmi_rst_n)       ,
    .S_ycbcr_vsync          (S_ycbcr_vsync)       ,
    .S_ycbcr_de             (S_ycbcr_de)       ,
    .S_quant4_center_d3     (S_quant4_center_out),
    .S_quant4_vsync         (S_quant4_vsync),
    .S_quant4_de            (S_quant4_de)
);


    // END LOCAL_DISPLAY_EFFECTS
