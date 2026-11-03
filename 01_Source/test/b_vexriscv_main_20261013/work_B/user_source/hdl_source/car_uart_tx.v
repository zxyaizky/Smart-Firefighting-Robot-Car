`timescale 1ns/1ps
// FPGA -> Car-32-4S STM32 USART3 command transmitter.
// Protocol: 9600 baud, 8N1, one binary command byte (0x00..0x07).
module car_uart_tx #(
    parameter integer CLK_HZ    = 50000000,
    parameter integer BAUD_RATE = 9600,
    parameter integer REPEAT_MS = 100
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] cmd_code,
    input  wire       cmd_valid,
    output wire       cmd_ready,
    output reg        uart_tx,
    output wire       busy
);
    // cmd_code: 0=coast stop, 1=forward, 2=backward, 3=left,
    //           4=right, 5=brake, 6=speed +1%, 7=speed -1%.
    // A command is accepted only when cmd_valid && cmd_ready. Keep cmd_valid
    // asserted until then; a one-cycle pulse while !cmd_ready is not stored.

    function integer clog2;
        input integer value;
        begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1)
                value = value >> 1;
        end
    endfunction

    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer REPEAT_CYCLES = (CLK_HZ / 1000) * REPEAT_MS;
    localparam integer BAUD_W = (CLKS_PER_BIT < 2) ? 1 : clog2(CLKS_PER_BIT);
    localparam integer REPEAT_W = (REPEAT_CYCLES < 2) ? 1 : clog2(REPEAT_CYCLES);
    localparam [BAUD_W-1:0] LAST_BAUD = CLKS_PER_BIT[BAUD_W-1:0] - 1'b1;
    localparam [REPEAT_W-1:0] LAST_REPEAT = REPEAT_CYCLES[REPEAT_W-1:0] - 1'b1;

    localparam [1:0] TX_IDLE  = 2'd0;
    localparam [1:0] TX_START = 2'd1;
    localparam [1:0] TX_DATA  = 2'd2;
    localparam [1:0] TX_STOP  = 2'd3;

    reg [1:0] tx_state;
    reg [BAUD_W-1:0] baud_count;
    reg [REPEAT_W-1:0] repeat_count;
    reg [2:0] bit_index;
    reg [7:0] shift_data;
    reg [7:0] pending_byte;
    reg       pending_valid;
    reg [2:0] motion_code; // Zero means no motion to repeat.

    assign cmd_ready = !pending_valid;
    assign busy = pending_valid || (tx_state != TX_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx       <= 1'b1;
            tx_state      <= TX_IDLE;
            baud_count    <= {BAUD_W{1'b0}};
            repeat_count  <= {REPEAT_W{1'b0}};
            bit_index     <= 3'd0;
            shift_data    <= 8'd0;
            pending_byte  <= 8'd0;
            pending_valid <= 1'b0;
            motion_code   <= 3'd0;
        end else begin
            // UART sends one full start/data/stop frame at a time.
            case (tx_state)
                TX_IDLE: begin
                    uart_tx <= 1'b1;
                    baud_count <= {BAUD_W{1'b0}};
                    if (pending_valid) begin
                        shift_data <= pending_byte;
                        pending_valid <= 1'b0;
                        bit_index <= 3'd0;
                        uart_tx <= 1'b0;
                        tx_state <= TX_START;
                    end
                end
                TX_START: begin
                    if (baud_count == LAST_BAUD) begin
                        baud_count <= {BAUD_W{1'b0}};
                        uart_tx <= shift_data[0];
                        shift_data <= {1'b0, shift_data[7:1]};
                        tx_state <= TX_DATA;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                TX_DATA: begin
                    if (baud_count == LAST_BAUD) begin
                        baud_count <= {BAUD_W{1'b0}};
                        if (bit_index == 3'd7) begin
                            uart_tx <= 1'b1;
                            tx_state <= TX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            uart_tx <= shift_data[0];
                            shift_data <= {1'b0, shift_data[7:1]};
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                TX_STOP: begin
                    if (baud_count == LAST_BAUD) begin
                        baud_count <= {BAUD_W{1'b0}};
                        tx_state <= TX_IDLE;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                default: tx_state <= TX_IDLE;
            endcase

            // Explicit commands take priority over the periodic repeat.
            if (cmd_valid && cmd_ready) begin
                pending_byte <= {5'd0, cmd_code};
                pending_valid <= 1'b1;
                if (cmd_code >= 3'd1 && cmd_code <= 3'd4) begin
                    motion_code <= cmd_code;
                    repeat_count <= {REPEAT_W{1'b0}};
                end else if (cmd_code == 3'd0 || cmd_code == 3'd5) begin
                    motion_code <= 3'd0;
                    repeat_count <= {REPEAT_W{1'b0}};
                end
                // Speed commands are one-shot; movement remains active.
            end else if (motion_code != 3'd0) begin
                if (repeat_count == LAST_REPEAT) begin
                    if (!pending_valid) begin
                        pending_byte <= {5'd0, motion_code};
                        pending_valid <= 1'b1;
                        repeat_count <= {REPEAT_W{1'b0}};
                    end
                end else begin
                    repeat_count <= repeat_count + 1'b1;
                end
            end
        end
    end
endmodule
