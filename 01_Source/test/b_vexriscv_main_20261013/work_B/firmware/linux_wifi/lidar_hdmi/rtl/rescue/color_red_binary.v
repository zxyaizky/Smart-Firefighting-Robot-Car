`resetall
`timescale 1ns/1ps
`default_nettype none

// Division-free HSV thresholds. H uses degrees 0..359; S/V use 0..255.
// Red hue wraps through zero: [340,360) or [0,20); green is inclusive.
// Compare H_num / delta and 255*delta / max by cross multiplication.
// Three register stages: sample at E0, output after E2, one sample per clock.
// Metadata advances even on invalid cycles so SOF/EOF/abort/VS stay aligned.
module color_hsv_pixel #(
    parameter [8:0] RED_H_MIN = 9'd340,
    parameter [8:0] RED_H_MAX = 9'd20,
    parameter [7:0] RED_S_MIN = 8'd100,
    parameter [7:0] RED_V_MIN = 8'd50,
    parameter [8:0] GREEN_H_MIN = 9'd85,
    parameter [8:0] GREEN_H_MAX = 9'd125,
    parameter [7:0] GREEN_S_MIN = 8'd55,
    parameter [7:0] GREEN_S_MAX = 8'd255,
    parameter [7:0] GREEN_V_MIN = 8'd70,
    parameter [7:0] GREEN_V_MAX = 8'd255,
    parameter integer META_WIDTH = 1,
    parameter integer DYNAMIC_GREEN_S = 0,
    parameter integer DYNAMIC_GREEN_V = 0
) (
    input wire clk, rst,
    input wire [23:0] rgb_i,
    input wire valid_i,
    input wire [7:0] green_s_min_i, green_s_max_i,
    input wire [7:0] green_v_min_i, green_v_max_i,
    input wire [META_WIDTH-1:0] metadata_i,
    output reg green_o, red_o, valid_o,
    output reg [META_WIDTH-1:0] metadata_o
);
    wire [7:0] r = rgb_i[23:16], g = rgb_i[15:8], b = rgb_i[7:0];
    wire [7:0] max_rg = r >= g ? r : g;
    wire [7:0] min_rg = r <= g ? r : g;
    wire [7:0] maximum = max_rg >= b ? max_rg : b;
    wire [7:0] minimum = min_rg <= b ? min_rg : b;
    wire r_max = r == maximum;
    wire g_max = !r_max && g == maximum;
    wire [7:0] channel_a = r_max ? g : g_max ? b : r;
    wire [7:0] channel_b = r_max ? b : g_max ? r : g;
    reg [7:0] max0, delta0, difference0;
    reg [1:0] sector0;
    reg subtract0, valid0, valid1;
    reg [META_WIDTH-1:0] meta0, meta1;
    reg [7:0] gs_min0, gs_max0;
    reg [7:0] gv_min0, gv_max0;
    reg [15:0] saturation1, rs_min1, gs_min1, gs_max1;
    reg r_value1, g_value1, chromatic1;
    wire [15:0] delta_wide = {8'd0, delta0};
    wire red_hue, green_hue;
    generate if (RED_H_MIN == 340 && RED_H_MAX == 20 &&
                 GREEN_H_MIN == 85 && GREEN_H_MAX == 125) begin : g_fixed_hue
        // Exact algebra for the configured hue intervals, with no division,
        // 17-bit angle construction or angle*delta threshold multipliers.
        // R sector: H=60*diff/delta; G sector: H=120 +/- 60*diff/delta.
        // Red wrap [340,20): R-sector positive side uses <, negative side <=.
        // Green [85,125]: 12*diff <= 7*delta (G negative), <= delta (G positive).
        wire [9:0] diff_w = {2'd0,difference0};
        wire [11:0] diff_wide = {4'd0,difference0};
        wire [11:0] delta_w = {4'd0,delta0};
        wire [9:0] diff3 = (diff_w << 1) + diff_w;
        wire [11:0] diff12 = (diff_wide << 3) + (diff_wide << 2);
        wire [11:0] delta7 = (delta_w << 3) - delta_w;
        reg red1, green1;
        assign red_hue = red1;
        assign green_hue = green1;
        always @(posedge clk) begin
            red1 <= sector0 == 0 && (subtract0 ?
                    diff3 <= {2'd0, delta0} : diff3 < {2'd0, delta0});
            green1 <= sector0 == 1 && (subtract0 ? diff12 <= delta7 : diff12 <= delta_w);
            if (rst) begin red1 <= 0; green1 <= 0; end
        end
    end else begin : g_general_hue
        // Preserve arbitrary hue parameters, including wrap through 0 degrees.
        reg [16:0] hue1, rh_min1, rh_max1, gh_min1, gh_max1;
        wire [16:0] d = {9'd0, delta0};
        wire [16:0] diff = {9'd0, difference0};
        wire [16:0] step60 = (diff << 6) - (diff << 2);
        wire [16:0] base120 = (d << 7) - (d << 3);
        wire [16:0] base240 = (d << 8) - (d << 4);
        wire [16:0] base360 = (d << 8) + (d << 6) + (d << 5) + (d << 3);
        wire [16:0] base = sector0 == 0 ? (subtract0 ? base360 : 17'd0) :
                           sector0 == 1 ? base120 : base240;
        wire [16:0] hue_next = subtract0 ? base - step60 : base + step60;
        assign red_hue = RED_H_MIN <= RED_H_MAX ?
            (hue1 >= rh_min1 && hue1 < rh_max1) : (hue1 >= rh_min1 || hue1 < rh_max1);
        assign green_hue = GREEN_H_MIN <= GREEN_H_MAX ?
            (hue1 >= gh_min1 && hue1 <= gh_max1) : (hue1 >= gh_min1 || hue1 <= gh_max1);
        always @(posedge clk) begin
            hue1 <= hue_next;
            rh_min1 <= RED_H_MIN * delta0;
            rh_max1 <= RED_H_MAX * delta0;
            gh_min1 <= GREEN_H_MIN * delta0;
            gh_max1 <= GREEN_H_MAX * delta0;
            if (rst) begin
                hue1 <= 0; rh_min1 <= 0; rh_max1 <= 0; gh_min1 <= 0; gh_max1 <= 0;
            end
        end
    end endgenerate
    // For real RGB pixels delta <= maximum, hence S=255*delta/maximum
    // cannot exceed 255. Dynamic or narrower upper limits keep the comparison.
    wire green_s_upper_ok = DYNAMIC_GREEN_S == 0 && GREEN_S_MAX == 255 ?
                            1'b1 : saturation1 <= gs_max1;
    always @(posedge clk) begin
        max0 <= maximum;
        delta0 <= maximum - minimum;
        difference0 <= channel_a >= channel_b ? channel_a - channel_b : channel_b - channel_a;
        sector0 <= r_max ? 2'd0 : g_max ? 2'd1 : 2'd2;
        subtract0 <= channel_a < channel_b;
        valid0 <= valid_i;
        meta0 <= metadata_i;
        gs_min0 <= green_s_min_i;
        gs_max0 <= green_s_max_i;
        gv_min0 <= green_v_min_i;
        gv_max0 <= green_v_max_i;
        saturation1 <= (delta_wide << 8) - delta_wide;
        rs_min1 <= RED_S_MIN * max0;
        gs_min1 <= (DYNAMIC_GREEN_S != 0 ? gs_min0 : GREEN_S_MIN) * max0;
        gs_max1 <= (DYNAMIC_GREEN_S != 0 ? gs_max0 : GREEN_S_MAX) * max0;
        r_value1 <= max0 >= RED_V_MIN;
        g_value1 <= max0 >= (DYNAMIC_GREEN_V != 0 ? gv_min0 : GREEN_V_MIN) &&
                    max0 <= (DYNAMIC_GREEN_V != 0 ? gv_max0 : GREEN_V_MAX);
        chromatic1 <= delta0 != 0;
        valid1 <= valid0;
        meta1 <= meta0;
        red_o <= valid1 && chromatic1 && r_value1 && red_hue && saturation1 >= rs_min1;
        green_o <= valid1 && chromatic1 && g_value1 && green_hue &&
                   saturation1 >= gs_min1 && green_s_upper_ok;
        valid_o <= valid1;
        metadata_o <= meta1;
        if (rst) begin
            max0 <= 0; delta0 <= 0; difference0 <= 0; sector0 <= 0; subtract0 <= 0;
            valid0 <= 0; valid1 <= 0; meta0 <= 0; meta1 <= 0;
            gs_min0 <= 0; gs_max0 <= 0;
            gv_min0 <= 0; gv_max0 <= 0;
            saturation1 <= 0; rs_min1 <= 0; gs_min1 <= 0; gs_max1 <= 0;
            r_value1 <= 0; g_value1 <= 0; chromatic1 <= 0;
            red_o <= 0; green_o <= 0; valid_o <= 0; metadata_o <= 0;
        end
    end
endmodule

// BINARY_COLOR=1
// displays green (default); 2 displays red. Output remains white/black.
// The full active raster is shown. Optional binary majority + opening remove
// speckle; the recognition branch now applies the same three filter passes.
module red_binary_video #(
    parameter [10:0] IMG_HDISP = 11'd1280,
    parameter integer DENOISE_ENABLE = 1,
    parameter integer OPENING_ENABLE = 1,
    parameter integer BINARY_COLOR = 1,
    parameter integer DYNAMIC_GREEN_S = 0,
    parameter integer DYNAMIC_GREEN_V = 0,
    parameter [8:0] RED_H_MIN = 9'd340,
    parameter [8:0] RED_H_MAX = 9'd20,
    parameter [7:0] RED_S_MIN = 8'd100,
    parameter [7:0] RED_V_MIN = 8'd50,
    parameter [8:0] GREEN_H_MIN = 9'd85,
    parameter [8:0] GREEN_H_MAX = 9'd125,
    parameter [7:0] GREEN_S_MIN = 8'd55,
    parameter [7:0] GREEN_S_MAX = 8'd255,
    parameter [7:0] GREEN_V_MIN = 8'd70,
    parameter [7:0] GREEN_V_MAX = 8'd255
) (
    input wire clk, rst,
    input wire [23:0] rgb_i,
    input wire de_i, vsync_i,
    input wire [7:0] green_s_min_i, green_s_max_i,
    input wire [7:0] green_v_min_i, green_v_max_i,
    output wire [23:0] rgb_o,
    output wire de_o, vsync_o
);
    wire red, green, hsv_valid, hsv_vs;
    wire selected_mask = BINARY_COLOR == 1 ? green : red;
    reg raw_mask, raw_de, raw_vs;
    color_hsv_pixel #(
        .DYNAMIC_GREEN_S(DYNAMIC_GREEN_S),
        .DYNAMIC_GREEN_V(DYNAMIC_GREEN_V),
        .RED_H_MIN(RED_H_MIN), .RED_H_MAX(RED_H_MAX),
        .RED_S_MIN(RED_S_MIN), .RED_V_MIN(RED_V_MIN),
        .GREEN_H_MIN(GREEN_H_MIN), .GREEN_H_MAX(GREEN_H_MAX),
        .GREEN_S_MIN(GREEN_S_MIN), .GREEN_S_MAX(GREEN_S_MAX),
        .GREEN_V_MIN(GREEN_V_MIN), .GREEN_V_MAX(GREEN_V_MAX)
    ) u_threshold (.clk(clk), .rst(rst), .rgb_i(rgb_i), .valid_i(de_i),
        .green_s_min_i(green_s_min_i), .green_s_max_i(green_s_max_i),
        .green_v_min_i(green_v_min_i), .green_v_max_i(green_v_max_i),
        .metadata_i(vsync_i), .red_o(red), .green_o(green),
        .valid_o(hsv_valid), .metadata_o(hsv_vs));
    always @(posedge clk) begin
        raw_mask <= hsv_valid && selected_mask;
        raw_de <= hsv_valid;
        raw_vs <= hsv_vs;
        if (rst) begin
            raw_mask <= 0; raw_de <= 0; raw_vs <= 0;
        end
    end
    generate if (DENOISE_ENABLE != 0) begin : g_denoise
        wire median_mask, median_de, median_vs;
        binary_filter3x3 #(.IMG_HDISP(IMG_HDISP), .MODE(0)) u_majority (
            .clk(clk), .rst(rst), .pixel_i(raw_mask), .de_i(raw_de), .vsync_i(raw_vs),
            .pixel_o(median_mask), .de_o(median_de), .vsync_o(median_vs));
        if (OPENING_ENABLE != 0) begin : g_opening
            wire eroded_mask, eroded_de, eroded_vs, opened_mask;
            binary_filter3x3 #(.IMG_HDISP(IMG_HDISP), .MODE(1)) u_erosion (
                .clk(clk), .rst(rst), .pixel_i(median_mask), .de_i(median_de), .vsync_i(median_vs),
                .pixel_o(eroded_mask), .de_o(eroded_de), .vsync_o(eroded_vs));
            binary_filter3x3 #(.IMG_HDISP(IMG_HDISP), .MODE(2)) u_dilation (
                .clk(clk), .rst(rst), .pixel_i(eroded_mask), .de_i(eroded_de), .vsync_i(eroded_vs),
                .pixel_o(opened_mask), .de_o(de_o), .vsync_o(vsync_o));
            assign rgb_o = {24{de_o && opened_mask}};
        end else begin : g_majority_only
            assign rgb_o = {24{median_de && median_mask}};
            assign de_o = median_de;
            assign vsync_o = median_vs;
        end
    end else begin : g_raw
        assign rgb_o = {24{raw_de && raw_mask}};
        assign de_o = raw_de;
        assign vsync_o = raw_vs;
    end endgenerate
endmodule
`resetall
