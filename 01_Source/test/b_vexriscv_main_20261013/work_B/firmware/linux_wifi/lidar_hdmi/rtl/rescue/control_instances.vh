    // BEGIN B_RESCUE_CONTROL
    // Metadata only. No memory master, framebuffer access or video backpressure.
    wire [2:0] S_car_cmd_code;
    wire S_car_cmd_valid, S_car_cmd_ready;
    wire [3:0] S_rescue_updates, S_rescue_flags, S_rescue_voice_flags;
    wire [15:0] S_rescue_mm;
    wire S_rescue_range_valid, S_rescue_fire_allow, S_rescue_green_clear;
    wire S_arm_request, S_arm_owns, S_arm_done;
    wire [15:0] S_arm_pickup_mm;
    wire [71:0] S_arm_manual_pulses, S_arm_pulses, S_arm_active_pulses;
    localparam [71:0] RESCUE_ARM_HOME = {
        12'd500,12'd1500,12'd2500,12'd500,12'd1500,12'd1500};
    wire S_rescue_person = S_eth_rx_bbox_valid && S_eth_rx_bbox_source_valid &&
        S_eth_rx_bbox_x1<=S_eth_rx_bbox_x2 && S_eth_rx_bbox_x2<=159 &&
        S_eth_rx_bbox_y1<=S_eth_rx_bbox_y2 && S_eth_rx_bbox_y2<=119 &&
        S_eth_rx_bbox_y1<=104 && S_eth_rx_bbox_y2>=15 && !S_eth_rx_frame_abort;
    wire S_rescue_color_bad = !S_video_out_rst_n || S_left_video_error || S_hsv_sample_abort;
    wire S_rescue_person_bad = S_eth_rx_frame_abort || S_eth_rx_fifo_underflow;
    reg S_rescue_color_bad_reg = 1'b0, S_rescue_person_bad_reg = 1'b0;
    reg S_rescue_green_clear_reg = 1'b0;
    wire S_rescue_green_clear_source = !S_rescue_color_bad &&
        (S_rescue_color_update ? !S_hsv_green_bbox_valid : S_rescue_green_clear_reg);
    wire S_rescue_color_fault_event = S_rescue_color_bad && !S_rescue_color_bad_reg;
    wire S_rescue_person_fault_event = S_rescue_person_bad && !S_rescue_person_bad_reg;
    (* async_reg = "true" *) reg [1:0] S_rescue_fire_allow_sync = 2'b00;
    wire S_rescue_fire_allow_pixel = S_rescue_fire_allow_sync[1] &&
        !S_rescue_color_bad && I_rst_n && S_hdmi_rst_n;
    always @(posedge S_hdmi_pixel_clk) begin
        if (S_rescue_color_bad) S_rescue_green_clear_reg <= 1'b0;
        else if (S_rescue_color_update) S_rescue_green_clear_reg <= !S_hsv_green_bbox_valid;
        S_rescue_color_bad_reg <= S_rescue_color_bad;
        S_rescue_person_bad_reg <= S_rescue_person_bad;
        S_rescue_fire_allow_sync <= {S_rescue_fire_allow_sync[0], S_rescue_fire_allow};
        if (!I_rst_n || !S_hdmi_rst_n) begin
            S_rescue_color_bad_reg <= 1'b0;
            S_rescue_green_clear_reg <= 1'b0;
            S_rescue_person_bad_reg <= 1'b0;
            S_rescue_fire_allow_sync <= 2'b00;
        end
    end
    rescue_sensor_mailbox u_rescue_sensors (
        .clk_pixel(S_hdmi_pixel_clk), .clk(I_sys_clk), .rst(!I_rst_n),
        .updates_i({lidar_npu_update || S_rescue_person_fault_event,
                    S_rescue_color_update || S_rescue_color_fault_event,
                    S_rescue_color_update || S_rescue_color_fault_event,
                    S_hcsr04_distance_update}),
        .flags_i({S_rescue_person && !S_rescue_person_bad,
                  S_hsv_yellow_bbox_valid && !S_rescue_color_bad,
                  S_hsv_green_bbox_valid && !S_rescue_color_bad,
                  S_rescue_yellow_fire_valid && !S_rescue_color_bad}),
        .green_clear_i(S_rescue_green_clear_source),
        .green_clear_o(S_rescue_green_clear),
        .distance_mm_i(S_hcsr04_distance_mm), .distance_valid_i(S_hcsr04_distance_valid),
        .updates_o(S_rescue_updates), .flags_o(S_rescue_flags),
        .distance_mm_o(S_rescue_mm), .distance_valid_o(S_rescue_range_valid)
    );
    rescue_control u_rescue_control (
        .clk(I_sys_clk), .rst(!I_rst_n), .switch_ni(I_car_auto_switch_n),
        .updates_i(S_rescue_updates), .flags_i(S_rescue_flags),
        .green_clear_i(S_rescue_green_clear),
        .distance_mm_i(S_rescue_mm), .distance_valid_i(S_rescue_range_valid),
        .arm_done_i(S_arm_done), .arm_owns_pwm_i(S_arm_owns),
        .arm_home_i(S_arm_manual_pulses == RESCUE_ARM_HOME),
        .cmd_ready_i(S_car_cmd_ready), .cmd_code_o(S_car_cmd_code),
        .cmd_valid_o(S_car_cmd_valid), .enabled_o(),
        .fire_allowed_o(S_rescue_fire_allow), .arm_request_o(S_arm_request),
        .pickup_mm_o(S_arm_pickup_mm), .voice_flags_o(S_rescue_voice_flags)
    );
    // Match the working car: AA, command, AA XOR command; refresh every 50 ms.
    c30d_motion_tx #(.CLK_HZ(50000000), .BAUD_RATE(9600), .REPEAT_MS(50)) u_car_uart_tx (
        .clk(I_sys_clk), .rst_n(I_rst_n), .cmd_code(S_car_cmd_code),
        .cmd_valid(S_car_cmd_valid), .send_enable_i(1'b1),
        .cmd_ready(S_car_cmd_ready), .uart_tx(O_car_uart_tx), .busy()
    );
    // A9 selects a joint, B9 steps 5 degrees; B4 remains the HDMI source switch.
    servo_pwm6_buttons u_arm_buttons (
        .clk(I_sys_clk), .rst_n(I_rst_n),
        .button_n({I_car_backward_n,I_car_forward_n}),
        .enable_i(!(S_arm_owns || S_arm_request)),
        .pulse_us_o(S_arm_manual_pulses), .selected_o()
    );
    arm_distance_position_auto u_arm_auto (
        .clk(I_sys_clk), .rst_n(I_rst_n), .auto_mode_i(S_arm_request),
        .manual_pulse_us_i(S_arm_manual_pulses), .active_pulse_us_i(S_arm_active_pulses),
        .distance_mm_i(S_arm_pickup_mm), .distance_valid_i(S_arm_request),
        .distance_update_i(S_arm_request), .pulse_us_o(S_arm_pulses),
        .owns_pwm_o(S_arm_owns), .cycle_done_o(S_arm_done)
    );
    servo_pwm6 #(.RESET_PULSES_US(RESCUE_ARM_HOME)) u_arm_pwm (
        .clk(I_sys_clk), .rst_n(I_rst_n), .pulse_us_i(S_arm_pulses),
        .pwm_o(O_arm_pwm), .active_pulse_us_o(S_arm_active_pulses)
    );
    voice_alert_uart_tx u_rescue_voice (
        .clk(I_sys_clk), .rst(!I_rst_n), .flags_i(S_rescue_voice_flags),
        .uart_tx_o(O_voice_uart_tx)
    );
    // END B_RESCUE_CONTROL

