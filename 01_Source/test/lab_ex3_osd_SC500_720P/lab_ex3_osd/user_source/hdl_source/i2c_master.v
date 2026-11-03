// -----------------------------------------------------------------------------
// File   : i2c_master.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Single-register I2C master with a byte-stream read response. The input
//   clock remains the only clock domain. SDA is always open drain.
//   i_start is accepted only while idle. i_rw=0 writes one register byte;
//   i_rw=1 reads i_read_len bytes after a repeated START (zero means one).
//   o_rd_valid/o_rd_last mark response bytes; o_done is a one-clock pulse.
//   o_ack_error remains set until the next accepted transaction or reset.
//   SCL is push-pull and clock stretching is not supported in this version.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-28  Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module i2c_master #
(
    parameter integer CLK_HZ = 24000000,
    parameter integer I2C_HZ = 100000
)
(
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_start,
    input  wire       i_rw,
    input  wire [6:0] i_dev_addr,
    input  wire [7:0] i_reg_addr,
    input  wire [7:0] i_wr_data,
    input  wire [7:0] i_read_len,
    output reg  [7:0] o_rd_data,
    output reg        o_rd_valid,
    output reg        o_rd_last,
    output reg        o_busy,
    output reg        o_done,
    output reg        o_ack_error,
    inout  wire       io_sda,
    output reg        o_scl
);

    localparam integer QUARTER_CYCLES = CLK_HZ / (I2C_HZ * 4);
    localparam integer COUNTER_WIDTH = (QUARTER_CYCLES < 2) ? 1 : $clog2(QUARTER_CYCLES);
    localparam [COUNTER_WIDTH-1:0] QUARTER_LAST =
        QUARTER_CYCLES[COUNTER_WIDTH-1:0] - 1'b1;
    localparam [3:0] IDLE = 4'd0;
    localparam [3:0] START_HOLD = 4'd1;
    localparam [3:0] START_LOW = 4'd2;
    localparam [3:0] SEND_BIT = 4'd3;
    localparam [3:0] RECEIVE_ACK = 4'd4;
    localparam [3:0] REPEATED_HIGH = 4'd5;
    localparam [3:0] REPEATED_START = 4'd6;
    localparam [3:0] REPEATED_LOW = 4'd7;
    localparam [3:0] RECEIVE_BIT = 4'd8;
    localparam [3:0] SEND_ACK = 4'd9;
    localparam [3:0] STOP_LOW = 4'd10;
    localparam [3:0] STOP_HIGH = 4'd11;
    localparam [3:0] STOP_RELEASE = 4'd12;
    localparam [3:0] REPEATED_RELEASE = 4'd13;
    localparam [3:0] BUS_FREE = 4'd14;

    reg [3:0] state_reg;
    reg [COUNTER_WIDTH-1:0] quarter_count_reg;
    reg [1:0] phase_reg;
    reg [2:0] bit_index_reg;
    reg [1:0] write_stage_reg;
    reg [7:0] transmit_reg;
    reg [7:0] receive_reg;
    reg [7:0] read_remaining_reg;
    reg [6:0] device_addr_reg;
    reg [7:0] register_addr_reg;
    reg [7:0] write_data_reg;
    reg       read_mode_reg;
    reg       sda_drive_low_reg;

    assign io_sda = sda_drive_low_reg ? 1'b0 : 1'bz;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state_reg          <= IDLE;
            quarter_count_reg  <= {COUNTER_WIDTH{1'b0}};
            phase_reg          <= 2'd0;
            bit_index_reg      <= 3'd7;
            write_stage_reg    <= 2'd0;
            transmit_reg       <= 8'd0;
            receive_reg        <= 8'd0;
            read_remaining_reg <= 8'd0;
            device_addr_reg    <= 7'd0;
            register_addr_reg  <= 8'd0;
            write_data_reg     <= 8'd0;
            read_mode_reg      <= 1'b0;
            sda_drive_low_reg  <= 1'b0;
            o_scl              <= 1'b1;
            o_rd_data          <= 8'd0;
            o_rd_valid         <= 1'b0;
            o_rd_last          <= 1'b0;
            o_busy             <= 1'b0;
            o_done             <= 1'b0;
            o_ack_error        <= 1'b0;
        end else begin
            o_done     <= 1'b0;
            o_rd_valid <= 1'b0;
            o_rd_last  <= 1'b0;
            if (state_reg == IDLE) begin
                quarter_count_reg <= {COUNTER_WIDTH{1'b0}};
                if (i_start) begin
                    device_addr_reg    <= i_dev_addr;
                    register_addr_reg  <= i_reg_addr;
                    write_data_reg     <= i_wr_data;
                    read_mode_reg      <= i_rw;
                    read_remaining_reg <= (i_read_len == 8'd0) ? 8'd1 : i_read_len;
                    write_stage_reg    <= 2'd0;
                    transmit_reg       <= {i_dev_addr, 1'b0};
                    o_ack_error        <= 1'b0;
                    o_busy             <= 1'b1;
                    state_reg          <= START_HOLD;
                end
            end else if (quarter_count_reg == QUARTER_LAST) begin
                quarter_count_reg <= {COUNTER_WIDTH{1'b0}};
                case (state_reg)
                    START_HOLD: begin
                        sda_drive_low_reg <= 1'b1;
                        state_reg         <= START_LOW;
                    end
                    START_LOW: begin
                        if (phase_reg == 2'd0) begin
                            phase_reg <= 2'd1;
                        end else begin
                            o_scl         <= 1'b0;
                            phase_reg     <= 2'd0;
                            bit_index_reg <= 3'd7;
                            state_reg     <= SEND_BIT;
                        end
                    end
                    SEND_BIT: begin
                        case (phase_reg)
                            2'd0: sda_drive_low_reg <= ~transmit_reg[bit_index_reg];
                            2'd1: o_scl <= 1'b1;
                            2'd2: begin end
                            2'd3: begin
                                o_scl <= 1'b0;
                                if (bit_index_reg == 3'd0) begin
                                    state_reg <= RECEIVE_ACK;
                                end else begin
                                    bit_index_reg <= bit_index_reg - 3'd1;
                                end
                            end
                        endcase
                        phase_reg <= phase_reg + 2'd1;
                    end
                    RECEIVE_ACK: begin
                        case (phase_reg)
                            2'd0: sda_drive_low_reg <= 1'b0;
                            2'd1: o_scl <= 1'b1;
                            2'd2: begin
                                if (io_sda != 1'b0) o_ack_error <= 1'b1;
                            end
                            2'd3: begin
                                o_scl     <= 1'b0;
                                phase_reg <= 2'd0;
                                if (o_ack_error) begin
                                    state_reg <= STOP_LOW;
                                end else if (write_stage_reg == 2'd0) begin
                                    transmit_reg    <= register_addr_reg;
                                    write_stage_reg <= 2'd1;
                                    bit_index_reg   <= 3'd7;
                                    state_reg       <= SEND_BIT;
                                end else if (write_stage_reg == 2'd1) begin
                                    if (read_mode_reg) begin
                                        state_reg <= REPEATED_RELEASE;
                                    end else begin
                                        transmit_reg    <= write_data_reg;
                                        write_stage_reg <= 2'd2;
                                        bit_index_reg   <= 3'd7;
                                        state_reg       <= SEND_BIT;
                                    end
                                end else if (write_stage_reg == 2'd2) begin
                                    state_reg <= STOP_LOW;
                                end else begin
                                    bit_index_reg <= 3'd7;
                                    state_reg     <= RECEIVE_BIT;
                                end
                            end
                        endcase
                        if (phase_reg != 2'd3) phase_reg <= phase_reg + 2'd1;
                    end
                    REPEATED_RELEASE: begin
                        sda_drive_low_reg <= 1'b0;
                        state_reg         <= REPEATED_HIGH;
                    end
                    REPEATED_HIGH: begin
                        o_scl             <= 1'b1;
                        state_reg         <= REPEATED_START;
                    end
                    REPEATED_START: begin
                        if (phase_reg == 2'd0) begin
                            phase_reg <= 2'd1;
                        end else begin
                            sda_drive_low_reg <= 1'b1;
                            phase_reg         <= 2'd0;
                            state_reg         <= REPEATED_LOW;
                        end
                    end
                    REPEATED_LOW: begin
                        if (phase_reg == 2'd0) begin
                            phase_reg <= 2'd1;
                        end else begin
                            o_scl           <= 1'b0;
                            transmit_reg    <= {device_addr_reg, 1'b1};
                            write_stage_reg <= 2'd3;
                            bit_index_reg   <= 3'd7;
                            phase_reg       <= 2'd0;
                            state_reg       <= SEND_BIT;
                        end
                    end
                    RECEIVE_BIT: begin
                        case (phase_reg)
                            2'd0: sda_drive_low_reg <= 1'b0;
                            2'd1: o_scl <= 1'b1;
                            2'd2: receive_reg[bit_index_reg] <= io_sda;
                            2'd3: begin
                                o_scl <= 1'b0;
                                if (bit_index_reg == 3'd0) begin
                                    o_rd_data <= receive_reg;
                                    state_reg <= SEND_ACK;
                                end else begin
                                    bit_index_reg <= bit_index_reg - 3'd1;
                                end
                            end
                        endcase
                        phase_reg <= phase_reg + 2'd1;
                    end
                    SEND_ACK: begin
                        case (phase_reg)
                            2'd0: sda_drive_low_reg <= (read_remaining_reg != 8'd1);
                            2'd1: o_scl <= 1'b1;
                            2'd2: begin end
                            2'd3: begin
                                o_scl              <= 1'b0;
                                o_rd_valid         <= 1'b1;
                                o_rd_last          <= (read_remaining_reg == 8'd1);
                                read_remaining_reg <= read_remaining_reg - 8'd1;
                                bit_index_reg      <= 3'd7;
                                if (read_remaining_reg == 8'd1) begin
                                    state_reg <= STOP_LOW;
                                end else begin
                                    state_reg <= RECEIVE_BIT;
                                end
                            end
                        endcase
                        phase_reg <= phase_reg + 2'd1;
                    end
                    STOP_LOW: begin
                        sda_drive_low_reg <= 1'b1;
                        state_reg         <= STOP_HIGH;
                    end
                    STOP_HIGH: begin
                        o_scl     <= 1'b1;
                        state_reg <= STOP_RELEASE;
                    end
                    STOP_RELEASE: begin
                        if (phase_reg == 2'd0) begin
                            phase_reg <= 2'd1;
                        end else begin
                            sda_drive_low_reg <= 1'b0;
                            phase_reg         <= 2'd0;
                            state_reg         <= BUS_FREE;
                        end
                    end
                    BUS_FREE: begin
                        if (phase_reg == 2'd0) begin
                            phase_reg <= 2'd1;
                        end else begin
                            phase_reg <= 2'd0;
                            o_busy    <= 1'b0;
                            o_done    <= 1'b1;
                            state_reg <= IDLE;
                        end
                    end
                    default: state_reg <= IDLE;
                endcase
            end else begin
                quarter_count_reg <= quarter_count_reg + 1'b1;
            end
        end
    end
endmodule

`resetall
