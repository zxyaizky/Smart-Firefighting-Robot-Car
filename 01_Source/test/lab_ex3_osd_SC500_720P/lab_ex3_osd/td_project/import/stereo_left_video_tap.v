// -----------------------------------------------------------------------------
// File   : stereo_left_video_tap.v
// Author : Codex
// Date   : 2026-10-02
// Description: Align VTC control with the two-register video_out RGB pipeline.
// Change Log: 2026-10-02 v1.0 Stage 3 passive clean-video control tap.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_left_video_tap
(
    input  wire clk,
    input  wire rst,
    input  wire read_enable_i,
    input  wire frame_user_i,
    input  wire line_last_i,
    input  wire vsync_i,
    output wire frame_start_o,
    output wire pixel_valid_o,
    output wire line_end_o,
    output wire frame_end_o
);
    reg [1:0] valid_pipe_reg = 2'b00;
    reg [1:0] user_pipe_reg = 2'b00;
    reg [1:0] last_pipe_reg = 2'b00;
    reg [1:0] vsync_pipe_reg = 2'b00;
    reg vsync_d_reg = 1'b0;
    reg [9:0] row_reg = 10'd0, row_next;
    assign frame_start_o = user_pipe_reg[1];
    assign pixel_valid_o = valid_pipe_reg[1];
    assign line_end_o = last_pipe_reg[1];
    // The normal EOF coincides with the final active pixel. VS is a fallback
    // boundary: a source with missing lines/markers must still be terminated.
    assign frame_end_o = (last_pipe_reg[1] && row_reg == 10'd719) ||
                         (vsync_pipe_reg[1] && !vsync_d_reg);
    always @* begin
        row_next = row_reg;
        if (user_pipe_reg[1]) row_next = 10'd0;
        if (last_pipe_reg[1]) row_next = row_reg + 10'd1;
    end
    always @(posedge clk) begin
        valid_pipe_reg <= {valid_pipe_reg[0], read_enable_i};
        user_pipe_reg <= {user_pipe_reg[0], frame_user_i};
        last_pipe_reg <= {last_pipe_reg[0], line_last_i};
        vsync_pipe_reg <= {vsync_pipe_reg[0], vsync_i};
        vsync_d_reg <= vsync_pipe_reg[1];
        row_reg <= row_next;
        if (rst) begin
            valid_pipe_reg <= 2'b00;
            user_pipe_reg <= 2'b00;
            last_pipe_reg <= 2'b00;
            vsync_pipe_reg <= 2'b00;
            vsync_d_reg <= 1'b0;
            row_reg <= 10'd0;
        end
    end
endmodule
`resetall
