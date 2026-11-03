// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// -----------------------------------------------------------------------------
// File   : ethernet_video_rx_top.v
// Author : OpenAI Codex
// Date   : 2026-09-20
// -----------------------------------------------------------------------------
// Description:
//   RGMII/UDP receive counterpart of ethernet_video_tx_top.  The default
//   network parameters are the peer of the existing transmitter:
//     TX FPGA 192.168.137.2:6002 -> RX FPGA 192.168.137.1:6001
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module ethernet_video_rx_top #
(
    parameter [47:0] LOCAL_MAC_ADDR = 48'h01_23_45_67_89_ac,
    parameter [31:0] LOCAL_IP_ADDR = 32'hc0a8_8901,
    parameter [15:0] LOCAL_UDP_PORT = 16'd6001,
    parameter [31:0] REMOTE_IP_ADDR = 32'hc0a8_8902,
    parameter [15:0] REMOTE_UDP_PORT = 16'd6002,
    parameter FIFO_ADDR_WIDTH = 12
)
(
    input  wire        clk_reference,
    input  wire        rst_reference,
    input  wire        clk_pixel,
    input  wire        rst_pixel,

    input  wire [3:0]  rgmii_rxd_i,
    input  wire        rgmii_rx_control_i,
    input  wire        rgmii_rx_clock_i,
    output wire [3:0]  rgmii_txd_o,
    output wire        rgmii_tx_control_o,
    output wire        rgmii_tx_clock_o,
    output wire        phy_reset_no,

    output wire        frame_start_o,
    output wire        pixel_valid_o,
    output wire [23:0] pixel_rgb_o,
    output wire        frame_end_o,
    output wire        frame_abort_o,
    output wire [15:0] frame_id_o,
    output wire [15:0] sync_id_o,
    output wire        sync_valid_o,
    output wire [15:0] source_frame_id_o,
    output wire        bbox_valid_o,
    output wire [7:0]  bbox_x1_o,
    output wire [6:0]  bbox_y1_o,
    output wire [7:0]  bbox_x2_o,
    output wire [6:0]  bbox_y2_o,
    output wire        bbox_source_valid_o,
    output wire [15:0] bbox_source_frame_id_o,
    output wire [15:0] bbox_result_id_o,
    output wire        video_fifo_overflow_o,
    output wire        video_fifo_underflow_o,
    output wire        udp_packet_error_o,
    output wire        video_frame_drop_o,
    output wire [15:0] completed_frame_id_o,
    output wire [15:0] completed_frame_count_o,
    output wire        ip_rx_error_o,
    output wire        mac_rx_error_o
);

    wire       clk_25;
    wire       clk_125;
    wire       pll_locked;
    wire       phy_reset_n;
    wire       stack_reset;
    reg [1:0]  udp_reset_sync_reg = 2'b11;
    wire       udp_reset;

    wire [7:0] gmii_tx_data;
    wire       gmii_tx_valid;
    wire       gmii_rx_clock;
    wire [7:0] gmii_rx_data;
    wire       gmii_rx_valid;
    wire       udp_rx_valid;
    wire [7:0] udp_rx_data;
    wire [15:0] udp_rx_length;
    wire [15:0] udp_rx_src_port;

    assign phy_reset_no = phy_reset_n;
    assign stack_reset = ~phy_reset_n;
    assign udp_reset = udp_reset_sync_reg[1];

    eth_pll eth_pll_inst (
        .refclk   (clk_reference),
        .reset    (rst_reference),
        .clk0_out (clk_125),
        .clk1_out (),
        .clk2_out (clk_25),
        .lock     (pll_locked)
    );

    eth_phy_reset #(
        .CLK_FREQ (32'd25_000_000)
    ) eth_phy_reset_inst (
        .I_CLK    (clk_25),
        .I_rstn   (pll_locked),
        .I_phyrst (pll_locked),
        .O_phyrst (phy_reset_n)
    );

    always @(posedge clk_125) begin
        udp_reset_sync_reg <= {udp_reset_sync_reg[0], 1'b0};
        if (stack_reset) begin
            udp_reset_sync_reg <= 2'b11;
        end
    end

    video_udp_rx #(
        .FIFO_ADDR_WIDTH      (FIFO_ADDR_WIDTH),
        .EXPECTED_SOURCE_PORT (REMOTE_UDP_PORT)
    ) video_udp_rx_inst (
        .clk_udp                  (clk_125),
        .rst_udp                  (udp_reset),
        .udp_rx_valid_i           (udp_rx_valid),
        .udp_rx_data_i            (udp_rx_data),
        .udp_rx_length_i          (udp_rx_length),
        .udp_rx_src_port_i        (udp_rx_src_port),
        .clk_pixel                (clk_pixel),
        .rst_pixel                (rst_pixel),
        .frame_start_o            (frame_start_o),
        .pixel_valid_o            (pixel_valid_o),
        .pixel_rgb_o              (pixel_rgb_o),
        .frame_end_o              (frame_end_o),
        .frame_abort_o            (frame_abort_o),
        .frame_id_o (frame_id_o),
        .sync_id_o (sync_id_o),
        .sync_valid_o (sync_valid_o),
        .source_frame_id_o (source_frame_id_o),
        .bbox_valid_o (bbox_valid_o),
        .bbox_x1_o (bbox_x1_o),
        .bbox_y1_o (bbox_y1_o),
        .bbox_x2_o (bbox_x2_o),
        .bbox_y2_o (bbox_y2_o),
        .bbox_source_valid_o (bbox_source_valid_o),
        .bbox_source_frame_id_o (bbox_source_frame_id_o),
        .bbox_result_id_o (bbox_result_id_o),
        .fifo_overflow_o          (video_fifo_overflow_o),
        .fifo_underflow_o         (video_fifo_underflow_o),
        .packet_error_o           (udp_packet_error_o),
        .frame_drop_o             (video_frame_drop_o),
        .completed_frame_id_o     (completed_frame_id_o),
        .completed_frame_count_o  (completed_frame_count_o)
    );

    uiudp_stack #(
        .CRC_GEN_EN      (1'b1),
        .INTER_FRAME_GAP (4'd12)
    ) uiudp_stack_inst (
        .I_uclk            (clk_125),
        .I_reset           (stack_reset),
        .I_mac_local_addr  (LOCAL_MAC_ADDR),
        .I_udp_local_port  (LOCAL_UDP_PORT),
        .I_ip_local_addr   (LOCAL_IP_ADDR),
        .I_udp_dest_port   (REMOTE_UDP_PORT),
        .I_ip_dest_addr    (REMOTE_IP_ADDR),
        .O_W_udp_busy      (),
        .I_W_udp_req       (1'b0),
        .I_W_udp_valid     (1'b0),
        .I_W_udp_data      (8'd0),
        .I_W_udp_len       (16'd0),
        .O_R_udp_valid     (udp_rx_valid),
        .O_R_udp_data      (udp_rx_data),
        .O_R_udp_len       (udp_rx_length),
        .O_R_udp_src_port  (udp_rx_src_port),
        .I_gmii_rclk       (gmii_rx_clock),
        .I_gmii_rvalid     (gmii_rx_valid),
        .I_gmii_rdata      (gmii_rx_data),
        .I_gmii_tclk       (clk_125),
        .O_gmii_tvalid     (gmii_tx_valid),
        .O_gmii_tdata      (gmii_tx_data),
        .O_ip_rerror       (ip_rx_error_o),
        .O_mac_rerror      (mac_rx_error_o)
    );

    rgmii_interface rgmii_interface_inst (
        .speed_10_100   (1'b0),
        .gmii_tx_clk_d  (clk_125),
        .gmii_tx_reset_d(stack_reset),
        .gmii_tx_reset  (stack_reset),
        .gmii_tx_clk    (clk_125),
        .gmii_txd       (gmii_tx_data),
        .gmii_tx_en     (gmii_tx_valid),
        .gmii_tx_er     (1'b0),
        .gmii_rx_reset  (stack_reset),
        .gmii_rx_clk    (gmii_rx_clock),
        .gmii_rxd       (gmii_rx_data),
        .gmii_rx_dv     (gmii_rx_valid),
        .gmii_rx_er     (),
        .rgmii_txd      (rgmii_txd_o),
        .rgmii_tx_ctl   (rgmii_tx_control_o),
        .rgmii_txc      (rgmii_tx_clock_o),
        .rgmii_rxd      (rgmii_rxd_i),
        .rgmii_rx_ctl   (rgmii_rx_control_i),
        .rgmii_rxc      (rgmii_rx_clock_i),
        .gmii_crs       (),
        .gmii_col       (),
        .link_status    (),
        .clock_speed    (),
        .duplex_status  ()
    );

endmodule

`resetall

