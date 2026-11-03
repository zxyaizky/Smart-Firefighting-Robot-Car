// -----------------------------------------------------------------------------
// File   : ethernet_video_sampler.v
// Author : Codex
// Date   : 2026-10-22
// Description:
//   Sample the clean 1280x720 raster at (2*x,2*y), independently of NPU input.
//   A clock-based token admits at most 30 frames/s on the 75 MHz video clock.
// Change Log:
//   2026-10-22  Codex  v1.0  640x360 RGB stream with atomic source metadata.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module ethernet_video_sampler #
(
    // Actual video clock, independent of the raster refresh rate.
    parameter integer CLOCK_HZ = 75000000,
    // Maximum transmitted frames per second; a slower source is not duplicated.
    parameter integer FRAME_RATE = 30
)
(
    input  wire         clk,
    input  wire         rst,
    input  wire         vsync_i,
    input  wire         read_enable_i,
    input  wire [23:0]  rgb_i,
    input  wire         metadata_valid_i,
    input  wire [127:0] metadata_i,
    output wire         frame_start_o,
    output wire         pixel_valid_o,
    output wire [23:0]  pixel_rgb_o,
    output wire         frame_end_o,
    output wire         frame_abort_o,
    output wire [127:0] frame_metadata_o
);
    localparam integer FRAME_CLOCKS = CLOCK_HZ / FRAME_RATE;
    localparam integer TIMER_WIDTH = $clog2(FRAME_CLOCKS);
    reg [TIMER_WIDTH-1:0] timer_reg = {TIMER_WIDTH{1'b0}};
    reg credit_reg = 1'b1;
    reg [1:0] valid_pipe_reg = 2'b00;
    reg vsync_reg = 1'b0;
    reg armed_reg = 1'b0;
    reg active_reg = 1'b0;
    reg [10:0] x_reg = 11'd0;
    reg [9:0] y_reg = 10'd0;
    reg [17:0] count_reg = 18'd0;
    reg first_pixel_reg = 1'b0;
    reg [23:0] first_rgb_reg = 24'd0;
    reg start_reg = 1'b0;
    reg valid_reg = 1'b0;
    reg [23:0] rgb_reg = 24'd0;
    reg end_reg = 1'b0;
    reg abort_reg = 1'b0;
    reg [127:0] metadata_reg = 128'd0;
    wire start_frame;
    assign start_frame = armed_reg && valid_pipe_reg[1] && metadata_valid_i;
    assign frame_start_o = start_reg;
    assign pixel_valid_o = valid_reg;
    assign pixel_rgb_o = rgb_reg;
    assign frame_end_o = end_reg;
    assign frame_abort_o = abort_reg;
    assign frame_metadata_o = metadata_reg;

    // read_enable precedes the registered video_out RGB by two clocks.
    always @(posedge clk) begin
        valid_pipe_reg <= {valid_pipe_reg[0], read_enable_i};
        vsync_reg <= vsync_i;
        start_reg <= 1'b0;
        valid_reg <= first_pixel_reg;
        end_reg <= 1'b0;
        abort_reg <= 1'b0;
        first_pixel_reg <= 1'b0;
        if (first_pixel_reg) rgb_reg <= first_rgb_reg;
        if (timer_reg == FRAME_CLOCKS - 1) begin
            timer_reg <= {TIMER_WIDTH{1'b0}};
            credit_reg <= 1'b1;
        end else begin
            timer_reg <= timer_reg + 1'b1;
        end
        if (vsync_i && !vsync_reg) begin
            armed_reg <= 1'b1;
            if (active_reg) abort_reg <= 1'b1;
            active_reg <= 1'b0;
        end
        if (start_frame) begin
            armed_reg <= 1'b0;
            if (credit_reg) begin
                credit_reg <= 1'b0;
                active_reg <= 1'b1;
                start_reg <= 1'b1;
                first_pixel_reg <= 1'b1;
                first_rgb_reg <= rgb_i;
                metadata_reg <= metadata_i;
                x_reg <= 11'd1;
                y_reg <= 10'd0;
                count_reg <= 18'd1;
            end
        end else if (active_reg && valid_pipe_reg[1]) begin
            if (!x_reg[0] && !y_reg[0]) begin
                valid_reg <= 1'b1;
                rgb_reg <= rgb_i;
                count_reg <= count_reg + 1'b1;
            end
            if (x_reg == 11'd1279) begin
                x_reg <= 11'd0;
                y_reg <= y_reg + 1'b1;
                if (y_reg == 10'd719) begin
                    active_reg <= 1'b0;
                    end_reg <= count_reg == 18'd230400;
                    abort_reg <= count_reg != 18'd230400;
                end
            end else begin
                x_reg <= x_reg + 1'b1;
            end
        end
        if (rst) begin
            timer_reg <= {TIMER_WIDTH{1'b0}};
            credit_reg <= 1'b1;
            valid_pipe_reg <= 2'b00;
            vsync_reg <= 1'b0;
            armed_reg <= 1'b0;
            active_reg <= 1'b0;
            x_reg <= 11'd0;
            y_reg <= 10'd0;
            count_reg <= 18'd0;
            first_pixel_reg <= 1'b0;
            start_reg <= 1'b0;
            valid_reg <= 1'b0;
            end_reg <= 1'b0;
            abort_reg <= 1'b0;
            metadata_reg <= 128'd0;
        end
    end
endmodule
`resetall
