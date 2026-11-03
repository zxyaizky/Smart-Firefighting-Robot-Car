// -----------------------------------------------------------------------------
// File   : us100_uart_rx.v
// Author : Codex
// Date   : 2026-10-08
// -----------------------------------------------------------------------------
// Description:
//   Enabled 8N1 UART receiver with input synchronizer, mid-bit start validation
//   and stop-bit checking. Disabled transactions discard all partial bytes.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-08  Codex  v1.0  Independent US-100 receive path
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module us100_uart_rx #
(
    // Actual B-board HDMI pixel clock.
    parameter integer CLK_FREQ_HZ = 75000000,
    // US-100 UART baud rate, eight data bits, no parity, one stop bit.
    parameter integer BAUD_RATE = 9600
)
(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable_i,
    input  wire       uart_rx_i,
    output wire [7:0] data_o,
    output wire       valid_o,
    output wire       error_o
);
    localparam integer BIT_CYCLES = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer TIMER_WIDTH = BIT_CYCLES > 1 ? $clog2(BIT_CYCLES) : 1;
    localparam [TIMER_WIDTH-1:0] BIT_LAST = BIT_CYCLES - 1;
    localparam [TIMER_WIDTH-1:0] HALF_LAST = BIT_CYCLES / 2 - 1;
    // One-hot encoding, all states remain in clk.
    localparam [3:0] RX_IDLE = 4'b0001, RX_START = 4'b0010,
        RX_DATA = 4'b0100, RX_STOP = 4'b1000;

    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_sync_reg = 2'b11;
    reg previous_rx_reg = 1'b1;
    reg [3:0] state_reg = RX_IDLE, state_next;
    reg [TIMER_WIDTH-1:0] timer_reg = {TIMER_WIDTH{1'b0}}, timer_next;
    reg [2:0] bit_index_reg = 3'd0, bit_index_next;
    reg [7:0] shift_reg = 8'd0, shift_next;
    reg [7:0] data_reg = 8'd0, data_next;
    reg valid_reg = 1'b0, valid_next;
    reg error_reg = 1'b0, error_next;
    wire falling_edge;

    assign falling_edge = previous_rx_reg && !rx_sync_reg[1];
    assign data_o       = data_reg;
    assign valid_o      = valid_reg && enable_i && !rst;
    assign error_o      = error_reg && enable_i && !rst;

    always @* begin
        state_next = state_reg;
        timer_next = timer_reg;
        bit_index_next = bit_index_reg;
        shift_next = shift_reg;
        data_next = data_reg;
        valid_next = 1'b0;
        error_next = 1'b0;
        case (state_reg)
            RX_IDLE: begin
                if (falling_edge) begin
                    timer_next = HALF_LAST;
                    state_next = RX_START;
                end
            end
            RX_START: begin
                if (timer_reg == 0) begin
                    if (!rx_sync_reg[1]) begin
                        timer_next = BIT_LAST;
                        bit_index_next = 3'd0;
                        state_next = RX_DATA;
                    end else state_next = RX_IDLE;
                end else timer_next = timer_reg - 1'b1;
            end
            RX_DATA: begin
                if (timer_reg == 0) begin
                    shift_next[bit_index_reg] = rx_sync_reg[1];
                    timer_next = BIT_LAST;
                    if (bit_index_reg == 3'd7) state_next = RX_STOP;
                    else bit_index_next = bit_index_reg + 3'd1;
                end else timer_next = timer_reg - 1'b1;
            end
            RX_STOP: begin
                if (timer_reg == 0) begin
                    state_next = RX_IDLE;
                    if (rx_sync_reg[1]) begin
                        data_next = shift_reg;
                        valid_next = 1'b1;
                    end else error_next = 1'b1;
                end else timer_next = timer_reg - 1'b1;
            end
            default: state_next = RX_IDLE;
        endcase
        if (!enable_i) begin
            state_next = RX_IDLE;
            timer_next = {TIMER_WIDTH{1'b0}};
            bit_index_next = 3'd0;
            shift_next = 8'd0;
            valid_next = 1'b0;
            error_next = 1'b0;
        end
    end

    always @(posedge clk) begin
        rx_sync_reg <= {rx_sync_reg[0], uart_rx_i};
        previous_rx_reg <= rx_sync_reg[1];
        state_reg <= state_next;
        timer_reg <= timer_next;
        bit_index_reg <= bit_index_next;
        shift_reg <= shift_next;
        data_reg <= data_next;
        valid_reg <= valid_next;
        error_reg <= error_next;
        if (rst) begin
            rx_sync_reg <= 2'b11;
            previous_rx_reg <= 1'b1;
            state_reg <= RX_IDLE;
            timer_reg <= {TIMER_WIDTH{1'b0}};
            bit_index_reg <= 3'd0;
            shift_reg <= 8'd0;
            data_reg <= 8'd0;
            valid_reg <= 1'b0;
            error_reg <= 1'b0;
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || BAUD_RATE < 1 || BIT_CYCLES < 8) begin
            $error("Invalid us100_uart_rx parameters");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`resetall
