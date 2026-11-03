// -----------------------------------------------------------------------------
// File   : hsv_red_bbox.v
// Author : Codex
// Date   : 2026-10-10
// -----------------------------------------------------------------------------
// Description:
//   Lightweight parameterized red extent accumulation, independent of stereo ranging.
//   frame_result_valid_i and red_count_i MUST be the registered outputs of the
//   existing hsv_red_pixel_counter driven by exactly the same pixel/frame inputs.
//   It remains the sole completeness/order validator and red-count authority.
//   EOF captures a candidate including a coincident final pixel. The counter's
//   commit pulse exposes that candidate on the SAME edge, without another cycle.
//   A holding register captures it on the following edge; the mux transition
//   preserves the committed tuple. Invalid frames never replace the held result.
//   Bounds are inclusive; center is floor((min+max)/2). Invalid boxes are zero.
//   Optional run/row/streak filter excludes sparse noise before extent updates.
//   Separate dense supported regions still share one box. red_count_o stays raw.
//   Filtering does not add cycles to the validated EOF publication interface.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-11  Codex  v2.1  Optional RAM-free spatial support filter.
//   2026-10-11  Codex  v2.0  Parameterize full-resolution bounds and widened center sums.
//   2026-10-10  Codex  v1.0  Independent HSV bbox with shared frame validation.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module hsv_red_bbox #
(
    // Legacy defaults; top-level full-resolution instance overrides to 11/10/20.
    parameter integer X_WIDTH = 8,
    parameter integer Y_WIDTH = 7,
    parameter integer COUNT_WIDTH = 14,
    // Even threshold zero requires at least one red pixel.
    parameter [COUNT_WIDTH-1:0] MIN_RED_PIXELS = 20,
    // Zero preserves the legacy union of every red pixel.
    parameter integer SPATIAL_FILTER_ENABLE = 0,
    parameter integer IMAGE_WIDTH = 160,
    // shortcut: caller commits only ordered frames <= this bound; zero keeps
    // legacy modulo counters. Increase COUNT_WIDTH before using larger frames.
    parameter integer FRAME_PIXEL_LIMIT = 0,
    // All three thresholds must be >= 1. No line or frame memory is used.
    parameter integer MIN_RUN_PIXELS = 4,
    parameter integer MIN_ROW_PIXELS = 8,
    parameter integer MIN_CONSECUTIVE_ROWS = 3
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        red_mask_i,
    input  wire        pixel_valid_i,
    input  wire [X_WIDTH-1:0]  pixel_x_i,
    input  wire [Y_WIDTH-1:0]  pixel_y_i,
    input  wire        frame_start_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    input  wire        frame_result_valid_i,
    input  wire [COUNT_WIDTH-1:0] red_count_i,
    output wire        result_valid_o,
    output wire        bbox_valid_o,
    output wire [X_WIDTH-1:0]  xmin_o,
    output wire [X_WIDTH-1:0]  xmax_o,
    output wire [Y_WIDTH-1:0]  ymin_o,
    output wire [Y_WIDTH-1:0]  ymax_o,
    output wire [X_WIDTH-1:0]  center_x_o,
    output wire [Y_WIDTH-1:0]  center_y_o,
    output wire [COUNT_WIDTH-1:0] red_count_o
);
    localparam integer TUPLE_WIDTH = 3 * (X_WIDTH + Y_WIDTH);
    localparam integer RUN_WIDTH = (MIN_RUN_PIXELS < 2) ? 1 : $clog2(MIN_RUN_PIXELS+1);
    localparam integer STREAK_WIDTH = (MIN_CONSECUTIVE_ROWS < 2) ? 1 :
                                     $clog2(MIN_CONSECUTIVE_ROWS+1);
    localparam integer PENDING_WIDTH = X_WIDTH + STREAK_WIDTH + 1;
    localparam [X_WIDTH-1:0] LAST_X = IMAGE_WIDTH-1;
    localparam [RUN_WIDTH-1:0] RUN_LIMIT = MIN_RUN_PIXELS;
    localparam [X_WIDTH:0] RUN_WEIGHT = MIN_RUN_PIXELS;
    localparam [X_WIDTH:0] ROW_LIMIT = MIN_ROW_PIXELS;
    localparam [STREAK_WIDTH-1:0] STREAK_LIMIT = MIN_CONSECUTIVE_ROWS;
    localparam integer COUNT_CAP = (MIN_RED_PIXELS > MIN_ROW_PIXELS) ?
                                  MIN_RED_PIXELS : MIN_ROW_PIXELS;
    localparam integer COMPACT_WIDTH = COUNT_CAP < 2 ? 1 : $clog2(COUNT_CAP+1);
    localparam integer COMPACT = FRAME_PIXEL_LIMIT > 0 &&
        FRAME_PIXEL_LIMIT < (64'd1 << COUNT_WIDTH);
    localparam integer ROW_WIDTH = COMPACT && COMPACT_WIDTH < X_WIDTH+1 ? COMPACT_WIDTH : X_WIDTH+1;
    localparam integer BLOCK_COUNT_WIDTH = COMPACT && COMPACT_WIDTH < PENDING_WIDTH ? COMPACT_WIDTH : PENDING_WIDTH;
    localparam integer SUPPORT_WIDTH = COMPACT && COMPACT_WIDTH < COUNT_WIDTH ? COMPACT_WIDTH : COUNT_WIDTH;
    localparam integer ADD_WIDTH = COMPACT_WIDTH > X_WIDTH+1 ? COMPACT_WIDTH : X_WIDTH+1;
    function [COMPACT_WIDTH-1:0] count_add;
        input [ADD_WIDTH-1:0] a,b,c;
        reg [ADD_WIDTH+1:0] sum;
        begin
            sum = {2'b00,a} + {2'b00,b} + {2'b00,c};
            count_add = sum >= COUNT_CAP ? COUNT_CAP : sum[COMPACT_WIDTH-1:0];
        end
    endfunction
    reg [RUN_WIDTH-1:0] run_reg = 0, run_next;
    reg [X_WIDTH-1:0] run_start_reg = 0, run_start_next;
    reg [ROW_WIDTH-1:0] row_count_reg = 0, row_count_next;
    reg row_seen_reg = 0, row_seen_next;
    reg [X_WIDTH-1:0] row_min_reg = 0, row_min_next, row_max_reg = 0, row_max_next;
    reg [STREAK_WIDTH-1:0] streak_reg = 0, streak_next;
    reg [X_WIDTH-1:0] block_min_reg = 0, block_min_next, block_max_reg = 0, block_max_next;
    reg [Y_WIDTH-1:0] block_y_reg = 0, block_y_next;
    reg [BLOCK_COUNT_WIDTH-1:0] pending_count_reg = 0, pending_count_next;
    reg [SUPPORT_WIDTH-1:0] supported_count_reg = 0, supported_count_next;
    // Combinational rectangle event merged into the existing frame bounds.
    reg [X_WIDTH:0] row_increment;
    reg add_bounds;
    reg [X_WIDTH-1:0] add_xmin, add_xmax;
    reg [Y_WIDTH-1:0] add_ymin, add_ymax;
    reg active_reg = 1'b0, active_next;
    reg seen_reg = 1'b0, seen_next;
    reg [X_WIDTH-1:0] xmin_reg = {X_WIDTH{1'b0}}, xmin_next;
    reg [X_WIDTH-1:0] xmax_reg = {X_WIDTH{1'b0}}, xmax_next;
    reg [Y_WIDTH-1:0] ymin_reg = {Y_WIDTH{1'b0}}, ymin_next;
    reg [Y_WIDTH-1:0] ymax_reg = {Y_WIDTH{1'b0}}, ymax_next;
    // Tuple: {xmin, xmax, ymin, ymax, center_x, center_y}.
    reg [TUPLE_WIDTH-1:0] candidate_reg = {TUPLE_WIDTH{1'b0}}, candidate_next;
    reg candidate_seen_reg = 1'b0, candidate_seen_next;
    reg [TUPLE_WIDTH-1:0] published_reg = {TUPLE_WIDTH{1'b0}}, published_next;
    reg published_valid_reg = 1'b0, published_valid_next;
    wire [X_WIDTH:0] center_sum_x;
    wire [Y_WIDTH:0] center_sum_y;
    wire candidate_valid;
    wire [TUPLE_WIDTH-1:0] visible_tuple;

    assign center_sum_x = {1'b0, xmin_next} + {1'b0, xmax_next};
    assign center_sum_y = {1'b0, ymin_next} + {1'b0, ymax_next};
    assign candidate_valid = candidate_seen_reg && (red_count_i >= MIN_RED_PIXELS);
    assign visible_tuple = frame_result_valid_i ?
                           (candidate_valid ? candidate_reg : {TUPLE_WIDTH{1'b0}}) : published_reg;
    assign result_valid_o = frame_result_valid_i;
    assign bbox_valid_o = frame_result_valid_i ? candidate_valid : published_valid_reg;
    assign {xmin_o, xmax_o, ymin_o, ymax_o, center_x_o, center_y_o} = visible_tuple;
    assign red_count_o = red_count_i;

    always @* begin
        run_next = run_reg;
        run_start_next = run_start_reg;
        row_count_next = row_count_reg;
        row_seen_next = row_seen_reg;
        row_min_next = row_min_reg;
        row_max_next = row_max_reg;
        streak_next = streak_reg;
        block_min_next = block_min_reg;
        block_max_next = block_max_reg;
        block_y_next = block_y_reg;
        pending_count_next = pending_count_reg;
        supported_count_next = supported_count_reg;
        row_increment = 0;
        add_bounds = 1'b0;
        add_xmin = pixel_x_i;
        add_xmax = pixel_x_i;
        add_ymin = pixel_y_i;
        add_ymax = pixel_y_i;
        active_next = active_reg;
        seen_next = seen_reg;
        xmin_next = xmin_reg;
        xmax_next = xmax_reg;
        ymin_next = ymin_reg;
        ymax_next = ymax_reg;
        candidate_next = candidate_reg;
        candidate_seen_next = candidate_seen_reg;
        published_next = published_reg;
        published_valid_next = published_valid_reg;

        // The previous candidate is still stable before this edge. This can
        // coincide with the next SOF, EOF, or abort without mixing the frames.
        if (frame_result_valid_i) begin
            published_next = candidate_valid ? candidate_reg : {TUPLE_WIDTH{1'b0}};
            published_valid_next = candidate_valid;
        end
        if (frame_start_i || frame_abort_i) begin
            run_next = 0;
            run_start_next = 0;
            row_count_next = 0;
            row_seen_next = 0;
            row_min_next = 0;
            row_max_next = 0;
            streak_next = 0;
            block_min_next = 0;
            block_max_next = 0;
            block_y_next = 0;
            pending_count_next = 0;
            supported_count_next = 0;
        end
        if (frame_start_i) begin
            active_next = 1'b1;
            seen_next = 1'b0;
            xmin_next = {X_WIDTH{1'b0}};
            xmax_next = {X_WIDTH{1'b0}};
            ymin_next = {Y_WIDTH{1'b0}};
            ymax_next = {Y_WIDTH{1'b0}};
        end
        if (active_next && !frame_abort_i) begin
            if (SPATIAL_FILTER_ENABLE == 0) begin
                add_bounds = pixel_valid_i && red_mask_i;
            end else if (pixel_valid_i) begin
                // Bubbles hold state; only a valid non-red pixel breaks a run.
                if (red_mask_i) begin
                    if (run_next == 0) run_start_next = pixel_x_i;
                    if (run_next < RUN_LIMIT) begin
                        run_next = run_next + {{(RUN_WIDTH-1){1'b0}}, 1'b1};
                        if (run_next == RUN_LIMIT) begin
                            // Include the beginning of a confirmed run, without
                            // storing or replaying its earlier pixels.
                            row_increment = RUN_WEIGHT;
                            if (!row_seen_next) row_min_next = run_start_next;
                            row_max_next = pixel_x_i;
                            row_seen_next = 1'b1;
                        end
                    end else begin
                        row_increment = {{X_WIDTH{1'b0}}, 1'b1};
                        row_max_next = pixel_x_i;
                    end
                end else begin
                    run_next = 0;
                end
                row_count_next = COMPACT ? count_add(row_count_next, row_increment, 0) :
                                 row_count_next + row_increment;
                if (pixel_x_i == LAST_X) begin
                    if (row_seen_next && row_count_next >= ROW_LIMIT) begin
                        if (streak_next == 0) begin
                            block_min_next = row_min_next;
                            block_max_next = row_max_next;
                            block_y_next = pixel_y_i;
                        end else begin
                            if (row_min_next < block_min_next) block_min_next = row_min_next;
                            if (row_max_next > block_max_next) block_max_next = row_max_next;
                        end
                        if (streak_next < STREAK_LIMIT) begin
                            streak_next = streak_next + {{(STREAK_WIDTH-1){1'b0}}, 1'b1};
                            if (streak_next == STREAK_LIMIT) begin
                                supported_count_next = COMPACT ?
                                    count_add(supported_count_next,row_count_next,pending_count_next) :
                                    supported_count_next + pending_count_next + row_count_next;
                                pending_count_next = 0;
                            end else begin
                                pending_count_next = COMPACT ? count_add(pending_count_next,row_count_next,0) :
                                                     pending_count_next + row_count_next;
                            end
                        end else begin
                            supported_count_next = COMPACT ? count_add(supported_count_next,row_count_next,0) :
                                                   supported_count_next + row_count_next;
                        end
                        if (streak_next == STREAK_LIMIT) begin
                            add_bounds = 1'b1;
                            add_xmin = block_min_next;
                            add_xmax = block_max_next;
                            add_ymin = block_y_next;
                            add_ymax = pixel_y_i;
                        end
                    end else begin
                        streak_next = 0;
                        pending_count_next = 0;
                    end
                    run_next = 0;
                    row_count_next = 0;
                    row_seen_next = 0;
                end
            end
            if (add_bounds) begin
                if (!seen_next) begin
                    xmin_next = add_xmin;
                    xmax_next = add_xmax;
                    ymin_next = add_ymin;
                    ymax_next = add_ymax;
                    seen_next = 1'b1;
                end else begin
                    if (add_xmin < xmin_next) xmin_next = add_xmin;
                    if (add_xmax > xmax_next) xmax_next = add_xmax;
                    if (add_ymin < ymin_next) ymin_next = add_ymin;
                    if (add_ymax > ymax_next) ymax_next = add_ymax;
                end
            end
            if (frame_end_i) begin
                candidate_next = {xmin_next, xmax_next, ymin_next, ymax_next,
                                  center_sum_x[X_WIDTH:1], center_sum_y[Y_WIDTH:1]};
                candidate_seen_next = seen_next &&
                    ((SPATIAL_FILTER_ENABLE == 0) || (supported_count_next >= MIN_RED_PIXELS));
                active_next = 1'b0;
            end
        end
        if (frame_abort_i) begin
            active_next = 1'b0;
            seen_next = 1'b0;
            xmin_next = {X_WIDTH{1'b0}};
            xmax_next = {X_WIDTH{1'b0}};
            ymin_next = {Y_WIDTH{1'b0}};
            ymax_next = {Y_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        run_reg <= run_next;
        run_start_reg <= run_start_next;
        row_count_reg <= row_count_next;
        row_seen_reg <= row_seen_next;
        row_min_reg <= row_min_next;
        row_max_reg <= row_max_next;
        streak_reg <= streak_next;
        block_min_reg <= block_min_next;
        block_max_reg <= block_max_next;
        block_y_reg <= block_y_next;
        pending_count_reg <= pending_count_next;
        supported_count_reg <= supported_count_next;
        active_reg <= active_next;
        seen_reg <= seen_next;
        xmin_reg <= xmin_next;
        xmax_reg <= xmax_next;
        ymin_reg <= ymin_next;
        ymax_reg <= ymax_next;
        candidate_reg <= candidate_next;
        candidate_seen_reg <= candidate_seen_next;
        published_reg <= published_next;
        published_valid_reg <= published_valid_next;
        if (rst) begin
            run_reg <= 0;
            run_start_reg <= 0;
            row_count_reg <= 0;
            row_seen_reg <= 0;
            row_min_reg <= 0;
            row_max_reg <= 0;
            streak_reg <= 0;
            block_min_reg <= 0;
            block_max_reg <= 0;
            block_y_reg <= 0;
            pending_count_reg <= 0;
            supported_count_reg <= 0;
            active_reg <= 1'b0;
            seen_reg <= 1'b0;
            xmin_reg <= {X_WIDTH{1'b0}};
            xmax_reg <= {X_WIDTH{1'b0}};
            ymin_reg <= {Y_WIDTH{1'b0}};
            ymax_reg <= {Y_WIDTH{1'b0}};
            candidate_reg <= {TUPLE_WIDTH{1'b0}};
            candidate_seen_reg <= 1'b0;
            published_reg <= {TUPLE_WIDTH{1'b0}};
            published_valid_reg <= 1'b0;
        end
    end
endmodule
`resetall

