// -----------------------------------------------------------------------------
// Final-stage Anlogic logo and algorithm-status overlay.
// 2026-10-12: algorithm text has a transparent background; original glyph scale.
//
// This block sits after mode_select, so the logo RGB data never passes through
// grayscale, median, Sobel, cartoon or frame-difference processing.
// -----------------------------------------------------------------------------
module video_logo_overlay #(
    parameter integer IMG_WIDTH  = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer LOGO_X     = 0,
    parameter integer LOGO_Y     = 0,
    parameter integer LOGO_W     = 160,
    parameter integer LOGO_H     = 160
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_vsync,
    input  wire        I_de,
    input  wire [23:0] I_rgb,
    input  wire [2:0]  I_algorithm_mode,
    input  wire        I_ae_enable,
    input  wire [11:0] I_heart_rate_bcd,
    input  wire        I_heart_rate_display_valid,
    input  wire [11:0] I_spo2_bcd,
    input  wire        I_spo2_display_valid,

    output reg         O_vsync,
    output reg         O_de,
    output reg  [23:0] O_rgb
);

    reg  [11:0] S_x;
    reg  [11:0] S_y;
    reg         S_de_d;
    reg         S_ae_enable_meta;
    reg         S_ae_enable_sync;
    reg         S_ae_enable_show;
    wire        S_logo_window;
    wire        S_logo_content_window;
    wire [13:0] S_logo_addr;
    wire [9:0]  S_logo_index;
    wire [24:0] S_logo_pixel;

    wire        S_status_overlay_enable;
    wire [23:0] S_status_overlay_rgb;
    reg         S_status_overlay_enable_d;
    reg  [23:0] S_status_overlay_rgb_d;

    reg         S_vsync_d;
    reg  [23:0] S_rgb_d;
    reg         S_logo_window_d;
    reg         S_alg_panel_d;
    reg         S_alg_on_d;
    reg  [23:0] S_alg_color_d;

    reg         S_alg_panel;
    reg         S_alg_on;
    reg  [23:0] S_alg_color;
    reg  [7:0]  S_alg_local_x;
    reg  [5:0]  S_alg_local_y;
    reg  [3:0]  S_alg_char_idx;
    reg  [4:0]  S_alg_char_x;
    reg  [2:0]  S_alg_col;
    reg  [2:0]  S_alg_row;
    reg  [4:0]  S_alg_char_code;
    reg  [4:0]  S_alg_bits;

    localparam integer ALG_X = 1080;
    localparam integer ALG_Y = 24;
    localparam integer ALG_W = 180;
    localparam integer ALG_H = 31;

    // Non-transparent logo data occupies this 146x94 bounding box.  Cropping
    // the empty border reduces the synchronous ROM depth from 25,600 words to
    // 13,724 words.
    localparam integer LOGO_DATA_X_MIN = 7;
    localparam integer LOGO_DATA_X_MAX = 152;
    localparam integer LOGO_DATA_Y_MIN = 34;
    localparam integer LOGO_DATA_Y_MAX = 127;
    localparam integer LOGO_DATA_W     = 146;

    // Results are drawn after every image effect, below the mode panel.
    max30102_status_osd #(
        .H_ACTIVE  (IMG_WIDTH),
        .V_ACTIVE  (IMG_HEIGHT),
        .PANEL_TOP (80)
    ) u_max30102_status_osd (
        .video_de                 (I_de),
        .pixel_x                  (S_x),
        .pixel_y                  (S_y),
        .heart_rate_bcd           (I_heart_rate_bcd),
        .heart_rate_display_valid (I_heart_rate_display_valid),
        .spo2_bcd                 (I_spo2_bcd),
        .spo2_display_valid       (I_spo2_display_valid),
        .overlay_enable           (S_status_overlay_enable),
        .overlay_rgb              (S_status_overlay_rgb)
    );

    function [4:0] F_algorithm_char_bits;
        input [4:0] I_char;
        input [2:0] I_row;
        reg [34:0] S_glyph;
        begin
            case(I_char)
                5'd0:  S_glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // A
                5'd1:  S_glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110}; // B
                5'd2:  S_glyph={5'b01110,5'b10001,5'b10000,5'b10000,5'b10000,5'b10001,5'b01110}; // C
                5'd3:  S_glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111}; // E
                5'd4:  S_glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000}; // F
                5'd5:  S_glyph={5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110}; // G
                5'd6:  S_glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111}; // L
                5'd7:  S_glyph={5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001}; // N
                5'd8:  S_glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110}; // O
                5'd9:  S_glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001}; // R
                5'd10: S_glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110}; // S
                5'd11: S_glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100}; // T
                5'd12: S_glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100}; // Y
                5'd13: S_glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110}; // D
                5'd14: S_glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111}; // I
                5'd15: S_glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001}; // M
                default:S_glyph=35'd0;
            endcase
            F_algorithm_char_bits = S_glyph >> ((3'd6-I_row)*5);
        end
    endfunction

    assign S_logo_window = I_de &&
                           (S_x >= LOGO_X) && (S_x < (LOGO_X + LOGO_W)) &&
                           (S_y >= LOGO_Y) && (S_y < (LOGO_Y + LOGO_H));

    assign S_logo_content_window = S_logo_window &&
                                   (S_x >= (LOGO_X + LOGO_DATA_X_MIN)) &&
                                   (S_x <= (LOGO_X + LOGO_DATA_X_MAX)) &&
                                   (S_y >= (LOGO_Y + LOGO_DATA_Y_MIN)) &&
                                   (S_y <= (LOGO_Y + LOGO_DATA_Y_MAX));

    // The next raster coordinates are known from the current input and
    // counter state. Fetch that index one clock early; the registered colour
    // lookup then reaches the existing output edge with NO extra video delay.
    wire [11:0] logo_next_x = (!I_rst_n || I_vsync || !I_de) ? 12'd0 :
        ((S_x < IMG_WIDTH-1) ? S_x + 12'd1 : S_x);
    wire [11:0] logo_next_y = (!I_rst_n || I_vsync) ? 12'd0 :
        ((!I_de && S_de_d && S_y < IMG_HEIGHT-1) ? S_y + 12'd1 : S_y);
    wire logo_prefetch_content =
        logo_next_x >= LOGO_X && logo_next_x < LOGO_X+LOGO_W &&
        logo_next_y >= LOGO_Y && logo_next_y < LOGO_Y+LOGO_H &&
        logo_next_x >= LOGO_X+LOGO_DATA_X_MIN &&
        logo_next_x <= LOGO_X+LOGO_DATA_X_MAX &&
        logo_next_y >= LOGO_Y+LOGO_DATA_Y_MIN &&
        logo_next_y <= LOGO_Y+LOGO_DATA_Y_MAX;
    assign S_logo_addr = logo_prefetch_content ?
        ((logo_next_y-LOGO_Y-LOGO_DATA_Y_MIN)*LOGO_DATA_W +
         (logo_next_x-LOGO_X-LOGO_DATA_X_MIN)) : 14'd0;
    // Discard a stale prefetched index when asynchronous reset is released.
    // The raster starts at (0,0), in the bitmap's transparent outer border.
    reg logo_prefetch_valid;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) logo_prefetch_valid <= 1'b0;
        else logo_prefetch_valid <= 1'b1;
    end

    (* keep_hierarchy = "true" *) anlogic_logo_rom u_anlogic_logo_rom (
        .I_clk   (I_clk),
        .I_addr  (S_logo_addr),
        .O_index (S_logo_index)
    );

    anlogic_logo_palette u_anlogic_logo_palette (
        .I_clk   (I_clk),
        .I_index (logo_prefetch_valid ? S_logo_index : 10'd0),
        .O_pixel (S_logo_pixel)
    );

    always @(*) begin
        S_alg_panel     = 1'b0;
        S_alg_on        = 1'b0;
        S_alg_color     = 24'hffffff;
        S_alg_local_x   = 8'd0;
        S_alg_local_y   = 6'd0;
        S_alg_char_idx  = 4'd0;
        S_alg_char_x    = 5'd0;
        S_alg_col       = 3'd0;
        S_alg_row       = 3'd0;
        S_alg_char_code = 5'd31;
        S_alg_bits      = 5'd0;
        if(I_de && (S_x >= ALG_X) && (S_x < (ALG_X + ALG_W)) &&
           (S_y >= ALG_Y) && (S_y < (ALG_Y + ALG_H))) begin
            S_alg_panel = 1'b1;

            if((S_x >= (ALG_X + 9)) && (S_x < (ALG_X + 171)) &&
               (S_y >= (ALG_Y + 5)) && (S_y < (ALG_Y + 26))) begin
                S_alg_local_x  = S_x - ALG_X - 9;
                S_alg_local_y  = S_y - ALG_Y - 5;
                S_alg_char_idx = S_alg_local_x / 8'd18;
                S_alg_char_x = S_alg_local_x - (S_alg_char_idx * 8'd18);
                S_alg_col = S_alg_char_x / 5'd3;
                S_alg_row = S_alg_local_y / 6'd3;

                case(I_algorithm_mode)
                    3'd0: begin // AE ON / AE OFF
                        case(S_alg_char_idx)
                            0:S_alg_char_code=0; 1:S_alg_char_code=3; 2:S_alg_char_code=31;
                            3:S_alg_char_code=8; 4:S_alg_char_code=S_ae_enable_show ? 7 : 4;
                            5:S_alg_char_code=S_ae_enable_show ? 31 : 4;
                            default:S_alg_char_code=31;
                        endcase
                    end
                    3'd1: begin // GRAYSCALE
                        case(S_alg_char_idx)
                            0:S_alg_char_code=5; 1:S_alg_char_code=9; 2:S_alg_char_code=0; 3:S_alg_char_code=12;
                            4:S_alg_char_code=10; 5:S_alg_char_code=2; 6:S_alg_char_code=0; 7:S_alg_char_code=6;
                            8:S_alg_char_code=3; default:S_alg_char_code=31;
                        endcase
                    end
                    3'd2: begin // MEDIAN
                        case(S_alg_char_idx)
                            0:S_alg_char_code=15; 1:S_alg_char_code=3; 2:S_alg_char_code=13;
                            3:S_alg_char_code=14; 4:S_alg_char_code=0; 5:S_alg_char_code=7;
                            default:S_alg_char_code=31;
                        endcase
                    end
                    3'd3: begin // SOBEL
                        case(S_alg_char_idx)
                            0:S_alg_char_code=10; 1:S_alg_char_code=8; 2:S_alg_char_code=1;
                            3:S_alg_char_code=3; 4:S_alg_char_code=6; default:S_alg_char_code=31;
                        endcase
                    end
                    3'd4: begin // CARTOON
                        case(S_alg_char_idx)
                            0:S_alg_char_code=2; 1:S_alg_char_code=0; 2:S_alg_char_code=9; 3:S_alg_char_code=11;
                            4:S_alg_char_code=8; 5:S_alg_char_code=8; 6:S_alg_char_code=7;
                            default:S_alg_char_code=31;
                        endcase
                    end
                    3'd5: begin // MOTION
                        case(S_alg_char_idx)
                            0:S_alg_char_code=15; 1:S_alg_char_code=8; 2:S_alg_char_code=11;
                            3:S_alg_char_code=14; 4:S_alg_char_code=8; 5:S_alg_char_code=7;
                            default:S_alg_char_code=31;
                        endcase
                    end
                    3'd6: begin // DIFF
                        case(S_alg_char_idx)
                            0:S_alg_char_code=13; 1:S_alg_char_code=14;
                            2:S_alg_char_code=4; 3:S_alg_char_code=4;
                            default:S_alg_char_code=31;
                        endcase
                    end
                    default:S_alg_char_code=31;
                endcase

                S_alg_bits = F_algorithm_char_bits(S_alg_char_code,S_alg_row);
                if((S_alg_char_x < 15) && (S_alg_col < 5))
                    S_alg_on = S_alg_bits[4-S_alg_col];
            end

            case(I_algorithm_mode)
                3'd0:S_alg_color=S_ae_enable_show ? 24'h00ff40 : 24'hff3030;
                3'd1:S_alg_color=24'hffffff;
                3'd2:S_alg_color=24'h40ff80;
                3'd3:S_alg_color=24'hffff00;
                3'd4:S_alg_color=24'h00e6ff;
                3'd5:S_alg_color=24'hff4040;
                3'd6:S_alg_color=24'hff8000;
                default:S_alg_color=24'hffffff;
            endcase
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x     <= 12'd0;
            S_y     <= 12'd0;
            S_de_d  <= 1'b0;
            S_ae_enable_meta <= 1'b1;
            S_ae_enable_sync <= 1'b1;
            S_ae_enable_show <= 1'b1;
            S_status_overlay_enable_d <= 1'b0;
            S_status_overlay_rgb_d <= 24'd0;
            S_vsync_d <= 1'b0;
            S_rgb_d <= 24'd0;
            S_logo_window_d <= 1'b0;
            S_alg_panel_d <= 1'b0;
            S_alg_on_d <= 1'b0;
            S_alg_color_d <= 24'd0;
            O_vsync <= 1'b0;
            O_de    <= 1'b0;
            O_rgb   <= 24'd0;
        end
        else begin
            O_vsync <= S_vsync_d;
            O_de    <= S_de_d;
            S_de_d  <= I_de;
            S_status_overlay_enable_d <= S_status_overlay_enable;
            S_status_overlay_rgb_d <= S_status_overlay_rgb;
            S_vsync_d <= I_vsync;
            S_rgb_d <= I_rgb;
            S_logo_window_d <= S_logo_window;
            S_alg_panel_d <= S_alg_panel;
            S_alg_on_d <= S_alg_on;
            S_alg_color_d <= S_alg_color;
            S_ae_enable_meta <= I_ae_enable;
            S_ae_enable_sync <= S_ae_enable_meta;

            if(I_vsync) begin
                S_x <= 12'd0;
                S_y <= 12'd0;
                S_ae_enable_show <= S_ae_enable_sync;
            end
            else if(I_de) begin
                if(S_x < (IMG_WIDTH - 1))
                    S_x <= S_x + 12'd1;
            end
            else begin
                S_x <= 12'd0;
                if(S_de_d && (S_y < (IMG_HEIGHT - 1)))
                    S_y <= S_y + 12'd1;
            end

            if(S_logo_window_d && S_logo_pixel[24])
                O_rgb <= S_logo_pixel[23:0];
            else if(S_status_overlay_enable_d)
                O_rgb <= S_status_overlay_rgb_d;
            else if(S_alg_panel_d && S_alg_on_d)
                O_rgb <= S_alg_color_d;
            else
                O_rgb <= S_rgb_d;
        end
    end

endmodule
