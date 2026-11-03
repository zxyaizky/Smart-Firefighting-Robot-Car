# TD re-evaluates the text of each exception after mapping. Keep every exception
# query literal: loop variables and stored collections do not survive that step.
# Variables below validate the queries only; they are never exception arguments.
foreach endpoint {{request_sync[0]} {ack_sync[0]} {valid_sync[0]} {reset_pixel_sync[0]} {snapshot_request_sync[0]} {snapshot_ack_sync[0]}} {
    if {[llength [get_regs -hier -nowarn u_lidar_map/$endpoint]] != 1} {
        error "Lidar CDC endpoint missing: $endpoint"
    }
}
foreach {name expected} {
    robot_reg 16 robot_display_reg 16 heading_reg 16 heading_display_reg 16
    enable_hold_reg 1 display_enable_reg 1
    label_position_reg 64 label_display_reg 64 label_refresh_reg 4
    label_refresh_age_reg 32 label_ttl_reg 32
    detection_hold_reg 208 response_data_reg 32
} {
    if {$expected == 1} {set pattern u_lidar_map/$name} else {
        set pattern [format {u_lidar_map/%s[*]} $name]
    }
    if {[llength [get_regs -hier -nowarn $pattern]] != $expected} {
        error "Lidar mailbox register count changed: $name (expected $expected)"
    }
}
# Only the asynchronous first stages are exempt; stage 2 stays timed.
set_false_path -to [get_regs -hier -nowarn {u_lidar_map/request_sync[0]}]
set_false_path -to [get_regs -hier -nowarn {u_lidar_map/ack_sync[0]}]
set_false_path -to [get_regs -hier -nowarn {u_lidar_map/valid_sync[0]}]
set_false_path -to [get_regs -hier -nowarn {u_lidar_map/reset_pixel_sync[0]}]
set_false_path -to [get_regs -hier -nowarn {u_lidar_map/snapshot_request_sync[0]}]
set_false_path -to [get_regs -hier -nowarn {u_lidar_map/snapshot_ack_sync[0]}]
# These bundles stay frozen across request/ack. Bound all mapped arcs of each
# bundle, including shared LUT inputs after packing, to the same 10 ns limit.
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/robot_reg[*]}] -to [get_regs -hier -nowarn {u_lidar_map/robot_display_reg[*]}]
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/heading_reg[*]}] -to [get_regs -hier -nowarn {u_lidar_map/heading_display_reg[*]}]
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/enable_hold_reg}] -to [get_regs -hier -nowarn {u_lidar_map/display_enable_reg}]
puts "LIDAR_CDC_CONSTRAINTS_APPLIED"
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/label_position_reg[*]}] -to [get_regs -hier -nowarn {u_lidar_map/label_display_reg[*]}]
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/label_refresh_reg[*]}] -to [get_regs -hier -nowarn {u_lidar_map/label_ttl_reg[*]}]
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/label_refresh_age_reg[*]}] -to [get_regs -hier -nowarn {u_lidar_map/label_ttl_reg[*]}]
# The reverse mailbox holds all detection data until the next CPU request.
set_max_delay -datapath_only 10.000 -from [get_regs -hier -nowarn {u_lidar_map/detection_hold_reg[*]}] -to [get_regs -hier -nowarn {u_lidar_map/response_data_reg[*]}]
puts "LIDAR_SEMANTIC_CDC_CONSTRAINTS_APPLIED"
