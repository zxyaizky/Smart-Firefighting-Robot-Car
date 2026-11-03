`resetall
`timescale 1ns / 1ps
`default_nettype none

// Latch A-board sensor results from a completed UDP frame header. The video
// receiver has already crossed metadata into clk_pixel before frame_start_i.
module remote_vitals_display #(
    parameter integer STALE_CYCLES = 150000000
)(
    input  wire        clk_pixel,
    input  wire        rst_n,
    input  wire        frame_start_i,
    input  wire        frame_abort_i,
    input  wire        sensor_metadata_valid_i,
    input  wire        heart_rate_valid_i,
    input  wire        spo2_valid_i,
    input  wire [8:0]  heart_rate_bpm_i,
    input  wire [7:0]  spo2_i,
    output reg  [11:0] heart_rate_bcd_o,
    output reg         heart_rate_display_valid_o,
    output reg  [11:0] spo2_bcd_o,
    output reg         spo2_display_valid_o
);
    reg [31:0] stale_count;

    function [11:0] binary_to_bcd;
        input [8:0] binary_value;
        reg [11:0] bcd;
        integer bit_index;
        begin
            bcd = 12'd0;
            for (bit_index = 8; bit_index >= 0; bit_index = bit_index - 1) begin
                if (bcd[3:0] >= 4'd5) bcd[3:0] = bcd[3:0] + 4'd3;
                if (bcd[7:4] >= 4'd5) bcd[7:4] = bcd[7:4] + 4'd3;
                if (bcd[11:8] >= 4'd5) bcd[11:8] = bcd[11:8] + 4'd3;
                bcd = {bcd[10:0], binary_value[bit_index]};
            end
            binary_to_bcd = bcd;
        end
    endfunction

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            stale_count <= 32'd0;
            heart_rate_bcd_o <= 12'd0;
            heart_rate_display_valid_o <= 1'b0;
            spo2_bcd_o <= 12'd0;
            spo2_display_valid_o <= 1'b0;
        end else if (frame_start_i) begin
            stale_count <= 32'd0;
            heart_rate_bcd_o <= binary_to_bcd(heart_rate_bpm_i);
            spo2_bcd_o <= binary_to_bcd({1'b0, spo2_i});
            heart_rate_display_valid_o <= sensor_metadata_valid_i && heart_rate_valid_i;
            spo2_display_valid_o <= sensor_metadata_valid_i && spo2_valid_i;
        end else if (frame_abort_i || stale_count >= STALE_CYCLES - 1) begin
            heart_rate_display_valid_o <= 1'b0;
            spo2_display_valid_o <= 1'b0;
        end else begin
            stale_count <= stale_count + 32'd1;
        end
    end
endmodule

`resetall
