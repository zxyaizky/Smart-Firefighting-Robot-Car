create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 4.167 -waveform {0.000 2.083} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# AE control is intentionally resynchronized after crossing into the HDMI
# pixel domain. The first stage is asynchronous; later HDMI stages stay timed.
set_false_path -from [get_clocks {pll_clk_24m}] \
               -to [get_clocks {HDMI_PIXEL_CLK}]

# Processed VSYNC is sampled by a two-flop synchronizer in the 50 MHz
# domain. Only the asynchronous first-stage register is exempted; the
# second synchronizer stage and all downstream logic remain fully timed.
set_false_path -from [get_clocks {HDMI_PIXEL_CLK}] \
               -to [get_regs -nowarn {u_video_out/S_processed_vsync_meta}]

# MAX30102 mailbox acknowledgments return from the HDMI pixel domain.
# Request/quality and held BCD paths use the existing 24m -> pixel exception.
# Only the first acknowledgment stage is asynchronous; stage 2 stays timed.
set_false_path -from [get_clocks {HDMI_PIXEL_CLK}] \
               -to [get_regs -nowarn {u_max30102_osd_cdc/hr_ack_sync_reg[0]}]
set_false_path -from [get_clocks {HDMI_PIXEL_CLK}] \
               -to [get_regs -nowarn {u_max30102_osd_cdc/spo2_ack_sync_reg[0]}]
