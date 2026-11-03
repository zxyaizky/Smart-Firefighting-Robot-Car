// -----------------------------------------------------------------------------
// File   : line_buffer_conv.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Generate global-coordinate tile windows with native Anlogic row FIFOs.
// Change Log:
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// File: line_buffer_conv.v -- tiled raster windows using native show-ahead FIFOs.
// Input is the padded halo rectangle supplied by BCU, in raster order per Cin.
// cfg_width/height remain the FULL input surface; output coordinates are global.
`timescale 1ns/1ps
module line_buffer_conv #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 512
)(
    input wire clk,
    input wire rst_n,
    input wire i_clr,
    input wire [7:0] cfg_width,
    input wire [7:0] cfg_height,
    input wire [7:0] cfg_tile_y_base,
    input wire [7:0] cfg_tile_rows,
    input wire [1:0] kernel_size,
    input wire padding_en,
    input wire is_last_cin,
    input wire [DATA_WIDTH-1:0] data_in,
    input wire data_in_valid,
    output wire [DATA_WIDTH*9-1:0] win_out_flat,
    output wire win_valid,
    output wire [7:0] out_x,
    output wire [7:0] out_y,
    output wire o_busy
);
    wire [8:0] span = kernel_size == 2'b00 ? 9'd0 :
                      (kernel_size == 2'b01 ? 9'd1 : 9'd2);
    wire [8:0] scan_w = {1'b0, cfg_width} +
                        ((padding_en && kernel_size != 2'b00) ? 9'd2 : 9'd0);
    wire [8:0] scan_h = {1'b0, cfg_tile_rows} + span;
    reg [8:0] x_reg = 9'd0, y_reg = 9'd0;
    reg end_reg = 1'b0, valid_reg = 1'b0;
    reg [7:0] out_x_reg = 8'd0, out_y_reg = 8'd0;
    reg [DATA_WIDTH*9-1:0] window_reg = 0;
    reg [DATA_WIDTH-1:0] top_left = 0, top_mid = 0;
    reg [DATA_WIDTH-1:0] mid_left = 0, mid_mid = 0;
    reg [DATA_WIDTH-1:0] bot_left = 0, bot_mid = 0;
    wire row1_read = data_in_valid && y_reg >= 1 && kernel_size != 2'b00;
    wire row0_read = data_in_valid && y_reg >= 2 && kernel_size == 2'b10;
    wire [7:0] row1_data, row0_data;
    wire clear_fifo = !rst_n || i_clr || end_reg;
    wire sample_end = data_in_valid && x_reg == scan_w - 1 && y_reg == scan_h - 1;

    al_fifo_npu_8x512 u_fifo_row1 (
        .clk(clk), .srst(clear_fifo), .di(data_in),
        .we(data_in_valid && kernel_size != 2'b00), .re(row1_read),
        .dout(row1_data), .empty_flag(), .full_flag()
    );
    al_fifo_npu_8x512 u_fifo_row0 (
        .clk(clk), .srst(clear_fifo), .di(row1_data),
        .we(row1_read && kernel_size == 2'b10), .re(row0_read),
        .dout(row0_data), .empty_flag(), .full_flag()
    );
    assign win_out_flat = window_reg;
    assign win_valid = valid_reg;
    assign out_x = out_x_reg;
    assign out_y = out_y_reg;
    assign o_busy = data_in_valid || valid_reg || end_reg;

    always @(posedge clk) begin
        end_reg <= sample_end;
        valid_reg <= 1'b0;
        if (data_in_valid) begin
            top_left <= top_mid;
            top_mid <= row0_data;
            mid_left <= mid_mid;
            mid_mid <= row1_data;
            bot_left <= bot_mid;
            bot_mid <= data_in;
            if (x_reg >= span && y_reg >= span) begin
                valid_reg <= 1'b1;
                out_x_reg <= x_reg - span;
                out_y_reg <= cfg_tile_y_base + y_reg - span;
                case (kernel_size)
                    2'b00: window_reg <= {32'd0, data_in, 32'd0};
                    2'b01: window_reg <= {32'd0, data_in, bot_mid, 8'd0,
                                         row1_data, mid_mid};
                    default: window_reg <= {data_in, bot_mid, bot_left,
                                             row1_data, mid_mid, mid_left,
                                             row0_data, top_mid, top_left};
                endcase
            end
            if (x_reg == scan_w - 1) begin
                x_reg <= 9'd0;
                y_reg <= sample_end ? 9'd0 : y_reg + 9'd1;
            end else x_reg <= x_reg + 9'd1;
        end
        if (!rst_n || i_clr) begin
            x_reg <= 0;
            y_reg <= 0;
            end_reg <= 0;
            valid_reg <= 0;
            out_x_reg <= 0;
            out_y_reg <= 0;
            window_reg <= 0;
            top_left <= 0; top_mid <= 0;
            mid_left <= 0; mid_mid <= 0;
            bot_left <= 0; bot_mid <= 0;
        end
    end
endmodule

`resetall
