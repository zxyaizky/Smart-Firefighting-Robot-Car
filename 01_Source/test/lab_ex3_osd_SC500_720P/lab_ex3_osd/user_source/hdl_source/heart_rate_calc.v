// -----------------------------------------------------------------------------
// File   : heart_rate_calc.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Sample-enabled signed IR peak detection, interval limits, iterative
//   integer BPM division, and a rolling four-interval BPM average.
//   The fixed peak threshold requires calibration with real PPG data.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module heart_rate_calc #
(
    parameter integer SAMPLE_RATE_HZ = 100,
    parameter integer MIN_BPM = 40,
    parameter integer MAX_BPM = 200,
    parameter signed [18:0] PEAK_THRESHOLD = 19'sd800
)
(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [18:0] ir_filtered,
    input  wire               ppg_valid,
    input  wire               finger_present,
    input  wire               signal_good,
    output reg  [8:0]         heart_rate_bpm,
    output reg                heart_rate_valid,
    output reg                peak_detected,
    output reg  [15:0]        peak_interval,
    output reg                candidate_peak,
    output wire               refractory_active
);
    localparam integer BPM_NUMERATOR = 60 * SAMPLE_RATE_HZ;
    localparam integer MIN_PEAK_INTERVAL =
        (BPM_NUMERATOR + MAX_BPM - 1) / MAX_BPM;
    localparam integer MAX_PEAK_INTERVAL = BPM_NUMERATOR / MIN_BPM;
    localparam integer SHORT_RESET_INTERVAL =
        (MIN_PEAK_INTERVAL < 2) ? 1 : (MIN_PEAK_INTERVAL / 2);
    localparam [15:0] MIN_INTERVAL_16 = MIN_PEAK_INTERVAL[15:0];
    localparam [15:0] MAX_INTERVAL_16 = MAX_PEAK_INTERVAL[15:0];
    localparam [15:0] SHORT_RESET_16 = SHORT_RESET_INTERVAL[15:0];
    localparam integer DIV_WIDTH = (BPM_NUMERATOR < 2) ? 1 :
                                   $clog2(BPM_NUMERATOR + 1);
    localparam integer REM_WIDTH = (DIV_WIDTH + 1 > 17) ?
                                   (DIV_WIDTH + 1) : 17;
    localparam integer DIV_COUNT_WIDTH = $clog2(DIV_WIDTH + 1);
    localparam [DIV_WIDTH-1:0] DIVIDEND_INITIAL =
        BPM_NUMERATOR[DIV_WIDTH-1:0];
    localparam [DIV_COUNT_WIDTH-1:0] DIV_BITS_INITIAL =
        DIV_WIDTH[DIV_COUNT_WIDTH-1:0];

    reg signed [18:0] older_point_reg;
    reg signed [18:0] previous_point_reg;
    reg [1:0] history_count_reg;
    reg have_previous_peak_reg;
    reg short_candidate_seen_reg;
    reg [15:0] samples_since_peak_reg;
    reg [8:0] bpm0_reg;
    reg [8:0] bpm1_reg;
    reg [8:0] bpm2_reg;
    reg [1:0] bpm_history_count_reg;
    reg divider_busy_reg;
    reg [DIV_WIDTH-1:0] dividend_reg;
    reg [DIV_WIDTH-1:0] quotient_reg;
    reg [REM_WIDTH-1:0] remainder_reg;
    reg [15:0] divisor_reg;
    reg [DIV_COUNT_WIDTH-1:0] division_bits_left_reg;

    wire local_maximum;
    wire qualified_candidate;
    wire [15:0] current_interval;
    wire [REM_WIDTH-1:0] trial_remainder;
    wire [REM_WIDTH-1:0] divisor_extended;
    wire trial_fits;
    wire [DIV_WIDTH-1:0] quotient_next;
    // The low two sum bits are intentionally discarded by /4.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [10:0] bpm_sum_next;
    /* verilator lint_on UNUSEDSIGNAL */

    assign local_maximum = (history_count_reg == 2'd2) &&
                           (previous_point_reg > older_point_reg) &&
                           (previous_point_reg >= ir_filtered);
    assign qualified_candidate = local_maximum &&
                                 (previous_point_reg > PEAK_THRESHOLD);
    assign current_interval = samples_since_peak_reg + 1'b1;
    assign refractory_active = have_previous_peak_reg &&
                               (samples_since_peak_reg < MIN_INTERVAL_16);

    // One quotient bit is produced per FPGA clock; no '/' operator is used
    // on a signal and no combinational divider is inferred.
    assign trial_remainder = (remainder_reg << 1) |
        {{(REM_WIDTH-1){1'b0}}, dividend_reg[DIV_WIDTH-1]};
    assign divisor_extended = {{(REM_WIDTH-16){1'b0}}, divisor_reg};
    assign trial_fits = (trial_remainder >= divisor_extended);
    assign quotient_next = (quotient_reg << 1) |
        {{(DIV_WIDTH-1){1'b0}}, trial_fits};
    assign bpm_sum_next = {2'd0, bpm0_reg} + {2'd0, bpm1_reg} +
                          {2'd0, bpm2_reg} + {2'd0, quotient_next[8:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            older_point_reg        <= 19'sd0;
            previous_point_reg     <= 19'sd0;
            history_count_reg      <= 2'd0;
            have_previous_peak_reg <= 1'b0;
            short_candidate_seen_reg <= 1'b0;
            samples_since_peak_reg <= 16'd0;
            bpm0_reg               <= 9'd0;
            bpm1_reg               <= 9'd0;
            bpm2_reg               <= 9'd0;
            bpm_history_count_reg  <= 2'd0;
            divider_busy_reg       <= 1'b0;
            dividend_reg           <= {DIV_WIDTH{1'b0}};
            quotient_reg           <= {DIV_WIDTH{1'b0}};
            remainder_reg          <= {REM_WIDTH{1'b0}};
            divisor_reg            <= 16'd0;
            division_bits_left_reg <= {DIV_COUNT_WIDTH{1'b0}};
            heart_rate_bpm         <= 9'd0;
            heart_rate_valid       <= 1'b0;
            peak_detected          <= 1'b0;
            peak_interval          <= 16'd0;
            candidate_peak         <= 1'b0;
        end else begin
            heart_rate_valid <= 1'b0;
            peak_detected    <= 1'b0;
            candidate_peak   <= 1'b0;
            if (!finger_present || !signal_good) begin
                older_point_reg          <= 19'sd0;
                previous_point_reg       <= 19'sd0;
                history_count_reg        <= 2'd0;
                have_previous_peak_reg   <= 1'b0;
                short_candidate_seen_reg <= 1'b0;
                samples_since_peak_reg   <= 16'd0;
                bpm0_reg                 <= 9'd0;
                bpm1_reg                 <= 9'd0;
                bpm2_reg                 <= 9'd0;
                bpm_history_count_reg    <= 2'd0;
                divider_busy_reg         <= 1'b0;
                dividend_reg             <= {DIV_WIDTH{1'b0}};
                quotient_reg             <= {DIV_WIDTH{1'b0}};
                remainder_reg            <= {REM_WIDTH{1'b0}};
                divisor_reg              <= 16'd0;
                division_bits_left_reg   <= {DIV_COUNT_WIDTH{1'b0}};
                heart_rate_bpm           <= 9'd0;
                peak_interval            <= 16'd0;
            end else begin
                if (divider_busy_reg) begin
                    dividend_reg <= dividend_reg << 1;
                    quotient_reg <= quotient_next;
                    if (trial_fits)
                        remainder_reg <= trial_remainder - divisor_extended;
                    else
                        remainder_reg <= trial_remainder;
                    division_bits_left_reg <= division_bits_left_reg - 1'b1;
                    if (division_bits_left_reg == 1) begin
                        divider_busy_reg <= 1'b0;
                        bpm2_reg <= bpm1_reg;
                        bpm1_reg <= bpm0_reg;
                        bpm0_reg <= quotient_next[8:0];
                        if (bpm_history_count_reg != 2'd3)
                            bpm_history_count_reg <= bpm_history_count_reg + 1'b1;
                        else begin
                            heart_rate_bpm <= bpm_sum_next[10:2];
                            heart_rate_valid <= 1'b1;
                        end
                    end
                end

                if (ppg_valid) begin
                    older_point_reg <= previous_point_reg;
                    previous_point_reg <= ir_filtered;
                    if (history_count_reg != 2'd2)
                        history_count_reg <= history_count_reg + 1'b1;
                    if (qualified_candidate) candidate_peak <= 1'b1;

                    if (!have_previous_peak_reg) begin
                        if (qualified_candidate) begin
                            have_previous_peak_reg <= 1'b1;
                            samples_since_peak_reg <= 16'd0;
                            short_candidate_seen_reg <= 1'b0;
                            peak_detected <= 1'b1;
                        end
                    end else if (qualified_candidate) begin
                        if (current_interval < MIN_INTERVAL_16) begin
                            if (short_candidate_seen_reg ||
                                current_interval >= SHORT_RESET_16) begin
                                // A persistent too-fast train must not alias
                                // into a legal half-rate sequence. A single
                                // close secondary peak is merely discarded.
                                samples_since_peak_reg <= 16'd0;
                                short_candidate_seen_reg <= 1'b0;
                                bpm_history_count_reg <= 2'd0;
                                heart_rate_bpm <= 9'd0;
                                peak_interval <= 16'd0;
                            end else begin
                                short_candidate_seen_reg <= 1'b1;
                                samples_since_peak_reg <= current_interval;
                            end
                        end else if (current_interval > MAX_INTERVAL_16) begin
                            samples_since_peak_reg <= 16'd0;
                            short_candidate_seen_reg <= 1'b0;
                            bpm_history_count_reg <= 2'd0;
                            heart_rate_bpm <= 9'd0;
                            peak_interval <= 16'd0;
                            peak_detected <= 1'b1;
                        end else begin
                            samples_since_peak_reg <= 16'd0;
                            short_candidate_seen_reg <= 1'b0;
                            peak_interval <= current_interval;
                            peak_detected <= 1'b1;
                            if (!divider_busy_reg) begin
                                dividend_reg <= DIVIDEND_INITIAL;
                                quotient_reg <= {DIV_WIDTH{1'b0}};
                                remainder_reg <= {REM_WIDTH{1'b0}};
                                divisor_reg <= current_interval;
                                division_bits_left_reg <= DIV_BITS_INITIAL;
                                divider_busy_reg <= 1'b1;
                            end
                        end
                    end else if (samples_since_peak_reg >= MAX_INTERVAL_16) begin
                        have_previous_peak_reg <= 1'b0;
                        short_candidate_seen_reg <= 1'b0;
                        samples_since_peak_reg <= 16'd0;
                        bpm_history_count_reg <= 2'd0;
                        heart_rate_bpm <= 9'd0;
                        peak_interval <= 16'd0;
                    end else begin
                        samples_since_peak_reg <= current_interval;
                    end
                end
            end
        end
    end
endmodule

`resetall
