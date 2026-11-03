// -----------------------------------------------------------------------------
// File   : hsv_bbox_overlay.v
// Author : Codex
// Date   : 2026-10-10
// -----------------------------------------------------------------------------
// Description:
//   Zero-pixel-latency RGB/sync overlay, using existing final-raster coordinates.
//   COORD_SHIFT=0 maps 720P coordinates directly; legacy default is shift 3.
//   Default red stroke is two pixels, inset three pixels to separate it from
//   the existing three-pixel green stroke. Inset clamps to half the span.
//   Qualified results enter pending; only a VS rising edge in blanking publishes.
//   A result arriving on that edge waits for the next boundary. No frame buffer.
//   Source IDs are preserved, not compared against a nonexistent final-video ID.
//   Repeated source IDs do NOT renew freshness, so a frozen DDR image expires.
//   Latest-complete-result policy; not an exact same-source-frame display.
//   Three stale VS boundaries expire a box. A 200ms wall watchdog also clears
//   stalled video without VS; that abnormal-frame case can clear mid-raster.
//   Downstream original overlays keep green borders and distance text priority.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-11  Codex  v2.0  Add direct 720P mapping; keep publisher, stroke and expiry logic.
//   2026-10-10  Codex  v1.0  Independent HSV display and freshness control.
//   2026-10-10  Codex  v1.1  Passive draw/clear diagnostics; publication unchanged.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module hsv_bbox_overlay #
(
    // Legal values: thickness 1..7, inset 0..15.
    // Legacy defaults are isolated from the top-level 720P direct-coordinate instance.
    parameter integer X_WIDTH = 8,
    parameter integer Y_WIDTH = 7,
    parameter integer COORD_SHIFT = 3,
    parameter [2:0] BOX_THICKNESS = 3'd2,
    parameter [3:0] BOX_INSET = 4'd3,
    parameter [23:0] BOX_COLOR = 24'hff0000,
    // At 75MHz, default wall timeout is 200ms. Both limits must be >= 2.
    parameter integer STALE_FRAMES = 3,
    parameter integer MAX_AGE_CYCLES = 15000000
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] rgb_i,
    input  wire        de_i,
    input  wire        hsync_i,
    input  wire        vsync_i,
    input  wire [10:0] pixel_x_i,
    input  wire [9:0]  pixel_y_i,
    input  wire        result_valid_i,
    input  wire        bbox_valid_i,
    input  wire [X_WIDTH-1:0] xmin_i,
    input  wire [X_WIDTH-1:0] xmax_i,
    input  wire [Y_WIDTH-1:0] ymin_i,
    input  wire [Y_WIDTH-1:0] ymax_i,
    input  wire        source_frame_valid_i,
    input  wire [15:0] source_frame_id_i,
    output wire [23:0] rgb_o,
    output wire        de_o,
    output wire        hsync_o,
    output wire        vsync_o,
    output wire        active_valid_o,
    output wire [15:0] active_source_frame_id_o,
    output wire [10:0] display_xmin_o,
    output wire [10:0] display_xmax_o,
    output wire [9:0]  display_ymin_o,
    output wire [9:0]  display_ymax_o,
    output wire        draw_hit_o,
    output wire [3:0]  clear_reason_o
);
    localparam [X_WIDTH-1:0] LAST_X = (1280 >> COORD_SHIFT) - 1;
    localparam [Y_WIDTH-1:0] LAST_Y = (720 >> COORD_SHIFT) - 1;
    localparam [10:0] CELL_X_SUFFIX = (1 << COORD_SHIFT) - 1;
    localparam [9:0] CELL_Y_SUFFIX = (1 << COORD_SHIFT) - 1;
    localparam integer AGE_WIDTH = $clog2(MAX_AGE_CYCLES + 1);
    localparam integer FRAME_WIDTH = $clog2(STALE_FRAMES + 1);
    localparam [AGE_WIDTH-1:0] MAX_AGE = MAX_AGE_CYCLES;
    localparam [FRAME_WIDTH-1:0] MAX_FRAMES = STALE_FRAMES;
    // Tuple: {source_id, cell coverage xyxy, inset draw xyxy, valid}.
    reg [100:0] pending_reg = 101'd0, pending_next;
    reg [100:0] active_reg = 101'd0, active_next;
    reg pending_valid_reg = 1'b0, pending_valid_next;
    reg vsync_d_reg = 1'b0;
    reg source_seen_reg = 1'b0, source_seen_next;
    reg [15:0] last_source_id_reg = 16'd0, last_source_id_next;
    reg [AGE_WIDTH-1:0] age_reg = MAX_AGE, age_next;
    reg [FRAME_WIDTH-1:0] frame_age_reg = MAX_FRAMES, frame_age_next;
    wire legal_box;
    wire qualified_result;
    wire fresh_source;
    wire safe_boundary;
    wire [10:0] mapped_xmin, mapped_xmax, span_x, inset_x;
    wire [9:0] mapped_ymin, mapped_ymax, span_y, inset_y;
    wire [10:0] draw_xmin, draw_xmax;
    wire [9:0] draw_ymin, draw_ymax;
    wire [100:0] incoming;
    wire inside_box;
    wire border;
    // One-clock event: 1 valid no-target publication, 2 frame expiry, 3 wall expiry.
    reg [3:0] clear_reason_reg = 4'd0, clear_reason_next;

    assign legal_box = xmin_i <= xmax_i && ymin_i <= ymax_i &&
                       xmax_i <= LAST_X && ymax_i <= LAST_Y;
    assign qualified_result = result_valid_i && source_frame_valid_i &&
                              (!bbox_valid_i || legal_box);
    assign fresh_source = qualified_result &&
                          (!source_seen_reg || source_frame_id_i != last_source_id_reg);
    assign safe_boundary = vsync_i && !vsync_d_reg && !de_i;
    assign mapped_xmin = ({{(11-X_WIDTH){1'b0}}, xmin_i} << COORD_SHIFT);
    assign mapped_xmax = ({{(11-X_WIDTH){1'b0}}, xmax_i} << COORD_SHIFT) | CELL_X_SUFFIX;
    assign mapped_ymin = ({{(10-Y_WIDTH){1'b0}}, ymin_i} << COORD_SHIFT);
    assign mapped_ymax = ({{(10-Y_WIDTH){1'b0}}, ymax_i} << COORD_SHIFT) | CELL_Y_SUFFIX;
    assign span_x = mapped_xmax - mapped_xmin;
    assign span_y = mapped_ymax - mapped_ymin;
    assign inset_x = (span_x >> 1) < {7'd0, BOX_INSET} ?
                     (span_x >> 1) : {7'd0, BOX_INSET};
    assign inset_y = (span_y >> 1) < {6'd0, BOX_INSET} ?
                     (span_y >> 1) : {6'd0, BOX_INSET};
    assign draw_xmin = mapped_xmin + inset_x;
    assign draw_xmax = mapped_xmax - inset_x;
    assign draw_ymin = mapped_ymin + inset_y;
    assign draw_ymax = mapped_ymax - inset_y;
    assign incoming = bbox_valid_i ?
        {source_frame_id_i, mapped_xmin, mapped_xmax, mapped_ymin, mapped_ymax,
         draw_xmin, draw_xmax, draw_ymin, draw_ymax, 1'b1} :
        {source_frame_id_i, 85'd0};
    assign inside_box = active_reg[0] &&
                        pixel_x_i >= active_reg[42:32] && pixel_x_i <= active_reg[31:21] &&
                        pixel_y_i >= active_reg[20:11] && pixel_y_i <= active_reg[10:1];
    assign border = inside_box &&
        ((pixel_x_i - active_reg[42:32] < {8'd0, BOX_THICKNESS}) ||
         (active_reg[31:21] - pixel_x_i < {8'd0, BOX_THICKNESS}) ||
         (pixel_y_i - active_reg[20:11] < {7'd0, BOX_THICKNESS}) ||
         (active_reg[10:1] - pixel_y_i < {7'd0, BOX_THICKNESS}));
    assign rgb_o = de_i && !rst && border ? BOX_COLOR : rgb_i;
    assign draw_hit_o = de_i && !rst && border;
    assign clear_reason_o = clear_reason_reg;
    assign de_o = de_i;
    assign hsync_o = hsync_i;
    assign vsync_o = vsync_i;
    assign active_valid_o = active_reg[0];
    assign active_source_frame_id_o = active_reg[100:85];
    assign {display_xmin_o, display_xmax_o, display_ymin_o, display_ymax_o} =
        active_reg[84:43];

    always @* begin
        pending_next = pending_reg;
        active_next = active_reg;
        pending_valid_next = pending_valid_reg;
        source_seen_next = source_seen_reg;
        last_source_id_next = last_source_id_reg;
        age_next = age_reg;
        frame_age_next = frame_age_reg;
        clear_reason_next = 4'd0;
        if (age_reg < MAX_AGE) age_next = age_reg + {{(AGE_WIDTH-1){1'b0}}, 1'b1};
        if (safe_boundary) begin
            if (pending_valid_reg) begin
                if (active_reg[0] && !pending_reg[0]) clear_reason_next = 4'd1;
                active_next = pending_reg;
                pending_valid_next = 1'b0;
            end
            if (frame_age_reg < MAX_FRAMES) begin
                frame_age_next = frame_age_reg + {{(FRAME_WIDTH-1){1'b0}}, 1'b1};
            end
            if (frame_age_next == MAX_FRAMES) begin
                if (active_reg[0] || active_next[0] ||
                    (pending_valid_reg && pending_reg[0])) clear_reason_next = 4'd2;
                active_next = 101'd0;
                pending_valid_next = 1'b0;
            end
        end
        // Watchdog is the only non-boundary active change, for stalled/abnormal video.
        if (age_next == MAX_AGE) begin
            if (active_reg[0] || active_next[0] ||
                (pending_valid_reg && pending_reg[0])) clear_reason_next = 4'd3;
            active_next = 101'd0;
            pending_valid_next = 1'b0;
        end
        // Capture AFTER boundary handling; a coincident result is never lost.
        if (qualified_result) begin
            pending_next = incoming;
            pending_valid_next = 1'b1;
        end
        if (fresh_source) begin
            source_seen_next = 1'b1;
            last_source_id_next = source_frame_id_i;
            age_next = {AGE_WIDTH{1'b0}};
            frame_age_next = {FRAME_WIDTH{1'b0}};
        end
    end
    always @(posedge clk) begin
        pending_reg <= pending_next;
        active_reg <= active_next;
        pending_valid_reg <= pending_valid_next;
        vsync_d_reg <= vsync_i;
        source_seen_reg <= source_seen_next;
        last_source_id_reg <= last_source_id_next;
        age_reg <= age_next;
        frame_age_reg <= frame_age_next;
        clear_reason_reg <= clear_reason_next;
        if (rst) begin
            pending_reg <= 101'd0;
            active_reg <= 101'd0;
            pending_valid_reg <= 1'b0;
            vsync_d_reg <= 1'b0;
            source_seen_reg <= 1'b0;
            last_source_id_reg <= 16'd0;
            age_reg <= MAX_AGE;
            frame_age_reg <= MAX_FRAMES;
            clear_reason_reg <= 4'd0;
        end
    end
endmodule
`resetall
