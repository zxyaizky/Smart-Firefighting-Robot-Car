// -----------------------------------------------------------------------------
// File   : spo2_calc.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Non-overlapping RED/IR windows. Raw averages estimate DC; signed
//   filtered peak-to-peak values estimate AC. A time-shared restoring divider
//   calculates both DC averages, R*1000, and Maxim's R*100 table index.
//   The lookup table is copied from the local MAXREFDES117 spo2_algorithm.h.
//   This simplified AC method is not a calibrated medical SpO2 algorithm.
//   WINDOW_SIZE must be at least two; R_SCALE must be a positive multiple
//   of 100 so that Maxim's R*100 table index is exact.
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module spo2_calc #
(
    parameter integer WINDOW_SIZE = 100,
    parameter integer R_SCALE = 1000
)
(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [17:0]        red_raw,
    input  wire [17:0]        ir_raw,
    input  wire signed [18:0] red_filtered,
    input  wire signed [18:0] ir_filtered,
    input  wire               ppg_valid,
    input  wire               finger_present,
    input  wire               signal_good,
    output reg  [7:0]         spo2,
    output reg                spo2_valid,
    output reg  [31:0]        ratio_r,
    output reg  [17:0]        red_dc_window,
    output reg  [17:0]        ir_dc_window,
    output reg  [19:0]        red_ac_window,
    output reg  [19:0]        ir_ac_window
);
    localparam integer COUNT_WIDTH = (WINDOW_SIZE < 2) ? 1 :
                                     $clog2(WINDOW_SIZE);
    localparam integer SUM_WIDTH = 18 + $clog2(WINDOW_SIZE);
    localparam integer SCALE_WIDTH = (R_SCALE < 2) ? 1 :
                                     $clog2(R_SCALE + 1);
    localparam integer PRODUCT_WIDTH = 38;
    localparam integer SCALED_WIDTH = PRODUCT_WIDTH + SCALE_WIDTH;
    localparam integer DIV_WIDTH = (SCALED_WIDTH > 32) ?
                                   SCALED_WIDTH : 32;
    localparam integer DIV_COUNT_WIDTH = $clog2(DIV_WIDTH + 1);
    localparam integer INDEX_DIVISOR = (R_SCALE >= 100) ?
                                       (R_SCALE / 100) : 1;
    localparam SCALE_VALID = (R_SCALE >= 100) &&
                             ((R_SCALE % 100) == 0);
    localparam [31:0] WINDOW_SIZE_32 = WINDOW_SIZE;
    localparam [31:0] INDEX_DIVISOR_32 = INDEX_DIVISOR;
    /* verilator lint_off WIDTHCONCAT */
    localparam [DIV_WIDTH-1:0] WINDOW_DIVISOR =
        {{(DIV_WIDTH-32){1'b0}}, WINDOW_SIZE_32};
    localparam [DIV_WIDTH-1:0] TABLE_INDEX_DIVISOR =
        {{(DIV_WIDTH-32){1'b0}}, INDEX_DIVISOR_32};
    /* verilator lint_on WIDTHCONCAT */
    localparam [COUNT_WIDTH-1:0] WINDOW_LAST =
        WINDOW_SIZE[COUNT_WIDTH-1:0] - 1'b1;
    localparam [DIV_COUNT_WIDTH-1:0] DIV_BITS =
        DIV_WIDTH[DIV_COUNT_WIDTH-1:0];

    localparam [2:0] IDLE = 3'd0;
    localparam [2:0] DIV_RED_DC = 3'd1;
    localparam [2:0] DIV_IR_DC = 3'd2;
    localparam [2:0] SETUP_RATIO = 3'd3;
    localparam [2:0] DIV_RATIO = 3'd4;
    localparam [2:0] DIV_INDEX = 3'd5;

    reg [2:0] calc_state_reg;
    reg [COUNT_WIDTH-1:0] window_count_reg;
    reg [SUM_WIDTH-1:0] red_sum_reg;
    reg [SUM_WIDTH-1:0] ir_sum_reg;
    reg signed [18:0] red_min_reg;
    reg signed [18:0] red_max_reg;
    reg signed [18:0] ir_min_reg;
    reg signed [18:0] ir_max_reg;
    reg [SUM_WIDTH-1:0] ir_sum_snapshot_reg;
    reg ratio_overflow_reg;

    reg [DIV_WIDTH-1:0] dividend_reg;
    reg [DIV_WIDTH-1:0] divisor_reg;
    reg [DIV_WIDTH-1:0] quotient_reg;
    reg [DIV_WIDTH:0] remainder_reg;
    reg [DIV_COUNT_WIDTH-1:0] division_bits_left_reg;

    wire [SUM_WIDTH-1:0] red_sum_next;
    wire [SUM_WIDTH-1:0] ir_sum_next;
    wire signed [18:0] red_max_next;
    wire signed [18:0] red_min_next;
    wire signed [18:0] ir_max_next;
    wire signed [18:0] ir_min_next;
    wire signed [19:0] red_span_signed;
    wire signed [19:0] ir_span_signed;
    wire [PRODUCT_WIDTH-1:0] red_product;
    wire [PRODUCT_WIDTH-1:0] denominator_product;
    wire [SCALED_WIDTH-1:0] scaled_product;
    wire [DIV_WIDTH:0] trial_remainder;
    wire [DIV_WIDTH:0] divisor_extended;
    wire trial_fits;
    wire [DIV_WIDTH-1:0] quotient_next;
    wire [7:0] table_value;

    assign red_sum_next = red_sum_reg +
                          {{(SUM_WIDTH-18){1'b0}}, red_raw};
    assign ir_sum_next = ir_sum_reg +
                         {{(SUM_WIDTH-18){1'b0}}, ir_raw};
    assign red_max_next = (red_filtered > red_max_reg) ?
                          red_filtered : red_max_reg;
    assign red_min_next = (red_filtered < red_min_reg) ?
                          red_filtered : red_min_reg;
    assign ir_max_next = (ir_filtered > ir_max_reg) ?
                         ir_filtered : ir_max_reg;
    assign ir_min_next = (ir_filtered < ir_min_reg) ?
                         ir_filtered : ir_min_reg;
    assign red_span_signed = $signed({red_max_next[18], red_max_next}) -
                             $signed({red_min_next[18], red_min_next});
    assign ir_span_signed = $signed({ir_max_next[18], ir_max_next}) -
                            $signed({ir_min_next[18], ir_min_next});
    assign red_product = red_ac_window * ir_dc_window;
    assign denominator_product = ir_ac_window * red_dc_window;
    assign scaled_product = red_product *
                            R_SCALE[SCALE_WIDTH-1:0];

    // Restoring division: one quotient bit per FPGA clock.
    assign trial_remainder = (remainder_reg << 1) |
        {{DIV_WIDTH{1'b0}}, dividend_reg[DIV_WIDTH-1]};
    assign divisor_extended = {1'b0, divisor_reg};
    assign trial_fits = (trial_remainder >= divisor_extended);
    assign quotient_next = (quotient_reg << 1) |
        {{(DIV_WIDTH-1){1'b0}}, trial_fits};
    assign table_value = maxim_table(quotient_next[7:0]);

    function [7:0] maxim_table;
        input [7:0] index;
        begin
            case (index)
+            8'd0: maxim_table = 8'd95;
            8'd1: maxim_table = 8'd95;
            8'd2: maxim_table = 8'd95;
            8'd3: maxim_table = 8'd96;
            8'd4: maxim_table = 8'd96;
            8'd5: maxim_table = 8'd96;
            8'd6: maxim_table = 8'd97;
            8'd7: maxim_table = 8'd97;
            8'd8: maxim_table = 8'd97;
            8'd9: maxim_table = 8'd97;
            8'd10: maxim_table = 8'd97;
            8'd11: maxim_table = 8'd98;
            8'd12: maxim_table = 8'd98;
            8'd13: maxim_table = 8'd98;
            8'd14: maxim_table = 8'd98;
            8'd15: maxim_table = 8'd98;
            8'd16: maxim_table = 8'd99;
            8'd17: maxim_table = 8'd99;
            8'd18: maxim_table = 8'd99;
            8'd19: maxim_table = 8'd99;
            8'd20: maxim_table = 8'd99;
            8'd21: maxim_table = 8'd99;
            8'd22: maxim_table = 8'd99;
            8'd23: maxim_table = 8'd99;
            8'd24: maxim_table = 8'd100;
            8'd25: maxim_table = 8'd100;
            8'd26: maxim_table = 8'd100;
            8'd27: maxim_table = 8'd100;
            8'd28: maxim_table = 8'd100;
            8'd29: maxim_table = 8'd100;
            8'd30: maxim_table = 8'd100;
            8'd31: maxim_table = 8'd100;
            8'd32: maxim_table = 8'd100;
            8'd33: maxim_table = 8'd100;
            8'd34: maxim_table = 8'd100;
            8'd35: maxim_table = 8'd100;
            8'd36: maxim_table = 8'd100;
            8'd37: maxim_table = 8'd100;
            8'd38: maxim_table = 8'd100;
            8'd39: maxim_table = 8'd100;
            8'd40: maxim_table = 8'd100;
            8'd41: maxim_table = 8'd100;
            8'd42: maxim_table = 8'd100;
            8'd43: maxim_table = 8'd100;
            8'd44: maxim_table = 8'd99;
            8'd45: maxim_table = 8'd99;
            8'd46: maxim_table = 8'd99;
            8'd47: maxim_table = 8'd99;
            8'd48: maxim_table = 8'd99;
            8'd49: maxim_table = 8'd99;
            8'd50: maxim_table = 8'd99;
            8'd51: maxim_table = 8'd99;
            8'd52: maxim_table = 8'd98;
            8'd53: maxim_table = 8'd98;
            8'd54: maxim_table = 8'd98;
            8'd55: maxim_table = 8'd98;
            8'd56: maxim_table = 8'd98;
            8'd57: maxim_table = 8'd98;
            8'd58: maxim_table = 8'd97;
            8'd59: maxim_table = 8'd97;
            8'd60: maxim_table = 8'd97;
            8'd61: maxim_table = 8'd97;
            8'd62: maxim_table = 8'd96;
            8'd63: maxim_table = 8'd96;
            8'd64: maxim_table = 8'd96;
            8'd65: maxim_table = 8'd96;
            8'd66: maxim_table = 8'd95;
            8'd67: maxim_table = 8'd95;
            8'd68: maxim_table = 8'd95;
            8'd69: maxim_table = 8'd94;
            8'd70: maxim_table = 8'd94;
            8'd71: maxim_table = 8'd94;
            8'd72: maxim_table = 8'd93;
            8'd73: maxim_table = 8'd93;
            8'd74: maxim_table = 8'd93;
            8'd75: maxim_table = 8'd92;
            8'd76: maxim_table = 8'd92;
            8'd77: maxim_table = 8'd92;
            8'd78: maxim_table = 8'd91;
            8'd79: maxim_table = 8'd91;
            8'd80: maxim_table = 8'd90;
            8'd81: maxim_table = 8'd90;
            8'd82: maxim_table = 8'd89;
            8'd83: maxim_table = 8'd89;
            8'd84: maxim_table = 8'd89;
            8'd85: maxim_table = 8'd88;
            8'd86: maxim_table = 8'd88;
            8'd87: maxim_table = 8'd87;
            8'd88: maxim_table = 8'd87;
            8'd89: maxim_table = 8'd86;
            8'd90: maxim_table = 8'd86;
            8'd91: maxim_table = 8'd85;
            8'd92: maxim_table = 8'd85;
            8'd93: maxim_table = 8'd84;
            8'd94: maxim_table = 8'd84;
            8'd95: maxim_table = 8'd83;
            8'd96: maxim_table = 8'd82;
            8'd97: maxim_table = 8'd82;
            8'd98: maxim_table = 8'd81;
            8'd99: maxim_table = 8'd81;
            8'd100: maxim_table = 8'd80;
            8'd101: maxim_table = 8'd80;
            8'd102: maxim_table = 8'd79;
            8'd103: maxim_table = 8'd78;
            8'd104: maxim_table = 8'd78;
            8'd105: maxim_table = 8'd77;
            8'd106: maxim_table = 8'd76;
            8'd107: maxim_table = 8'd76;
            8'd108: maxim_table = 8'd75;
            8'd109: maxim_table = 8'd74;
            8'd110: maxim_table = 8'd74;
            8'd111: maxim_table = 8'd73;
            8'd112: maxim_table = 8'd72;
            8'd113: maxim_table = 8'd72;
            8'd114: maxim_table = 8'd71;
            8'd115: maxim_table = 8'd70;
            8'd116: maxim_table = 8'd69;
            8'd117: maxim_table = 8'd69;
            8'd118: maxim_table = 8'd68;
            8'd119: maxim_table = 8'd67;
            8'd120: maxim_table = 8'd66;
            8'd121: maxim_table = 8'd66;
            8'd122: maxim_table = 8'd65;
            8'd123: maxim_table = 8'd64;
            8'd124: maxim_table = 8'd63;
            8'd125: maxim_table = 8'd62;
            8'd126: maxim_table = 8'd62;
            8'd127: maxim_table = 8'd61;
            8'd128: maxim_table = 8'd60;
            8'd129: maxim_table = 8'd59;
            8'd130: maxim_table = 8'd58;
            8'd131: maxim_table = 8'd57;
            8'd132: maxim_table = 8'd56;
            8'd133: maxim_table = 8'd56;
            8'd134: maxim_table = 8'd55;
            8'd135: maxim_table = 8'd54;
            8'd136: maxim_table = 8'd53;
            8'd137: maxim_table = 8'd52;
            8'd138: maxim_table = 8'd51;
            8'd139: maxim_table = 8'd50;
            8'd140: maxim_table = 8'd49;
            8'd141: maxim_table = 8'd48;
            8'd142: maxim_table = 8'd47;
            8'd143: maxim_table = 8'd46;
            8'd144: maxim_table = 8'd45;
            8'd145: maxim_table = 8'd44;
            8'd146: maxim_table = 8'd43;
            8'd147: maxim_table = 8'd42;
            8'd148: maxim_table = 8'd41;
            8'd149: maxim_table = 8'd40;
            8'd150: maxim_table = 8'd39;
            8'd151: maxim_table = 8'd38;
            8'd152: maxim_table = 8'd37;
            8'd153: maxim_table = 8'd36;
            8'd154: maxim_table = 8'd35;
            8'd155: maxim_table = 8'd34;
            8'd156: maxim_table = 8'd33;
            8'd157: maxim_table = 8'd31;
            8'd158: maxim_table = 8'd30;
            8'd159: maxim_table = 8'd29;
            8'd160: maxim_table = 8'd28;
            8'd161: maxim_table = 8'd27;
            8'd162: maxim_table = 8'd26;
            8'd163: maxim_table = 8'd25;
            8'd164: maxim_table = 8'd23;
            8'd165: maxim_table = 8'd22;
            8'd166: maxim_table = 8'd21;
            8'd167: maxim_table = 8'd20;
            8'd168: maxim_table = 8'd19;
            8'd169: maxim_table = 8'd17;
            8'd170: maxim_table = 8'd16;
            8'd171: maxim_table = 8'd15;
            8'd172: maxim_table = 8'd14;
            8'd173: maxim_table = 8'd12;
            8'd174: maxim_table = 8'd11;
            8'd175: maxim_table = 8'd10;
            8'd176: maxim_table = 8'd9;
            8'd177: maxim_table = 8'd7;
            8'd178: maxim_table = 8'd6;
            8'd179: maxim_table = 8'd5;
            8'd180: maxim_table = 8'd3;
            8'd181: maxim_table = 8'd2;
            8'd182: maxim_table = 8'd1;
            8'd183: maxim_table = 8'd0; // C array's implicit final zero
                default: maxim_table = 8'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calc_state_reg <= IDLE;
            window_count_reg <= {COUNT_WIDTH{1'b0}};
            red_sum_reg <= {SUM_WIDTH{1'b0}};
            ir_sum_reg <= {SUM_WIDTH{1'b0}};
            red_min_reg <= 19'sd0;
            red_max_reg <= 19'sd0;
            ir_min_reg <= 19'sd0;
            ir_max_reg <= 19'sd0;
            ir_sum_snapshot_reg <= {SUM_WIDTH{1'b0}};
            ratio_overflow_reg <= 1'b0;
            dividend_reg <= {DIV_WIDTH{1'b0}};
            divisor_reg <= {DIV_WIDTH{1'b0}};
            quotient_reg <= {DIV_WIDTH{1'b0}};
            remainder_reg <= {(DIV_WIDTH+1){1'b0}};
            division_bits_left_reg <= {DIV_COUNT_WIDTH{1'b0}};
            spo2 <= 8'd0;
            spo2_valid <= 1'b0;
            ratio_r <= 32'd0;
            red_dc_window <= 18'd0;
            ir_dc_window <= 18'd0;
            red_ac_window <= 20'd0;
            ir_ac_window <= 20'd0;
        end else begin
            spo2_valid <= 1'b0;
            if (!finger_present || !signal_good) begin
                calc_state_reg <= IDLE;
                window_count_reg <= {COUNT_WIDTH{1'b0}};
                red_sum_reg <= {SUM_WIDTH{1'b0}};
                ir_sum_reg <= {SUM_WIDTH{1'b0}};
                red_min_reg <= 19'sd0;
                red_max_reg <= 19'sd0;
                ir_min_reg <= 19'sd0;
                ir_max_reg <= 19'sd0;
                ir_sum_snapshot_reg <= {SUM_WIDTH{1'b0}};
                ratio_overflow_reg <= 1'b0;
                dividend_reg <= {DIV_WIDTH{1'b0}};
                divisor_reg <= {DIV_WIDTH{1'b0}};
                quotient_reg <= {DIV_WIDTH{1'b0}};
                remainder_reg <= {(DIV_WIDTH+1){1'b0}};
                division_bits_left_reg <= {DIV_COUNT_WIDTH{1'b0}};
                spo2 <= 8'd0;
                ratio_r <= 32'd0;
                red_dc_window <= 18'd0;
                ir_dc_window <= 18'd0;
                red_ac_window <= 20'd0;
                ir_ac_window <= 20'd0;
            end else begin
                // Acquisition is independent of the calculation FSM. At
                // 100 samples/s the ~200-clock calculation finishes long
                // before the next 100-sample window can end.
                if (ppg_valid) begin
                    if (window_count_reg == {COUNT_WIDTH{1'b0}}) begin
                        red_sum_reg <= {{(SUM_WIDTH-18){1'b0}}, red_raw};
                        ir_sum_reg <= {{(SUM_WIDTH-18){1'b0}}, ir_raw};
                        red_min_reg <= red_filtered;
                        red_max_reg <= red_filtered;
                        ir_min_reg <= ir_filtered;
                        ir_max_reg <= ir_filtered;
                        window_count_reg <= window_count_reg + 1'b1;
                    end else if (window_count_reg == WINDOW_LAST) begin
                        window_count_reg <= {COUNT_WIDTH{1'b0}};
                        red_sum_reg <= {SUM_WIDTH{1'b0}};
                        ir_sum_reg <= {SUM_WIDTH{1'b0}};
                        if (calc_state_reg == IDLE) begin
                            ir_sum_snapshot_reg <= ir_sum_next;
                            red_ac_window <= red_span_signed[19:0];
                            ir_ac_window <= ir_span_signed[19:0];
                            dividend_reg <= {{(DIV_WIDTH-SUM_WIDTH){1'b0}},
                                             red_sum_next};
                            divisor_reg <= WINDOW_DIVISOR;
                            quotient_reg <= {DIV_WIDTH{1'b0}};
                            remainder_reg <= {(DIV_WIDTH+1){1'b0}};
                            division_bits_left_reg <= DIV_BITS;
                            calc_state_reg <= DIV_RED_DC;
                        end
                    end else begin
                        red_sum_reg <= red_sum_next;
                        ir_sum_reg <= ir_sum_next;
                        red_min_reg <= red_min_next;
                        red_max_reg <= red_max_next;
                        ir_min_reg <= ir_min_next;
                        ir_max_reg <= ir_max_next;
                        window_count_reg <= window_count_reg + 1'b1;
                    end
                end

                if (calc_state_reg == DIV_RED_DC ||
                    calc_state_reg == DIV_IR_DC ||
                    calc_state_reg == DIV_RATIO ||
                    calc_state_reg == DIV_INDEX) begin
                    dividend_reg <= dividend_reg << 1;
                    quotient_reg <= quotient_next;
                    if (trial_fits)
                        remainder_reg <= trial_remainder - divisor_extended;
                    else
                        remainder_reg <= trial_remainder;
                    division_bits_left_reg <= division_bits_left_reg - 1'b1;
                    if (division_bits_left_reg == 1) begin
                        if (calc_state_reg == DIV_RED_DC) begin
                            red_dc_window <= quotient_next[17:0];
                            dividend_reg <= {{(DIV_WIDTH-SUM_WIDTH){1'b0}},
                                             ir_sum_snapshot_reg};
                            divisor_reg <= WINDOW_DIVISOR;
                            quotient_reg <= {DIV_WIDTH{1'b0}};
                            remainder_reg <= {(DIV_WIDTH+1){1'b0}};
                            division_bits_left_reg <= DIV_BITS;
                            calc_state_reg <= DIV_IR_DC;
                        end else if (calc_state_reg == DIV_IR_DC) begin
                            ir_dc_window <= quotient_next[17:0];
                            calc_state_reg <= SETUP_RATIO;
                        end else if (calc_state_reg == DIV_RATIO) begin
                            if ((quotient_next >> 32) != 0) begin
                                ratio_r <= 32'hffffffff;
                                ratio_overflow_reg <= 1'b1;
                            end else begin
                                ratio_r <= quotient_next[31:0];
                                ratio_overflow_reg <= 1'b0;
                            end
                            dividend_reg <= quotient_next;
                            divisor_reg <= TABLE_INDEX_DIVISOR;
                            quotient_reg <= {DIV_WIDTH{1'b0}};
                            remainder_reg <= {(DIV_WIDTH+1){1'b0}};
                            division_bits_left_reg <= DIV_BITS;
                            calc_state_reg <= DIV_INDEX;
                        end else begin
                            if (!ratio_overflow_reg &&
                                (quotient_next >> 8) == 0 &&
                                quotient_next[7:0] > 8'd2 &&
                                quotient_next[7:0] < 8'd184) begin
                                spo2 <= table_value;
                                if (table_value >= 8'd70 &&
                                    table_value <= 8'd100)
                                    spo2_valid <= 1'b1;
                            end else begin
                                spo2 <= 8'd0;
                            end
                            calc_state_reg <= IDLE;
                        end
                    end
                end else if (calc_state_reg == SETUP_RATIO) begin
                    if (!SCALE_VALID ||
                        red_ac_window == 20'd0 ||
                        ir_ac_window == 20'd0 ||
                        red_dc_window == 18'd0 ||
                        ir_dc_window == 18'd0 ||
                        denominator_product == {PRODUCT_WIDTH{1'b0}}) begin
                        ratio_r <= 32'd0;
                        spo2 <= 8'd0;
                        calc_state_reg <= IDLE;
                    end else begin
                        dividend_reg <= {{(DIV_WIDTH-SCALED_WIDTH){1'b0}},
                                         scaled_product};
                        divisor_reg <= {{(DIV_WIDTH-PRODUCT_WIDTH){1'b0}},
                                        denominator_product};
                        quotient_reg <= {DIV_WIDTH{1'b0}};
                        remainder_reg <= {(DIV_WIDTH+1){1'b0}};
                        division_bits_left_reg <= DIV_BITS;
                        calc_state_reg <= DIV_RATIO;
                    end
                end
            end
        end
    end
endmodule

`resetall
