// -----------------------------------------------------------------------------
// File   : max30102_osd_cdc.v
// Author : Codex
// Date   : 2026-09-29
// -----------------------------------------------------------------------------
// Description:
//   Transfer slow MAX30102 result pulses from the 24 MHz sensor domain to the
//   HDMI pixel domain. Held BCD mailboxes use independent toggle acknowledgments.
//   Quality flags are synchronized separately and invalidate displayed results.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-29  Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_osd_cdc (
    input  wire        clk_sensor,
    input  wire        clk_pixel,
    input  wire        rst_n,
    input  wire [8:0]  heart_rate_bpm,
    input  wire        heart_rate_valid,
    input  wire [7:0]  spo2,
    input  wire        spo2_valid,
    input  wire        finger_present,
    input  wire        signal_good,
    input  wire        system_ready,
    output reg  [11:0] heart_rate_bcd_pixel,
    output reg         heart_rate_display_valid_pixel,
    output reg  [11:0] spo2_bcd_pixel,
    output reg         spo2_display_valid_pixel
);
    reg [11:0] hr_mailbox_reg;
    reg [11:0] spo2_mailbox_reg;
    reg hr_request_reg;
    reg spo2_request_reg;
    reg hr_ack_reg;
    reg spo2_ack_reg;
    (* async_reg = "true" *) reg [1:0] hr_ack_sync_reg;
    (* async_reg = "true" *) reg [1:0] spo2_ack_sync_reg;
    (* async_reg = "true" *) reg [1:0] hr_request_sync_reg;
    (* async_reg = "true" *) reg [1:0] spo2_request_sync_reg;
    (* async_reg = "true" *) reg [1:0] ready_sync_reg;
    (* async_reg = "true" *) reg [1:0] finger_sync_reg;
    (* async_reg = "true" *) reg [1:0] quality_sync_reg;
    wire source_quality;
    wire pixel_quality;

    assign source_quality = system_ready && finger_present && signal_good;
    assign pixel_quality = ready_sync_reg[1] && finger_sync_reg[1] &&
                           quality_sync_reg[1];

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

    // A mailbox cannot change until its request has returned through the
    // acknowledgement synchronizer. The destination samples a stable bus.
    always @(posedge clk_sensor or negedge rst_n) begin
        if (!rst_n) begin
            hr_mailbox_reg <= 12'd0;
            spo2_mailbox_reg <= 12'd0;
            hr_request_reg <= 1'b0;
            spo2_request_reg <= 1'b0;
            hr_ack_sync_reg <= 2'b00;
            spo2_ack_sync_reg <= 2'b00;
        end else begin
            hr_ack_sync_reg <= {hr_ack_sync_reg[0], hr_ack_reg};
            spo2_ack_sync_reg <= {spo2_ack_sync_reg[0], spo2_ack_reg};
            if (source_quality) begin
                if (heart_rate_valid && hr_request_reg == hr_ack_sync_reg[1]) begin
                    hr_mailbox_reg <= binary_to_bcd(heart_rate_bpm);
                    hr_request_reg <= ~hr_request_reg;
                end
                if (spo2_valid && spo2_request_reg == spo2_ack_sync_reg[1]) begin
                    spo2_mailbox_reg <= binary_to_bcd({1'b0, spo2});
                    spo2_request_reg <= ~spo2_request_reg;
                end
            end
        end
    end

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            hr_request_sync_reg <= 2'b00;
            spo2_request_sync_reg <= 2'b00;
            ready_sync_reg <= 2'b00;
            finger_sync_reg <= 2'b00;
            quality_sync_reg <= 2'b00;
            hr_ack_reg <= 1'b0;
            spo2_ack_reg <= 1'b0;
            heart_rate_bcd_pixel <= 12'd0;
            spo2_bcd_pixel <= 12'd0;
            heart_rate_display_valid_pixel <= 1'b0;
            spo2_display_valid_pixel <= 1'b0;
        end else begin
            hr_request_sync_reg <= {hr_request_sync_reg[0], hr_request_reg};
            spo2_request_sync_reg <= {spo2_request_sync_reg[0], spo2_request_reg};
            ready_sync_reg <= {ready_sync_reg[0], system_ready};
            finger_sync_reg <= {finger_sync_reg[0], finger_present};
            quality_sync_reg <= {quality_sync_reg[0], signal_good};

            if (!pixel_quality) begin
                heart_rate_bcd_pixel <= 12'd0;
                spo2_bcd_pixel <= 12'd0;
                heart_rate_display_valid_pixel <= 1'b0;
                spo2_display_valid_pixel <= 1'b0;
            end
            if (hr_request_sync_reg[1] != hr_ack_reg) begin
                hr_ack_reg <= hr_request_sync_reg[1];
                if (pixel_quality) begin
                    heart_rate_bcd_pixel <= hr_mailbox_reg;
                    heart_rate_display_valid_pixel <= 1'b1;
                end
            end
            if (spo2_request_sync_reg[1] != spo2_ack_reg) begin
                spo2_ack_reg <= spo2_request_sync_reg[1];
                if (pixel_quality) begin
                    spo2_bcd_pixel <= spo2_mailbox_reg;
                    spo2_display_valid_pixel <= 1'b1;
                end
            end
        end
    end
endmodule

`resetall
