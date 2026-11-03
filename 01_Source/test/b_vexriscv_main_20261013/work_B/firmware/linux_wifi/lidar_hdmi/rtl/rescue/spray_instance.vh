    // A sustained fire result consumes one burst, rather than spraying continuously.
    wire S_fire_spray_enable;
    fire_spray_burst #(.CLK_HZ(FIRE_CONTROL_CLK_HZ)) u_fire_spray_burst (
        .clk(S_hdmi_pixel_clk), .rst(S_fire_ctrl_rst),
        .fire_present_i(S_rescue_yellow_fire_valid && !S_rescue_color_bad),
        .qualified_i(FIRE_SERVO_POSITION_MODE ? S_fire_position_pump_enable : S_fire_pump_enable),
        .allowed_i(S_rescue_fire_allow_pixel && S_fire_ctrl_valid &&
                   !SERVO_TEST_MODE && !PUMP_MANUAL_TEST_MODE),
        .pump_enable_o(S_fire_spray_enable)
    );
