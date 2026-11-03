// -----------------------------------------------------------------------------
// File   : awb.v
// Author : XiaoQingquan, OpenAI Codex
// Date   : 2026-09-20
// -----------------------------------------------------------------------------
// Description:
//   Low-area frame-based gray-world automatic white balance for four RGB888
//   pixels per clock. One iterative divider is shared by the red and blue gain
//   calculations; gains are committed only at a frame boundary.
// -----------------------------------------------------------------------------
// Change Log:
//   2024-10-01  XiaoQingquan  v1.0  Original streaming AWB implementation
//   2026-09-20  OpenAI Codex  v2.0  Replace two pipelined dividers and BRAM delay
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module awb #
(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
)
(
    input  wire         I_clk,
    input  wire         I_rst_n,

    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    output wire         I_tready,

    output wire         O_tlast,
    output wire         O_tuser,
    output wire [95:0]  O_tdata,
    output wire         O_tvalid
);

    localparam [19:0] UNITY_GAIN = 20'h1_0000;
    localparam [15:0] LAST_LINE  = IMG_HEIGHT - 1;

    // Binary encoding minimizes state registers for this slow control path.
    localparam [1:0]
        DIV_STATE_IDLE = 2'd0,
        DIV_STATE_RED  = 2'd1,
        DIV_STATE_BLUE = 2'd2;

    wire rst;

    wire [7:0] red_lane_zero;
    wire [7:0] green_lane_zero;
    wire [7:0] blue_lane_zero;
    wire [7:0] red_lane_one;
    wire [7:0] green_lane_one;
    wire [7:0] blue_lane_one;
    wire [7:0] red_lane_two;
    wire [7:0] green_lane_two;
    wire [7:0] blue_lane_two;
    wire [7:0] red_lane_three;
    wire [7:0] green_lane_three;
    wire [7:0] blue_lane_three;

    wire [8:0] red_pair_low;
    wire [8:0] red_pair_high;
    wire [8:0] green_pair_low;
    wire [8:0] green_pair_high;
    wire [8:0] blue_pair_low;
    wire [8:0] blue_pair_high;
    wire [9:0] red_lane_sum;
    wire [9:0] green_lane_sum;
    wire [9:0] blue_lane_sum;

    reg [31:0] red_sum_reg = 32'd0;
    reg [31:0] green_sum_reg = 32'd0;
    reg [31:0] blue_sum_reg = 32'd0;
    reg [15:0] line_count_reg = 16'd0;

    wire [32:0] red_sum_with_beat;
    wire [32:0] green_sum_with_beat;
    wire [32:0] blue_sum_with_beat;
    wire frame_end;

    reg [1:0]  divide_state_reg = DIV_STATE_IDLE;
    reg [5:0]  divide_count_reg = 6'd0;
    reg [31:0] divide_denominator_reg = 32'd0;
    reg [47:0] divide_dividend_reg = 48'd0;
    reg [32:0] divide_remainder_reg = 33'd0;
    reg [47:0] divide_quotient_reg = 48'd0;
    reg [31:0] saved_green_sum_reg = 32'd0;
    reg [31:0] saved_blue_sum_reg = 32'd0;

    wire [32:0] divide_remainder_shift;
    wire        divide_subtract;
    wire [32:0] divide_remainder_step;
    wire [47:0] divide_dividend_step;
    wire [47:0] divide_quotient_step;
    wire [19:0] divide_gain_clamped;

    reg [19:0] red_gain_reg = UNITY_GAIN;
    reg [19:0] blue_gain_reg = UNITY_GAIN;
    reg [19:0] pending_red_gain_reg = UNITY_GAIN;
    reg [19:0] pending_blue_gain_reg = UNITY_GAIN;
    reg        pending_gain_valid_reg = 1'b0;

    wire [19:0] red_gain_for_pixel;
    wire [19:0] blue_gain_for_pixel;

    reg [27:0] red_product_zero_reg = 28'd0;
    reg [27:0] blue_product_zero_reg = 28'd0;
    reg [27:0] red_product_one_reg = 28'd0;
    reg [27:0] blue_product_one_reg = 28'd0;
    reg [27:0] red_product_two_reg = 28'd0;
    reg [27:0] blue_product_two_reg = 28'd0;
    reg [27:0] red_product_three_reg = 28'd0;
    reg [27:0] blue_product_three_reg = 28'd0;
    reg [7:0]  green_zero_reg = 8'd0;
    reg [7:0]  green_one_reg = 8'd0;
    reg [7:0]  green_two_reg = 8'd0;
    reg [7:0]  green_three_reg = 8'd0;
    reg        output_valid_reg = 1'b0;
    reg        output_user_reg = 1'b0;
    reg        output_last_reg = 1'b0;

    wire [7:0] red_zero_clamped;
    wire [7:0] blue_zero_clamped;
    wire [7:0] red_one_clamped;
    wire [7:0] blue_one_clamped;
    wire [7:0] red_two_clamped;
    wire [7:0] blue_two_clamped;
    wire [7:0] red_three_clamped;
    wire [7:0] blue_three_clamped;

    assign rst = ~I_rst_n;

    assign red_lane_zero     = I_tdata[23:16];
    assign green_lane_zero   = I_tdata[15:8];
    assign blue_lane_zero    = I_tdata[7:0];
    assign red_lane_one      = I_tdata[47:40];
    assign green_lane_one    = I_tdata[39:32];
    assign blue_lane_one     = I_tdata[31:24];
    assign red_lane_two      = I_tdata[71:64];
    assign green_lane_two    = I_tdata[63:56];
    assign blue_lane_two     = I_tdata[55:48];
    assign red_lane_three    = I_tdata[95:88];
    assign green_lane_three  = I_tdata[87:80];
    assign blue_lane_three   = I_tdata[79:72];

    assign red_pair_low    = {1'b0, red_lane_zero} + {1'b0, red_lane_one};
    assign red_pair_high   = {1'b0, red_lane_two} + {1'b0, red_lane_three};
    assign green_pair_low  = {1'b0, green_lane_zero} + {1'b0, green_lane_one};
    assign green_pair_high = {1'b0, green_lane_two} + {1'b0, green_lane_three};
    assign blue_pair_low   = {1'b0, blue_lane_zero} + {1'b0, blue_lane_one};
    assign blue_pair_high  = {1'b0, blue_lane_two} + {1'b0, blue_lane_three};

    assign red_lane_sum   = {1'b0, red_pair_low} + {1'b0, red_pair_high};
    assign green_lane_sum = {1'b0, green_pair_low} + {1'b0, green_pair_high};
    assign blue_lane_sum  = {1'b0, blue_pair_low} + {1'b0, blue_pair_high};

    assign red_sum_with_beat =
        {1'b0, red_sum_reg} + {23'd0, red_lane_sum};
    assign green_sum_with_beat =
        {1'b0, green_sum_reg} + {23'd0, green_lane_sum};
    assign blue_sum_with_beat =
        {1'b0, blue_sum_reg} + {23'd0, blue_lane_sum};
    assign frame_end = I_tvalid && I_tlast && (line_count_reg == LAST_LINE);

    // Frame statistics. All four pixels contribute to one sum per color.
    always @(posedge I_clk) begin
        if (I_tvalid) begin
            if (I_tuser) begin
                red_sum_reg    <= {22'd0, red_lane_sum};
                green_sum_reg  <= {22'd0, green_lane_sum};
                blue_sum_reg   <= {22'd0, blue_lane_sum};
                line_count_reg <= 16'd0;
            end else begin
                red_sum_reg   <= red_sum_with_beat[31:0];
                green_sum_reg <= green_sum_with_beat[31:0];
                blue_sum_reg  <= blue_sum_with_beat[31:0];
                if (I_tlast && (line_count_reg != LAST_LINE)) begin
                    line_count_reg <= line_count_reg + 16'd1;
                end
            end
        end

        if (rst) begin
            red_sum_reg    <= 32'd0;
            green_sum_reg  <= 32'd0;
            blue_sum_reg   <= 32'd0;
            line_count_reg <= 16'd0;
        end
    end

    // One-bit-per-cycle unsigned restoring divider.
    assign divide_remainder_shift =
        {divide_remainder_reg[31:0], divide_dividend_reg[47]};
    assign divide_subtract =
        divide_remainder_shift >= {1'b0, divide_denominator_reg};
    assign divide_remainder_step = divide_subtract
        ? divide_remainder_shift - {1'b0, divide_denominator_reg}
        : divide_remainder_shift;
    assign divide_dividend_step = {divide_dividend_reg[46:0], 1'b0};
    assign divide_quotient_step = {divide_quotient_reg[46:0], divide_subtract};
    assign divide_gain_clamped = (|divide_quotient_step[47:20])
        ? 20'hf_ffff : divide_quotient_step[19:0];

    // Calculate G/R and G/B after the last line, sharing a single divider.
    always @(posedge I_clk) begin
        if (I_tuser && I_tvalid && pending_gain_valid_reg) begin
            red_gain_reg           <= pending_red_gain_reg;
            blue_gain_reg          <= pending_blue_gain_reg;
            pending_gain_valid_reg <= 1'b0;
        end

        case (divide_state_reg)
            DIV_STATE_IDLE: begin
                if (frame_end) begin
                    saved_green_sum_reg <= green_sum_with_beat[31:0];
                    saved_blue_sum_reg  <= blue_sum_with_beat[31:0];

                    if (green_sum_with_beat[31:0] == 32'd0) begin
                        pending_red_gain_reg   <= UNITY_GAIN;
                        pending_blue_gain_reg  <= UNITY_GAIN;
                        pending_gain_valid_reg <= 1'b1;
                    end else if (red_sum_with_beat[31:0] == 32'd0) begin
                        pending_red_gain_reg <= UNITY_GAIN;
                        if (blue_sum_with_beat[31:0] == 32'd0) begin
                            pending_blue_gain_reg  <= UNITY_GAIN;
                            pending_gain_valid_reg <= 1'b1;
                        end else begin
                            divide_denominator_reg <= blue_sum_with_beat[31:0];
                            divide_dividend_reg <= {green_sum_with_beat[31:0], 16'd0};
                            divide_remainder_reg <= 33'd0;
                            divide_quotient_reg <= 48'd0;
                            divide_count_reg <= 6'd0;
                            divide_state_reg <= DIV_STATE_BLUE;
                        end
                    end else begin
                        divide_denominator_reg <= red_sum_with_beat[31:0];
                        divide_dividend_reg <= {green_sum_with_beat[31:0], 16'd0};
                        divide_remainder_reg <= 33'd0;
                        divide_quotient_reg <= 48'd0;
                        divide_count_reg <= 6'd0;
                        divide_state_reg <= DIV_STATE_RED;
                    end
                end
            end

            DIV_STATE_RED: begin
                divide_dividend_reg  <= divide_dividend_step;
                divide_remainder_reg <= divide_remainder_step;
                divide_quotient_reg  <= divide_quotient_step;
                divide_count_reg     <= divide_count_reg + 6'd1;

                if (divide_count_reg == 6'd47) begin
                    pending_red_gain_reg <= divide_gain_clamped;
                    if (saved_blue_sum_reg == 32'd0) begin
                        pending_blue_gain_reg  <= UNITY_GAIN;
                        pending_gain_valid_reg <= 1'b1;
                        divide_state_reg       <= DIV_STATE_IDLE;
                    end else begin
                        divide_denominator_reg <= saved_blue_sum_reg;
                        divide_dividend_reg    <= {saved_green_sum_reg, 16'd0};
                        divide_remainder_reg   <= 33'd0;
                        divide_quotient_reg    <= 48'd0;
                        divide_count_reg       <= 6'd0;
                        divide_state_reg       <= DIV_STATE_BLUE;
                    end
                end
            end

            DIV_STATE_BLUE: begin
                divide_dividend_reg  <= divide_dividend_step;
                divide_remainder_reg <= divide_remainder_step;
                divide_quotient_reg  <= divide_quotient_step;
                divide_count_reg     <= divide_count_reg + 6'd1;

                if (divide_count_reg == 6'd47) begin
                    pending_blue_gain_reg  <= divide_gain_clamped;
                    pending_gain_valid_reg <= 1'b1;
                    divide_state_reg       <= DIV_STATE_IDLE;
                end
            end

            default: begin
                divide_state_reg <= DIV_STATE_IDLE;
            end
        endcase

        if (rst) begin
            divide_state_reg       <= DIV_STATE_IDLE;
            divide_count_reg       <= 6'd0;
            divide_denominator_reg <= 32'd0;
            divide_dividend_reg    <= 48'd0;
            divide_remainder_reg   <= 33'd0;
            divide_quotient_reg    <= 48'd0;
            saved_green_sum_reg    <= 32'd0;
            saved_blue_sum_reg     <= 32'd0;
            red_gain_reg           <= UNITY_GAIN;
            blue_gain_reg          <= UNITY_GAIN;
            pending_red_gain_reg   <= UNITY_GAIN;
            pending_blue_gain_reg  <= UNITY_GAIN;
            pending_gain_valid_reg <= 1'b0;
        end
    end

    assign red_gain_for_pixel = (I_tuser && pending_gain_valid_reg)
        ? pending_red_gain_reg : red_gain_reg;
    assign blue_gain_for_pixel = (I_tuser && pending_gain_valid_reg)
        ? pending_blue_gain_reg : blue_gain_reg;

    // Eight DSP multiplies preserve the four-pixel-per-clock throughput.
    always @(posedge I_clk) begin
        output_valid_reg <= I_tvalid;
        output_user_reg  <= I_tuser && I_tvalid;
        output_last_reg  <= I_tlast && I_tvalid;

        if (I_tvalid) begin
            red_product_zero_reg   <= red_gain_for_pixel * red_lane_zero;
            blue_product_zero_reg  <= blue_gain_for_pixel * blue_lane_zero;
            red_product_one_reg    <= red_gain_for_pixel * red_lane_one;
            blue_product_one_reg   <= blue_gain_for_pixel * blue_lane_one;
            red_product_two_reg    <= red_gain_for_pixel * red_lane_two;
            blue_product_two_reg   <= blue_gain_for_pixel * blue_lane_two;
            red_product_three_reg  <= red_gain_for_pixel * red_lane_three;
            blue_product_three_reg <= blue_gain_for_pixel * blue_lane_three;
            green_zero_reg         <= green_lane_zero;
            green_one_reg          <= green_lane_one;
            green_two_reg          <= green_lane_two;
            green_three_reg        <= green_lane_three;
        end

        if (rst) begin
            output_valid_reg <= 1'b0;
            output_user_reg  <= 1'b0;
            output_last_reg  <= 1'b0;
        end
    end

    assign red_zero_clamped = (|red_product_zero_reg[27:24])
        ? 8'hff : red_product_zero_reg[23:16];
    assign blue_zero_clamped = (|blue_product_zero_reg[27:24])
        ? 8'hff : blue_product_zero_reg[23:16];
    assign red_one_clamped = (|red_product_one_reg[27:24])
        ? 8'hff : red_product_one_reg[23:16];
    assign blue_one_clamped = (|blue_product_one_reg[27:24])
        ? 8'hff : blue_product_one_reg[23:16];
    assign red_two_clamped = (|red_product_two_reg[27:24])
        ? 8'hff : red_product_two_reg[23:16];
    assign blue_two_clamped = (|blue_product_two_reg[27:24])
        ? 8'hff : blue_product_two_reg[23:16];
    assign red_three_clamped = (|red_product_three_reg[27:24])
        ? 8'hff : red_product_three_reg[23:16];
    assign blue_three_clamped = (|blue_product_three_reg[27:24])
        ? 8'hff : blue_product_three_reg[23:16];

    assign I_tready = 1'b1;
    assign O_tlast  = output_last_reg;
    assign O_tuser  = output_user_reg;
    assign O_tvalid = output_valid_reg;
    assign O_tdata  = {
        red_three_clamped, green_three_reg, blue_three_clamped,
        red_two_clamped,   green_two_reg,   blue_two_clamped,
        red_one_clamped,   green_one_reg,   blue_one_clamped,
        red_zero_clamped,  green_zero_reg,  blue_zero_clamped
    };

endmodule

`resetall
