# Only the new MCU/Flash mailbox is constrained here; existing video SDC is intact.
# MCU ahb_clk is a real top-level net; the old u_linux_flash_mcu/ahb_clk pin
# selector does not resolve in this TD elaborated hierarchy.
set flash_ahb_net [get_nets {S_mcu_ahb_clk}]
if {[llength $flash_ahb_net] != 1} {error "Missing MCU AHB clock net"}
create_clock -name {linux_flash_ahb} -period 10.000 $flash_ahb_net

set flash_request_toggle [get_regs -hier {*flash_bridge_inst*request_toggle_reg}]
set flash_request_meta [get_regs -hier {*flash_bridge_inst*request_sync[0]}]
set flash_response_toggle [get_regs -hier {*flash_bridge_inst*response_toggle_reg}]
set flash_response_meta [get_regs -hier {*flash_bridge_inst*response_sync[0]}]
foreach endpoints [list $flash_request_toggle $flash_request_meta $flash_response_toggle $flash_response_meta] {
    if {[llength $endpoints] != 1} {error "Flash toggle CDC endpoint must resolve exactly once"}
}
# Keep queries inline: TD re-resolves stored exceptions after each mapping stage.
set_false_path -from [get_regs -hier {*flash_bridge_inst*request_toggle_reg}] -to [get_regs -hier {*flash_bridge_inst*request_sync[0]}]
set_false_path -from [get_regs -hier {*flash_bridge_inst*response_toggle_reg}] -to [get_regs -hier {*flash_bridge_inst*response_sync[0]}]

# TD's SDC evaluator does not execute the former for/format collection loop.
# Match vector bits directly; constant address bits may disappear in synthesis.
# The handshake holds each bus until its synchronized toggle is observed.
# Keep the original 20 ns datapath limit (TD excludes async hold for this limit).
set flash_address_sources [get_regs -hier {*flash_bridge_inst*request_address_reg[*]}]
set flash_data_sources [get_regs -hier {*flash_bridge_inst*response_data_reg[*]}]
set flash_data_targets [get_regs -hier {*flash_bridge_inst*result_reg[*]}]
foreach endpoints [list $flash_address_sources $flash_data_sources $flash_data_targets] {
    if {[llength $endpoints] == 0} {error "Missing Flash bundled-data registers"}
}
set_max_delay -datapath_only 20.000 -from [get_regs -hier {*flash_bridge_inst*request_address_reg[*]}] -to [get_clocks {linux_flash_ahb}]
set_max_delay -datapath_only 20.000 -from [get_regs -hier {*flash_bridge_inst*response_data_reg[*]}] -to [get_regs -hier {*flash_bridge_inst*result_reg[*]}]
set flash_error_source [get_regs -hier {*flash_bridge_inst*response_error_reg}]
set flash_error_target [get_regs -hier {*flash_bridge_inst*result_error_reg}]
if {[llength $flash_error_source] != 1 || [llength $flash_error_target] != 1} {error "Missing Flash response-error endpoints"}
set_max_delay -datapath_only 20.000 -from [get_regs -hier {*flash_bridge_inst*response_error_reg}] -to [get_regs -hier {*flash_bridge_inst*result_error_reg}]
puts "WIFI_FLASH_CDC_ENDPOINTS_PASS address=[llength $flash_address_sources] response=[llength $flash_data_sources] target=[llength $flash_data_targets]"
