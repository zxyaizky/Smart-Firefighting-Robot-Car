// Change Log: 2026-10-19 Codex Board USB UART H1/J1 for CPU console.
// Change Log: 2026-10-16 Codex Green S=80; add shared HSV yellow detection and yellow box.
// Change Log: 2026-10-14 Codex User trial: green S=100, sharing the red saturation limit.
// Change Log: 2026-10-14 Codex Tighten green S to 64 after large-box feedback; red S=100 unchanged.
// Change Log: 2026-10-14 Codex Green S=50 for pale objects; red S=100 unchanged.
// Change Log: 2026-10-14 Codex Remove matching; independent red flame/green object HSV boxes.
// Change Log: 2026-10-14 Codex Trial NPU/HSV bbox centre alignment; display only, no distance input.
// Change Log: 2026-10-14 Codex Display A-board NPU green box independently of stereo ranging.
// Change Log: 2026-10-14 Codex Comment stereo ranging out of top; local HSV box + HC-SR04 only.
// Change Log: 2026-10-12 Codex Remove HSV debug panel and display-only mailboxes.
// Change Log: 2026-10-11 Codex v6.1 HC-SR04 2020 GPIO; US-100 kept commented for restore.
// Change Log: 2026-10-11 Codex v6.0 Full-resolution HSV branch; stereo unchanged.
// Change Log: 2026-10-08 Codex v5.7 Independent US-100 UART and dual-distance OSD.
// Change Log: 2026-10-07 Codex v5.6 Spray after fixed-camera servo command settles.
// Change Log: 2026-10-06 Codex v5.5 Display-only B bbox coverage and frame coherence.
// Change Log: 2026-10-06 Codex v5.4 Restore flame-driven tracking per clarified user request.
// Change Log: 2026-10-06 Codex v5.3 Re-enable independent self-test for ground reconnection check.
// Change Log: 2026-10-06 Codex v5.2 Restore automatic mode after confirmed servo self-test.
// Change Log: 2026-10-06 Codex v5.1 Temporary independent servo test; pump forced off.
// Change Log: 2026-10-05 Codex v5.0 Independent fire aim/pump GPIO branch.
// Change Log: 2026-10-02 Codex v3.0 Local left-eye sync identity and Gray8 preparation.
// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.


// Change Log: 2026-10-02 Codex v4.0 Passive Ethernet right Gray8 capture branch.
module design_top_wrapper #(
    parameter CPU_MIN_AREA = 1'b0,
    parameter SERVO_TEST_MODE = 1'b0,
    parameter integer SERVO_TEST_DWELL_MS = 2000,
    parameter FIRE_SERVO_REVERSE = 1'b0,
    // Fixed cameras: command a finite angle. Set 0 for cameras mounted on the servo.
    parameter FIRE_SERVO_POSITION_MODE = 1'b1,
    parameter integer FIRE_SERVO_POSITION_INTERVAL_MS = 100,
    parameter integer FIRE_SERVO_PIXELS_PER_DEGREE_SHIFT = 2,
    parameter integer FIRE_SERVO_SETTLE_MS = 200,
    parameter FIRE_PUMP_ACTIVE_HIGH = 1'b1,
    // Fixed-camera spray: user-requested fire + settled angle, without stereo gating.
    parameter FIRE_PUMP_REQUIRE_DISTANCE = 1'b0,
    parameter integer FIRE_PUMP_STABLE_SAMPLES = 3,
    // Temporary driver test: SW2/B4 directly controls the pump, independent of fire/range.
    parameter PUMP_MANUAL_TEST_MODE = 1'b0,
    parameter PUMP_TEST_SWITCH_ACTIVE_LOW = 1'b1,
    parameter integer PUMP_TEST_DEBOUNCE_MS = 20,
    parameter integer FIRE_RESULT_TIMEOUT_MS = 5000,
    // Area-ratio comparison default, not a calibrated physical-object threshold.
    // Compile-time diagnosis: 0 normal; 1 DDR RGB; 2 mixer; 3 mode; 4 HSV mask.
    // Keep 0 for normal operation. These taps do not alter DDR requests or HSV.
    parameter integer HDMI_DIAGNOSTIC_MODE = 0,
    // Protect a completed RAW frame whose ISP/FIFO tail is still draining.
    // A conflicting new source frame is discarded in full, without backpressure.
    parameter integer ISP_TAIL_FRAME_GUARD = 1,
    // RAM-free bbox noise rejection; set 0 for original raw extents.
    parameter integer HSV_BBOX_FILTER_ENABLE = 1,
    parameter integer HSV_BBOX_MIN_RUN_PIXELS = 4,
    parameter integer HSV_BBOX_MIN_ROW_PIXELS = 8,
    parameter integer HSV_BBOX_MIN_CONSECUTIVE_ROWS = 3,
    parameter [19:0] HSV_MIN_RED_PIXELS = 20'd1280,
    // Green hue 80..160 degrees; reject weakly saturated green-tinted background.
    parameter [7:0] HSV_GREEN_S_MIN = 8'd80,
    parameter [7:0] HSV_GREEN_V_MIN = 8'd50,
    parameter integer HSV_GREEN_HUE_DELTA_SCALE = 2,
    parameter [19:0] HSV_MIN_GREEN_PIXELS = 20'd128,
    // Yellow uses H=40..80, red S/V floors (100/50), and the same spatial filter.
    parameter [19:0] HSV_MIN_YELLOW_PIXELS = 20'd128
) (
    input wire        I_sys_clk,
    input wire        I_cpu_uart_rx,
    input wire        I_wifi_uart_rx,
    output wire       O_wifi_uart_tx,
    output wire       O_cpu_uart_tx,
    output wire       stereo_sync_o,
    output wire       servo_pwm_out,
    output wire       pump_ctrl_out,
    // output wire       us100_uart_tx_out,
    // input wire        us100_uart_rx_in,
    output wire       hcsr04_trig_out,
    input wire        hcsr04_echo_in,
    input wire        I_rst_n,
    input wire        I_ae_switch,
    input wire        I_pump_test_switch,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [1:0]  I_button,
    input wire        key,
    input wire        I_car_forward_n,
    input wire        I_car_backward_n,
    input wire        I_car_uart_rx,
    output wire       O_car_uart_tx,
    output wire       max30102_scl,
    inout  wire       max30102_sda,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p,

    input  wire[3:0]  I_a_rgmii_rxd,
    input  wire       I_a_rgmii_rx_ctl,
    input  wire       I_a_rgmii_rxc,
    output wire[3:0]  O_a_rgmii_txd,
    output wire       O_a_rgmii_tx_ctl,
    output wire       O_a_rgmii_txc,
    output wire       O_phy_rst,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n   
);


    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_aux_50m_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
	wire 			S_ae_req; 
	reg             S_ae_switch_sync_1d;
	reg             S_ae_switch_sync_2d;
	wire            S_ae_enable;
	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;
		
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;

    // Ethernet video RX stream.  These nets are deliberately kept while the
    // final image consumer (HDMI/DDR/NPU) is selected, so synthesis retains
    // the complete receive and frame-reassembly datapath.
    wire [15:0] S_stereo_sync_id;
    wire S_stereo_sync_event;
    wire [15:0] S_eth_rx_frame_id;
    wire [15:0] S_eth_rx_sync_id;
    wire        S_eth_rx_sync_valid;
    wire [15:0] S_eth_rx_source_frame_id;
    wire        S_eth_rx_bbox_valid;
    wire [7:0]  S_eth_rx_bbox_x1;
    wire [6:0]  S_eth_rx_bbox_y1;
    wire [7:0]  S_eth_rx_bbox_x2;
    wire [6:0]  S_eth_rx_bbox_y2;
    wire        S_eth_rx_bbox_source_valid;
    wire [15:0] S_eth_rx_bbox_source_frame_id;
    wire [15:0] S_eth_rx_bbox_result_id;
    wire        S_eth_rx_frame_start;
    wire        S_eth_rx_pixel_valid;
    wire [23:0] S_eth_rx_pixel_rgb;
    wire        S_eth_rx_frame_end;
    wire        S_eth_rx_frame_abort;
    wire        S_eth_rx_fifo_underflow;

    wire right_frame_end;
    wire right_frame_abort;
    wire [63:0] right_bbox_result_metadata;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     
    wire S_left_sync_event_ddr;
    wire [15:0] S_left_sync_id_ddr;
    wire S_left_write_frame_start;
    wire [1:0] S_left_write_page;
    wire S_video_out_sync_valid;
    wire [15:0] S_video_out_sync_id;
    wire left_video_frame_valid;
    wire [15:0] left_video_source_frame_id;
    wire S_left_video_error;
    wire S_left_input_frame_start, S_left_input_pixel_valid;
    wire S_left_input_line_end, S_left_input_frame_end;
    // HSV side branch: no feedback into local video, stereo Gray8, or HDMI.
    wire [23:0] S_hsv_sample_rgb;
    wire S_hsv_sample_valid, S_hsv_sample_start, S_hsv_sample_end, S_hsv_sample_abort;
    wire [10:0] S_hsv_sample_x;
    wire [9:0] S_hsv_sample_y;
    wire S_hsv_green_mask;
    wire [19:0] S_hsv_green_pixel_count;
    wire S_hsv_green_bbox_result_valid, S_hsv_green_bbox_valid;
    wire [10:0] S_hsv_green_bbox_xmin, S_hsv_green_bbox_xmax;
    wire [9:0] S_hsv_green_bbox_ymin, S_hsv_green_bbox_ymax;
    wire [23:0] S_hsv_green_overlay_rgb;
    wire S_hsv_yellow_mask;
    wire [19:0] S_hsv_yellow_pixel_count;
    wire S_hsv_yellow_bbox_result_valid, S_hsv_yellow_bbox_valid;
    wire [10:0] S_hsv_yellow_bbox_xmin, S_hsv_yellow_bbox_xmax;
    wire [9:0] S_hsv_yellow_bbox_ymin, S_hsv_yellow_bbox_ymax;
    wire [23:0] S_hsv_yellow_overlay_rgb;
    wire S_hsv_red_mask, S_hsv_pixel_valid;
    wire [10:0] S_hsv_pixel_x;
    wire [9:0] S_hsv_pixel_y;
    wire S_hsv_frame_start, S_hsv_frame_end, S_hsv_frame_abort;
    wire [19:0] S_hsv_red_pixel_count;
    wire S_hsv_frame_result_valid;
    wire [13:0] S_hsv_top_red_count; // Complete-frame red hits in rows 0..7.
    // HSV bbox is independent of the right-camera stereo bbox and distance.
    wire S_hsv_bbox_result_valid;
    wire S_hsv_bbox_valid;
    wire [10:0] S_hsv_bbox_xmin, S_hsv_bbox_xmax;
    wire [9:0] S_hsv_bbox_ymin, S_hsv_bbox_ymax;
    wire [15:0] S_hsv_bbox_source_frame_id;
    wire S_hsv_bbox_source_frame_valid;
    reg [16:0] hsv_source_frame_work_reg = 17'd0;
    reg [16:0] hsv_source_frame_candidate_reg = 17'd0;
    reg [16:0] hsv_source_frame_published_reg = 17'd0;
    wire[15:0]  S_capture_frame_id;
    wire[15:0]  S_video_out_frame_id;
    wire        S_video_out_frame_valid;
    wire[7:0]   S_latency_frames;
    wire[19:0]  S_latency_10us_bcd;
    wire[23:0]  S_processed_fps_bcd;

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;
    wire [8:0]  S_vo_ddr_fifo_used;
    wire [9:0]  S_vo_ddr_outstanding;
    wire        S_video_read_credit_error;
    wire [4:0]  S_video_read_block_status;
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

    wire        S_init_calib_complete; 
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    // BEGIN CPU_DDR_SHARED_DECLARATIONS
    wire S_video_queue_valid, S_video_queue_write, S_video_queue_ready;
    wire [24:0] S_video_queue_addr;
    wire [127:0] S_video_queue_wdata;
    wire S_video_mc_rvalid;
    wire [127:0] S_video_mc_rdata;
    wire S_mc_awready, S_mc_arready, S_mc_wready;
    // END CPU_DDR_SHARED_DECLARATIONS
    wire        S_mc_app_wdf_rdy;       
    wire        S_mc_dbg_fifo_afull;
    wire        S_mc_dbg_app_rdy;
    wire        S_mc_dbg_wdf_rdy;
    wire        S_mc_dbg_cmd_pop;

    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;
    wire S_left_sync_mailbox_event_ddr;
    wire [16:0] S_left_sync_mailbox_data_ddr;
    // Stage 7: latest complete result and final HDMI raster, all pixel-clock domain.
    // wire [15:0] S_us100_distance_mm;
    // wire S_us100_distance_valid;
    wire [15:0] S_hcsr04_distance_mm;
    wire S_hcsr04_distance_valid;
    wire [23:0] S_dual_distance_rgb;
    wire [23:0] stereo_hdmi_rgb;
    reg [10:0] stereo_pixel_x_reg = 11'd0;
    reg [9:0] stereo_pixel_y_reg = 10'd0;
    reg stereo_pixel_de_reg = 1'b0;


    wire[23:0]  S_video_rd_data;
    reg         S_dbg_raw_seen;
    reg         S_dbg_isp_seen;
    reg         S_dbg_ddr_wr_seen;
    reg         S_dbg_ddr_rd_seen;
    reg         S_dbg_cam_cfg_seen;
    reg         S_dbg_hs_seen;
    reg         S_dbg_csi_seen;
    reg         S_dbg_raw10_seen;
    reg         S_dbg_isp_fs_seen;
    reg         S_dbg_isp_valid_seen;
    reg         S_dbg_ddr_req_seen;
    reg         S_dbg_ddr_ready_seen;
    reg [1:0]   S_dbg_raw_seen_sync;
    reg [1:0]   S_dbg_isp_seen_sync;
    reg [1:0]   S_dbg_ddr_wr_seen_sync;
    reg [1:0]   S_dbg_ddr_rd_seen_sync;
    reg [1:0]   S_dbg_cam_cfg_seen_sync;
    reg [1:0]   S_dbg_hs_seen_sync;
    reg [1:0]   S_dbg_csi_seen_sync;
    reg [1:0]   S_dbg_raw10_seen_sync;
    reg [1:0]   S_dbg_isp_fs_seen_sync;
    reg [1:0]   S_dbg_isp_valid_seen_sync;
    reg [1:0]   S_dbg_ddr_req_seen_sync;
    reg [1:0]   S_dbg_ddr_ready_seen_sync;
    reg         S_dbg_video_nonzero_seen;
    reg         S_dbg_rd_req_seen;
    reg         S_dbg_rd_valid_seen;
    reg         S_dbg_rd_nonzero_seen;
    reg [1:0]   S_dbg_rd_req_seen_sync;
    reg [1:0]   S_dbg_rd_valid_seen_sync;
    reg [1:0]   S_dbg_rd_nonzero_seen_sync;
    reg         S_dbg_mc_init_seen;
    reg         S_dbg_mc_app_rdy_seen;
    reg         S_dbg_mc_wdf_rdy_seen;
    reg         S_dbg_mc_cmd_pop_seen;
    reg [1:0]   S_dbg_mc_init_seen_sync;
    reg [1:0]   S_dbg_mc_app_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_wdf_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_cmd_pop_seen_sync;
    wire[3:0]   S_hdmi_debug_status;
    wire[11:0]  S_hr_bcd_pixel;
    wire        S_hr_display_valid_pixel;
    wire[11:0]  S_spo2_bcd_pixel;
    wire        S_spo2_display_valid_pixel;
    wire[8:0]   S_max30102_heart_rate_bpm;
    wire        S_max30102_heart_rate_valid;
    wire[7:0]   S_max30102_spo2;
    wire        S_max30102_spo2_valid;
    wire        S_max30102_finger_present;
    wire        S_max30102_signal_good;
    wire        S_max30102_system_ready;
    wire        S_lane_error_any;

    wire [23:0] data ;

    wire  key_out;

    wire [23:0]S_quant4_center_out;
    wire       S_quant4_vsync;
    wire       S_quant4_de;

