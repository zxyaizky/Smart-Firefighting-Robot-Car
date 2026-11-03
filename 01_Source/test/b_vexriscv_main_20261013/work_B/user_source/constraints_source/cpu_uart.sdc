# Only the asynchronous UART pin to the first synchronizer stage is excepted.
set cpu_uart_rx_meta [get_regs -hier {u_vexriscv_linux/memory_inst/cpu_uart_enabled$uart_inst/uart_rx_inst/rx_sync_reg[0]}]
if {[llength $cpu_uart_rx_meta] != 1} {error "CPU UART RX first-stage endpoint must resolve exactly once"}
set_false_path -from [get_ports {I_cpu_uart_rx}] -to $cpu_uart_rx_meta
puts "CPU_UART_RX_FIRST_STAGE_ONLY $cpu_uart_rx_meta"
