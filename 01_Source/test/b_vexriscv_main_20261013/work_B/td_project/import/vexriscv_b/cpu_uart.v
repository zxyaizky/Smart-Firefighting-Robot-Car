// -----------------------------------------------------------------------------
// File   : cpu_uart.v
// Author : Codex
// Date   : 2026-10-19
// -----------------------------------------------------------------------------
// Description:
//   Fixed-baud 8N1 CPU UART with LiteUART polling registers and 16-byte RX FIFO.
//   RXTX reads peek; write EV_PENDING bit 1 to consume one received byte.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-19  Codex  v1.0  Add CPU-controlled console, independent of video.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module cpu_uart #
(
    // CPU/system clock frequency in Hz.
    parameter integer CLK_FREQ_HZ = 50000000,
    // Fixed line speed; software must use the same baud rate.
    parameter integer BAUD_RATE = 115200
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_i,
    output wire        tx_o,
    input  wire [2:0]  address_i,
    input  wire        write_i,
    input  wire [7:0]  data_i,
    output wire [31:0] data_o,
    output wire        tx_full_o
);
    localparam integer BIT_CYCLES = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer TIMER_WIDTH = BIT_CYCLES > 1 ? $clog2(BIT_CYCLES) : 1;
    localparam [TIMER_WIDTH-1:0] BIT_LAST = BIT_CYCLES - 1;
    reg [9:0] tx_shift_reg = 10'h3ff, tx_shift_next;
    reg [3:0] tx_bits_reg = 4'd0, tx_bits_next;
    reg [TIMER_WIDTH-1:0] tx_timer_reg = {TIMER_WIDTH{1'b0}}, tx_timer_next;
    reg [3:0] rx_head_reg = 4'd0, rx_head_next;
    reg [3:0] rx_tail_reg = 4'd0, rx_tail_next;
    reg [4:0] rx_count_reg = 5'd0, rx_count_next;
    reg [1:0] event_enable_reg = 2'd0, event_enable_next;
    reg [1:0] error_reg = 2'd0, error_next;
    (* ram_style = "dram" *) reg [7:0] rx_memory [15:0];
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;
    wire rx_pop;
    wire rx_push;
    wire tx_write;
    wire [7:0] rx_front;
    wire [1:0] events;

    assign tx_o      = tx_shift_reg[0];
    assign tx_full_o = tx_bits_reg != 4'd0;
    assign tx_write  = write_i && address_i == 3'd0 && !tx_full_o;
    assign rx_pop    = write_i && address_i == 3'd4 && data_i[1] &&
                       rx_count_reg != 5'd0;
    assign rx_push   = rx_valid && (rx_count_reg != 5'd16 || rx_pop);
    assign rx_front  = rx_count_reg != 5'd0 ? rx_memory[rx_head_reg] : 8'd0;
    assign events    = {rx_count_reg != 5'd0, !tx_full_o};
    assign data_o =
        ({32{address_i == 3'd0}} & {24'd0, rx_front}) |
        ({32{address_i == 3'd1}} & {31'd0, tx_full_o}) |
        ({32{address_i == 3'd2}} & {31'd0, rx_count_reg == 5'd0}) |
        ({32{address_i == 3'd3}} & {30'd0, events}) |
        ({32{address_i == 3'd4}} & {30'd0, events}) |
        ({32{address_i == 3'd5}} & {30'd0, event_enable_reg}) |
        ({32{address_i == 3'd6}} & {30'd0, error_reg}) |
        ({32{address_i == 3'd7}} & 32'h55415254);

    // Reuse the existing synchronized, midpoint-sampling 8N1 receiver.
    us100_uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) uart_rx_inst (
        .clk       (clk),
        .rst       (rst),
        .enable_i  (1'b1),
        .uart_rx_i (rx_i),
        .data_o    (rx_data),
        .valid_o   (rx_valid),
        .error_o   (rx_error)
    );

    always @* begin
        tx_shift_next = tx_shift_reg;
        tx_bits_next = tx_bits_reg;
        tx_timer_next = tx_timer_reg;
        rx_head_next = rx_head_reg;
        rx_tail_next = rx_tail_reg;
        rx_count_next = rx_count_reg;
        event_enable_next = event_enable_reg;
        error_next = error_reg;
        if (tx_full_o) begin
            if (tx_timer_reg == {TIMER_WIDTH{1'b0}}) begin
                tx_shift_next = {1'b1, tx_shift_reg[9:1]};
                tx_bits_next = tx_bits_reg - 4'd1;
                tx_timer_next = BIT_LAST;
            end else begin
                tx_timer_next = tx_timer_reg - {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
            end
        end
        if (tx_write) begin
            tx_shift_next = {1'b1, data_i, 1'b0};
            tx_bits_next = 4'd10;
            tx_timer_next = BIT_LAST;
        end
        if (write_i && address_i == 3'd5) event_enable_next = data_i[1:0];
        if (write_i && address_i == 3'd6) error_next = error_reg & ~data_i[1:0];
        if (rx_error) error_next[0] = 1'b1;
        if (rx_valid && !rx_push) error_next[1] = 1'b1;
        if (rx_pop) rx_head_next = rx_head_reg + 4'd1;
        if (rx_push) rx_tail_next = rx_tail_reg + 4'd1;
        case ({rx_push, rx_pop})
            2'b10: rx_count_next = rx_count_reg + 5'd1;
            2'b01: rx_count_next = rx_count_reg - 5'd1;
            default: ;
        endcase
    end

    // FIFO data has no reset; the reset count prevents reading invalid storage.
    always @(posedge clk) begin
        if (rx_push && !rst) rx_memory[rx_tail_reg] <= rx_data;
    end
    always @(posedge clk) begin
        tx_shift_reg <= tx_shift_next;
        tx_bits_reg <= tx_bits_next;
        tx_timer_reg <= tx_timer_next;
        rx_head_reg <= rx_head_next;
        rx_tail_reg <= rx_tail_next;
        rx_count_reg <= rx_count_next;
        event_enable_reg <= event_enable_next;
        error_reg <= error_next;
        if (rst) begin
            tx_shift_reg <= 10'h3ff;
            tx_bits_reg <= 4'd0;
            tx_timer_reg <= {TIMER_WIDTH{1'b0}};
            rx_head_reg <= 4'd0;
            rx_tail_reg <= 4'd0;
            rx_count_reg <= 5'd0;
            event_enable_reg <= 2'd0;
            error_reg <= 2'd0;
        end
    end
endmodule
`resetall
