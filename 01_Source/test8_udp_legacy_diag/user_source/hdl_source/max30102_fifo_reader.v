// -----------------------------------------------------------------------------
// File   : max30102_fifo_reader.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Reads one six-byte RED/IR sample from MAX30102 FIFO_DATA using the
//   existing i2c_master byte-stream interface. The caller ensures FIFO data
//   is available before asserting i_start.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-28  Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_fifo_reader
(
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_start,
    output reg  [17:0] red_raw,
    output reg  [17:0] ir_raw,
    output reg         sample_valid,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg         o_i2c_start,
    output wire        o_i2c_rw,
    output wire [6:0]  o_i2c_dev_addr,
    output wire [7:0]  o_i2c_reg_addr,
    output wire [7:0]  o_i2c_wr_data,
    output wire [7:0]  o_i2c_read_len,
    input  wire        i_i2c_busy,
    input  wire        i_i2c_done,
    input  wire        i_i2c_ack_error,
    input  wire [7:0]  i_i2c_rd_data,
    input  wire        i_i2c_rd_valid,
    input  wire        i_i2c_rd_last
);
    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] ISSUE_READ = 2'd1;
    localparam [1:0] WAIT_BUSY = 2'd2;
    localparam [1:0] READ_BYTES = 2'd3;

    reg [1:0] state_reg;
    reg [2:0] byte_count_reg;
    reg       format_error_reg;
    reg [1:0] byte0_reg;
    reg [7:0] byte1_reg;
    reg [7:0] byte2_reg;
    reg [1:0] byte3_reg;
    reg [7:0] byte4_reg;
    reg [7:0] byte5_reg;

    assign o_i2c_rw       = 1'b1;
    assign o_i2c_dev_addr = 7'h57;
    assign o_i2c_reg_addr = 8'h07;
    assign o_i2c_wr_data  = 8'd0;
    assign o_i2c_read_len = 8'd6;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state_reg        <= IDLE;
            byte_count_reg   <= 3'd0;
            format_error_reg <= 1'b0;
            byte0_reg        <= 2'd0;
            byte1_reg        <= 8'd0;
            byte2_reg        <= 8'd0;
            byte3_reg        <= 2'd0;
            byte4_reg        <= 8'd0;
            byte5_reg        <= 8'd0;
            red_raw          <= 18'd0;
            ir_raw           <= 18'd0;
            sample_valid     <= 1'b0;
            busy             <= 1'b0;
            done             <= 1'b0;
            error            <= 1'b0;
            o_i2c_start      <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            done         <= 1'b0;
            o_i2c_start  <= 1'b0;
            case (state_reg)
                IDLE: begin
                    if (i_start) begin
                        byte_count_reg   <= 3'd0;
                        format_error_reg <= 1'b0;
                        error            <= 1'b0;
                        busy             <= 1'b1;
                        state_reg        <= ISSUE_READ;
                    end
                end
                ISSUE_READ: begin
                    if (!i_i2c_busy) begin
                        o_i2c_start <= 1'b1;
                        state_reg   <= WAIT_BUSY;
                    end
                end
                WAIT_BUSY: begin
                    if (i_i2c_busy) state_reg <= READ_BYTES;
                end
                READ_BYTES: begin
                    if (i_i2c_rd_valid) begin
                        // Saturate at six, so unexpected extra bytes cannot
                        // wrap the counter and overwrite the first byte.
                        if (byte_count_reg < 3'd6) begin
                            byte_count_reg <= byte_count_reg + 1'b1;
                            case (byte_count_reg)
                                3'd0: byte0_reg <= i_i2c_rd_data[1:0];
                                3'd1: byte1_reg <= i_i2c_rd_data;
                                3'd2: byte2_reg <= i_i2c_rd_data;
                                3'd3: byte3_reg <= i_i2c_rd_data[1:0];
                                3'd4: byte4_reg <= i_i2c_rd_data;
                                3'd5: byte5_reg <= i_i2c_rd_data;
                                default: format_error_reg <= 1'b1;
                            endcase
                        end else begin
                            format_error_reg <= 1'b1;
                        end
                        if (i_i2c_rd_last != (byte_count_reg == 3'd5))
                            format_error_reg <= 1'b1;
                    end
                    if (i_i2c_done) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        if (i_i2c_ack_error || format_error_reg ||
                            byte_count_reg != 3'd6 || i_i2c_rd_valid) begin
                            error <= 1'b1;
                        end else begin
                            // FIFO_DATA[23:18] is unused for each channel.
                            red_raw      <= {byte0_reg, byte1_reg, byte2_reg};
                            ir_raw       <= {byte3_reg, byte4_reg, byte5_reg};
                            sample_valid <= 1'b1;
                        end
                        state_reg <= IDLE;
                    end
                end
                default: state_reg <= IDLE;
            endcase
        end
    end
endmodule

`resetall
