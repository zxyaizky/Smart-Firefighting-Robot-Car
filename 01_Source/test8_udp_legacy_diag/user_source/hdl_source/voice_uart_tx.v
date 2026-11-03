// -----------------------------------------------------------------------------
// File   : voice_uart_tx.v
// Author : Codex
// Date   : 2026-09-26
// -----------------------------------------------------------------------------
// Description:
//   CI-03T fire-prompt UART transmitter. Sends AA 55 01 55 AA at 9600 8N1
//   once per qualified fire_detect rising edge. Re-arms only after a
//   continuous two-second absence of fire.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-26  Codex  v1.0  Initial release
//   2026-09-26  Codex  v1.1  Require two seconds of continuous no-fire to re-arm
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Sends the CI-03T fire prompt immediately on the first fire rising edge.
// Later edges are ignored until fire_detect stays low for two full seconds.
// An edge while busy never interrupts or queues another command.
module voice_uart_tx #(
    // Clock frequency of clk in hertz.
    parameter integer CLK_FREQ_HZ = 100000000,
    // CI-03T UART baud rate.
    parameter integer BAUD_RATE   = 9600,
    // Two seconds by default; override only to accelerate simulation.
    parameter integer REARM_LOW_CYCLES = 2 * CLK_FREQ_HZ
) (
    input  wire clk,
    input  wire rst_n,
    input  wire fire_detect,
    output wire uart_tx,
    output wire busy
);
    function integer count_width;
        input integer count;
        integer value;
        begin
            value = count - 1;
            count_width = 0;
            while (value > 0) begin
                value = value >> 1;
                count_width = count_width + 1;
            end
            if (count_width == 0) count_width = 1;
        end
    endfunction

    // Round to the nearest whole clock for the smallest baud-rate error.
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer COUNT_WIDTH = count_width(CLKS_PER_BIT);
    localparam integer REARM_COUNT_WIDTH = count_width(REARM_LOW_CYCLES);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA = 2'd2;
    localparam [1:0] ST_STOP = 2'd3;

    reg [1:0] state_reg, state_next;
    reg [COUNT_WIDTH-1:0] count_reg, count_next;
    reg [2:0] bit_reg, bit_next;
    reg [2:0] byte_reg, byte_next;
    reg [7:0] data_reg, data_next;
    reg fire_prev_reg;
    reg locked_reg, locked_next;
    reg [REARM_COUNT_WIDTH-1:0] low_count_reg, low_count_next;
    wire fire_rise = fire_detect && !fire_prev_reg;

    assign busy = (state_reg != ST_IDLE);
    assign uart_tx = (state_reg == ST_START) ? 1'b0 :
                     (state_reg == ST_DATA)  ? data_reg[bit_reg] : 1'b1;

    always @* begin
        state_next = state_reg;
        count_next = count_reg;
        bit_next = bit_reg;
        byte_next = byte_reg;
        data_next = data_reg;
        locked_next = locked_reg;
        low_count_next = low_count_reg;
        if (locked_reg) begin
            if (fire_detect) begin
                low_count_next = {REARM_COUNT_WIDTH{1'b0}};
            end else if (low_count_reg == REARM_LOW_CYCLES - 1) begin
                locked_next = 1'b0;
                low_count_next = {REARM_COUNT_WIDTH{1'b0}};
            end else begin
                low_count_next = low_count_reg + 1'b1;
            end
        end else begin
            low_count_next = {REARM_COUNT_WIDTH{1'b0}};
        end
        case (state_reg)
            ST_IDLE: begin
                count_next = {COUNT_WIDTH{1'b0}};
                if (fire_rise && !locked_reg) begin
                    state_next = ST_START;
                    locked_next = 1'b1;
                    bit_next = 3'd0;
                    byte_next = 3'd0;
                    data_next = 8'hAA;
                end
            end
            ST_START: begin
                if (count_reg == CLKS_PER_BIT - 1) begin
                    count_next = {COUNT_WIDTH{1'b0}};
                    state_next = ST_DATA;
                end else count_next = count_reg + 1'b1;
            end
            ST_DATA: begin
                if (count_reg == CLKS_PER_BIT - 1) begin
                    count_next = {COUNT_WIDTH{1'b0}};
                    if (bit_reg == 3'd7) state_next = ST_STOP;
                    else bit_next = bit_reg + 1'b1;
                end else count_next = count_reg + 1'b1;
            end
            ST_STOP: begin
                if (count_reg == CLKS_PER_BIT - 1) begin
                    count_next = {COUNT_WIDTH{1'b0}};
                    if (byte_reg == 3'd4) begin
                        state_next = ST_IDLE;
                    end else begin
                        state_next = ST_START;
                        byte_next = byte_reg + 1'b1;
                        bit_next = 3'd0;
                        case (byte_reg)
                            3'd0: data_next = 8'h55;
                            3'd1: data_next = 8'h01;
                            3'd2: data_next = 8'h55;
                            default: data_next = 8'hAA;
                        endcase
                    end
                end else count_next = count_reg + 1'b1;
            end
            default: begin
                state_next = ST_IDLE;
                count_next = {COUNT_WIDTH{1'b0}};
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= ST_IDLE;
            count_reg <= {COUNT_WIDTH{1'b0}};
            bit_reg <= 3'd0;
            byte_reg <= 3'd0;
            data_reg <= 8'd0;
            fire_prev_reg <= 1'b0;
            locked_reg <= 1'b0;
            low_count_reg <= {REARM_COUNT_WIDTH{1'b0}};
        end else begin
            state_reg <= state_next;
            count_reg <= count_next;
            bit_reg <= bit_next;
            byte_reg <= byte_next;
            data_reg <= data_next;
            fire_prev_reg <= fire_detect;
            locked_reg <= locked_next;
            low_count_reg <= low_count_next;
        end
    end
endmodule

`resetall
