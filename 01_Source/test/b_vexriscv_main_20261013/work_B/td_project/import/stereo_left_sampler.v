// -----------------------------------------------------------------------------
// File   : stereo_left_sampler.v
// Author : Codex
// Date   : 2026-10-02
// Description: Selected 1280x720 RGB raster -> phase-zero 160x90 Gray8 stream.
// Change Log: 2026-10-02 v1.0 Stage 3; no image RAM or stereo calculation.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_left_sampler #
(
    // Maximum idle clocks between rows. Normal 720p horizontal blanking is 370.
    parameter MAX_IDLE_CYCLES = 4096
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] pixel_rgb_i,
    input  wire        line_end_i,
    input  wire        frame_end_i,
    input  wire        video_error_i,
    input  wire        frame_valid_i,
    input  wire [15:0] source_frame_id_i,
    input  wire        sync_valid_i,
    input  wire [15:0] sync_id_i,
    output wire        frame_start_o,
    output wire        pixel_valid_o,
    output wire [7:0]  gray_o,
    output wire [7:0]  x_o,
    output wire [6:0]  y_o,
    output wire        frame_end_o,
    output wire        frame_abort_o,
    output wire [15:0] source_frame_id_o,
    output wire        sync_valid_o,
    output wire [15:0] sync_id_o,
    output wire [31:0] left_completed_count_o,
    output wire [31:0] left_abort_count_o
);
    localparam integer IDLE_WIDTH = $clog2(MAX_IDLE_CYCLES + 1);
    localparam [IDLE_WIDTH-1:0] LAST_IDLE = MAX_IDLE_CYCLES - 1;
    reg active_reg = 1'b0, active_next;
    // x counts valid pixels within a row; y counts completed rows.
    reg [10:0] source_x_reg = 11'd0, source_x_next;
    reg [9:0] source_y_reg = 10'd0, source_y_next;
    reg [14:0] sample_count_reg = 15'd0, sample_count_next;
    reg [IDLE_WIDTH-1:0] idle_reg = {IDLE_WIDTH{1'b0}}, idle_next;
    reg [15:0] frame_source_reg = 16'd0, frame_source_next;
    reg [15:0] frame_sync_reg = 16'd0, frame_sync_next;
    reg frame_sync_valid_reg = 1'b0, frame_sync_valid_next;
    reg history_valid_reg = 1'b0, history_valid_next;
    reg start_reg = 1'b0, start_next;
    reg valid_reg = 1'b0, valid_next;
    reg end_reg = 1'b0, end_next;
    reg abort_reg = 1'b0, abort_next;
    reg [7:0] gray_reg = 8'd0, gray_next;
    reg [7:0] x_reg = 8'd0, x_next;
    reg [6:0] y_reg = 7'd0, y_next;
    reg [31:0] completed_reg = 32'd0, completed_next;
    reg [31:0] aborted_reg = 32'd0, aborted_next;
    reg reject_frame;
    wire replayed;
    wire [15:0] sync_distance;
    wire [16:0] red_wide, green_wide, blue_wide;
    wire [16:0] red_term, green_term, blue_term, gray_sum;
    // Serial-number ordering suppresses older as well as consecutive replays.
    // Valid forward distance is 1..32767; 65535->0 is forward distance one.
    assign sync_distance = sync_id_i - frame_sync_reg;
    assign replayed = history_valid_reg && (sync_distance == 16'd0 || sync_distance[15]);
    assign red_wide = {9'd0, pixel_rgb_i[23:16]};
    assign green_wide = {9'd0, pixel_rgb_i[15:8]};
    assign blue_wide = {9'd0, pixel_rgb_i[7:0]};
    // 77=64+8+4+1, 150=128+16+4+2, 29=16+8+4+1.
    // All operands are explicitly 17 bits, including the rounding addition.
    assign red_term = (red_wide << 6) + (red_wide << 3) +
                      (red_wide << 2) + red_wide;
    assign green_term = (green_wide << 7) + (green_wide << 4) +
                        (green_wide << 2) + (green_wide << 1);
    assign blue_term = (blue_wide << 4) + (blue_wide << 3) +
                       (blue_wide << 2) + blue_wide;
    assign gray_sum = red_term + green_term + blue_term + 17'd128;
    assign frame_start_o = start_reg;
    assign pixel_valid_o = valid_reg;
    assign gray_o = gray_reg;
    assign x_o = x_reg;
    assign y_o = y_reg;
    assign frame_end_o = end_reg;
    assign frame_abort_o = abort_reg;
    assign source_frame_id_o = frame_source_reg;
    assign sync_id_o = frame_sync_reg;
    assign sync_valid_o = frame_sync_valid_reg;
    assign left_completed_count_o = completed_reg;
    assign left_abort_count_o = aborted_reg;
    always @* begin
        active_next = active_reg;
        source_x_next = source_x_reg;
        source_y_next = source_y_reg;
        sample_count_next = sample_count_reg;
        idle_next = idle_reg;
        frame_source_next = frame_source_reg;
        frame_sync_next = frame_sync_reg;
        frame_sync_valid_next = frame_sync_valid_reg;
        history_valid_next = history_valid_reg;
        start_next = 1'b0;
        valid_next = 1'b0;
        end_next = 1'b0;
        abort_next = 1'b0;
        gray_next = gray_reg;
        x_next = x_reg;
        y_next = y_reg;
        completed_next = completed_reg;
        aborted_next = aborted_reg;
        reject_frame = 1'b0;
        if (frame_start_i) begin
            if (active_reg) begin
                // Abort the old frame without relabeling its already-emitted pixels.
                reject_frame = 1'b1;
            end else if (frame_valid_i && sync_valid_i && !replayed) begin
                active_next = 1'b1;
                source_x_next = 11'd0;
                source_y_next = 10'd0;
                sample_count_next = 15'd0;
                idle_next = {IDLE_WIDTH{1'b0}};
                frame_source_next = source_frame_id_i;
                frame_sync_next = sync_id_i;
                frame_sync_valid_next = 1'b1;
                history_valid_next = 1'b1;
                start_next = 1'b1;
                if (!pixel_valid_i) reject_frame = 1'b1;
            end
        end
        if (active_next && !reject_frame) begin
            if (!frame_valid_i || !sync_valid_i ||
                source_frame_id_i != frame_source_next || sync_id_i != frame_sync_next ||
                video_error_i) begin
                reject_frame = 1'b1;
            end else if (pixel_valid_i) begin
                idle_next = {IDLE_WIDTH{1'b0}};
                if (source_x_next >= 11'd1280 || source_y_next >= 10'd720) begin
                    reject_frame = 1'b1;
                end else begin
                    if (source_x_next[2:0] == 3'd0 && source_y_next[2:0] == 3'd0) begin
                        valid_next = 1'b1;
                        gray_next = gray_sum[15:8];
                        x_next = source_x_next[10:3];
                        y_next = source_y_next[9:3];
                        sample_count_next = sample_count_next + 15'd1;
                    end
                    source_x_next = source_x_next + 11'd1;
                end
            end else begin
                if (source_x_next != 11'd0 || idle_reg == LAST_IDLE) begin
                    // Horizontal blanking is legal only after a qualified line end.
                    reject_frame = 1'b1;
                end else begin
                    idle_next = idle_reg + {{(IDLE_WIDTH-1){1'b0}}, 1'b1};
                end
            end
            if (line_end_i) begin
                if (!pixel_valid_i || source_x_next != 11'd1280) begin
                    reject_frame = 1'b1;
                end else begin
                    source_x_next = 11'd0;
                    source_y_next = source_y_next + 10'd1;
                end
            end
            if (frame_end_i) begin
                if (!reject_frame && source_x_next == 11'd0 &&
                    source_y_next == 10'd720 && sample_count_next == 15'd14400) begin
                    active_next = 1'b0;
                    end_next = 1'b1;
                    completed_next = completed_reg + 32'd1;
                end else begin
                    reject_frame = 1'b1;
                end
            end
        end
        if (reject_frame) begin
            active_next = 1'b0;
            valid_next = 1'b0;
            start_next = 1'b0;
            end_next = 1'b0;
            abort_next = 1'b1;
            aborted_next = aborted_reg + 32'd1;
        end
    end
    always @(posedge clk) begin
        active_reg <= active_next;
        source_x_reg <= source_x_next;
        source_y_reg <= source_y_next;
        sample_count_reg <= sample_count_next;
        idle_reg <= idle_next;
        frame_source_reg <= frame_source_next;
        frame_sync_reg <= frame_sync_next;
        frame_sync_valid_reg <= frame_sync_valid_next;
        history_valid_reg <= history_valid_next;
        start_reg <= start_next;
        valid_reg <= valid_next;
        end_reg <= end_next;
        abort_reg <= abort_next;
        gray_reg <= gray_next;
        x_reg <= x_next;
        y_reg <= y_next;
        completed_reg <= completed_next;
        aborted_reg <= aborted_next;
        if (rst) begin
            // First reset clock aborts an in-flight frame; held reset gives no
            // repeated abort. Consumers sharing reset also discard partial data.
            abort_reg <= active_reg;
            active_reg <= 1'b0;
            source_x_reg <= 11'd0;
            source_y_reg <= 10'd0;
            sample_count_reg <= 15'd0;
            idle_reg <= {IDLE_WIDTH{1'b0}};
            frame_source_reg <= 16'd0;
            frame_sync_reg <= 16'd0;
            frame_sync_valid_reg <= 1'b0;
            history_valid_reg <= 1'b0;
            start_reg <= 1'b0;
            valid_reg <= 1'b0;
            end_reg <= 1'b0;
            gray_reg <= 8'd0;
            x_reg <= 8'd0;
            y_reg <= 7'd0;
            completed_reg <= 32'd0;
            aborted_reg <= 32'd0;
        end
    end
    initial begin
        if (MAX_IDLE_CYCLES < 2) begin
            $display("Invalid MAX_IDLE_CYCLES; must be at least 2");
            $finish;
        end
    end
endmodule
`resetall
