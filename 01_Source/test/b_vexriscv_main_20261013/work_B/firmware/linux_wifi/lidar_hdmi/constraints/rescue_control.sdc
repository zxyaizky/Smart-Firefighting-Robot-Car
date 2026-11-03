# Only asynchronous first stages are exempt. Synchronizer stage 2 stays timed.
set_false_path -to [get_regs -hier -nowarn {u_rescue_sensors/u_mailbox/request_sync_reg[0]}]
set_false_path -to [get_regs -hier -nowarn {u_rescue_sensors/u_mailbox/acknowledge_sync_reg[0]}]
set_false_path -to [get_regs -hier -nowarn {S_rescue_fire_allow_sync[0]}]
set_false_path -to [get_regs -hier -nowarn {u_rescue_control/u_car_auto/switch_sync1}]
set_false_path -to [get_regs -hier -nowarn {u_arm_buttons/sync_1[0]}]
set_false_path -to [get_regs -hier -nowarn {u_arm_buttons/sync_1[1]}]
# The payload remains stable until the return acknowledgment. Bound the bundle.
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_rescue_sensors/u_mailbox/held_reg[*]}] -to [get_regs -hier -nowarn {u_rescue_sensors/u_mailbox/data_reg[*]}]
puts "B_RESCUE_CDC_CONSTRAINTS_APPLIED"
