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
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# Keep the pre-existing video/PLL-domain exceptions. CPU<->DDR is instead
# bounded below so a clock-group false path cannot hide mailbox payload timing.
set_clock_groups -asynchronous \
    -group [get_clocks {pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# Existing CPU<->DDR-domain crossings were wholly ignored before this change.
# A loose data-only bound preserves their asynchronous-clock treatment; the
# actual held mailbox data has a tighter bound than either sampling period.
set_max_delay -datapath_only 100.000 \
    -from [get_clocks {sys_clk_50m}] \
    -to [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]
set_max_delay -datapath_only 100.000 \
    -from [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] \
    -to [get_clocks {sys_clk_50m}]
set_max_delay -datapath_only 10.000 \
    -from [get_regs -hier {*request_hold_reg*}] \
    -to [get_regs -hier {*u_cpu_ddr_word_service*request_payload_reg*}]
# Cache-hit data/address/lane also feed the held response before request recapture.
set_max_delay -datapath_only 10.000 \
    -from [get_regs -hier {*request_hold_reg*}] \
    -to [get_regs -hier {*u_cpu_ddr_word_service*word_response_payload_reg*}]
# Four-phase held bundles: receiver captures the request once, and the
# DDR word service holds all 32 data bits AND error until the next request.
# Native 128-bit line selection is local to DDR; no unbounded payload crossing.
set_max_delay -datapath_only 10.000 \
    -from [get_regs -hier {*u_cpu_ddr_word_service*word_response_payload_reg*}] \
    -to [get_regs -hier {*cpu_ddr_enabled$bridge_inst*}]

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

# VexRiscv B main integration: u_vexriscv_linux uses I_sys_clk directly.
# It is covered by existing sys_clk_50m (20 ns); no duplicate/generated clock.
# CPU local memory, IRQs and reset synchronizer run in this same domain.
# The NEW DDR mailbox alone crosses to the existing DDR user clock.
