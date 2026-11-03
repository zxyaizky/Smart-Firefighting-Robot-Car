// -----------------------------------------------------------------------------
// File   : stereo_frame_selector.v
// Author : Codex
// Date   : 2026-10-02
// Description: Select the next CSI SOF after a synchronized request; label all SOFs.
// Change Log: 2026-10-02 v1.0 Stage 2 native source-frame identity.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_frame_selector (
    input  wire        clk,
    input  wire        rst,
    input  wire        stereo_sync_pulse_i,
    input  wire [15:0] pending_sync_id_i,
    input  wire        csi_frame_start_i,
    output wire        selected_frame_start_o,
    output wire [15:0] selected_sync_id_o,
    output wire        selected_frame_pending_o,
    output wire [15:0] source_frame_id_o,
    output wire        source_sync_valid_o,
    output wire        request_overrun_o
);
    reg pending_reg = 1'b0, pending_next;
    reg [15:0] pending_id_reg = 16'd0, pending_id_next;
    reg [15:0] source_id_reg = 16'd0, source_id_next;
    reg [15:0] selected_id_reg = 16'd0, selected_id_next;
    reg selected_start_reg = 1'b0, selected_start_next;
    reg source_selected_reg = 1'b0, source_selected_next;
    reg overrun_reg = 1'b0, overrun_next;
    assign selected_frame_start_o = selected_start_reg;
    assign selected_sync_id_o = selected_id_reg;
    assign selected_frame_pending_o = pending_reg;
    assign source_frame_id_o = source_id_reg;
    assign source_sync_valid_o = source_selected_reg;
    assign request_overrun_o = overrun_reg;
    always @* begin
        pending_next = pending_reg;
        pending_id_next = pending_id_reg;
        source_id_next = source_id_reg;
        selected_id_next = selected_id_reg;
        selected_start_next = 1'b0;
        source_selected_next = source_selected_reg;
        overrun_next = 1'b0;
        if (csi_frame_start_i) begin
            source_id_next = source_id_reg + 16'd1;
            source_selected_next = pending_reg;
            selected_id_next = pending_reg ? pending_id_reg : 16'd0;
            selected_start_next = pending_reg;
            pending_next = 1'b0;
        end
        // A request coincident with SOF belongs to the NEXT SOF. If an older
        // request exists, this SOF consumes it and the new request remains pending.
        if (stereo_sync_pulse_i) begin
            overrun_next = pending_reg && !csi_frame_start_i;
            pending_next = 1'b1;
            pending_id_next = pending_sync_id_i;
        end
    end
    always @(posedge clk) begin
        pending_reg <= pending_next;
        pending_id_reg <= pending_id_next;
        source_id_reg <= source_id_next;
        selected_id_reg <= selected_id_next;
        selected_start_reg <= selected_start_next;
        source_selected_reg <= source_selected_next;
        overrun_reg <= overrun_next;
        if (rst) begin
            pending_reg <= 1'b0;
            pending_id_reg <= 16'd0;
            source_id_reg <= 16'd0;
            selected_id_reg <= 16'd0;
            selected_start_reg <= 1'b0;
            source_selected_reg <= 1'b0;
            overrun_reg <= 1'b0;
        end
    end
endmodule
`resetall
