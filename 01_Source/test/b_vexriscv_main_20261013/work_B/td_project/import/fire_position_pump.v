// -----------------------------------------------------------------------------
// File   : fire_position_pump.v
// Author : Codex
// Date   : 2026-10-07
// -----------------------------------------------------------------------------
// Description:
//   Permit spray when a fixed-camera servo command has settled and fire remains valid.
//   Immediately remove pump permission on reset, lost fire or renewed motion.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-07  Codex  v1.0  Position-based spray permission
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module fire_position_pump
(
    input  wire rst,
    input  wire fire_valid_i,
    input  wire position_ready_i,
    input  wire distance_allowed_i,
    output wire pump_enable_o
);
    // The ready signal already includes a legal X, target arrival, settling
    // time and a same-cycle gate for a fresh detection changing the target.
    assign pump_enable_o = !rst && fire_valid_i && position_ready_i &&
        distance_allowed_i;
endmodule
`resetall
