// -----------------------------------------------------------------------------
// File   : wifi_uart_wb.v
// Author : Codex
// Date   : 2026-10-21
// -----------------------------------------------------------------------------
// Description:
//   Registered Wishbone 8N1 network UART, synchronous RX/TX FIFOs, sticky errors.
//   RX data reads peek; write bit 0 at offset 16 to consume exactly one byte.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-21  Codex  v1.0  Independent PPP serial port; no video/DDR changes.
//   2026-10-25  Codex  v1.1  Guard TX prefetch across mapped RAM collisions.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module wifi_uart_wb #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer RX_ADDR_WIDTH = 11,
    parameter integer TX_ADDR_WIDTH = 8
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_i,
    output wire        tx_o,
    input  wire        cyc_i,
    input  wire        stb_i,
    input  wire        we_i,
    input  wire [2:0]  address_i,
    input  wire [31:0] data_i,
    input  wire [3:0]  select_i,
    input  wire [2:0]  cti_i,
    input  wire [1:0]  bte_i,
    output wire        ack_o,
    output wire        error_o,
    output wire [31:0] data_o
);
    localparam integer BIT_CYCLES = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer TIMER_WIDTH = $clog2(BIT_CYCLES);
    localparam [TIMER_WIDTH-1:0] BIT_LAST = BIT_CYCLES - 1;
    localparam [RX_ADDR_WIDTH:0] RX_DEPTH = 1 << RX_ADDR_WIDTH;
    localparam [TX_ADDR_WIDTH:0] TX_DEPTH = 1 << TX_ADDR_WIDTH;

    reg [7:0] rx_memory [0:(1 << RX_ADDR_WIDTH)-1];
    reg [7:0] tx_memory [0:(1 << TX_ADDR_WIDTH)-1];
    reg [7:0] rx_front_reg, tx_front_reg;
    reg rx_front_valid_reg, tx_front_valid_reg;
    reg tx_prefetch_ready_reg;
    reg [RX_ADDR_WIDTH-1:0] rx_head_reg, rx_tail_reg;
    reg [TX_ADDR_WIDTH-1:0] tx_head_reg, tx_tail_reg;
    reg [RX_ADDR_WIDTH:0] rx_count_reg;
    reg [TX_ADDR_WIDTH:0] tx_count_reg;
    reg [9:0] tx_shift_reg;
    reg [3:0] tx_bits_reg;
    reg [TIMER_WIDTH-1:0] tx_timer_reg;
    reg [1:0] errors_reg;
    reg response_reg, response_error_reg;
    reg [31:0] response_data_reg;
    reg [31:0] read_data;
    wire [7:0] rx_data;
    wire rx_valid, rx_error;
    wire accept, protocol_valid, access_valid;
    wire rx_pop, rx_push, tx_push, tx_pop;
    wire write_access;
    wire rx_empty, rx_full, tx_full;

    assign rx_empty = rx_count_reg == 0 || !rx_front_valid_reg;
    assign rx_full = rx_count_reg == RX_DEPTH;
    assign tx_full = tx_count_reg == TX_DEPTH;
    assign accept = cyc_i && stb_i && !response_reg && !rst;
    assign protocol_valid = bte_i == 0 && select_i[0] &&
        (cti_i == 3'b000 || cti_i == 3'b010 || cti_i == 3'b111);
    assign access_valid = protocol_valid &&
        (!we_i || address_i == 0 || address_i == 4 || address_i == 6) &&
        !(we_i && address_i == 0 && tx_full);
    assign write_access = accept && access_valid && we_i;
    assign rx_pop = write_access && address_i == 4 && data_i[0] && !rx_empty;
    assign rx_push = rx_valid && (!rx_full || rx_pop) && !rst;
    assign tx_push = write_access && address_i == 0;
    assign tx_pop = tx_bits_reg == 0 && tx_count_reg != 0 && tx_front_valid_reg && !rst;
    assign tx_o = tx_shift_reg[0];
    assign ack_o = response_reg && cyc_i && stb_i && !response_error_reg && !rst;
    assign error_o = response_reg && cyc_i && stb_i && response_error_reg && !rst;
    assign data_o = response_data_reg;

    us100_uart_rx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) uart_rx_inst (
        .clk(clk), .rst(rst), .enable_i(1'b1), .uart_rx_i(rx_i),
        .data_o(rx_data), .valid_o(rx_valid), .error_o(rx_error)
    );

    always @* begin
        read_data = 32'd0;
        case (address_i)
            3'd0: read_data = rx_empty ? 32'd0 : {24'd0, rx_front_reg};
            3'd1: read_data = {31'd0, tx_full};
            3'd2: read_data = {31'd0, rx_empty};
            3'd3: read_data = {{(31-RX_ADDR_WIDTH){1'b0}}, rx_count_reg};
            3'd4: read_data = 32'd0;
            3'd5: read_data = {{(31-TX_ADDR_WIDTH){1'b0}}, tx_count_reg} +
                {31'd0, tx_bits_reg != 0};
            3'd6: read_data = {30'd0, errors_reg};
            3'd7: read_data = 32'h4e455455;
            default: read_data = 32'd0;
        endcase
    end

    // RAM payloads have no reset. Valid flags mask synchronous prefetch latency
    // after a first write or a head change, including read/write collisions.
    always @(posedge clk) begin
        if (rx_push) rx_memory[rx_tail_reg] <= rx_data;
        if (tx_push) tx_memory[tx_tail_reg] <= data_i[7:0];
        rx_front_reg <= rx_memory[rx_head_reg];
        tx_front_reg <= tx_memory[tx_head_reg];
    end

    always @(posedge clk) begin
        response_reg <= accept;
        rx_front_valid_reg <= rx_count_reg != 0 && !rx_pop;
        // A mapped OUTREG RAM may retain collision data for an extra clock.
        tx_prefetch_ready_reg <= tx_count_reg != 0 && !tx_pop;
        tx_front_valid_reg <= tx_prefetch_ready_reg && tx_count_reg != 0 && !tx_pop;
        if (accept) begin
            response_error_reg <= !access_valid;
            response_data_reg <= read_data;
        end
        if (rx_pop) rx_head_reg <= rx_head_reg + 1'b1;
        if (rx_push) rx_tail_reg <= rx_tail_reg + 1'b1;
        if (tx_pop) tx_head_reg <= tx_head_reg + 1'b1;
        if (tx_push) tx_tail_reg <= tx_tail_reg + 1'b1;
        case ({rx_push, rx_pop})
            2'b10: rx_count_reg <= rx_count_reg + 1'b1;
            2'b01: rx_count_reg <= rx_count_reg - 1'b1;
            default: ;
        endcase
        case ({tx_push, tx_pop})
            2'b10: tx_count_reg <= tx_count_reg + 1'b1;
            2'b01: tx_count_reg <= tx_count_reg - 1'b1;
            default: ;
        endcase
        if (write_access && address_i == 6) errors_reg <= errors_reg & ~data_i[1:0];
        if (rx_error) errors_reg[0] <= 1'b1;
        if (rx_valid && !rx_push) errors_reg[1] <= 1'b1;
        if (tx_bits_reg != 0) begin
            if (tx_timer_reg == 0) begin
                tx_shift_reg <= {1'b1, tx_shift_reg[9:1]};
                tx_bits_reg <= tx_bits_reg - 1'b1;
                tx_timer_reg <= BIT_LAST;
            end else tx_timer_reg <= tx_timer_reg - 1'b1;
        end
        if (tx_pop) begin
            tx_shift_reg <= {1'b1, tx_front_reg, 1'b0};
            tx_bits_reg <= 4'd10;
            tx_timer_reg <= BIT_LAST;
        end
        if (rst) begin
            rx_head_reg <= 0;
            rx_tail_reg <= 0;
            tx_head_reg <= 0;
            tx_tail_reg <= 0;
            rx_count_reg <= 0;
            tx_count_reg <= 0;
            tx_shift_reg <= 10'h3ff;
            tx_bits_reg <= 0;
            tx_timer_reg <= 0;
            errors_reg <= 0;
            response_reg <= 1'b0;
            rx_front_valid_reg <= 1'b0;
            tx_front_valid_reg <= 1'b0;
            tx_prefetch_ready_reg <= 1'b0;
            response_error_reg <= 1'b0;
            response_data_reg <= 0;
        end
    end
endmodule
`resetall
