// -----------------------------------------------------------------------------
// File   : us100_uart_ranging.v
// Author : Codex
// Date   : 2026-10-08
// -----------------------------------------------------------------------------
// Description:
//   Periodically transmit US-100 command 0x55 using UART 8N1, then decode the
//   high and low millimetre bytes. Timeout and malformed replies invalidate Z.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-08  Codex  v1.0  Independent ultrasonic distance measurement
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module us100_uart_ranging #
(
    // Actual B-board HDMI pixel clock, also used by the display.
    parameter integer CLK_FREQ_HZ = 75000000,
    // US-100 jumper-present mode uses 9600 baud, 8N1.
    parameter integer BAUD_RATE = 9600,
    // Interval between command starts, also initial sensor power-up delay.
    parameter integer POLL_INTERVAL_MS = 200,
    // Maximum wait for both response bytes after the command completes.
    parameter integer RESPONSE_TIMEOUT_MS = 100,
    // Specified usable range; invalid values are not displayed as distances.
    parameter [15:0] MIN_DISTANCE_MM = 16'd20,
    parameter [15:0] MAX_DISTANCE_MM = 16'd4500
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx_i,
    output wire        uart_tx_o,
    output wire [15:0] distance_mm_o,
    output wire        distance_valid_o,
    output wire        result_update_o
);
    localparam integer BIT_CYCLES = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam [63:0] POLL_CYCLES =
        (64'd1 * CLK_FREQ_HZ * POLL_INTERVAL_MS + 64'd999) / 64'd1000;
    localparam [63:0] TIMEOUT_CYCLES =
        (64'd1 * CLK_FREQ_HZ * RESPONSE_TIMEOUT_MS + 64'd999) / 64'd1000;
    localparam integer BIT_WIDTH = BIT_CYCLES > 1 ? $clog2(BIT_CYCLES) : 1;
    localparam integer POLL_WIDTH = POLL_CYCLES > 1 ? $clog2(POLL_CYCLES) : 1;
    localparam integer TIMEOUT_WIDTH = TIMEOUT_CYCLES > 1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam [BIT_WIDTH-1:0] BIT_LAST = BIT_CYCLES - 1;
    localparam [POLL_WIDTH-1:0] POLL_LAST = POLL_CYCLES - 64'd1;
    localparam [TIMEOUT_WIDTH-1:0] TIMEOUT_LAST = TIMEOUT_CYCLES - 64'd1;
    // One-hot encoding, all states remain in the same pixel clock domain.
    localparam [4:0] WAIT_POLL = 5'b00001, SEND_COMMAND = 5'b00010,
        WAIT_HIGH = 5'b00100, WAIT_LOW = 5'b01000, QUIET = 5'b10000;

    reg [4:0] state_reg = WAIT_POLL, state_next;
    reg [POLL_WIDTH-1:0] poll_reg = {POLL_WIDTH{1'b0}}, poll_next;
    reg [TIMEOUT_WIDTH-1:0] timeout_reg = {TIMEOUT_WIDTH{1'b0}}, timeout_next;
    reg [BIT_WIDTH-1:0] bit_timer_reg = {BIT_WIDTH{1'b0}}, bit_timer_next;
    reg [3:0] tx_index_reg = 4'd0, tx_index_next;
    reg [9:0] tx_frame_reg = 10'h3ff, tx_frame_next;
    reg [7:0] high_byte_reg = 8'd0, high_byte_next;
    reg [15:0] distance_reg = 16'd0, distance_next;
    reg distance_valid_reg = 1'b0, distance_valid_next;
    reg result_update_reg = 1'b0, result_update_next;
    wire receiving;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;
    wire [15:0] received_distance;

    assign receiving        = state_reg == WAIT_HIGH || state_reg == WAIT_LOW;
    assign received_distance = {high_byte_reg, rx_data};
    assign uart_tx_o         = rst || state_reg != SEND_COMMAND ? 1'b1 : tx_frame_reg[0];
    assign distance_mm_o     = distance_reg;
    assign distance_valid_o  = distance_valid_reg && !rst;
    assign result_update_o   = result_update_reg && !rst;

    us100_uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) us100_uart_rx_inst (
        .clk         (clk),
        .rst         (rst),
        .enable_i    (receiving),
        .uart_rx_i   (uart_rx_i),
        .data_o      (rx_data),
        .valid_o     (rx_valid),
        .error_o     (rx_error)
    );

    always @* begin
        state_next = state_reg;
        poll_next = poll_reg;
        timeout_next = timeout_reg;
        bit_timer_next = bit_timer_reg;
        tx_index_next = tx_index_reg;
        tx_frame_next = tx_frame_reg;
        high_byte_next = high_byte_reg;
        distance_next = distance_reg;
        distance_valid_next = distance_valid_reg;
        result_update_next = 1'b0;
        if (poll_reg != POLL_LAST) poll_next = poll_reg + 1'b1;
        case (state_reg)
            WAIT_POLL: begin
                if (poll_reg == POLL_LAST) begin
                    // Start + eight data bits LSB first + stop, command 0x55.
                    tx_frame_next = {1'b1, 8'h55, 1'b0};
                    tx_index_next = 4'd0;
                    bit_timer_next = BIT_LAST;
                    poll_next = {POLL_WIDTH{1'b0}};
                    state_next = SEND_COMMAND;
                end
            end
            SEND_COMMAND: begin
                if (bit_timer_reg == 0) begin
                    if (tx_index_reg == 4'd9) begin
                        timeout_next = {TIMEOUT_WIDTH{1'b0}};
                        state_next = WAIT_HIGH;
                    end else begin
                        tx_frame_next = {1'b1, tx_frame_reg[9:1]};
                        tx_index_next = tx_index_reg + 4'd1;
                        bit_timer_next = BIT_LAST;
                    end
                end else bit_timer_next = bit_timer_reg - 1'b1;
            end
            WAIT_HIGH, WAIT_LOW: begin
                timeout_next = timeout_reg + 1'b1;
                if (rx_valid) begin
                    if (state_reg == WAIT_HIGH) begin
                        high_byte_next = rx_data;
                        state_next = WAIT_LOW;
                    end else begin
                        state_next = QUIET;
                        result_update_next = 1'b1;
                        distance_valid_next = received_distance >= MIN_DISTANCE_MM &&
                            received_distance <= MAX_DISTANCE_MM;
                        distance_next = distance_valid_next ? received_distance : 16'd0;
                    end
                end
                if (rx_error || timeout_reg == TIMEOUT_LAST) begin
                    state_next = QUIET;
                    distance_valid_next = 1'b0;
                    distance_next = 16'd0;
                    result_update_next = 1'b1;
                end
            end
            QUIET: begin
                // Ignore late/unsolicited bytes until the next complete command.
                if (poll_reg == POLL_LAST) state_next = WAIT_POLL;
            end
            default: begin
                state_next = WAIT_POLL;
                distance_valid_next = 1'b0;
                distance_next = 16'd0;
            end
        endcase
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        poll_reg <= poll_next;
        timeout_reg <= timeout_next;
        bit_timer_reg <= bit_timer_next;
        tx_index_reg <= tx_index_next;
        tx_frame_reg <= tx_frame_next;
        high_byte_reg <= high_byte_next;
        distance_reg <= distance_next;
        distance_valid_reg <= distance_valid_next;
        result_update_reg <= result_update_next;
        if (rst) begin
            state_reg <= WAIT_POLL;
            poll_reg <= {POLL_WIDTH{1'b0}};
            timeout_reg <= {TIMEOUT_WIDTH{1'b0}};
            bit_timer_reg <= {BIT_WIDTH{1'b0}};
            tx_index_reg <= 4'd0;
            tx_frame_reg <= 10'h3ff;
            high_byte_reg <= 8'd0;
            distance_reg <= 16'd0;
            distance_valid_reg <= 1'b0;
            result_update_reg <= 1'b0;
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || BAUD_RATE < 1 || BIT_CYCLES < 8 ||
            POLL_INTERVAL_MS <= RESPONSE_TIMEOUT_MS || RESPONSE_TIMEOUT_MS < 1 ||
            TIMEOUT_CYCLES < 10 * BIT_CYCLES ||
            POLL_CYCLES <= TIMEOUT_CYCLES + 10 * BIT_CYCLES ||
            MIN_DISTANCE_MM > MAX_DISTANCE_MM) begin
            $error("Invalid us100_uart_ranging parameters");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`resetall
