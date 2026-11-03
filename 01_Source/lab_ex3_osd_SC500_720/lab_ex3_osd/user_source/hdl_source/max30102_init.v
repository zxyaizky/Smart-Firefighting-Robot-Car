// -----------------------------------------------------------------------------
// File   : max30102_init.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   MAX30102 initialization controller for the existing i2c_master interface.
//   Writes one register per transaction and polls MODE_CONFIG RESET until clear.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-28  Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_init #
(
    parameter integer CLK_HZ = 24000000,
    parameter integer POWER_WAIT_CYCLES = CLK_HZ / 100,
    parameter integer RESET_POLL_CYCLES = CLK_HZ / 1000,
    parameter integer MAX_RESET_POLLS = 20
)
(
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_start,
    output reg        o_init_busy,
    output reg        o_init_done,
    output reg        o_init_error,
    output reg        o_i2c_start,
    output reg        o_i2c_rw,
    output wire [6:0] o_i2c_dev_addr,
    output reg  [7:0] o_i2c_reg_addr,
    output reg  [7:0] o_i2c_wr_data,
    output wire [7:0] o_i2c_read_len,
    input  wire       i_i2c_busy,
    input  wire       i_i2c_done,
    input  wire       i_i2c_ack_error,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0] i_i2c_rd_data,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire       i_i2c_rd_valid,
    input  wire       i_i2c_rd_last
);

    localparam [6:0] DEVICE_ADDR = 7'h57;
    localparam [7:0] REG_FIFO_WR_PTR = 8'h04;
    localparam [7:0] REG_OVF_COUNTER = 8'h05;
    localparam [7:0] REG_FIFO_RD_PTR = 8'h06;
    localparam [7:0] REG_FIFO_CONFIG = 8'h08;
    localparam [7:0] REG_MODE_CONFIG = 8'h09;
    localparam [7:0] REG_SPO2_CONFIG = 8'h0a;
    localparam [7:0] REG_LED1_PA = 8'h0c;
    localparam [7:0] REG_LED2_PA = 8'h0d;

    localparam [7:0] VALUE_RESET = 8'h40;
    localparam [7:0] VALUE_FIFO_CLEAR = 8'h00;
    localparam [7:0] VALUE_FIFO_CONFIG = 8'h0f;
    localparam [7:0] VALUE_SPO2_CONFIG = 8'h27;
    localparam [7:0] VALUE_RED_LED_CURRENT = 8'h24;
    localparam [7:0] VALUE_IR_LED_CURRENT = 8'h24;
    localparam [7:0] VALUE_SPO2_MODE = 8'h03;

    localparam integer WAIT_WIDTH = (POWER_WAIT_CYCLES < 2) ? 1 :
                                    $clog2(POWER_WAIT_CYCLES);
    localparam integer POLL_WIDTH = (MAX_RESET_POLLS < 2) ? 1 :
                                    $clog2(MAX_RESET_POLLS + 1);
    localparam [WAIT_WIDTH-1:0] POWER_WAIT_LAST =
        POWER_WAIT_CYCLES[WAIT_WIDTH-1:0] - 1'b1;
    localparam [WAIT_WIDTH-1:0] RESET_POLL_LAST =
        RESET_POLL_CYCLES[WAIT_WIDTH-1:0] - 1'b1;
    localparam [POLL_WIDTH-1:0] MAX_POLLS = MAX_RESET_POLLS[POLL_WIDTH-1:0];

    localparam [3:0] IDLE = 4'd0;
    localparam [3:0] POWER_WAIT = 4'd1;
    localparam [3:0] WRITE_ISSUE = 4'd2;
    localparam [3:0] WRITE_WAIT_BUSY = 4'd3;
    localparam [3:0] WRITE_WAIT_DONE = 4'd4;
    localparam [3:0] RESET_DELAY = 4'd5;
    localparam [3:0] POLL_ISSUE = 4'd6;
    localparam [3:0] POLL_WAIT_BUSY = 4'd7;
    localparam [3:0] POLL_WAIT_DONE = 4'd8;
    localparam [3:0] DONE = 4'd9;
    localparam [3:0] ERROR = 4'd10;

    reg [3:0] state_reg;
    reg [3:0] command_index_reg;
    reg [WAIT_WIDTH-1:0] wait_count_reg;
    reg [POLL_WIDTH-1:0] poll_count_reg;
    reg poll_data_valid_reg;
    reg poll_reset_set_reg;
    reg [7:0] command_address;
    reg [7:0] command_value;

    assign o_i2c_dev_addr = DEVICE_ADDR;
    assign o_i2c_read_len = 8'd1;

    always @* begin
        command_address = REG_MODE_CONFIG;
        command_value = VALUE_RESET;
        case (command_index_reg)
            4'd0: begin
                command_address = REG_MODE_CONFIG;
                command_value = VALUE_RESET;
            end
            4'd1: begin
                command_address = REG_FIFO_WR_PTR;
                command_value = VALUE_FIFO_CLEAR;
            end
            4'd2: begin
                command_address = REG_OVF_COUNTER;
                command_value = VALUE_FIFO_CLEAR;
            end
            4'd3: begin
                command_address = REG_FIFO_RD_PTR;
                command_value = VALUE_FIFO_CLEAR;
            end
            4'd4: begin
                command_address = REG_FIFO_CONFIG;
                command_value = VALUE_FIFO_CONFIG;
            end
            4'd5: begin
                command_address = REG_SPO2_CONFIG;
                command_value = VALUE_SPO2_CONFIG;
            end
            4'd6: begin
                command_address = REG_LED1_PA;
                command_value = VALUE_RED_LED_CURRENT;
            end
            4'd7: begin
                command_address = REG_LED2_PA;
                command_value = VALUE_IR_LED_CURRENT;
            end
            4'd8: begin
                command_address = REG_MODE_CONFIG;
                command_value = VALUE_SPO2_MODE;
            end
            default: begin
                command_address = REG_MODE_CONFIG;
                command_value = VALUE_RESET;
            end
        endcase
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state_reg          <= IDLE;
            command_index_reg  <= 4'd0;
            wait_count_reg     <= {WAIT_WIDTH{1'b0}};
            poll_count_reg     <= {POLL_WIDTH{1'b0}};
            poll_data_valid_reg <= 1'b0;
            poll_reset_set_reg <= 1'b0;
            o_init_busy        <= 1'b0;
            o_init_done        <= 1'b0;
            o_init_error       <= 1'b0;
            o_i2c_start        <= 1'b0;
            o_i2c_rw           <= 1'b0;
            o_i2c_reg_addr     <= 8'd0;
            o_i2c_wr_data      <= 8'd0;
        end else begin
            o_i2c_start <= 1'b0;
            case (state_reg)
                IDLE: begin
                    if (i_start) begin
                        command_index_reg <= 4'd0;
                        wait_count_reg    <= {WAIT_WIDTH{1'b0}};
                        poll_count_reg    <= {POLL_WIDTH{1'b0}};
                        o_init_busy       <= 1'b1;
                        o_init_done       <= 1'b0;
                        o_init_error      <= 1'b0;
                        state_reg         <= POWER_WAIT;
                    end
                end
                POWER_WAIT: begin
                    if (wait_count_reg == POWER_WAIT_LAST) begin
                        wait_count_reg <= {WAIT_WIDTH{1'b0}};
                        state_reg      <= WRITE_ISSUE;
                    end else begin
                        wait_count_reg <= wait_count_reg + 1'b1;
                    end
                end
                WRITE_ISSUE: begin
                    if (!i_i2c_busy) begin
                        o_i2c_rw       <= 1'b0;
                        o_i2c_reg_addr <= command_address;
                        o_i2c_wr_data  <= command_value;
                        o_i2c_start    <= 1'b1;
                        state_reg      <= WRITE_WAIT_BUSY;
                    end
                end
                WRITE_WAIT_BUSY: begin
                    if (i_i2c_busy) state_reg <= WRITE_WAIT_DONE;
                end
                WRITE_WAIT_DONE: begin
                    if (i_i2c_done) begin
                        if (i_i2c_ack_error) begin
                            o_init_busy  <= 1'b0;
                            o_init_error <= 1'b1;
                            state_reg    <= ERROR;
                        end else if (command_index_reg == 4'd0) begin
                            wait_count_reg <= {WAIT_WIDTH{1'b0}};
                            state_reg      <= RESET_DELAY;
                        end else if (command_index_reg == 4'd8) begin
                            o_init_busy <= 1'b0;
                            o_init_done <= 1'b1;
                            state_reg   <= DONE;
                        end else begin
                            command_index_reg <= command_index_reg + 1'b1;
                            state_reg         <= WRITE_ISSUE;
                        end
                    end
                end
                RESET_DELAY: begin
                    if (wait_count_reg == RESET_POLL_LAST) begin
                        wait_count_reg <= {WAIT_WIDTH{1'b0}};
                        state_reg      <= POLL_ISSUE;
                    end else begin
                        wait_count_reg <= wait_count_reg + 1'b1;
                    end
                end
                POLL_ISSUE: begin
                    if (!i_i2c_busy) begin
                        o_i2c_rw            <= 1'b1;
                        o_i2c_reg_addr      <= REG_MODE_CONFIG;
                        o_i2c_start         <= 1'b1;
                        poll_data_valid_reg <= 1'b0;
                        poll_reset_set_reg  <= 1'b0;
                        poll_count_reg      <= poll_count_reg + 1'b1;
                        state_reg           <= POLL_WAIT_BUSY;
                    end
                end
                POLL_WAIT_BUSY: begin
                    if (i_i2c_busy) state_reg <= POLL_WAIT_DONE;
                end
                POLL_WAIT_DONE: begin
                    if (i_i2c_rd_valid) begin
                        poll_data_valid_reg <= i_i2c_rd_last;
                        poll_reset_set_reg  <= i_i2c_rd_data[6];
                    end
                    if (i_i2c_done) begin
                        if (i_i2c_ack_error || !poll_data_valid_reg) begin
                            o_init_busy  <= 1'b0;
                            o_init_error <= 1'b1;
                            state_reg    <= ERROR;
                        end else if (!poll_reset_set_reg) begin
                            command_index_reg <= 4'd1;
                            state_reg         <= WRITE_ISSUE;
                        end else if (poll_count_reg == MAX_POLLS) begin
                            o_init_busy  <= 1'b0;
                            o_init_error <= 1'b1;
                            state_reg    <= ERROR;
                        end else begin
                            wait_count_reg <= {WAIT_WIDTH{1'b0}};
                            state_reg      <= RESET_DELAY;
                        end
                    end
                end
                DONE: begin
                    state_reg <= DONE;
                end
                ERROR: begin
                    state_reg <= ERROR;
                end
                default: begin
                    o_init_busy  <= 1'b0;
                    o_init_error <= 1'b1;
                    state_reg    <= ERROR;
                end
            endcase
        end
    end
endmodule

`resetall
