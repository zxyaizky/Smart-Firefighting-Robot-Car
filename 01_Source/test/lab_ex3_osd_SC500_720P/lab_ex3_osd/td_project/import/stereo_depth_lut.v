// File: stereo_depth_lut.v
// Author: Codex
// Date: 2026-10-02
// Description: Constant-folded f*baseline/disparity lookup, floor mm, saturate16.
// Change Log: 2026-10-02 Codex v1.0 Stereo stage 6 uncalibrated distance table.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_depth_lut #(
    parameter [31:0] FB_CONSTANT = 32'd8000
) (
    input  wire [5:0] disparity_i,
    output wire [15:0] distance_mm_o
);
    localparam [31:0] DISTANCE_01 = FB_CONSTANT / 32'd1;
    localparam [31:0] DISTANCE_02 = FB_CONSTANT / 32'd2;
    localparam [31:0] DISTANCE_03 = FB_CONSTANT / 32'd3;
    localparam [31:0] DISTANCE_04 = FB_CONSTANT / 32'd4;
    localparam [31:0] DISTANCE_05 = FB_CONSTANT / 32'd5;
    localparam [31:0] DISTANCE_06 = FB_CONSTANT / 32'd6;
    localparam [31:0] DISTANCE_07 = FB_CONSTANT / 32'd7;
    localparam [31:0] DISTANCE_08 = FB_CONSTANT / 32'd8;
    localparam [31:0] DISTANCE_09 = FB_CONSTANT / 32'd9;
    localparam [31:0] DISTANCE_10 = FB_CONSTANT / 32'd10;
    localparam [31:0] DISTANCE_11 = FB_CONSTANT / 32'd11;
    localparam [31:0] DISTANCE_12 = FB_CONSTANT / 32'd12;
    localparam [31:0] DISTANCE_13 = FB_CONSTANT / 32'd13;
    localparam [31:0] DISTANCE_14 = FB_CONSTANT / 32'd14;
    localparam [31:0] DISTANCE_15 = FB_CONSTANT / 32'd15;
    localparam [31:0] DISTANCE_16 = FB_CONSTANT / 32'd16;
    localparam [31:0] DISTANCE_17 = FB_CONSTANT / 32'd17;
    localparam [31:0] DISTANCE_18 = FB_CONSTANT / 32'd18;
    localparam [31:0] DISTANCE_19 = FB_CONSTANT / 32'd19;
    localparam [31:0] DISTANCE_20 = FB_CONSTANT / 32'd20;
    localparam [31:0] DISTANCE_21 = FB_CONSTANT / 32'd21;
    localparam [31:0] DISTANCE_22 = FB_CONSTANT / 32'd22;
    localparam [31:0] DISTANCE_23 = FB_CONSTANT / 32'd23;
    localparam [31:0] DISTANCE_24 = FB_CONSTANT / 32'd24;
    localparam [31:0] DISTANCE_25 = FB_CONSTANT / 32'd25;
    localparam [31:0] DISTANCE_26 = FB_CONSTANT / 32'd26;
    localparam [31:0] DISTANCE_27 = FB_CONSTANT / 32'd27;
    localparam [31:0] DISTANCE_28 = FB_CONSTANT / 32'd28;
    localparam [31:0] DISTANCE_29 = FB_CONSTANT / 32'd29;
    localparam [31:0] DISTANCE_30 = FB_CONSTANT / 32'd30;
    localparam [31:0] DISTANCE_31 = FB_CONSTANT / 32'd31;
    reg [15:0] distance_comb;
    assign distance_mm_o = distance_comb;
    // Every division has a parameter numerator and literal denominator.
    // These are elaboration constants, never a runtime hardware divider.
    always @* begin
        distance_comb = 16'd0;
        case (disparity_i)
            6'd1: distance_comb = (DISTANCE_01 > 32'd65535) ?
                16'hffff : DISTANCE_01[15:0];
            6'd2: distance_comb = (DISTANCE_02 > 32'd65535) ?
                16'hffff : DISTANCE_02[15:0];
            6'd3: distance_comb = (DISTANCE_03 > 32'd65535) ?
                16'hffff : DISTANCE_03[15:0];
            6'd4: distance_comb = (DISTANCE_04 > 32'd65535) ?
                16'hffff : DISTANCE_04[15:0];
            6'd5: distance_comb = (DISTANCE_05 > 32'd65535) ?
                16'hffff : DISTANCE_05[15:0];
            6'd6: distance_comb = (DISTANCE_06 > 32'd65535) ?
                16'hffff : DISTANCE_06[15:0];
            6'd7: distance_comb = (DISTANCE_07 > 32'd65535) ?
                16'hffff : DISTANCE_07[15:0];
            6'd8: distance_comb = (DISTANCE_08 > 32'd65535) ?
                16'hffff : DISTANCE_08[15:0];
            6'd9: distance_comb = (DISTANCE_09 > 32'd65535) ?
                16'hffff : DISTANCE_09[15:0];
            6'd10: distance_comb = (DISTANCE_10 > 32'd65535) ?
                16'hffff : DISTANCE_10[15:0];
            6'd11: distance_comb = (DISTANCE_11 > 32'd65535) ?
                16'hffff : DISTANCE_11[15:0];
            6'd12: distance_comb = (DISTANCE_12 > 32'd65535) ?
                16'hffff : DISTANCE_12[15:0];
            6'd13: distance_comb = (DISTANCE_13 > 32'd65535) ?
                16'hffff : DISTANCE_13[15:0];
            6'd14: distance_comb = (DISTANCE_14 > 32'd65535) ?
                16'hffff : DISTANCE_14[15:0];
            6'd15: distance_comb = (DISTANCE_15 > 32'd65535) ?
                16'hffff : DISTANCE_15[15:0];
            6'd16: distance_comb = (DISTANCE_16 > 32'd65535) ?
                16'hffff : DISTANCE_16[15:0];
            6'd17: distance_comb = (DISTANCE_17 > 32'd65535) ?
                16'hffff : DISTANCE_17[15:0];
            6'd18: distance_comb = (DISTANCE_18 > 32'd65535) ?
                16'hffff : DISTANCE_18[15:0];
            6'd19: distance_comb = (DISTANCE_19 > 32'd65535) ?
                16'hffff : DISTANCE_19[15:0];
            6'd20: distance_comb = (DISTANCE_20 > 32'd65535) ?
                16'hffff : DISTANCE_20[15:0];
            6'd21: distance_comb = (DISTANCE_21 > 32'd65535) ?
                16'hffff : DISTANCE_21[15:0];
            6'd22: distance_comb = (DISTANCE_22 > 32'd65535) ?
                16'hffff : DISTANCE_22[15:0];
            6'd23: distance_comb = (DISTANCE_23 > 32'd65535) ?
                16'hffff : DISTANCE_23[15:0];
            6'd24: distance_comb = (DISTANCE_24 > 32'd65535) ?
                16'hffff : DISTANCE_24[15:0];
            6'd25: distance_comb = (DISTANCE_25 > 32'd65535) ?
                16'hffff : DISTANCE_25[15:0];
            6'd26: distance_comb = (DISTANCE_26 > 32'd65535) ?
                16'hffff : DISTANCE_26[15:0];
            6'd27: distance_comb = (DISTANCE_27 > 32'd65535) ?
                16'hffff : DISTANCE_27[15:0];
            6'd28: distance_comb = (DISTANCE_28 > 32'd65535) ?
                16'hffff : DISTANCE_28[15:0];
            6'd29: distance_comb = (DISTANCE_29 > 32'd65535) ?
                16'hffff : DISTANCE_29[15:0];
            6'd30: distance_comb = (DISTANCE_30 > 32'd65535) ?
                16'hffff : DISTANCE_30[15:0];
            6'd31: distance_comb = (DISTANCE_31 > 32'd65535) ?
                16'hffff : DISTANCE_31[15:0];
            default: distance_comb = 16'd0;
        endcase
    end
endmodule
`resetall
