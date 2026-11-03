// File: fire_spray_burst.v
// Author: Codex
// Date: 2026-10-27
// Description: Ten-second spray; three continuous fire-free seconds rearm it.
// Change Log: 2026-10-27 v1.0 B-board automatic spray limit.
`resetall
`timescale 1ns / 1ps
`default_nettype none
module fire_spray_burst #
(
    // Fire-control pixel clock frequency.
    parameter integer CLK_HZ = 75000000
)
(
    input  wire clk,
    input  wire rst,
    input  wire fire_present_i,
    input  wire qualified_i,
    input  wire allowed_i,
    output wire pump_enable_o
);
    localparam integer SPRAY_CYCLES = CLK_HZ * 10;
    localparam integer REARM_CYCLES = CLK_HZ * 3;
    localparam integer COUNT_W = $clog2((SPRAY_CYCLES > REARM_CYCLES ?
                                       SPRAY_CYCLES : REARM_CYCLES) + 1);
    localparam [COUNT_W-1:0] SPRAY_LAST = SPRAY_CYCLES - 1;
    localparam [COUNT_W-1:0] REARM_LAST = REARM_CYCLES - 1;
    // Binary state encoding keeps this three-state interlock small.
    localparam [1:0] STATE_READY = 2'd0, STATE_SPRAY = 2'd1, STATE_CLEAR = 2'd2;
    reg [1:0] state_reg = STATE_READY, state_next;
    reg [COUNT_W-1:0] count_reg = {COUNT_W{1'b0}}, count_next;
    assign pump_enable_o = !rst && state_reg == STATE_SPRAY && allowed_i && fire_present_i;

    always @* begin
        state_next = state_reg;
        count_next = count_reg;
        case (state_reg)
            STATE_READY: begin
                count_next = {COUNT_W{1'b0}};
                if (qualified_i && allowed_i && fire_present_i) state_next = STATE_SPRAY;
            end
            STATE_SPRAY: begin
                if (!allowed_i || !fire_present_i || count_reg == SPRAY_LAST) begin
                    state_next = STATE_CLEAR;
                    count_next = {COUNT_W{1'b0}};
                end else count_next = count_reg + 1'b1;
            end
            STATE_CLEAR: begin
                if (fire_present_i) count_next = {COUNT_W{1'b0}};
                else if (count_reg == REARM_LAST) begin
                    state_next = STATE_READY;
                    count_next = {COUNT_W{1'b0}};
                end else count_next = count_reg + 1'b1;
            end
            default: begin
                state_next = STATE_READY;
                count_next = {COUNT_W{1'b0}};
            end
        endcase
    end
    always @(posedge clk) begin
        state_reg <= state_next;
        count_reg <= count_next;
        if (rst) begin
            state_reg <= STATE_READY;
            count_reg <= {COUNT_W{1'b0}};
        end
    end
endmodule
`resetall
