// -----------------------------------------------------------------------------
// File   : vexriscv_b_reset.v
// Author : Codex
// Date   : 2026-10-16
// Description: CPU-only power-on reset; qualify the existing PLL lock.
// Change Log: 2026-10-16 v1.0 Synchronize inputs, then hold reset 1024 clocks.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module vexriscv_b_reset #
(
    // Consecutive qualified CPU clocks before releasing synchronous CPU reset.
    parameter integer HOLD_CYCLES = 1024
)
(
    input  wire clk,
    input  wire rst,
    input  wire clock_locked_i,
    output wire ready_o,
    output wire cpu_reset_o
);
    localparam integer COUNT_WIDTH = HOLD_CYCLES > 0 ? $clog2(HOLD_CYCLES + 1) : 1;
    localparam [COUNT_WIDTH-1:0] HOLD_COUNT = HOLD_CYCLES;

    // TD SWUG106 section 5.3.3 supports declaration DFF initialization.
    // These INIT values hold CPU reset even when the board button starts high.
    reg [1:0] reset_sync_reg = 2'b11;
    reg [1:0] locked_sync_reg = 2'b00;
    reg [COUNT_WIDTH-1:0] hold_count_reg = {COUNT_WIDTH{1'b0}}, hold_count_next;
    wire ready;

    assign ready = !reset_sync_reg[1] && locked_sync_reg[1];
    assign ready_o = ready;
    assign cpu_reset_o = !ready || hold_count_reg != HOLD_COUNT;

    always @* begin
        hold_count_next = hold_count_reg;
        if (ready && hold_count_reg != HOLD_COUNT)
            hold_count_next = hold_count_reg + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
    end

    always @(posedge clk) begin
        reset_sync_reg <= {reset_sync_reg[0], rst};
        locked_sync_reg <= {locked_sync_reg[0], clock_locked_i};
        hold_count_reg <= hold_count_next;
        if (!ready) hold_count_reg <= {COUNT_WIDTH{1'b0}};
    end
endmodule

`resetall