// RGB转YCbCr信号
    wire        S_ycbcr_hsync;
    wire        S_ycbcr_vsync;
    wire        S_ycbcr_de;
    wire [7:0]  S_img_y;
    wire [7:0]  S_img_cb;
    wire [7:0]  S_img_cr;

    // Histogram-equalized grayscale branch (display mode 1 only)
    wire        S_hist_eq_vsync;
    wire        S_hist_eq_de;
    wire [7:0]  S_hist_eq_y;

    // Sobel输出信号
    wire        S_sobel_vsync;
    wire        S_sobel_href;
    wire        S_sobel_clken;
    wire        S_sobel_de;
    wire        S_sobel_bit;
    wire [23:0] S_sobel_rgb;

    // 3x3中值滤波输出信号
    wire        S_median_vsync;
    wire        S_median_href;
    wire        S_median_clken;
    wire        S_median_de;
    wire [7:0]  S_median_y;

    // 8x8 block-average frame-difference motion detector
    wire        S_motion_vsync;
    wire        S_motion_de;
    wire [23:0] S_motion_rgb;
    wire [23:0] S_motion_diff_rgb;
    wire        S_motion_active;
    wire [15:0] S_motion_count;
    wire [19:0] S_motion_count_bcd;

    //选择场有效信号
    wire mode_select_vsync;
    wire mode_select_de;
    wire [2:0] S_algorithm_mode;
    wire        S_logo_out_vsync;
    wire        S_logo_out_de;
    wire [23:0] S_logo_out_data;
    // HSV red display is a zero-latency side overlay before original green/text.
    wire [23:0] S_hsv_overlay_rgb;
    wire S_hsv_overlay_de, S_hsv_overlay_vsync;
    wire [23:0] S_hsv_debug_rgb;
    wire S_hsv_debug_de, S_hsv_debug_vsync, S_hsv_draw_hit;
    wire [3:0] S_hsv_abort_reason, S_hsv_clear_reason;
    wire [7:0] S_hsv_capture_debug_ddr;
    wire [17:0] S_hsv_capture_words_ddr;
    wire [9:0] S_isp_frame_diag;
    wire S_raw_frame_complete;
    wire [19:0] S_hsv_abort_count;
    wire [10:0] S_hsv_abort_x;
    wire [9:0] S_hsv_abort_y;
    wire        S_network_hdmi_vsync;
    wire        S_network_hdmi_de;
    wire [23:0] S_network_hdmi_rgb;
    wire        S_network_hdmi_active;
    wire        S_logo_in_vsync;
    wire        S_logo_in_de;
    wire [23:0] S_logo_in_rgb;

    assign S_video_out_vsync = ~S_hdmi_vsync;
	
	
    assign S_rst_n 		= S_pll_lock;
    assign S_hdmi_rst_n = S_pll_lock;

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw_seen <= 1'b0;
        else if(S_raw10_frame_start | S_axis_tvalid)
            S_dbg_raw_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_seen <= 1'b0;
        else if(S_ISP_O_tuser | S_ISP_O_tvalid)
            S_dbg_isp_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_wr_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_wr_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_rd_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_ddr_rd_seen <= 1'b1;
    end

    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_cam_cfg_seen <= 1'b0;
        else if(S_cam_cfg_done)
            S_dbg_cam_cfg_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_hs_seen <= 1'b0;
        else if(S_hs_rx_valid)
            S_dbg_hs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_csi_seen <= 1'b0;
        else if(S_csi_frame_start | S_csi_valid)
            S_dbg_csi_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw10_seen <= 1'b0;
        else if(S_raw10_frame_start | S_raw10_valid)
            S_dbg_raw10_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_fs_seen <= 1'b0;
        else if(S_ISP_O_tuser)
            S_dbg_isp_fs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_valid_seen <= 1'b0;
        else if(S_ISP_O_tvalid)
            S_dbg_isp_valid_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_req_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_ready_seen <= 1'b0;
        else if(S_ddr_user_ready)
            S_dbg_ddr_ready_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_vo_ddr_rd_en)
            S_dbg_rd_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_rd_valid_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
            S_dbg_rd_nonzero_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_init_seen <= 1'b0;
        else if(S_init_calib_complete)
            S_dbg_mc_init_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_app_rdy_seen <= 1'b0;
        else if(S_mc_dbg_app_rdy)
            S_dbg_mc_app_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_wdf_rdy_seen <= 1'b0;
        else if(S_mc_dbg_wdf_rdy)
            S_dbg_mc_wdf_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_cmd_pop_seen <= 1'b0;
        else if(S_mc_dbg_cmd_pop)
            S_dbg_mc_cmd_pop_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if(!S_hdmi_rst_n) begin
            S_dbg_cam_cfg_seen_sync <= 2'b00;
            S_dbg_hs_seen_sync      <= 2'b00;
            S_dbg_csi_seen_sync     <= 2'b00;
            S_dbg_raw10_seen_sync   <= 2'b00;
            S_dbg_raw_seen_sync    <= 2'b00;
            S_dbg_isp_seen_sync    <= 2'b00;
            S_dbg_ddr_wr_seen_sync <= 2'b00;
            S_dbg_ddr_rd_seen_sync <= 2'b00;
            S_dbg_isp_fs_seen_sync  <= 2'b00;
            S_dbg_isp_valid_seen_sync <= 2'b00;
            S_dbg_ddr_req_seen_sync <= 2'b00;
            S_dbg_ddr_ready_seen_sync <= 2'b00;
            S_dbg_video_nonzero_seen <= 1'b0;
            S_dbg_rd_req_seen_sync <= 2'b00;
            S_dbg_rd_valid_seen_sync <= 2'b00;
            S_dbg_rd_nonzero_seen_sync <= 2'b00;
            S_dbg_mc_init_seen_sync <= 2'b00;
            S_dbg_mc_app_rdy_seen_sync <= 2'b00;
            S_dbg_mc_wdf_rdy_seen_sync <= 2'b00;
            S_dbg_mc_cmd_pop_seen_sync <= 2'b00;
        end
        else begin
            S_dbg_cam_cfg_seen_sync <= {S_dbg_cam_cfg_seen_sync[0], S_dbg_cam_cfg_seen};
            S_dbg_hs_seen_sync      <= {S_dbg_hs_seen_sync[0],      S_dbg_hs_seen};
            S_dbg_csi_seen_sync     <= {S_dbg_csi_seen_sync[0],     S_dbg_csi_seen};
            S_dbg_raw10_seen_sync   <= {S_dbg_raw10_seen_sync[0],   S_dbg_raw10_seen};
            S_dbg_raw_seen_sync    <= {S_dbg_raw_seen_sync[0],    S_dbg_raw_seen};
            S_dbg_isp_seen_sync    <= {S_dbg_isp_seen_sync[0],    S_dbg_isp_seen};
            S_dbg_ddr_wr_seen_sync <= {S_dbg_ddr_wr_seen_sync[0], S_dbg_ddr_wr_seen};
            S_dbg_ddr_rd_seen_sync <= {S_dbg_ddr_rd_seen_sync[0], S_dbg_ddr_rd_seen};
            S_dbg_isp_fs_seen_sync  <= {S_dbg_isp_fs_seen_sync[0],  S_dbg_isp_fs_seen};
            S_dbg_isp_valid_seen_sync <= {S_dbg_isp_valid_seen_sync[0], S_dbg_isp_valid_seen};
            S_dbg_ddr_req_seen_sync <= {S_dbg_ddr_req_seen_sync[0], S_dbg_ddr_req_seen};
            S_dbg_ddr_ready_seen_sync <= {S_dbg_ddr_ready_seen_sync[0], S_dbg_ddr_ready_seen};
            S_dbg_rd_req_seen_sync <= {S_dbg_rd_req_seen_sync[0], S_dbg_rd_req_seen};
            S_dbg_rd_valid_seen_sync <= {S_dbg_rd_valid_seen_sync[0], S_dbg_rd_valid_seen};
            S_dbg_rd_nonzero_seen_sync <= {S_dbg_rd_nonzero_seen_sync[0], S_dbg_rd_nonzero_seen};
            S_dbg_mc_init_seen_sync <= {S_dbg_mc_init_seen_sync[0], S_dbg_mc_init_seen};
            S_dbg_mc_app_rdy_seen_sync <= {S_dbg_mc_app_rdy_seen_sync[0], S_dbg_mc_app_rdy_seen};
            S_dbg_mc_wdf_rdy_seen_sync <= {S_dbg_mc_wdf_rdy_seen_sync[0], S_dbg_mc_wdf_rdy_seen};
            S_dbg_mc_cmd_pop_seen_sync <= {S_dbg_mc_cmd_pop_seen_sync[0], S_dbg_mc_cmd_pop_seen};
            if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
                S_dbg_video_nonzero_seen <= 1'b1;
        end
    end

    assign S_lane_error_any = |S_lane_error;

    assign S_vo_dbg_fifo_rst = 1'b0;
    assign S_vo_dbg_ddr_rd_valid = 1'b0;
    assign S_vo_dbg_fifo_rd_en = 1'b0;
    assign S_vo_dbg_fifo_empty = 1'b0;
    assign S_mc_dbg_fifo_afull = 1'b0;
    assign S_mc_dbg_app_rdy = 1'b0;
    assign S_mc_dbg_wdf_rdy = 1'b0;
    assign S_mc_dbg_cmd_pop = 1'b0;

    assign S_hdmi_debug_status = {
        (|S_ddr_user_rd_data),
        S_ddr_user_rd_valid,
        S_vo_ddr_rd_en,
        S_vi_ddr_wr_en
    };
	
	assign O_cam_rst 	= 1'b1;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_pixel_clk  ),
        .clk5_out    ( S_hdmi_serial_clk ),

        .lock        ( S_pll_lock        )

    );


	

  // A4 DIP switch level control. The switch is active-low:
  // ON (0) enables AE, OFF (1) disables AE.
  always @(posedge S_24m_clk or negedge S_rst_n) begin
      if (!S_rst_n) begin
          S_ae_switch_sync_1d <= 1'b1;
          S_ae_switch_sync_2d <= 1'b1;
      end
      else begin
          S_ae_switch_sync_1d <= I_ae_switch;
          S_ae_switch_sync_2d <= S_ae_switch_sync_1d;
      end
  end

  assign S_ae_enable = ~S_ae_switch_sync_2d;

  auto_exposure #(
      .TARGET_LEVEL      (8'd110),
      .TARGET_HYSTERESIS (8'd8),
      .EXPOSURE_MAX      (16'd1990),
      .GAIN_INIT         (16'd112),
      .GAIN_MAX          (16'd143)
  ) u_auto_exposure (
      .I_pix_clk        (S_csi_rx_clk),
      .I_cfg_clk        (S_24m_clk),
      .I_rst_n          (S_rst_n),
      .I_enable         (S_ae_enable),
      .I_frame_start    (S_raw10_frame_start),
      .I_pixel_valid    (S_raw10_valid),
      .I_pixel_data     (S_raw10_data),
      .I_cam_cfg_done   (S_cam_cfg_done),
      .I_ae_cfg_done    (S_ae_cfg_done),
      .O_ae_req         (S_ae_req),
      .O_ae             (S_ae),
      .O_ag             (S_ag)
  );
  
    uicfgcs500_720p #(
      .CLK_DIV(24000000 / 100000 - 1)
  ) u_uicfgcs500 (
      .I_clk(S_24m_clk),  //系统时钟输入
      .I_rst_n(S_rst_n),  //系统复位输入
      .I_ae_req(S_ae_req),
      .I_ae(S_ae),
      .I_ag(S_ag),
      .O_cam_scl(O_cam_scl),  //I2C总线，SCL时钟
      .IO_cam_sda(IO_cam_sda),  //I2C总线，SDA数据
      .O_cfg_done(S_cam_cfg_done),  //摄像头寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done)  //AE配置完成
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "0dB"   ),//"0dB","1.5dB","3dB","4.5dB","6dB","7.5dB","9dB","10.5dB"
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast ),
.frame_complete_o(S_raw_frame_complete)
);
	

// 原厂HD模式直接输出1280x720 RAW10，不再进行FPGA固定窗口裁剪。
// BEGIN ISP TAIL FRAME GUARD
// Readiness is tested at the first accepted RAW beat (AXI SOF), not native FS.
// If the previous complete frame is busy, reject this entire incoming frame.
// Never reset the old ISP job or capture FIFO with a rejected frame marker.
generate
    if (ISP_TAIL_FRAME_GUARD != 0) begin : g_isp_tail_frame_guard
        reg discard_frame_reg;
        wire completed_tail_busy;
        wire accept_frame;
        assign completed_tail_busy = S_isp_frame_diag[0] &&
            (!S_isp_frame_diag[3] || !S_isp_frame_diag[4] || S_ISP_O_tvalid);
        assign accept_frame = S_axis_tuser ? !completed_tail_busy : !discard_frame_reg;
        always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
            if (!S_rst_n) discard_frame_reg <= 1'b0;
            else if (S_axis_tuser) discard_frame_reg <= completed_tail_busy;
        end
        assign S_raw_tvalid = S_axis_tvalid && accept_frame;
        assign S_raw_tlast = S_axis_tlast && accept_frame;
        assign S_raw_tuser = S_axis_tuser && accept_frame;
    end else begin : g_isp_tail_frame_guard_off
        assign S_raw_tvalid = S_axis_tvalid;
        assign S_raw_tlast = S_axis_tlast;
        assign S_raw_tuser = S_axis_tuser;
    end
endgenerate
assign S_raw_tdata = S_axis_tdata;
// END ISP TAIL FRAME GUARD


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


//ISP算法顶层模块
isp_top u_isp_top (
.axi4s_video_aclk(S_csi_rx_clk),
.I_rst_n         (S_rst_n),
.I_tlast         (S_raw_tlast	),
.I_tuser         (S_raw_tuser	),
.I_tdata         (S_raw_tdata	),
.I_tvalid        (S_raw_tvalid	),
.I_tdest         (),
.O_tready        (S_ISP_O_tready),
.O_tdata         (S_ISP_O_tdata ),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.I_tready        (),
.O_frame_diag    (S_isp_frame_diag)
  );


    video_in u_video_in(
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        // Use the RAW-domain frame marker so the input FIFO reset completes
        // before the delayed ISP pixels reach video_in.  Resetting from the
        // ISP marker erased the first words of every frame.
        .I_camera_frame_start ( S_raw_tuser    ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_left_sync_event    ( S_left_sync_event_ddr ),
        .I_left_sync_id       ( S_left_sync_id_ddr ),
        .O_left_write_frame_start(S_left_write_frame_start),
        .O_left_write_page    ( S_left_write_page ),
        .O_left_selected_valid(),
        .O_left_selected_sync_id(),
        .O_left_selected_source_frame_id(),
        .O_left_selected_count(),
        .O_left_request_overflow(),
        .O_video_out_sync_valid(S_video_out_sync_valid),
        .O_video_out_sync_id(S_video_out_sync_id),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy   ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),
        .O_capture_frame_id   ( S_capture_frame_id    ),
        .O_video_out_frame_id ( S_video_out_frame_id  ),
        .O_video_out_frame_valid(S_video_out_frame_valid),
        .O_capture_debug_status(S_hsv_capture_debug_ddr),
        .O_capture_debug_word_count(S_hsv_capture_words_ddr),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready      )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 'd0;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_data;


    assign S_video_out_rst_n = S_hdmi_rst_n;

    // Reserve output FIFO slots before VO reads enter the shared MC queue.
    // Keep VI ready unchanged. Frame/FIFO reset does not cancel queued reads.
    video_ddr_read_credit #(.CREDIT_LIMIT(480)) u_video_ddr_read_credit (
        .clk(S_ddr_clk), .rst(!S_rst_n),
        .fifo_used_i(S_vo_ddr_fifo_used), .read_request_i(S_vo_ddr_rd_en),
        .read_return_i(S_ddr_user_rd_valid), .downstream_ready_i(S_ddr_user_ready),
        .ready_o(S_vo_ddr_rd_ready), .outstanding_o(S_vo_ddr_outstanding),
        .error_o(S_video_read_credit_error)
    );

    video_out u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_sys_clk           ( I_sys_clk            ),
        .I_processed_frame_vsync(mode_select_vsync  ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
        .I_capture_frame_id  ( S_capture_frame_id   ),
        .I_video_out_frame_id(S_video_out_frame_id ),
        .I_video_out_frame_valid(S_video_out_frame_valid),
        .I_video_out_sync_valid(S_video_out_sync_valid),
        .I_video_out_sync_id(S_video_out_sync_id),
        .I_left_write_frame_start(S_left_write_frame_start),
        .I_left_write_page(S_left_write_page),
        .O_left_video_frame_valid(left_video_frame_valid),
        .O_left_video_source_frame_id(left_video_source_frame_id),
        .O_left_video_sync_valid(),
        .O_left_video_sync_id(),
        .O_left_video_error(S_left_video_error),
        .O_latency_frames    ( S_latency_frames     ),
        .O_latency_10us_bcd  ( S_latency_10us_bcd   ),
        .O_processed_fps_bcd ( S_processed_fps_bcd  ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .O_ddr_fifo_used     ( S_vo_ddr_fifo_used   ),
        .O_read_block_status( S_video_read_block_status ),
        .I_ddr_user_ready    ( S_vo_ddr_rd_ready    ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),
        .I_ddr_reads_outstanding(S_vo_ddr_outstanding),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );



    mc_to_user_interface #(.EXTERNAL_ARBITRATION(1'b1)) u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             (),
        .O_mc_app_addr           (),
        .O_mc_app_cmd            (),
        .I_mc_app_rdy            (1'b0),
        .O_mc_app_wdf_wren       (),
        .O_mc_app_wdf_data       (),
        .O_mc_app_wdf_end        (),
        .O_mc_app_wdf_mask       (),
        .I_mc_app_wdf_rdy        (1'b0),
        .I_mc_app_rd_data        ( S_video_mc_rdata        ),
        .I_mc_app_rd_data_end    ( 1'b1                      ),
        .I_mc_app_rd_data_valid  ( S_video_mc_rvalid       ),
        .O_queue_valid           ( S_video_queue_valid ),
        .O_queue_write           ( S_video_queue_write ),
        .O_queue_addr            ( S_video_queue_addr ),
        .O_queue_wdata           ( S_video_queue_wdata ),
        .I_queue_ready           ( S_video_queue_ready )
    );



    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_app_cmd           ( S_mc_app_cmd           ),
        .I_mc_app_en            ( S_mc_app_en            ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),
        .O_mc_app_awready       ( S_mc_awready ),
        .O_mc_app_arready       ( S_mc_arready ),
        .O_mc_app_wready        ( S_mc_wready ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    uivtc #(
        .H_ActiveSize ( 1280 ),
        .H_FrameSize  ( 1650 ),
        .H_SyncStart  ( 1390 ),
        .H_SyncEnd    ( 1430 ),
        .V_ActiveSize ( 720  ),
        .V_FrameSize  ( 750  ),
        .V_SyncStart  ( 725  ),
        .V_SyncEnd    ( 730  )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    // Sensor uses the existing PLL C1 clock (23.809524 MHz).
    max30102_top #(
        .CLK_HZ (23809524),
        .I2C_HZ (100000)
    ) u_max30102_top (
        .clk              (S_24m_clk),
        .rst_n            (S_rst_n),
        .max30102_scl     (max30102_scl),
        .max30102_sda     (max30102_sda),
        .part_id          (),
        .device_ok        (),
        .red_raw          (),
        .ir_raw           (),
        .sample_valid     (),
        .finger_present   (S_max30102_finger_present),
        .signal_good      (S_max30102_signal_good),
        .heart_rate_bpm   (S_max30102_heart_rate_bpm),
        .heart_rate_valid (S_max30102_heart_rate_valid),
        .spo2             (S_max30102_spo2),
        .spo2_valid       (S_max30102_spo2_valid),
        .ratio_r          (),
        .init_done        (),
        .system_ready     (S_max30102_system_ready),
        .error            (),
        .init_error_dbg   (),
        .id_error_dbg     (),
        .sampler_error_dbg(),
        .fifo_overflow_dbg()
    );

    max30102_osd_cdc u_max30102_osd_cdc (
        .clk_sensor                    (S_24m_clk),
        .clk_pixel                     (S_hdmi_pixel_clk),
        .rst_n                         (S_hdmi_rst_n),
        .heart_rate_bpm                (S_max30102_heart_rate_bpm),
        .heart_rate_valid              (S_max30102_heart_rate_valid),
        .spo2                          (S_max30102_spo2),
        .spo2_valid                    (S_max30102_spo2_valid),
        .finger_present                (S_max30102_finger_present),
        .signal_good                   (S_max30102_signal_good),
        .system_ready                  (S_max30102_system_ready),
        .heart_rate_bcd_pixel          (S_hr_bcd_pixel),
        .heart_rate_display_valid_pixel (S_hr_display_valid_pixel),
        .spo2_bcd_pixel                (S_spo2_bcd_pixel),
        .spo2_display_valid_pixel      (S_spo2_display_valid_pixel)
    );

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        .DEBUG_MODE ( 0    )
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_debug_status  ( S_hdmi_debug_status),
        .I_ae_enable     ( S_ae_enable        ),
        .I_algorithm_mode( S_algorithm_mode   ),
        .I_latency_10us_bcd ( S_latency_10us_bcd  ),
        .I_processed_fps_bcd( S_processed_fps_bcd ),
        .I_motion_count_bcd ( S_motion_count_bcd  ),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );


//=========================================================
// RGB888转YCbCr
// 输入、输出控制信号相差3拍
//=========================================================
rgb2ycbcr u_rgb2ycbcr (
    .pclk             (S_hdmi_pixel_clk),
    .sys_rst_n        (S_hdmi_rst_n),

    .rgb888_r         (S_hdmi_out_data[23:16]),
    .rgb888_g         (S_hdmi_out_data[15:8]),
    .rgb888_b         (S_hdmi_out_data[7:0]),

    .pre_video_hsync  (S_hdmi_out_hsync),
    .pre_video_vsync  (S_hdmi_out_vsync),
    .pre_video_de     (S_hdmi_out_de),

    // 当前Sobel不需要坐标，暂时接0
    .i_x_pos          (11'd0),
    .i_y_pos          (11'd0),

    .post_video_hsync (S_ycbcr_hsync),
    .post_video_vsync (S_ycbcr_vsync),
    .post_video_de    (S_ycbcr_de),

    .post_i_x_pos     (),
    .post_i_y_pos     (),

    .img_y            (S_img_y),
    .img_cb           (S_img_cb),
    .img_cr           (S_img_cr)
);

//=========================================================
// 1280x720 streaming histogram equalization
// The previous-frame LUT is applied only to grayscale display mode.
//=========================================================
histogram_equalizer_720p #(
    .IMG_WIDTH  (1280),
    .IMG_HEIGHT (720)
) u_histogram_equalizer_720p (
    .I_clk   (S_hdmi_pixel_clk),
    .I_rst_n (S_hdmi_rst_n),
    .I_vsync (S_ycbcr_vsync),
    .I_de    (S_ycbcr_de),
    .I_img_y (S_img_y),
    .O_vsync (S_hist_eq_vsync),
    .O_de    (S_hist_eq_de),
    .O_img_y (S_hist_eq_y)
);

//=========================================================
// Hardware motion detection
// - 8x8 gray block average, so only a 160x90 previous frame is stored
// - absolute inter-frame difference and programmable fixed threshold
// - stable one-frame-late block mask, motion count and bounding box overlay
//=========================================================
motion_frame_diff #(
    .IMG_WIDTH          (1280),
    .IMG_HEIGHT         (720),
    .BLOCK_SHIFT        (3),
    .DIFF_THRESHOLD     (8'd12),
    .MIN_MOTION_BLOCKS  (15'd12)
) u_motion_frame_diff (
    .I_clk              (S_hdmi_pixel_clk),
    .I_rst_n            (S_hdmi_rst_n),
    .I_frame_vsync      (S_ycbcr_vsync),
    .I_frame_de         (S_ycbcr_de),
    .I_img_y            (S_img_y),

    .O_frame_vsync      (S_motion_vsync),
    .O_frame_de         (S_motion_de),
    .O_motion_rgb       (S_motion_rgb),
    .O_diff_rgb         (S_motion_diff_rgb),
    .O_motion_active    (S_motion_active),
    .O_motion_count     (S_motion_count),
    .O_motion_count_bcd (S_motion_count_bcd)
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


 xiaodou u_xiaodou(
	.clk       (S_hdmi_pixel_clk)           ,
	.rst_n     (S_hdmi_rst_n)               ,
	.key_in    (key)                           ,
	.key_flag	(key_out)	                        //滤波后的信号（脉冲信号）
    );





mode_select u_mode_select(
    .key_out                    (key_out),
    .clk                        (S_hdmi_pixel_clk),
    .rst                        (S_hdmi_rst_n),
    .S_quant4_center_out        (S_quant4_center_out),
    .S_quant4_vsync             (S_quant4_vsync),
    .S_quant4_de                (S_quant4_de),
    .S_hdmi_out_data            (S_hdmi_out_data),
    .S_img_y                    (S_hist_eq_y),
    .S_sobel_rgb                (S_sobel_rgb),
    .S_median_y                 (S_median_y),
    .S_motion_rgb               (S_motion_rgb),
    .S_motion_diff_rgb          (S_motion_diff_rgb),
    .S_motion_vsync             (S_motion_vsync),
    .S_motion_de                (S_motion_de),
    .S_ycbcr_vsync              (S_hist_eq_vsync)                          ,
    .S_ycbcr_de                 (S_hist_eq_de   )                          ,
    .S_sobel_de                 (S_sobel_de      )                         ,
    .S_sobel_vsync              (S_sobel_vsync   )                         ,
    .S_median_de                (S_median_de     )                         ,
    .S_median_vsync             (S_median_vsync  )                         ,
    .S_hdmi_out_vsync           (S_hdmi_out_vsync)                         ,   
    .S_hdmi_out_de              (S_hdmi_out_de   )                         ,
    .mode_select_vsync          (mode_select_vsync)                        ,
    .mode_select_de             (mode_select_de )                          ,
    .data                       (data),
    .O_algorithm_mode           (S_algorithm_mode)
 );

//=========================================================
// PC-camera UDP frame buffer and HDMI display source select
// - The existing UDP receiver supplies complete 160x120 RGB888 frames.
// - Frames are double-buffered in RGB565 and enlarged 8x6 to 1280x720.
// - Until the first complete network frame arrives, the original MIPI/ISP
//   picture remains on HDMI.  All MIPI logic continues running afterwards.
//=========================================================
ethernet_hdmi_framebuffer u_ethernet_hdmi_framebuffer (
    .I_clk             (S_hdmi_pixel_clk),
    .I_rst_n           (S_hdmi_rst_n),
    .I_net_frame_start (S_eth_rx_frame_start),
    .I_net_pixel_valid (S_eth_rx_pixel_valid),
    .I_net_pixel_rgb   (S_eth_rx_pixel_rgb),
    .I_net_frame_end   (S_eth_rx_frame_end),
    .I_net_frame_abort (S_eth_rx_frame_abort),
    .I_hdmi_vsync      (mode_select_vsync),
    .I_hdmi_de         (mode_select_de),
    .O_hdmi_vsync      (S_network_hdmi_vsync),
    .O_hdmi_de         (S_network_hdmi_de),
    .O_hdmi_rgb        (S_network_hdmi_rgb),
    .O_network_active  (S_network_hdmi_active)
);

// HDMI is fixed back to the original MIPI/ISP/DDR display path.
// Keep the complete Ethernet receive and frame-buffer path instantiated.
// BEGIN HSV MASK DISPLAY
// Reuse the detector output, not a second colour classifier.
// From the aligned DDR RGB/tap interface: input register + five threshold
// registers = six register boundaries. VTC VS additionally needs the two
// video_out/tap boundaries. Preserve the raw display DE even on aborted frames.
generate
    if (HDMI_DIAGNOSTIC_MODE == 4) begin : g_hsv_mask_display
        reg [5:0] mask_de_pipe_reg;
        reg [7:0] mask_vs_pipe_reg;
        always @(posedge S_hdmi_pixel_clk) begin
            if (!S_hdmi_rst_n || !S_video_out_rst_n) begin
                mask_de_pipe_reg <= 6'd0;
                mask_vs_pipe_reg <= 8'd0;
            end else begin
                mask_de_pipe_reg <= {mask_de_pipe_reg[4:0], S_left_input_pixel_valid};
                mask_vs_pipe_reg <= {mask_vs_pipe_reg[6:0], S_hdmi_vsync};
            end
        end
        assign S_logo_in_vsync = mask_vs_pipe_reg[7];
        assign S_logo_in_de = mask_de_pipe_reg[5];
        // White: red hit; black: classified non-red; blue: no valid HSV pixel.
        assign S_logo_in_rgb = S_hsv_pixel_valid ?
            (S_hsv_red_mask ? 24'hffffff : 24'h000000) : 24'h0000ff;
    end else begin : g_hsv_mask_display_off
        assign S_logo_in_vsync = mode_select_vsync;
        assign S_logo_in_de = mode_select_de;
        assign S_logo_in_rgb = data;
    end
endgenerate
// END HSV MASK DISPLAY

//=========================================================
// Final-stage full-colour Anlogic logo overlay
// Placed after mode selection so image effects cannot alter its colour.
//=========================================================
video_logo_overlay #(
    .IMG_WIDTH  (1280),
    .IMG_HEIGHT (720),
    .LOGO_X     (0),
    .LOGO_Y     (0),
    .LOGO_W     (160),
    .LOGO_H     (160)
) u_video_logo_overlay (
    .I_clk   (S_hdmi_pixel_clk),
    .I_rst_n (S_hdmi_rst_n),
    .I_vsync (S_logo_in_vsync),
    .I_de    (S_logo_in_de),
    .I_rgb   (S_logo_in_rgb),
    .I_algorithm_mode (S_algorithm_mode),
    .I_ae_enable      (S_ae_enable),
    .I_heart_rate_bcd           (S_hr_bcd_pixel),
    .I_heart_rate_display_valid (S_hr_display_valid_pixel),
    .I_spo2_bcd                 (S_spo2_bcd_pixel),
    .I_spo2_display_valid       (S_spo2_display_valid_pixel),
    .O_vsync (S_logo_out_vsync),
    .O_de    (S_logo_out_de),
    .O_rgb   (S_logo_out_data)
);

    // Coordinates describe the EXISTING final RGB/DE, with no added video latency.
    always @(posedge S_hdmi_pixel_clk) begin
        stereo_pixel_de_reg <= S_logo_out_de;
        if (S_logo_out_vsync) begin
            stereo_pixel_x_reg <= 11'd0;
            stereo_pixel_y_reg <= 10'd0;
        end else if (S_logo_out_de) begin
            if (stereo_pixel_x_reg < 11'd1279)
                stereo_pixel_x_reg <= stereo_pixel_x_reg + 11'd1;
        end else begin
            stereo_pixel_x_reg <= 11'd0;
            if (stereo_pixel_de_reg && stereo_pixel_y_reg < 10'd719)
                stereo_pixel_y_reg <= stereo_pixel_y_reg + 10'd1;
        end
        if (!S_hdmi_rst_n) begin
            stereo_pixel_x_reg <= 11'd0;
            stereo_pixel_y_reg <= 10'd0;
            stereo_pixel_de_reg <= 1'b0;
        end
    end

    hsv_bbox_overlay #(.X_WIDTH(11), .Y_WIDTH(10), .COORD_SHIFT(0))
    hsv_bbox_overlay_inst (
        .clk                       (S_hdmi_pixel_clk),
        .rst                       (~S_hdmi_rst_n),
        .rgb_i                     (S_logo_out_data),
        .de_i                      (S_logo_out_de),
        // Final RGB interface has VS/DE only; hdmi_tx regenerates line markers.
        .hsync_i                   (1'b0),
        .vsync_i                   (S_logo_out_vsync),
        .pixel_x_i                 (stereo_pixel_x_reg),
        .pixel_y_i                 (stereo_pixel_y_reg),
        .result_valid_i            (S_hsv_bbox_result_valid),
        .bbox_valid_i              (S_hsv_bbox_valid),
        .xmin_i                    (S_hsv_bbox_xmin),
        .xmax_i                    (S_hsv_bbox_xmax),
        .ymin_i                    (S_hsv_bbox_ymin),
        .ymax_i                    (S_hsv_bbox_ymax),
        .source_frame_valid_i      (S_hsv_bbox_source_frame_valid),
        .source_frame_id_i         (S_hsv_bbox_source_frame_id),
        .rgb_o                     (S_hsv_overlay_rgb),
        .de_o                      (S_hsv_overlay_de),
        .hsync_o                   (),
        .vsync_o                   (S_hsv_overlay_vsync),
        .active_valid_o            (),
        .active_source_frame_id_o  (),
        .display_xmin_o            (),
        .display_xmax_o            (),
        .display_ymin_o            (),
        .display_ymax_o            (),
        .draw_hit_o                (S_hsv_draw_hit),
        .clear_reason_o            (S_hsv_clear_reason)
    );

    // HSV_GREEN_DISPLAY_BEGIN
    hsv_bbox_overlay #(
        .X_WIDTH(11), .Y_WIDTH(10), .COORD_SHIFT(0),
        .BOX_COLOR(24'h00ff00), .BOX_THICKNESS(3'd2), .BOX_INSET(4'd0)
    ) hsv_green_bbox_overlay_inst (
        .clk                       (S_hdmi_pixel_clk),
        .rst                       (~S_hdmi_rst_n),
        .rgb_i                     (S_hsv_overlay_rgb),
        .de_i                      (S_hsv_overlay_de),
        .hsync_i                   (1'b0),
        .vsync_i                   (S_hsv_overlay_vsync),
        .pixel_x_i                 (stereo_pixel_x_reg),
        .pixel_y_i                 (stereo_pixel_y_reg),
        .result_valid_i            (S_hsv_green_bbox_result_valid),
        .bbox_valid_i              (S_hsv_green_bbox_valid),
        .xmin_i                    (S_hsv_green_bbox_xmin),
        .xmax_i                    (S_hsv_green_bbox_xmax),
        .ymin_i                    (S_hsv_green_bbox_ymin),
        .ymax_i                    (S_hsv_green_bbox_ymax),
        .source_frame_valid_i      (S_hsv_bbox_source_frame_valid),
        .source_frame_id_i         (S_hsv_bbox_source_frame_id),
        .rgb_o                     (S_hsv_green_overlay_rgb),
        .de_o                      (),
        .hsync_o                   (),
        .vsync_o                   (),
        .active_valid_o            (),
        .active_source_frame_id_o  (),
        .display_xmin_o            (),
        .display_xmax_o            (),
        .display_ymin_o            (),
        .display_ymax_o            (),
        .draw_hit_o                (),
        .clear_reason_o            ()
    );
    // HSV_GREEN_DISPLAY_END

    // HSV_YELLOW_DISPLAY_BEGIN
    hsv_bbox_overlay #(
        .X_WIDTH(11), .Y_WIDTH(10), .COORD_SHIFT(0),
        .BOX_COLOR(24'hffff00), .BOX_THICKNESS(3'd2), .BOX_INSET(4'd0)
    ) hsv_yellow_bbox_overlay_inst (
        .clk                       (S_hdmi_pixel_clk),
        .rst                       (~S_hdmi_rst_n),
        .rgb_i                     (S_hsv_green_overlay_rgb),
        .de_i                      (S_hsv_overlay_de),
        .hsync_i                   (1'b0),
        .vsync_i                   (S_hsv_overlay_vsync),
        .pixel_x_i                 (stereo_pixel_x_reg),
        .pixel_y_i                 (stereo_pixel_y_reg),
        .result_valid_i            (S_hsv_yellow_bbox_result_valid),
        .bbox_valid_i              (S_hsv_yellow_bbox_valid),
        .xmin_i                    (S_hsv_yellow_bbox_xmin),
        .xmax_i                    (S_hsv_yellow_bbox_xmax),
        .ymin_i                    (S_hsv_yellow_bbox_ymin),
        .ymax_i                    (S_hsv_yellow_bbox_ymax),
        .source_frame_valid_i      (S_hsv_bbox_source_frame_valid),
        .source_frame_id_i         (S_hsv_bbox_source_frame_id),
        .rgb_o                     (S_hsv_yellow_overlay_rgb),
        .de_o                      (),
        .hsync_o                   (),
        .vsync_o                   (),
        .active_valid_o            (),
        .active_source_frame_id_o  (),
        .display_xmin_o            (),
        .display_xmax_o            (),
        .display_ymin_o            (),
        .display_ymax_o            (),
        .draw_hit_o                (),
        .clear_reason_o            ()
    );
    // HSV_YELLOW_DISPLAY_END

    // HSV debug text and its diagnostic mailboxes have been removed.
    // Keep the existing downstream signal names as direct, zero-latency wires.
    assign S_hsv_debug_rgb = S_hsv_yellow_overlay_rgb;
    assign S_hsv_debug_de = S_hsv_overlay_de;
    assign S_hsv_debug_vsync = S_hsv_overlay_vsync;

    // NPU_DISPLAY_BEGIN
    // Latest complete A-board result, independent of current image/sync membership.
    // Raw NPU coordinates are 160x120, with 15 padding rows above/below 160x90.
    // Crop that padding, then the reused renderer scales x/y by eight to 720P.
    // This display has no right-to-left disparity correction or ranging dependency.
    wire [7:0] npu_box_xmin, npu_box_xmax;
    wire [6:0] npu_box_raw_ymin, npu_box_raw_ymax;
    wire [6:0] npu_box_clipped_ymin, npu_box_clipped_ymax;
    wire [6:0] npu_box_ymin, npu_box_ymax;
    wire npu_box_intersects, npu_box_valid, npu_overlay_rst;
    assign npu_box_xmin = right_bbox_result_metadata[62:55];
    assign npu_box_xmax = right_bbox_result_metadata[47:40];
    assign npu_box_raw_ymin = right_bbox_result_metadata[54:48];
    assign npu_box_raw_ymax = right_bbox_result_metadata[39:33];
    assign npu_box_intersects = npu_box_xmin <= npu_box_xmax &&
        npu_box_raw_ymin <= npu_box_raw_ymax && npu_box_xmax <= 8'd159 &&
        npu_box_raw_ymax <= 7'd119 && npu_box_raw_ymin <= 7'd104 &&
        npu_box_raw_ymax >= 7'd15;
    assign npu_box_clipped_ymin = npu_box_raw_ymin < 7'd15 ?
        7'd15 : (npu_box_raw_ymin > 7'd104 ? 7'd104 : npu_box_raw_ymin);
    assign npu_box_clipped_ymax = npu_box_raw_ymax > 7'd104 ?
        7'd104 : (npu_box_raw_ymax < 7'd15 ? 7'd15 : npu_box_raw_ymax);
    assign npu_box_ymin = npu_box_clipped_ymin - 7'd15;
    assign npu_box_ymax = npu_box_clipped_ymax - 7'd15;
    assign npu_box_valid = right_bbox_result_metadata[63] && npu_box_intersects;
    assign npu_overlay_rst = !S_hdmi_rst_n || right_frame_abort ||
        S_eth_rx_frame_abort || S_eth_rx_fifo_underflow;

    // Allow the NPU's slower result cadence; repeated source IDs do not renew age.
    // Green NPU borders take priority over local HSV red borders at overlap.
    hsv_bbox_overlay #(
        .X_WIDTH(8), .Y_WIDTH(7), .COORD_SHIFT(3),
        .BOX_THICKNESS(3'd3), .BOX_INSET(4'd0), .BOX_COLOR(24'h00ff00),
        .STALE_FRAMES(300), .MAX_AGE_CYCLES(375000000)
    ) npu_bbox_overlay_inst (
        .clk                       (S_hdmi_pixel_clk),
        .rst                       (npu_overlay_rst),
        .rgb_i                     (S_hsv_debug_rgb),
        .de_i                      (S_hsv_debug_de),
        .hsync_i                   (1'b0),
        .vsync_i                   (S_hsv_debug_vsync),
        .pixel_x_i                 (stereo_pixel_x_reg),
        .pixel_y_i                 (stereo_pixel_y_reg),
        .result_valid_i            (right_frame_end),
        .bbox_valid_i              (npu_box_valid),
        .xmin_i                    (npu_box_xmin),
        .xmax_i                    (npu_box_xmax),
        .ymin_i                    (npu_box_ymin),
        .ymax_i                    (npu_box_ymax),
        .source_frame_valid_i      (right_bbox_result_metadata[32]),
        .source_frame_id_i         (right_bbox_result_metadata[31:16]),
        .rgb_o                     (stereo_hdmi_rgb),
        .de_o                      (),
        .hsync_o                   (),
        .vsync_o                   (),
        .active_valid_o            (),
        .active_source_frame_id_o  (),
        .display_xmin_o            (),
        .display_xmax_o            (),
        .display_ymin_o            (),
        .display_ymax_o            (),
        .draw_hit_o                (),
        .clear_reason_o            ()
    );
    // NPU_DISPLAY_END

    // Independent US-100 UART, same 75 MHz domain as the existing stereo OSD.
    // Jumpers present: 9600 baud, send 0x55, high-byte then low-byte mm reply.
    // US-100 retained in full for restoration; inactive in this GPIO trial.
    // us100_uart_ranging #(
    //     .CLK_FREQ_HZ         (75000000),
    //     .BAUD_RATE           (9600),
    //     .POLL_INTERVAL_MS    (200),
    //     .RESPONSE_TIMEOUT_MS (100)
    // ) us100_uart_ranging_inst (
    //     .clk              (S_hdmi_pixel_clk),
    //     .rst              (!(I_rst_n && S_hdmi_rst_n)),
    //     .uart_rx_i        (us100_uart_rx_in),
    //     .uart_tx_o        (us100_uart_tx_out),
    //     .distance_mm_o    (S_us100_distance_mm),
    //     .distance_valid_o (S_us100_distance_valid),
    //     .result_update_o  ()
    // );

    // HC-SR04 2020 default GPIO: R4/R5 unpopulated, 3.3 V supply.
    // T3/J1 pin 6 -> Trig, Echo -> T2/J1 pin 7; idle level is low.
    hcsr04_2020_ranging #(
        .CLK_FREQ_HZ         (75000000),
        .POLL_INTERVAL_MS    (200),
        .RESPONSE_TIMEOUT_MS (100),
        .TRIGGER_US          (20)
    ) hcsr04_2020_ranging_inst (
        .clk              (S_hdmi_pixel_clk),
        .rst              (!(I_rst_n && S_hdmi_rst_n)),
        .echo_i           (hcsr04_echo_in),
        .trig_o           (hcsr04_trig_out),
        .distance_mm_o    (S_hcsr04_distance_mm),
        .distance_valid_o (S_hcsr04_distance_valid),
        .result_update_o  ()
    );

    // Extra comparison text only; original bbox/label module stays unchanged.
    dual_distance_overlay #(
        .SHOW_STEREO_ROW (0),
        .ULTRASONIC_LABEL ("HC-SR04")
    ) dual_distance_overlay_inst (
        .clk                (S_hdmi_pixel_clk),
        .rst                (!(I_rst_n && S_hdmi_rst_n)),
        .frame_start_i      (S_hsv_debug_vsync),
        .pixel_x_i          (stereo_pixel_x_reg),
        .pixel_y_i          (stereo_pixel_y_reg),
        .pixel_valid_i      (S_hsv_debug_de),
        .rgb_i              (stereo_hdmi_rgb),
        .stereo_valid_i     (1'b0),
        .stereo_mm_i        (16'd0),
        // .ultrasonic_valid_i (S_us100_distance_valid),
        // .ultrasonic_mm_i    (S_us100_distance_mm),
        .ultrasonic_valid_i (S_hcsr04_distance_valid),
        .ultrasonic_mm_i    (S_hcsr04_distance_mm),
        .rgb_o              (S_dual_distance_rgb)
    );

    // BEGIN HDMI_DIAGNOSTIC_TAP
    // Only MODE 1 adds two VS registers, matching video_out/tap RGB latency.
    // MODE 0 is a direct wire connection to the original final output.
    wire [23:0] S_hdmi_selected_rgb;
    wire S_hdmi_selected_de, S_hdmi_selected_vs;
    generate
        if (HDMI_DIAGNOSTIC_MODE == 1) begin : g_hdmi_ddr_diagnostic
            reg [1:0] vs_pipe_reg = 2'b00;
            always @(posedge S_hdmi_pixel_clk) begin
                if (!S_hdmi_rst_n) vs_pipe_reg <= 2'b00;
                else vs_pipe_reg <= {vs_pipe_reg[0], S_hdmi_vsync};
            end
            assign S_hdmi_selected_rgb = S_video_rd_data;
            assign S_hdmi_selected_de = S_left_input_pixel_valid;
            assign S_hdmi_selected_vs = vs_pipe_reg[1];
        end else if (HDMI_DIAGNOSTIC_MODE == 2) begin : g_hdmi_mixer_diagnostic
            assign S_hdmi_selected_rgb = S_hdmi_out_data;
            assign S_hdmi_selected_de = S_hdmi_out_de;
            assign S_hdmi_selected_vs = S_hdmi_out_vsync;
        end else if (HDMI_DIAGNOSTIC_MODE == 3) begin : g_hdmi_mode_diagnostic
            assign S_hdmi_selected_rgb = data;
            assign S_hdmi_selected_de = mode_select_de;
            assign S_hdmi_selected_vs = mode_select_vsync;
        end else begin : g_hdmi_normal
            assign S_hdmi_selected_rgb = S_dual_distance_rgb;
            assign S_hdmi_selected_de = S_hsv_debug_de;
            assign S_hdmi_selected_vs = S_hsv_debug_vsync;
        end
    endgenerate
    // END HDMI_DIAGNOSTIC_TAP

    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      (S_hdmi_selected_vs),
        .I_video_in_de      (S_hdmi_selected_de),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    (S_hdmi_selected_rgb),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );


    stereo_sync_gen #(
        .CLK_FREQ(50000000), .SYNC_RATE(10), .PULSE_CYCLES(50000)
    ) u_stereo_sync_gen (
        .clk(I_sys_clk), .rst(~I_rst_n),
        .stereo_sync_o(stereo_sync_o),
        .stereo_sync_id_o(S_stereo_sync_id),
        .stereo_sync_event_o(S_stereo_sync_event)
    );

    // CDC: generated 50 MHz sync ID is held through a DDR-domain acknowledgment.
    // Requests repeat at 10 Hz; the existing 1 ms wire packet is unchanged.
    stereo_metadata_mailbox #(.DATA_WIDTH(17)) stereo_sync_request_mailbox_inst (
        .clk_source(I_sys_clk), .rst_source(~I_rst_n),
        .clk_dest(S_ddr_clk), .rst_dest(~S_rst_n),
        .send_i(S_stereo_sync_event), .data_i({1'b1, S_stereo_sync_id}),
        .ready_o(), .overflow_o(),
        .event_o(S_left_sync_mailbox_event_ddr), .data_o(S_left_sync_mailbox_data_ddr)
    );
    assign S_left_sync_event_ddr = S_left_sync_mailbox_event_ddr && S_left_sync_mailbox_data_ddr[16];
    assign S_left_sync_id_ddr = S_left_sync_mailbox_data_ddr[15:0];
    // S_video_rd_data is the registered, clean local RGB before hdmi_mixer.
    // VTC user/last and the actual read enable follow the same two clock delay.
    stereo_left_video_tap stereo_left_video_tap_inst (
        .clk(S_hdmi_pixel_clk), .rst(~S_video_out_rst_n),
        .read_enable_i(S_hdmi_window_rd_en), .frame_user_i(S_hdmi_user),
        .line_last_i(S_hdmi_last), .vsync_i(S_hdmi_vsync),
        .frame_start_o(S_left_input_frame_start),
        .pixel_valid_o(S_left_input_pixel_valid),
        .line_end_o(S_left_input_line_end), .frame_end_o(S_left_input_frame_end)
    );

    // HSV passive local RGB side branch. Existing stereo input wiring is unchanged.
    hsv_fullres_input hsv_fullres_input_inst (
        .clk(S_hdmi_pixel_clk), .rst(~S_video_out_rst_n),
        .pixel_rgb_i(S_video_rd_data), .pixel_valid_i(S_left_input_pixel_valid),
        .frame_start_i(S_left_input_frame_start), .line_end_i(S_left_input_line_end),
        .frame_end_i(S_left_input_frame_end), .video_error_i(S_left_video_error),
        .frame_valid_i(left_video_frame_valid),
        .pixel_rgb_o(S_hsv_sample_rgb), .pixel_valid_o(S_hsv_sample_valid),
        .pixel_x_o(S_hsv_sample_x), .pixel_y_o(S_hsv_sample_y),
        .frame_start_o(S_hsv_sample_start), .frame_end_o(S_hsv_sample_end),
        .frame_abort_o(S_hsv_sample_abort),
        .abort_reason_o(S_hsv_abort_reason), .abort_pixel_count_o(S_hsv_abort_count),
        .abort_source_x_o(S_hsv_abort_x), .abort_source_y_o(S_hsv_abort_y)
    );
    hsv_red_threshold #(.S_MIN(8'd100), .V_MIN(8'd50),
                        .GREEN_S_MIN(HSV_GREEN_S_MIN), .GREEN_V_MIN(HSV_GREEN_V_MIN),
                        .GREEN_HUE_DELTA_SCALE(HSV_GREEN_HUE_DELTA_SCALE),
                        .X_WIDTH(11), .Y_WIDTH(10)) hsv_red_threshold_inst (
        .clk(S_hdmi_pixel_clk), .rst(~S_video_out_rst_n),
        .pixel_rgb_i(S_hsv_sample_rgb), .pixel_valid_i(S_hsv_sample_valid),
        .pixel_x_i(S_hsv_sample_x), .pixel_y_i(S_hsv_sample_y),
        .frame_start_i(S_hsv_sample_start), .frame_end_i(S_hsv_sample_end),
        .frame_abort_i(S_hsv_sample_abort),
        .red_mask_o(S_hsv_red_mask), .green_mask_o(S_hsv_green_mask),
        .yellow_mask_o(S_hsv_yellow_mask),
        .pixel_valid_o(S_hsv_pixel_valid),
        .pixel_x_o(S_hsv_pixel_x), .pixel_y_o(S_hsv_pixel_y),
        .frame_start_o(S_hsv_frame_start), .frame_end_o(S_hsv_frame_end),
        .frame_abort_o(S_hsv_frame_abort)
    );
    hsv_red_pixel_counter #(.IMAGE_WIDTH(1280), .IMAGE_HEIGHT(720),
                            .X_WIDTH(11), .Y_WIDTH(10), .COUNT_WIDTH(20), .TOP_ROWS(8))
    hsv_red_pixel_counter_inst (
        .clk(S_hdmi_pixel_clk), .rst(~S_video_out_rst_n),
        .red_mask_i(S_hsv_red_mask), .green_mask_i(S_hsv_green_mask),
        .yellow_mask_i(S_hsv_yellow_mask),
        .pixel_valid_i(S_hsv_pixel_valid),
        .pixel_x_i(S_hsv_pixel_x), .pixel_y_i(S_hsv_pixel_y),
        .frame_start_i(S_hsv_frame_start), .frame_end_i(S_hsv_frame_end),
        .frame_abort_i(S_hsv_frame_abort),
        .red_pixel_count_o(S_hsv_red_pixel_count),
        .green_pixel_count_o(S_hsv_green_pixel_count),
        .yellow_pixel_count_o(S_hsv_yellow_pixel_count),
        .frame_result_valid_o(S_hsv_frame_result_valid),
        .top_red_pixel_count_o(S_hsv_top_red_count)
    );

    // Share the existing counter's registered commit; no second frame validator.
    hsv_red_bbox #(
        .FRAME_PIXEL_LIMIT (1280*720),
        .X_WIDTH(11), .Y_WIDTH(10), .COUNT_WIDTH(20),
        .MIN_RED_PIXELS     (HSV_MIN_RED_PIXELS),
        .SPATIAL_FILTER_ENABLE (HSV_BBOX_FILTER_ENABLE),
        .IMAGE_WIDTH       (1280),
        .MIN_RUN_PIXELS    (HSV_BBOX_MIN_RUN_PIXELS),
        .MIN_ROW_PIXELS    (HSV_BBOX_MIN_ROW_PIXELS),
        .MIN_CONSECUTIVE_ROWS (HSV_BBOX_MIN_CONSECUTIVE_ROWS)
    ) hsv_red_bbox_inst (
        .clk               (S_hdmi_pixel_clk),
        .rst               (~S_video_out_rst_n),
        .red_mask_i        (S_hsv_red_mask),
        .pixel_valid_i     (S_hsv_pixel_valid),
        .pixel_x_i         (S_hsv_pixel_x),
        .pixel_y_i         (S_hsv_pixel_y),
        .frame_start_i     (S_hsv_frame_start),
        .frame_end_i       (S_hsv_frame_end),
        .frame_abort_i     (S_hsv_frame_abort),
        .frame_result_valid_i(S_hsv_frame_result_valid),
        .red_count_i       (S_hsv_red_pixel_count),
        .result_valid_o    (S_hsv_bbox_result_valid),
        .bbox_valid_o      (S_hsv_bbox_valid),
        .xmin_o            (S_hsv_bbox_xmin),
        .xmax_o            (S_hsv_bbox_xmax),
        .ymin_o            (S_hsv_bbox_ymin),
        .ymax_o            (S_hsv_bbox_ymax),
        .center_x_o        (),
        .center_y_o        (),
        .red_count_o       ()
    );

    // HSV_GREEN_BBOX_BEGIN
    // The shared counter supplies the same complete-frame commit for all masks.
    hsv_red_bbox #(
        .FRAME_PIXEL_LIMIT (1280*720),
        .X_WIDTH(11), .Y_WIDTH(10), .COUNT_WIDTH(20),
        .MIN_RED_PIXELS(HSV_MIN_GREEN_PIXELS),
        .SPATIAL_FILTER_ENABLE(HSV_BBOX_FILTER_ENABLE), .IMAGE_WIDTH(1280),
        .MIN_RUN_PIXELS(HSV_BBOX_MIN_RUN_PIXELS),
        .MIN_ROW_PIXELS(HSV_BBOX_MIN_ROW_PIXELS),
        .MIN_CONSECUTIVE_ROWS(HSV_BBOX_MIN_CONSECUTIVE_ROWS)
    ) hsv_green_bbox_inst (
        .clk                  (S_hdmi_pixel_clk),
        .rst                  (~S_video_out_rst_n),
        .red_mask_i           (S_hsv_green_mask),
        .pixel_valid_i        (S_hsv_pixel_valid),
        .pixel_x_i            (S_hsv_pixel_x),
        .pixel_y_i            (S_hsv_pixel_y),
        .frame_start_i        (S_hsv_frame_start),
        .frame_end_i          (S_hsv_frame_end),
        .frame_abort_i        (S_hsv_frame_abort),
        .frame_result_valid_i (S_hsv_frame_result_valid),
        .red_count_i          (S_hsv_green_pixel_count),
        .result_valid_o       (S_hsv_green_bbox_result_valid),
        .bbox_valid_o         (S_hsv_green_bbox_valid),
        .xmin_o               (S_hsv_green_bbox_xmin),
        .xmax_o               (S_hsv_green_bbox_xmax),
        .ymin_o               (S_hsv_green_bbox_ymin),
        .ymax_o               (S_hsv_green_bbox_ymax),
        .center_x_o           (),
        .center_y_o           (),
        .red_count_o          ()
    );
    // HSV_GREEN_BBOX_END

    // HSV_YELLOW_BBOX_BEGIN
    // The shared counter supplies the same complete-frame commit for all masks.
    hsv_red_bbox #(
        .FRAME_PIXEL_LIMIT (1280*720),
        .X_WIDTH(11), .Y_WIDTH(10), .COUNT_WIDTH(20),
        .MIN_RED_PIXELS(HSV_MIN_YELLOW_PIXELS),
        .SPATIAL_FILTER_ENABLE(HSV_BBOX_FILTER_ENABLE), .IMAGE_WIDTH(1280),
        .MIN_RUN_PIXELS(HSV_BBOX_MIN_RUN_PIXELS),
        .MIN_ROW_PIXELS(HSV_BBOX_MIN_ROW_PIXELS),
        .MIN_CONSECUTIVE_ROWS(HSV_BBOX_MIN_CONSECUTIVE_ROWS)
    ) hsv_yellow_bbox_inst (
        .clk                  (S_hdmi_pixel_clk),
        .rst                  (~S_video_out_rst_n),
        .red_mask_i           (S_hsv_yellow_mask),
        .pixel_valid_i        (S_hsv_pixel_valid),
        .pixel_x_i            (S_hsv_pixel_x),
        .pixel_y_i            (S_hsv_pixel_y),
        .frame_start_i        (S_hsv_frame_start),
        .frame_end_i          (S_hsv_frame_end),
        .frame_abort_i        (S_hsv_frame_abort),
        .frame_result_valid_i (S_hsv_frame_result_valid),
        .red_count_i          (S_hsv_yellow_pixel_count),
        .result_valid_o       (S_hsv_yellow_bbox_result_valid),
        .bbox_valid_o         (S_hsv_yellow_bbox_valid),
        .xmin_o               (S_hsv_yellow_bbox_xmin),
        .xmax_o               (S_hsv_yellow_bbox_xmax),
        .ymin_o               (S_hsv_yellow_bbox_ymin),
        .ymax_o               (S_hsv_yellow_bbox_ymax),
        .center_x_o           (),
        .center_y_o           (),
        .red_count_o          ()
    );
    // HSV_YELLOW_BBOX_END

    // Preserve the actual LEFT video source identity, never a right bbox/sync ID.
    // Capture at aligned input SOF; freeze only at accepted sampler EOF.
    // A new SOF immediately after EOF cannot change the pending identity.
    assign {S_hsv_bbox_source_frame_valid, S_hsv_bbox_source_frame_id} =
        S_hsv_bbox_result_valid ? hsv_source_frame_candidate_reg :
                                 hsv_source_frame_published_reg;
    always @(posedge S_hdmi_pixel_clk) begin
        if (S_left_input_frame_start) begin
            hsv_source_frame_work_reg <=
                {left_video_frame_valid, left_video_source_frame_id};
        end
        if (S_hsv_sample_end) begin
            hsv_source_frame_candidate_reg <= hsv_source_frame_work_reg;
        end
        if (S_hsv_bbox_result_valid) begin
            hsv_source_frame_published_reg <= hsv_source_frame_candidate_reg;
        end
        if (!S_video_out_rst_n) begin
            hsv_source_frame_work_reg <= 17'd0;
            hsv_source_frame_candidate_reg <= 17'd0;
            hsv_source_frame_published_reg <= 17'd0;
        end
    end

    // UDP video receiver paired with the transmitter at 192.168.137.2:6002.
    // Local endpoint: MAC 01:23:45:67:89:AC, IP 192.168.137.1, UDP port 6001.
    (* keep_hierarchy = "yes" *)
    ethernet_video_rx_top u_ethernet_video_rx_top (
        .clk_reference              (I_sys_clk),
        .rst_reference              (~I_rst_n),
        .clk_pixel                  (S_hdmi_pixel_clk),
        .rst_pixel                  (~S_hdmi_rst_n),
        .rgmii_rxd_i                (I_a_rgmii_rxd),
        .rgmii_rx_control_i         (I_a_rgmii_rx_ctl),
        .rgmii_rx_clock_i           (I_a_rgmii_rxc),
        .rgmii_txd_o                (O_a_rgmii_txd),
        .rgmii_tx_control_o         (O_a_rgmii_tx_ctl),
        .rgmii_tx_clock_o           (O_a_rgmii_txc),
        .phy_reset_no               (O_phy_rst),
        .frame_start_o              (S_eth_rx_frame_start),
        .pixel_valid_o              (S_eth_rx_pixel_valid),
        .pixel_rgb_o                (S_eth_rx_pixel_rgb),
        .frame_end_o                (S_eth_rx_frame_end),
        .frame_abort_o              (S_eth_rx_frame_abort),
        .video_fifo_overflow_o      (),
        .video_fifo_underflow_o     (S_eth_rx_fifo_underflow),
        .udp_packet_error_o         (),
        .video_frame_drop_o         (),
        .frame_id_o (S_eth_rx_frame_id),
        .sync_id_o (S_eth_rx_sync_id),
        .sync_valid_o (S_eth_rx_sync_valid),
        .source_frame_id_o (S_eth_rx_source_frame_id),
        .bbox_valid_o (S_eth_rx_bbox_valid),
        .bbox_x1_o (S_eth_rx_bbox_x1),
        .bbox_y1_o (S_eth_rx_bbox_y1),
        .bbox_x2_o (S_eth_rx_bbox_x2),
        .bbox_y2_o (S_eth_rx_bbox_y2),
        .bbox_source_valid_o (S_eth_rx_bbox_source_valid),
        .bbox_source_frame_id_o (S_eth_rx_bbox_source_frame_id),
        .bbox_result_id_o (S_eth_rx_bbox_result_id),
        .completed_frame_id_o       (),
        .completed_frame_count_o    (),
        .ip_rx_error_o              (),
        .mac_rx_error_o             ()
    );


    // RX has already crossed RGB and metadata to S_hdmi_pixel_clk. This passive
    // branch crops the framed stream without feeding HDMI or pairing with LEFT.
    stereo_right_capture #(
        .RIGHT_FRAME_TIMEOUT_CYCLES (15000000)
    ) stereo_right_capture_inst (
        .clk                           (S_hdmi_pixel_clk),
        .rst                           (~S_hdmi_rst_n),
        .frame_start_i                 (S_eth_rx_frame_start),
        .pixel_valid_i                 (S_eth_rx_pixel_valid),
        .pixel_rgb_i                   (S_eth_rx_pixel_rgb),
        .frame_end_i                   (S_eth_rx_frame_end),
        .frame_abort_i                 (S_eth_rx_frame_abort),
        .udp_frame_id_i                (S_eth_rx_frame_id),
        .sync_valid_i                  (S_eth_rx_sync_valid),
        .sync_id_i                     (S_eth_rx_sync_id),
        .source_frame_id_i             (S_eth_rx_source_frame_id),
        .bbox_valid_i                  (S_eth_rx_bbox_valid),
        .bbox_x1_i                     (S_eth_rx_bbox_x1),
        .bbox_y1_i                     (S_eth_rx_bbox_y1),
        .bbox_x2_i                     (S_eth_rx_bbox_x2),
        .bbox_y2_i                     (S_eth_rx_bbox_y2),
        .bbox_source_valid_i           (S_eth_rx_bbox_source_valid),
        .bbox_source_frame_id_i         (S_eth_rx_bbox_source_frame_id),
        .bbox_result_id_i              (S_eth_rx_bbox_result_id),
        .frame_start_o                 (),
        .pixel_valid_o                 (),
        .gray_o                        (),
        .x_o                           (),
        .y_o                           (),
        .frame_end_o                   (right_frame_end),
        .frame_abort_o                 (right_frame_abort),
        .udp_frame_id_o                (),
        .sync_valid_o                  (),
        .sync_id_o                     (),
        .source_frame_id_o             (),
        .bbox_result_metadata_o        (right_bbox_result_metadata),
        .bbox_current_valid_o          (),
        .bbox_valid_o                  (),
        .bbox_x1_o                     (),
        .bbox_y1_o                     (),
        .bbox_x2_o                     (),
        .bbox_y2_o                     (),
        .bbox_source_valid_o           (),
        .bbox_source_frame_id_o        (),
        .bbox_result_id_o              (),
        .right_completed_count_o       (),
        .right_abort_count_o           (),
        .right_timeout_count_o         (),
        .right_bbox_valid_count_o      (),
        .right_bbox_stale_count_o      (),
        .last_right_sync_id_o          (),
        .last_right_source_frame_id_o  ()
    );

    // Dedicated active-low controls on A9/B9 drive the STM32 car.
    wire [2:0] S_car_cmd_code;
    wire       S_car_cmd_valid;
    wire       S_car_cmd_ready;

    car_button_control #(
        .CLK_HZ(50000000),
        .DEBOUNCE_MS(20)
    ) u_car_button_control (
        .clk(I_sys_clk),
        .rst_n(I_rst_n),
        .forward_n(I_car_forward_n),
        .backward_n(I_car_backward_n),
        .cmd_ready(S_car_cmd_ready),
        .cmd_code(S_car_cmd_code),
        .cmd_valid(S_car_cmd_valid)
    );

    car_uart_tx #(
        .CLK_HZ(50000000),
        .BAUD_RATE(9600),
        .REPEAT_MS(100)
    ) u_car_uart_tx (
        .clk(I_sys_clk),
        .rst_n(I_rst_n),
        .cmd_code(S_car_cmd_code),
        .cmd_valid(S_car_cmd_valid),
        .cmd_ready(S_car_cmd_ready),
        .uart_tx(O_car_uart_tx),
        .busy()
    );





    // Independent fire-control branch; the existing video/ranging paths remain readers.
    // u_PLL actual C4 frequency is 75 MHz (.params_PLL.txt CLK4_ACTUAL_FREQ_DISP).
    localparam integer FIRE_CONTROL_CLK_HZ = 75000000;
    wire S_fire_ctrl_sample, S_fire_ctrl_valid, S_fire_distance_valid;
    wire [7:0] S_fire_center_x, S_fire_servo_angle;
    wire [7:0] S_fire_incremental_angle, S_fire_servo_target_angle;
    wire S_fire_position_ready;
    wire S_fire_position_pump_enable;
    wire S_fire_pump_enable;
    wire S_fire_ctrl_rst;
    reg [1:0] S_fire_reset_ready_sync = 2'b00;
    // Local reset release synchronization; assertion also gates the pump immediately.
    always @(posedge S_hdmi_pixel_clk) begin
        S_fire_reset_ready_sync <= {S_fire_reset_ready_sync[0], I_rst_n && S_hdmi_rst_n};
        if (!(I_rst_n && S_hdmi_rst_n)) S_fire_reset_ready_sync <= 2'b00;
    end
    assign S_fire_ctrl_rst = !(I_rst_n && S_hdmi_rst_n && S_fire_reset_ready_sync[1]);

    fire_control_bridge #(
        .CLK_FREQ_HZ          (FIRE_CONTROL_CLK_HZ),
        .RESULT_TIMEOUT_MS    (FIRE_RESULT_TIMEOUT_MS)
    ) fire_control_bridge_inst (
        .clk                             (S_hdmi_pixel_clk),
        .rst                             (S_fire_ctrl_rst),
        .right_frame_end_i               (right_frame_end),
        .right_bbox_result_metadata_i    (right_bbox_result_metadata),
        // These ABORT/read-underflow signals already belong to the 75 MHz domain.
        .link_fault_i                    (right_frame_abort || S_eth_rx_frame_abort ||
                                          S_eth_rx_fifo_underflow),
        .pair_take_i                     (1'b0),
        .pair_bbox_result_id_i           (16'd0),
        .pair_right_source_frame_id_i    (16'd0),
        .pair_sync_id_i                  (16'd0),
        .range_done_i                    (1'b0),
        .raw_range_valid_i               (1'b0),
        .range_pair_sync_id_i            (16'd0),
        .fire_sample_o                   (S_fire_ctrl_sample),
        .fire_valid_o                    (S_fire_ctrl_valid),
        .fire_center_x_o                 (S_fire_center_x),
        .distance_valid_o                ()
    );

    fire_aim_controller #(
        .CLK_FREQ_HZ          (FIRE_CONTROL_CLK_HZ),
        .UPDATE_INTERVAL_MS   (50),
        .IMAGE_WIDTH          (160),
        .DEAD_ZONE            (5),
        .STABLE_SAMPLES       (3),
        .ANGLE_STEP           (8'd1),
        .MIN_ANGLE            (8'd10),
        .MAX_ANGLE            (8'd170),
        .RESET_ANGLE          (8'd90),
        .REVERSE_DIRECTION    (FIRE_SERVO_REVERSE)
    ) fire_aim_controller_inst (
        .clk                  (S_hdmi_pixel_clk),
        .rst                  (S_fire_ctrl_rst),
        .fire_sample_i        (S_fire_ctrl_sample),
        .fire_valid_i         (S_fire_ctrl_valid),
        .fire_center_x_i      (S_fire_center_x),
        .distance_valid_i     (S_fire_distance_valid),
        .servo_angle_o        (S_fire_incremental_angle),
        .aim_locked_o         (),
        .pump_enable_o        (S_fire_pump_enable),
        .state_o              ()
    );

    // HC-SR04 replaces stereo distance validity. Keep fresh bbox/link qualification
    // from the bridge; the default FIRE_PUMP_REQUIRE_DISTANCE remains unchanged.
    assign S_fire_distance_valid = S_hcsr04_distance_valid && S_fire_ctrl_valid;

    // Fixed-camera positioning does not depend on stereo distance or change its algorithms.
    generate
        if (FIRE_SERVO_POSITION_MODE) begin : servo_position_mode
            fire_servo_position #(
                .CLK_FREQ_HZ              (FIRE_CONTROL_CLK_HZ),
                .UPDATE_INTERVAL_MS       (FIRE_SERVO_POSITION_INTERVAL_MS),
                .IMAGE_WIDTH              (160),
                .DEAD_ZONE                (5),
                .PIXELS_PER_DEGREE_SHIFT  (FIRE_SERVO_PIXELS_PER_DEGREE_SHIFT),
                .SETTLE_MS                (FIRE_SERVO_SETTLE_MS),
                .ANGLE_STEP               (8'd1),
                .MIN_ANGLE                (8'd10),
                .MAX_ANGLE                (8'd170),
                .RESET_ANGLE              (8'd90),
                .REVERSE_DIRECTION        (FIRE_SERVO_REVERSE)
            ) fire_servo_position_inst (
                .clk                  (S_hdmi_pixel_clk),
                .rst                  (S_fire_ctrl_rst),
                .fire_sample_i        (S_fire_ctrl_sample),
                .fire_valid_i         (S_fire_ctrl_valid),
                .fire_center_x_i      (S_fire_center_x),
                .servo_angle_o        (S_fire_servo_angle),
                .target_angle_o       (S_fire_servo_target_angle),
                .position_ready_o     (S_fire_position_ready)
            );

            // Fixed cameras need not bring the detected box back to image centre.
            fire_position_pump #(
                .STABLE_SAMPLES       (FIRE_PUMP_STABLE_SAMPLES)
            ) fire_position_pump_inst (
                .clk                  (S_hdmi_pixel_clk),
                .rst                  (S_fire_ctrl_rst),
                .fire_sample_i        (S_fire_ctrl_sample),
                .fire_valid_i         (S_fire_ctrl_valid),
                .position_ready_i     (S_fire_position_ready),
                .distance_allowed_i   (!FIRE_PUMP_REQUIRE_DISTANCE || S_fire_distance_valid),
                .pump_enable_o        (S_fire_position_pump_enable)
            );
        end else begin : servo_incremental_mode
            assign S_fire_servo_angle = S_fire_incremental_angle;
            assign S_fire_servo_target_angle = S_fire_incremental_angle;
            assign S_fire_position_ready = 1'b1;
            assign S_fire_position_pump_enable = 1'b0;
        end
    endgenerate

    // Compile-time selection only: no runtime clock mux or new clock crossing.
    // SERVO_TEST_MODE=0 restores automatic tracking on the original pixel clock.
    generate
        if (SERVO_TEST_MODE) begin : servo_test_mode
            wire test_rst;
            wire [7:0] test_angle;
            reg [1:0] test_reset_ready_sync = 2'b00;
            always @(posedge I_sys_clk) begin
                test_reset_ready_sync <= {test_reset_ready_sync[0], I_rst_n};
                if (!I_rst_n) test_reset_ready_sync <= 2'b00;
            end
            assign test_rst = !I_rst_n || !test_reset_ready_sync[1];

            servo_test_controller #(
                .CLK_FREQ_HZ          (50000000),
                .DWELL_MS             (SERVO_TEST_DWELL_MS)
            ) servo_test_controller_inst (
                .clk                  (I_sys_clk),
                .rst                  (test_rst),
                .servo_angle_o        (test_angle)
            );

            servo_pwm #(
                .CLK_FREQ_HZ          (50000000),
                .PWM_PERIOD_US        (20000),
                .MIN_ANGLE            (10),
                .MAX_ANGLE            (170),
                .RESET_ANGLE          (90)
            ) servo_test_pwm_inst (
                .clk                  (I_sys_clk),
                .rst                  (test_rst),
                .servo_angle_i        (test_angle),
                .servo_pwm_o          (servo_pwm_out)
            );
        end else begin : servo_automatic_mode
            servo_pwm #(
                .CLK_FREQ_HZ          (FIRE_CONTROL_CLK_HZ),
                .PWM_PERIOD_US        (20000),
                .MIN_ANGLE            (10),
                .MAX_ANGLE            (170),
                .RESET_ANGLE          (90)
            ) servo_pwm_inst (
                .clk                  (S_hdmi_pixel_clk),
                .rst                  (S_fire_ctrl_rst),
                .servo_angle_i        (S_fire_servo_angle),
                .servo_pwm_o          (servo_pwm_out)
            );
        end
    endgenerate

    // The manual test uses the 50 MHz crystal and external reset, not the video clock.
    wire S_manual_pump_enable, S_pump_drive_enable;
    generate
        if (PUMP_MANUAL_TEST_MODE) begin : pump_manual_test
            pump_switch_test #(
                .CLK_FREQ_HZ       (50000000),
                .DEBOUNCE_MS       (PUMP_TEST_DEBOUNCE_MS),
                .SWITCH_ACTIVE_LOW (PUMP_TEST_SWITCH_ACTIVE_LOW)
            ) pump_switch_test_inst (
                .clk           (I_sys_clk),
                .rst           (~I_rst_n),
                .switch_i      (I_pump_test_switch),
                .pump_enable_o (S_manual_pump_enable)
            );
        end else begin : pump_automatic_control
            assign S_manual_pump_enable = 1'b0;
        end
    endgenerate
    // Independent servo self-test keeps its existing forced-OFF pump priority.
    assign S_pump_drive_enable = SERVO_TEST_MODE ? 1'b0 :
        (PUMP_MANUAL_TEST_MODE ? S_manual_pump_enable :
         (FIRE_SERVO_POSITION_MODE ? S_fire_position_pump_enable : S_fire_pump_enable));
    assign pump_ctrl_out = FIRE_PUMP_ACTIVE_HIGH ? S_pump_drive_enable : ~S_pump_drive_enable;


    // BEGIN VEXRISCV_B_MAIN_INTEGRATION
    // Local ROM self-test plus protected DDR execution; original video FIFO retained.
    wire [31:0] S_cpu_cycle_count;
    wire [31:0] S_cpu_status;
    wire [31:0] S_cpu_heartbeat;
    wire [31:0] S_cpu_last_trap;
    wire [31:0] S_cpu_result;
    wire S_cpu_protocol_error;
    wire [2:0] S_cpu_debug_state;
    wire S_cpu_rst;
    wire S_cpu_clock_ready;
    wire S_cpu_boot_pass;
    wire S_cpu_boot_fail;
    wire S_cpu_ddr_req_valid, S_cpu_ddr_req_ready, S_cpu_ddr_req_write;
    wire [24:0] S_cpu_ddr_req_addr;
    wire [127:0] S_cpu_ddr_req_data;
    wire [15:0] S_cpu_ddr_req_mask;
    wire S_cpu_ddr_rsp_valid, S_cpu_ddr_rsp_ready;
    wire [32:0] S_cpu_ddr_response;
    wire [1:0] S_cpu_ddr_req_lane;
    wire [3:0] S_cpu_ddr_req_select;
    wire S_cpu_ddr_busy, S_cpu_ddr_error, S_cpu_ddr_read_done, S_cpu_ddr_write_done;
    wire [31:0] S_cpu_ddr_status, S_cpu_ddr_heartbeat;
    wire S_cpu_ddr_link_ready;
    // Narrow CPU mailbox; native 128-bit lines remain in the DDR domain.
    wire [63:0] S_ddr_word_request;
    wire S_ddr_word_req_valid, S_ddr_word_req_ready;
    wire S_ddr_word_rsp_valid, S_ddr_word_rsp_ready;
    wire [32:0] S_ddr_word_response;
    wire S_ddr_native_write;
    wire [24:0] S_ddr_native_addr;
    wire [31:0] S_ddr_native_wdata;
    wire [3:0] S_ddr_native_mask;
    wire S_ddr_native_req_valid, S_ddr_native_req_ready;
    wire S_ddr_native_rsp_valid, S_ddr_native_rsp_ready, S_ddr_native_error;
    wire [31:0] S_ddr_native_rdata;
    wire [1:0] S_ddr_native_rsp_lane;
    wire S_ddr_arb_error, S_ddr_arb_busy;
    wire [1:0] S_ddr_arb_owner;
    wire S_cpu_ddr_reset_request;
    wire S_cpu_ddr_rst;
    (* async_reg="true" *) reg [1:0] S_cpu_ddr_reset_sync=2'b11;
    (* async_reg="true" *) reg [1:0] S_cpu_ddr_ready_sync=2'b00;
    (* async_reg="true" *) reg [1:0] S_cpu_ddr_arb_error_sync=2'b00;
    reg S_cpu_ddr_cdc_fault=1'b0;
    reg S_cpu_ddr_read_toggle=1'b0, S_cpu_ddr_write_toggle=1'b0;
    localparam integer CPU_SAMPLE_WIDTH = CPU_MIN_AREA ? 7 : 17;
    // TD SWUG111 2.2.2.4 inserts a real ChipWatcher consumer for MARK_DEBUG.
    // Both modes consume software-written heartbeat, not an independent counter.
    (* MARK_DEBUG = "TRUE" *) reg [CPU_SAMPLE_WIDTH-1:0] S_cpu_debug_sample =
        {CPU_SAMPLE_WIDTH{1'b0}};

    assign S_cpu_boot_pass = S_cpu_status == 32'h600d0001;
    assign S_cpu_boot_fail = S_cpu_status == 32'hbad00001;

    vexriscv_b_reset #(
        .HOLD_CYCLES (1024)
    ) u_cpu_boot_reset (
        .clk            (I_sys_clk),
        .rst            (~I_rst_n),
        .clock_locked_i (S_pll_lock),
        .ready_o        (S_cpu_clock_ready),
        .cpu_reset_o    (S_cpu_rst)
    );

    generate
        if (!CPU_MIN_AREA) begin : cpu_debug_observation
            always @(posedge I_sys_clk) begin
                S_cpu_debug_sample <= {S_cpu_rst, S_cpu_clock_ready, S_cpu_boot_fail,
                    S_cpu_heartbeat[7:0], S_cpu_debug_state,
                    S_cpu_boot_pass, S_cpu_protocol_error, S_cpu_last_trap[31]};
                if (S_cpu_rst)
                    S_cpu_debug_sample <= {S_cpu_rst, S_cpu_clock_ready, 15'd0};
            end
        end else begin : cpu_health_observation
            always @(posedge I_sys_clk) begin
                S_cpu_debug_sample <= {S_cpu_rst, S_cpu_clock_ready, S_cpu_boot_fail,
                    S_cpu_heartbeat[1:0], S_cpu_boot_pass, S_cpu_protocol_error};
                if (S_cpu_rst)
                    S_cpu_debug_sample <= {S_cpu_rst, S_cpu_clock_ready, 5'd0};
            end
        end
    endgenerate

    (* keep_hierarchy = "true" *) vexriscv_b_subsystem #(
        .TIMER_PERIOD_CYCLES (50000),
        .WAIT_CYCLES         (1),
        .ENABLE_DDR          (1'b1),
        .DDR_BOOT_ENABLE     (1'b1),
        .UART_ENABLE         (1'b1),
        .DDR_WORD_RESPONSE   (1)
    ) u_vexriscv_linux (
        .clk                (I_sys_clk),
        .rst                (S_cpu_rst),
        .uart_rx_i          (I_cpu_uart_rx),
        .wifi_rx_i          (I_wifi_uart_rx),
        .wifi_tx_o          (O_wifi_uart_tx),
        .uart_tx_o          (O_cpu_uart_tx),
        .cycle_count_o      (S_cpu_cycle_count),
        .status_o           (S_cpu_status),
        .heartbeat_o        (S_cpu_heartbeat),
        .last_trap_o        (S_cpu_last_trap),
        .result_o           (S_cpu_result),
        .protocol_error_o   (S_cpu_protocol_error),
        .debug_state_o      (S_cpu_debug_state),
        .ddr_ready_i        (S_cpu_ddr_ready_sync[1] && S_cpu_ddr_link_ready),
        .ddr_errors_i       ({S_cpu_ddr_cdc_fault,S_cpu_ddr_arb_error_sync[1]}),
        .ddr_req_valid_o    (S_cpu_ddr_req_valid), .ddr_req_ready_i(S_cpu_ddr_req_ready),
        .ddr_req_write_o    (S_cpu_ddr_req_write), .ddr_req_addr_o(S_cpu_ddr_req_addr),
        .ddr_req_wdata_o    (S_cpu_ddr_req_data), .ddr_req_mask_o(S_cpu_ddr_req_mask),
        .ddr_req_lane_o     (S_cpu_ddr_req_lane), .ddr_req_select_o(S_cpu_ddr_req_select),
        .ddr_rsp_valid_i    (S_cpu_ddr_rsp_valid), .ddr_rsp_ready_o(S_cpu_ddr_rsp_ready),
        .ddr_rsp_rdata_i    (S_cpu_ddr_response[31:0]),
        .ddr_rsp_error_i    (S_cpu_ddr_response[32]),
        .ddr_status_o       (S_cpu_ddr_status), .ddr_heartbeat_o(S_cpu_ddr_heartbeat),
        .ddr_busy_o         (S_cpu_ddr_busy), .ddr_error_o(S_cpu_ddr_error),
        .ddr_read_done_o    (S_cpu_ddr_read_done), .ddr_write_done_o(S_cpu_ddr_write_done)
    );
    // Only new DDR/CDC controls use this qualifier. Video resets and DDR IP
    // initialization remain exactly as before. Assert async, release on DDR clk.
    assign S_cpu_ddr_reset_request=!S_rst_n || !S_init_calib_complete;
    always @(posedge S_ddr_clk or posedge S_cpu_ddr_reset_request) begin
        if (S_cpu_ddr_reset_request) S_cpu_ddr_reset_sync<=2'b11;
        else S_cpu_ddr_reset_sync<={S_cpu_ddr_reset_sync[0],1'b0};
    end
    assign S_cpu_ddr_rst=S_cpu_ddr_reset_sync[1];
    always @(posedge I_sys_clk) begin
        S_cpu_ddr_ready_sync<={S_cpu_ddr_ready_sync[0],S_init_calib_complete && S_rst_n};
        S_cpu_ddr_arb_error_sync<={S_cpu_ddr_arb_error_sync[0],S_ddr_arb_error};
        if (S_cpu_ddr_busy && !S_cpu_ddr_link_ready && S_cpu_ddr_ready_sync[1])
            S_cpu_ddr_cdc_fault<=1'b1;
        if (S_cpu_ddr_read_done) S_cpu_ddr_read_toggle<=!S_cpu_ddr_read_toggle;
        if (S_cpu_ddr_write_done) S_cpu_ddr_write_toggle<=!S_cpu_ddr_write_toggle;
        if (S_cpu_rst) begin
            S_cpu_ddr_ready_sync<=2'b00;
            S_cpu_ddr_arb_error_sync<=2'b00;
            S_cpu_ddr_cdc_fault<=1'b0;
            S_cpu_ddr_read_toggle<=1'b0;S_cpu_ddr_write_toggle<=1'b0;
        end
    end
    cpu_ddr_cdc #(.REQUEST_WIDTH(64), .RESPONSE_WIDTH(33), .RESPONSE_HELD_BY_TARGET(1), .REQUEST_CAPTURED_BY_TARGET(1)) u_cpu_ddr_cdc (
        .s_clk(I_sys_clk),.s_rst(S_cpu_rst),.m_clk(S_ddr_clk),.m_rst(S_cpu_ddr_rst),
        .s_req_valid_i(S_cpu_ddr_req_valid),.s_req_ready_o(S_cpu_ddr_req_ready),
        .s_req_payload_i({S_cpu_ddr_req_write,S_cpu_ddr_req_addr,S_cpu_ddr_req_data[31:0],S_cpu_ddr_req_select,S_cpu_ddr_req_lane}),
        .s_rsp_valid_o(S_cpu_ddr_rsp_valid),.s_rsp_ready_i(S_cpu_ddr_rsp_ready),
        .s_rsp_payload_o(S_cpu_ddr_response),
        .m_req_valid_o(S_ddr_word_req_valid),.m_req_ready_i(S_ddr_word_req_ready),
        .m_req_payload_o(S_ddr_word_request),
        .m_rsp_valid_i(S_ddr_word_rsp_valid),.m_rsp_ready_o(S_ddr_word_rsp_ready),
        .m_rsp_payload_i(S_ddr_word_response),
        .link_ready_o(S_cpu_ddr_link_ready)
    );
    cpu_ddr_word_service #(.NATIVE_WORD_RESPONSE(1), .NATIVE_WORD_REQUEST(1)) u_cpu_ddr_word_service (
        .clk(S_ddr_clk),.rst(S_cpu_ddr_rst),
        .backend_ready_i(S_init_calib_complete),.backend_error_i(S_ddr_arb_error),
        .req_valid_i(S_ddr_word_req_valid),.req_ready_o(S_ddr_word_req_ready),
        .req_payload_i(S_ddr_word_request),
        .rsp_valid_o(S_ddr_word_rsp_valid),.rsp_ready_i(S_ddr_word_rsp_ready),
        .rsp_payload_o(S_ddr_word_response),
        .native_req_valid_o(S_ddr_native_req_valid),.native_req_ready_i(S_ddr_native_req_ready),
        .native_req_write_o(S_ddr_native_write),.native_req_addr_o(S_ddr_native_addr),
        .native_req_wdata_o(S_ddr_native_wdata),.native_req_mask_o(S_ddr_native_mask),
        .native_rsp_valid_i(S_ddr_native_rsp_valid),.native_rsp_ready_o(S_ddr_native_rsp_ready),
        .native_rsp_error_i(S_ddr_native_error),.native_rsp_rdata_i(S_ddr_native_rdata),
        .native_rsp_lane_o(S_ddr_native_rsp_lane)
    );
    ddr_video_cpu_arbiter #(.WORD_RESPONSE(1), .HELD_WORD_REQUEST(1)) u_ddr_video_cpu_arbiter (
        .clk(S_ddr_clk),.rst(S_cpu_ddr_rst),.ddr_ready_i(S_init_calib_complete),
        .video_valid_i(S_video_queue_valid),.video_write_i(S_video_queue_write),
        .video_addr_i(S_video_queue_addr),.video_wdata_i(S_video_queue_wdata),
        .video_ready_o(S_video_queue_ready),.video_rvalid_o(S_video_mc_rvalid),
        .video_rdata_o(S_video_mc_rdata),
        .req_valid_i(S_ddr_native_req_valid),.req_ready_o(S_ddr_native_req_ready),
        .req_write_i(S_ddr_native_write),.req_addr_i(S_ddr_native_addr),
        .req_wdata_i(S_ddr_native_wdata),.req_mask_i(S_ddr_native_mask),
        .rsp_valid_o(S_ddr_native_rsp_valid),.rsp_ready_i(S_ddr_native_rsp_ready),
        .rsp_rdata_o(S_ddr_native_rdata),.rsp_error_o(S_ddr_native_error),
        .rsp_lane_i(S_ddr_native_rsp_lane),.req_lane_i(S_ddr_native_rsp_lane),
        .mc_en_o(S_mc_app_en),.mc_addr_o(S_mc_app_addr),.mc_cmd_o(S_mc_app_cmd),
        .mc_wdata_o(S_mc_app_wdf_data),.mc_mask_o(S_mc_app_wdf_mask),
        .mc_wren_o(S_mc_app_wdf_wren),.mc_wend_o(S_mc_app_wdf_end),
        .mc_awready_i(S_mc_awready),.mc_arready_i(S_mc_arready),.mc_wready_i(S_mc_wready),
        .mc_rvalid_i(S_mc_app_rd_data_valid),.mc_rlast_i(S_mc_app_rd_data_end),.mc_rdata_i(S_mc_app_rd_data),
        .error_o(S_ddr_arb_error),.busy_o(S_ddr_arb_busy),.owner_o(S_ddr_arb_owner),
        .read_done_o(),.write_done_o()
    );
    generate
        if (!CPU_MIN_AREA) begin : cpu_ddr_debug_observation
            (* MARK_DEBUG="TRUE" *) reg [10:0] S_cpu_ddr_debug_sample=11'd0;
            always @(posedge I_sys_clk) begin
                S_cpu_ddr_debug_sample<={S_cpu_ddr_ready_sync[1],S_cpu_ddr_busy,
                    (S_cpu_ddr_error || S_cpu_ddr_arb_error_sync[1] || S_cpu_ddr_cdc_fault),
                    (S_cpu_ddr_status==32'hd00d0001),(S_cpu_ddr_status==32'hbad20001),
                    S_cpu_ddr_heartbeat[3:0],S_cpu_ddr_read_toggle,S_cpu_ddr_write_toggle};
                if (S_cpu_rst) S_cpu_ddr_debug_sample<=11'd0;
            end
            // Passive video progress only; independent bits cross into 50 MHz.
            // Bit3 clears each display VSYNC; other progress bits latch until reset.
            (* async_reg="true" *) reg [7:0] video_status_meta=8'd0;
            (* async_reg="true" *) reg [7:0] video_status_sync=8'd0;
            (* MARK_DEBUG="TRUE" *) reg [7:0] S_video_debug_sample=8'd0;
            always @(posedge I_sys_clk) begin
                video_status_meta<={S_dbg_cam_cfg_seen,S_dbg_raw_seen,
                    S_dbg_isp_valid_seen,S_dbg_ddr_wr_seen,S_dbg_rd_req_seen,
                    S_dbg_ddr_rd_seen,S_dbg_video_nonzero_seen,S_video_read_credit_error};
                video_status_sync<=video_status_meta;
                S_video_debug_sample<=video_status_sync;
                if (S_cpu_rst) begin
                    video_status_meta<=8'd0;
                    video_status_sync<=8'd0;
                    S_video_debug_sample<=8'd0;
                end
            end
            // DDR-domain historical milestones do not clear every display VSYNC.
            reg video_read_request_seen=1'b0;
            reg video_read_queue_seen=1'b0;
            reg video_read_native_seen=1'b0;
            always @(posedge S_ddr_clk or negedge S_rst_n) begin
                if (!S_rst_n) begin
                    video_read_request_seen<=1'b0;
                    video_read_queue_seen<=1'b0;
                    video_read_native_seen<=1'b0;
                end else begin
                    if (S_vo_ddr_rd_en) video_read_request_seen<=1'b1;
                    if (S_video_queue_valid && !S_video_queue_write)
                        video_read_queue_seen<=1'b1;
                    if (S_ddr_arb_owner==2'd0 && S_mc_app_en &&
                        S_mc_app_cmd[0] && S_mc_arready)
                        video_read_native_seen<=1'b1;
                end
            end
            // Independent status bits, not an atomic multi-bit counter snapshot.
            (* async_reg="true" *) reg [15:0] video_read_status_meta=16'd0;
            (* async_reg="true" *) reg [15:0] video_read_status_sync=16'd0;
            (* MARK_DEBUG="TRUE" *) reg [15:0] S_video_read_debug_sample=16'd0;
            always @(posedge I_sys_clk) begin
                video_read_status_meta<={S_video_out_rst_n,
                    S_video_read_block_status[3],S_video_in_wr_busy,
                    S_video_read_block_status[2],S_ddr_user_ready,S_vo_ddr_rd_ready,
                    S_video_read_block_status[1],(|S_vo_ddr_outstanding),
                    S_video_read_block_status[4],video_read_request_seen,
                    video_read_queue_seen,video_read_native_seen,S_dbg_ddr_rd_seen,
                    S_mc_arready,S_video_read_block_status[0],S_video_read_credit_error};
                video_read_status_sync<=video_read_status_meta;
                S_video_read_debug_sample<=video_read_status_sync;
                if (S_cpu_rst) begin
                    video_read_status_meta<=16'd0;
                    video_read_status_sync<=16'd0;
                    S_video_read_debug_sample<=16'd0;
                end
            end
        end
    endgenerate
    // END VEXRISCV_B_MAIN_INTEGRATION
endmodule
