    // One confirmed green OR yellow box; geometry and colour commit together.
    // The same source publishes both legacy valid aliases on the same clock.
    rescue_color_bbox_overlay #(
        .X_WIDTH(11), .Y_WIDTH(10), .COORD_SHIFT(0),
        .BOX_THICKNESS(3'd2), .BOX_INSET(4'd0)
    ) u_rescue_color_overlay (
        .clk(S_hdmi_pixel_clk), .rst(~S_hdmi_rst_n),
        .rgb_i(S_hsv_overlay_rgb), .de_i(S_hsv_overlay_de),
        .hsync_i(1'b0), .vsync_i(S_hsv_overlay_vsync),
        .pixel_x_i(stereo_pixel_x_reg), .pixel_y_i(stereo_pixel_y_reg),
        .result_valid_i(S_hsv_green_bbox_result_valid),
        .bbox_valid_i(S_rescue_color_valid),
        .box_yellow_i(S_rescue_color == 2'd2),
        .xmin_i(S_rescue_color_x1), .xmax_i(S_rescue_color_x2),
        .ymin_i(S_rescue_color_y1), .ymax_i(S_rescue_color_y2),
        .source_frame_valid_i(S_hsv_bbox_source_frame_valid),
        .source_frame_id_i(S_hsv_bbox_source_frame_id),
        .rgb_o(S_hsv_yellow_overlay_rgb), .de_o(), .hsync_o(), .vsync_o(),
        .active_valid_o(), .active_source_frame_id_o(),
        .display_xmin_o(), .display_xmax_o(), .display_ymin_o(), .display_ymax_o(),
        .draw_hit_o(), .clear_reason_o()
    );
