// File: stereo_pair_ctrl.v
// Author: Codex
// Date: 2026-10-02
// Description: Match committed Gray banks by sync identity and reserve until done.
// Change Log: 2026-10-02 Codex v1.0 Stereo stage 5 metadata scheduler.
// 2026-10-12 Codex Parallel exact-pair selection; no cycle or priority change.
// 2026-10-03 Codex v1.1 Lock exact pairs until delayed source-matched results.
// No image RAM; duplicate results cannot refresh the bounded result lifetime.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_pair_ctrl #(
    parameter WAIT_FOR_BBOX = 0,
    parameter BBOX_WAIT_CYCLES = 375000000
) (
    input  wire clk,
    input  wire rst,
    input  wire [1:0] left_bank_valid_i,
    input  wire [65:0] left_bank_metadata_i,
    input  wire [1:0] right_bank_valid_i,
    input  wire [191:0] right_bank_metadata_i,
    input  wire [31:0] left_busy_drop_count_i,
    input  wire [31:0] right_busy_drop_count_i,
    input  wire bbox_result_valid_i,
    input  wire [63:0] bbox_result_metadata_i,
    output wire bbox_waiting_o,
    output wire [31:0] bbox_timeout_count_o,
    input  wire pair_accept_i,
    input  wire pair_done_i,
    output wire [1:0] left_bank_lock_o,
    output wire [1:0] right_bank_lock_o,
    output wire [1:0] left_bank_release_o,
    output wire [1:0] right_bank_release_o,
    output wire [1:0] left_bank_discard_o,
    output wire [1:0] right_bank_discard_o,
    output wire pair_valid_o,
    output wire pair_start_o,
    output wire pair_busy_o,
    output wire [15:0] pair_sync_id_o,
    output wire left_bank_o,
    output wire right_bank_o,
    output wire [15:0] left_source_frame_id_o,
    output wire [15:0] right_source_frame_id_o,
    output wire pair_bbox_valid_o,
    output wire [7:0] pair_bbox_x1_o,
    output wire [6:0] pair_bbox_y1_o,
    output wire [7:0] pair_bbox_x2_o,
    output wire [6:0] pair_bbox_y2_o,
    output wire [15:0] pair_bbox_result_id_o,
    output wire [15:0] pair_udp_frame_id_o,
    output wire [31:0] pair_count_o,
    output wire [31:0] pair_mismatch_drop_count_o,
    output wire [31:0] pair_busy_drop_count_o,
    output wire [15:0] last_pair_sync_id_o
);
    // Metadata layout (LSB first): sync_valid, sync_id16, source_id16;
    // RIGHT additionally bbox_valid, x1_8, y1_7, x2_8, y2_7, result16, udp16.
    // One-hot scheduling. OFFER already reserves both banks before accept.
    localparam [3:0] PAIR_IDLE = 4'b0001, PAIR_WAIT = 4'b0010,
                     PAIR_OFFER = 4'b0100, PAIR_ACTIVE = 4'b1000;
    localparam integer WAIT_WIDTH = $clog2(BBOX_WAIT_CYCLES + 1);
    localparam [WAIT_WIDTH-1:0] WAIT_LAST = BBOX_WAIT_CYCLES - 1;
    reg [3:0] state_reg = PAIR_IDLE, state_next;
    reg [WAIT_WIDTH-1:0] wait_reg = {WAIT_WIDTH{1'b0}}, wait_next;
    reg [WAIT_WIDTH-1:0] result_age_reg = {WAIT_WIDTH{1'b0}}, result_age_next;
    reg result_seen_reg = 1'b0, result_seen_next;
    reg [63:0] result_reg = 64'd0, result_next;
    reg [31:0] timeout_reg = 32'd0, timeout_next;
    wire new_result, result_fresh;
    reg left_bank_reg = 1'b0, left_bank_next;
    reg right_bank_reg = 1'b0, right_bank_next;
    reg [32:0] left_meta_reg = 33'd0, left_meta_next;
    reg [95:0] right_meta_reg = 96'd0, right_meta_next;
    reg watermark_valid_reg = 1'b0, watermark_valid_next;
    reg [15:0] watermark_reg = 16'd0, watermark_next;
    reg start_reg = 1'b0, start_next;
    reg [31:0] count_reg = 32'd0, count_next;
    reg [31:0] mismatch_reg = 32'd0, mismatch_next;
    reg [1:0] left_lock, right_lock, left_release, right_release;
    reg [1:0] left_discard, right_discard, left_usable, right_usable;
    reg found;
    reg selected_left, selected_right;
    reg [3:0] pair_match;
    wire [32:0] left_meta [0:1];
    wire [95:0] right_meta [0:1];
    wire [15:0] left_id [0:1];
    wire [15:0] right_id [0:1];
    integer li, ri;

    function forward;
        input [15:0] new_id;
        input [15:0] old_id;
        reg [15:0] delta;
        begin
            delta = new_id - old_id;
            forward = delta != 16'd0 && !delta[15];
        end
    endfunction

    assign left_meta[0] = left_bank_metadata_i[32:0];
    assign left_meta[1] = left_bank_metadata_i[65:33];
    assign right_meta[0] = right_bank_metadata_i[95:0];
    assign right_meta[1] = right_bank_metadata_i[191:96];
    assign left_id[0] = left_meta[0][16:1];
    assign left_id[1] = left_meta[1][16:1];
    assign right_id[0] = right_meta[0][16:1];
    assign right_id[1] = right_meta[1][16:1];
    assign left_bank_lock_o = left_lock;
    assign right_bank_lock_o = right_lock;
    assign left_bank_release_o = left_release;
    assign right_bank_release_o = right_release;
    assign left_bank_discard_o = left_discard;
    assign right_bank_discard_o = right_discard;
    assign bbox_waiting_o = state_reg == PAIR_WAIT;
    assign bbox_timeout_count_o = timeout_reg;
    assign new_result = bbox_result_valid_i && bbox_result_metadata_i[32] &&
        (!result_seen_reg || bbox_result_metadata_i[31:0] != result_reg[31:0]);
    assign result_fresh = result_seen_reg && result_age_reg < WAIT_LAST;
    assign pair_valid_o = state_reg == PAIR_OFFER;
    assign pair_busy_o = state_reg == PAIR_ACTIVE;
    assign pair_start_o = start_reg;
    assign left_bank_o = left_bank_reg;
    assign right_bank_o = right_bank_reg;
    assign pair_sync_id_o = left_meta_reg[16:1];
    assign left_source_frame_id_o = left_meta_reg[32:17];
    assign right_source_frame_id_o = right_meta_reg[32:17];
    assign pair_bbox_valid_o = right_meta_reg[33];
    assign pair_bbox_x1_o = right_meta_reg[41:34];
    assign pair_bbox_y1_o = right_meta_reg[48:42];
    assign pair_bbox_x2_o = right_meta_reg[56:49];
    assign pair_bbox_y2_o = right_meta_reg[63:57];
    assign pair_bbox_result_id_o = right_meta_reg[79:64];
    assign pair_udp_frame_id_o = right_meta_reg[95:80];
    assign pair_count_o = count_reg;
    assign pair_mismatch_drop_count_o = mismatch_reg;
    assign pair_busy_drop_count_o = left_busy_drop_count_i + right_busy_drop_count_i;
    assign last_pair_sync_id_o = watermark_reg;

    // Attach a result to preserved image metadata only AFTER exact source matching.
    // Layout is the existing RIGHT bank layout. Padding-only/illegal boxes stay invalid.
    function [95:0] attach_result;
        input [95:0] image_metadata;
        input [63:0] detection;
        reg valid_box;
        reg [6:0] y1, y2;
        begin
            valid_box = detection[63] && detection[62:55] <= detection[47:40] &&
                detection[54:48] <= detection[39:33] && detection[47:40] <= 8'd159 &&
                detection[39:33] <= 7'd119 && detection[54:48] <= 7'd104 &&
                detection[39:33] >= 7'd15;
            y1 = detection[54:48] < 7'd15 ? 7'd15 : detection[54:48];
            y2 = detection[39:33] > 7'd104 ? 7'd104 : detection[39:33];
            attach_result = {image_metadata[95:80], detection[15:0],
                valid_box ? y2 - 7'd15 : 7'd0,
                valid_box ? detection[47:40] : 8'd0,
                valid_box ? y1 - 7'd15 : 7'd0,
                valid_box ? detection[62:55] : 8'd0, valid_box, image_metadata[32:0]};
        end
    endfunction

    initial begin
        if (BBOX_WAIT_CYCLES < 2) begin
            $error("BBOX_WAIT_CYCLES must be at least two");
            $finish;
        end
    end

    always @* begin
        state_next = state_reg;
        wait_next = wait_reg;
        result_age_next = result_age_reg;
        result_seen_next = result_seen_reg;
        result_next = result_reg;
        timeout_next = timeout_reg;
        if (result_seen_reg && result_age_reg < WAIT_LAST)
            result_age_next = result_age_reg + {{(WAIT_WIDTH-1){1'b0}}, 1'b1};
        if (WAIT_FOR_BBOX && new_result) begin
            result_next = bbox_result_metadata_i;
            result_seen_next = 1'b1;
            result_age_next = {WAIT_WIDTH{1'b0}};
        end
        left_bank_next = left_bank_reg;
        right_bank_next = right_bank_reg;
        left_meta_next = left_meta_reg;
        right_meta_next = right_meta_reg;
        watermark_valid_next = watermark_valid_reg;
        watermark_next = watermark_reg;
        start_next = 1'b0;
        count_next = count_reg;
        mismatch_next = mismatch_reg;
        left_lock = 2'd0;
        right_lock = 2'd0;
        left_release = 2'd0;
        right_release = 2'd0;
        left_discard = 2'd0;
        right_discard = 2'd0;
        left_usable = left_bank_valid_i;
        right_usable = right_bank_valid_i;
        found = 1'b0;
        selected_left = 1'b0;
        selected_right = 1'b0;
        pair_match = 4'd0;

        case (state_reg)
            PAIR_IDLE: begin
                // Reject unsynchronized frames and IDs at/behind the accepted watermark.
                // This also rejects half-range ambiguous distance 32768 from watermark.
                for (li = 0; li < 2; li = li + 1) begin
                    if (left_bank_valid_i[li] && (!left_meta[li][0] ||
                        (watermark_valid_reg && !forward(left_id[li], watermark_reg))))
                        left_discard[li] = 1'b1;
                    if (right_bank_valid_i[li] && (!right_meta[li][0] ||
                        (watermark_valid_reg && !forward(right_id[li], watermark_reg))))
                        right_discard[li] = 1'b1;
                end
                left_usable = left_bank_valid_i & ~left_discard;
                right_usable = right_bank_valid_i & ~right_discard;
                // Compare all bank identities in parallel. A matching LEFT bank
                // has one identity regardless of which RIGHT bank matched it.
                // Compare the two LEFT identities once, avoiding the original
                // chain of candidate muxes and modular-order subtractors.
                pair_match[0] = left_usable[0] && right_usable[0] && left_id[0] == right_id[0];
                pair_match[1] = left_usable[0] && right_usable[1] && left_id[0] == right_id[1];
                pair_match[2] = left_usable[1] && right_usable[0] && left_id[1] == right_id[0];
                pair_match[3] = left_usable[1] && right_usable[1] && left_id[1] == right_id[1];
                found = |pair_match;
                selected_left = (|pair_match[3:2]) &&
                    (!(|pair_match[1:0]) || forward(left_id[0], left_id[1]));
                // Equal IDs and half-range ambiguity retain the original bank0
                // priority; RIGHT bank0 wins when duplicate images both match.
                selected_right = found &&
                    (selected_left ? !pair_match[2] : !pair_match[0]);
                if (found) begin
                    left_bank_next = selected_left;
                    right_bank_next = selected_right;
                    left_meta_next = left_meta[selected_left];
                    right_meta_next = right_meta[selected_right];
                    left_lock[selected_left] = 1'b1;
                    right_lock[selected_right] = 1'b1;
                    state_next = WAIT_FOR_BBOX ? PAIR_WAIT : PAIR_OFFER;
                    wait_next = {WAIT_WIDTH{1'b0}};
                end else begin
                    // No exact match remains: peer advancement proves older frame stale.
                    // Ambiguous half-range separation discards both, never invents order.
                    for (li = 0; li < 2; li = li + 1) begin
                        for (ri = 0; ri < 2; ri = ri + 1) begin
                            if (left_usable[li] && right_usable[ri]) begin
                                if (forward(right_id[ri], left_id[li]))
                                    left_discard[li] = 1'b1;
                                if (forward(left_id[li], right_id[ri]))
                                    right_discard[ri] = 1'b1;
                                if ((left_id[li] - right_id[ri]) == 16'h8000) begin
                                    left_discard[li] = 1'b1;
                                    right_discard[ri] = 1'b1;
                                end
                            end
                        end
                    end
                    // If peer is silent, retain newest bank and make room for next frame.
                    // Equal unpaired duplicates retain bank0. Ambiguous own pair drops both.
                    if (left_usable == 2'b11) begin
                        if (forward(left_id[1], left_id[0])) left_discard[0] = 1'b1;
                        else if (forward(left_id[0], left_id[1]) ||
                                 left_id[0] == left_id[1]) left_discard[1] = 1'b1;
                        else left_discard = 2'b11;
                    end
                    if (right_usable == 2'b11) begin
                        if (forward(right_id[1], right_id[0])) right_discard[0] = 1'b1;
                        else if (forward(right_id[0], right_id[1]) ||
                                 right_id[0] == right_id[1]) right_discard[1] = 1'b1;
                        else right_discard = 2'b11;
                    end
                end
                mismatch_next = mismatch_reg + {31'd0, left_discard[0]} +
                    {31'd0, left_discard[1]} + {31'd0, right_discard[0]} +
                    {31'd0, right_discard[1]};
            end
            PAIR_WAIT: begin
                // Retain the exact matched images. Other frames cannot consume the
                // free bank indefinitely while inference is still running.
                left_lock[left_bank_reg] = 1'b1;
                right_lock[right_bank_reg] = 1'b1;
                left_discard = left_bank_valid_i & ~(2'b01 << left_bank_reg);
                right_discard = right_bank_valid_i & ~(2'b01 << right_bank_reg);
                mismatch_next = mismatch_reg + {31'd0, left_discard[0]} +
                    {31'd0, left_discard[1]} + {31'd0, right_discard[0]} +
                    {31'd0, right_discard[1]};
                if (new_result && bbox_result_metadata_i[31:16] == right_meta_reg[32:17]) begin
                    right_meta_next = attach_result(right_meta_reg, bbox_result_metadata_i);
                    state_next = PAIR_OFFER;
                end else if (result_fresh && result_reg[31:16] == right_meta_reg[32:17]) begin
                    right_meta_next = attach_result(right_meta_reg, result_reg);
                    state_next = PAIR_OFFER;
                end else if (wait_reg == WAIT_LAST) begin
                    // Timeout discards both images. It cannot publish a fake result.
                    left_release[left_bank_reg] = 1'b1;
                    right_release[right_bank_reg] = 1'b1;
                    state_next = PAIR_IDLE;
                    timeout_next = timeout_reg + 32'd1;
                    mismatch_next = mismatch_next + 32'd2;
                end else wait_next = wait_reg + {{(WAIT_WIDTH-1){1'b0}}, 1'b1};
            end
            PAIR_OFFER: begin
                left_lock[left_bank_reg] = 1'b1;
                right_lock[right_bank_reg] = 1'b1;
                if (pair_accept_i) begin
                    state_next = PAIR_ACTIVE;
                    start_next = 1'b1;
                    count_next = count_reg + 32'd1;
                    watermark_valid_next = 1'b1;
                    watermark_next = left_meta_reg[16:1];
                end
            end
            PAIR_ACTIVE: begin
                left_lock[left_bank_reg] = 1'b1;
                right_lock[right_bank_reg] = 1'b1;
                if (pair_done_i) begin
                    left_release[left_bank_reg] = 1'b1;
                    right_release[right_bank_reg] = 1'b1;
                    state_next = PAIR_IDLE;
                end
            end
            default: state_next = PAIR_IDLE;
        endcase
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        wait_reg <= wait_next;
        result_age_reg <= result_age_next;
        result_seen_reg <= result_seen_next;
        result_reg <= result_next;
        timeout_reg <= timeout_next;
        left_bank_reg <= left_bank_next;
        right_bank_reg <= right_bank_next;
        left_meta_reg <= left_meta_next;
        right_meta_reg <= right_meta_next;
        watermark_valid_reg <= watermark_valid_next;
        watermark_reg <= watermark_next;
        start_reg <= start_next;
        count_reg <= count_next;
        mismatch_reg <= mismatch_next;
        if (rst) begin
            state_reg <= PAIR_IDLE;
            wait_reg <= {WAIT_WIDTH{1'b0}};
            result_age_reg <= {WAIT_WIDTH{1'b0}};
            result_seen_reg <= 1'b0;
            result_reg <= 64'd0;
            timeout_reg <= 32'd0;
            left_bank_reg <= 1'b0;
            right_bank_reg <= 1'b0;
            left_meta_reg <= 33'd0;
            right_meta_reg <= 96'd0;
            watermark_valid_reg <= 1'b0;
            watermark_reg <= 16'd0;
            start_reg <= 1'b0;
            count_reg <= 32'd0;
            mismatch_reg <= 32'd0;
        end
    end
endmodule
`resetall
