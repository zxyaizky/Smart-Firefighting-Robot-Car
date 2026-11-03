// -----------------------------------------------------------------------------
// File   : stereo_metadata_fifo.v
// Author : OpenAI Codex
// Date   : 2026-10-02
// -----------------------------------------------------------------------------
// Description:
//   Four-entry Gray-pointer metadata FIFO. No pixel/frame RAM is stored here.
//   One entry accompanies each accepted START token in the separate RGB FIFO.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-02  Codex  v1.0  Stage 2 bounded metadata transport.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_metadata_fifo #
(
    // Width of each FIFO entry
    parameter DATA_WIDTH = 128,
    // FIFO depth is 2**ADDR_WIDTH entries
    parameter ADDR_WIDTH = 2,
    // Free entries reserved for write-side admission margin
    parameter ALMOST_FULL_MARGIN = 1
)
(
    input  wire                  clk_write,
    input  wire                  rst_write,
    input  wire                  clk_read,
    input  wire                  rst_read,
    input  wire [DATA_WIDTH-1:0] write_data_i,
    input  wire                  write_enable_i,
    output wire                  write_full_o,
    output wire                  write_almost_full_o,
    output wire [ADDR_WIDTH:0]   write_level_o,
    output wire                  write_overflow_o,
    output wire [DATA_WIDTH-1:0] read_data_o,
    input  wire                  read_enable_i,
    output wire                  read_valid_o,
    output wire                  read_empty_o,
    output wire [ADDR_WIDTH:0]   read_level_o,
    output wire                  read_underflow_o
);

    localparam FIFO_DEPTH = (1 << ADDR_WIDTH);
    localparam ALMOST_FULL_LEVEL = FIFO_DEPTH - ALMOST_FULL_MARGIN;

    (* ramstyle = "no_rw_check", ram_style = "dram" *)
    reg [DATA_WIDTH-1:0] memory[(2**ADDR_WIDTH)-1:0];

    reg [ADDR_WIDTH:0] write_binary_reg = {(ADDR_WIDTH+1){1'b0}};
    reg [ADDR_WIDTH:0] write_gray_reg = {(ADDR_WIDTH+1){1'b0}};
    reg [ADDR_WIDTH:0] read_binary_reg = {(ADDR_WIDTH+1){1'b0}};
    reg [ADDR_WIDTH:0] read_gray_reg = {(ADDR_WIDTH+1){1'b0}};
    (* async_reg = "true" *)
    reg [ADDR_WIDTH:0] read_gray_write_sync_reg = {(ADDR_WIDTH+1){1'b0}};
    (* async_reg = "true" *)
    reg [ADDR_WIDTH:0] read_gray_write_sync_pipe_reg = {(ADDR_WIDTH+1){1'b0}};
    (* async_reg = "true" *)
    reg [ADDR_WIDTH:0] write_gray_read_sync_reg = {(ADDR_WIDTH+1){1'b0}};
    (* async_reg = "true" *)
    reg [ADDR_WIDTH:0] write_gray_read_sync_pipe_reg = {(ADDR_WIDTH+1){1'b0}};
    reg [DATA_WIDTH-1:0] read_data_reg = {DATA_WIDTH{1'b0}};
    reg read_valid_reg = 1'b0;
    reg write_overflow_reg = 1'b0;
    reg read_underflow_reg = 1'b0;

    wire [ADDR_WIDTH:0] write_binary_next;
    wire [ADDR_WIDTH:0] write_gray_next;
    wire [ADDR_WIDTH:0] read_binary_next;
    wire [ADDR_WIDTH:0] read_gray_next;
    wire [ADDR_WIDTH:0] read_binary_write_sync;
    wire [ADDR_WIDTH:0] write_binary_read_sync;
    wire [ADDR_WIDTH:0] write_level;
    wire [ADDR_WIDTH:0] read_level;
    wire write_full;
    wire read_empty;

    function [ADDR_WIDTH:0] gray_to_binary;
        input [ADDR_WIDTH:0] gray_value;
        integer bit_index;
        begin
            gray_to_binary[ADDR_WIDTH] = gray_value[ADDR_WIDTH];
            for (bit_index = ADDR_WIDTH - 1; bit_index >= 0;
                 bit_index = bit_index - 1) begin
                gray_to_binary[bit_index] = gray_to_binary[bit_index + 1]
                    ^ gray_value[bit_index];
            end
        end
    endfunction

    assign write_binary_next = write_binary_reg + {{ADDR_WIDTH{1'b0}}, 1'b1};
    assign write_gray_next   = (write_binary_next >> 1) ^ write_binary_next;
    assign read_binary_next  = read_binary_reg + {{ADDR_WIDTH{1'b0}}, 1'b1};
    assign read_gray_next    = (read_binary_next >> 1) ^ read_binary_next;
    assign read_binary_write_sync = gray_to_binary(read_gray_write_sync_pipe_reg);
    assign write_binary_read_sync = gray_to_binary(write_gray_read_sync_pipe_reg);
    assign write_level = write_binary_reg - read_binary_write_sync;
    assign read_level  = write_binary_read_sync - read_binary_reg;
    assign write_full = write_gray_next
        == {~read_gray_write_sync_pipe_reg[ADDR_WIDTH:ADDR_WIDTH-1],
            read_gray_write_sync_pipe_reg[ADDR_WIDTH-2:0]};
    assign read_empty = read_gray_reg == write_gray_read_sync_pipe_reg;

    assign write_full_o        = write_full;
    assign write_almost_full_o = write_level >= ALMOST_FULL_LEVEL;
    assign write_level_o       = write_level;
    assign write_overflow_o    = write_overflow_reg;
    assign read_data_o         = read_data_reg;
    assign read_valid_o        = read_valid_reg;
    assign read_empty_o        = read_empty;
    assign read_level_o        = read_level;
    assign read_underflow_o    = read_underflow_reg;

    always @(posedge clk_write) begin
        read_gray_write_sync_reg      <= read_gray_reg;
        read_gray_write_sync_pipe_reg <= read_gray_write_sync_reg;
        write_overflow_reg            <= write_enable_i && write_full;
        if (write_enable_i && !write_full) begin
            memory[write_binary_reg[ADDR_WIDTH-1:0]] <= write_data_i;
            write_binary_reg <= write_binary_next;
            write_gray_reg   <= write_gray_next;
        end

        if (rst_write) begin
            write_binary_reg                <= {(ADDR_WIDTH+1){1'b0}};
            write_gray_reg                  <= {(ADDR_WIDTH+1){1'b0}};
            read_gray_write_sync_reg        <= {(ADDR_WIDTH+1){1'b0}};
            read_gray_write_sync_pipe_reg   <= {(ADDR_WIDTH+1){1'b0}};
            write_overflow_reg              <= 1'b0;
        end
    end

    always @(posedge clk_read) begin
        write_gray_read_sync_reg      <= write_gray_reg;
        write_gray_read_sync_pipe_reg <= write_gray_read_sync_reg;
        read_valid_reg                <= 1'b0;
        read_underflow_reg            <= read_enable_i && read_empty;
        if (read_enable_i && !read_empty) begin
            read_data_reg   <= memory[read_binary_reg[ADDR_WIDTH-1:0]];
            read_valid_reg  <= 1'b1;
            read_binary_reg <= read_binary_next;
            read_gray_reg   <= read_gray_next;
        end

        if (rst_read) begin
            read_binary_reg                 <= {(ADDR_WIDTH+1){1'b0}};
            read_gray_reg                   <= {(ADDR_WIDTH+1){1'b0}};
            write_gray_read_sync_reg        <= {(ADDR_WIDTH+1){1'b0}};
            write_gray_read_sync_pipe_reg   <= {(ADDR_WIDTH+1){1'b0}};
            read_data_reg                   <= {DATA_WIDTH{1'b0}};
            read_valid_reg                  <= 1'b0;
            read_underflow_reg              <= 1'b0;
        end
    end

endmodule

`resetall
