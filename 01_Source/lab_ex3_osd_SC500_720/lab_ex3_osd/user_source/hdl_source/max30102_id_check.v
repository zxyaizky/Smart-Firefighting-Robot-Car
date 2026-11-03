// -----------------------------------------------------------------------------
// File   : max30102_id_check.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Reads MAX30102 PART_ID through the existing i2c_master byte-read interface.
//   A wrong ID is distinct from an I2C or response-format error.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-28  Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_id_check
(
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_start,
    output reg  [7:0] part_id,
    output reg        check_done,
    output reg        device_ok,
    output reg        check_error,
    output reg        o_i2c_start,
    output wire       o_i2c_rw,
    output wire [6:0] o_i2c_dev_addr,
    output wire [7:0] o_i2c_reg_addr,
    output wire [7:0] o_i2c_wr_data,
    output wire [7:0] o_i2c_read_len,
    input  wire       i_i2c_busy,
    input  wire       i_i2c_done,
    input  wire       i_i2c_ack_error,
    input  wire [7:0] i_i2c_rd_data,
    input  wire       i_i2c_rd_valid,
    input  wire       i_i2c_rd_last
);

    localparam [6:0] DEVICE_ADDR = 7'h57;
    localparam [7:0] REG_PART_ID = 8'hff;
    localparam [7:0] EXPECTED_PART_ID = 8'h15;

    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] ISSUE_READ = 2'd1;
    localparam [1:0] WAIT_BUSY = 2'd2;
    localparam [1:0] WAIT_DONE = 2'd3;

    reg [1:0] state_reg;
    reg       data_seen_reg;
    reg       data_last_reg;

    assign o_i2c_rw       = 1'b1;
    assign o_i2c_dev_addr = DEVICE_ADDR;
    assign o_i2c_reg_addr = REG_PART_ID;
    assign o_i2c_wr_data  = 8'd0;
    assign o_i2c_read_len = 8'd1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state_reg       <= IDLE;
            data_seen_reg   <= 1'b0;
            data_last_reg   <= 1'b0;
            part_id         <= 8'd0;
            check_done      <= 1'b0;
            device_ok       <= 1'b0;
            check_error     <= 1'b0;
            o_i2c_start     <= 1'b0;
        end else begin
            o_i2c_start <= 1'b0;
            case (state_reg)
                IDLE: begin
                    if (i_start) begin
                        part_id       <= 8'd0;
                        check_done    <= 1'b0;
                        device_ok     <= 1'b0;
                        check_error   <= 1'b0;
                        data_seen_reg <= 1'b0;
                        data_last_reg <= 1'b0;
                        state_reg     <= ISSUE_READ;
                    end
                end
                ISSUE_READ: begin
                    if (!i_i2c_busy) begin
                        o_i2c_start <= 1'b1;
                        state_reg   <= WAIT_BUSY;
                    end
                end
                WAIT_BUSY: begin
                    if (i_i2c_busy) state_reg <= WAIT_DONE;
                end
                WAIT_DONE: begin
                    if (i_i2c_rd_valid && !data_seen_reg) begin
                        part_id       <= i_i2c_rd_data;
                        data_seen_reg <= 1'b1;
                        data_last_reg <= i_i2c_rd_last;
                    end
                    if (i_i2c_done) begin
                        check_done <= 1'b1;
                        if (i_i2c_ack_error || !data_seen_reg || !data_last_reg) begin
                            check_error <= 1'b1;
                            device_ok   <= 1'b0;
                        end else begin
                            check_error <= 1'b0;
                            device_ok   <= (part_id == EXPECTED_PART_ID);
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
