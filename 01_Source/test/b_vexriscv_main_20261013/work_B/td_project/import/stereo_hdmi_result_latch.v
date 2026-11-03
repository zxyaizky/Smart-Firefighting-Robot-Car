// -----------------------------------------------------------------------------
// File   : stereo_hdmi_result_latch.v
// Author : Codex
// Date   : 2026-10-05
// -----------------------------------------------------------------------------
// Description:
//   Same-clock atomic bbox/range publication. Optional median/mean filtering of
//   the D/Z label; raw disparity remains available for the current bbox projection.
//   Invalid completions always hide the result. Optional brief same-target range
//   gaps preserve filter history without publishing an invalid distance as valid.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-02  Codex  v1.0  HDMI debug result capture
//   2026-10-02  Codex  v1.1  Expose actual completion count and result presence
//   2026-10-05  Codex  v1.2  Stabilize labels while preserving raw bbox projection
//   2026-10-05  Codex  v1.3  Add fractional-mean hysteresis and fresh-result confirmation
//   2026-10-05  Codex  v1.4  Preserve recent same-target history across hidden range gaps
//   2026-10-05  Codex  v1.5  Optional exact-candidate confirmation for small D changes
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_hdmi_result_latch #(
    parameter STABILIZE_DISPLAY = 0,
    parameter KEEP_HISTORY_ON_RANGE_GAP = 0,
    parameter [31:0] FB_CONSTANT = 32'd8000,
    // One second at the production 75 MHz clock. Only expires filter history.
    parameter [31:0] HISTORY_TIMEOUT_CYCLES = 32'd75000000,
    // 2 keeps the original two-direction rule; >2 confirms small changes.
    parameter SMALL_STEP_CONFIRMATIONS = 2,
    parameter [5:0] SMALL_STEP_MAX_DELTA = 6'd2
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        pair_take_i,
    input  wire [15:0] pair_sync_id_i,
    input  wire        bbox_valid_i,
    input  wire [7:0]  bbox_x1_i,
    input  wire [6:0]  bbox_y1_i,
    input  wire [7:0]  bbox_x2_i,
    input  wire [6:0]  bbox_y2_i,
    input  wire        range_done_i,
    input  wire        range_valid_i,
    input  wire [5:0]  disparity_i,
    input  wire [15:0] distance_mm_i,
    input  wire [15:0] range_sync_id_i,
    output wire        bbox_valid_o,
    output wire [7:0]  bbox_x1_o,
    output wire [6:0]  bbox_y1_o,
    output wire [7:0]  bbox_x2_o,
    output wire [6:0]  bbox_y2_o,
    output wire        range_valid_o,
    // Current raw D is deliberately kept separate from the smoothed label D.
    output wire [5:0]  disparity_o,
    output wire [15:0] distance_mm_o,
    output wire [15:0] pair_sync_id_o,
    output wire        result_seen_o,
    output wire [15:0] update_count_o,
    output wire [5:0]  label_disparity_o
);
    reg [46:0] active_reg = 47'd0;
    reg        pending_reg = 1'd0;
    reg [69:0] latest_reg = 70'd0;
    reg [5:0]  label_reg = 6'd0;
    reg        seen_reg = 1'd0;
    reg [15:0] count_reg = 16'd0;
    wire       identity_ok;
    wire       publish_valid;
    wire [69:0] publish_tuple;
    wire [5:0] publish_label;

    assign result_seen_o = seen_reg;
    assign update_count_o = count_reg;
    assign label_disparity_o = label_reg;
    assign identity_ok = pending_reg && active_reg[46:31] == range_sync_id_i;
    assign {pair_sync_id_o, bbox_valid_o, bbox_x1_o, bbox_y1_o,
            bbox_x2_o, bbox_y2_o, range_valid_o, disparity_o, distance_mm_o} = latest_reg;

    generate
        if (STABILIZE_DISPLAY != 0) begin : gen_stable_label
            localparam integer SMALL_COUNT_WIDTH = SMALL_STEP_CONFIRMATIONS > 2 ?
                $clog2(SMALL_STEP_CONFIRMATIONS) : 1;
            localparam [SMALL_COUNT_WIDTH-1:0] SMALL_CONFIRM_LAST = SMALL_STEP_CONFIRMATIONS - 1;
            reg [SMALL_COUNT_WIDTH-1:0] small_count_reg = {SMALL_COUNT_WIDTH{1'b0}};
            reg [5:0] small_candidate_reg = 6'd0;
            reg        history_valid_reg = 1'd0;
            reg [29:0] history_bbox_reg = 30'd0;
            reg [15:0] history_id_reg = 16'd0;
            reg [31:0] history_age_reg = 32'd0;
            reg [5:0]  previous_raw_reg = 6'd0;
            reg [5:0]  older_raw_reg = 6'd0;
            reg [5:0]  previous_median_reg = 6'd0;
            reg [5:0]  older_median_reg = 6'd0;
            reg [5:0]  oldest_median_reg = 6'd0;
            reg        valid_pipe1_reg = 1'd0;
            reg        valid_pipe2_reg = 1'd0;
            reg        seed_pipe1_reg = 1'd0;
            reg [69:0] tuple_pipe1_reg = 70'd0;
            reg [69:0] tuple_pipe2_reg = 70'd0;
            reg [5:0]  median_pipe1_reg = 6'd0;
            reg [5:0]  label_pipe2_reg = 6'd0;
            reg [5:0]  filter_label_reg = 6'd0;
            reg        retain_pipe1_reg = 1'b0;
            // 0: none, 1: increasing D, 2: decreasing D. Counts completions, not clocks.
            reg [1:0]  pending_direction_reg = 2'd0;
            wire [15:0] id_delta;
            wire       bbox_ordered;
            wire       bbox_in_bounds;
            wire       bbox_overlap;
            wire       current_valid;
            wire       same_context;
            wire       retain_on_invalid;
            wire [5:0] current_median;
            wire [8:0] median_sum;
            wire [8:0] rounded_sum;
            wire [8:0] label_center;
            wire [1:0] mean_direction;
            wire [5:0] mean_candidate;
            wire [5:0] mean_delta;
            wire small_change;
            wire [15:0] label_distance;

            function [5:0] median_of_three;
                input [5:0] a;
                input [5:0] b;
                input [5:0] c;
                begin
                    if (a <= b) begin
                        if (b <= c) median_of_three = b;
                        else if (a <= c) median_of_three = c;
                        else median_of_three = a;
                    end else begin
                        if (a <= c) median_of_three = a;
                        else if (b <= c) median_of_three = c;
                        else median_of_three = b;
                    end
                end
            endfunction

            assign id_delta = range_sync_id_i - history_id_reg;
            assign bbox_ordered = active_reg[29:22] <= active_reg[14:7] &&
                                  active_reg[21:15] <= active_reg[6:0];
            assign bbox_in_bounds = active_reg[14:7] <= 8'd159 &&
                                    active_reg[6:0] <= 7'd89;
            assign bbox_overlap = active_reg[29:22] <= history_bbox_reg[14:7] &&
                                  history_bbox_reg[29:22] <= active_reg[14:7] &&
                                  active_reg[21:15] <= history_bbox_reg[6:0] &&
                                  history_bbox_reg[21:15] <= active_reg[6:0];
            assign current_valid = identity_ok && range_valid_i && active_reg[30] &&
                                   bbox_ordered && bbox_in_bounds &&
                                   disparity_i != 6'd0 && disparity_i <= 6'd31;
            // Missing sync IDs are normal. Modular forward IDs include FFFF -> 0000.
            assign same_context = history_valid_reg && bbox_overlap &&
                                  history_age_reg < HISTORY_TIMEOUT_CYCLES &&
                                  id_delta != 16'd0 && !id_delta[15];
            // Range failures may hide a frame without destroying a recent estimate.
            // No bbox, bad identity/geometry, target change, or expired history clears it.
            assign retain_on_invalid = KEEP_HISTORY_ON_RANGE_GAP != 0 &&
                                       identity_ok && active_reg[30] && bbox_ordered &&
                                       bbox_in_bounds && !range_valid_i && same_context;
            assign current_median = same_context ?
                median_of_three(disparity_i, previous_raw_reg, older_raw_reg) : disparity_i;
            assign median_sum = {3'd0, median_pipe1_reg} +
                                {3'd0, previous_median_reg} +
                                {3'd0, older_median_reg} +
                                {3'd0, oldest_median_reg};
            assign rounded_sum = median_sum + 9'd2;
            // Keep quarter-pixel mean precision until the output decision. An
            // integer label changes only beyond +/-0.75 pixel on two fresh results.
            assign label_center = {1'b0, filter_label_reg, 2'b00};
            assign mean_direction = median_sum >= label_center + 9'd3 ? 2'd1 :
                                    median_sum + 9'd3 <= label_center ? 2'd2 : 2'd0;
            assign mean_candidate = rounded_sum[7:2];
            assign mean_delta = mean_candidate >= filter_label_reg ?
                mean_candidate - filter_label_reg : filter_label_reg - mean_candidate;
            assign small_change = SMALL_STEP_CONFIRMATIONS > 2 &&
                                  mean_delta <= SMALL_STEP_MAX_DELTA;
            assign publish_valid = valid_pipe2_reg;
            assign publish_tuple = {tuple_pipe2_reg[69:16], label_distance};
            assign publish_label = label_pipe2_reg;

            stereo_depth_lut #(.FB_CONSTANT(FB_CONSTANT)) label_depth_inst (
                .disparity_i   (label_pipe2_reg),
                .distance_mm_o (label_distance)
            );

            // Median, mean, and distance lookup have separate register boundaries.
            // Throughput is one completion/clock; enabled publication adds two clocks.
            always @(posedge clk) begin
                valid_pipe1_reg <= range_done_i;
                valid_pipe2_reg <= valid_pipe1_reg;
                if (history_valid_reg && history_age_reg < HISTORY_TIMEOUT_CYCLES)
                    history_age_reg <= history_age_reg + 32'd1;

                if (range_done_i) begin
                    tuple_pipe1_reg <= {range_sync_id_i, active_reg[30] && identity_ok,
                                        active_reg[29:0], current_valid,
                                        disparity_i, distance_mm_i};
                    seed_pipe1_reg <= !same_context;
                    retain_pipe1_reg <= retain_on_invalid;
                    median_pipe1_reg <= current_valid ? current_median : 6'd0;
                    history_valid_reg <= current_valid || retain_on_invalid;
                    // Age is tested before the next edge increments the counter.
                    // Starting at one gives an exact event-to-event timeout.
                    // Only valid measurements restart the age; failures cannot extend it.
                    if (current_valid) begin
                        history_age_reg <= 32'd1;
                        history_bbox_reg <= active_reg[29:0];
                        history_id_reg <= range_sync_id_i;
                        previous_raw_reg <= disparity_i;
                        older_raw_reg <= same_context ? previous_raw_reg : disparity_i;
                    end else if (!retain_on_invalid) begin
                        history_age_reg <= 32'd0;
                        history_bbox_reg <= 30'd0;
                        history_id_reg <= 16'd0;
                        previous_raw_reg <= 6'd0;
                        older_raw_reg <= 6'd0;
                    end
                end

                if (valid_pipe1_reg) begin
                    // Only this job's label stage changes confirmation state.
                    // Neutral/invalid/seed/large changes cancel a small candidate.
                    small_count_reg <= {SMALL_COUNT_WIDTH{1'b0}};
                    small_candidate_reg <= 6'd0;
                    tuple_pipe2_reg <= tuple_pipe1_reg;
                    if (!tuple_pipe1_reg[22]) begin
                        label_pipe2_reg <= 6'd0;
                        pending_direction_reg <= 2'd0;
                        if (!retain_pipe1_reg) begin
                            filter_label_reg <= 6'd0;
                            previous_median_reg <= 6'd0;
                            older_median_reg <= 6'd0;
                            oldest_median_reg <= 6'd0;
                        end
                    end else if (seed_pipe1_reg) begin
                        label_pipe2_reg <= median_pipe1_reg;
                        filter_label_reg <= median_pipe1_reg;
                        pending_direction_reg <= 2'd0;
                        previous_median_reg <= median_pipe1_reg;
                        older_median_reg <= median_pipe1_reg;
                        oldest_median_reg <= median_pipe1_reg;
                    end else begin
                        label_pipe2_reg <= filter_label_reg;
                        if (mean_direction == 2'd0) begin
                            pending_direction_reg <= 2'd0;
                        end else if (small_change) begin
                            // The same rounded candidate must recur on fresh
                            // valid results; idle clocks never advance this count.
                            pending_direction_reg <= 2'd0;
                            small_candidate_reg <= mean_candidate;
                            if (small_count_reg != {SMALL_COUNT_WIDTH{1'b0}} &&
                                small_candidate_reg == mean_candidate) begin
                                if (small_count_reg == SMALL_CONFIRM_LAST) begin
                                    label_pipe2_reg <= mean_candidate;
                                    filter_label_reg <= mean_candidate;
                                    small_candidate_reg <= 6'd0;
                                end else begin
                                    small_count_reg <= small_count_reg +
                                        {{(SMALL_COUNT_WIDTH-1){1'b0}}, 1'b1};
                                end
                            end else begin
                                small_count_reg <= {{(SMALL_COUNT_WIDTH-1){1'b0}}, 1'b1};
                            end
                        end else if (mean_direction == pending_direction_reg) begin
                            label_pipe2_reg <= rounded_sum[7:2];
                            filter_label_reg <= rounded_sum[7:2];
                            pending_direction_reg <= 2'd0;
                        end else begin
                            pending_direction_reg <= mean_direction;
                        end
                        previous_median_reg <= median_pipe1_reg;
                        older_median_reg <= previous_median_reg;
                        oldest_median_reg <= older_median_reg;
                    end
                end

                if (rst) begin
                    history_valid_reg <= 1'b0;
                    history_bbox_reg <= 30'd0;
                    history_id_reg <= 16'd0;
                    history_age_reg <= 32'd0;
                    previous_raw_reg <= 6'd0;
                    older_raw_reg <= 6'd0;
                    previous_median_reg <= 6'd0;
                    older_median_reg <= 6'd0;
                    oldest_median_reg <= 6'd0;
                    valid_pipe1_reg <= 1'b0;
                    valid_pipe2_reg <= 1'b0;
                    seed_pipe1_reg <= 1'b0;
                    tuple_pipe1_reg <= 70'd0;
                    tuple_pipe2_reg <= 70'd0;
                    median_pipe1_reg <= 6'd0;
                    label_pipe2_reg <= 6'd0;
                    filter_label_reg <= 6'd0;
                    retain_pipe1_reg <= 1'b0;
                    pending_direction_reg <= 2'd0;
                    small_count_reg <= {SMALL_COUNT_WIDTH{1'b0}};
                    small_candidate_reg <= 6'd0;
                end
            end
        end else begin : gen_passthrough
            assign publish_valid = range_done_i;
            assign publish_tuple = {range_sync_id_i, active_reg[30] && identity_ok,
                                    active_reg[29:0], range_valid_i && identity_ok,
                                    disparity_i, distance_mm_i};
            assign publish_label = disparity_i;
        end
    endgenerate

    always @(posedge clk) begin
        if (range_done_i) pending_reg <= 1'b0;
        // Acceptance of the next pair may share a clock with the old completion.
        if (pair_take_i) begin
            active_reg <= {pair_sync_id_i, bbox_valid_i, bbox_x1_i, bbox_y1_i,
                           bbox_x2_i, bbox_y2_i};
            pending_reg <= 1'b1;
        end
        if (publish_valid) begin
            latest_reg <= publish_tuple;
            label_reg <= publish_label;
            seen_reg <= 1'b1;
            count_reg <= count_reg + 16'd1;
        end
        if (rst) begin
            active_reg <= 47'd0;
            pending_reg <= 1'b0;
            latest_reg <= 70'd0;
            label_reg <= 6'd0;
            seen_reg <= 1'b0;
            count_reg <= 16'd0;
        end
    end
endmodule
`resetall
