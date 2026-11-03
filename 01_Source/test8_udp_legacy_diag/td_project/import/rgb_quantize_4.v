`timescale 1ns / 1ps

// ENABLE=1: two horizontal neighbours, no line RAM (resource-fit default).
// ENABLE=2: full 2x2 mean using one RGB line RAM. ENABLE=0: bypass.
module cartoon_smooth_2x2 #(
    parameter integer IMG_HDISP = 1280,
    parameter integer ENABLE = 1
)(
    input wire clk, rst_n,
    input wire in_vsync, in_href, in_clken,
    input wire [10:0] in_x, in_y,
    input wire [23:0] in_rgb,
    output reg out_vsync, out_href, out_clken,
    output reg [10:0] out_x, out_y,
    output reg [23:0] out_rgb
);
    reg [23:0] line_rgb [0:IMG_HDISP-1];
    reg [10:0] column;
    reg first_row, previous_de;
    reg [23:0] previous_rgb, row_pixel, row_left;
    reg [23:0] current_pixel, current_left;
    reg first_column_d, first_row_d;
    reg vsync_d, href_d, clken_d;
    reg [10:0] x_d, y_d;
    wire [23:0] top_left = first_column_d ? row_pixel : row_left;
    wire [23:0] bottom_left = first_column_d ? current_pixel : current_left;
    wire [23:0] upper = first_row_d ? current_pixel : row_pixel;
    wire [23:0] upper_left = first_row_d ? bottom_left : top_left;
    wire [9:0] r_sum = {2'b0, upper[23:16]} + {2'b0, upper_left[23:16]} +
                       {2'b0, current_pixel[23:16]} + {2'b0, bottom_left[23:16]};
    wire [9:0] g_sum = {2'b0, upper[15:8]} + {2'b0, upper_left[15:8]} +
                       {2'b0, current_pixel[15:8]} + {2'b0, bottom_left[15:8]};
    wire [9:0] b_sum = {2'b0, upper[7:0]} + {2'b0, upper_left[7:0]} +
                       {2'b0, current_pixel[7:0]} + {2'b0, bottom_left[7:0]};
    wire [8:0] r_pair = {1'b0,current_pixel[23:16]} + {1'b0,bottom_left[23:16]};
    wire [8:0] g_pair = {1'b0,current_pixel[15:8]} + {1'b0,bottom_left[15:8]};
    wire [8:0] b_pair = {1'b0,current_pixel[7:0]} + {1'b0,bottom_left[7:0]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            column <= 0;
            first_row <= 1'b1;
            previous_de <= 0;
            previous_rgb <= 0;
            row_pixel <= 0;
            row_left <= 0;
            current_pixel <= 0;
            current_left <= 0;
            first_column_d <= 0;
            first_row_d <= 0;
            vsync_d <= 0;
            href_d <= 0;
            clken_d <= 0;
            x_d <= 0;
            y_d <= 0;
            out_vsync <= 0;
            out_href <= 0;
            out_clken <= 0;
            out_x <= 0;
            out_y <= 0;
            out_rgb <= 0;
        end else begin
            previous_de <= in_href;
            if (in_vsync)
                first_row <= 1'b1;
            else if (previous_de && !in_href)
                first_row <= 1'b0;
            if (!in_href)
                column <= 0;
            else if (in_clken) begin
                if (column == IMG_HDISP-1) column <= 0;
                else column <= column + 1'b1;
                // Inferred synchronous read-before-write line RAM.
                if (ENABLE == 2) begin
                    row_pixel <= line_rgb[column];
                    line_rgb[column] <= in_rgb;
                end
                row_left <= row_pixel;
                current_pixel <= in_rgb;
                current_left <= previous_rgb;
                previous_rgb <= in_rgb;
                first_column_d <= (column == 0);
                first_row_d <= first_row;
            end
            vsync_d <= in_vsync;
            href_d <= in_href;
            clken_d <= in_clken;
            x_d <= in_x;
            y_d <= in_y;
            out_vsync <= vsync_d;
            out_href <= href_d;
            out_clken <= clken_d;
            out_x <= x_d;
            out_y <= y_d;
            if (clken_d) begin
                if (ENABLE == 2)
                    out_rgb <= {r_sum[9:2], g_sum[9:2], b_sum[9:2]};
                else if (ENABLE == 1)
                    out_rgb <= {r_pair[8:1], g_pair[8:1], b_pair[8:1]};
                else
                    out_rgb <= current_pixel;
            end
        end
    end
endmodule

// The quantized pixel arrives seven clocks before the Sobel classification.
// Nine alignment registers and the output register match the three edge
// growth registers: both outputs are thirteen clocks after input RGB.
module cartoon_final_fusion #(
    parameter integer IMG_HDISP = 1280,
    parameter integer EDGE_GROW = 1,
    parameter integer COLOR_BOOST_ENABLE = 1,
    parameter [23:0] WEAK_EDGE_COLOR = 24'h404040
)(
    input wire clk,rst_n,
    input wire [23:0] quant_in,
    input wire quant_vsync,quant_de,
    input wire [10:0] quant_x,quant_y,
    input wire strong_in,weak_in,edge_vsync,edge_href,edge_clken,
    input wire [10:0] edge_x,edge_y,
    output reg [23:0] quant_out,boost_out,
    output wire [23:0] sobel_out,cartoon_out,
    output reg out_vsync,out_href,out_clken,
    output reg [10:0] out_x,out_y,
    output reg strong_out,weak_out
);
    reg [23:0] quant_pipe[0:8];
    reg [8:0] quant_vs_pipe,quant_de_pipe;
    reg [10:0] quant_x_pipe[0:8],quant_y_pipe[0:8];
    integer qi;
    reg strong_line[0:IMG_HDISP-1];
    reg left_strong,left_weak,up_strong;
    reg h_strong,h_weak,h_vsync,h_href,h_clken;
    reg [10:0] h_x,h_y;
    reg g_strong,g_weak,g_vsync,g_href,g_clken;
    reg [10:0] g_x,g_y;
    wire [9:0] y_sum = {2'b0,quant_pipe[8][23:16]} +
                       {1'b0,quant_pipe[8][15:8],1'b0} +
                       {2'b0,quant_pipe[8][7:0]};
    wire [7:0] lum = y_sum[9:2];
    function [7:0] boost_channel;
        input [7:0] channel,luminance;
        reg signed [10:0] diff,value;
        begin
            diff=$signed({3'b000,channel})-$signed({3'b000,luminance});
            value=$signed({3'b000,channel})+(diff >>> 2);
            if(value<0) boost_channel=8'd0;
            else if(value>255) boost_channel=8'd255;
            else boost_channel=value[7:0];
        end
    endfunction
    assign sobel_out = strong_out ? 24'hffffff :
                       weak_out ? 24'h808080 : 24'h000000;
    assign cartoon_out = strong_out ? 24'h000000 :
                         weak_out ? WEAK_EDGE_COLOR : boost_out;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            for(qi=0;qi<9;qi=qi+1) begin
                quant_pipe[qi]<=0;quant_x_pipe[qi]<=0;quant_y_pipe[qi]<=0;
            end
            quant_vs_pipe<=0;quant_de_pipe<=0;
            quant_out<=0;boost_out<=0;
            left_strong<=0;left_weak<=0;up_strong<=0;
            h_strong<=0;h_weak<=0;h_vsync<=0;h_href<=0;h_clken<=0;
            h_x<=0;h_y<=0;
            g_strong<=0;g_weak<=0;g_vsync<=0;g_href<=0;g_clken<=0;
            g_x<=0;g_y<=0;
            strong_out<=0;weak_out<=0;
            out_vsync<=0;out_href<=0;out_clken<=0;out_x<=0;out_y<=0;
        end else begin
            quant_pipe[0]<=quant_in;
            quant_x_pipe[0]<=quant_x;quant_y_pipe[0]<=quant_y;
            for(qi=1;qi<9;qi=qi+1) begin
                quant_pipe[qi]<=quant_pipe[qi-1];
                quant_x_pipe[qi]<=quant_x_pipe[qi-1];
                quant_y_pipe[qi]<=quant_y_pipe[qi-1];
            end
            quant_vs_pipe<={quant_vs_pipe[7:0],quant_vsync};
            quant_de_pipe<={quant_de_pipe[7:0],quant_de};
            quant_out<=quant_pipe[8];
            boost_out <= (COLOR_BOOST_ENABLE != 0) ?
                {boost_channel(quant_pipe[8][23:16],lum),
                 boost_channel(quant_pipe[8][15:8],lum),
                 boost_channel(quant_pipe[8][7:0],lum)} : quant_pipe[8];

            h_vsync<=edge_vsync;h_href<=edge_href;h_clken<=edge_clken;
            h_x<=edge_x;h_y<=edge_y;
            if(edge_href && edge_clken && edge_x<IMG_HDISP) begin
                up_strong <= (edge_y==0) ? 1'b0 : strong_line[edge_x];
                strong_line[edge_x] <= strong_in;
                left_strong<=strong_in;left_weak<=weak_in;
            end else if(!edge_href) begin
                left_strong<=0;left_weak<=0;up_strong<=0;
            end
            h_strong<=strong_in |
                ((EDGE_GROW!=0) && (edge_x!=0) && left_strong);
            h_weak<=weak_in |
                ((EDGE_GROW!=0) && (edge_x!=0) && left_weak);
            g_vsync<=h_vsync;g_href<=h_href;g_clken<=h_clken;
            g_x<=h_x;g_y<=h_y;
            g_strong<=h_strong | ((EDGE_GROW!=0) && up_strong);
            g_weak<=h_weak & ~(h_strong | ((EDGE_GROW!=0) && up_strong));
            out_vsync<=g_vsync;out_href<=g_href;out_clken<=g_clken;
            out_x<=g_x;out_y<=g_y;
            strong_out<=g_strong;weak_out<=g_weak;
        end
    end
endmodule

// Causal 3x3 window anchored at (in_x,in_y). Missing top/left samples
// replicate the nearest valid pixel; line RAM contents from an older frame
// are never used in the first two rows. One registered clock of latency.
module cartoon_window_3x3_8bit #(
    parameter integer IMG_HDISP = 1280
)(
    input wire clk, rst_n,
    input wire in_vsync, in_href, in_clken,
    input wire [10:0] in_x, in_y,
    input wire [7:0] in_pixel,
    output reg out_vsync, out_href, out_clken,
    output reg [10:0] out_x, out_y,
    output wire [7:0] p11,p12,p13,p21,p22,p23,p31,p32,p33
);
    reg [7:0] line1[0:IMG_HDISP-1];
    reg [7:0] line2[0:IMG_HDISP-1];
    reg [7:0] c0,c1,c2,m0,m1,m2,t0,t1,t2;
    reg row0,row1,col0,col1;
    wire [7:0] mid0 = row0 ? c0 : m0;
    wire [7:0] mid1 = row0 ? c1 : m1;
    wire [7:0] mid2 = row0 ? c2 : m2;
    wire [7:0] top0 = (row0 || row1) ? mid0 : t0;
    wire [7:0] top1 = (row0 || row1) ? mid1 : t1;
    wire [7:0] top2 = (row0 || row1) ? mid2 : t2;
    assign p11 = col0 ? top2 : col1 ? top1 : top0;
    assign p12 = col0 ? top2 : top1;
    assign p13 = top2;
    assign p21 = col0 ? mid2 : col1 ? mid1 : mid0;
    assign p22 = col0 ? mid2 : mid1;
    assign p23 = mid2;
    assign p31 = col0 ? c2 : col1 ? c1 : c0;
    assign p32 = col0 ? c2 : c1;
    assign p33 = c2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c0<=0;c1<=0;c2<=0;m0<=0;m1<=0;m2<=0;t0<=0;t1<=0;t2<=0;
            row0<=0;row1<=0;col0<=0;col1<=0;
            out_vsync<=0;out_href<=0;out_clken<=0;out_x<=0;out_y<=0;
        end else begin
            out_vsync <= in_vsync;
            out_href <= in_href;
            out_clken <= in_clken;
            out_x <= in_x;
            out_y <= in_y;
            if (in_href && in_clken && in_x < IMG_HDISP) begin
                // Synchronous read-before-write RAMs: the old values are
                // the preceding one and two lines at this column.
                m2 <= line1[in_x];
                t2 <= line2[in_x];
                line2[in_x] <= line1[in_x];
                line1[in_x] <= in_pixel;
                c0 <= c1; c1 <= c2; c2 <= in_pixel;
                m0 <= m1; m1 <= m2;
                t0 <= t1; t1 <= t2;
                row0 <= (in_y == 0);
                row1 <= (in_y == 1);
                col0 <= (in_x == 0);
                col1 <= (in_x == 1);
            end
        end
    end
endmodule

// Three separable [1 2 1] windows. The two shifts and adders form
// [1 2 1;2 4 2;1 2 1]/16 without a multiplier.
module cartoon_gaussian_3x3 #(
    parameter integer IMG_HDISP = 1280
)(
    input wire clk,rst_n,in_vsync,in_href,in_clken,
    input wire [10:0] in_x,in_y,
    input wire [23:0] in_rgb,
    output reg out_vsync,out_href,out_clken,
    output reg [10:0] out_x,out_y,
    output reg [23:0] out_rgb
);
    wire wv,wh,wc;
    wire [10:0] wx,wy;
    wire [7:0] r11,r12,r13,r21,r22,r23,r31,r32,r33;
    wire [7:0] g11,g12,g13,g21,g22,g23,g31,g32,g33;
    wire [7:0] b11,b12,b13,b21,b22,b23,b31,b32,b33;
    cartoon_window_3x3_8bit #(.IMG_HDISP(IMG_HDISP)) wr(
        .clk(clk),.rst_n(rst_n),.in_vsync(in_vsync),.in_href(in_href),.in_clken(in_clken),
        .in_x(in_x),.in_y(in_y),.in_pixel(in_rgb[23:16]),
        .out_vsync(wv),.out_href(wh),.out_clken(wc),.out_x(wx),.out_y(wy),
        .p11(r11),.p12(r12),.p13(r13),.p21(r21),.p22(r22),.p23(r23),
        .p31(r31),.p32(r32),.p33(r33));
    cartoon_window_3x3_8bit #(.IMG_HDISP(IMG_HDISP)) wg(
        .clk(clk),.rst_n(rst_n),.in_vsync(in_vsync),.in_href(in_href),.in_clken(in_clken),
        .in_x(in_x),.in_y(in_y),.in_pixel(in_rgb[15:8]),
        .out_vsync(),.out_href(),.out_clken(),.out_x(),.out_y(),
        .p11(g11),.p12(g12),.p13(g13),.p21(g21),.p22(g22),.p23(g23),
        .p31(g31),.p32(g32),.p33(g33));
    cartoon_window_3x3_8bit #(.IMG_HDISP(IMG_HDISP)) wb(
        .clk(clk),.rst_n(rst_n),.in_vsync(in_vsync),.in_href(in_href),.in_clken(in_clken),
        .in_x(in_x),.in_y(in_y),.in_pixel(in_rgb[7:0]),
        .out_vsync(),.out_href(),.out_clken(),.out_x(),.out_y(),
        .p11(b11),.p12(b12),.p13(b13),.p21(b21),.p22(b22),.p23(b23),
        .p31(b31),.p32(b32),.p33(b33));
    wire [11:0] rs = ({4'b0,r11}+({4'b0,r12}<<1)+{4'b0,r13})+
                     (({4'b0,r21}+({4'b0,r22}<<1)+{4'b0,r23})<<1)+
                     ({4'b0,r31}+({4'b0,r32}<<1)+{4'b0,r33});
    wire [11:0] gs = ({4'b0,g11}+({4'b0,g12}<<1)+{4'b0,g13})+
                     (({4'b0,g21}+({4'b0,g22}<<1)+{4'b0,g23})<<1)+
                     ({4'b0,g31}+({4'b0,g32}<<1)+{4'b0,g33});
    wire [11:0] bs = ({4'b0,b11}+({4'b0,b12}<<1)+{4'b0,b13})+
                     (({4'b0,b21}+({4'b0,b22}<<1)+{4'b0,b23})<<1)+
                     ({4'b0,b31}+({4'b0,b32}<<1)+{4'b0,b33});
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vsync<=0;out_href<=0;out_clken<=0;out_x<=0;out_y<=0;out_rgb<=0;
        end else begin
            out_vsync<=wv;out_href<=wh;out_clken<=wc;out_x<=wx;out_y<=wy;
            out_rgb <= {rs[11:4],gs[11:4],bs[11:4]};
        end
    end
endmodule

// RGB is delayed to match rgb2ycbcr's three-cycle output before this module.
// Its centre pixels use the same matrix timing as the Sobel grayscale matrix.
module rgb_quantize_4 #(
    parameter [10:0] IMG_HDISP = 11'd1280,
    parameter integer LEVELS = 4,
    parameter integer DIRECT_INPUT = 0
)(
    input wire S_hdmi_pixel_clk, S_hdmi_rst_n,
    input wire [23:0] rgb_in,
    input wire S_ycbcr_vsync, S_ycbcr_de,
    output wire [23:0] S_quant4_center_d3,
    output wire out_vsync, out_de
);
    wire [7:0] center_r, center_g, center_b;
    wire matrix_vsync, matrix_href, matrix_clken;
    reg [23:0] quant_pipe [0:4];
    reg [4:0] vsync_pipe, href_pipe, clken_pipe;
    integer i;
    function [7:0] quant_channel;
        input [7:0] value;
        begin
            if (LEVELS == 8)
                quant_channel = {value[7:5], 5'b10000}; // 16,48,...,240
            else
                quant_channel = {value[7:6], 6'b100000}; // 32,96,160,224
        end
    endfunction
    generate if (DIRECT_INPUT == 0) begin : g_window
    Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .SPARSE_INPUT(1'b0)) u_r (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .per_frame_vsync(S_ycbcr_vsync), .per_frame_href(S_ycbcr_de),
        .per_frame_clken(S_ycbcr_de), .per_img_Y(rgb_in[23:16]),
        .matrix_frame_vsync(matrix_vsync), .matrix_frame_href(matrix_href),
        .matrix_frame_clken(matrix_clken),
        .matrix_p11(), .matrix_p12(), .matrix_p13(), .matrix_p21(),
        .matrix_p22(center_r), .matrix_p23(), .matrix_p31(), .matrix_p32(), .matrix_p33()
    );
    Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .SPARSE_INPUT(1'b0)) u_g (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .per_frame_vsync(S_ycbcr_vsync), .per_frame_href(S_ycbcr_de),
        .per_frame_clken(S_ycbcr_de), .per_img_Y(rgb_in[15:8]),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_clken(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(), .matrix_p21(),
        .matrix_p22(center_g), .matrix_p23(), .matrix_p31(), .matrix_p32(), .matrix_p33()
    );
    Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .SPARSE_INPUT(1'b0)) u_b (
        .clk(S_hdmi_pixel_clk), .rst_n(S_hdmi_rst_n),
        .per_frame_vsync(S_ycbcr_vsync), .per_frame_href(S_ycbcr_de),
        .per_frame_clken(S_ycbcr_de), .per_img_Y(rgb_in[7:0]),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_clken(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(), .matrix_p21(),
        .matrix_p22(center_b), .matrix_p23(), .matrix_p31(), .matrix_p32(), .matrix_p33()
    );
    end else begin : g_direct
        assign center_r = rgb_in[23:16];
        assign center_g = rgb_in[15:8];
        assign center_b = rgb_in[7:0];
        assign matrix_vsync = S_ycbcr_vsync;
        assign matrix_href = S_ycbcr_de;
        assign matrix_clken = S_ycbcr_de;
    end endgenerate
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) begin
            for (i=0; i<5; i=i+1) quant_pipe[i] <= 0;
            vsync_pipe <= 0;
            href_pipe <= 0;
            clken_pipe <= 0;
        end else begin
            quant_pipe[0] <= {quant_channel(center_r), quant_channel(center_g), quant_channel(center_b)};
            for (i=1; i<5; i=i+1) quant_pipe[i] <= quant_pipe[i-1];
            vsync_pipe <= {vsync_pipe[3:0], matrix_vsync};
            href_pipe <= {href_pipe[3:0], matrix_href};
            clken_pipe <= {clken_pipe[3:0], matrix_clken};
        end
    end
    assign S_quant4_center_d3 = DIRECT_INPUT ? quant_pipe[0] : quant_pipe[4];
    assign out_vsync = DIRECT_INPUT ? vsync_pipe[0] : vsync_pipe[4];
    assign out_de = DIRECT_INPUT ? (href_pipe[0] & clken_pipe[0]) :
                                   (href_pipe[4] & clken_pipe[4]);
endmodule
