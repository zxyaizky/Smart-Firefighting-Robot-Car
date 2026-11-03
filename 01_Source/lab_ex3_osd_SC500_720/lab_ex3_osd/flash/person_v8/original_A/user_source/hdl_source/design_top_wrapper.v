// Change Log: 2026-10-22 Codex 640x360@30 Ethernet; NPU input unchanged.
// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// Change Log: 2026-10-03 Codex v2.1 Default-on automatic exposure; manual fallback.


module design_top_wrapper #(
    parameter integer AUTO_EXPOSURE_ENABLE = 1,
    parameter [10:0] CARTOON_EDGE_LOW = 11'd100,
    parameter [10:0] CARTOON_EDGE_HIGH = 11'd180,
    parameter integer CARTOON_LEVELS = 4,
    parameter integer CARTOON_SMOOTH_ENABLE = 1, // 1=2x1 no RAM; 2=2x2; 0=off
    parameter integer CARTOON_EDGE_GROW = 1,
    parameter integer CARTOON_COLOR_BOOST_ENABLE = 1,
    parameter [23:0] CARTOON_WEAK_EDGE_COLOR = 24'h404040
) (
    input wire        I_sys_clk,
    input wire        stereo_sync_i,
    input wire        I_rst_n,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [1:0]  I_button,
    input wire        key,
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
    output wire       ci03t_uart_tx,

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
	
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;
    // NPU side branch: official video/DDR/display datapaths are not backpressured.
    wire S_npu_clk, S_npu_pll_lock, S_npu_reset_ready, S_npu_rst_n;
    reg [1:0] S_npu_rst_sync;
    wire S_npu_input_busy, S_npu_frame_valid, S_npu_byte_valid;
    wire [7:0] S_npu_byte;
    // Absolute-ID receiver stays alive while the MIPI byte clock is stopped.
    wire S_stereo_sync_packet;
    wire [15:0] S_stereo_sync_packet_id;
    wire S_stereo_sync_mailbox_event;
    wire [16:0] S_stereo_sync_mailbox_data;
    (* keep = "true" *) wire S_stereo_sync_mailbox_ready;
    (* keep = "true" *) wire S_stereo_sync_mailbox_overflow;
    wire S_stereo_sync_pulse;
    wire [15:0] S_stereo_pending_sync_id;
    (* keep = "true" *) wire S_stereo_selected_frame_start;
    (* keep = "true" *) wire S_stereo_selected_frame_pending;
    (* keep = "true" *) wire S_stereo_request_overrun;
    wire [15:0] S_stereo_selected_sync_id;
    wire [15:0] S_capture_frame_id;
    wire S_stereo_source_sync_valid;
    wire [32:0] S_camera_frame_metadata;
    wire [33:0] S_video_page_metadata;
    wire [32:0] S_video_frame_metadata;
    wire S_video_frame_metadata_valid;
    wire [32:0] S_npu_capture_metadata;
    reg S_npu_frame_valid_d_reg = 1'b0;
    reg [15:0] S_npu_inference_source_id_reg = 16'd0;
    reg S_npu_inference_source_valid_reg = 1'b0;
    wire S_bbox_valid, S_bbox_source_valid;
    wire [7:0] S_bbox_x1, S_bbox_x2;
    wire [6:0] S_bbox_y1, S_bbox_y2;
    wire [15:0] S_bbox_source_frame_id, S_bbox_result_id;
    wire [127:0] S_udp_frame_metadata;
    wire S_npu_model_ready, S_npu_done, S_npu_tile_error;
    wire S_npu_tile_ready, S_npu_tile_done, S_npu_layer_done;
    wire S_npu_tensor_valid;
    wire [63:0] S_npu_tensor_data;
    // Hold the latest complete inference as a level, not a per-frame pulse.
    reg S_voice_fire_detect;
    wire [7:0] S_npu_tensor_x, S_npu_tensor_y;
    wire S_npu_weight_req;
    wire [23:0] S_npu_weight_addr;
    wire [15:0] S_npu_weight_len;
    // U33 configuration-flash boot stream, delivered by the hard MCU.
    wire S_param_begin_valid, S_param_begin_ready, S_param_valid, S_param_ready;
    wire [23:0] S_param_size_bytes;
    wire [31:0] S_param_crc32;
    wire [127:0] S_param_data;
    wire S_param_last, S_param_busy, S_param_error;
    wire S_u33_boot_done, S_u33_boot_error;
    wire S_u33_boot_rst;
    wire S_mcu_ahb_clk;
    wire [1:0] S_mcu_htrans;
    wire S_mcu_hwrite;
    wire [30:0] S_mcu_haddr;
    wire [2:0] S_mcu_hsize;
    wire [2:0] S_mcu_hburst;
    wire [3:0] S_mcu_hprot;
    wire S_mcu_hmastlock;
    wire [31:0] S_mcu_hwdata;
    wire [31:0] S_mcu_hrdata;
    wire [1:0] S_mcu_hresp;
    wire S_mcu_hready;
    wire S_init_calib_complete;
    wire S_npu_params_ready, S_npu_run_rst_n, S_npu_ddr_error;
    wire S_npu_weight_ready, S_npu_weight_valid;
    wire [15:0] S_npu_weight_data;
    // Independent clean 640x360 RGB side path for Ethernet video transmission.
    wire S_udp_frame_start_raw, S_udp_pixel_valid_raw;
    wire [23:0] S_udp_pixel_rgb_raw;
    wire S_udp_frame_end_raw, S_udp_frame_abort_raw;
    wire S_udp_fifo_overflow, S_udp_fifo_underflow, S_udp_frame_drop;
    wire [15:0] S_udp_completed_frame_id, S_udp_completed_frame_count;
    wire S_mc_read_ready, S_mc_write_ready;
    assign S_npu_run_rst_n=S_npu_rst_n && S_npu_params_ready;
    assign S_u33_boot_rst=!(S_rst_n && S_init_calib_complete);




    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     

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
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

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
    wire        S_lane_error_any;

    wire [23:0] data ;

    wire  key_out;

    wire [23:0]S_quant4_center_out;
    wire [23:0] S_cartoon_rgb;
    wire [23:0] S_gaussian_rgb, S_quant_raw;
    wire S_gaussian_vsync, S_gaussian_href, S_gaussian_clken;
    wire [10:0] S_gaussian_x, S_gaussian_y;
    wire S_quant_vsync, S_quant_de;
    reg [10:0] S_quant_x, S_quant_y;
    wire [23:0] S_boosted_rgb;
    wire S_color_vsync, S_color_href, S_color_clken;
    wire [10:0] S_color_x, S_color_y;
    wire [23:0] S_smooth_rgb;
    wire S_smooth_vsync, S_smooth_href, S_smooth_clken;
    wire [10:0] S_smooth_x, S_smooth_y;
    reg [10:0] S_cartoon_input_x, S_cartoon_input_y;
    reg S_cartoon_input_de_d;
    wire S_sobel_strong, S_sobel_weak;
    wire [10:0] S_sobel_x, S_sobel_y;
    wire S_final_strong, S_final_weak;
    wire S_edge_vsync, S_edge_href, S_edge_clken;
    wire [10:0] S_edge_x, S_edge_y;

// RGB转YCbCr信号
    wire        S_ycbcr_hsync;
    wire        S_ycbcr_vsync;
    wire        S_ycbcr_de;
    wire [7:0]  S_img_y;
    wire [7:0]  S_img_cb;
    wire [7:0]  S_img_cr;
    wire [10:0] S_ycbcr_x, S_ycbcr_y;

    // Sobel输出信号
    wire        S_sobel_vsync;
    wire        S_sobel_href;
    wire        S_sobel_clken;
    wire        S_sobel_de;
    wire [23:0] S_sobel_rgb;


    //选择场有效信号
    wire mode_select_vsync;
    wire mode_select_de;
    wire S_npu_overlay_vsync;
    wire S_npu_overlay_de;
    wire [23:0] S_npu_overlay_data;

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


	

  
    // Passive RAW10 statistics; independent of display mode, NPU and UDP.
    // Default-on AE needs no new GPIO. Compile-time 0 retains legacy buttons.
    generate
        if (AUTO_EXPOSURE_ENABLE != 0) begin : automatic_exposure
            sc500_auto_exposure #(
                .TARGET_LEVEL       (8'd110),
                .TARGET_HYSTERESIS  (8'd8),
                .EXPOSURE_MIN       (16'd32),
                .EXPOSURE_MAX       (16'd1990),
                .EXPOSURE_INIT      (16'd1990),
                .GAIN_MIN           (16'd16),
                .GAIN_MAX           (16'd143),
                .GAIN_INIT          (16'd136),
                .SAMPLE_LOG2        (4),
                .MIN_SAMPLES        (16'd256)
            ) sc500_auto_exposure_inst (
                .clk_pixel            (S_csi_rx_clk),
                .clk_config           (S_24m_clk),
                .rst                  (~S_rst_n || ~I_rst_n),
                .frame_start_i        (S_raw10_frame_start),
                .pixel_valid_i        (S_raw10_valid),
                .pixel_data_i         (S_raw10_data),
                .camera_config_done_i (S_cam_cfg_done),
                .ae_config_done_i     (S_ae_cfg_done),
                .ae_request_o         (S_ae_req),
                .exposure_o           (S_ae),
                .gain_o               (S_ag)
            );
        end else begin : manual_exposure
            ae_set u_ae_set (
                .I_clk          (S_24m_clk),
                .I_rst          (~S_rst_n),
                .I_btn          ({I_button, 2'b11}),
                .I_cam_cfg_done (S_cam_cfg_done),
                .I_ae_cfg_done  (S_ae_cfg_done),
                .O_ae_req       (S_ae_req),
                .O_ae           (S_ae),
                .O_ag           (S_ag)
            );
        end
    endgenerate

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
    // 2026-10-03: receive the actual B ID, never count GPIO edges in CSI clock.
    stereo_sync_rx u_stereo_sync_rx (
        .clk (I_sys_clk), .rst (~I_rst_n), .stereo_sync_i (stereo_sync_i),
        .stereo_sync_pulse_o (S_stereo_sync_packet),
        .pending_sync_id_o (S_stereo_sync_packet_id)
    );
    // CDC: stable validated ID remains held until the CSI domain acknowledges.
    stereo_metadata_mailbox #(.DATA_WIDTH(17)) stereo_sync_receive_mailbox_inst (
        .clk_source(I_sys_clk), .rst_source(~I_rst_n),
        .clk_dest(S_csi_rx_clk), .rst_dest(~S_rst_n),
        .send_i(S_stereo_sync_packet), .data_i({1'b1, S_stereo_sync_packet_id}),
        .ready_o(S_stereo_sync_mailbox_ready),
        .overflow_o(S_stereo_sync_mailbox_overflow),
        .event_o(S_stereo_sync_mailbox_event), .data_o(S_stereo_sync_mailbox_data)
    );
    // Reject an empty/reset mailbox even if a paused destination sees a toggle.
    assign S_stereo_sync_pulse = S_stereo_sync_mailbox_event && S_stereo_sync_mailbox_data[16];
    assign S_stereo_pending_sync_id = S_stereo_sync_mailbox_data[15:0];
    stereo_frame_selector u_stereo_frame_selector (
        .clk (S_csi_rx_clk), .rst (~S_rst_n),
        .stereo_sync_pulse_i (S_stereo_sync_pulse),
        .pending_sync_id_i (S_stereo_pending_sync_id),
        .csi_frame_start_i (S_csi_frame_start),
        .selected_frame_start_o (S_stereo_selected_frame_start),
        .selected_sync_id_o (S_stereo_selected_sync_id),
        .selected_frame_pending_o (S_stereo_selected_frame_pending),
        .source_frame_id_o (S_capture_frame_id),
        .source_sync_valid_o (S_stereo_source_sync_valid),
        .request_overrun_o (S_stereo_request_overrun)
    );
    assign S_camera_frame_metadata = {
        S_stereo_source_sync_valid, S_stereo_selected_sync_id, S_capture_frame_id};

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
.axis_tlast  (S_axis_tlast )
);
	

// 原厂HD模式直接输出1280x720 RAW10，不再进行FPGA固定窗口裁剪。
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tuser  = S_axis_tuser;


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
.O_tdata         (S_ISP_O_tdata ),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.I_tready        ()
  );


    video_in u_video_in(
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        // Start the input-FIFO reset from the raw-frame marker.  The ISP
        // latency lets the reset finish before the first 128-bit word arrives.
        .I_camera_frame_start ( S_raw_tuser    ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_camera_metadata    ( S_camera_frame_metadata ),
        .O_page_metadata      ( S_video_page_metadata ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy   ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),

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

    video_out u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
        .I_page_metadata     ( S_video_page_metadata ),
        .O_frame_metadata    ( S_video_frame_metadata ),
        .O_frame_metadata_valid(S_video_frame_metadata_valid),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready     ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );



    // U33 shares the FPGA configuration pins and its clock is the dedicated
    // CCLK_0 pin. PH1P_LOGIC_QSPI2MCU inside the generated MCU IP hands those
    // pins to the hard MCU after configuration. Firmware executes from the U33
    // XIP window and copies the parameter area at flash offset 0x200000 to AHB.
    MCU u_npu_flash_mcu (
        .core_clk(S_100m_clk), .timer_clk(S_100m_clk),
        .core_reset(S_u33_boot_rst), .por_reset(S_u33_boot_rst),
        .nmi(1'b0), .clic_irq(23'd0),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0), .jtag_tdo(),
        .gpio0_in(1'b0), .gpio0_out(), .gpio0_dir(),
        .gpio1_in(1'b0), .gpio1_out(), .gpio1_dir(),
        .gpio2_in(1'b0), .gpio2_out(), .gpio2_dir(),
        .gpio3_in(1'b0), .gpio3_out(), .gpio3_dir(),
        .gpio4_in(1'b0), .gpio4_out(), .gpio4_dir(),
        .gpio5_in(1'b0), .gpio5_out(), .gpio5_dir(),
        .gpio6_in(1'b0), .gpio6_out(), .gpio6_dir(),
        .gpio7_in(1'b0), .gpio7_out(), .gpio7_dir(),
        .uart0_tx(), .uart0_rx(1'b1), .uart1_tx(), .uart1_rx(1'b1),
        .qspi1_clk(), .qspi1_ss(),
        .qspi1_d0_in(1'b0), .qspi1_d1_in(1'b0),
        .qspi1_d2_in(1'b0), .qspi1_d3_in(1'b0),
        .qspi1_d0_out(), .qspi1_d1_out(),
        .qspi1_d2_out(), .qspi1_d3_out(), .qspi1_dir(),
        .ahb_clk(S_mcu_ahb_clk), .htrans(S_mcu_htrans),
        .hwrite(S_mcu_hwrite), .haddr(S_mcu_haddr),
        .hsize(S_mcu_hsize), .hburst(S_mcu_hburst),
        .hprot(S_mcu_hprot), .hmastlock(S_mcu_hmastlock),
        .hwdata(S_mcu_hwdata), .hrdata(S_mcu_hrdata),
        .hresp(S_mcu_hresp), .hready(S_mcu_hready),
        .apb_clk(S_ddr_clk), .apb_rst(S_u33_boot_rst),
        .paddr(), .psel(), .penable(), .pwrite(), .pwdata(),
        .pstrobe(), .pprot(), .prdata(32'd0), .pready(1'b1),
        .pslverr(1'b0)
    );

    npu_u33_mcu_bridge #(
        .PARAM_SIZE_BYTES(24'd327680),
        .PARAM_CRC32(32'he27c4b4d)
    ) u_npu_u33_mcu_bridge (
        .clk_ahb(S_mcu_ahb_clk), .rst_ahb(S_u33_boot_rst),
        .i_htrans(S_mcu_htrans), .i_hwrite(S_mcu_hwrite),
        .i_haddr(S_mcu_haddr), .i_hsize(S_mcu_hsize),
        .i_hwdata(S_mcu_hwdata), .o_hrdata(S_mcu_hrdata),
        .o_hresp(S_mcu_hresp), .o_hready(S_mcu_hready),
        .clk_ddr(S_ddr_clk), .rst_ddr(S_u33_boot_rst),
        .o_load_begin_valid(S_param_begin_valid),
        .i_load_begin_ready(S_param_begin_ready),
        .o_load_size_bytes(S_param_size_bytes),
        .o_load_crc32(S_param_crc32),
        .o_load_valid(S_param_valid),
        .i_load_ready(S_param_ready),
        .o_load_data(S_param_data),
        .o_load_last(S_param_last),
        .o_done(S_u33_boot_done),
        .o_error(S_u33_boot_error)
    );

    // Video command FIFO and strict video-priority arbitration are inside this
    // subsystem. Parameter read responses never enter the video FIFO.
    npu_ddr_subsystem u_npu_ddr (
        .clk_ddr(S_ddr_clk), .clk_npu(S_npu_clk),
        .rst_n(S_rst_n && S_init_calib_complete), .i_client_rst_n(S_npu_run_rst_n),
        .i_video_wr(S_ddr_user_wr_en), .i_video_rd(S_ddr_user_rd_en),
        .i_video_addr(S_ddr_user_addr), .i_video_data(S_ddr_user_wr_data),
        .o_video_ready(S_ddr_user_ready), .o_video_rd_valid(S_ddr_user_rd_valid),
        .o_video_rd_data(S_ddr_user_rd_data),
        .i_load_begin_valid(S_param_begin_valid), .o_load_begin_ready(S_param_begin_ready),
        .i_load_size_bytes(S_param_size_bytes), .i_load_crc32(S_param_crc32),
        .i_load_valid(S_param_valid), .o_load_ready(S_param_ready),
        .i_load_data(S_param_data), .i_load_last(S_param_last),
        .o_load_busy(S_param_busy), .o_load_error(S_param_error),
        .o_params_ready_npu(S_npu_params_ready),
        .i_npu_req_valid(S_npu_weight_req), .o_npu_req_ready(S_npu_weight_ready),
        .i_npu_req_addr(S_npu_weight_addr), .i_npu_req_len(S_npu_weight_len),
        .o_npu_rd_valid(S_npu_weight_valid), .o_npu_rd_data(S_npu_weight_data),
        .o_app_en(S_mc_app_en), .o_app_addr(S_mc_app_addr), .o_app_cmd(S_mc_app_cmd),
        .i_app_read_ready(S_mc_read_ready), .i_app_write_ready(S_mc_write_ready),
        .o_wdf_valid(S_mc_app_wdf_wren), .o_wdf_data(S_mc_app_wdf_data),
        .o_wdf_end(S_mc_app_wdf_end), .o_wdf_mask(S_mc_app_wdf_mask[15:0]),
        .i_wdf_ready(S_mc_app_wdf_rdy), .i_rd_valid(S_mc_app_rd_data_valid),
        .i_rd_end(S_mc_app_rd_data_end), .i_rd_data(S_mc_app_rd_data),
        .o_transport_error(S_npu_ddr_error)
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
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask[15:0]),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_read_ready    ( S_mc_read_ready        ),
        .O_mc_app_write_ready   ( S_mc_write_ready       ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),

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
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );


    /* Key-controlled image modes disabled; keep all RTL for later re-enable.
    // Input coordinates are generated only for this display-effect branch.
    // They follow the same register stages as the pixel and sync controls.
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) begin
            S_cartoon_input_x <= 0;
            S_cartoon_input_y <= 0;
            S_cartoon_input_de_d <= 0;
        end else begin
            S_cartoon_input_de_d <= S_hdmi_out_de;
            if (S_hdmi_out_vsync) S_cartoon_input_y <= 0;
            else if (S_cartoon_input_de_d && !S_hdmi_out_de)
                S_cartoon_input_y <= S_cartoon_input_y + 1'b1;
            if (!S_hdmi_out_de) S_cartoon_input_x <= 0;
            else S_cartoon_input_x <= S_cartoon_input_x + 1'b1;
        end
    end

    cartoon_smooth_2x2 #(
        .IMG_HDISP(1280), .ENABLE(CARTOON_SMOOTH_ENABLE)
    ) u_cartoon_smooth (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .in_vsync(S_hdmi_out_vsync), .in_href(S_hdmi_out_de),
        .in_clken(S_hdmi_out_de), .in_x(S_cartoon_input_x),
        .in_y(S_cartoon_input_y), .in_rgb(S_hdmi_out_data),
        .out_vsync(S_smooth_vsync), .out_href(S_smooth_href),
        .out_clken(S_smooth_clken), .out_x(S_smooth_x),
        .out_y(S_smooth_y), .out_rgb(S_smooth_rgb)
    );

    rgb2ycbcr u_cartoon_rgb2ycbcr (
        .pclk(S_hdmi_pixel_clk), .sys_rst_n(S_hdmi_rst_n),
        .rgb888_r(S_smooth_rgb[23:16]), .rgb888_g(S_smooth_rgb[15:8]),
        .rgb888_b(S_smooth_rgb[7:0]),
        .pre_video_hsync(1'b0), .pre_video_vsync(S_smooth_vsync),
        .pre_video_de(S_smooth_href & S_smooth_clken),
        .i_x_pos(S_smooth_x), .i_y_pos(S_smooth_y),
        .post_video_hsync(S_ycbcr_hsync), .post_video_vsync(S_ycbcr_vsync),
        .post_video_de(S_ycbcr_de), .post_i_x_pos(S_ycbcr_x),
        .post_i_y_pos(S_ycbcr_y), .img_y(S_img_y),
        .img_cb(S_img_cb), .img_cr(S_img_cr)
    );

    cartoon_gaussian_3x3 #(.IMG_HDISP(1280)) u_cartoon_gaussian (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .in_vsync(S_hdmi_out_vsync), .in_href(S_hdmi_out_de),
        .in_clken(S_hdmi_out_de), .in_x(S_cartoon_input_x),
        .in_y(S_cartoon_input_y), .in_rgb(S_hdmi_out_data),
        .out_vsync(S_gaussian_vsync), .out_href(S_gaussian_href),
        .out_clken(S_gaussian_clken), .out_x(S_gaussian_x),
        .out_y(S_gaussian_y), .out_rgb(S_gaussian_rgb)
    );

    rgb_quantize_4 #(.IMG_HDISP(11'd1280),
                     .LEVELS(CARTOON_LEVELS), .DIRECT_INPUT(1))
    u_rgb_quantize_4 (
        .rgb_in(S_gaussian_rgb), .S_hdmi_pixel_clk(S_hdmi_pixel_clk),
        .S_hdmi_rst_n(S_hdmi_rst_n), .S_ycbcr_vsync(S_gaussian_vsync),
        .S_ycbcr_de(S_gaussian_href & S_gaussian_clken),
        .S_quant4_center_d3(S_quant_raw),
        .out_vsync(S_quant_vsync), .out_de(S_quant_de)
    );

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) begin
            S_quant_x<=0;S_quant_y<=0;
        end else begin
            S_quant_x<=S_gaussian_x;S_quant_y<=S_gaussian_y;
        end
    end

    xiaodou u_xiaodou (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .key_in(key), .key_flag(key_out)
    );

    Sobel_Edge_Detector #(
        .IMG_HDISP(11'd1280), .SPARSE_INPUT(1'b0),
        .EDGE_LOW(CARTOON_EDGE_LOW), .EDGE_HIGH(CARTOON_EDGE_HIGH)
    ) u_Sobel_Edge_Detector (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .per_frame_vsync(S_ycbcr_vsync), .per_frame_href(S_ycbcr_de),
        .per_frame_clken(S_ycbcr_de), .per_img_Y(S_img_y),
        .per_x(S_ycbcr_x), .per_y(S_ycbcr_y),
        .post_frame_vsync(S_sobel_vsync), .post_frame_href(S_sobel_href),
        .post_frame_clken(S_sobel_clken),
        .post_img_Bit(S_sobel_strong), .post_img_Weak(S_sobel_weak),
        .post_x(S_sobel_x), .post_y(S_sobel_y), .post_grad()
    );

    cartoon_final_fusion #(
        .IMG_HDISP(1280), .EDGE_GROW(CARTOON_EDGE_GROW),
        .COLOR_BOOST_ENABLE(CARTOON_COLOR_BOOST_ENABLE),
        .WEAK_EDGE_COLOR(CARTOON_WEAK_EDGE_COLOR)
    ) u_cartoon_fusion (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .quant_in(S_quant_raw), .quant_vsync(S_quant_vsync),
        .quant_de(S_quant_de), .quant_x(S_quant_x), .quant_y(S_quant_y),
        .strong_in(S_sobel_strong), .weak_in(S_sobel_weak),
        .edge_vsync(S_sobel_vsync), .edge_href(S_sobel_href),
        .edge_clken(S_sobel_clken), .edge_x(S_sobel_x), .edge_y(S_sobel_y),
        .quant_out(S_quant4_center_out), .boost_out(S_boosted_rgb),
        .sobel_out(S_sobel_rgb), .cartoon_out(S_cartoon_rgb),
        .out_vsync(S_edge_vsync), .out_href(S_edge_href),
        .out_clken(S_edge_clken), .out_x(S_edge_x), .out_y(S_edge_y),
        .strong_out(S_final_strong), .weak_out(S_final_weak)
    );
    assign S_sobel_de = S_edge_href & S_edge_clken;

    // Each preview mode carries its own VS/DE. Only the RGB/Sobel fusion
    // needs common latency, so no full-frame-width RGB delay is synthesized.
    mode_select u_mode_select (
        .key_out(key_out), .clk(S_hdmi_pixel_clk), .rst(S_hdmi_rst_n),
        .S_quant4_center_out(S_quant4_center_out),
        .S_cartoon_rgb(S_cartoon_rgb),
        .S_hdmi_out_data(S_hdmi_out_data),
        .S_img_y(S_img_y), .S_sobel_rgb(S_sobel_rgb),
        .S_ycbcr_vsync(S_ycbcr_vsync),
        .S_ycbcr_de(S_ycbcr_de),
        .S_sobel_de(S_sobel_de), .S_sobel_vsync(S_edge_vsync),
        .S_hdmi_out_vsync(S_hdmi_out_vsync),
        .S_hdmi_out_de(S_hdmi_out_de),
        .mode_select_vsync(mode_select_vsync),
        .mode_select_de(mode_select_de), .data(data)
    );
    */
    // Cross each completed NPU result into the video clock domain and draw the
    // detection over the selected display mode. The source video path remains
    // free-running while the NPU is busy or skips input frames.
    // Board diagnosis: bits left-to-right are META, VIDEO, FRAME, BYTE,
    // WEIGHT_REQ, WEIGHT_DATA, LAYER_DONE, INFERENCE_DONE. Sticky observations
    // do not qualify capture, DDR, inference or source-frame identity.
    reg [1:0] S_npu_debug_video_seen = 2'd0;
    reg [7:2] S_npu_debug_core_seen = 6'd0;
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) S_npu_debug_video_seen <= 2'd0;
        else begin
            if (S_video_frame_metadata_valid) S_npu_debug_video_seen[0] <= 1'b1;
            if (S_hdmi_window_rd_en) S_npu_debug_video_seen[1] <= 1'b1;
        end
    end
    always @(posedge S_npu_clk or negedge S_npu_run_rst_n) begin
        if (!S_npu_run_rst_n) S_npu_debug_core_seen <= 6'd0;
        else begin
            if (S_npu_frame_valid) S_npu_debug_core_seen[2] <= 1'b1;
            if (S_npu_byte_valid) S_npu_debug_core_seen[3] <= 1'b1;
            if (S_npu_weight_req) S_npu_debug_core_seen[4] <= 1'b1;
            if (S_npu_weight_valid) S_npu_debug_core_seen[5] <= 1'b1;
            if (S_npu_layer_done) S_npu_debug_core_seen[6] <= 1'b1;
            if (S_npu_done) S_npu_debug_core_seen[7] <= 1'b1;
        end
    end
    npu_result_overlay #(.ENABLE_BOARD_DEBUG(1)) u_npu_result_overlay (
        .clk_npu(S_npu_clk),
        .rst_n_npu(S_npu_run_rst_n),
        .i_model_ready(S_npu_model_ready && S_npu_params_ready),
        .i_error(S_npu_tile_error || S_npu_ddr_error ||
                 S_param_error || S_u33_boot_error),
        .i_tensor_valid(S_npu_tensor_valid),
        .i_tensor_data(S_npu_tensor_data),
        .i_inference_done(S_npu_done),
        .i_debug_flags({S_npu_debug_core_seen, S_npu_debug_video_seen}),
        .clk_video(S_hdmi_pixel_clk),
        .rst_n_video(S_hdmi_rst_n),
        .i_video_vsync(S_hdmi_out_vsync),
        .i_video_de(S_hdmi_out_de),
        .i_video_data(S_hdmi_out_data),
        .o_video_vsync(S_npu_overlay_vsync),
        .o_video_de(S_npu_overlay_de),
        .o_video_data(S_npu_overlay_data)
    );

    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      (S_npu_overlay_vsync),//( S_hdmi_out_vsync  ),
        .I_video_in_de      (S_npu_overlay_de),//( S_hdmi_out_de     ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    (S_npu_overlay_data),//( S_hdmi_out_data   ),
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


    
    // NPU input integration. Current generated PLL: FIN=50 MHz, CLK0=100 MHz.
    // connect I_sys_clk, never the 100 MHz system-PLL output.
    PLLF6F1D0P0_0 u_npu_pll (
        .refclk(I_sys_clk), .reset(~I_rst_n),
        .clk0_out(S_npu_clk), .lock(S_npu_pll_lock)
    );
    assign S_npu_reset_ready = I_rst_n && S_npu_pll_lock &&
                               S_hdmi_rst_n && S_video_out_rst_n;
    always @(posedge S_npu_clk or negedge S_npu_reset_ready) begin
        if (!S_npu_reset_ready) S_npu_rst_sync <= 2'b00;
        else S_npu_rst_sync <= {S_npu_rst_sync[0], 1'b1};
    end
    assign S_npu_rst_n = S_npu_rst_sync[1];

    // Clean 1280x720 RGB888 from video_out, BEFORE hdmi_mixer's OSD and all
    // display algorithms. npu_video_input aligns DE to the registered RGB.
    // Inference stays independent if B is absent; observed tags enable stereo priority.
    npu_video_input #(.REQUIRE_METADATA(1), .SYNC_ONLY(1), .SYNC_FALLBACK_FRAMES(30))
    u_npu_video_input (
        .clk_video(S_hdmi_pixel_clk), .clk_npu(S_npu_clk),
        .rst_n(S_npu_reset_ready && S_npu_params_ready), .i_vsync(S_hdmi_vsync),
        .i_video_rd_en(S_hdmi_window_rd_en), .i_video_rgb(S_video_rd_data),
        .i_frame_metadata(S_video_frame_metadata),
        .i_frame_metadata_valid(S_video_frame_metadata_valid),
        .o_frame_metadata(S_npu_capture_metadata),
        .i_npu_busy(S_npu_input_busy), .o_frame_valid(S_npu_frame_valid),
        .o_byte_valid(S_npu_byte_valid), .o_byte(S_npu_byte), .o_capture_busy()
    );

    // Same object/fire thresholds as npu_result_overlay.fire_detect. Sampling
    // the complete result here keeps the voice trigger in the NPU clock domain.
    always @(posedge S_npu_clk or negedge S_npu_run_rst_n) begin
        if (!S_npu_run_rst_n) S_voice_fire_detect <= 1'b0;
        else if (S_npu_done)
            S_voice_fire_detect <= S_npu_tensor_valid &&
                                   S_npu_model_ready && S_npu_params_ready &&
                                   !(S_npu_tile_error || S_npu_ddr_error ||
                                     S_param_error || S_u33_boot_error) &&
                                   (S_npu_tensor_data[7:0] >= 8'd144) &&
                                   (S_npu_tensor_data[47:40] >= 8'd128);
    end

    voice_uart_tx #(.CLK_FREQ_HZ(100000000), .BAUD_RATE(9600)) u_voice_uart_tx (
        .clk(S_npu_clk),
        .rst_n(S_npu_run_rst_n),
        .fire_detect(S_voice_fire_detect),
        .uart_tx(ci03t_uart_tx),
        .busy()
    );

    // Associate each admitted NPU input with its native CSI source identity.
    // This register remains owned by that inference until the next admitted input.
    always @(posedge S_npu_clk) begin
        S_npu_frame_valid_d_reg <= S_npu_frame_valid;
        if (S_npu_frame_valid && !S_npu_frame_valid_d_reg && !S_npu_input_busy) begin
            S_npu_inference_source_id_reg <= S_npu_capture_metadata[15:0];
            S_npu_inference_source_valid_reg <= 1'b1;
        end
        if (!S_npu_run_rst_n) begin
            S_npu_frame_valid_d_reg <= 1'b0;
            S_npu_inference_source_id_reg <= 16'd0;
            S_npu_inference_source_valid_reg <= 1'b0;
        end
    end
    // Cross only fully decoded NPU results; multi-bit bbox snapshots are atomic.
    wire [63:0] udp_bbox_input;
    wire [63:0] udp_bbox_cdc_data;
    wire udp_bbox_full, udp_bbox_valid, udp_bbox_empty;
    reg [15:0] udp_bbox_seen_reg = 16'd0;
    reg [63:0] udp_bbox_pixel_reg = 64'd0;
    wire [127:0] udp_video_metadata;
    assign udp_bbox_input = {S_bbox_valid, S_bbox_x1, S_bbox_y1,
        S_bbox_x2, S_bbox_y2, S_bbox_source_valid, S_bbox_source_frame_id, S_bbox_result_id};
    stereo_metadata_fifo #(.DATA_WIDTH(64)) udp_bbox_metadata_fifo_inst (
        .clk_write(S_npu_clk), .rst_write(!S_npu_run_rst_n),
        .clk_read(S_hdmi_pixel_clk), .rst_read(!S_hdmi_rst_n),
        .write_data_i(udp_bbox_input),
        .write_enable_i(S_bbox_result_id != udp_bbox_seen_reg && !udp_bbox_full),
        .write_full_o(udp_bbox_full), .write_almost_full_o(), .write_level_o(),
        .write_overflow_o(), .read_data_o(udp_bbox_cdc_data),
        .read_enable_i(!udp_bbox_empty), .read_valid_o(udp_bbox_valid),
        .read_empty_o(udp_bbox_empty), .read_level_o(), .read_underflow_o()
    );
    always @(posedge S_npu_clk) begin
        if (S_bbox_result_id != udp_bbox_seen_reg && !udp_bbox_full)
            udp_bbox_seen_reg <= S_bbox_result_id;
        if (!S_npu_run_rst_n) udp_bbox_seen_reg <= 16'd0;
    end
    always @(posedge S_hdmi_pixel_clk) begin
        if (udp_bbox_valid) udp_bbox_pixel_reg <= udp_bbox_cdc_data;
        if (!S_hdmi_rst_n) udp_bbox_pixel_reg <= 64'd0;
    end
    assign udp_video_metadata = {
        S_video_frame_metadata[31:16],
        7'd0, udp_bbox_pixel_reg[63], udp_bbox_pixel_reg[62:55],
        1'b0, udp_bbox_pixel_reg[54:48], udp_bbox_pixel_reg[47:40],
        1'b0, udp_bbox_pixel_reg[39:33],
        6'd0, udp_bbox_pixel_reg[32], S_video_frame_metadata[32],
        S_video_frame_metadata[15:0], udp_bbox_pixel_reg[31:16],
        udp_bbox_pixel_reg[15:0], 16'd0
    };

    npu_network_top #(.PARAM_ADDR_W(21)) u_npu (
        .clk(S_npu_clk), .rst_n(S_npu_run_rst_n),
        .i_frame_valid(S_npu_frame_valid), .i_byte_valid(S_npu_byte_valid),
        .i_byte(S_npu_byte), .o_input_busy(S_npu_input_busy),
        .o_model_ready(S_npu_model_ready), .o_tile_ready(S_npu_tile_ready),
        .o_tile_done(S_npu_tile_done), .o_tile_error(S_npu_tile_error),
        .o_layer_done(S_npu_layer_done), .o_inference_done(S_npu_done),
        .o_tensor_valid(S_npu_tensor_valid), .o_tensor_data(S_npu_tensor_data),
        .o_tensor_x(S_npu_tensor_x), .o_tensor_y(S_npu_tensor_y),
        .o_sdram_rd_req_valid(S_npu_weight_req), .o_sdram_rd_addr(S_npu_weight_addr),
        .o_sdram_rd_len_halfwords(S_npu_weight_len),
        .i_sdram_rd_req_ready(S_npu_weight_ready),
        .i_sdram_rd_data(S_npu_weight_data), .i_sdram_rd_valid(S_npu_weight_valid)
    );

    // Preserve the clean A-camera field of view; infer at 160x120 independently.
    ethernet_video_sampler #(.CLOCK_HZ(75000000), .FRAME_RATE(30)) u_udp_video_input (
        .clk(S_hdmi_pixel_clk), .rst(!S_hdmi_rst_n),
        .vsync_i(S_hdmi_vsync), .read_enable_i(S_hdmi_window_rd_en),
        .rgb_i(S_video_rd_data), .metadata_valid_i(S_video_frame_metadata_valid),
        .metadata_i(udp_video_metadata),
        .frame_start_o(S_udp_frame_start_raw), .pixel_valid_o(S_udp_pixel_valid_raw),
        .pixel_rgb_o(S_udp_pixel_rgb_raw), .frame_end_o(S_udp_frame_end_raw),
        .frame_abort_o(S_udp_frame_abort_raw), .frame_metadata_o(S_udp_frame_metadata)
    );

    npu_bbox_overlay_160x120 u_npu_bbox_overlay_160x120 (
        .clk              (S_npu_clk),
        .rst              (~S_npu_run_rst_n),
        .tensor_valid_i   (S_npu_tensor_valid),
        .tensor_data_i    (S_npu_tensor_data),
        .inference_done_i (S_npu_done && S_npu_inference_source_valid_reg &&
            !(S_npu_tile_error || S_npu_ddr_error || S_param_error || S_u33_boot_error)),
        .source_frame_id_i (S_npu_inference_source_id_reg),
        .bbox_valid_o (S_bbox_valid),
        .bbox_x1_o (S_bbox_x1), .bbox_y1_o (S_bbox_y1),
        .bbox_x2_o (S_bbox_x2), .bbox_y2_o (S_bbox_y2),
        .bbox_source_valid_o (S_bbox_source_valid),
        .bbox_source_frame_id_o (S_bbox_source_frame_id),
        .bbox_result_id_o (S_bbox_result_id),
        .frame_start_i    (1'b0),
        .pixel_valid_i    (1'b0),
        .pixel_rgb_i      (24'd0),
        .frame_end_i      (1'b0),
        .frame_abort_i    (1'b0),
        .frame_start_o    (),
        .pixel_valid_o    (),
        .pixel_rgb_o      (),
        .frame_end_o      (),
        .frame_abort_o    ()
    );

    ethernet_video_tx_top u_ethernet_video_tx_top (
        .frame_metadata_i           (S_udp_frame_metadata),
        .clk_reference              (I_sys_clk),
        .rst_reference              (~I_rst_n),
        .clk_pixel                  (S_hdmi_pixel_clk),
        .rst_pixel                  (~S_hdmi_rst_n),
        .frame_start_i              (S_udp_frame_start_raw),
        .pixel_valid_i              (S_udp_pixel_valid_raw),
        .pixel_rgb_i                (S_udp_pixel_rgb_raw),
        .frame_end_i                (S_udp_frame_end_raw),
        .frame_abort_i              (S_udp_frame_abort_raw),
        .rgmii_rxd_i                (I_a_rgmii_rxd),
        .rgmii_rx_control_i         (I_a_rgmii_rx_ctl),
        .rgmii_rx_clock_i           (I_a_rgmii_rxc),
        .rgmii_txd_o                (O_a_rgmii_txd),
        .rgmii_tx_control_o         (O_a_rgmii_tx_ctl),
        .rgmii_tx_clock_o           (O_a_rgmii_txc),
        .phy_reset_no               (O_phy_rst),
        .video_fifo_overflow_o      (S_udp_fifo_overflow),
        .video_fifo_underflow_o     (S_udp_fifo_underflow),
        .video_frame_drop_o         (S_udp_frame_drop),
        .completed_frame_id_o       (S_udp_completed_frame_id),
        .completed_frame_count_o    (S_udp_completed_frame_count)
    );

endmodule
