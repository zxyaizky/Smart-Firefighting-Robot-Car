// -----------------------------------------------------------------------------
// File   : max30102_ppg_preprocess.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Sample-enabled RED/IR DC tracking, signed AC extraction, four-point
//   smoothing, and simple finger / amplitude / saturation quality flags.
//   Threshold defaults are simulation starting points, not hardware-calibrated.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_ppg_preprocess #
(
    parameter integer DC_SHIFT = 6,
    parameter [17:0] FINGER_THRESHOLD = 18'd60000,
    parameter integer FINGER_DEBOUNCE = 8,
    parameter integer AMP_WINDOW_SAMPLES = 100,
    parameter [19:0] PPG_AMP_MIN = 20'd500,
    parameter [19:0] PPG_AMP_MAX = 20'd20000,
    parameter [17:0] SAT_LOW = 18'd1000,
    parameter [17:0] SAT_HIGH = 18'd261143,
    parameter integer SAT_DEBOUNCE = 4
)
(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [17:0]        red_raw,
    input  wire [17:0]        ir_raw,
    input  wire               sample_valid,
    output reg  [17:0]        red_dc,
    output reg  [17:0]        ir_dc,
    output reg  signed [18:0] red_ac,
    output reg  signed [18:0] ir_ac,
    output reg  signed [18:0] red_filtered,
    output reg  signed [18:0] ir_filtered,
    output reg                ppg_valid,
    output reg                finger_present,
    output reg                amplitude_good,
    output reg  [19:0]        ir_p2p,
    output reg                saturation_detect,
    output wire               signal_good
);
    localparam integer FINGER_WIDTH = (FINGER_DEBOUNCE < 2) ? 1 :
                                      $clog2(FINGER_DEBOUNCE);
    localparam integer SAT_WIDTH = (SAT_DEBOUNCE < 2) ? 1 :
                                   $clog2(SAT_DEBOUNCE);
    localparam integer WINDOW_WIDTH = (AMP_WINDOW_SAMPLES < 2) ? 1 :
                                      $clog2(AMP_WINDOW_SAMPLES);
    localparam [FINGER_WIDTH-1:0] FINGER_LAST =
        FINGER_DEBOUNCE[FINGER_WIDTH-1:0] - 1'b1;
    localparam [SAT_WIDTH-1:0] SAT_LAST =
        SAT_DEBOUNCE[SAT_WIDTH-1:0] - 1'b1;
    localparam [WINDOW_WIDTH-1:0] WINDOW_LAST =
        AMP_WINDOW_SAMPLES[WINDOW_WIDTH-1:0] - 1'b1;

    reg first_sample_seen_reg;
    reg [1:0] history_count_reg;
    reg signed [18:0] red_hist0_reg;
    reg signed [18:0] red_hist1_reg;
    reg signed [18:0] red_hist2_reg;
    reg signed [18:0] ir_hist0_reg;
    reg signed [18:0] ir_hist1_reg;
    reg signed [18:0] ir_hist2_reg;
    reg [FINGER_WIDTH-1:0] finger_count_reg;
    reg [SAT_WIDTH-1:0] sat_count_reg;
    reg [WINDOW_WIDTH-1:0] window_count_reg;
    reg signed [18:0] window_min_reg;
    reg signed [18:0] window_max_reg;

    wire signed [18:0] red_delta;
    wire signed [18:0] ir_delta;
    wire signed [18:0] red_dc_next_signed;
    wire signed [18:0] ir_dc_next_signed;
    wire signed [18:0] red_ac_next;
    wire signed [18:0] ir_ac_next;
    // Division by four deliberately discards the two fractional sum bits.
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [20:0] red_sum;
    wire signed [20:0] ir_sum;
    /* verilator lint_on UNUSEDSIGNAL */
    wire signed [18:0] red_average;
    wire signed [18:0] ir_average;
    wire signed [18:0] ir_filtered_next;
    wire signed [18:0] window_max_next;
    wire signed [18:0] window_min_next;
    wire signed [19:0] p2p_signed;
    wire [19:0] p2p_next;
    wire raw_saturated;

    // A 19-bit signed difference covers the complete 18-bit ADC range.
    assign red_delta = $signed({1'b0, red_raw}) - $signed({1'b0, red_dc});
    assign ir_delta  = $signed({1'b0, ir_raw}) - $signed({1'b0, ir_dc});
    assign red_dc_next_signed = first_sample_seen_reg ?
        ($signed({1'b0, red_dc}) + (red_delta >>> DC_SHIFT)) :
        $signed({1'b0, red_raw});
    assign ir_dc_next_signed = first_sample_seen_reg ?
        ($signed({1'b0, ir_dc}) + (ir_delta >>> DC_SHIFT)) :
        $signed({1'b0, ir_raw});
    assign red_ac_next = $signed({1'b0, red_raw}) - red_dc_next_signed;
    assign ir_ac_next  = $signed({1'b0, ir_raw}) - ir_dc_next_signed;

    // Four signed 19-bit values require 21 bits before the shift by two.
    assign red_sum = {{2{red_ac_next[18]}}, red_ac_next} +
                     {{2{red_hist0_reg[18]}}, red_hist0_reg} +
                     {{2{red_hist1_reg[18]}}, red_hist1_reg} +
                     {{2{red_hist2_reg[18]}}, red_hist2_reg};
    assign ir_sum = {{2{ir_ac_next[18]}}, ir_ac_next} +
                    {{2{ir_hist0_reg[18]}}, ir_hist0_reg} +
                    {{2{ir_hist1_reg[18]}}, ir_hist1_reg} +
                    {{2{ir_hist2_reg[18]}}, ir_hist2_reg};
    // [20:2] is the exact 19-bit result of an arithmetic right shift by 2.
    assign red_average = red_sum[20:2];
    assign ir_average  = ir_sum[20:2];
    assign ir_filtered_next = ir_average;

    assign window_max_next = (ir_filtered_next > window_max_reg) ?
                             ir_filtered_next : window_max_reg;
    assign window_min_next = (ir_filtered_next < window_min_reg) ?
                             ir_filtered_next : window_min_reg;
    assign p2p_signed = $signed({window_max_next[18], window_max_next}) -
                        $signed({window_min_next[18], window_min_next});
    assign p2p_next = p2p_signed[19:0];
    assign raw_saturated = (red_raw < SAT_LOW) || (red_raw > SAT_HIGH) ||
                           (ir_raw < SAT_LOW) || (ir_raw > SAT_HIGH);
    assign signal_good = finger_present && amplitude_good &&
                         !saturation_detect;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_sample_seen_reg <= 1'b0;
            history_count_reg     <= 2'd0;
            red_dc                <= 18'd0;
            ir_dc                 <= 18'd0;
            red_ac                <= 19'sd0;
            ir_ac                 <= 19'sd0;
            red_filtered          <= 19'sd0;
            ir_filtered           <= 19'sd0;
            red_hist0_reg         <= 19'sd0;
            red_hist1_reg         <= 19'sd0;
            red_hist2_reg         <= 19'sd0;
            ir_hist0_reg          <= 19'sd0;
            ir_hist1_reg          <= 19'sd0;
            ir_hist2_reg          <= 19'sd0;
            ppg_valid             <= 1'b0;
            finger_present        <= 1'b0;
            finger_count_reg      <= {FINGER_WIDTH{1'b0}};
            amplitude_good        <= 1'b0;
            ir_p2p                <= 20'd0;
            window_count_reg      <= {WINDOW_WIDTH{1'b0}};
            window_min_reg        <= 19'sd0;
            window_max_reg        <= 19'sd0;
            saturation_detect     <= 1'b0;
            sat_count_reg         <= {SAT_WIDTH{1'b0}};
        end else begin
            ppg_valid <= 1'b0;
            if (sample_valid) begin
                first_sample_seen_reg <= 1'b1;
                red_dc       <= red_dc_next_signed[17:0];
                ir_dc        <= ir_dc_next_signed[17:0];
                red_ac       <= red_ac_next;
                ir_ac        <= ir_ac_next;
                red_filtered <= red_average;
                ir_filtered  <= ir_filtered_next;
                red_hist2_reg <= red_hist1_reg;
                red_hist1_reg <= red_hist0_reg;
                red_hist0_reg <= red_ac_next;
                ir_hist2_reg <= ir_hist1_reg;
                ir_hist1_reg <= ir_hist0_reg;
                ir_hist0_reg <= ir_ac_next;
                if (history_count_reg != 2'd3)
                    history_count_reg <= history_count_reg + 1'b1;
                if (history_count_reg == 2'd3) ppg_valid <= 1'b1;

                // Consecutive samples are required in both directions.
                if (ir_dc_next_signed[17:0] > FINGER_THRESHOLD) begin
                    if (!finger_present) begin
                        if (finger_count_reg == FINGER_LAST) begin
                            finger_present   <= 1'b1;
                            finger_count_reg <= {FINGER_WIDTH{1'b0}};
                        end else begin
                            finger_count_reg <= finger_count_reg + 1'b1;
                        end
                    end else begin
                        finger_count_reg <= {FINGER_WIDTH{1'b0}};
                    end
                end else if (finger_present) begin
                    if (finger_count_reg == FINGER_LAST) begin
                        finger_present   <= 1'b0;
                        finger_count_reg <= {FINGER_WIDTH{1'b0}};
                    end else begin
                        finger_count_reg <= finger_count_reg + 1'b1;
                    end
                end else begin
                    finger_count_reg <= {FINGER_WIDTH{1'b0}};
                end

                if (raw_saturated) begin
                    if (!saturation_detect) begin
                        if (sat_count_reg == SAT_LAST) begin
                            saturation_detect <= 1'b1;
                            sat_count_reg <= {SAT_WIDTH{1'b0}};
                        end else begin
                            sat_count_reg <= sat_count_reg + 1'b1;
                        end
                    end else begin
                        sat_count_reg <= {SAT_WIDTH{1'b0}};
                    end
                end else if (saturation_detect) begin
                    if (sat_count_reg == SAT_LAST) begin
                        saturation_detect <= 1'b0;
                        sat_count_reg <= {SAT_WIDTH{1'b0}};
                    end else begin
                        sat_count_reg <= sat_count_reg + 1'b1;
                    end
                end else begin
                    sat_count_reg <= {SAT_WIDTH{1'b0}};
                end

                // A completed window is required before amplitude_good can
                // assert. An excessive excursion invalidates it immediately.
                if (history_count_reg != 2'd3 || !finger_present ||
                    saturation_detect) begin
                    window_count_reg <= {WINDOW_WIDTH{1'b0}};
                    amplitude_good <= 1'b0;
                    ir_p2p <= 20'd0;
                end else if (window_count_reg == {WINDOW_WIDTH{1'b0}}) begin
                    window_min_reg <= ir_filtered_next;
                    window_max_reg <= ir_filtered_next;
                    window_count_reg <= window_count_reg + 1'b1;
                end else if (window_count_reg == WINDOW_LAST) begin
                    ir_p2p <= p2p_next;
                    amplitude_good <= (p2p_next >= PPG_AMP_MIN) &&
                                      (p2p_next <= PPG_AMP_MAX);
                    window_count_reg <= {WINDOW_WIDTH{1'b0}};
                end else begin
                    window_min_reg <= window_min_next;
                    window_max_reg <= window_max_next;
                    window_count_reg <= window_count_reg + 1'b1;
                    if (p2p_next > PPG_AMP_MAX) amplitude_good <= 1'b0;
                end
            end
        end
    end
endmodule

`resetall
