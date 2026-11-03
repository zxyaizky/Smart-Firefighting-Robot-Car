// -----------------------------------------------------------------------------
// File   : max30102_sampler.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Polls MAX30102 FIFO status and drains available RED/IR samples through
//   one shared i2c_master interface. Init/ID-check arbitration is external.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_sampler #
(
    parameter integer CLK_HZ = 24000000,
    parameter integer POLL_INTERVAL_MS = 2
)
(
    input  wire        i_clk,
    input  wire        i_rst_n,
    output reg  [17:0] red_raw,
    output reg  [17:0] ir_raw,
    output reg         sample_valid,
    output reg  [31:0] sample_count,
    output reg         error,
    output wire        fifo_overflow,
    output wire [4:0]  fifo_wr_ptr,
    output wire [4:0]  fifo_rd_ptr,
    output wire [4:0]  ovf_counter,
    output wire [5:0]  available_samples,
    output wire        data_available,
    output wire        status_valid,
    output wire        o_i2c_start,
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
    localparam integer POLL_CYCLES = (CLK_HZ / 1000) * POLL_INTERVAL_MS;
    localparam integer POLL_WIDTH = (POLL_CYCLES < 2) ? 1 :
                                    $clog2(POLL_CYCLES);
    localparam [POLL_WIDTH-1:0] POLL_RELOAD =
        POLL_CYCLES[POLL_WIDTH-1:0] - 1'b1;

    localparam [2:0] WAIT_INTERVAL = 3'd0;
    localparam [2:0] START_STATUS  = 3'd1;
    localparam [2:0] WAIT_STATUS   = 3'd2;
    localparam [2:0] START_READER  = 3'd3;
    localparam [2:0] WAIT_READER   = 3'd4;

    reg [2:0] state_reg;
    reg [POLL_WIDTH-1:0] poll_count_reg;
    reg status_start_reg;
    reg reader_start_reg;
    wire status_i2c_start;
    wire status_i2c_rw;
    wire [6:0] status_i2c_dev_addr;
    wire [7:0] status_i2c_reg_addr;
    wire [7:0] status_i2c_wr_data;
    wire [7:0] status_i2c_read_len;
    wire status_done;
    wire status_busy;
    wire status_error;
    wire reader_i2c_start;
    wire reader_i2c_rw;
    wire [6:0] reader_i2c_dev_addr;
    wire [7:0] reader_i2c_reg_addr;
    wire [7:0] reader_i2c_wr_data;
    wire [7:0] reader_i2c_read_len;
    wire reader_done;
    wire reader_busy;
    wire reader_error;
    wire reader_valid;
    wire [17:0] reader_red;
    wire [17:0] reader_ir;
    wire select_reader;

    assign select_reader = (state_reg == START_READER || state_reg == WAIT_READER);
    assign o_i2c_start    = select_reader ? reader_i2c_start : status_i2c_start;
    assign o_i2c_rw       = select_reader ? reader_i2c_rw : status_i2c_rw;
    assign o_i2c_dev_addr = select_reader ? reader_i2c_dev_addr : status_i2c_dev_addr;
    assign o_i2c_reg_addr = select_reader ? reader_i2c_reg_addr : status_i2c_reg_addr;
    assign o_i2c_wr_data  = select_reader ? reader_i2c_wr_data : status_i2c_wr_data;
    assign o_i2c_read_len = select_reader ? reader_i2c_read_len : status_i2c_read_len;

    max30102_fifo_status status_inst (
        .i_clk           (i_clk),
        .i_rst_n         (i_rst_n),
        .i_start         (status_start_reg),
        .fifo_wr_ptr     (fifo_wr_ptr),
        .fifo_rd_ptr     (fifo_rd_ptr),
        .ovf_counter     (ovf_counter),
        .available_samples (available_samples),
        .data_available  (data_available),
        .fifo_overflow   (fifo_overflow),
        .status_valid    (status_valid),
        .busy            (status_busy),
        .done            (status_done),
        .error           (status_error),
        .o_i2c_start     (status_i2c_start),
        .o_i2c_rw        (status_i2c_rw),
        .o_i2c_dev_addr  (status_i2c_dev_addr),
        .o_i2c_reg_addr  (status_i2c_reg_addr),
        .o_i2c_wr_data   (status_i2c_wr_data),
        .o_i2c_read_len  (status_i2c_read_len),
        .i_i2c_busy      (i_i2c_busy),
        .i_i2c_done      (i_i2c_done),
        .i_i2c_ack_error (i_i2c_ack_error),
        .i_i2c_rd_data   (i_i2c_rd_data),
        .i_i2c_rd_valid  (i_i2c_rd_valid),
        .i_i2c_rd_last   (i_i2c_rd_last)
    );

    max30102_fifo_reader reader_inst (
        .i_clk           (i_clk),
        .i_rst_n         (i_rst_n),
        .i_start         (reader_start_reg),
        .red_raw         (reader_red),
        .ir_raw          (reader_ir),
        .sample_valid    (reader_valid),
        .busy            (reader_busy),
        .done            (reader_done),
        .error           (reader_error),
        .o_i2c_start     (reader_i2c_start),
        .o_i2c_rw        (reader_i2c_rw),
        .o_i2c_dev_addr  (reader_i2c_dev_addr),
        .o_i2c_reg_addr  (reader_i2c_reg_addr),
        .o_i2c_wr_data   (reader_i2c_wr_data),
        .o_i2c_read_len  (reader_i2c_read_len),
        .i_i2c_busy      (i_i2c_busy),
        .i_i2c_done      (i_i2c_done),
        .i_i2c_ack_error (i_i2c_ack_error),
        .i_i2c_rd_data   (i_i2c_rd_data),
        .i_i2c_rd_valid  (i_i2c_rd_valid),
        .i_i2c_rd_last   (i_i2c_rd_last)
    );

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state_reg        <= WAIT_INTERVAL;
            poll_count_reg   <= POLL_RELOAD;
            status_start_reg <= 1'b0;
            reader_start_reg <= 1'b0;
            red_raw          <= 18'd0;
            ir_raw           <= 18'd0;
            sample_valid     <= 1'b0;
            sample_count     <= 32'd0;
            error            <= 1'b0;
        end else begin
            status_start_reg <= 1'b0;
            reader_start_reg <= 1'b0;
            sample_valid     <= 1'b0;
            case (state_reg)
                WAIT_INTERVAL: begin
                    if (poll_count_reg == {POLL_WIDTH{1'b0}}) begin
                        state_reg <= START_STATUS;
                    end else begin
                        poll_count_reg <= poll_count_reg - 1'b1;
                    end
                end
                START_STATUS: begin
                    status_start_reg <= 1'b1;
                    state_reg        <= WAIT_STATUS;
                end
                WAIT_STATUS: begin
                    if (status_done && !status_busy) begin
                        if (status_error || !status_valid) begin
                            error          <= 1'b1;
                            poll_count_reg <= POLL_RELOAD;
                            state_reg      <= WAIT_INTERVAL;
                        end else if (data_available) begin
                            state_reg <= START_READER;
                        end else begin
                            poll_count_reg <= POLL_RELOAD;
                            state_reg      <= WAIT_INTERVAL;
                        end
                    end
                end
                START_READER: begin
                    reader_start_reg <= 1'b1;
                    state_reg        <= WAIT_READER;
                end
                WAIT_READER: begin
                    if (reader_done && !reader_busy) begin
                        if (reader_error || !reader_valid) begin
                            error          <= 1'b1;
                            poll_count_reg <= POLL_RELOAD;
                            state_reg      <= WAIT_INTERVAL;
                        end else begin
                            red_raw      <= reader_red;
                            ir_raw       <= reader_ir;
                            sample_valid <= 1'b1;
                            sample_count <= sample_count + 1'b1;
                            // Recheck actual pointers after every sample: new
                            // writes can arrive while the I2C read is running.
                            state_reg <= START_STATUS;
                        end
                    end
                end
                default: state_reg <= WAIT_INTERVAL;
            endcase
        end
    end
endmodule

`resetall
