// -----------------------------------------------------------------------------
// File   : hsv_left_rgb_sampler.v
// Author : Codex
// Date   : 2026-10-10
// -----------------------------------------------------------------------------
// Description:
//   Passive phase-zero RGB888 sampling, 1280x720 -> 160x90, without pixel RAM.
//   Accepts every valid local frame independently of stereo synchronization IDs.
//   Source rows must have 1280 contiguous valid pixels and a qualified last pixel.
//   Blanking is legal between rows; a mid-row valid gap aborts the partial frame.
//   Successful EOF requires all 720 rows, 14400 samples, and the actual input EOF.
//   Sampling (1272,712) does not commit a frame. Later errors still cancel it.
//   A nested SOF aborts the old frame and drops that overlapping new frame.
//   All outputs have one register layer and synchronous active-high reset.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-10  Codex  v1.0  Independent validated RGB sampling side branch.
//   2026-10-10  Codex  v1.1  Passive abort diagnostics; acceptance unchanged.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module hsv_left_rgb_sampler #
(
    // Legal values >= 2. Counts idle clocks while waiting for a row or real EOF.
    parameter MAX_IDLE_CYCLES = 4096
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] pixel_rgb_i,
    input  wire        pixel_valid_i,
    input  wire        frame_start_i,
    input  wire        line_end_i,
    input  wire        frame_end_i,
    input  wire        video_error_i,
    input  wire        frame_valid_i,
    output wire [23:0] pixel_rgb_o,
    output wire        pixel_valid_o,
    output wire [7:0]  pixel_x_o,
    output wire [6:0]  pixel_y_o,
    output wire        frame_start_o,
    output wire        frame_end_o,
    output wire        frame_abort_o,
    output wire [3:0]  abort_reason_o,
    output wire [13:0] abort_sample_count_o,
    output wire [10:0] abort_source_x_o,
    output wire [9:0]  abort_source_y_o
);
    localparam integer IDLE_WIDTH = $clog2(MAX_IDLE_CYCLES + 1);
    localparam [IDLE_WIDTH-1:0] LAST_IDLE = MAX_IDLE_CYCLES - 1;
    reg active_reg = 1'b0, active_next;
    reg [10:0] source_x_reg = 11'd0, source_x_next;
    reg [9:0] source_y_reg = 10'd0, source_y_next;
    reg [13:0] sample_count_reg = 14'd0, sample_count_next;
    reg [IDLE_WIDTH-1:0] idle_reg = {IDLE_WIDTH{1'b0}}, idle_next;
    reg [23:0] rgb_pipe_reg = 24'd0, rgb_pipe_next;
    reg valid_pipe_reg = 1'b0, valid_pipe_next;
    reg [7:0] x_pipe_reg = 8'd0, x_pipe_next;
    reg [6:0] y_pipe_reg = 7'd0, y_pipe_next;
    reg start_pipe_reg = 1'b0, start_pipe_next;
    reg end_pipe_reg = 1'b0, end_pipe_next;
    reg abort_pipe_reg = 1'b0, abort_pipe_next;
    reg reject_frame = 1'b0;
    // First rejection cause: 1 nested SOF, 2 SOF without pixel, 3 frame invalid,
    // 4 video error, 5 raster bounds, 6 sample overflow, 7 row gap, 8 timeout,
    // 9 line width/marker, A incomplete EOF. Snapshots are BEFORE rejected input.
    reg [3:0] reject_reason = 4'd0;
    reg [3:0] abort_reason_reg = 4'd0;
    reg [13:0] abort_sample_count_reg = 14'd0;
    reg [10:0] abort_source_x_reg = 11'd0;
    reg [9:0] abort_source_y_reg = 10'd0;

    assign pixel_rgb_o   = rgb_pipe_reg;
    assign pixel_valid_o = valid_pipe_reg;
    assign pixel_x_o     = x_pipe_reg;
    assign pixel_y_o     = y_pipe_reg;
    assign frame_start_o = start_pipe_reg;
    assign frame_end_o   = end_pipe_reg;
    assign frame_abort_o = abort_pipe_reg;
    assign abort_reason_o = abort_reason_reg;
    assign abort_sample_count_o = abort_sample_count_reg;
    assign abort_source_x_o = abort_source_x_reg;
    assign abort_source_y_o = abort_source_y_reg;

    always @* begin
        active_next = active_reg;
        source_x_next = source_x_reg;
        source_y_next = source_y_reg;
        sample_count_next = sample_count_reg;
        idle_next = idle_reg;
        rgb_pipe_next = rgb_pipe_reg;
        x_pipe_next = x_pipe_reg;
        y_pipe_next = y_pipe_reg;
        valid_pipe_next = 1'b0;
        start_pipe_next = 1'b0;
        end_pipe_next = 1'b0;
        abort_pipe_next = 1'b0;
        reject_frame = 1'b0;
        reject_reason = 4'd0;
        if (frame_start_i) begin
            if (active_reg) begin
                reject_frame = 1'b1;
                reject_reason = 4'd1;
            end else begin
                active_next = 1'b1;
                source_x_next = 11'd0;
                source_y_next = 10'd0;
                sample_count_next = 14'd0;
                idle_next = {IDLE_WIDTH{1'b0}};
                start_pipe_next = 1'b1;
                if (!pixel_valid_i) reject_frame = 1'b1;
                if (!pixel_valid_i) reject_reason = 4'd2;
            end
        end
        if (active_next && !reject_frame) begin
            if (!frame_valid_i || video_error_i) begin
                reject_frame = 1'b1;
                reject_reason = !frame_valid_i ? 4'd3 : 4'd4;
            end else if (pixel_valid_i) begin
                idle_next = {IDLE_WIDTH{1'b0}};
                if (source_x_next >= 11'd1280 || source_y_next >= 10'd720) begin
                    reject_frame = 1'b1;
                    reject_reason = 4'd5;
                end else begin
                    if (source_x_next[2:0] == 3'd0 && source_y_next[2:0] == 3'd0) begin
                        if (sample_count_next >= 14'd14400) begin
                            reject_frame = 1'b1;
                            reject_reason = 4'd6;
                        end else begin
                            valid_pipe_next = 1'b1;
                            rgb_pipe_next = pixel_rgb_i;
                            x_pipe_next = source_x_next[10:3];
                            y_pipe_next = source_y_next[9:3];
                            sample_count_next = sample_count_next + 14'd1;
                        end
                    end
                    source_x_next = source_x_next + 11'd1;
                end
            end else if (source_x_next != 11'd0 || idle_reg == LAST_IDLE) begin
                reject_frame = 1'b1;
                reject_reason = source_x_next != 11'd0 ? 4'd7 : 4'd8;
            end else begin
                idle_next = idle_reg + {{(IDLE_WIDTH-1){1'b0}}, 1'b1};
            end
            if (line_end_i) begin
                if (!pixel_valid_i || source_x_next != 11'd1280) begin
                    reject_frame = 1'b1;
                    if (reject_reason == 4'd0) reject_reason = 4'd9;
                end else begin
                    source_x_next = 11'd0;
                    source_y_next = source_y_next + 10'd1;
                end
            end
            if (frame_end_i) begin
                if (!reject_frame && source_x_next == 11'd0 && source_y_next == 10'd720 &&
                    sample_count_next == 14'd14400) begin
                    active_next = 1'b0;
                    end_pipe_next = 1'b1;
                end else begin
                    reject_frame = 1'b1;
                    if (reject_reason == 4'd0) reject_reason = 4'ha;
                end
            end
        end
        if (reject_frame) begin
            active_next = 1'b0;
            valid_pipe_next = 1'b0;
            start_pipe_next = 1'b0;
            end_pipe_next = 1'b0;
            abort_pipe_next = 1'b1;
        end
    end

    always @(posedge clk) begin
        active_reg <= active_next;
        source_x_reg <= source_x_next;
        source_y_reg <= source_y_next;
        sample_count_reg <= sample_count_next;
        idle_reg <= idle_next;
        rgb_pipe_reg <= rgb_pipe_next;
        valid_pipe_reg <= valid_pipe_next;
        x_pipe_reg <= x_pipe_next;
        y_pipe_reg <= y_pipe_next;
        start_pipe_reg <= start_pipe_next;
        end_pipe_reg <= end_pipe_next;
        abort_pipe_reg <= abort_pipe_next;
        if (reject_frame) begin
            abort_reason_reg <= reject_reason;
            abort_sample_count_reg <= frame_start_i && !active_reg ? 14'd0 : sample_count_reg;
            abort_source_x_reg <= frame_start_i && !active_reg ? 11'd0 : source_x_reg;
            abort_source_y_reg <= frame_start_i && !active_reg ? 10'd0 : source_y_reg;
        end
        if (rst) begin
            active_reg <= 1'b0;
            source_x_reg <= 11'd0;
            source_y_reg <= 10'd0;
            sample_count_reg <= 14'd0;
            idle_reg <= {IDLE_WIDTH{1'b0}};
            rgb_pipe_reg <= 24'd0;
            valid_pipe_reg <= 1'b0;
            x_pipe_reg <= 8'd0;
            y_pipe_reg <= 7'd0;
            start_pipe_reg <= 1'b0;
            end_pipe_reg <= 1'b0;
            abort_pipe_reg <= 1'b0;
            abort_reason_reg <= 4'd0;
            abort_sample_count_reg <= 14'd0;
            abort_source_x_reg <= 11'd0;
            abort_source_y_reg <= 10'd0;
        end
    end
endmodule
`resetall
