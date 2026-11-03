// File: stereo_roi_ranging.v
// Author: Codex
// Date: 2026-10-02
// Description: Centre and two bbox-edge 5x5 templates, serial positive disparity search.
// Change Log: 2026-10-02 Codex v1.0 Stereo stage 6 direct target distance.
//   2026-10-03 Codex v1.1 Three windows; median of three valid disparities.
//   2026-10-05 Codex v1.2 Optional gradient ranking of raw-SAD-qualified candidates.
//   2026-10-08 Codex v1.3 Optional ambiguity rejection and two-window agreement.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_roi_ranging #(
    parameter [31:0] FB_CONSTANT = 32'd8000,
    parameter [12:0] MAX_MATCH_COST = 13'd1000,
    parameter [7:0] MIN_TEXTURE_RANGE = 8'd16,
    parameter READ_TIMEOUT_CYCLES = 16,
    // Preserve legacy matching unless explicitly enabled by the top.
    parameter GRADIENT_RANKING = 0,
    // Require a runner-up rank strictly above best + floor(best/8).
    parameter REJECT_AMBIGUOUS = 0,
    // Require another distinct usable window to support the chosen disparity.
    parameter REQUIRE_WINDOW_AGREEMENT = 0,
    // Maximum total-disparity difference between supporting windows.
    parameter [5:0] WINDOW_AGREEMENT_TOLERANCE = 6'd2
) (
    input  wire clk,
    input  wire rst,
    input  wire pair_valid_i,
    input  wire [15:0] pair_sync_id_i,
    input  wire left_bank_i,
    input  wire right_bank_i,
    input  wire bbox_valid_i,
    input  wire [7:0] bbox_x1_i,
    input  wire [6:0] bbox_y1_i,
    input  wire [7:0] bbox_x2_i,
    input  wire [6:0] bbox_y2_i,
    output wire pair_accept_o,
    output wire pair_done_o,
    output wire left_rd_en_o,
    output wire left_rd_bank_o,
    output wire [13:0] left_rd_addr_o,
    input  wire left_rd_valid_i,
    input  wire [7:0] left_rd_data_i,
    output wire right_rd_en_o,
    output wire right_rd_bank_o,
    output wire [13:0] right_rd_addr_o,
    input  wire right_rd_valid_i,
    input  wire [7:0] right_rd_data_i,
    output wire busy_o,
    output wire range_done_o,
    output wire range_valid_o,
    output wire [5:0] disparity_o,
    output wire [15:0] distance_mm_o,
    output wire [12:0] match_cost_o,
    output wire [7:0] target_x_o,
    output wire [6:0] target_y_o,
    output wire [15:0] pair_sync_id_o
);
    // One-hot state encoding; one paired RAM request, then consume synchronous return.
    localparam [10:0] RANGE_IDLE = 11'b00000000001, RANGE_CHECK = 11'b00000000010,
        RANGE_READ = 11'b00000000100, RANGE_WAIT = 11'b00000001000,
        RANGE_EVAL = 11'b00000010000, RANGE_RECORD = 11'b00000100000,
        RANGE_NEXT = 11'b00001000000, RANGE_SELECT = 11'b00010000000,
        RANGE_LOOKUP = 11'b00100000000, RANGE_DONE = 11'b01000000000,
        RANGE_GRADIENT = 11'b10000000000;
    reg [10:0] state_reg = RANGE_IDLE, state_next;
    reg bbox_ok_reg = 1'b0, bbox_ok_next;
    reg [7:0] cx_reg = 8'd0, cx_next;
    reg [6:0] cy_reg = 7'd0, cy_next;
    reg left_bank_reg = 1'b0, left_bank_next;
    reg right_bank_reg = 1'b0, right_bank_next;
    reg [15:0] sync_reg = 16'd0, sync_next;
    reg [5:0] d_reg = 6'd1, d_next;
    reg [5:0] d_max_reg = 6'd0, d_max_next;
    reg [2:0] col_reg = 3'd0, col_next;
    reg [2:0] row_reg = 3'd0, row_next;
    reg [13:0] base_reg = 14'd0, base_next;
    reg [13:0] addr_reg = 14'd0, addr_next;
    reg [12:0] cost_reg = 13'd0, cost_next;
    reg [12:0] best_cost_reg = 13'h1fff, best_cost_next;
    reg [5:0] best_d_reg = 6'd0, best_d_next;
    // 20 horizontal gradient terms, each at most 510: max total 10200.
    reg [13:0] gradient_cost_reg = 14'd0, gradient_cost_next;
    reg [13:0] best_gradient_reg = 14'h3fff, best_gradient_next;
    reg [8:0] gradient_sample_reg = 9'd0, gradient_sample_next;
    reg [7:0] previous_left_reg = 8'd0, previous_left_next;
    reg [7:0] previous_right_reg = 8'd0, previous_right_next;
    wire [8:0] gradient_lhs;
    wire [8:0] gradient_rhs;
    wire [8:0] gradient_error;
    wire candidate_better;
    reg [13:0] second_rank_reg = 14'h3fff, second_rank_next;
    wire [13:0] candidate_rank;
    wire [13:0] best_rank;
    wire unique_window;
    wire [5:0] centre_left_delta, centre_right_delta, edge_delta;
    wire centre_supported, edge_left_supported, edge_right_supported;
    reg [7:0] min_reg = 8'hff, min_next;
    reg [7:0] max_reg = 8'd0, max_next;
    reg [15:0] wait_reg = 16'd0, wait_next;
    reg valid_reg = 1'b0, valid_next;
    reg [5:0] disparity_reg = 6'd0, disparity_next;
    reg [15:0] distance_reg = 16'd0, distance_next;
    reg [12:0] match_cost_reg = 13'd0, match_cost_next;
    // The original centre remains the public target coordinate. Edge windows
    // change matching evidence only; every read still belongs to this exact pair.
    reg [1:0] window_reg = 2'd0, window_next;
    reg [7:0] window_x_reg = 8'd0, window_x_next;
    reg [7:0] edge_left_x_reg = 8'd0, edge_left_x_next;
    reg [7:0] edge_right_x_reg = 8'd0, edge_right_x_next;
    reg edge_left_enable_reg = 1'b0, edge_left_enable_next;
    reg edge_right_enable_reg = 1'b0, edge_right_enable_next;
    reg centre_valid_reg = 1'b0, centre_valid_next;
    reg edge_left_valid_reg = 1'b0, edge_left_valid_next;
    reg edge_right_valid_reg = 1'b0, edge_right_valid_next;
    reg [5:0] centre_d_reg = 6'd0, centre_d_next;
    reg [5:0] edge_left_d_reg = 6'd0, edge_left_d_next;
    reg [5:0] edge_right_d_reg = 6'd0, edge_right_d_next;
    reg [12:0] centre_cost_reg = 13'd0, centre_cost_next;
    reg [12:0] edge_left_cost_reg = 13'd0, edge_left_cost_next;
    reg [12:0] edge_right_cost_reg = 13'd0, edge_right_cost_next;
    reg [5:0] selected_d_reg = 6'd0, selected_d_next;
    reg [12:0] selected_cost_reg = 13'd0, selected_cost_next;
    wire [8:0] input_left_x;
    wire [8:0] input_right_x;
    wire input_edges_fit;
    wire window_valid;
    wire all_windows_valid;
    wire [5:0] median_d;
    reg choose_valid = 1'b0;
    reg [5:0] choose_d = 6'd0;
    reg [12:0] choose_cost = 13'd0;
    wire [8:0] bbox_sum_x;
    wire [7:0] bbox_sum_y;
    wire [7:0] abs_diff;
    wire [7:0] texture_range;
    wire [7:0] available_d;
    wire [6:0] top_y;
    wire [13:0] top_row_base;
    wire [15:0] lut_distance;

    assign bbox_sum_x = {1'b0, bbox_x1_i} + {1'b0, bbox_x2_i};
    assign bbox_sum_y = {1'b0, bbox_y1_i} + {1'b0, bbox_y2_i};
    assign abs_diff = left_rd_data_i >= right_rd_data_i ?
        left_rd_data_i - right_rd_data_i : right_rd_data_i - left_rd_data_i;
    // Unsigned sums implement abs((L-Lprev)-(R-Rprev)) without signed truncation.
    assign gradient_lhs = {1'b0, left_rd_data_i} + {1'b0, previous_right_reg};
    assign gradient_rhs = {1'b0, right_rd_data_i} + {1'b0, previous_left_reg};
    assign gradient_error = gradient_lhs >= gradient_rhs ?
                            gradient_lhs - gradient_rhs : gradient_rhs - gradient_lhs;
    // Qualify EACH disparity by the unchanged raw SAD cutoff before ranking.
    // Tie order: gradient error, raw SAD, then the earlier (smaller) disparity.
    assign candidate_better = GRADIENT_RANKING != 0 ?
        (cost_reg <= MAX_MATCH_COST &&
         (gradient_cost_reg < best_gradient_reg ||
          (gradient_cost_reg == best_gradient_reg && cost_reg < best_cost_reg))) :
        cost_reg < best_cost_reg;
    assign candidate_rank = GRADIENT_RANKING != 0 ?
                            gradient_cost_reg : {1'b0, cost_reg};
    assign best_rank = GRADIENT_RANKING != 0 ?
                       best_gradient_reg : {1'b0, best_cost_reg};
    // Include adjacent disparities: broad or tied minima are also uncertain.
    // Extend the addition so the invalid sentinel cannot wrap.
    assign unique_window = {1'b0, second_rank_reg} >
                           {1'b0, best_rank} + {4'd0, best_rank[13:3]};
    assign texture_range = max_reg - min_reg;
    assign available_d = 8'd157 - window_x_reg;
    assign top_y = cy_reg - 7'd2;
    // 160 = 128+32. RANGE_CHECK/RANGE_NEXT load this only for legal ROI windows.
    assign top_row_base = ({7'd0, top_y} << 7) + ({7'd0, top_y} << 5);
    assign input_left_x = {1'b0, bbox_x1_i} + 9'd2;
    assign input_right_x = {1'b0, bbox_x2_i} - 9'd2;
    assign input_edges_fit = {1'b0, bbox_x2_i} >= {1'b0, bbox_x1_i} + 9'd4 &&
                            {1'b0, bbox_y2_i} >= {1'b0, bbox_y1_i} + 8'd4;
    assign window_valid = best_d_reg != 6'd0 && best_cost_reg <= MAX_MATCH_COST &&
                          texture_range >= MIN_TEXTURE_RANGE &&
                          (REJECT_AMBIGUOUS == 0 || unique_window);
    assign all_windows_valid = centre_valid_reg && edge_left_valid_reg &&
                               edge_right_valid_reg;
    assign median_d = centre_d_reg > edge_left_d_reg ?
        (edge_left_d_reg > edge_right_d_reg ? edge_left_d_reg :
         (centre_d_reg > edge_right_d_reg ? edge_right_d_reg : centre_d_reg)) :
        (centre_d_reg > edge_right_d_reg ? centre_d_reg :
         (edge_left_d_reg > edge_right_d_reg ? edge_right_d_reg : edge_left_d_reg));
    assign centre_left_delta = centre_d_reg >= edge_left_d_reg ?
        centre_d_reg - edge_left_d_reg : edge_left_d_reg - centre_d_reg;
    assign centre_right_delta = centre_d_reg >= edge_right_d_reg ?
        centre_d_reg - edge_right_d_reg : edge_right_d_reg - centre_d_reg;
    assign edge_delta = edge_left_d_reg >= edge_right_d_reg ?
        edge_left_d_reg - edge_right_d_reg : edge_right_d_reg - edge_left_d_reg;
    assign centre_supported = REQUIRE_WINDOW_AGREEMENT == 0 ||
        (edge_left_valid_reg && centre_left_delta <= WINDOW_AGREEMENT_TOLERANCE) ||
        (edge_right_valid_reg && centre_right_delta <= WINDOW_AGREEMENT_TOLERANCE);
    assign edge_left_supported = REQUIRE_WINDOW_AGREEMENT == 0 ||
        (centre_valid_reg && centre_left_delta <= WINDOW_AGREEMENT_TOLERANCE) ||
        (edge_right_valid_reg && edge_delta <= WINDOW_AGREEMENT_TOLERANCE);
    assign edge_right_supported = REQUIRE_WINDOW_AGREEMENT == 0 ||
        (centre_valid_reg && centre_right_delta <= WINDOW_AGREEMENT_TOLERANCE) ||
        (edge_left_valid_reg && edge_delta <= WINDOW_AGREEMENT_TOLERANCE);
    assign pair_accept_o = state_reg == RANGE_IDLE && !rst;
    assign pair_done_o = state_reg == RANGE_DONE && !rst;
    assign range_done_o = pair_done_o;
    assign left_rd_en_o = state_reg == RANGE_READ && !rst;
    assign right_rd_en_o = left_rd_en_o;
    assign left_rd_bank_o = left_bank_reg;
    assign right_rd_bank_o = right_bank_reg;
    assign right_rd_addr_o = addr_reg;
    assign left_rd_addr_o = addr_reg + {8'd0, d_reg};
    assign busy_o = state_reg != RANGE_IDLE;
    assign range_valid_o = valid_reg;
    assign disparity_o = disparity_reg;
    assign distance_mm_o = distance_reg;
    assign match_cost_o = match_cost_reg;
    assign target_x_o = cx_reg;
    assign target_y_o = cy_reg;
    assign pair_sync_id_o = sync_reg;

    stereo_depth_lut #(.FB_CONSTANT(FB_CONSTANT)) stereo_depth_lut_inst (
        .disparity_i(selected_d_reg),
        .distance_mm_o(lut_distance)
    );

    // Preserve original raw SAD and all numerical quality cutoffs. With three
    // usable windows use the median disparity, rejecting a single displacement
    // outlier. With fewer windows retain the lowest-SAD usable candidate.
    // Enabled confidence gates reject ambiguous or unsupported windows.
    // Order resolves equal costs in favour of centre, then the left edge.
    always @* begin
        choose_valid = 1'b0;
        choose_d = 6'd0;
        choose_cost = centre_cost_reg;
        if (centre_valid_reg && centre_supported &&
            (!all_windows_valid || centre_d_reg == median_d)) begin
            choose_valid = 1'b1;
            choose_d = centre_d_reg;
            choose_cost = centre_cost_reg;
        end
        if (edge_left_valid_reg && edge_left_supported &&
            (!all_windows_valid || edge_left_d_reg == median_d) &&
            (!choose_valid || edge_left_cost_reg < choose_cost)) begin
            choose_valid = 1'b1;
            choose_d = edge_left_d_reg;
            choose_cost = edge_left_cost_reg;
        end
        if (edge_right_valid_reg && edge_right_supported &&
            (!all_windows_valid || edge_right_d_reg == median_d) &&
            (!choose_valid || edge_right_cost_reg < choose_cost)) begin
            choose_valid = 1'b1;
            choose_d = edge_right_d_reg;
            choose_cost = edge_right_cost_reg;
        end
    end

    always @* begin
        state_next = state_reg;
        bbox_ok_next = bbox_ok_reg;
        cx_next = cx_reg;
        cy_next = cy_reg;
        left_bank_next = left_bank_reg;
        right_bank_next = right_bank_reg;
        sync_next = sync_reg;
        d_next = d_reg;
        d_max_next = d_max_reg;
        col_next = col_reg;
        row_next = row_reg;
        base_next = base_reg;
        addr_next = addr_reg;
        cost_next = cost_reg;
        best_cost_next = best_cost_reg;
        best_d_next = best_d_reg;
        gradient_cost_next = gradient_cost_reg;
        best_gradient_next = best_gradient_reg;
        second_rank_next = second_rank_reg;
        gradient_sample_next = gradient_sample_reg;
        previous_left_next = previous_left_reg;
        previous_right_next = previous_right_reg;
        min_next = min_reg;
        max_next = max_reg;
        wait_next = wait_reg;
        valid_next = valid_reg;
        disparity_next = disparity_reg;
        distance_next = distance_reg;
        match_cost_next = match_cost_reg;
        window_next = window_reg;
        window_x_next = window_x_reg;
        edge_left_x_next = edge_left_x_reg;
        edge_right_x_next = edge_right_x_reg;
        edge_left_enable_next = edge_left_enable_reg;
        edge_right_enable_next = edge_right_enable_reg;
        centre_valid_next = centre_valid_reg;
        edge_left_valid_next = edge_left_valid_reg;
        edge_right_valid_next = edge_right_valid_reg;
        centre_d_next = centre_d_reg;
        edge_left_d_next = edge_left_d_reg;
        edge_right_d_next = edge_right_d_reg;
        centre_cost_next = centre_cost_reg;
        edge_left_cost_next = edge_left_cost_reg;
        edge_right_cost_next = edge_right_cost_reg;
        selected_d_next = selected_d_reg;
        selected_cost_next = selected_cost_reg;


        case (state_reg)
            RANGE_IDLE: begin
                if (pair_valid_i) begin
                    // Accept snapshots all calculation inputs; later input changes ignored.
                    cx_next = bbox_sum_x[8:1];
                    cy_next = bbox_sum_y[7:1];
                    bbox_ok_next = bbox_valid_i && bbox_x1_i <= bbox_x2_i &&
                        bbox_y1_i <= bbox_y2_i && bbox_x2_i <= 8'd159 &&
                        bbox_y2_i <= 7'd89;
                    left_bank_next = left_bank_i;
                    right_bank_next = right_bank_i;
                    sync_next = pair_sync_id_i;
                    valid_next = 1'b0;
                    disparity_next = 6'd0;
                    distance_next = 16'd0;
                    match_cost_next = 13'd0;
                    window_next = 2'd0;
                    window_x_next = bbox_sum_x[8:1];
                    edge_left_x_next = input_left_x[7:0];
                    edge_right_x_next = input_right_x[7:0];
                    edge_left_enable_next = input_edges_fit && input_left_x >= 9'd2 &&
                        input_left_x <= 9'd156 && input_left_x != bbox_sum_x[8:1];
                    edge_right_enable_next = input_edges_fit && input_right_x >= 9'd2 &&
                        input_right_x <= 9'd156 && input_right_x != bbox_sum_x[8:1] &&
                        input_right_x != input_left_x;
                    centre_valid_next = 1'b0;
                    edge_left_valid_next = 1'b0;
                    edge_right_valid_next = 1'b0;
                    centre_d_next = 6'd0;
                    edge_left_d_next = 6'd0;
                    edge_right_d_next = 6'd0;
                    centre_cost_next = 13'd0;
                    edge_left_cost_next = 13'd0;
                    edge_right_cost_next = 13'd0;
                    selected_d_next = 6'd0;
                    selected_cost_next = 13'd0;
                    best_cost_next = 13'h1fff;
                    best_d_next = 6'd0;
                    best_gradient_next = 14'h3fff;
                second_rank_next = 14'h3fff;
                    gradient_cost_next = 14'd0;
                    gradient_sample_next = 9'd0;
                    previous_left_next = 8'd0;
                    previous_right_next = 8'd0;
                    min_next = 8'hff;
                    max_next = 8'd0;
                    state_next = RANGE_CHECK;
                end
            end
            RANGE_CHECK: begin
                if (!bbox_ok_reg || cx_reg < 8'd2 || cx_reg > 8'd156 ||
                    cy_reg < 7'd2 || cy_reg > 7'd87 || FB_CONSTANT == 32'd0) begin
                    // Invalid box/ROI releases without issuing any RAM request.
                    state_next = RANGE_DONE;
                end else begin
                    d_next = 6'd1;
                    d_max_next = available_d > 8'd31 ? 6'd31 : available_d[5:0];
                    base_next = top_row_base + {6'd0, window_x_reg} - 14'd2;
                    addr_next = base_next;
                    col_next = 3'd0;
                    row_next = 3'd0;
                    cost_next = 13'd0;
                    state_next = RANGE_READ;
                end
            end
            RANGE_READ: begin
                wait_next = 16'd0;
                state_next = RANGE_WAIT;
            end
            RANGE_WAIT: begin
                // RAM samples request in READ; data/valid are consumed on next edge.
                if (left_rd_valid_i && right_rd_valid_i) begin
                    cost_next = cost_reg + {5'd0, abs_diff};
                    if (d_reg == 6'd1) begin
                        if (right_rd_data_i < min_reg) min_next = right_rd_data_i;
                        if (right_rd_data_i > max_reg) max_next = right_rd_data_i;
                    end
                    if (GRADIENT_RANKING != 0) begin
                        // Register the term before the 14-bit accumulation; this
                        // adds one calculation cycle/pixel, not a video pipeline.
                        gradient_sample_next = col_reg == 3'd0 ? 9'd0 : gradient_error;
                        previous_left_next = left_rd_data_i;
                        previous_right_next = right_rd_data_i;
                        state_next = RANGE_GRADIENT;
                    end else begin
                        if (col_reg == 3'd4 && row_reg == 3'd4) begin
                            state_next = RANGE_EVAL;
                        end else begin
                            if (col_reg == 3'd4) begin
                                col_next = 3'd0;
                                row_next = row_reg + 3'd1;
                                addr_next = addr_reg + 14'd156;
                            end else begin
                                col_next = col_reg + 3'd1;
                                addr_next = addr_reg + 14'd1;
                            end
                            state_next = RANGE_READ;
                        end
                    end
                end else if (wait_reg == READ_TIMEOUT_CYCLES - 1) begin
                    // A missing paired return must not leave frame banks locked forever.
                    state_next = RANGE_DONE;
                end else begin
                    wait_next = wait_reg + 16'd1;
                end
            end
            RANGE_GRADIENT: begin
                gradient_cost_next = gradient_cost_reg + {5'd0, gradient_sample_reg};
                if (col_reg == 3'd4 && row_reg == 3'd4) begin
                    state_next = RANGE_EVAL;
                end else begin
                    if (col_reg == 3'd4) begin
                        col_next = 3'd0;
                        row_next = row_reg + 3'd1;
                        addr_next = addr_reg + 14'd156;
                    end else begin
                        col_next = col_reg + 3'd1;
                        addr_next = addr_reg + 14'd1;
                    end
                    state_next = RANGE_READ;
                end
            end
            RANGE_EVAL: begin
                if (REJECT_AMBIGUOUS != 0 && cost_reg <= MAX_MATCH_COST) begin
                    if (candidate_better) second_rank_next = best_rank;
                    else if (candidate_rank < second_rank_reg)
                        second_rank_next = candidate_rank;
                end
                if (candidate_better) begin
                    best_gradient_next = gradient_cost_reg;
                    best_cost_next = cost_reg;
                    best_d_next = d_reg;
                end
                if (d_reg == d_max_reg) begin
                    state_next = RANGE_RECORD;
                end else begin
                    d_next = d_reg + 6'd1;
                    gradient_cost_next = 14'd0;
                    previous_left_next = 8'd0;
                    previous_right_next = 8'd0;
                    cost_next = 13'd0;
                    col_next = 3'd0;
                    row_next = 3'd0;
                    addr_next = base_reg;
                    state_next = RANGE_READ;
                end
            end
            RANGE_RECORD: begin
                case (window_reg)
                    2'd0: begin
                        centre_valid_next = window_valid;
                        centre_d_next = best_d_reg;
                        centre_cost_next = best_cost_reg;
                    end
                    2'd1: begin
                        edge_left_valid_next = window_valid;
                        edge_left_d_next = best_d_reg;
                        edge_left_cost_next = best_cost_reg;
                    end
                    default: begin
                        edge_right_valid_next = window_valid;
                        edge_right_d_next = best_d_reg;
                        edge_right_cost_next = best_cost_reg;
                    end
                endcase
                if (window_reg == 2'd0 && edge_left_enable_reg) begin
                    window_next = 2'd1;
                    window_x_next = edge_left_x_reg;
                    state_next = RANGE_NEXT;
                end else if (window_reg != 2'd2 && edge_right_enable_reg) begin
                    window_next = 2'd2;
                    window_x_next = edge_right_x_reg;
                    state_next = RANGE_NEXT;
                end else begin
                    state_next = RANGE_SELECT;
                end
            end
            RANGE_NEXT: begin
                d_next = 6'd1;
                d_max_next = available_d > 8'd31 ? 6'd31 : available_d[5:0];
                base_next = top_row_base + {6'd0, window_x_reg} - 14'd2;
                addr_next = base_next;
                col_next = 3'd0;
                row_next = 3'd0;
                cost_next = 13'd0;
                best_cost_next = 13'h1fff;
                best_d_next = 6'd0;
                best_gradient_next = 14'h3fff;
                second_rank_next = 14'h3fff;
                gradient_cost_next = 14'd0;
                gradient_sample_next = 9'd0;
                previous_left_next = 8'd0;
                previous_right_next = 8'd0;
                min_next = 8'hff;
                max_next = 8'd0;
                state_next = RANGE_READ;
            end
            RANGE_SELECT: begin
                selected_d_next = choose_d;
                selected_cost_next = choose_cost;
                state_next = RANGE_LOOKUP;
            end
            RANGE_LOOKUP: begin
                match_cost_next = selected_cost_reg;
                if (selected_d_reg != 6'd0) begin
                    valid_next = 1'b1;
                    disparity_next = selected_d_reg;
                    distance_next = lut_distance;
                end
                state_next = RANGE_DONE;
            end
            RANGE_DONE: state_next = RANGE_IDLE;
            default: state_next = RANGE_IDLE;
        endcase
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        bbox_ok_reg <= bbox_ok_next;
        cx_reg <= cx_next;
        cy_reg <= cy_next;
        left_bank_reg <= left_bank_next;
        right_bank_reg <= right_bank_next;
        sync_reg <= sync_next;
        d_reg <= d_next;
        d_max_reg <= d_max_next;
        col_reg <= col_next;
        row_reg <= row_next;
        base_reg <= base_next;
        addr_reg <= addr_next;
        cost_reg <= cost_next;
        best_cost_reg <= best_cost_next;
        best_d_reg <= best_d_next;
        gradient_cost_reg <= gradient_cost_next;
        best_gradient_reg <= best_gradient_next;
        second_rank_reg <= second_rank_next;
        gradient_sample_reg <= gradient_sample_next;
        previous_left_reg <= previous_left_next;
        previous_right_reg <= previous_right_next;
        min_reg <= min_next;
        max_reg <= max_next;
        wait_reg <= wait_next;
        valid_reg <= valid_next;
        disparity_reg <= disparity_next;
        distance_reg <= distance_next;
        match_cost_reg <= match_cost_next;
        window_reg <= window_next;
        window_x_reg <= window_x_next;
        edge_left_x_reg <= edge_left_x_next;
        edge_right_x_reg <= edge_right_x_next;
        edge_left_enable_reg <= edge_left_enable_next;
        edge_right_enable_reg <= edge_right_enable_next;
        centre_valid_reg <= centre_valid_next;
        edge_left_valid_reg <= edge_left_valid_next;
        edge_right_valid_reg <= edge_right_valid_next;
        centre_d_reg <= centre_d_next;
        edge_left_d_reg <= edge_left_d_next;
        edge_right_d_reg <= edge_right_d_next;
        centre_cost_reg <= centre_cost_next;
        edge_left_cost_reg <= edge_left_cost_next;
        edge_right_cost_reg <= edge_right_cost_next;
        selected_d_reg <= selected_d_next;
        selected_cost_reg <= selected_cost_next;

        if (rst) begin
            state_reg <= RANGE_IDLE;
            bbox_ok_reg <= 1'b0;
            cx_reg <= 8'd0;
            cy_reg <= 7'd0;
            left_bank_reg <= 1'b0;
            right_bank_reg <= 1'b0;
            sync_reg <= 16'd0;
            d_reg <= 6'd1;
            d_max_reg <= 6'd0;
            col_reg <= 3'd0;
            row_reg <= 3'd0;
            base_reg <= 14'd0;
            addr_reg <= 14'd0;
            cost_reg <= 13'd0;
            best_cost_reg <= 13'h1fff;
            best_d_reg <= 6'd0;
            gradient_cost_reg <= 14'd0;
            best_gradient_reg <= 14'h3fff;
            second_rank_reg <= 14'h3fff;
            gradient_sample_reg <= 9'd0;
            previous_left_reg <= 8'd0;
            previous_right_reg <= 8'd0;
            min_reg <= 8'hff;
            max_reg <= 8'd0;
            wait_reg <= 16'd0;
            valid_reg <= 1'b0;
            disparity_reg <= 6'd0;
            distance_reg <= 16'd0;
            match_cost_reg <= 13'd0;
            window_reg <= 2'd0;
            window_x_reg <= 8'd0;
            edge_left_x_reg <= 8'd0;
            edge_right_x_reg <= 8'd0;
            edge_left_enable_reg <= 1'b0;
            edge_right_enable_reg <= 1'b0;
            centre_valid_reg <= 1'b0;
            edge_left_valid_reg <= 1'b0;
            edge_right_valid_reg <= 1'b0;
            centre_d_reg <= 6'd0;
            edge_left_d_reg <= 6'd0;
            edge_right_d_reg <= 6'd0;
            centre_cost_reg <= 13'd0;
            edge_left_cost_reg <= 13'd0;
            edge_right_cost_reg <= 13'd0;
            selected_d_reg <= 6'd0;
            selected_cost_reg <= 13'd0;

        end
    end
endmodule
`resetall
