// -----------------------------------------------------------------------------
// File   : max30102_fifo_status.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Burst-reads FIFO_WR_PTR, OVF_COUNTER, FIFO_RD_PTR (0x04..0x06).
//   The modulo-32 pointer difference represents 0..31 unread samples under
//   the normal, non-full FIFO assumption. A full 32 samples is ambiguous.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_fifo_status
(
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_start,
    output reg  [4:0] fifo_wr_ptr,
    output reg  [4:0] fifo_rd_ptr,
    output reg  [4:0] ovf_counter,
    output reg  [5:0] available_samples,
    output reg        data_available,
    output reg        fifo_overflow,
    output reg        status_valid,
    output reg        busy,
    output reg        done,
    output reg        error,
    output reg        o_i2c_start,
    output wire       o_i2c_rw,
    output wire [6:0] o_i2c_dev_addr,
    output wire [7:0] o_i2c_reg_addr,
    output wire [7:0] o_i2c_wr_data,
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
    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] ISSUE_READ = 2'd1;
    localparam [1:0] WAIT_BUSY = 2'd2;
    localparam [1:0] READ_BYTES = 2'd3;

    reg [1:0] state_reg;
    reg [2:0] byte_count_reg;
    reg       format_error_reg;
    reg [4:0] wr_temp_reg;
    reg [4:0] ovf_temp_reg;
    reg [4:0] rd_temp_reg;
    wire [4:0] pointer_difference;

    assign o_i2c_rw       = 1'b1;
    assign o_i2c_dev_addr = 7'h57;
    assign o_i2c_reg_addr = 8'h04;
    assign o_i2c_wr_data  = 8'd0;
    assign o_i2c_read_len = 8'd3;
    assign pointer_difference = wr_temp_reg - rd_temp_reg;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state_reg         <= IDLE;
            byte_count_reg    <= 3'd0;
            format_error_reg  <= 1'b0;
            wr_temp_reg       <= 5'd0;
            ovf_temp_reg      <= 5'd0;
            rd_temp_reg       <= 5'd0;
            fifo_wr_ptr       <= 5'd0;
            fifo_rd_ptr       <= 5'd0;
            ovf_counter       <= 5'd0;
            available_samples <= 6'd0;
            data_available    <= 1'b0;
            fifo_overflow     <= 1'b0;
            status_valid      <= 1'b0;
            busy              <= 1'b0;
            done              <= 1'b0;
            error             <= 1'b0;
            o_i2c_start       <= 1'b0;
        end else begin
            status_valid <= 1'b0;
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
                        if (byte_count_reg < 3'd3) begin
                            byte_count_reg <= byte_count_reg + 1'b1;
                            case (byte_count_reg)
                                3'd0: wr_temp_reg  <= i_i2c_rd_data[4:0];
                                3'd1: ovf_temp_reg <= i_i2c_rd_data[4:0];
                                3'd2: rd_temp_reg  <= i_i2c_rd_data[4:0];
                                default: format_error_reg <= 1'b1;
                            endcase
                        end else begin
                            format_error_reg <= 1'b1;
                        end
                        if (i_i2c_rd_last != (byte_count_reg == 3'd2))
                            format_error_reg <= 1'b1;
                    end
                    if (i_i2c_done) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        if (i_i2c_ack_error || format_error_reg ||
                            byte_count_reg != 3'd3 || i_i2c_rd_valid) begin
                            error <= 1'b1;
                        end else begin
                            fifo_wr_ptr       <= wr_temp_reg;
                            fifo_rd_ptr       <= rd_temp_reg;
                            ovf_counter       <= ovf_temp_reg;
                            available_samples <= {1'b0, pointer_difference};
                            data_available    <= (pointer_difference != 5'd0);
                            if (ovf_temp_reg != 5'd0) fifo_overflow <= 1'b1;
                            status_valid <= 1'b1;
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
