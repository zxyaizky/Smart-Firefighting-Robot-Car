// -----------------------------------------------------------------------------
// File   : fire_control_bridge.v
// Author : Codex
// Date   : 2026-10-05
// -----------------------------------------------------------------------------
// Description:
//   Passive 75 MHz B-board control tap. Count each complete NPU result once and
//   authorize only fresh range completions belonging to that exact NPU result.
//   All inputs already share the B-board HDMI pixel clock; there is no CDC here.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-05  Codex  v1.0  Independent frame identity and range safety bridge
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module fire_control_bridge #
(
    // Actual B-board HDMI pixel clock frequency.
    parameter integer CLK_FREQ_HZ = 75000000,
    // Maximum age of a distinct complete bbox result or authenticated range.
    parameter integer RESULT_TIMEOUT_MS = 5000
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        right_frame_end_i,
    input  wire [63:0] right_bbox_result_metadata_i,
    input  wire        link_fault_i,
    input  wire        pair_take_i,
    input  wire [15:0] pair_bbox_result_id_i,
    input  wire [15:0] pair_right_source_frame_id_i,
    input  wire [15:0] pair_sync_id_i,
    input  wire        range_done_i,
    input  wire        raw_range_valid_i,
    input  wire [15:0] range_pair_sync_id_i,
    output wire        fire_sample_o,
    output wire        fire_valid_o,
    output wire [7:0]  fire_center_x_o,
    output wire        distance_valid_o
);
    // Multiplication is explicitly 64 bit; 75 MHz * 5000 exceeds 32 bits.
    localparam [63:0] TIMEOUT_CYCLES_WIDE =
        (64'd1 * CLK_FREQ_HZ * RESULT_TIMEOUT_MS + 64'd999) / 64'd1000;
    localparam integer AGE_WIDTH = (TIMEOUT_CYCLES_WIDE < 64'd2) ?
        1 : $clog2(TIMEOUT_CYCLES_WIDE + 64'd1);
    localparam [AGE_WIDTH-1:0] TIMEOUT_CYCLES = TIMEOUT_CYCLES_WIDE;
    localparam [AGE_WIDTH-1:0] TIMEOUT_LAST = TIMEOUT_CYCLES_WIDE - 64'd1;

    reg bbox_seen_reg = 1'b0, bbox_seen_next;
    reg [15:0] bbox_result_reg = 16'd0, bbox_result_next;
    reg [15:0] bbox_source_reg = 16'd0, bbox_source_next;
    reg [AGE_WIDTH-1:0] bbox_age_reg = {AGE_WIDTH{1'b0}}, bbox_age_next;
    reg [AGE_WIDTH-1:0] range_age_reg = {AGE_WIDTH{1'b0}}, range_age_next;
    reg fire_sample_reg = 1'b0, fire_sample_next;
    reg fire_valid_reg = 1'b0, fire_valid_next;
    reg [7:0] fire_center_x_reg = 8'd80, fire_center_x_next;
    reg distance_valid_reg = 1'b0, distance_valid_next;
    reg range_pending_reg = 1'b0, range_pending_next;
    reg [15:0] pending_result_reg = 16'd0, pending_result_next;
    reg [15:0] pending_source_reg = 16'd0, pending_source_next;
    reg [15:0] pending_sync_reg = 16'd0, pending_sync_next;

    wire incoming_source_valid;
    wire incoming_fire;
    wire [7:0] incoming_x1, incoming_x2;
    wire [6:0] incoming_y1, incoming_y2;
    wire [15:0] incoming_source_id, incoming_result_id;
    wire [8:0] incoming_center_sum;
    wire incoming_box_legal;
    wire incoming_fire_valid;
    wire new_result;
    wire completed_frame_invalid;
    wire bbox_fresh;
    wire range_fresh;
    wire range_identity_matches;

    // Exact stereo_right_capture.v metadata_reg[63:0] layout (raw 160x120).
    assign incoming_fire         = right_bbox_result_metadata_i[63];
    assign incoming_x1           = right_bbox_result_metadata_i[62:55];
    assign incoming_y1           = right_bbox_result_metadata_i[54:48];
    assign incoming_x2           = right_bbox_result_metadata_i[47:40];
    assign incoming_y2           = right_bbox_result_metadata_i[39:33];
    assign incoming_source_valid = right_bbox_result_metadata_i[32];
    assign incoming_source_id    = right_bbox_result_metadata_i[31:16];
    assign incoming_result_id    = right_bbox_result_metadata_i[15:0];
    assign incoming_center_sum   = {1'b0, incoming_x1} + {1'b0, incoming_x2};
    assign incoming_box_legal = incoming_x1 <= incoming_x2 &&
        incoming_y1 <= incoming_y2 && incoming_x2 <= 8'd159 &&
        incoming_y2 <= 7'd119 && incoming_y1 <= 7'd104 && incoming_y2 >= 7'd15;
    assign incoming_fire_valid = incoming_source_valid && incoming_fire &&
                                 incoming_box_legal;
    assign new_result = right_frame_end_i && incoming_source_valid &&
        (!bbox_seen_reg || incoming_result_id != bbox_result_reg ||
         incoming_source_id != bbox_source_reg);
    assign completed_frame_invalid = right_frame_end_i && !incoming_fire_valid;
    assign bbox_fresh = bbox_seen_reg && bbox_age_reg < TIMEOUT_CYCLES;
    assign range_fresh = range_age_reg < TIMEOUT_CYCLES;
    assign range_identity_matches = range_pending_reg &&
        pending_sync_reg == range_pair_sync_id_i &&
        pending_result_reg == bbox_result_reg && pending_source_reg == bbox_source_reg;

    // Fault and raw range loss suppress control without waiting for an FSM tick.
    assign fire_sample_o   = fire_sample_reg && !rst && !link_fault_i;
    assign fire_valid_o    = fire_valid_reg && bbox_fresh && !rst && !link_fault_i &&
                             !completed_frame_invalid;
    assign fire_center_x_o = fire_center_x_reg;
    assign distance_valid_o = distance_valid_reg && range_fresh && fire_valid_o &&
                              raw_range_valid_i && !new_result;

    always @* begin
        bbox_seen_next = bbox_seen_reg;
        bbox_result_next = bbox_result_reg;
        bbox_source_next = bbox_source_reg;
        bbox_age_next = bbox_age_reg;
        range_age_next = range_age_reg;
        fire_sample_next = 1'b0;
        fire_valid_next = fire_valid_reg;
        fire_center_x_next = fire_center_x_reg;
        distance_valid_next = distance_valid_reg;
        range_pending_next = range_pending_reg;
        pending_result_next = pending_result_reg;
        pending_source_next = pending_source_reg;
        pending_sync_next = pending_sync_reg;

        if (bbox_seen_reg && bbox_age_reg < TIMEOUT_CYCLES) begin
            bbox_age_next = bbox_age_reg + {{(AGE_WIDTH-1){1'b0}}, 1'b1};
        end
        if (distance_valid_reg && range_age_reg < TIMEOUT_CYCLES) begin
            range_age_next = range_age_reg + {{(AGE_WIDTH-1){1'b0}}, 1'b1};
        end
        if (bbox_age_reg >= TIMEOUT_LAST) begin
            fire_valid_next = 1'b0;
            distance_valid_next = 1'b0;
        end
        if (range_age_reg >= TIMEOUT_LAST || !raw_range_valid_i) begin
            distance_valid_next = 1'b0;
        end

        // Completion consumes the previously accepted pair, including failures.
        if (range_done_i) begin
            range_pending_next = 1'b0;
            distance_valid_next = 1'b0;
            if (range_identity_matches && raw_range_valid_i && fire_valid_o &&
                !new_result && bbox_age_reg < TIMEOUT_LAST) begin
                distance_valid_next = 1'b1;
                range_age_next = {AGE_WIDTH{1'b0}};
            end
        end
        // A simultaneous next-pair acceptance belongs to the next completion.
        if (pair_take_i) begin
            range_pending_next = 1'b1;
            pending_result_next = pair_bbox_result_id_i;
            pending_source_next = pair_right_source_frame_id_i;
            pending_sync_next = pair_sync_id_i;
        end

        if (new_result) begin
            bbox_seen_next = 1'b1;
            bbox_result_next = incoming_result_id;
            bbox_source_next = incoming_source_id;
            bbox_age_next = {AGE_WIDTH{1'b0}};
            fire_sample_next = 1'b1;
            fire_valid_next = incoming_fire_valid;
            fire_center_x_next = incoming_fire_valid ? incoming_center_sum[8:1] : 8'd80;
            distance_valid_next = 1'b0;
        end
        if (completed_frame_invalid) begin
            fire_valid_next = 1'b0;
            distance_valid_next = 1'b0;
            range_pending_next = 1'b0;
        end
        if (link_fault_i) begin
            fire_sample_next = 1'b0;
            fire_valid_next = 1'b0;
            distance_valid_next = 1'b0;
            range_pending_next = 1'b0;
            // Keep seen IDs: replaying the last result cannot recover a fault.
        end
    end

    always @(posedge clk) begin
        bbox_seen_reg <= bbox_seen_next;
        bbox_result_reg <= bbox_result_next;
        bbox_source_reg <= bbox_source_next;
        bbox_age_reg <= bbox_age_next;
        range_age_reg <= range_age_next;
        fire_sample_reg <= fire_sample_next;
        fire_valid_reg <= fire_valid_next;
        fire_center_x_reg <= fire_center_x_next;
        distance_valid_reg <= distance_valid_next;
        range_pending_reg <= range_pending_next;
        pending_result_reg <= pending_result_next;
        pending_source_reg <= pending_source_next;
        pending_sync_reg <= pending_sync_next;
        if (rst) begin
            bbox_seen_reg <= 1'b0;
            bbox_result_reg <= 16'd0;
            bbox_source_reg <= 16'd0;
            bbox_age_reg <= {AGE_WIDTH{1'b0}};
            range_age_reg <= {AGE_WIDTH{1'b0}};
            fire_sample_reg <= 1'b0;
            fire_valid_reg <= 1'b0;
            fire_center_x_reg <= 8'd80;
            distance_valid_reg <= 1'b0;
            range_pending_reg <= 1'b0;
            pending_result_reg <= 16'd0;
            pending_source_reg <= 16'd0;
            pending_sync_reg <= 16'd0;
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ < 1 || RESULT_TIMEOUT_MS < 1 || TIMEOUT_CYCLES_WIDE < 64'd2) begin
            $error("Invalid fire control result freshness parameters");
            $finish;
        end
    end
    // synthesis translate_on
endmodule

`resetall
