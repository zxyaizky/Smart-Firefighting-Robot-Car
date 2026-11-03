// -----------------------------------------------------------------------------
// File   : stereo_right_capture.v
// Author : Codex
// Date   : 2026-10-02
// Description:
//   Crop framed Ethernet RGB888 to 160x90 Gray8 with held frame/bbox metadata.
//   No pixel memory, pairing, UDP parsing, or output backpressure.
//   2026-10-03 v1.1 Expose original delayed result metadata at completed frames.
// Change Log:
//   2026-10-02  Codex  v1.0  Stage 4 right stream, bbox association, idle timeout.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_right_capture #
(
    // Consecutive pixel-clock cycles without progress before an active abort.
    parameter RIGHT_FRAME_TIMEOUT_CYCLES = 15000000
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] pixel_rgb_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    input  wire [15:0] udp_frame_id_i,
    input  wire        sync_valid_i,
    input  wire [15:0] sync_id_i,
    input  wire [15:0] source_frame_id_i,
    input  wire        bbox_valid_i,
    input  wire [7:0]  bbox_x1_i,
    input  wire [6:0]  bbox_y1_i,
    input  wire [7:0]  bbox_x2_i,
    input  wire [6:0]  bbox_y2_i,
    input  wire        bbox_source_valid_i,
    input  wire [15:0] bbox_source_frame_id_i,
    input  wire [15:0] bbox_result_id_i,
    output wire        frame_start_o,
    output wire        pixel_valid_o,
    output wire [7:0]  gray_o,
    output wire [7:0]  x_o,
    output wire [6:0]  y_o,
    output wire        frame_end_o,
    output wire        frame_abort_o,
    output wire [15:0] udp_frame_id_o,
    output wire        sync_valid_o,
    output wire [15:0] sync_id_o,
    output wire [15:0] source_frame_id_o,
    output wire        bbox_current_valid_o,
    output wire        bbox_valid_o,
    output wire [7:0]  bbox_x1_o,
    output wire [6:0]  bbox_y1_o,
    output wire [7:0]  bbox_x2_o,
    output wire [6:0]  bbox_y2_o,
    output wire        bbox_source_valid_o,
    output wire [15:0] bbox_source_frame_id_o,
    output wire [15:0] bbox_result_id_o,
    output wire [31:0] right_completed_count_o,
    output wire [31:0] right_abort_count_o,
    output wire [31:0] right_timeout_count_o,
    output wire [31:0] right_bbox_valid_count_o,
    output wire [31:0] right_bbox_stale_count_o,
    output wire [15:0] last_right_sync_id_o,
    output wire [15:0] last_right_source_frame_id_o,
    output wire [63:0] bbox_result_metadata_o
);
    localparam integer IDLE_WIDTH = (RIGHT_FRAME_TIMEOUT_CYCLES > 1) ?
        $clog2(RIGHT_FRAME_TIMEOUT_CYCLES + 1) : 1;
    localparam [IDLE_WIDTH-1:0] LAST_IDLE = RIGHT_FRAME_TIMEOUT_CYCLES - 1;
    reg active_reg = 1'b0, active_next;
    reg [7:0] eth_x_reg = 8'd0, eth_x_next;
    reg [6:0] eth_y_reg = 7'd0, eth_y_next;
    reg [14:0] input_count_reg = 15'd0, input_count_next;
    reg [13:0] output_count_reg = 14'd0, output_count_next;
    reg [IDLE_WIDTH-1:0] idle_reg = {IDLE_WIDTH{1'b0}}, idle_next;
    // Atomic word includes the original bbox, even if stale/outside the crop.
    reg [112:0] metadata_reg = 113'd0, metadata_next;
    reg start_reg = 1'b0, start_next;
    reg valid_reg = 1'b0, valid_next;
    reg end_reg = 1'b0, end_next;
    reg abort_reg = 1'b0, abort_next;
    reg [7:0] gray_reg = 8'd0, gray_next;
    reg [7:0] x_reg = 8'd0, x_next;
    reg [6:0] y_reg = 7'd0, y_next;
    reg [31:0] completed_reg = 32'd0, completed_next;
    reg [31:0] aborted_reg = 32'd0, aborted_next;
    reg [31:0] timeout_reg = 32'd0, timeout_next;
    reg [31:0] bbox_valid_count_reg = 32'd0, bbox_valid_count_next;
    reg [31:0] bbox_stale_count_reg = 32'd0, bbox_stale_count_next;
    reg reject_frame = 1'b0;
    reg timeout_frame = 1'b0;
    wire [112:0] input_metadata;
    wire metadata_legal;
    wire raw_bbox_valid, raw_bbox_source_valid;
    wire [7:0] raw_bbox_x1, raw_bbox_x2;
    wire [6:0] raw_bbox_y1, raw_bbox_y2;
    wire [15:0] raw_source_id, raw_bbox_source_id;
    wire bbox_current, bbox_intersects, bbox_cropped_valid, bbox_stale;
    wire [7:0] clipped_x1, clipped_x2;
    wire [6:0] clipped_y1, clipped_y2;
    wire [16:0] red_wide, green_wide, blue_wide;
    wire [16:0] red_term, green_term, blue_term, gray_sum;

    assign input_metadata = {
        udp_frame_id_i, sync_valid_i, sync_id_i, source_frame_id_i,
        bbox_valid_i, bbox_x1_i, bbox_y1_i, bbox_x2_i, bbox_y2_i,
        bbox_source_valid_i, bbox_source_frame_id_i, bbox_result_id_i};
    // Membership (missing/stale bbox source) is not an image integrity error.
    // Only a declared bbox with invalid raster coordinates/order is malformed.
    assign metadata_legal = !bbox_valid_i ||
        (bbox_x1_i <= bbox_x2_i && bbox_y1_i <= bbox_y2_i &&
         bbox_x2_i <= 8'd159 && bbox_y2_i <= 7'd119);
    assign raw_source_id         = metadata_reg[79:64];
    assign raw_bbox_valid        = metadata_reg[63];
    assign raw_bbox_x1           = metadata_reg[62:55];
    assign raw_bbox_y1           = metadata_reg[54:48];
    assign raw_bbox_x2           = metadata_reg[47:40];
    assign raw_bbox_y2           = metadata_reg[39:33];
    assign raw_bbox_source_valid = metadata_reg[32];
    assign raw_bbox_source_id    = metadata_reg[31:16];
    assign bbox_current = raw_bbox_valid && raw_bbox_source_valid &&
                          raw_bbox_source_id == raw_source_id;
    assign bbox_stale = raw_bbox_valid && !bbox_current;
    // Inclusive rectangle intersection precedes clipping; a padding-only box
    // must not be turned into a one-row box at a crop boundary.
    assign bbox_intersects = raw_bbox_x1 <= raw_bbox_x2 &&
        raw_bbox_y1 <= raw_bbox_y2 && raw_bbox_x1 <= 8'd159 &&
        raw_bbox_y1 <= 7'd104 && raw_bbox_y2 >= 7'd15;
    assign clipped_x1 = (raw_bbox_x1 > 8'd159) ? 8'd159 : raw_bbox_x1;
    assign clipped_x2 = (raw_bbox_x2 > 8'd159) ? 8'd159 : raw_bbox_x2;
    assign clipped_y1 = (raw_bbox_y1 < 7'd15) ? 7'd15 :
                        ((raw_bbox_y1 > 7'd104) ? 7'd104 : raw_bbox_y1);
    assign clipped_y2 = (raw_bbox_y2 < 7'd15) ? 7'd15 :
                        ((raw_bbox_y2 > 7'd104) ? 7'd104 : raw_bbox_y2);
    assign bbox_cropped_valid = bbox_current && bbox_intersects &&
        clipped_x1 <= clipped_x2 && clipped_y1 <= clipped_y2;
    // Same explicit 17-bit shift-add expressions as stereo_left_sampler.
    assign red_wide = {9'd0, pixel_rgb_i[23:16]};
    assign green_wide = {9'd0, pixel_rgb_i[15:8]};
    assign blue_wide = {9'd0, pixel_rgb_i[7:0]};
    assign red_term = (red_wide << 6) + (red_wide << 3) +
                      (red_wide << 2) + red_wide;
    assign green_term = (green_wide << 7) + (green_wide << 4) +
                        (green_wide << 2) + (green_wide << 1);
    assign blue_term = (blue_wide << 4) + (blue_wide << 3) +
                       (blue_wide << 2) + blue_wide;
    assign gray_sum = red_term + green_term + blue_term + 17'd128;

    assign frame_start_o                 = start_reg;
    assign pixel_valid_o                 = valid_reg;
    assign gray_o                        = gray_reg;
    assign x_o                           = x_reg;
    assign y_o                           = y_reg;
    assign frame_end_o                   = end_reg;
    assign frame_abort_o                 = abort_reg;
    assign udp_frame_id_o                = metadata_reg[112:97];
    assign sync_valid_o                  = metadata_reg[96];
    assign sync_id_o                     = metadata_reg[95:80];
    assign source_frame_id_o             = raw_source_id;
    // Raw result identity/coordinates survive the current-image stale filter.
    // Consumers use this word ONLY with frame_end_o, never with abort/partial data.
    assign bbox_result_metadata_o        = metadata_reg[63:0];
    assign bbox_current_valid_o          = bbox_current;
    assign bbox_valid_o                  = bbox_cropped_valid;
    assign bbox_x1_o                     = bbox_cropped_valid ? clipped_x1 : 8'd0;
    assign bbox_y1_o                     = bbox_cropped_valid ? clipped_y1 - 7'd15 : 7'd0;
    assign bbox_x2_o                     = bbox_cropped_valid ? clipped_x2 : 8'd0;
    assign bbox_y2_o                     = bbox_cropped_valid ? clipped_y2 - 7'd15 : 7'd0;
    assign bbox_source_valid_o           = raw_bbox_source_valid;
    assign bbox_source_frame_id_o        = raw_bbox_source_id;
    assign bbox_result_id_o              = metadata_reg[15:0];
    assign right_completed_count_o       = completed_reg;
    assign right_abort_count_o           = aborted_reg;
    assign right_timeout_count_o         = timeout_reg;
    assign right_bbox_valid_count_o      = bbox_valid_count_reg;
    assign right_bbox_stale_count_o      = bbox_stale_count_reg;
    assign last_right_sync_id_o          = metadata_reg[95:80];
    assign last_right_source_frame_id_o   = raw_source_id;

    always @* begin
        active_next = active_reg;
        eth_x_next = eth_x_reg;
        eth_y_next = eth_y_reg;
        input_count_next = input_count_reg;
        output_count_next = output_count_reg;
        idle_next = idle_reg;
        metadata_next = metadata_reg;
        start_next = 1'b0;
        valid_next = 1'b0;
        end_next = 1'b0;
        abort_next = 1'b0;
        gray_next = gray_reg;
        x_next = x_reg;
        y_next = y_reg;
        completed_next = completed_reg;
        aborted_next = aborted_reg;
        timeout_next = timeout_reg;
        bbox_valid_count_next = bbox_valid_count_reg;
        bbox_stale_count_next = bbox_stale_count_reg;
        reject_frame = 1'b0;
        timeout_frame = 1'b0;

        if (frame_start_i) begin
            if (active_reg) begin
                // Preserve the old identity for its abort; discard this START.
                reject_frame = 1'b1;
            end else begin
                active_next = 1'b1;
                eth_x_next = 8'd0;
                eth_y_next = 7'd0;
                input_count_next = 15'd0;
                output_count_next = 14'd0;
                idle_next = {IDLE_WIDTH{1'b0}};
                metadata_next = input_metadata;
                start_next = 1'b1;
                if (!metadata_legal) reject_frame = 1'b1;
            end
        end
        if (active_next && !reject_frame) begin
            if (frame_abort_i) begin
                reject_frame = 1'b1;
            end else begin
                if (pixel_valid_i) begin
                    idle_next = {IDLE_WIDTH{1'b0}};
                    if (input_count_next >= 15'd19200 ||
                        eth_x_next >= 8'd160 || eth_y_next >= 7'd120) begin
                        reject_frame = 1'b1;
                    end else begin
                        if (eth_y_next >= 7'd15 && eth_y_next <= 7'd104) begin
                            valid_next = 1'b1;
                            gray_next = gray_sum[15:8];
                            x_next = eth_x_next;
                            y_next = eth_y_next - 7'd15;
                            output_count_next = output_count_next + 14'd1;
                        end
                        input_count_next = input_count_next + 15'd1;
                        if (eth_x_next == 8'd159) begin
                            eth_x_next = 8'd0;
                            eth_y_next = eth_y_next + 7'd1;
                        end else begin
                            eth_x_next = eth_x_next + 8'd1;
                        end
                    end
                end else if (!frame_start_i && !frame_end_i) begin
                    if (idle_reg == LAST_IDLE) begin
                        reject_frame = 1'b1;
                        timeout_frame = 1'b1;
                    end else begin
                        idle_next = idle_reg + {{(IDLE_WIDTH-1){1'b0}}, 1'b1};
                    end
                end
                // END can follow, or coincide with, the final source pixel.
                if (frame_end_i) begin
                    if (!reject_frame && input_count_next == 15'd19200 &&
                        output_count_next == 14'd14400 &&
                        eth_x_next == 8'd0 && eth_y_next == 7'd120) begin
                        active_next = 1'b0;
                        end_next = 1'b1;
                        completed_next = completed_reg + 32'd1;
                        if (bbox_cropped_valid) begin
                            bbox_valid_count_next = bbox_valid_count_reg + 32'd1;
                        end
                        if (bbox_stale) begin
                            bbox_stale_count_next = bbox_stale_count_reg + 32'd1;
                        end
                    end else begin
                        reject_frame = 1'b1;
                    end
                end
            end
        end
        if (reject_frame) begin
            active_next = 1'b0;
            start_next = 1'b0;
            valid_next = 1'b0;
            end_next = 1'b0;
            abort_next = 1'b1;
            aborted_next = aborted_reg + 32'd1;
            if (timeout_frame) timeout_next = timeout_reg + 32'd1;
        end
        // Outside an accepted frame, ignore orphan/late tokens until a START.
    end

    always @(posedge clk) begin
        active_reg <= active_next;
        eth_x_reg <= eth_x_next;
        eth_y_reg <= eth_y_next;
        input_count_reg <= input_count_next;
        output_count_reg <= output_count_next;
        idle_reg <= idle_next;
        metadata_reg <= metadata_next;
        start_reg <= start_next;
        valid_reg <= valid_next;
        end_reg <= end_next;
        abort_reg <= abort_next;
        gray_reg <= gray_next;
        x_reg <= x_next;
        y_reg <= y_next;
        completed_reg <= completed_next;
        aborted_reg <= aborted_next;
        timeout_reg <= timeout_next;
        bbox_valid_count_reg <= bbox_valid_count_next;
        bbox_stale_count_reg <= bbox_stale_count_next;
        if (rst) begin
            // One abort on the first reset clock of an active frame; consumers
            // sharing reset discard partial data. IDs/statistics reset to zero.
            abort_reg <= active_reg;
            active_reg <= 1'b0;
            eth_x_reg <= 8'd0;
            eth_y_reg <= 7'd0;
            input_count_reg <= 15'd0;
            output_count_reg <= 14'd0;
            idle_reg <= {IDLE_WIDTH{1'b0}};
            metadata_reg <= 113'd0;
            start_reg <= 1'b0;
            valid_reg <= 1'b0;
            end_reg <= 1'b0;
            gray_reg <= 8'd0;
            x_reg <= 8'd0;
            y_reg <= 7'd0;
            completed_reg <= 32'd0;
            aborted_reg <= 32'd0;
            timeout_reg <= 32'd0;
            bbox_valid_count_reg <= 32'd0;
            bbox_stale_count_reg <= 32'd0;
        end
    end

    initial begin
        if (RIGHT_FRAME_TIMEOUT_CYCLES < 2) begin
            $display("Invalid RIGHT_FRAME_TIMEOUT_CYCLES; must be at least 2");
            $finish;
        end
    end
endmodule
`resetall
