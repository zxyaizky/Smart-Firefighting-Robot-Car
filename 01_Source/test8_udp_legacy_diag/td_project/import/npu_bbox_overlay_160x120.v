// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// -----------------------------------------------------------------------------
// File   : npu_bbox_overlay_160x120.v
// Author : OpenAI Codex
// Date   : 2026-09-20
// -----------------------------------------------------------------------------
// Description:
//   Decode the NPU winner in its native padded 160x120 coordinate system and
//   draw a one-pixel red rectangle on an RGB888 raster stream.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-20  OpenAI Codex  v1.0  Initial implementation
//   2026-09-22  OpenAI Codex  v1.1  Pipeline result coordinate decoding
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module npu_bbox_overlay_160x120
(
    input  wire        clk,
    input  wire        rst,
    input  wire        tensor_valid_i,
    input  wire [63:0] tensor_data_i,
    input  wire        inference_done_i,
    input  wire [15:0] source_frame_id_i,
    output wire        bbox_valid_o,
    output wire [7:0]  bbox_x1_o,
    output wire [6:0]  bbox_y1_o,
    output wire [7:0]  bbox_x2_o,
    output wire [6:0]  bbox_y2_o,
    output wire        bbox_source_valid_o,
    output wire [15:0] bbox_source_frame_id_o,
    output wire [15:0] bbox_result_id_o,
    input  wire        frame_start_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] pixel_rgb_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    output wire        frame_start_o,
    output wire        pixel_valid_o,
    output wire [23:0] pixel_rgb_o,
    output wire        frame_end_o,
    output wire        frame_abort_o
);

    reg [15:0] decode_source_reg = 16'd0;
    reg [15:0] term_source_reg = 16'd0;
    reg [15:0] offset_source_reg = 16'd0;
    reg [15:0] bbox_source_reg = 16'd0;
    reg [15:0] result_id_reg = 16'd0;
    reg bbox_source_valid_reg = 1'b0;
    reg [63:0] result_reg = 64'd0;
    reg        detect_reg = 1'b0;
    reg [7:0]  box_x0_reg = 8'd0;
    reg [7:0]  box_x1_reg = 8'd0;
    reg [6:0]  box_y0_reg = 7'd0;
    reg [6:0]  box_y1_reg = 7'd0;
    reg [7:0]  x_reg = 8'd0;
    reg [6:0]  y_reg = 7'd0;
    reg        frame_start_reg = 1'b0;
    reg        pixel_valid_reg = 1'b0;
    reg [23:0] pixel_rgb_reg = 24'd0;
    reg        frame_end_reg = 1'b0;
    reg        frame_abort_reg = 1'b0;

    // The winner-to-box conversion is intentionally pipelined.  It runs only
    // once per inference, so a few cycles of latency are harmless, while
    // keeping the arithmetic out of the 100 MHz result-valid critical path.
    reg        decode_valid_reg = 1'b0;
    reg        term_valid_reg = 1'b0;
    reg        offset_valid_reg = 1'b0;
    reg [7:0]  term_obj_reg = 8'd0;
    reg [7:0]  term_fire_reg = 8'd0;
    reg [7:0]  term_gx_reg = 8'd0;
    reg [7:0]  term_gy_reg = 8'd0;
    reg signed [12:0] term_x1_reg = 13'sd0;
    reg        [12:0] term_x2_reg = 13'd0;
    reg signed [13:0] term_y1_reg = 14'sd0;
    reg        [13:0] term_y2_reg = 14'd0;
    reg [7:0]  offset_obj_reg = 8'd0;
    reg [7:0]  offset_fire_reg = 8'd0;
    reg [7:0]  offset_gx_reg = 8'd0;
    reg [7:0]  offset_gy_reg = 8'd0;
    reg        offset_x1_neg_reg = 1'b0;
    reg        offset_y1_neg_reg = 1'b0;
    reg [10:0] offset_x1_reg = 11'd0;
    reg [10:0] offset_x2_reg = 11'd0;
    reg [10:0] offset_y1_reg = 11'd0;
    reg [10:0] offset_y2_reg = 11'd0;

    wire [7:0]  winner_obj;
    wire [7:0]  winner_dx;
    wire [7:0]  winner_dy;
    wire [7:0]  winner_w;
    wire [7:0]  winner_h;
    wire [7:0]  winner_fire;
    wire [7:0]  winner_gx;
    wire [7:0]  winner_gy;
    wire [11:0] width_x10;
    wire [11:0] height_x15;
    wire signed [12:0] x1_term;
    wire [12:0] x2_term;
    wire signed [13:0] y1_term;
    wire [13:0] y2_term;
    wire [12:0] term_x1_abs;
    wire [13:0] term_y1_abs;
    wire [17:0] term_x1_numerator;
    wire [17:0] term_x2_numerator;
    wire [17:0] term_y1_numerator;
    wire [17:0] term_y2_numerator;
    wire signed [12:0] x1_unclipped;
    wire signed [12:0] x2_unclipped;
    wire signed [12:0] y1_unclipped;
    wire signed [12:0] y2_unclipped;
    wire [7:0] x1_clipped;
    wire [7:0] x2_clipped;
    wire [6:0] y1_clipped;
    wire [6:0] y2_clipped;
    wire       winner_detect;
    wire       box_pixel;

    function [10:0] div255_round_magnitude;
        input [17:0] numerator;
        reg [17:0] adjusted;
        reg [9:0]  quotient_base;
        reg [10:0] remainder_sum;
        begin
            adjusted = numerator + 18'd127;
            quotient_base = adjusted[17:8];
            remainder_sum = {1'b0, quotient_base} + {3'd0, adjusted[7:0]};
            div255_round_magnitude = {1'b0, quotient_base}
                + (remainder_sum >= 11'd255)
                + (remainder_sum >= 11'd510)
                + (remainder_sum >= 11'd765);
        end
    endfunction

    assign bbox_valid_o = detect_reg;
    assign bbox_x1_o = box_x0_reg;
    assign bbox_y1_o = box_y0_reg;
    assign bbox_x2_o = box_x1_reg;
    assign bbox_y2_o = box_y1_reg;
    assign bbox_source_valid_o = bbox_source_valid_reg;
    assign bbox_source_frame_id_o = bbox_source_reg;
    assign bbox_result_id_o = result_id_reg;

    assign winner_obj  = result_reg[7:0];
    assign winner_dx   = result_reg[15:8];
    assign winner_dy   = result_reg[23:16];
    assign winner_w    = result_reg[31:24];
    assign winner_h    = result_reg[39:32];
    assign winner_fire = result_reg[47:40];
    assign winner_gx   = result_reg[55:48];
    assign winner_gy   = result_reg[63:56];

    assign width_x10  = ({4'd0, winner_w} << 3) + ({4'd0, winner_w} << 1);
    assign height_x15 = ({4'd0, winner_h} << 4) - {4'd0, winner_h};
    assign x1_term = $signed({5'd0, winner_dx}) - $signed({1'b0, width_x10});
    assign x2_term = {5'd0, winner_dx} + {1'b0, width_x10};
    assign y1_term = $signed({5'd0, winner_dy, 1'b0})
        - $signed({2'd0, height_x15});
    assign y2_term = {5'd0, winner_dy, 1'b0} + {2'd0, height_x15};
    assign term_x1_abs = term_x1_reg[12] ? -term_x1_reg : term_x1_reg;
    assign term_y1_abs = term_y1_reg[13] ? -term_y1_reg : term_y1_reg;
    assign term_x1_numerator = {5'd0, term_x1_abs} << 3;
    assign term_x2_numerator = {5'd0, term_x2_reg} << 3;
    assign term_y1_numerator = {4'd0, term_y1_abs} << 2;
    assign term_y2_numerator = {4'd0, term_y2_reg} << 2;

    assign x1_unclipped = offset_x1_neg_reg
        ? $signed({1'b0, offset_gx_reg, 3'b000}) - $signed({2'd0, offset_x1_reg})
        : $signed({1'b0, offset_gx_reg, 3'b000}) + $signed({2'd0, offset_x1_reg});
    assign x2_unclipped = $signed({1'b0, offset_gx_reg, 3'b000})
        + $signed({2'd0, offset_x2_reg});
    assign y1_unclipped = offset_y1_neg_reg
        ? $signed({1'b0, offset_gy_reg, 3'b000}) - $signed({2'd0, offset_y1_reg})
        : $signed({1'b0, offset_gy_reg, 3'b000}) + $signed({2'd0, offset_y1_reg});
    assign y2_unclipped = $signed({1'b0, offset_gy_reg, 3'b000})
        + $signed({2'd0, offset_y2_reg});

    assign x1_clipped = (x1_unclipped < 13'sd0) ? 8'd0
        : (x1_unclipped > 13'sd159) ? 8'd159 : x1_unclipped[7:0];
    assign x2_clipped = (x2_unclipped < 13'sd0) ? 8'd0
        : (x2_unclipped > 13'sd159) ? 8'd159 : x2_unclipped[7:0];
    assign y1_clipped = (y1_unclipped < 13'sd0) ? 7'd0
        : (y1_unclipped > 13'sd119) ? 7'd119 : y1_unclipped[6:0];
    assign y2_clipped = (y2_unclipped < 13'sd0) ? 7'd0
        : (y2_unclipped > 13'sd119) ? 7'd119 : y2_unclipped[6:0];
    assign winner_detect = (offset_obj_reg >= 8'd128)
        && (offset_fire_reg >= 8'd128);

    assign box_pixel = detect_reg && pixel_valid_i
        && (x_reg >= box_x0_reg) && (x_reg <= box_x1_reg)
        && (y_reg >= box_y0_reg) && (y_reg <= box_y1_reg)
        && ((x_reg == box_x0_reg) || (x_reg == box_x1_reg)
            || (y_reg == box_y0_reg) || (y_reg == box_y1_reg));

    assign frame_start_o = frame_start_reg;
    assign pixel_valid_o = pixel_valid_reg;
    assign pixel_rgb_o   = pixel_rgb_reg;
    assign frame_end_o   = frame_end_reg;
    assign frame_abort_o = frame_abort_reg;

    always @(posedge clk) begin
        if (tensor_valid_i) begin
            result_reg <= tensor_data_i;
        end

        decode_valid_reg <= inference_done_i;
        if (inference_done_i) decode_source_reg <= source_frame_id_i;
        term_valid_reg   <= decode_valid_reg;
        offset_valid_reg <= term_valid_reg;

        if (decode_valid_reg) begin
            term_source_reg <= decode_source_reg;
            term_obj_reg  <= winner_obj;
            term_fire_reg <= winner_fire;
            term_gx_reg   <= winner_gx;
            term_gy_reg   <= winner_gy;
            term_x1_reg   <= x1_term;
            term_x2_reg   <= x2_term;
            term_y1_reg   <= y1_term;
            term_y2_reg   <= y2_term;
        end

        if (term_valid_reg) begin
            offset_source_reg <= term_source_reg;
            offset_obj_reg    <= term_obj_reg;
            offset_fire_reg   <= term_fire_reg;
            offset_gx_reg     <= term_gx_reg;
            offset_gy_reg     <= term_gy_reg;
            offset_x1_neg_reg <= term_x1_reg[12];
            offset_y1_neg_reg <= term_y1_reg[13];
            offset_x1_reg <= div255_round_magnitude(term_x1_numerator);
            offset_x2_reg <= div255_round_magnitude(term_x2_numerator);
            offset_y1_reg <= div255_round_magnitude(term_y1_numerator);
            offset_y2_reg <= div255_round_magnitude(term_y2_numerator);
        end

        if (offset_valid_reg) begin
            bbox_source_reg <= offset_source_reg;
            bbox_source_valid_reg <= 1'b1;
            result_id_reg <= result_id_reg + 16'd1;
            detect_reg <= winner_detect;
            box_x0_reg <= x1_clipped;
            box_x1_reg <= x2_clipped;
            box_y0_reg <= y1_clipped;
            box_y1_reg <= y2_clipped;
        end

        frame_start_reg <= frame_start_i;
        pixel_valid_reg <= pixel_valid_i;
        frame_end_reg   <= frame_end_i;
        frame_abort_reg <= frame_abort_i;
        if (box_pixel) begin
            pixel_rgb_reg <= 24'hff_20_20;
        end else begin
            pixel_rgb_reg <= pixel_rgb_i;
        end

        if (frame_start_i || frame_abort_i) begin
            x_reg <= 8'd0;
            y_reg <= 7'd0;
        end else if (pixel_valid_i) begin
            if (x_reg == 8'd159) begin
                x_reg <= 8'd0;
                if (y_reg == 7'd119) begin
                    y_reg <= 7'd0;
                end else begin
                    y_reg <= y_reg + 7'd1;
                end
            end else begin
                x_reg <= x_reg + 8'd1;
            end
        end

        if (rst) begin
            decode_source_reg <= 16'd0;
            term_source_reg <= 16'd0;
            offset_source_reg <= 16'd0;
            bbox_source_reg <= 16'd0;
            bbox_source_valid_reg <= 1'b0;
            result_id_reg <= 16'd0;
            result_reg      <= 64'd0;
            detect_reg      <= 1'b0;
            box_x0_reg      <= 8'd0;
            box_x1_reg      <= 8'd0;
            box_y0_reg      <= 7'd0;
            box_y1_reg      <= 7'd0;
            x_reg           <= 8'd0;
            y_reg           <= 7'd0;
            frame_start_reg <= 1'b0;
            pixel_valid_reg <= 1'b0;
            pixel_rgb_reg   <= 24'd0;
            frame_end_reg   <= 1'b0;
            frame_abort_reg <= 1'b0;
            decode_valid_reg <= 1'b0;
            term_valid_reg   <= 1'b0;
            offset_valid_reg <= 1'b0;
            term_obj_reg     <= 8'd0;
            term_fire_reg    <= 8'd0;
            term_gx_reg      <= 8'd0;
            term_gy_reg      <= 8'd0;
            term_x1_reg      <= 13'sd0;
            term_x2_reg      <= 13'd0;
            term_y1_reg      <= 14'sd0;
            term_y2_reg      <= 14'd0;
            offset_obj_reg   <= 8'd0;
            offset_fire_reg  <= 8'd0;
            offset_gx_reg    <= 8'd0;
            offset_gy_reg    <= 8'd0;
            offset_x1_neg_reg <= 1'b0;
            offset_y1_neg_reg <= 1'b0;
            offset_x1_reg    <= 11'd0;
            offset_x2_reg    <= 11'd0;
            offset_y1_reg    <= 11'd0;
            offset_y2_reg    <= 11'd0;
        end
    end

endmodule

`resetall
