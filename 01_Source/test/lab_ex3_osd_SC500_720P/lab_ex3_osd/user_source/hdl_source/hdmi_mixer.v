// 2026-10-12: render status glyphs over video without opaque panel backgrounds.
module hdmi_mixer #(
    parameter H_OFFSET = 128,
    parameter V_OFFSET = 60,
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter integer DEBUG_MODE = 0
)(
    input wire        I_clk,
    input wire        I_rst_n,

    input wire        I_video_vsync,
    input wire        I_video_hsync,
    input wire        I_video_de,
    input wire        I_video_user,
    input wire        I_video_last,

    input wire[3:0]   I_debug_status,
    input wire        I_ae_enable,
    input wire[2:0]   I_algorithm_mode,
    input wire[19:0]  I_latency_10us_bcd,
    input wire[23:0]  I_processed_fps_bcd,
    input wire[19:0]  I_motion_count_bcd,

    output wire       O_video_rd_en,
    input wire[23:0]  I_video_rd_data,

    output reg        O_hdmi_vsync,
    output reg        O_hdmi_hsync,
    output reg        O_hdmi_de,
    output reg[23:0]  O_hdmi_data
);

    reg        S_video_vsync_1d;
    reg        S_video_vsync_2d;
    reg        S_video_hsync_1d;
    reg        S_video_hsync_2d;
    reg        S_video_de_1d;
    reg        S_video_de_2d;
    reg [11:0] S_x;
    reg [11:0] S_y;
    reg [11:0] S_x_1d;
    reg [11:0] S_x_2d;
    reg [11:0] S_y_1d;
    reg [11:0] S_y_2d;

    reg        S_osd_hit;
    reg [23:0] S_osd_color;
    reg [3:0]  S_char_idx;
    reg [2:0]  S_char_row;
    reg [2:0]  S_char_col;
    reg [4:0]  S_char_bits;
    reg        S_char_on;
    reg        S_logo_blue_on;
    reg        S_logo_red_on;
    reg [11:0] S_logo_tmp_y;
    reg [3:0]  S_logo_red_band;
    reg [11:0] S_logo_red_x_start;
    reg [11:0] S_logo_red_x_end;
    reg [31:0] S_frame_cnt;
    reg [11:0] S_dyn_x;
    reg [11:0] S_dyn_y;
    reg [3:0]  S_dyn_char;
    reg [2:0]  S_dyn_col;
    reg [2:0]  S_dyn_row;
    reg [4:0]  S_dyn_bits;
    reg        S_dyn_on;
    reg [3:0]  S_dyn_digit_idx;
    reg [11:0] S_dyn_digit_x;
    reg [6:0]  S_dyn_seg;
    reg [3:0]  S_cnt_d0;
    reg [3:0]  S_cnt_d1;
    reg [3:0]  S_cnt_d2;
    reg [3:0]  S_cnt_d3;
    reg [3:0]  S_cnt_d4;
    reg [3:0]  S_cnt_d5;
    reg [2:0]  S_lbl_row;
    reg [2:0]  S_lbl_col;
    reg [1:0]  S_lbl_idx;
    reg [4:0]  S_lbl_bits;
    reg [6:0]  S_lbl_local_x;
    reg [3:0]  S_dyn_dec_digit;
    reg [4:0]  S_cn_local_x;
    reg [4:0]  S_cn_local_y;
    reg [3:0]  S_cn_col;
    reg [3:0]  S_cn_row;
    reg [15:0] S_cn_row_bits;
    reg        S_cn_on;
    reg [9:0]  S_cn_scale_x;
    reg [9:0]  S_cn_scale_y;
    reg [7:0]  S_pf_char;
    reg [4:0]  S_pf_local_x;
    reg [4:0]  S_pf_local_y;
    reg [3:0]  S_pf_col;
    reg [3:0]  S_pf_row;
    wire [15:0] S_pf_row_bits;
    reg        S_pf_on;
    reg [9:0]  S_pf_scale_x;
    reg [9:0]  S_pf_scale_y;
    reg        S_ae_enable_meta;
    reg        S_ae_enable_sync;
    reg [2:0]  S_algorithm_mode_show;
    reg [7:0]  S_alg_local_x;
    reg [5:0]  S_alg_local_y;
    reg [3:0]  S_alg_char_idx;
    reg [4:0]  S_alg_char_x;
    reg [2:0]  S_alg_col;
    reg [2:0]  S_alg_row;
    reg [4:0]  S_alg_char_code;
    reg [4:0]  S_alg_bits;
    reg        S_alg_on;
    reg [19:0] S_latency_bcd_meta;
    reg [19:0] S_latency_bcd_sync;
    reg [19:0] S_latency_bcd_show;
    reg [23:0] S_fps_bcd_meta;
    reg [23:0] S_fps_bcd_sync;
    reg [23:0] S_fps_bcd_show;
    reg [19:0] S_motion_count_bcd_meta;
    reg [19:0] S_motion_count_bcd_sync;
    reg [19:0] S_motion_count_bcd_show;
    reg [7:0]  S_mon_local_x;
    reg [6:0]  S_mon_local_y;
    reg [4:0]  S_mon_char_y;
    reg [1:0]  S_mon_line;
    reg [3:0]  S_mon_char_idx;
    reg [3:0]  S_mon_char_x;
    reg [2:0]  S_mon_col;
    reg [2:0]  S_mon_row;
    reg [3:0]  S_mon_char_code;
    reg [3:0]  S_mon_digit;
    reg [4:0]  S_mon_bits;
    reg        S_mon_is_digit;
    reg        S_mon_on;

    localparam COLOR_LOGO_BLUE   = 24'h1f315c;
    localparam COLOR_LOGO_RED    = 24'hec1c2d;
    localparam COLOR_TEXT        = 24'h00e6ff;
    localparam DYN_OSD_X         = 12'd375;
    localparam DYN_OSD_Y         = 12'd120;
    localparam DYN_OSD_W         = 12'd200;
    localparam DYN_OSD_H         = 12'd24;
    localparam CN_Y_OFFSET       = 12'd2;
    localparam COLOR_DYN_TEXT    = 24'hfff200;
    localparam CHAR_AN           = 8'h80;
    localparam CHAR_LU           = 8'h81;
    localparam CHAR_C            = 8'h43;
    localparam CHAR_N            = 8'h4e;
    localparam CHAR_T            = 8'h54;
    localparam CHAR_0            = 8'h30;
    localparam CHAR_COLON        = 8'h3a;
    // Legacy pre-processing mode panel is disabled.  The clean mode label is
    // now drawn after mode_select by video_logo_overlay.
    localparam ALG_OSD_ENABLE    = 1'b0;
    localparam ALG_OSD_X         = 12'd1080;
    localparam ALG_OSD_Y         = 12'd24;
    localparam ALG_OSD_W         = 12'd180;
    localparam ALG_OSD_H         = 12'd31;
    localparam COLOR_AE_ON       = 24'h00ff40;
    localparam COLOR_AE_OFF      = 24'hff3030;
    localparam COLOR_GRAY_TEXT   = 24'hffffff;
    localparam COLOR_SOBEL_TEXT  = 24'hffff00;
    localparam COLOR_CART_TEXT   = 24'h00e6ff;
    localparam COLOR_MEDIAN_TEXT = 24'h40ff80;
    localparam COLOR_MOTION_TEXT = 24'hff4040;
    localparam COLOR_DIFF_TEXT   = 24'hff8000;
    localparam MON_OSD_X         = 12'd1088;
    localparam MON_OSD_Y         = 12'd642;
    localparam MON_OSD_W         = 12'd176;
    localparam MON_OSD_H         = 12'd62;
    localparam COLOR_LAT_TEXT    = 24'h00e6ff;
    localparam COLOR_FPS_TEXT    = 24'hff80ff;
    localparam COLOR_MOTION_CNT  = 24'hff6040;

    // Compact 5x7 algorithm-status font.
    // Codes: A,B,C,E,F,G,L,N,O,R,S,T,Y,D,I,M,space.
    function [4:0] F_algorithm_char_bits;
        input [4:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'd0: begin case(I_row) // A
                    3'd0:F_algorithm_char_bits=5'b01110; 3'd1,3'd2:F_algorithm_char_bits=5'b10001;
                    3'd3:F_algorithm_char_bits=5'b11111; 3'd4,3'd5,3'd6:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd1: begin case(I_row) // B
                    3'd0,3'd3,3'd6:F_algorithm_char_bits=5'b11110;
                    3'd1,3'd2,3'd4,3'd5:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd2: begin case(I_row) // C
                    3'd0,3'd6:F_algorithm_char_bits=5'b01110; 3'd1,3'd5:F_algorithm_char_bits=5'b10001;
                    3'd2,3'd3,3'd4:F_algorithm_char_bits=5'b10000;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd3: begin case(I_row) // E
                    3'd0,3'd6:F_algorithm_char_bits=5'b11111; 3'd3:F_algorithm_char_bits=5'b11110;
                    3'd1,3'd2,3'd4,3'd5:F_algorithm_char_bits=5'b10000;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd4: begin case(I_row) // F
                    3'd0:F_algorithm_char_bits=5'b11111; 3'd3:F_algorithm_char_bits=5'b11110;
                    3'd1,3'd2,3'd4,3'd5,3'd6:F_algorithm_char_bits=5'b10000;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd5: begin case(I_row) // G
                    3'd0,3'd6:F_algorithm_char_bits=5'b01110; 3'd1,3'd5:F_algorithm_char_bits=5'b10001;
                    3'd2:F_algorithm_char_bits=5'b10000; 3'd3:F_algorithm_char_bits=5'b10111;
                    3'd4:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd6: begin case(I_row) // L
                    3'd0,3'd1,3'd2,3'd3,3'd4,3'd5:F_algorithm_char_bits=5'b10000;
                    3'd6:F_algorithm_char_bits=5'b11111;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd7: begin case(I_row) // N
                    3'd0,3'd6:F_algorithm_char_bits=5'b10001; 3'd1:F_algorithm_char_bits=5'b11001;
                    3'd2,3'd3:F_algorithm_char_bits=5'b10101; 3'd4:F_algorithm_char_bits=5'b10011;
                    3'd5:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd8: begin case(I_row) // O
                    3'd0,3'd6:F_algorithm_char_bits=5'b01110;
                    3'd1,3'd2,3'd3,3'd4,3'd5:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd9: begin case(I_row) // R
                    3'd0,3'd3:F_algorithm_char_bits=5'b11110; 3'd1,3'd2:F_algorithm_char_bits=5'b10001;
                    3'd4:F_algorithm_char_bits=5'b10100; 3'd5:F_algorithm_char_bits=5'b10010;
                    3'd6:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd10: begin case(I_row) // S
                    3'd0:F_algorithm_char_bits=5'b01111; 3'd1,3'd2:F_algorithm_char_bits=5'b10000;
                    3'd3:F_algorithm_char_bits=5'b01110; 3'd4,3'd5:F_algorithm_char_bits=5'b00001;
                    3'd6:F_algorithm_char_bits=5'b11110;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd11: begin case(I_row) // T
                    3'd0:F_algorithm_char_bits=5'b11111;
                    3'd1,3'd2,3'd3,3'd4,3'd5,3'd6:F_algorithm_char_bits=5'b00100;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                4'd12: begin case(I_row) // Y
                    3'd0,3'd1:F_algorithm_char_bits=5'b10001; 3'd2:F_algorithm_char_bits=5'b01010;
                    3'd3,3'd4,3'd5,3'd6:F_algorithm_char_bits=5'b00100;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                5'd13: begin case(I_row) // D
                    3'd0,3'd6:F_algorithm_char_bits=5'b11110;
                    3'd1,3'd2,3'd3,3'd4,3'd5:F_algorithm_char_bits=5'b10001;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                5'd14: begin case(I_row) // I
                    3'd0,3'd6:F_algorithm_char_bits=5'b11111;
                    3'd1,3'd2,3'd3,3'd4,3'd5:F_algorithm_char_bits=5'b00100;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                5'd15: begin case(I_row) // M
                    3'd0,3'd3,3'd4,3'd5,3'd6:F_algorithm_char_bits=5'b10001;
                    3'd1:F_algorithm_char_bits=5'b11011; 3'd2:F_algorithm_char_bits=5'b10101;
                    default:F_algorithm_char_bits=5'b00000; endcase end
                default: F_algorithm_char_bits = 5'b00000;
            endcase
        end
    endfunction

    // Compact monitor font. Codes: C,A,P,D,I,S,L,T,M,colon,dot,F,O.
    function [4:0] F_monitor_char_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'd0: begin case(I_row) // C
                    3'd0:F_monitor_char_bits=5'b01110; 3'd1:F_monitor_char_bits=5'b10001;
                    3'd2,3'd3,3'd4:F_monitor_char_bits=5'b10000;
                    3'd5:F_monitor_char_bits=5'b10001; 3'd6:F_monitor_char_bits=5'b01110;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd1: begin case(I_row) // A
                    3'd0:F_monitor_char_bits=5'b01110; 3'd1,3'd2:F_monitor_char_bits=5'b10001;
                    3'd3:F_monitor_char_bits=5'b11111; 3'd4,3'd5,3'd6:F_monitor_char_bits=5'b10001;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd2: begin case(I_row) // P
                    3'd0:F_monitor_char_bits=5'b11110; 3'd1,3'd2:F_monitor_char_bits=5'b10001;
                    3'd3:F_monitor_char_bits=5'b11110; 3'd4,3'd5,3'd6:F_monitor_char_bits=5'b10000;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd3: begin case(I_row) // D
                    3'd0:F_monitor_char_bits=5'b11110; 3'd1,3'd2,3'd3,3'd4,3'd5:F_monitor_char_bits=5'b10001;
                    3'd6:F_monitor_char_bits=5'b11110; default:F_monitor_char_bits=5'b00000; endcase end
                4'd4: begin case(I_row) // I
                    3'd0,3'd6:F_monitor_char_bits=5'b11111;
                    3'd1,3'd2,3'd3,3'd4,3'd5:F_monitor_char_bits=5'b00100;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd5: begin case(I_row) // S
                    3'd0:F_monitor_char_bits=5'b01111; 3'd1,3'd2:F_monitor_char_bits=5'b10000;
                    3'd3:F_monitor_char_bits=5'b01110; 3'd4,3'd5:F_monitor_char_bits=5'b00001;
                    3'd6:F_monitor_char_bits=5'b11110; default:F_monitor_char_bits=5'b00000; endcase end
                4'd6: begin case(I_row) // L
                    3'd0,3'd1,3'd2,3'd3,3'd4,3'd5:F_monitor_char_bits=5'b10000;
                    3'd6:F_monitor_char_bits=5'b11111; default:F_monitor_char_bits=5'b00000; endcase end
                4'd7: begin case(I_row) // T
                    3'd0:F_monitor_char_bits=5'b11111;
                    3'd1,3'd2,3'd3,3'd4,3'd5,3'd6:F_monitor_char_bits=5'b00100;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd8: begin case(I_row) // M
                    3'd0:F_monitor_char_bits=5'b10001; 3'd1:F_monitor_char_bits=5'b11011;
                    3'd2:F_monitor_char_bits=5'b10101;
                    3'd3,3'd4,3'd5,3'd6:F_monitor_char_bits=5'b10001;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd9: begin case(I_row) // colon
                    3'd2,3'd5:F_monitor_char_bits=5'b00100;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd10: begin case(I_row) // dot
                    3'd6:F_monitor_char_bits=5'b00100;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd11: begin case(I_row) // F
                    3'd0:F_monitor_char_bits=5'b11111;
                    3'd1,3'd2:F_monitor_char_bits=5'b10000;
                    3'd3:F_monitor_char_bits=5'b11110;
                    3'd4,3'd5,3'd6:F_monitor_char_bits=5'b10000;
                    default:F_monitor_char_bits=5'b00000; endcase end
                4'd12: begin case(I_row) // O
                    3'd0:F_monitor_char_bits=5'b01110;
                    3'd1,3'd2,3'd3,3'd4,3'd5:F_monitor_char_bits=5'b10001;
                    3'd6:F_monitor_char_bits=5'b01110;
                    default:F_monitor_char_bits=5'b00000; endcase end
                default: F_monitor_char_bits=5'b00000;
            endcase
        end
    endfunction

    function [4:0] F_logo_text_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'd0: begin
                    case(I_row) // A
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b11111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd1: begin
                    case(I_row) // N
                        3'd0: F_logo_text_bits = 5'b10001;
                        3'd1: F_logo_text_bits = 5'b11001;
                        3'd2: F_logo_text_bits = 5'b10101;
                        3'd3: F_logo_text_bits = 5'b10011;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd2: begin
                    case(I_row) // L
                        3'd0: F_logo_text_bits = 5'b10000;
                        3'd1: F_logo_text_bits = 5'b10000;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10000;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd3: begin
                    case(I_row) // O
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b10001;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd4: begin
                    case(I_row) // G
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd5: begin
                    case(I_row) // I
                        3'd0: F_logo_text_bits = 5'b11111;
                        3'd1: F_logo_text_bits = 5'b00100;
                        3'd2: F_logo_text_bits = 5'b00100;
                        3'd3: F_logo_text_bits = 5'b00100;
                        3'd4: F_logo_text_bits = 5'b00100;
                        3'd5: F_logo_text_bits = 5'b00100;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd6: begin
                    case(I_row) // C
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                default: F_logo_text_bits = 5'b00000;
            endcase
        end
    endfunction

    // 7-seg bit mapping: {a,b,c,d,e,f,g}
    function [6:0] F_hex7seg;
        input [3:0] I_hex;
        begin
            case(I_hex)
                4'h0: F_hex7seg = 7'b1111110;
                4'h1: F_hex7seg = 7'b0110000;
                4'h2: F_hex7seg = 7'b1101101;
                4'h3: F_hex7seg = 7'b1111001;
                4'h4: F_hex7seg = 7'b0110011;
                4'h5: F_hex7seg = 7'b1011011;
                4'h6: F_hex7seg = 7'b1011111;
                4'h7: F_hex7seg = 7'b1110000;
                4'h8: F_hex7seg = 7'b1111111;
                4'h9: F_hex7seg = 7'b1111011;
                4'ha: F_hex7seg = 7'b1110111;
                4'hb: F_hex7seg = 7'b0011111;
                4'hc: F_hex7seg = 7'b1001110;
                4'hd: F_hex7seg = 7'b0111101;
                4'he: F_hex7seg = 7'b1001111;
                4'hf: F_hex7seg = 7'b1000111;
                default: F_hex7seg = 7'b0000000;
            endcase
        end
    endfunction

    function [4:0] F_cnt_label_bits;
        input [1:0] I_idx;
        input [2:0] I_row;
        begin
            case(I_idx)
                2'd0: begin // C
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b01110;
                        3'd1: F_cnt_label_bits = 5'b10001;
                        3'd2: F_cnt_label_bits = 5'b10000;
                        3'd3: F_cnt_label_bits = 5'b10000;
                        3'd4: F_cnt_label_bits = 5'b10000;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b01110;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd1: begin // N
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b10001;
                        3'd1: F_cnt_label_bits = 5'b11001;
                        3'd2: F_cnt_label_bits = 5'b10101;
                        3'd3: F_cnt_label_bits = 5'b10011;
                        3'd4: F_cnt_label_bits = 5'b10001;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b10001;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd2: begin // T
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b11111;
                        3'd1: F_cnt_label_bits = 5'b00100;
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd3: F_cnt_label_bits = 5'b00100;
                        3'd4: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        3'd6: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                default: begin // ':'
                    case(I_row)
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
            endcase
        end
    endfunction

    // Minimal 16x16 Chinese bitmap rows for "an" and "lu".
    function [15:0] F_cn16_row;
        input I_char; // 0: an, 1: lu
        input [3:0] I_row;
        begin
            if(!I_char) begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h0200;
                    4'd1:  F_cn16_row = 16'h7ff0;
                    4'd2:  F_cn16_row = 16'h4410;
                    4'd3:  F_cn16_row = 16'h0400;
                    4'd4:  F_cn16_row = 16'h7ff0;
                    4'd5:  F_cn16_row = 16'h0840;
                    4'd6:  F_cn16_row = 16'h1040;
                    4'd7:  F_cn16_row = 16'h1c80;
                    4'd8:  F_cn16_row = 16'h0300;
                    4'd9:  F_cn16_row = 16'h0cc0;
                    4'd10: F_cn16_row = 16'h7020;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
            else begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h79e0;
                    4'd1:  F_cn16_row = 16'h4a20;
                    4'd2:  F_cn16_row = 16'h4d40;
                    4'd3:  F_cn16_row = 16'h7880;
                    4'd4:  F_cn16_row = 16'h1140;
                    4'd5:  F_cn16_row = 16'h1630;
                    4'd6:  F_cn16_row = 16'h5be0;
                    4'd7:  F_cn16_row = 16'h5220;
                    4'd8:  F_cn16_row = 16'h5220;
                    4'd9:  F_cn16_row = 16'h5be0;
                    4'd10: F_cn16_row = 16'h6220;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
        end
    endfunction

    function [4:0] F_dyn_char_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'h0: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10011; 3'd3:F_dyn_char_bits=5'b10101; 3'd4:F_dyn_char_bits=5'b11001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h1: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00100; 3'd1:F_dyn_char_bits=5'b01100; 3'd2:F_dyn_char_bits=5'b00100; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b00100; 3'd5:F_dyn_char_bits=5'b00100; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h2: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b00110; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'h3: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h4: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00010; 3'd1:F_dyn_char_bits=5'b00110; 3'd2:F_dyn_char_bits=5'b01010; 3'd3:F_dyn_char_bits=5'b10010; 3'd4:F_dyn_char_bits=5'b11111; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b00010; default:F_dyn_char_bits=5'b00000; endcase end
                4'h5: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b11110; 3'd3:F_dyn_char_bits=5'b00001; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h6: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00110; 3'd1:F_dyn_char_bits=5'b01000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h7: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00010; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b01000; 3'd6:F_dyn_char_bits=5'b01000; default:F_dyn_char_bits=5'b00000; endcase end
                4'h8: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h9: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01111; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b11100; default:F_dyn_char_bits=5'b00000; endcase end
                4'ha: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11111; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b10001; default:F_dyn_char_bits=5'b00000; endcase end
                4'hb: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hc: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b10000; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hd: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b10001; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'he: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'hf: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b10000; default:F_dyn_char_bits=5'b00000; endcase end
                default: F_dyn_char_bits = 5'b00000;
            endcase
        end
    endfunction

    // Unified prefix character library (16x16 rows): an/lu/C/N/T/:
    function [15:0] F_osd_char16_row;
        input [7:0] I_char;
        input [3:0] I_row;
        begin
            case(I_char)
                CHAR_AN: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h0200;
                        4'd1:  F_osd_char16_row = 16'h7ff0;
                        4'd2:  F_osd_char16_row = 16'h4410;
                        4'd3:  F_osd_char16_row = 16'h0400;
                        4'd4:  F_osd_char16_row = 16'h7ff0;
                        4'd5:  F_osd_char16_row = 16'h0840;
                        4'd6:  F_osd_char16_row = 16'h1040;
                        4'd7:  F_osd_char16_row = 16'h1c80;
                        4'd8:  F_osd_char16_row = 16'h0300;
                        4'd9:  F_osd_char16_row = 16'h0cc0;
                        4'd10: F_osd_char16_row = 16'h7020;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_LU: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h79e0;
                        4'd1:  F_osd_char16_row = 16'h4a20;
                        4'd2:  F_osd_char16_row = 16'h4d40;
                        4'd3:  F_osd_char16_row = 16'h7880;
                        4'd4:  F_osd_char16_row = 16'h1140;
                        4'd5:  F_osd_char16_row = 16'h1630;
                        4'd6:  F_osd_char16_row = 16'h5be0;
                        4'd7:  F_osd_char16_row = 16'h5220;
                        4'd8:  F_osd_char16_row = 16'h5220;
                        4'd9:  F_osd_char16_row = 16'h5be0;
                        4'd10: F_osd_char16_row = 16'h6220;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_C: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h03f0;
                        4'd3:  F_osd_char16_row = 16'h0c0c;
                        4'd4:  F_osd_char16_row = 16'h1800;
                        4'd5:  F_osd_char16_row = 16'h3000;
                        4'd6:  F_osd_char16_row = 16'h3000;
                        4'd7:  F_osd_char16_row = 16'h3000;
                        4'd8:  F_osd_char16_row = 16'h3000;
                        4'd9:  F_osd_char16_row = 16'h3000;
                        4'd10: F_osd_char16_row = 16'h1800;
                        4'd11: F_osd_char16_row = 16'h0c0c;
                        4'd12: F_osd_char16_row = 16'h03f0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_N: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h300c;
                        4'd3:  F_osd_char16_row = 16'h380c;
                        4'd4:  F_osd_char16_row = 16'h3c0c;
                        4'd5:  F_osd_char16_row = 16'h360c;
                        4'd6:  F_osd_char16_row = 16'h330c;
                        4'd7:  F_osd_char16_row = 16'h318c;
                        4'd8:  F_osd_char16_row = 16'h30cc;
                        4'd9:  F_osd_char16_row = 16'h306c;
                        4'd10: F_osd_char16_row = 16'h303c;
                        4'd11: F_osd_char16_row = 16'h301c;
                        4'd12: F_osd_char16_row = 16'h300c;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_T: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h3ffc;
                        4'd3:  F_osd_char16_row = 16'h03c0;
                        4'd4:  F_osd_char16_row = 16'h03c0;
                        4'd5:  F_osd_char16_row = 16'h03c0;
                        4'd6:  F_osd_char16_row = 16'h03c0;
                        4'd7:  F_osd_char16_row = 16'h03c0;
                        4'd8:  F_osd_char16_row = 16'h03c0;
                        4'd9:  F_osd_char16_row = 16'h03c0;
                        4'd10: F_osd_char16_row = 16'h03c0;
                        4'd11: F_osd_char16_row = 16'h03c0;
                        4'd12: F_osd_char16_row = 16'h03c0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_COLON: begin
                    case(I_row)
                        4'd6:  F_osd_char16_row = 16'h0180;
                        4'd7:  F_osd_char16_row = 16'h0180;
                        4'd10: F_osd_char16_row = 16'h0180;
                        4'd11: F_osd_char16_row = 16'h0180;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                default: F_osd_char16_row = 16'h0000;
            endcase
        end
    endfunction

    assign O_video_rd_en = I_video_de;

    // Synchronize the 24 MHz AE state into the HDMI pixel clock domain.
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_ae_enable_meta <= 1'b1;
            S_ae_enable_sync <= 1'b1;
            S_algorithm_mode_show <= 3'd0;
            S_latency_bcd_meta <= 20'd0;
            S_latency_bcd_sync <= 20'd0;
            S_latency_bcd_show <= 20'd0;
            S_fps_bcd_meta <= 24'd0;
            S_fps_bcd_sync <= 24'd0;
            S_fps_bcd_show <= 24'd0;
            S_motion_count_bcd_meta <= 20'd0;
            S_motion_count_bcd_sync <= 20'd0;
            S_motion_count_bcd_show <= 20'd0;
        end
        else begin
            S_ae_enable_meta <= I_ae_enable;
            S_ae_enable_sync <= S_ae_enable_meta;
            S_latency_bcd_meta <= I_latency_10us_bcd;
            S_latency_bcd_sync <= S_latency_bcd_meta;
            S_fps_bcd_meta <= I_processed_fps_bcd;
            S_fps_bcd_sync <= S_fps_bcd_meta;
            S_motion_count_bcd_meta <= I_motion_count_bcd;
            S_motion_count_bcd_sync <= S_motion_count_bcd_meta;

            // Hold all digits for one complete display frame to avoid tearing.
            if(I_video_user) begin
                S_algorithm_mode_show <= I_algorithm_mode;
                S_latency_bcd_show <= S_latency_bcd_sync;
                S_fps_bcd_show <= S_fps_bcd_sync;
                S_motion_count_bcd_show <= S_motion_count_bcd_sync;
            end
        end
    end

    osd_char_lib u_osd_char_lib(
        .I_char     ( S_pf_char     ),
        .I_row      ( S_pf_row      ),
        .O_row_bits ( S_pf_row_bits )
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_user) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_de) begin
            if(I_video_last) begin
                S_x <= 12'd0;
                S_y <= S_y + 12'd1;
            end
            else begin
                S_x <= S_x + 12'd1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_frame_cnt <= 32'd0;
            S_cnt_d0 <= 4'd0;
            S_cnt_d1 <= 4'd0;
            S_cnt_d2 <= 4'd0;
            S_cnt_d3 <= 4'd0;
            S_cnt_d4 <= 4'd0;
            S_cnt_d5 <= 4'd0;
        end
        else if(I_video_user) begin
            S_frame_cnt <= S_frame_cnt + 32'd1;
            if(S_cnt_d0 == 4'd9) begin
                S_cnt_d0 <= 4'd0;
                if(S_cnt_d1 == 4'd9) begin
                    S_cnt_d1 <= 4'd0;
                    if(S_cnt_d2 == 4'd9) begin
                        S_cnt_d2 <= 4'd0;
                        if(S_cnt_d3 == 4'd9) begin
                            S_cnt_d3 <= 4'd0;
                            if(S_cnt_d4 == 4'd9) begin
                                S_cnt_d4 <= 4'd0;
                                if(S_cnt_d5 == 4'd9)
                                    S_cnt_d5 <= 4'd0;
                                else
                                    S_cnt_d5 <= S_cnt_d5 + 4'd1;
                            end
                            else
                                S_cnt_d4 <= S_cnt_d4 + 4'd1;
                        end
                        else
                            S_cnt_d3 <= S_cnt_d3 + 4'd1;
                    end
                    else
                        S_cnt_d2 <= S_cnt_d2 + 4'd1;
                end
                else
                    S_cnt_d1 <= S_cnt_d1 + 4'd1;
            end
            else
                S_cnt_d0 <= S_cnt_d0 + 4'd1;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x_1d <= 12'd0;
            S_x_2d <= 12'd0;
            S_y_1d <= 12'd0;
            S_y_2d <= 12'd0;
        end
        else begin
            S_x_1d <= S_x;
            S_x_2d <= S_x_1d;
            S_y_1d <= S_y;
            S_y_2d <= S_y_1d;
        end
    end

    always @(*) begin
        S_osd_hit   = 1'b0;
        S_osd_color = 24'd0;
        S_char_idx = 4'd0;
        S_char_row = 3'd0;
        S_char_col = 3'd0;
        S_char_bits = 5'd0;
        S_char_on = 1'b0;
        S_logo_blue_on = 1'b0;
        S_logo_red_on = 1'b0;
        S_logo_tmp_y = 12'd0;
        S_logo_red_band = 4'd0;
        S_logo_red_x_start = 12'd0;
        S_logo_red_x_end = 12'd0;
        S_dyn_x = 12'd0;
        S_dyn_y = 12'd0;
        S_dyn_char = 4'd0;
        S_dyn_col = 3'd0;
        S_dyn_row = 3'd0;
        S_dyn_bits = 5'd0;
        S_dyn_on = 1'b0;
        S_dyn_digit_idx = 4'd0;
        S_dyn_digit_x = 12'd0;
        S_dyn_seg = 7'd0;
        S_lbl_row = 3'd0;
        S_lbl_col = 3'd0;
        S_lbl_idx = 2'd0;
        S_lbl_bits = 5'd0;
        S_lbl_local_x = 7'd0;
        S_dyn_dec_digit = 4'd0;
        S_cn_local_x = 5'd0;
        S_cn_local_y = 5'd0;
        S_cn_col = 4'd0;
        S_cn_row = 4'd0;
        S_cn_row_bits = 16'd0;
        S_cn_on = 1'b0;
        S_cn_scale_x = 10'd0;
        S_cn_scale_y = 10'd0;
        S_pf_char = 8'd0;
        S_pf_local_x = 5'd0;
        S_pf_local_y = 5'd0;
        S_pf_col = 4'd0;
        S_pf_row = 4'd0;
        S_pf_on = 1'b0;
        S_pf_scale_x = 10'd0;
        S_pf_scale_y = 10'd0;
        S_alg_local_x = 8'd0;
        S_alg_local_y = 6'd0;
        S_alg_char_idx = 4'd0;
        S_alg_char_x = 5'd0;
        S_alg_col = 3'd0;
        S_alg_row = 3'd0;
        S_alg_char_code = 5'd31;
        S_alg_bits = 5'd0;
        S_alg_on = 1'b0;
        S_mon_local_x = 8'd0;
        S_mon_local_y = 7'd0;
        S_mon_char_y = 5'd0;
        S_mon_line = 2'd0;
        S_mon_char_idx = 4'd0;
        S_mon_char_x = 4'd0;
        S_mon_col = 3'd0;
        S_mon_row = 3'd0;
        S_mon_char_code = 4'd15;
        S_mon_digit = 4'd0;
        S_mon_bits = 5'd0;
        S_mon_is_digit = 1'b0;
        S_mon_on = 1'b0;

        if(S_video_de_2d) begin
            // Legacy current-algorithm status panel (disabled above).
            // Current algorithm status. The key-selected image effect replaces
            // the AE label; mode 0 retains the original AE ON/OFF indication.
            if(ALG_OSD_ENABLE &&
               (S_x_2d >= ALG_OSD_X) && (S_x_2d < (ALG_OSD_X + ALG_OSD_W)) &&
               (S_y_2d >= ALG_OSD_Y) && (S_y_2d < (ALG_OSD_Y + ALG_OSD_H))) begin

                if((S_x_2d >= (ALG_OSD_X + 12'd9)) &&
                   (S_x_2d <  (ALG_OSD_X + 12'd171)) &&
                   (S_y_2d >= (ALG_OSD_Y + 12'd5)) &&
                   (S_y_2d <  (ALG_OSD_Y + 12'd26))) begin
                    S_alg_local_x = S_x_2d - ALG_OSD_X - 12'd9;
                    S_alg_local_y = S_y_2d - ALG_OSD_Y - 12'd5;
                    S_alg_char_idx = S_alg_local_x / 8'd18;
                    S_alg_char_x = S_alg_local_x - (S_alg_char_idx * 8'd18);
                    S_alg_col = S_alg_char_x / 5'd3;
                    S_alg_row = S_alg_local_y / 6'd3;

                    case(S_algorithm_mode_show)
                        3'd0: begin // AE ON / AE OFF
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=4'd0;  4'd1:S_alg_char_code=4'd3;
                                4'd2:S_alg_char_code=5'd31; 4'd3:S_alg_char_code=4'd8;
                                4'd4:S_alg_char_code=S_ae_enable_sync ? 4'd7 : 4'd4;
                                4'd5:S_alg_char_code=S_ae_enable_sync ? 5'd31 : 4'd4;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        3'd1: begin // GRAYSCALE
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=4'd5;  4'd1:S_alg_char_code=4'd9;
                                4'd2:S_alg_char_code=4'd0;  4'd3:S_alg_char_code=4'd12;
                                4'd4:S_alg_char_code=4'd10; 4'd5:S_alg_char_code=4'd2;
                                4'd6:S_alg_char_code=4'd0;  4'd7:S_alg_char_code=4'd6;
                                4'd8:S_alg_char_code=4'd3;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        3'd2: begin // MEDIAN
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=5'd15; 4'd1:S_alg_char_code=4'd3;
                                4'd2:S_alg_char_code=5'd13; 4'd3:S_alg_char_code=5'd14;
                                4'd4:S_alg_char_code=4'd0;  4'd5:S_alg_char_code=4'd7;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        3'd3: begin // SOBEL
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=4'd10; 4'd1:S_alg_char_code=4'd8;
                                4'd2:S_alg_char_code=4'd1;  4'd3:S_alg_char_code=4'd3;
                                4'd4:S_alg_char_code=4'd6;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        3'd4: begin // CARTOON
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=4'd2;  4'd1:S_alg_char_code=4'd0;
                                4'd2:S_alg_char_code=4'd9;  4'd3:S_alg_char_code=4'd11;
                                4'd4:S_alg_char_code=4'd8;  4'd5:S_alg_char_code=4'd8;
                                4'd6:S_alg_char_code=4'd7;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        3'd5: begin // MOTION
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=5'd15; 4'd1:S_alg_char_code=4'd8;
                                4'd2:S_alg_char_code=4'd11; 4'd3:S_alg_char_code=5'd14;
                                4'd4:S_alg_char_code=4'd8;  4'd5:S_alg_char_code=4'd7;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        3'd6: begin // DIFF
                            case(S_alg_char_idx)
                                4'd0:S_alg_char_code=5'd13; 4'd1:S_alg_char_code=5'd14;
                                4'd2:S_alg_char_code=4'd4;  4'd3:S_alg_char_code=4'd4;
                                default:S_alg_char_code=5'd31;
                            endcase
                        end
                        default:S_alg_char_code=5'd31;
                    endcase

                    S_alg_bits = F_algorithm_char_bits(S_alg_char_code, S_alg_row);
                    if((S_alg_char_x < 5'd15) && (S_alg_col < 3'd5)) begin
                        case(S_alg_col)
                            3'd0: S_alg_on = S_alg_bits[4];
                            3'd1: S_alg_on = S_alg_bits[3];
                            3'd2: S_alg_on = S_alg_bits[2];
                            3'd3: S_alg_on = S_alg_bits[1];
                            3'd4: S_alg_on = S_alg_bits[0];
                            default: S_alg_on = 1'b0;
                        endcase
                    end

                    if(S_alg_on) begin
                        S_osd_hit = 1'b1;
                        case(S_algorithm_mode_show)
                            3'd0: S_osd_color = S_ae_enable_sync ? COLOR_AE_ON : COLOR_AE_OFF;
                            3'd1: S_osd_color = COLOR_GRAY_TEXT;
                            3'd2: S_osd_color = COLOR_MEDIAN_TEXT;
                            3'd3: S_osd_color = COLOR_SOBEL_TEXT;
                            3'd4: S_osd_color = COLOR_CART_TEXT;
                            3'd5: S_osd_color = COLOR_MOTION_TEXT;
                            3'd6: S_osd_color = COLOR_DIFF_TEXT;
                            default: S_osd_color = COLOR_GRAY_TEXT;
                        endcase
                    end
                end
            end

            // Bottom-right latency, capture FPS and changed 8x8 block count.
            // Example: LAT:033.34MS / FPS:060.000 / MOT:00123.
            if((S_x_2d >= MON_OSD_X) && (S_x_2d < (MON_OSD_X + MON_OSD_W)) &&
               (S_y_2d >= MON_OSD_Y) && (S_y_2d < (MON_OSD_Y + MON_OSD_H))) begin

                if((S_x_2d >= (MON_OSD_X + 12'd8)) &&
                   (S_x_2d <  (MON_OSD_X + 12'd152)) &&
                   (S_y_2d >= (MON_OSD_Y + 12'd5)) &&
                   (S_y_2d <  (MON_OSD_Y + 12'd55))) begin
                    S_mon_local_x = S_x_2d - MON_OSD_X - 12'd8;
                    S_mon_local_y = S_y_2d - MON_OSD_Y - 12'd5;
                    S_mon_line = S_mon_local_y / 7'd18;
                    S_mon_char_y = S_mon_local_y - (S_mon_line * 7'd18);
                    S_mon_char_idx = S_mon_local_x / 8'd12;
                    S_mon_char_x = S_mon_local_x - (S_mon_char_idx * 8'd12);
                    S_mon_col = S_mon_char_x / 4'd2;
                    S_mon_row = S_mon_char_y / 5'd2;

                    case(S_mon_line)
                        2'd0: begin // LAT:ddd.ddMS
                            case(S_mon_char_idx)
                                4'd0: S_mon_char_code = 4'd6;
                                4'd1: S_mon_char_code = 4'd1;
                                4'd2: S_mon_char_code = 4'd7;
                                4'd3: S_mon_char_code = 4'd9;
                                4'd4: begin S_mon_is_digit=1'b1; S_mon_digit=S_latency_bcd_show[19:16]; end
                                4'd5: begin S_mon_is_digit=1'b1; S_mon_digit=S_latency_bcd_show[15:12]; end
                                4'd6: begin S_mon_is_digit=1'b1; S_mon_digit=S_latency_bcd_show[11:8]; end
                                4'd7: S_mon_char_code = 4'd10;
                                4'd8: begin S_mon_is_digit=1'b1; S_mon_digit=S_latency_bcd_show[7:4]; end
                                4'd9: begin S_mon_is_digit=1'b1; S_mon_digit=S_latency_bcd_show[3:0]; end
                                4'd10: S_mon_char_code = 4'd8;
                                4'd11: S_mon_char_code = 4'd5;
                                default: S_mon_char_code = 4'd15;
                            endcase
                        end
                        2'd1: begin // FPS:ddd.ddd
                            case(S_mon_char_idx)
                                4'd0: S_mon_char_code = 4'd11;
                                4'd1: S_mon_char_code = 4'd2;
                                4'd2: S_mon_char_code = 4'd5;
                                4'd3: S_mon_char_code = 4'd9;
                                4'd4: begin S_mon_is_digit=1'b1; S_mon_digit=S_fps_bcd_show[23:20]; end
                                4'd5: begin S_mon_is_digit=1'b1; S_mon_digit=S_fps_bcd_show[19:16]; end
                                4'd6: begin S_mon_is_digit=1'b1; S_mon_digit=S_fps_bcd_show[15:12]; end
                                4'd7: S_mon_char_code = 4'd10;
                                4'd8: begin S_mon_is_digit=1'b1; S_mon_digit=S_fps_bcd_show[11:8]; end
                                4'd9: begin S_mon_is_digit=1'b1; S_mon_digit=S_fps_bcd_show[7:4]; end
                                4'd10: begin S_mon_is_digit=1'b1; S_mon_digit=S_fps_bcd_show[3:0]; end
                                default: S_mon_char_code = 4'd15;
                            endcase
                        end
                        2'd2: begin // MOT:ddddd
                            case(S_mon_char_idx)
                                4'd0: S_mon_char_code = 4'd8;
                                4'd1: S_mon_char_code = 4'd12;
                                4'd2: S_mon_char_code = 4'd7;
                                4'd3: S_mon_char_code = 4'd9;
                                4'd4: begin S_mon_is_digit=1'b1; S_mon_digit=S_motion_count_bcd_show[19:16]; end
                                4'd5: begin S_mon_is_digit=1'b1; S_mon_digit=S_motion_count_bcd_show[15:12]; end
                                4'd6: begin S_mon_is_digit=1'b1; S_mon_digit=S_motion_count_bcd_show[11:8]; end
                                4'd7: begin S_mon_is_digit=1'b1; S_mon_digit=S_motion_count_bcd_show[7:4]; end
                                4'd8: begin S_mon_is_digit=1'b1; S_mon_digit=S_motion_count_bcd_show[3:0]; end
                                default: S_mon_char_code = 4'd15;
                            endcase
                        end
                        default: S_mon_char_code = 4'd15;
                    endcase

                    if(S_mon_is_digit)
                        S_mon_bits = F_dyn_char_bits(S_mon_digit, S_mon_row);
                    else
                        S_mon_bits = F_monitor_char_bits(S_mon_char_code, S_mon_row);

                    if((S_mon_char_y < 5'd14) &&
                       (S_mon_char_x < 4'd10) && (S_mon_col < 3'd5)) begin
                        case(S_mon_col)
                            3'd0: S_mon_on = S_mon_bits[4];
                            3'd1: S_mon_on = S_mon_bits[3];
                            3'd2: S_mon_on = S_mon_bits[2];
                            3'd3: S_mon_on = S_mon_bits[1];
                            3'd4: S_mon_on = S_mon_bits[0];
                            default: S_mon_on = 1'b0;
                        endcase
                    end

                    if(S_mon_on) begin
                        S_osd_hit = 1'b1;
                        case(S_mon_line)
                            2'd0: S_osd_color = COLOR_LAT_TEXT;
                            2'd1: S_osd_color = COLOR_FPS_TEXT;
                            default: S_osd_color = COLOR_MOTION_CNT;
                        endcase
                    end
                end
            end

            if((!S_osd_hit) &&
               (S_x_2d >= DYN_OSD_X) && (S_x_2d < (DYN_OSD_X + DYN_OSD_W)) &&
               (S_y_2d >= DYN_OSD_Y) && (S_y_2d < (DYN_OSD_Y + DYN_OSD_H))) begin
                S_dyn_x = S_x_2d - DYN_OSD_X;
                S_dyn_y = S_y_2d - DYN_OSD_Y;

                // Unified prefix render using one character library.
                // an:[0..23], lu:[24..47], C:[52..67], N:[68..83], T:[84..99], :[100..107]
                if((S_dyn_x < 12'd108) && (S_dyn_y < 12'd24)) begin
                    if((S_dyn_x < 12'd24) || ((S_dyn_x >= 12'd24) && (S_dyn_x < 12'd48))) begin
                        if(S_dyn_y >= CN_Y_OFFSET)
                            S_pf_local_y = S_dyn_y - CN_Y_OFFSET;
                        else
                            S_pf_local_y = 5'd31;

                        if(S_dyn_x < 12'd24) begin
                            S_pf_char = CHAR_AN;
                            S_pf_local_x = S_dyn_x;
                        end
                        else begin
                            S_pf_char = CHAR_LU;
                            S_pf_local_x = S_dyn_x - 12'd24;
                        end

                        if((S_pf_local_x < 5'd24) && (S_pf_local_y < 5'd24)) begin
                            S_pf_scale_x = S_pf_local_x * 10'd16;
                            S_pf_scale_y = S_pf_local_y * 10'd16;
                            S_pf_col = S_pf_scale_x / 10'd24;
                            S_pf_row = S_pf_scale_y / 10'd24;
                            case(S_pf_col)
                                4'd0:  S_pf_on = S_pf_row_bits[15];
                                4'd1:  S_pf_on = S_pf_row_bits[14];
                                4'd2:  S_pf_on = S_pf_row_bits[13];
                                4'd3:  S_pf_on = S_pf_row_bits[12];
                                4'd4:  S_pf_on = S_pf_row_bits[11];
                                4'd5:  S_pf_on = S_pf_row_bits[10];
                                4'd6:  S_pf_on = S_pf_row_bits[9];
                                4'd7:  S_pf_on = S_pf_row_bits[8];
                                4'd8:  S_pf_on = S_pf_row_bits[7];
                                4'd9:  S_pf_on = S_pf_row_bits[6];
                                4'd10: S_pf_on = S_pf_row_bits[5];
                                4'd11: S_pf_on = S_pf_row_bits[4];
                                4'd12: S_pf_on = S_pf_row_bits[3];
                                4'd13: S_pf_on = S_pf_row_bits[2];
                                4'd14: S_pf_on = S_pf_row_bits[1];
                                4'd15: S_pf_on = S_pf_row_bits[0];
                                default: S_pf_on = 1'b0;
                            endcase
                        end
                    end
                    else if((S_dyn_x >= 12'd52) && (S_dyn_x < 12'd100) && (S_dyn_y >= 12'd4) && (S_dyn_y < 12'd20)) begin
                        if(S_dyn_x < 12'd68) begin
                            S_pf_char = CHAR_C;
                            S_pf_local_x = S_dyn_x - 12'd52;
                        end
                        else if(S_dyn_x < 12'd84) begin
                            S_pf_char = CHAR_N;
                            S_pf_local_x = S_dyn_x - 12'd68;
                        end
                        else begin
                            S_pf_char = CHAR_T;
                            S_pf_local_x = S_dyn_x - 12'd84;
                        end
                        S_pf_local_y = S_dyn_y - 12'd4;
                        S_pf_col = S_pf_local_x[3:0];
                        S_pf_row = S_pf_local_y[3:0];
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                    end
                    else if((S_dyn_x >= 12'd100) && (S_dyn_x < 12'd108) && (S_dyn_y >= 12'd4) && (S_dyn_y < 12'd20)) begin
                        S_pf_char = CHAR_COLON;
                        S_pf_local_x = S_dyn_x - 12'd100;
                        S_pf_local_y = S_dyn_y - 12'd4;
                        S_pf_scale_x = S_pf_local_x * 10'd16;
                        S_pf_col = S_pf_scale_x / 10'd8;
                        S_pf_row = S_pf_local_y[3:0];
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                    end

                    if(S_pf_on)
                        S_dyn_on = 1'b1;
                end

                // Decimal 6 digits starts at x=110. Each digit is 15x24.
                if((S_dyn_x >= 12'd110) && (S_dyn_x < 12'd200)) begin
                    if(S_dyn_x < 12'd125) begin
                        S_dyn_digit_idx = 4'd0;
                        S_dyn_digit_x = S_dyn_x - 12'd110;
                        S_dyn_dec_digit = S_cnt_d5;
                    end
                    else if(S_dyn_x < 12'd140) begin
                        S_dyn_digit_idx = 4'd1;
                        S_dyn_digit_x = S_dyn_x - 12'd125;
                        S_dyn_dec_digit = S_cnt_d4;
                    end
                    else if(S_dyn_x < 12'd155) begin
                        S_dyn_digit_idx = 4'd2;
                        S_dyn_digit_x = S_dyn_x - 12'd140;
                        S_dyn_dec_digit = S_cnt_d3;
                    end
                    else if(S_dyn_x < 12'd170) begin
                        S_dyn_digit_idx = 4'd3;
                        S_dyn_digit_x = S_dyn_x - 12'd155;
                        S_dyn_dec_digit = S_cnt_d2;
                    end
                    else if(S_dyn_x < 12'd185) begin
                        S_dyn_digit_idx = 4'd4;
                        S_dyn_digit_x = S_dyn_x - 12'd170;
                        S_dyn_dec_digit = S_cnt_d1;
                    end
                    else begin
                        S_dyn_digit_idx = 4'd5;
                        S_dyn_digit_x = S_dyn_x - 12'd185;
                        S_dyn_dec_digit = S_cnt_d0;
                    end

                    // Render decimal digits through unified 16x16 character library.
                    // Keep enlarged 15x24 box for readability.
                    if((S_dyn_digit_x < 12'd15) && (S_dyn_y < 12'd24)) begin
                        S_pf_char = CHAR_0 + {4'd0, S_dyn_dec_digit};
                        S_pf_local_x = S_dyn_digit_x[4:0];
                        S_pf_local_y = S_dyn_y[4:0];
                        S_pf_scale_x = S_pf_local_x * 10'd16;
                        S_pf_scale_y = S_pf_local_y * 10'd16;
                        S_pf_col = S_pf_scale_x / 10'd15;
                        S_pf_row = S_pf_scale_y / 10'd24;
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                        if(S_pf_on)
                            S_dyn_on = 1'b1;
                    end
                end

                if(S_dyn_on) begin
                    S_osd_hit = 1'b1;
                    S_osd_color = COLOR_DYN_TEXT;
                end
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_video_vsync_1d <= 1'b0;
            S_video_vsync_2d <= 1'b0;
            S_video_hsync_1d <= 1'b0;
            S_video_hsync_2d <= 1'b0;
            S_video_de_1d    <= 1'b0;
            S_video_de_2d    <= 1'b0;
            O_hdmi_vsync     <= 1'b0;
            O_hdmi_hsync     <= 1'b0;
            O_hdmi_de        <= 1'b0;
            O_hdmi_data      <= 24'd0;
        end
        else begin
            S_video_vsync_1d <= I_video_vsync;
            S_video_vsync_2d <= S_video_vsync_1d;
            O_hdmi_vsync     <= S_video_vsync_2d;

            S_video_hsync_1d <= I_video_hsync;
            S_video_hsync_2d <= S_video_hsync_1d;
            O_hdmi_hsync     <= S_video_hsync_2d;

            S_video_de_1d    <= I_video_de;
            S_video_de_2d    <= S_video_de_1d;
            O_hdmi_de        <= S_video_de_2d;
            if(DEBUG_MODE == 1) begin
                if(S_video_de_2d) begin
                    if(S_x < 12'd128)
                        O_hdmi_data <= 24'hff0000;
                    else if(S_x < 12'd256)
                        O_hdmi_data <= 24'h00ff00;
                    else if(S_x < 12'd384)
                        O_hdmi_data <= 24'h0000ff;
                    else if(S_x < 12'd512)
                        O_hdmi_data <= 24'hffff00;
                    else if(S_x < 12'd640)
                        O_hdmi_data <= 24'h00ffff;
                    else if(S_x < 12'd768)
                        O_hdmi_data <= 24'hff00ff;
                    else if(S_x < 12'd896)
                        O_hdmi_data <= 24'hffffff;
                    else
                        O_hdmi_data <= 24'h202020;
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else if(DEBUG_MODE == 2) begin
                if(S_video_de_2d) begin
                    case (I_debug_status)
                        4'b0000: O_hdmi_data <= 24'h000000;
                        4'b0001: O_hdmi_data <= 24'hff0000;
                        4'b0011: O_hdmi_data <= 24'hffff00;
                        4'b0111: O_hdmi_data <= 24'h00ff00;
                        4'b1111: O_hdmi_data <= I_video_rd_data;
                        default: O_hdmi_data <= 24'h0000ff;
                    endcase
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else if(DEBUG_MODE == 3) begin
                if(S_video_de_2d) begin
                    if(S_x < 12'd256)
                        O_hdmi_data <= I_debug_status[0] ? 24'hff8000 : 24'h201000;
                    else if(S_x < 12'd512)
                        O_hdmi_data <= I_debug_status[1] ? 24'hffff00 : 24'h202000;
                    else if(S_x < 12'd768)
                        O_hdmi_data <= I_debug_status[2] ? 24'hff0000 : 24'h200000;
                    else
                        O_hdmi_data <= I_debug_status[3] ? 24'h00ffff : 24'h002020;
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else begin
                if(S_osd_hit)
                    O_hdmi_data <= S_osd_color;
                else
                    // video_out has already registered the synchronous FIFO
                    // result.  A further two-cycle delay here would put RGB
                    // two pixels behind DE and soften/clip every line edge.
                    O_hdmi_data <= I_video_rd_data;
            end
        end
    end

endmodule
