// Resource-optimized automatic white balance.
//
// The original implementation ran two wide, fully-pipelined dividers on every
// valid pixel beat and delayed the video in ten ERAM blocks. White-balance
// gains only need to change once per frame, so this version accumulates one
// sample per four-pixel beat, calculates R/B gains once per frame with one
// shared serial divider, and applies the completed gains at the next frame
// boundary. The pixel path remains four pixels per clock.
module awb #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
) (
    input                   I_clk,
    input                   I_rst_n,

    input                   I_tlast,
    input                   I_tuser,
    input      [95:0]       I_tdata,
    input                   I_tvalid,
    output                  I_tready,

    output                  O_tlast,
    output                  O_tuser,
    output     [95:0]       O_tdata,
    output                  O_tvalid,
    input                   O_tready
);

    localparam [2:0] DIV_IDLE    = 3'd0;
    localparam [2:0] DIV_START_R = 3'd1;
    localparam [2:0] DIV_WAIT_R  = 3'd2;
    localparam [2:0] DIV_START_B = 3'd3;
    localparam [2:0] DIV_WAIT_B  = 3'd4;

    // One-entry output stage. This keeps the stream stable if backpressure is
    // ever enabled, while still accepting one four-pixel beat every clock.
    reg         out_valid;
    reg         out_tuser;
    reg         out_tlast;
    reg  [27:0] r_product_0;
    reg  [27:0] b_product_0;
    reg  [27:0] r_product_1;
    reg  [27:0] b_product_1;
    reg  [27:0] r_product_2;
    reg  [27:0] b_product_2;
    reg  [27:0] r_product_3;
    reg  [27:0] b_product_3;
    reg  [7:0]  g_pixel_0;
    reg  [7:0]  g_pixel_1;
    reg  [7:0]  g_pixel_2;
    reg  [7:0]  g_pixel_3;

    assign I_tready = ~out_valid | O_tready;
    wire pixel_fire = I_tvalid & I_tready;
    wire frame_start = pixel_fire & I_tuser;

    // Sample pixel zero from each four-pixel beat. This retains the original
    // sampling density but removes redundant running divider operations.
    wire [7:0] sample_r = I_tdata[23:16];
    wire [7:0] sample_g = I_tdata[15:8];
    wire [7:0] sample_b = I_tdata[7:0];
    wire [9:0] sample_rgb_sum = sample_r + sample_g + sample_b;

    reg [31:0] sum_r;
    reg [31:0] sum_g;
    reg [31:0] sum_b;
    reg        have_frame_samples;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            sum_r              <= 32'd1;
            sum_g              <= 32'd1;
            sum_b              <= 32'd1;
            have_frame_samples <= 1'b0;
        end else if (frame_start) begin
            sum_r <= 32'd1;
            sum_g <= 32'd1;
            sum_b <= 32'd1;
        end else if (pixel_fire && (sample_rgb_sum < 10'd720)) begin
            sum_r <= sum_r + sample_r;
            sum_g <= sum_g + sample_g;
            sum_b <= sum_b + sample_b;
            have_frame_samples <= 1'b1;
        end
    end

    // Active gains are constant for a complete frame. The serial divider
    // computes pending gains from the preceding frame in the background.
    reg [19:0] gain_r_active;
    reg [19:0] gain_b_active;
    reg [19:0] gain_r_pending;
    reg [19:0] gain_b_pending;

    reg [31:0] frame_sum_r;
    reg [31:0] frame_sum_g;
    reg [31:0] frame_sum_b;
    reg [2:0]  div_state;
    reg        div_start;
    reg [47:0] div_numerator;
    reg [31:0] div_denominator;
    wire [47:0] div_quotient;
    wire        div_done;

    function [19:0] clip_gain;
        input [47:0] quotient;
        begin
            if (|quotient[47:20])
                clip_gain = 20'hfffff;
            else
                clip_gain = quotient[19:0];
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            gain_r_active   <= 20'h10000;
            gain_b_active   <= 20'h10000;
            gain_r_pending  <= 20'h10000;
            gain_b_pending  <= 20'h10000;
            frame_sum_r     <= 32'd1;
            frame_sum_g     <= 32'd1;
            frame_sum_b     <= 32'd1;
            div_state       <= DIV_IDLE;
            div_start       <= 1'b0;
            div_numerator   <= 48'd0;
            div_denominator <= 32'd1;
        end else begin
            div_start <= 1'b0;

            // Commit both gains together, so a frame cannot change colour
            // balance part-way through a line.
            if (frame_start) begin
                gain_r_active <= gain_r_pending;
                gain_b_active <= gain_b_pending;
            end

            case (div_state)
                DIV_IDLE: begin
                    if (frame_start && have_frame_samples) begin
                        frame_sum_r <= sum_r;
                        frame_sum_g <= sum_g;
                        frame_sum_b <= sum_b;
                        div_state   <= DIV_START_R;
                    end
                end

                DIV_START_R: begin
                    div_numerator   <= {frame_sum_g, 16'd0};
                    div_denominator <= frame_sum_r;
                    div_start       <= 1'b1;
                    div_state       <= DIV_WAIT_R;
                end

                DIV_WAIT_R: begin
                    if (div_done) begin
                        gain_r_pending <= clip_gain(div_quotient);
                        div_state      <= DIV_START_B;
                    end
                end

                DIV_START_B: begin
                    div_numerator   <= {frame_sum_g, 16'd0};
                    div_denominator <= frame_sum_b;
                    div_start       <= 1'b1;
                    div_state       <= DIV_WAIT_B;
                end

                DIV_WAIT_B: begin
                    if (div_done) begin
                        gain_b_pending <= clip_gain(div_quotient);
                        div_state      <= DIV_IDLE;
                    end
                end

                default: div_state <= DIV_IDLE;
            endcase
        end
    end

    awb_serial_divider u_gain_divider (
        .clk        (I_clk),
        .rst_n      (I_rst_n),
        .start      (div_start),
        .numerator  (div_numerator),
        .denominator(div_denominator),
        .quotient   (div_quotient),
        .done       (div_done)
    );

    // On the first beat of a frame use the pending gains directly; the active
    // registers receive those same values on that clock edge.
    wire [19:0] pixel_gain_r = I_tuser ? gain_r_pending : gain_r_active;
    wire [19:0] pixel_gain_b = I_tuser ? gain_b_pending : gain_b_active;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            out_valid   <= 1'b0;
            out_tuser   <= 1'b0;
            out_tlast   <= 1'b0;
            r_product_0 <= 28'd0;
            b_product_0 <= 28'd0;
            r_product_1 <= 28'd0;
            b_product_1 <= 28'd0;
            r_product_2 <= 28'd0;
            b_product_2 <= 28'd0;
            r_product_3 <= 28'd0;
            b_product_3 <= 28'd0;
            g_pixel_0   <= 8'd0;
            g_pixel_1   <= 8'd0;
            g_pixel_2   <= 8'd0;
            g_pixel_3   <= 8'd0;
        end else if (I_tready) begin
            out_valid <= I_tvalid;
            out_tuser <= I_tvalid & I_tuser;
            out_tlast <= I_tvalid & I_tlast;
            if (I_tvalid) begin
                r_product_0 <= pixel_gain_r * I_tdata[23:16];
                b_product_0 <= pixel_gain_b * I_tdata[7:0];
                g_pixel_0   <= I_tdata[15:8];

                r_product_1 <= pixel_gain_r * I_tdata[47:40];
                b_product_1 <= pixel_gain_b * I_tdata[31:24];
                g_pixel_1   <= I_tdata[39:32];

                r_product_2 <= pixel_gain_r * I_tdata[71:64];
                b_product_2 <= pixel_gain_b * I_tdata[55:48];
                g_pixel_2   <= I_tdata[63:56];

                r_product_3 <= pixel_gain_r * I_tdata[95:88];
                b_product_3 <= pixel_gain_b * I_tdata[79:72];
                g_pixel_3   <= I_tdata[87:80];
            end
        end
    end

    wire [7:0] r_pixel_0 = |r_product_0[27:24] ? 8'hff : r_product_0[23:16];
    wire [7:0] b_pixel_0 = |b_product_0[27:24] ? 8'hff : b_product_0[23:16];
    wire [7:0] r_pixel_1 = |r_product_1[27:24] ? 8'hff : r_product_1[23:16];
    wire [7:0] b_pixel_1 = |b_product_1[27:24] ? 8'hff : b_product_1[23:16];
    wire [7:0] r_pixel_2 = |r_product_2[27:24] ? 8'hff : r_product_2[23:16];
    wire [7:0] b_pixel_2 = |b_product_2[27:24] ? 8'hff : b_product_2[23:16];
    wire [7:0] r_pixel_3 = |r_product_3[27:24] ? 8'hff : r_product_3[23:16];
    wire [7:0] b_pixel_3 = |b_product_3[27:24] ? 8'hff : b_product_3[23:16];

    assign O_tvalid = out_valid;
    assign O_tuser  = out_tuser;
    assign O_tlast  = out_tlast;
    assign O_tdata  = out_valid ? {
        r_pixel_3, g_pixel_3, b_pixel_3,
        r_pixel_2, g_pixel_2, b_pixel_2,
        r_pixel_1, g_pixel_1, b_pixel_1,
        r_pixel_0, g_pixel_0, b_pixel_0
    } : 96'd0;

    // Parameters remain part of the interface for compatibility with the
    // existing project, although frame boundaries now define accumulation.
    wire _unused_parameters = (IMG_HEIGHT == 0) | (IMG_WIDTH == 0);

endmodule


// Small iterative unsigned divider used only twice per frame. It produces the
// same fixed-point expression as the former IP: (channel_sum << 16) / sum.
module awb_serial_divider (
    input             clk,
    input             rst_n,
    input             start,
    input      [47:0] numerator,
    input      [31:0] denominator,
    output reg [47:0] quotient,
    output reg        done
);

    reg        busy;
    reg [5:0]  bit_count;
    reg [47:0] dividend_shift;
    reg [32:0] remainder;
    reg [31:0] denominator_reg;
    wire [32:0] shifted_remainder = {remainder[31:0], dividend_shift[47]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quotient        <= 48'd0;
            done            <= 1'b0;
            busy            <= 1'b0;
            bit_count       <= 6'd0;
            dividend_shift  <= 48'd0;
            remainder       <= 33'd0;
            denominator_reg <= 32'd1;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                if (denominator == 0) begin
                    quotient <= {48{1'b1}};
                    done     <= 1'b1;
                end else begin
                    quotient        <= 48'd0;
                    busy            <= 1'b1;
                    bit_count       <= 6'd48;
                    dividend_shift  <= numerator;
                    remainder       <= 33'd0;
                    denominator_reg <= denominator;
                end
            end else if (busy) begin
                dividend_shift <= {dividend_shift[46:0], 1'b0};
                if (shifted_remainder >= {1'b0, denominator_reg}) begin
                    remainder <= shifted_remainder - {1'b0, denominator_reg};
                    quotient  <= {quotient[46:0], 1'b1};
                end else begin
                    remainder <= shifted_remainder;
                    quotient  <= {quotient[46:0], 1'b0};
                end

                bit_count <= bit_count - 1'b1;
                if (bit_count == 6'd1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
