// File: voice_alert_uart_tx.v
// Author: Codex
// Date: 2026-10-27
// Description: Queued CI-03T messages, once per appearance, 9600 baud 8N1.
// Change Log: 2026-11-01 Red fire uses existing voice code 01.
// Change Log: 2026-10-30 Yellow fire 01, green 03, person 04; obsolete 02 removed.
`resetall
`timescale 1ns / 1ps
`default_nettype none
module voice_alert_uart_tx #
(
    // Input clock frequency.
    parameter integer CLK_HZ = 50000000,
    // Module serial configuration: eight data bits, no parity, one stop bit.
    parameter integer BAUD_RATE = 9600,
    // A target must disappear continuously before its next announcement.
    parameter integer REARM_MS = 2000
)
(
    input  wire       clk,
    input  wire       rst,
    input  wire [3:0] flags_i,
    output wire       uart_tx_o
);
    localparam integer BIT_CYCLES = (CLK_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer BIT_W = BIT_CYCLES < 2 ? 1 : $clog2(BIT_CYCLES);
    localparam integer MS_CYCLES = CLK_HZ / 1000;
    localparam integer MS_W = MS_CYCLES < 2 ? 1 : $clog2(MS_CYCLES);
    localparam integer AGE_W = $clog2(REARM_MS + 1);
    localparam [AGE_W-1:0] AGE_LIMIT = REARM_MS;
    localparam [MS_W-1:0] MS_LAST = MS_CYCLES - 1;
    localparam [BIT_W-1:0] BIT_LAST = BIT_CYCLES - 1;
    reg [3:0] armed_reg = 4'hf, armed_next;
    reg [3:0] pending_reg = 4'd0, pending_next;
    reg [4*AGE_W-1:0] absent_reg = {4{AGE_LIMIT}}, absent_next;
    reg [MS_W-1:0] ms_reg = {MS_W{1'b0}}, ms_next;
    reg [BIT_W-1:0] baud_reg = {BIT_W{1'b0}}, baud_next;
    reg active_reg = 1'b0, active_next;
    reg [2:0] byte_reg = 3'd0, byte_next;
    reg [3:0] bit_reg = 4'd0, bit_next;
    reg [9:0] shift_reg = 10'h3ff, shift_next;
    reg [2:0] code_reg = 3'd0, code_next;
    reg [3:0] select_mask;
    reg [2:0] select_code;
    integer channel;
    wire ms_tick = ms_reg == MS_LAST;
    assign uart_tx_o = shift_reg[0];

    // The selected code is frozen for all five bytes; new classes queue up.
    always @* begin
        armed_next = armed_reg;
        pending_next = pending_reg | (flags_i & armed_reg & 4'b1011);
        ms_next = ms_reg + 1'b1;
        baud_next = baud_reg;
        active_next = active_reg;
        byte_next = byte_reg;
        bit_next = bit_reg;
        shift_next = shift_reg;
        code_next = code_reg;
        absent_next = absent_reg;
        select_mask = 4'd0;
        select_code = 3'd0;
        for (channel = 0; channel < 4; channel = channel + 1) begin
            if (flags_i[channel]) begin
                absent_next[channel*AGE_W +: AGE_W] = {AGE_W{1'b0}};
                armed_next[channel] = 1'b0;
            end else if (ms_tick) begin
                if (absent_reg[channel*AGE_W +: AGE_W] < AGE_LIMIT)
                    absent_next[channel*AGE_W +: AGE_W] = absent_reg[channel*AGE_W +: AGE_W] + 1'b1;
                if (absent_reg[channel*AGE_W +: AGE_W] >= AGE_LIMIT - 1'b1)
                    armed_next[channel] = 1'b1;
            end
        end
        if (ms_tick) ms_next = {MS_W{1'b0}};
        // Red fire (01), green supplies (03), personnel (04).
        if (pending_next[0]) begin select_mask = 4'b0001; select_code = 3'd1; end
        else if (pending_next[1]) begin select_mask = 4'b0010; select_code = 3'd3; end
        else if (pending_next[3]) begin select_mask = 4'b1000; select_code = 3'd4; end
        if (!active_reg && |select_mask) begin
            active_next = 1'b1;
            byte_next = 3'd0;
            bit_next = 4'd0;
            baud_next = {BIT_W{1'b0}};
            code_next = select_code;
            shift_next = {1'b1, 8'haa, 1'b0};
            pending_next = pending_next & ~select_mask;
        end else if (active_reg) begin
            if (baud_reg == BIT_LAST) begin
                baud_next = {BIT_W{1'b0}};
                if (bit_reg == 4'd9) begin
                    bit_next = 4'd0;
                    byte_next = byte_reg + 1'b1;
                    // Advance from the byte just completed.
                    case (byte_reg)
                        3'd0: shift_next = {1'b1, 8'h55, 1'b0};
                        3'd1: shift_next = {1'b1, 5'd0, code_reg, 1'b0};
                        3'd2: shift_next = {1'b1, 8'h55, 1'b0};
                        3'd3: shift_next = {1'b1, 8'haa, 1'b0};
                        default: begin active_next = 1'b0; shift_next = 10'h3ff; end
                    endcase
                end else begin
                    bit_next = bit_reg + 1'b1;
                    shift_next = {1'b1, shift_reg[9:1]};
                end
            end else baud_next = baud_reg + 1'b1;
        end
    end
    always @(posedge clk) begin
        armed_reg <= armed_next;
        pending_reg <= pending_next;
        ms_reg <= ms_next;
        baud_reg <= baud_next;
        active_reg <= active_next;
        byte_reg <= byte_next;
        bit_reg <= bit_next;
        shift_reg <= shift_next;
        code_reg <= code_next;
        absent_reg <= absent_next;
        if (rst) begin
            armed_reg <= 4'hf;
            pending_reg <= 4'd0;
            ms_reg <= {MS_W{1'b0}};
            baud_reg <= {BIT_W{1'b0}};
            active_reg <= 1'b0;
            byte_reg <= 3'd0;
            bit_reg <= 4'd0;
            shift_reg <= 10'h3ff;
            code_reg <= 3'd0;
            absent_reg <= {4{AGE_LIMIT}};
        end
    end
endmodule
`resetall
