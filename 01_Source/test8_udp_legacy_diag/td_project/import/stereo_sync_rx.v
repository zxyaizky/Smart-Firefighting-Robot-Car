// -----------------------------------------------------------------------------
// File   : stereo_sync_rx.v
// Author : Codex
// Date   : 2026-10-03
// Description: Validated absolute sync IDs in the always-running system clock.
// Change Log: 2026-10-03 v2.0 Framing/CRC replace a CSI-clock GPIO edge counter.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_sync_rx #
(
    // Both system clocks are 50 MHz; B default packet interval is 50000/40.
    parameter BIT_CYCLES = 1250
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        stereo_sync_i,
    output wire        stereo_sync_pulse_o,
    output wire [15:0] pending_sync_id_o
);
    // One-hot local FSM. Wire format: A5, ID-high, ID-low, CRC-8/MAXIM.
    // Inverted UART 8N1; idle=0, start=1, data inverted, stop=0.
    localparam [4:0] RX_IDLE = 5'b00001, RX_START = 5'b00010,
                     RX_DATA = 5'b00100, RX_STOP = 5'b01000, RX_TAIL = 5'b10000;
    localparam integer TIMER_WIDTH = $clog2(BIT_CYCLES);
    localparam integer WAIT_WIDTH = $clog2(12 * BIT_CYCLES + 1);
    localparam [TIMER_WIDTH-1:0] BIT_LAST = BIT_CYCLES - 1;
    localparam [TIMER_WIDTH-1:0] HALF_LAST = BIT_CYCLES / 2 - 1;
    localparam [WAIT_WIDTH-1:0] ARM_LAST = 3 * BIT_CYCLES;
    localparam [WAIT_WIDTH-1:0] WAIT_LAST = 12 * BIT_CYCLES;
    (* async_reg = "true" *) reg [1:0] input_sync_reg = 2'b00;
    reg input_delayed_reg = 1'b0;
    reg [4:0] state_reg = RX_IDLE, state_next;
    reg [TIMER_WIDTH-1:0] timer_reg = {TIMER_WIDTH{1'b0}}, timer_next;
    reg [WAIT_WIDTH-1:0] idle_reg = {WAIT_WIDTH{1'b0}}, idle_next;
    reg [WAIT_WIDTH-1:0] wait_reg = {WAIT_WIDTH{1'b0}}, wait_next;
    reg [1:0] byte_reg = 2'd0, byte_next;
    reg [2:0] bit_reg = 3'd0, bit_next;
    reg [7:0] data_reg = 8'd0, data_next;
    reg [15:0] packet_id_reg = 16'd0, packet_id_next;
    reg [7:0] crc_reg = 8'd0, crc_next;
    reg [15:0] sync_id_reg = 16'd0, sync_id_next;
    reg pulse_reg = 1'b0, pulse_next;
    wire rise;
    assign rise = input_sync_reg[1] && !input_delayed_reg;
    assign stereo_sync_pulse_o = pulse_reg;
    assign pending_sync_id_o = sync_id_reg;
    initial begin
        if (BIT_CYCLES < 8 || BIT_CYCLES % 2 != 0) begin
            $error("Invalid absolute-ID sync receiver bit interval");
            $finish;
        end
    end
    always @* begin
        state_next = state_reg;
        timer_next = timer_reg;
        idle_next = idle_reg;
        wait_next = wait_reg;
        byte_next = byte_reg;
        bit_next = bit_reg;
        data_next = data_reg;
        packet_id_next = packet_id_reg;
        crc_next = crc_reg;
        sync_id_next = sync_id_reg;
        pulse_next = 1'b0;
        case (state_reg)
            RX_IDLE: begin
                if (!input_sync_reg[1] && idle_reg < ARM_LAST)
                    idle_next = idle_reg + {{(WAIT_WIDTH-1){1'b0}}, 1'b1};
                if (input_sync_reg[1]) idle_next = {WAIT_WIDTH{1'b0}};
                if (byte_reg != 2'd0) begin
                    if (wait_reg == WAIT_LAST) begin
                        byte_next = 2'd0;
                        idle_next = {WAIT_WIDTH{1'b0}};
                    end else wait_next = wait_reg + {{(WAIT_WIDTH-1){1'b0}}, 1'b1};
                end
                if (rise && ((byte_reg != 2'd0 && wait_reg != WAIT_LAST) ||
                             (byte_reg == 2'd0 && idle_reg == ARM_LAST))) begin
                    state_next = RX_START;
                    timer_next = HALF_LAST;
                    wait_next = {WAIT_WIDTH{1'b0}};
                    idle_next = {WAIT_WIDTH{1'b0}};
                    data_next = 8'd0;
                    bit_next = 3'd0;
                end
            end
            RX_START: begin
                if (timer_reg != {TIMER_WIDTH{1'b0}})
                    timer_next = timer_reg - {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
                else if (input_sync_reg[1]) begin
                    state_next = RX_DATA;
                    timer_next = BIT_LAST;
                end else begin
                    state_next = RX_IDLE;
                    byte_next = 2'd0;
                    idle_next = {WAIT_WIDTH{1'b0}};
                end
            end
            RX_DATA: begin
                if (timer_reg != {TIMER_WIDTH{1'b0}})
                    timer_next = timer_reg - {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
                else begin
                    data_next[bit_reg] = ~input_sync_reg[1];
                    if (byte_reg == 2'd1 || byte_reg == 2'd2)
                        crc_next = (crc_reg >> 1) ^
                                   ((crc_reg[0] ^ ~input_sync_reg[1]) ? 8'h8c : 8'd0);
                    timer_next = BIT_LAST;
                    if (bit_reg == 3'd7) state_next = RX_STOP;
                    else bit_next = bit_reg + 3'd1;
                end
            end
            RX_STOP: begin
                if (timer_reg != {TIMER_WIDTH{1'b0}})
                    timer_next = timer_reg - {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
                else begin
                    state_next = RX_IDLE;
                    wait_next = {WAIT_WIDTH{1'b0}};
                    idle_next = {WAIT_WIDTH{1'b0}};
                    if (input_sync_reg[1]) byte_next = 2'd0;
                    else begin
                        case (byte_reg)
                            2'd0: begin
                                byte_next = data_reg == 8'ha5 ? 2'd1 : 2'd0;
                                crc_next = 8'd0;
                            end
                            2'd1: begin
                                packet_id_next[15:8] = data_reg;
                                byte_next = 2'd2;
                            end
                            2'd2: begin
                                packet_id_next[7:0] = data_reg;
                                byte_next = 2'd3;
                            end
                            2'd3: begin
                                byte_next = 2'd0;
                                if (data_reg == crc_reg) begin
                                    state_next = RX_TAIL;
                                    timer_next = HALF_LAST;
                                end
                            end
                            default: byte_next = 2'd0;
                        endcase
                    end
                end
            end
            RX_TAIL: begin
                if (timer_reg != {TIMER_WIDTH{1'b0}})
                    timer_next = timer_reg - {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
                else begin
                    state_next = RX_IDLE;
                    idle_next = {WAIT_WIDTH{1'b0}};
                    if (!input_sync_reg[1]) begin
                        sync_id_next = packet_id_reg;
                        pulse_next = 1'b1;
                    end
                end
            end
            default: begin
                state_next = RX_IDLE;
                byte_next = 2'd0;
                idle_next = {WAIT_WIDTH{1'b0}};
            end
        endcase
    end
    always @(posedge clk) begin
        // CDC: GPIO -> system clock. Preserve the existing first-flop constraint path.
        input_sync_reg <= {input_sync_reg[0], stereo_sync_i};
        input_delayed_reg <= input_sync_reg[1];
        state_reg <= state_next;
        timer_reg <= timer_next;
        idle_reg <= idle_next;
        wait_reg <= wait_next;
        byte_reg <= byte_next;
        bit_reg <= bit_next;
        data_reg <= data_next;
        packet_id_reg <= packet_id_next;
        crc_reg <= crc_next;
        sync_id_reg <= sync_id_next;
        pulse_reg <= pulse_next;
        if (rst) begin
            input_sync_reg <= 2'b00;
            input_delayed_reg <= 1'b0;
            state_reg <= RX_IDLE;
            timer_reg <= {TIMER_WIDTH{1'b0}};
            idle_reg <= {WAIT_WIDTH{1'b0}};
            wait_reg <= {WAIT_WIDTH{1'b0}};
            byte_reg <= 2'd0;
            bit_reg <= 3'd0;
            data_reg <= 8'd0;
            packet_id_reg <= 16'd0;
            crc_reg <= 8'd0;
            sync_id_reg <= 16'd0;
            pulse_reg <= 1'b0;
        end
    end
endmodule
`resetall
