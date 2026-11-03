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

// File: line_buffer_pool.v -- global-coordinate 2x2 stride-2 pooling windows.
// One even row is queued; odd rows consume it. No synthetic end-of-frame flush.
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
    output wire [NUM_CHANNELS*32-1:0] pool_win_flat,
    output wire win_valid,
    output wire [7:0] out_x,
    output wire [7:0] out_y
);
    localparam DATA_WIDTH = NUM_CHANNELS * 8;
    wire [DATA_WIDTH-1:0] fifo_data;
    wire take = data_in_valid && in_x < cfg_width && in_y < cfg_height;
    reg [DATA_WIDTH-1:0] prev_top = 0, prev_bottom = 0;
    reg [DATA_WIDTH*4-1:0] window_reg = 0;
    reg valid_reg = 1'b0;
    reg [7:0] x_reg = 0, y_reg = 0;
    genvar g;
    generate
        for (g = 0; g < DATA_WIDTH / 64; g = g + 1) begin : GEN_POOL_FIFO_SLICE
            sync_fifo_for_linebufferpool u_fifo_pool (
                .clk(clk), .srst(!rst_n || i_clr),
                .we(take && !in_y[0]), .di(data_in[g*64 +: 64]),
                .re(take && in_y[0]), .dout(fifo_data[g*64 +: 64]),
                .empty_flag(), .full_flag()
            );
        end
    endgenerate
    assign pool_win_flat = window_reg;
    assign win_valid = valid_reg;
    assign out_x = x_reg;
    assign out_y = y_reg;
    always @(posedge clk) begin
        valid_reg <= 1'b0;
        if (take && in_y[0]) begin
            prev_top <= fifo_data;
            prev_bottom <= data_in;
            if (in_x[0]) begin
                window_reg <= {data_in, prev_bottom, fifo_data, prev_top};
                x_reg <= in_x;
                y_reg <= in_y;
                valid_reg <= 1'b1;
            end
        end
        if (!rst_n || i_clr) begin
            prev_top <= 0;
            prev_bottom <= 0;
            window_reg <= 0;
            valid_reg <= 0;
            x_reg <= 0;
            y_reg <= 0;
        end
    end
endmodule

`resetall
