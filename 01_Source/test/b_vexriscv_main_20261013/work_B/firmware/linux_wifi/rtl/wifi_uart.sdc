# Except only the external asynchronous input to the first synchronizer stage.
set wifi_rx_meta [get_regs -hier {u_vexriscv_linux/wifi_uart_wb_inst/uart_rx_inst/rx_sync_reg[0]}]
if {[llength $wifi_rx_meta] != 1} {error "Wi-Fi UART RX first-stage endpoint must resolve exactly once"}
set_false_path -from [get_ports {I_wifi_uart_rx}] -to $wifi_rx_meta
puts "WIFI_UART_RX_FIRST_STAGE_ONLY $wifi_rx_meta"
