create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 4.167 -waveform {0.000 2.083} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]
rename_clock -name {NPU_CLK_100M} [get_clocks {u_npu_pll/ph1p_phy_pll_wrapper_0caf81c79f74_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {ETH_CLK_125M} [get_clocks {u_ethernet_video_tx_top/eth_pll_inst/ph1p_phy_pll_wrapper_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {ETH_CLK_25M} [get_clocks {u_ethernet_video_tx_top/eth_pll_inst/ph1p_phy_pll_wrapper_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[2]}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m HDMI_PIXEL_CLK}] \
    -group [get_clocks {pll_clk_24m}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/ctl_clk u_ph1p35_324_ddr_wrapper/u_ddr2/ref_clk u_ph1p35_324_ddr_wrapper/u_ddr2/mcu_clk}] \
    -group [get_clocks {NPU_CLK_100M}] \
    -group [get_clocks {ETH_CLK_125M ETH_CLK_25M}]

# Only the asynchronous GPIO-to-first-flop path is exempted.
set_false_path -from [get_ports {stereo_sync_i}] \
    -to [get_regs -nowarn {u_stereo_sync_rx/input_sync_reg[0]}]
