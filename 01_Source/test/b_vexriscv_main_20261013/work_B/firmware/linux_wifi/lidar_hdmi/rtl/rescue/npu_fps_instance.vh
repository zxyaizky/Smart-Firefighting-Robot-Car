    // BEGIN NPU_FPS_OVERLAY
    wire [23:0] S_npu_fps_hdmi_rgb;
    npu_fps_overlay #(.CLK_HZ(75000000)) u_npu_fps_overlay (
        .clk(S_hdmi_pixel_clk), .rst(!S_hdmi_rst_n),
        .result_frame_end_i(S_eth_rx_frame_end),
        .result_bad_i(S_eth_rx_frame_abort || S_eth_rx_fifo_underflow),
        .result_source_valid_i(S_eth_rx_bbox_source_valid),
        .result_id_i(S_eth_rx_bbox_result_id),
        .video_vsync_i(S_lidar_hdmi_vs), .video_de_i(S_lidar_hdmi_de),
        .video_rgb_i(S_lidar_hdmi_rgb), .video_rgb_o(S_npu_fps_hdmi_rgb)
    );
    // END NPU_FPS_OVERLAY

