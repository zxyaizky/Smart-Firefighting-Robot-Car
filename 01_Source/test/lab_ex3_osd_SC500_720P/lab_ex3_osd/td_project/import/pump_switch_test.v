// -----------------------------------------------------------------------------
// File   : pump_switch_test.v
// Author : Codex
// Date   : 2026-10-07
// -----------------------------------------------------------------------------
// Description:
//   Synchronized manual pump test. Require stable OFF after reset, then stable
//   ON to start. A synchronized OFF immediately cancels the ON qualification.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-07  Codex  v1.0  Independent switch-controlled GPIO permission
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module pump_switch_test #
(
    // Actual B-board crystal clock; does not depend on video or PLL lock.
    parameter integer CLK_FREQ_HZ = 50000000,
    // Stable switch level required for OFF arming and ON activation.
    parameter integer DEBOUNCE_MS = 20,
    // Zero input level commands ON by default. Change to match switch direction.
    parameter SWITCH_ACTIVE_LOW = 1'b1
)
(
    input  wire clk,
    input  wire rst,
    input  wire switch_i,
    output wire pump_enable_o
);
    localparam [63:0] DEBOUNCE_CYCLES =
        (64'd1 * CLK_FREQ_HZ * DEBOUNCE_MS + 64'd999) / 64'd1000;
    localparam integer COUNT_WIDTH = DEBOUNCE_CYCLES > 1 ? $clog2(DEBOUNCE_CYCLES) : 1;
    localparam [COUNT_WIDTH-1:0] COUNT_LAST = DEBOUNCE_CYCLES - 64'd1;
    localparam OFF_LEVEL = SWITCH_ACTIVE_LOW ? 1'b1 : 1'b0;

    (* ASYNC_REG = "TRUE" *) reg [1:0] switch_sync_reg = {2{OFF_LEVEL}};
    reg [1:0] sync_valid_reg = 2'b00;
    reg candidate_reg = OFF_LEVEL, candidate_next;
    reg [COUNT_WIDTH-1:0] count_reg = {COUNT_WIDTH{1'b0}}, count_next;
    reg armed_reg = 1'b0, armed_next;
    reg enable_reg = 1'b0, enable_next;
    wire switch_on;
    wire sync_ready;

    assign switch_on = SWITCH_ACTIVE_LOW ? !switch_sync_reg[1] : switch_sync_reg[1];
    assign sync_ready = &sync_valid_reg;
    assign pump_enable_o = !rst && sync_ready && armed_reg && enable_reg && switch_on;

    always @* begin
        candidate_next = candidate_reg;
        count_next = count_reg;
        armed_next = armed_reg;
        enable_next = enable_reg;
        if (!sync_ready) begin
            count_next = {COUNT_WIDTH{1'b0}};
            enable_next = 1'b0;
        end else begin
            if (!switch_on) enable_next = 1'b0;
            if (switch_sync_reg[1] != candidate_reg) begin
                candidate_next = switch_sync_reg[1];
                count_next = {COUNT_WIDTH{1'b0}};
                enable_next = 1'b0;
            end else if (count_reg == COUNT_LAST) begin
                if (!switch_on) armed_next = 1'b1;
                else if (armed_reg) enable_next = 1'b1;
            end else begin
                count_next = count_reg + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
            end
        end
    end

    always @(posedge clk) begin
        switch_sync_reg <= {switch_sync_reg[0], switch_i};
        sync_valid_reg <= {sync_valid_reg[0], 1'b1};
        candidate_reg <= candidate_next;
        count_reg <= count_next;
        armed_reg <= armed_next;
        enable_reg <= enable_next;
        if (rst) begin
            switch_sync_reg <= {2{OFF_LEVEL}};
            sync_valid_reg <= 2'b00;
            candidate_reg <= OFF_LEVEL;
            count_reg <= {COUNT_WIDTH{1'b0}};
            armed_reg <= 1'b0;
            enable_reg <= 1'b0;
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || DEBOUNCE_MS < 1 || DEBOUNCE_CYCLES < 1) begin
            $error("Invalid pump_switch_test parameters");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`resetall
