// -----------------------------------------------------------------------------
// File   : fire_position_pump.v
// Author : Codex
// Date   : 2026-10-07
// -----------------------------------------------------------------------------
// Description:
//   Qualify fresh fire results after a fixed-camera servo command has settled.
//   Immediately remove pump permission on reset, lost fire or renewed motion.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-07  Codex  v1.0  Position-based spray permission
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module fire_position_pump #
(
    // Number of distinct valid detections after the servo command has settled.
    parameter integer STABLE_SAMPLES = 3
)
(
    input  wire clk,
    input  wire rst,
    input  wire fire_sample_i,
    input  wire fire_valid_i,
    input  wire position_ready_i,
    input  wire distance_allowed_i,
    output wire pump_enable_o
);
    localparam integer COUNT_WIDTH = STABLE_SAMPLES > 1 ? $clog2(STABLE_SAMPLES + 1) : 1;
    localparam [COUNT_WIDTH-1:0] COUNT_LIMIT = STABLE_SAMPLES;

    reg [COUNT_WIDTH-1:0] stable_count_reg = {COUNT_WIDTH{1'b0}}, stable_count_next;

    // The ready signal already includes a legal X, target arrival, settling
    // time and a same-cycle gate for a fresh detection changing the target.
    assign pump_enable_o = !rst && fire_valid_i && position_ready_i &&
        distance_allowed_i && stable_count_reg == COUNT_LIMIT;

    always @* begin
        stable_count_next = stable_count_reg;
        if (!fire_valid_i || !position_ready_i) begin
            stable_count_next = {COUNT_WIDTH{1'b0}};
        end else if (fire_sample_i && stable_count_reg < COUNT_LIMIT) begin
            stable_count_next = stable_count_reg + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
        end
    end

    always @(posedge clk) begin
        stable_count_reg <= stable_count_next;
        if (rst) stable_count_reg <= {COUNT_WIDTH{1'b0}};
    end

    // synthesis translate_off
    initial begin
        if (STABLE_SAMPLES < 1) begin
            $error("Invalid fire_position_pump STABLE_SAMPLES");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`resetall
