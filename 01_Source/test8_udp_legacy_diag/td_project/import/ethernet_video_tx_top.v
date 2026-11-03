// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// -----------------------------------------------------------------------------
// File   : ethernet_video_tx_top.v
// Author : OpenAI Codex
// Date   : 2026-09-20
// -----------------------------------------------------------------------------
// Description:
//   Integrate the verified Ethernet PLL, PHY reset, RGMII interface and UDP/IP
//   stack with video_udp_tx. Ethernet remains a transmit-only video side path.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-20  OpenAI Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module ethernet_video_tx_top
(
    input  wire        clk_reference,
    input  wire        rst_reference,
    input  wire        clk_pixel,
    input  wire        rst_pixel,
    input  wire        frame_start_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] pixel_rgb_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    input  wire [127:0] frame_metadata_i,
    input  wire [3:0]  rgmii_rxd_i,
    input  wire        rgmii_rx_control_i,
    input  wire        rgmii_rx_clock_i,
    output wire [3:0]  rgmii_txd_o,
    output wire        rgmii_tx_control_o,
    output wire        rgmii_tx_clock_o,
    output wire        phy_reset_no,
    output wire        video_fifo_overflow_o,
    output wire        video_fifo_underflow_o,
    output wire        video_frame_drop_o,
    output wire [15:0] completed_frame_id_o,
    output wire [15:0] completed_frame_count_o
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
    wire       udp_tx_busy;
    wire       udp_tx_request;
    wire       udp_tx_valid;
    wire [7:0] udp_tx_data;
    wire [15:0] udp_tx_length;

    assign phy_reset_no = phy_reset_n;
    assign stack_reset  = ~phy_reset_n;
    assign udp_reset    = udp_reset_sync_reg[1];

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
    )
    eth_phy_reset_inst (
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

    video_udp_tx #(
        .FIFO_ADDR_WIDTH (12)
    )
    video_udp_tx_inst (
        .clk_pixel                (clk_pixel),
        .rst_pixel                (rst_pixel),
        .clk_udp                  (clk_125),
        .rst_udp                  (udp_reset),
        .frame_start_i            (frame_start_i),
        .pixel_valid_i            (pixel_valid_i),
        .pixel_rgb_i              (pixel_rgb_i),
        .frame_end_i              (frame_end_i),
        .frame_abort_i            (frame_abort_i),
        .frame_metadata_i         (frame_metadata_i),
        .udp_tx_req_o             (udp_tx_request),
        .udp_tx_valid_o           (udp_tx_valid),
        .udp_tx_data_o            (udp_tx_data),
        .udp_tx_length_o          (udp_tx_length),
        .udp_tx_busy_i            (udp_tx_busy),
        .fifo_overflow_o          (video_fifo_overflow_o),
        .fifo_underflow_o         (video_fifo_underflow_o),
        .frame_drop_o             (video_frame_drop_o),
        .completed_frame_id_o     (completed_frame_id_o),
        .completed_frame_count_o  (completed_frame_count_o)
    );

    uiudp_stack #(
        .CRC_GEN_EN      (1'b1),
        .INTER_FRAME_GAP (4'd12)
    )
    uiudp_stack_inst (
        .I_uclk            (clk_125),
        .I_reset           (stack_reset),
        .I_mac_local_addr  (48'h01_23_45_67_89_ab),
        .I_udp_local_port  (16'd6002),
        .I_ip_local_addr   (32'hc0a8_8902),
        .I_udp_dest_port   (16'd6001),
        .I_ip_dest_addr    (32'hc0a8_8901),
        .O_W_udp_busy      (udp_tx_busy),
        .I_W_udp_req       (udp_tx_request),
        .I_W_udp_valid     (udp_tx_valid),
        .I_W_udp_data      (udp_tx_data),
        .I_W_udp_len       (udp_tx_length),
        .O_R_udp_valid     (),
        .O_R_udp_data      (),
        .O_R_udp_len       (),
        .O_R_udp_src_port  (),
        .I_gmii_rclk       (gmii_rx_clock),
        .I_gmii_rvalid     (gmii_rx_valid),
        .I_gmii_rdata      (gmii_rx_data),
        .I_gmii_tclk       (clk_125),
        .O_gmii_tvalid     (gmii_tx_valid),
        .O_gmii_tdata      (gmii_tx_data),
        .O_ip_rerror       (),
        .O_mac_rerror      ()
    );

    rgmii_interface rgmii_interface_inst (
        .speed_10_100  (1'b0),
        .gmii_tx_clk_d (clk_125),
        .gmii_tx_reset_d(stack_reset),
        .gmii_tx_reset (stack_reset),
        .gmii_tx_clk   (clk_125),
        .gmii_txd      (gmii_tx_data),
        .gmii_tx_en    (gmii_tx_valid),
        .gmii_tx_er    (1'b0),
        .gmii_rx_reset (stack_reset),
        .gmii_rx_clk   (gmii_rx_clock),
        .gmii_rxd      (gmii_rx_data),
        .gmii_rx_dv    (gmii_rx_valid),
        .gmii_rx_er    (),
        .rgmii_txd     (rgmii_txd_o),
        .rgmii_tx_ctl  (rgmii_tx_control_o),
        .rgmii_txc     (rgmii_tx_clock_o),
        .rgmii_rxd     (rgmii_rxd_i),
        .rgmii_rx_ctl  (rgmii_rx_control_i),
        .rgmii_rxc     (rgmii_rx_clock_i),
        .gmii_crs      (),
        .gmii_col      (),
        .link_status   (),
        .clock_speed   (),
        .duplex_status ()
    );

endmodule

`resetall
