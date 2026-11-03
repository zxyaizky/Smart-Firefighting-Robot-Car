`resetall
`timescale 1ns / 1ps
`default_nettype none

// Transparent HR/SpO2 text after the NPU overlay.  Two registered stages keep
// the incoming video, DE and VSYNC aligned with the font/color decision.
module max30102_video_overlay #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer PANEL_TOP = 120
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vsync,
    input  wire        in_de,
    input  wire [23:0] in_rgb,
    input  wire [11:0] heart_rate_bcd,
    input  wire        heart_rate_display_valid,
    input  wire [11:0] spo2_bcd,
    input  wire        spo2_display_valid,
    output reg         out_vsync,
    output reg         out_de,
    output reg  [23:0] out_rgb
);
    reg [11:0] pixel_x;
    reg [11:0] pixel_y;
    reg de_d;
    reg vsync_d;
    reg [23:0] rgb_d;
    reg overlay_enable_d;
    reg [1:0] overlay_style_d;
    wire overlay_enable;
    wire [1:0] overlay_style;

    wire [23:0] overlay_color =
        (overlay_style_d == 2'd0) ? 24'ha8c0c9 :
        (overlay_style_d == 2'd1) ? 24'hf7fbff :
        (overlay_style_d == 2'd2) ? 24'hff8d78 : 24'h57dec7;

    max30102_status_osd #(
        .H_ACTIVE(IMG_WIDTH),
        .V_ACTIVE(IMG_HEIGHT),
        .PANEL_TOP(PANEL_TOP)
    ) u_status (
        .video_de(in_de),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .heart_rate_bcd(heart_rate_bcd),
        .heart_rate_display_valid(heart_rate_display_valid),
        .spo2_bcd(spo2_bcd),
        .spo2_display_valid(spo2_display_valid),
        .overlay_enable(overlay_enable),
        .overlay_rgb(), .overlay_style(overlay_style)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 12'd0;
            pixel_y <= 12'd0;
            de_d <= 1'b0;
            vsync_d <= 1'b0;
            rgb_d <= 24'd0;
            overlay_enable_d <= 1'b0;
            overlay_style_d <= 2'd0;
            out_vsync <= 1'b0;
            out_de <= 1'b0;
            out_rgb <= 24'd0;
        end else begin
            out_vsync <= vsync_d;
            out_de <= de_d;
            out_rgb <= overlay_enable_d ? overlay_color : rgb_d;
            vsync_d <= in_vsync;
            de_d <= in_de;
            rgb_d <= in_rgb;
            overlay_enable_d <= overlay_enable;
            overlay_style_d <= overlay_style;

            if (in_vsync) begin
                pixel_x <= 12'd0;
                pixel_y <= 12'd0;
            end else if (in_de) begin
                if (pixel_x < IMG_WIDTH - 1)
                    pixel_x <= pixel_x + 12'd1;
            end else begin
                pixel_x <= 12'd0;
                if (de_d && pixel_y < IMG_HEIGHT - 1)
                    pixel_y <= pixel_y + 12'd1;
            end
        end
    end
endmodule

`resetall
