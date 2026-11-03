// -----------------------------------------------------------------------------
// File   : stereo_left_frame_selector.v
// Author : Codex
// Date   : 2026-10-02
// Description: Queue sync requests and bind one per existing DDR capture boundary.
// Change Log: 2026-10-02 v1.0 Stage 3; reuse the existing local source ID.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_left_frame_selector
(
    input  wire        clk,
    input  wire        rst,
    input  wire        sync_event_i,
    input  wire [15:0] sync_id_i,
    input  wire        capture_frame_start_i,
    input  wire [15:0] capture_source_frame_id_i,
    output wire        left_selected_valid_o,
    output wire [15:0] left_selected_sync_id_o,
    output wire [15:0] left_selected_source_frame_id_o,
    output wire        request_overflow_o,
    output wire [31:0] left_selected_count_o
);
    // Four metadata entries; no image pixels. Unreset payload is qualified by count.
    reg [15:0] request_mem [3:0];
    reg [1:0] write_index_reg = 2'd0, write_index_next;
    reg [1:0] read_index_reg = 2'd0, read_index_next;
    reg [2:0] count_reg = 3'd0, count_next;
    reg overflow_reg = 1'b0, overflow_next;
    reg [31:0] selected_count_reg = 32'd0, selected_count_next;
    reg write_enable;
    wire selected;
    assign selected = capture_frame_start_i && (count_reg != 3'd0) && !rst;
    // These wires qualify the page write on this exact DDR edge, before the
    // existing capture counter and page pointer advance via nonblocking updates.
    assign left_selected_valid_o = selected;
    assign left_selected_sync_id_o = selected ? request_mem[read_index_reg] : 16'd0;
    assign left_selected_source_frame_id_o = capture_source_frame_id_i;
    assign request_overflow_o = overflow_reg;
    assign left_selected_count_o = selected_count_reg;
    always @* begin
        write_index_next = write_index_reg;
        read_index_next = read_index_reg;
        count_next = count_reg;
        selected_count_next = selected_count_reg;
        overflow_next = 1'b0;
        write_enable = 1'b0;
        if (selected) begin
            read_index_next = read_index_reg + 2'd1;
            count_next = count_reg - 3'd1;
            selected_count_next = selected_count_reg + 32'd1;
        end
        // A coincident new request is enqueued AFTER this boundary's selection.
        // With no old request pending, it must wait for the following boundary.
        if (sync_event_i) begin
            if (count_next < 3'd4) begin
                write_enable = 1'b1;
                write_index_next = write_index_reg + 2'd1;
                count_next = count_next + 3'd1;
            end else begin
                overflow_next = 1'b1;
            end
        end
    end
    always @(posedge clk) begin
        write_index_reg <= write_index_next;
        read_index_reg <= read_index_next;
        count_reg <= count_next;
        selected_count_reg <= selected_count_next;
        overflow_reg <= overflow_next;
        if (write_enable && !rst) request_mem[write_index_reg] <= sync_id_i;
        if (rst) begin
            write_index_reg <= 2'd0;
            read_index_reg <= 2'd0;
            count_reg <= 3'd0;
            selected_count_reg <= 32'd0;
            overflow_reg <= 1'b0;
        end
    end
endmodule
`resetall
