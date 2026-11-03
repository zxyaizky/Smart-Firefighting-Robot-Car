// -----------------------------------------------------------------------------
// File   : activation_quant_fused.v
// Author : OpenAI Codex
// Date   : 2026-09-13
// -----------------------------------------------------------------------------
// Description:
//   Exact activation and uint8 quantization using two time-multiplexed lanes.
//   Sixteen input channels are consumed over eight cycles to reduce LUT usage.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-13  OpenAI Codex  v1.0  Fuse the activation and quantization stages
//   2026-09-13  OpenAI Codex  v1.1  Reuse two arithmetic lanes across 16 channels
//   2026-09-22  OpenAI Codex  v1.2  Pipeline bias add before activation/quantize
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module activation_quant_fused #(
    parameter ACC_WIDTH    = 32,
    parameter NUM_CHANNELS = 16
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire [1:0]                            cfg_activation_type,
    input  wire [3:0]                            shift_bits,
    input  wire [ACC_WIDTH*NUM_CHANNELS-1:0]     in_sum_bus,
    input  wire [63:0]                           in_bias_pair,
    input  wire                                  in_valid,
    input  wire [7:0]                            in_x,
    input  wire [7:0]                            in_y,
    output reg  [NUM_CHANNELS*8-1:0]             out_pixel_bus,
    output reg                                   out_valid,
    output reg                                   stage_valid,
    output wire                                  busy,
    output wire [2:0]                            bias_pair_addr,
    output reg  [7:0]                            out_x,
    output reg  [7:0]                            out_y
);

    localparam SUM_BUS_WIDTH   = ACC_WIDTH * NUM_CHANNELS;
    localparam PIXEL_BUS_WIDTH = 8 * NUM_CHANNELS;
    localparam [3:0] LAST_PAIR = (NUM_CHANNELS / 2) - 1;

    function [7:0] activated_quantized;
        input signed [ACC_WIDTH-1:0] value;
        input [1:0] activation;
        input [3:0] shift;
        reg [26:0] plus_three_small;
        reg [32:0] scaled_small;
        reg [24:0] hard_value;
        reg [22:0] positive_value;
        reg [22:0] shifted_positive;
        reg clip_high;
        reg signed [ACC_WIDTH+6:0] extended_value;
        reg signed [ACC_WIDTH+6:0] plus_three;
        reg signed [ACC_WIDTH+6:0] scaled;
        reg signed [ACC_WIDTH-1:0] activated_value;
        reg signed [ACC_WIDTH-1:0] shifted_value;
        begin
            if (ACC_WIDTH == 32) begin
                // A uint8 result shifted by at most 15 only needs 23 bits.
                // Larger positive values necessarily saturate; all negative
                // values map to zero for every supported activation mode.
                // HardSigmoid remains exactly floor(43*(value+3)/256).
                plus_three_small = {1'b0, value[25:0]} + 27'd3;
                scaled_small = ({6'd0, plus_three_small} << 5) +
                               ({6'd0, plus_three_small} << 3) +
                               ({6'd0, plus_three_small} << 1) +
                               {6'd0, plus_three_small};
                hard_value = scaled_small[32:8];
                if (activation == 2'b01) begin
                    positive_value = hard_value[22:0];
                    clip_high = (|value[30:26]) || (|hard_value[24:23]);
                end else begin
                    positive_value = value[22:0];
                    clip_high = |value[30:23];
                end
                shifted_positive = positive_value >> shift;
                if (value[31]) activated_quantized = 8'd0;
                else if (clip_high || (|shifted_positive[22:8]))
                    activated_quantized = 8'd255;
                else activated_quantized = shifted_positive[7:0];
            end else begin

            extended_value = {{7{value[ACC_WIDTH-1]}}, value};
            plus_three = extended_value + 39'sd3;
            scaled = (plus_three <<< 5) + (plus_three <<< 3) +
                     (plus_three <<< 1) + plus_three;

            if (activation == 2'b01) begin
                activated_value = scaled >>> 8;
            end else if (activation == 2'b10) begin
                activated_value = value;
            end else if (value[ACC_WIDTH-1]) begin
                activated_value = {ACC_WIDTH{1'b0}};
            end else begin
                activated_value = value;
            end

            shifted_value = activated_value >>> shift;
            if (shifted_value[ACC_WIDTH-1]) begin
                activated_quantized = 8'd0;
            end else if (|shifted_value[ACC_WIDTH-2:8]) begin
                activated_quantized = 8'd255;
            end else begin
                activated_quantized = shifted_value[7:0];
            end
            end
        end
    endfunction

    reg [SUM_BUS_WIDTH-1:0]   sum_shift_reg;
    reg [PIXEL_BUS_WIDTH-1:0] pixel_shift_reg;
    reg [1:0]                 activation_reg;
    reg [3:0]                 shift_reg;
    reg [3:0]                 pair_index_reg;
    reg                       busy_reg;
    reg signed [ACC_WIDTH-1:0] biased_low_reg;
    reg signed [ACC_WIDTH-1:0] biased_high_reg;
    reg                       bias_valid_reg;
    reg                       bias_last_reg;
    reg                       issue_done_reg;
    reg [7:0]                 x_reg;
    reg [7:0]                 y_reg;

    wire [7:0]  quantized_low;
    wire [7:0]  quantized_high;
    wire [15:0] quantized_pair;
    wire signed [ACC_WIDTH-1:0] biased_low;
    wire signed [ACC_WIDTH-1:0] biased_high;

    // Bias addition shares the same two arithmetic lanes as quantization.
    // The pair RAM is asynchronous and follows pair_index_reg, so sixteen
    // parallel 32-bit adders are no longer required in conv_engine_top.
    assign biased_low = $signed(sum_shift_reg[ACC_WIDTH-1:0]) +
                        $signed(in_bias_pair[31:0]);
    assign biased_high = $signed(sum_shift_reg[(2*ACC_WIDTH)-1:ACC_WIDTH]) +
                         $signed(in_bias_pair[63:32]);

    assign quantized_low = activated_quantized(
        biased_low_reg, activation_reg, shift_reg
    );
    assign quantized_high = activated_quantized(
        biased_high_reg, activation_reg, shift_reg
    );
    assign quantized_pair = {quantized_high, quantized_low};
    assign busy = busy_reg;
    assign bias_pair_addr = pair_index_reg[2:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_shift_reg   <= {SUM_BUS_WIDTH{1'b0}};
            pixel_shift_reg <= {PIXEL_BUS_WIDTH{1'b0}};
            activation_reg  <= 2'b00;
            shift_reg       <= 4'd0;
            pair_index_reg  <= 4'd0;
            busy_reg        <= 1'b0;
            biased_low_reg  <= {ACC_WIDTH{1'b0}};
            biased_high_reg <= {ACC_WIDTH{1'b0}};
            bias_valid_reg  <= 1'b0;
            bias_last_reg   <= 1'b0;
            issue_done_reg  <= 1'b0;
            x_reg           <= 8'd0;
            y_reg           <= 8'd0;
            out_pixel_bus   <= {PIXEL_BUS_WIDTH{1'b0}};
            out_valid       <= 1'b0;
            stage_valid     <= 1'b0;
            out_x           <= 8'd0;
            out_y           <= 8'd0;
        end else begin
            stage_valid <= in_valid && !busy_reg;
            out_valid   <= 1'b0;

            if (in_valid && !busy_reg) begin
                // Issue pair 0 on the acceptance edge. This keeps the external
                // initiation interval at the original eight cycles while the
                // bias add and activation remain separated by a register.
                sum_shift_reg   <= {
                    {(2*ACC_WIDTH){1'b0}},
                    in_sum_bus[SUM_BUS_WIDTH-1:2*ACC_WIDTH]
                };
                pixel_shift_reg <= {PIXEL_BUS_WIDTH{1'b0}};
                activation_reg  <= cfg_activation_type;
                shift_reg       <= shift_bits;
                pair_index_reg  <= (LAST_PAIR == 0) ? 4'd0 : 4'd1;
                busy_reg        <= 1'b1;
                biased_low_reg  <= $signed(in_sum_bus[ACC_WIDTH-1:0]) +
                                   $signed(in_bias_pair[31:0]);
                biased_high_reg <= $signed(in_sum_bus[(2*ACC_WIDTH)-1:ACC_WIDTH]) +
                                   $signed(in_bias_pair[63:32]);
                bias_valid_reg  <= 1'b1;
                bias_last_reg   <= (LAST_PAIR == 0);
                issue_done_reg  <= (LAST_PAIR == 0);
                x_reg           <= in_x;
                y_reg           <= in_y;
            end else if (busy_reg) begin
                // Stage 1: asynchronous bias RAM read plus the two bias adds.
                // Stage 2 below activates and quantizes the previously issued
                // pair. One pair still advances each cycle after fill.
                if (!issue_done_reg) begin
                    biased_low_reg  <= biased_low;
                    biased_high_reg <= biased_high;
                    bias_valid_reg  <= 1'b1;
                    bias_last_reg   <= pair_index_reg == LAST_PAIR;
                    sum_shift_reg <= {
                        {(2*ACC_WIDTH){1'b0}},
                        sum_shift_reg[SUM_BUS_WIDTH-1:2*ACC_WIDTH]
                    };
                    if (pair_index_reg == LAST_PAIR) begin
                        issue_done_reg <= 1'b1;
                    end else begin
                        pair_index_reg <= pair_index_reg + 4'd1;
                    end
                end else begin
                    bias_valid_reg <= 1'b0;
                end

                if (bias_valid_reg) begin
                    pixel_shift_reg <= {
                        quantized_pair,
                        pixel_shift_reg[PIXEL_BUS_WIDTH-1:16]
                    };
                end

                if (bias_valid_reg && bias_last_reg) begin
                    out_pixel_bus <= {
                        quantized_pair,
                        pixel_shift_reg[PIXEL_BUS_WIDTH-1:16]
                    };
                    out_valid <= 1'b1;
                    out_x     <= x_reg;
                    out_y     <= y_reg;
                    busy_reg  <= 1'b0;
                    bias_valid_reg <= 1'b0;
                    issue_done_reg <= 1'b0;
                    pair_index_reg <= 4'd0;
                end
            end
        end
    end

endmodule

`resetall
