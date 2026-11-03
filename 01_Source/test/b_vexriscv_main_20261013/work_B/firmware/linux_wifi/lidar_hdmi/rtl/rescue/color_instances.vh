    // Shared pre-OSD detections feed video boxes, Linux semantic MMIO and control.
    wire S_rescue_green_valid, S_rescue_yellow_valid;
    wire S_rescue_yellow_fire_valid, S_rescue_yellow_fire_sample;
    wire [11:0] S_rescue_yellow_center_sum = {1'b0,S_hsv_yellow_bbox_xmin} + {1'b0,S_hsv_yellow_bbox_xmax};
    wire [10:0] S_rescue_yellow_center = S_rescue_yellow_center_sum[11:1];
    // Reserved legacy red MMIO/overlay inputs stay inactive; no red classifier.
    assign S_hsv_bbox_result_valid = S_rescue_color_update;
    assign S_hsv_bbox_valid = 1'b0;
    assign S_hsv_bbox_xmin = 0; assign S_hsv_bbox_xmax = 0;
    assign S_hsv_bbox_ymin = 0; assign S_hsv_bbox_ymax = 0;
    color_green_yellow_frame #(.IMG_HDISP(1280), .IMG_VDISP(720), .DENOISE_ENABLE(1),
        .CLK_FREQ_HZ(75000000), .RESULT_TIMEOUT_MS(5000))
    u_rescue_color (
        .clk(S_hdmi_pixel_clk), .rst(~S_video_out_rst_n || S_left_video_error),
        .pixel_rgb_i(S_hsv_sample_rgb), .pixel_valid_i(S_hsv_sample_valid),
        .pixel_x_i(S_hsv_sample_x), .pixel_y_i(S_hsv_sample_y),
        .frame_start_i(S_hsv_sample_start), .frame_end_i(S_hsv_sample_end),
        .frame_abort_i(S_hsv_sample_abort),
        .green_s_min_i(8'd55), .green_s_max_i(8'd255),
        .green_v_min_i(8'd70), .green_v_max_i(8'd255),
        .color_o(S_rescue_color), .result_update_o(S_rescue_color_update),
        .bbox_valid_o(S_rescue_color_valid),
        .bbox_x1_o(S_rescue_color_x1), .bbox_x2_o(S_rescue_color_x2),
        .bbox_y1_o(S_rescue_color_y1), .bbox_y2_o(S_rescue_color_y2),
        .green_valid_o(S_rescue_green_valid), .yellow_valid_o(S_rescue_yellow_valid),
        .green_x1_o(S_hsv_green_bbox_xmin), .green_x2_o(S_hsv_green_bbox_xmax),
        .green_y1_o(S_hsv_green_bbox_ymin), .green_y2_o(S_hsv_green_bbox_ymax),
        .yellow_x1_o(S_hsv_yellow_bbox_xmin), .yellow_x2_o(S_hsv_yellow_bbox_xmax),
        .yellow_y1_o(S_hsv_yellow_bbox_ymin), .yellow_y2_o(S_hsv_yellow_bbox_ymax),
        .yellow_fire_valid_o(S_rescue_yellow_fire_valid), .yellow_fire_sample_o(S_rescue_yellow_fire_sample)
    );
    assign S_hsv_green_bbox_result_valid = S_rescue_color_update;
    assign S_hsv_yellow_bbox_result_valid = S_rescue_color_update;
    assign S_hsv_green_bbox_valid = S_rescue_green_valid;
    assign S_hsv_yellow_bbox_valid = S_rescue_yellow_valid;
    // END SHARED_COLOR_DETECTIONS
