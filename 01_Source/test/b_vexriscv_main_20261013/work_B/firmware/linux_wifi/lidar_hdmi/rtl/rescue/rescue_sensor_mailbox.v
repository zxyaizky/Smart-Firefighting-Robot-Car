// File: rescue_sensor_mailbox.v
// Author: Codex
// Date: 2026-10-27
// Description: Coalesced coherent sensor CDC; only actual channel updates renew age.
// Change Log: 2026-10-27 v1.0 Pixel-to-system metadata, no video backpressure.
`resetall
`timescale 1ns / 1ps
`default_nettype none
module rescue_sensor_mailbox
(
    input  wire        clk_pixel,
    input  wire        clk,
    input  wire        rst,
    input  wire [3:0]  updates_i,
    input  wire [3:0]  flags_i,
    input  wire        green_clear_i,
    input  wire [15:0] distance_mm_i,
    input  wire        distance_valid_i,
    output wire [3:0]  updates_o,
    output wire [3:0]  flags_o,
    output wire        green_clear_o,
    output wire [15:0] distance_mm_o,
    output wire        distance_valid_o
);
    reg [3:0] pending_reg = 4'd0;
    wire [3:0] requested = pending_reg | updates_i;
    wire ready, event_valid;
    wire send = ready && |requested;
    wire [25:0] received;
    always @(posedge clk_pixel) begin
        pending_reg <= send ? 4'd0 : requested;
        if (rst) pending_reg <= 4'd0;
    end
    stereo_metadata_mailbox #(.DATA_WIDTH(26)) u_mailbox (
        .clk_source(clk_pixel), .rst_source(rst), .clk_dest(clk), .rst_dest(rst),
        .send_i(send), .data_i({green_clear_i, requested, flags_i, distance_valid_i, distance_mm_i}),
        .ready_o(ready), .overflow_o(), .event_o(event_valid), .data_o(received)
    );
    assign updates_o = received[24:21] & {4{event_valid}};
    assign flags_o = received[20:17];
    assign green_clear_o = received[25];
    assign distance_valid_o = received[16];
    assign distance_mm_o = received[15:0];
endmodule
`resetall
