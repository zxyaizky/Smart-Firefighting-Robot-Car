// -----------------------------------------------------------------------------
// File   : stereo_sync_gen.v
// Author : Codex
// Date   : 2026-10-03
// Description: Absolute-ID sync packets on the existing idle-low GPIO.
// Change Log: 2026-10-03 v2.0 CRC-protected IDs replace independent edge counts.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_sync_gen #
(
    // Existing board reference clock and request rate.
    parameter CLK_FREQ = 50000000,
    parameter SYNC_RATE = 5,
    // Complete 40-bit packet duration: 1 ms at the default clock.
    parameter PULSE_CYCLES = 50000
)
(
    input  wire        clk,
    input  wire        rst,
    output wire        stereo_sync_o,
    output wire [15:0] stereo_sync_id_o,
    output wire        stereo_sync_event_o
);
    // A5, ID-high, ID-low, CRC-8/MAXIM; inverted 8N1, LSB first per byte.
    localparam integer PERIOD_CYCLES = CLK_FREQ / SYNC_RATE;
    localparam integer BIT_CYCLES = PULSE_CYCLES / 40;
    localparam integer COUNT_WIDTH = $clog2(PERIOD_CYCLES);
    localparam integer BIT_WIDTH = $clog2(BIT_CYCLES);
    localparam [COUNT_WIDTH-1:0] PERIOD_LAST = PERIOD_CYCLES - 1;
    localparam [BIT_WIDTH-1:0] BIT_LAST = BIT_CYCLES - 1;
    reg [COUNT_WIDTH-1:0] count_reg = {COUNT_WIDTH{1'b0}}, count_next;
    reg [BIT_WIDTH-1:0] timer_reg = {BIT_WIDTH{1'b0}}, timer_next;
    reg [15:0] sync_id_reg = 16'd0, sync_id_next;
    reg active_reg = 1'b0, active_next;
    reg [1:0] byte_reg = 2'd0, byte_next;
    reg [3:0] bit_reg = 4'd0, bit_next;
    reg gpio_reg = 1'b0, gpio_next;
    reg event_reg = 1'b0, event_next;
    reg [7:0] crc_reg = 8'd0, crc_next;
    reg [15:0] crc_data_reg = 16'd0, crc_data_next;
    reg [4:0] crc_count_reg = 5'd0, crc_count_next;
    reg [7:0] transmit_byte = 8'd0;
    assign stereo_sync_o = gpio_reg;
    assign stereo_sync_id_o = sync_id_reg;
    assign stereo_sync_event_o = event_reg;
    initial begin
        if (SYNC_RATE < 1 || CLK_FREQ % SYNC_RATE != 0 ||
            PULSE_CYCLES % 40 != 0 || BIT_CYCLES < 8 ||
            PULSE_CYCLES + 4 * BIT_CYCLES >= PERIOD_CYCLES) begin
            $error("Invalid absolute-ID sync packet parameters");
            $finish;
        end
    end
    always @* begin
        transmit_byte = 8'ha5;
        case (byte_reg)
            2'd1: transmit_byte = sync_id_reg[15:8];
            2'd2: transmit_byte = sync_id_reg[7:0];
            2'd3: transmit_byte = crc_reg;
            default: transmit_byte = 8'ha5;
        endcase
    end
    always @* begin
        count_next = count_reg + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
        timer_next = timer_reg;
        sync_id_next = sync_id_reg;
        active_next = active_reg;
        byte_next = byte_reg;
        bit_next = bit_reg;
        gpio_next = gpio_reg;
        event_next = 1'b0;
        crc_next = crc_reg;
        crc_data_next = crc_data_reg;
        crc_count_next = crc_count_reg;
        // One CRC bit per clock avoids a long combinational CRC path.
        if (crc_count_reg != 5'd0) begin
            crc_next = (crc_reg >> 1) ^
                       ((crc_reg[0] ^ crc_data_reg[0]) ? 8'h8c : 8'd0);
            crc_data_next = {1'b0, crc_data_reg[15:1]};
            crc_count_next = crc_count_reg - 5'd1;
        end
        if (active_reg) begin
            if (timer_reg == BIT_LAST) begin
                timer_next = {BIT_WIDTH{1'b0}};
                if (bit_reg == 4'd9) begin
                    bit_next = 4'd0;
                    if (byte_reg == 2'd3) begin
                        active_next = 1'b0;
                        gpio_next = 1'b0;
                        // Local and peer select frames only after packet completion.
                        event_next = 1'b1;
                    end else begin
                        byte_next = byte_reg + 2'd1;
                        gpio_next = 1'b1;
                    end
                end else begin
                    bit_next = bit_reg + 4'd1;
                    gpio_next = bit_reg < 4'd8 ? ~transmit_byte[bit_reg] : 1'b0;
                end
            end else timer_next = timer_reg + {{(BIT_WIDTH-1){1'b0}}, 1'b1};
        end
        if (count_reg == PERIOD_LAST) begin
            count_next = {COUNT_WIDTH{1'b0}};
            sync_id_next = sync_id_reg + 16'd1;
            active_next = 1'b1;
            timer_next = {BIT_WIDTH{1'b0}};
            byte_next = 2'd0;
            bit_next = 4'd0;
            gpio_next = 1'b1;
            crc_next = 8'd0;
            crc_data_next = {sync_id_next[7:0], sync_id_next[15:8]};
            crc_count_next = 5'd16;
        end
    end
    always @(posedge clk) begin
        count_reg <= count_next;
        timer_reg <= timer_next;
        sync_id_reg <= sync_id_next;
        active_reg <= active_next;
        byte_reg <= byte_next;
        bit_reg <= bit_next;
        gpio_reg <= gpio_next;
        event_reg <= event_next;
        crc_reg <= crc_next;
        crc_data_reg <= crc_data_next;
        crc_count_reg <= crc_count_next;
        if (rst) begin
            count_reg <= {COUNT_WIDTH{1'b0}};
            timer_reg <= {BIT_WIDTH{1'b0}};
            sync_id_reg <= 16'd0;
            active_reg <= 1'b0;
            byte_reg <= 2'd0;
            bit_reg <= 4'd0;
            gpio_reg <= 1'b0;
            event_reg <= 1'b0;
            crc_reg <= 8'd0;
            crc_data_reg <= 16'd0;
            crc_count_reg <= 5'd0;
        end
    end
endmodule
`resetall
