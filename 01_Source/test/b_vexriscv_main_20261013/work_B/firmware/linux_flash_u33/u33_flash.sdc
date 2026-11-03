# Hard MCU IP matches the A-board 100 MHz AHB configuration.
# Only the new Flash bridge crossing is bounded here; video/DDR clocks are unchanged.
create_clock -name {linux_flash_ahb} -period 10.000 [get_pins {u_linux_flash_mcu/ahb_clk}]
set_max_delay -datapath_only 10.000 -from [get_clocks {sys_clk_50m}] -to [get_clocks {linux_flash_ahb}]
set_max_delay -datapath_only 10.000 -from [get_clocks {linux_flash_ahb}] -to [get_clocks {sys_clk_50m}]
