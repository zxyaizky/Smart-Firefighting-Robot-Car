// -----------------------------------------------------------------------------
// File   : line_buffer_pool.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Build stride-two pool windows from global coordinates and native FIFOs.
// Change Log:
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// File: line_buffer_pool.v -- global-coordinate 2x2 stride-2 pooling.
// One even row is queued; odd rows consume it.  Max reduction is performed at
// the row-buffer output so a 512-bit window register and a separate two-stage
// pool pipeline are unnecessary.
`timescale 1ns/1ps
module line_buffer_pool #(
    parameter NUM_CHANNELS = 16,
    parameter FIFO_DEPTH = 512
)(
    input wire clk,
    input wire rst_n,
    input wire i_clr,
    input wire [7:0] cfg_width,
    input wire [7:0] cfg_height,
    input wire [7:0] in_x,
    input wire [7:0] in_y,
    input wire [NUM_CHANNELS*8-1:0] data_in,
    input wire data_in_valid,
    output wire [NUM_CHANNELS*8-1:0] pool_data_out,
    output wire pool_valid,
    output wire [7:0] out_x,
    output wire [7:0] out_y
);
    localparam DATA_WIDTH = NUM_CHANNELS * 8;
    wire take = data_in_valid && in_x < cfg_width && in_y < cfg_height;
    // Max pooling is associative. Store one horizontal maximum per pair
    // instead of both raw top-row pixels. The input scan visits x in order;
    // valid gaps are permitted, and the output still occurs on each odd x.
    // This halves the distributed row RAM without changing output latency.
    reg [DATA_WIDTH-1:0] row_mem [0:79]; // synthesis ram_style=dram
    wire [DATA_WIDTH-1:0] top_data = row_mem[in_x[7:1]];
    reg [DATA_WIDTH-1:0] prev_even = 0, prev_bottom = 0;
    wire [DATA_WIDTH-1:0] even_pair_max;
    reg [DATA_WIDTH-1:0] pool_data_reg = 0;
    reg valid_reg = 1'b0;
    reg [7:0] x_reg = 0, y_reg = 0;
    wire [DATA_WIDTH-1:0] pool_comb;
    assign pool_data_out = pool_data_reg;
    assign pool_valid = valid_reg;
    assign out_x = x_reg;
    assign out_y = y_reg;

    genvar ch;
    generate
        for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin : G_POOL_MAX
            wire [7:0] top_max;
            wire [7:0] bottom_max;
            wire [7:0] window_max;
            assign top_max = top_data[ch*8 +: 8];
            assign even_pair_max[ch*8 +: 8] =
                (prev_even[ch*8 +: 8] > data_in[ch*8 +: 8])
                ? prev_even[ch*8 +: 8] : data_in[ch*8 +: 8];
            assign bottom_max = (prev_bottom[ch*8 +: 8] > data_in[ch*8 +: 8])
                              ? prev_bottom[ch*8 +: 8] : data_in[ch*8 +: 8];
            assign window_max = (top_max > bottom_max) ? top_max : bottom_max;
            assign pool_comb[ch*8 +: 8] = window_max;
        end
    endgenerate

    always @(posedge clk) begin
        valid_reg <= 1'b0;
        if (take && !in_y[0]) begin
            prev_even <= data_in;
            if (in_x[0]) row_mem[in_x[7:1]] <= even_pair_max;
        end
        if (take && in_y[0]) begin
            prev_bottom <= data_in;
            if (in_x[0]) begin
                pool_data_reg <= pool_comb;
                x_reg <= in_x >> 1;
                y_reg <= in_y >> 1;
                valid_reg <= 1'b1;
            end
        end
        if (!rst_n || i_clr) begin
            prev_even <= 0;
            prev_bottom <= 0;
            pool_data_reg <= 0;
            valid_reg <= 0;
            x_reg <= 0;
            y_reg <= 0;
        end
    end
endmodule

`resetall
