module mode_select(
    input key_out,
    input clk,
    input rst,
    input [23:0]S_quant4_center_out,
    input S_quant4_vsync,
    input S_quant4_de,
    input [23:0]S_hdmi_out_data,
    input [7:0]S_img_y,
    input [23:0]S_sobel_rgb,
    input [7:0]S_median_y,
    input [23:0]S_motion_rgb,
    input [23:0]S_motion_diff_rgb,
    input S_ycbcr_vsync,
    input S_ycbcr_de,
    input S_sobel_de,
    input S_sobel_vsync,
    input S_median_de,
    input S_median_vsync,
    input S_motion_vsync,
    input S_motion_de,
    input S_hdmi_out_vsync,
    input S_hdmi_out_de,

    output reg mode_select_vsync,
    output reg mode_select_de,
    output reg [23:0]data,
    output wire [2:0] O_algorithm_mode
 );


reg key_out_d1;
reg [2:0]cnt ;
reg S_hdmi_out_vsync_d1;
reg [2:0]cnt_vaild ;

assign O_algorithm_mode = cnt_vaild;

always@(posedge clk or negedge rst)begin
    if(!rst)begin
        key_out_d1<=0;
        S_hdmi_out_vsync_d1<=0;
    end else begin
        key_out_d1<=key_out;
        S_hdmi_out_vsync_d1<=S_hdmi_out_vsync;
    end

end

always@(posedge clk or negedge rst)begin
    if(!rst)
       cnt<=3'd0;
    else if((!key_out_d1)&&(key_out))begin
        if(cnt<6)
            cnt<=cnt+1;
        else
            cnt<=0;
end

end


always@(posedge clk or negedge rst)begin
    if(!rst)begin
        cnt_vaild<=0;
    end
    else if((!S_hdmi_out_vsync_d1)&&(S_hdmi_out_vsync))begin
        cnt_vaild<=cnt;
    end
    end

always@(posedge clk or negedge rst)begin
    if(!rst)begin
        data<=24'd0;
        mode_select_vsync<=1'b0;    
        mode_select_de<=1'b0;
    end
    else begin
    case(cnt_vaild)
        3'd0:begin    data <=S_hdmi_out_data;      mode_select_vsync<=S_hdmi_out_vsync;    mode_select_de<=S_hdmi_out_de;end
        3'd1:begin    data <={3{S_img_y}};         mode_select_vsync<=S_ycbcr_vsync;       mode_select_de<=S_ycbcr_de;end
        3'd2:begin    data <={3{S_median_y}};      mode_select_vsync<=S_median_vsync;      mode_select_de<=S_median_de;end
        3'd3:begin    data <=S_sobel_rgb;          mode_select_vsync<=S_sobel_vsync;       mode_select_de<=S_sobel_de;end
        3'd4:begin    data <=S_quant4_center_out;  mode_select_vsync<=S_quant4_vsync;      mode_select_de<=S_quant4_de;end
        3'd5:begin    data <=S_motion_rgb;          mode_select_vsync<=S_motion_vsync;      mode_select_de<=S_motion_de;end
        3'd6:begin    data <=S_motion_diff_rgb;     mode_select_vsync<=S_motion_vsync;      mode_select_de<=S_motion_de;end
        default:begin data <=S_hdmi_out_data;      mode_select_vsync<=S_hdmi_out_vsync;    mode_select_de<=S_hdmi_out_de;end
endcase
    end
end


endmodule
