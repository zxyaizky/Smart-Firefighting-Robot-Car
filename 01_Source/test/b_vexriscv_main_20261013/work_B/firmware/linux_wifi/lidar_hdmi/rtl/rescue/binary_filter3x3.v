`resetall
`timescale 1ns/1ps
`default_nettype none

// Binary-only line buffers: two bits per column, not an RGB frame buffer.
// MODE 0: majority (>=5/9), 1: erosion (9/9), 2: dilation (>=1/9).
// Uses the existing window generator's replicated horizontal/startup edges.
// Each pass has one row of vertical look-behind; RGB/DE/VS stay aligned.
module binary_filter3x3 #(
    parameter [10:0] IMG_HDISP = 11'd1280,
    parameter integer MODE = 0
) (
    input wire clk, rst,
    input wire pixel_i, de_i, vsync_i,
    output reg pixel_o, de_o, vsync_o
);
    wire window_vs, window_href, window_valid;
    wire p11,p12,p13,p21,p22,p23,p31,p32,p33;
    wire [1:0] row1 = {1'b0,p11} + {1'b0,p12} + {1'b0,p13};
    wire [1:0] row2 = {1'b0,p21} + {1'b0,p22} + {1'b0,p23};
    wire [1:0] row3 = {1'b0,p31} + {1'b0,p32} + {1'b0,p33};
    wire [3:0] count = {2'd0,row1} + {2'd0,row2} + {2'd0,row3};
    wire filtered = MODE == 1 ? count == 4'd9 :
                    MODE == 2 ? count != 4'd0 : count >= 4'd5;
    Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .DATA_WIDTH(1)) u_window (
        .clk(clk), .rst_n(~rst),
        .per_frame_vsync(vsync_i), .per_frame_href(de_i),
        .per_frame_clken(de_i), .per_img_Y(pixel_i),
        .matrix_frame_vsync(window_vs), .matrix_frame_href(window_href),
        .matrix_frame_clken(window_valid),
        .matrix_p11(p11), .matrix_p12(p12), .matrix_p13(p13),
        .matrix_p21(p21), .matrix_p22(p22), .matrix_p23(p23),
        .matrix_p31(p31), .matrix_p32(p32), .matrix_p33(p33)
    );
    always @(posedge clk) begin
        pixel_o <= window_href && window_valid && filtered;
        de_o <= window_href && window_valid;
        vsync_o <= window_vs;
        if (rst) begin pixel_o <= 0; de_o <= 0; vsync_o <= 0; end
    end
endmodule
`resetall
