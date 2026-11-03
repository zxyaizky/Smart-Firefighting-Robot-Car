`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/12/04 22:02:46
// Design Name: 
// Module Name: rgb2ycbcr
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module rgb2ycbcr(
    input           pclk,
    input           sys_rst_n,

    input [7:0]     rgb888_r,
    input [7:0]     rgb888_g,
    input [7:0]     rgb888_b,

    input           pre_video_hsync,
    input           pre_video_vsync,
    input           pre_video_de,     
    input	wire [10:0]			i_x_pos,
	input	wire [10:0] 		i_y_pos,

    output          post_video_hsync,
    output          post_video_vsync,
    output          post_video_de,   
    output          [10:0]post_i_x_pos,
    output          [10:0]post_i_y_pos,
    output [7:0]    img_y,
    output [7:0]    img_cb,
    output [7:0]    img_cr              
    );




// Use spare DSP multipliers for the exact weights; preserve pipeline registers.
(* dsp_style = "yes" *) wire [15:0] red_mul77,green_mul150,blue_mul29;
 assign red_mul77=rgb888_r * 8'd77;
 assign green_mul150=rgb888_g * 8'd150;
 assign blue_mul29=rgb888_b * 8'd29;
 /*****reg******/
    reg [15:0]rgb_r_m0,rgb_r_m1,rgb_r_m2;
    reg [15:0]rgb_g_m0,rgb_g_m1,rgb_g_m2;
    reg [15:0]rgb_b_m0,rgb_b_m1,rgb_b_m2;

    reg [15:0]img_y_0;
    reg [15:0]img_cb_0;
    reg [15:0]img_cr_0;
    
    reg [7:0]img_y_1;
    reg [7:0]img_cb_1;
    reg [7:0]img_cr_1;

    reg [2:0]pre_video_hsync_d;
    reg [2:0]pre_video_vsync_d;
    reg [2:0]pre_video_de_d;  



    reg [10:0]			i_x_pos_d0;
	reg [10:0] 		    i_y_pos_d0;
    reg [10:0]			i_x_pos_d1;
	reg [10:0] 		    i_y_pos_d1;

    reg [10:0]			i_x_pos_d2;
	reg [10:0] 		    i_y_pos_d2;

    assign post_video_hsync=pre_video_hsync_d[2];
    assign post_video_vsync=pre_video_vsync_d[2];
    assign post_i_x_pos=i_x_pos_d2;
    assign post_i_y_pos=i_y_pos_d2;    
    assign post_video_de=pre_video_de_d[2];
    assign img_y=post_video_de?img_y_1:8'd0;
    assign img_cb=post_video_de?img_cb_1:8'd0;
    assign img_cr=post_video_de?img_cr_1:8'd0;

    always @(posedge pclk or negedge sys_rst_n)begin
        if(!sys_rst_n)begin
            rgb_r_m0<=16'd0;
            rgb_r_m1<=16'd0;
            rgb_r_m2<=16'd0;
            rgb_g_m0<=16'd0;
            rgb_g_m1<=16'd0;
            rgb_g_m2<=16'd0;
            rgb_b_m0<=16'd0;
            rgb_b_m1<=16'd0;
            rgb_b_m2<=16'd0;
        end
       else begin
            rgb_r_m0 <= red_mul77;
            rgb_r_m1 <= rgb888_r * 8'd43;
            rgb_r_m2 <= {1'b0, rgb888_r, 7'b0};

            rgb_g_m0 <= green_mul150;
            rgb_g_m1 <= rgb888_g * 8'd85;
            rgb_g_m2 <= rgb888_g * 8'd107;

            rgb_b_m0 <= blue_mul29;
            rgb_b_m1 <= {1'b0, rgb888_b, 7'b0};
            rgb_b_m2 <= rgb888_b * 8'd21;
end
    end

    always @(posedge pclk or negedge sys_rst_n)begin
        if(!sys_rst_n)begin
            img_y_0<=16'd0;
            img_cb_0<=16'd0;
            img_cr_0<=16'd0;      
        end
        else begin
            img_y_0<=rgb_r_m0+rgb_b_m0+rgb_g_m0;
            img_cb_0<=rgb_b_m1-rgb_g_m1-rgb_r_m1+16'd32768;
            img_cr_0<=rgb_r_m2-rgb_g_m2-rgb_b_m2+16'd32768; 
        end
    end     

    always @(posedge pclk or negedge sys_rst_n)begin
        if(!sys_rst_n)begin
            img_y_1 <=8'd0;
            img_cb_1<=8'd0;
            img_cr_1<=8'd0;
        end
        else begin
            img_y_1 <=img_y_0[15:8];
            img_cb_1<=img_cb_0[15:8];
            img_cr_1<=img_cr_0[15:8];
        end
    end

    always @(posedge pclk or negedge sys_rst_n)begin
        if(!sys_rst_n)begin
            pre_video_hsync_d<=3'd0;
            pre_video_vsync_d<=3'd0;
            pre_video_de_d   <=3'd0;
    		i_x_pos_d0<=11'd0;
	        i_y_pos_d0<=11'd0;
            i_x_pos_d1<=11'd0;
	        i_y_pos_d1<=11'd0;
            i_x_pos_d2<=11'd0;
	        i_y_pos_d2<=11'd0;
        end
        else begin
            pre_video_hsync_d<={pre_video_hsync_d[1:0],pre_video_hsync};
            pre_video_vsync_d<={pre_video_vsync_d[1:0],pre_video_vsync};
            pre_video_de_d   <={pre_video_de_d[1:0],pre_video_de};
            i_x_pos_d0<=i_x_pos;
	        i_y_pos_d0<=i_y_pos;
            i_x_pos_d1<=i_x_pos_d0;
            i_y_pos_d1<=i_y_pos_d0;
            i_x_pos_d2<=i_x_pos_d1;
            i_y_pos_d2<=i_y_pos_d1;
        end
    end
endmodule
