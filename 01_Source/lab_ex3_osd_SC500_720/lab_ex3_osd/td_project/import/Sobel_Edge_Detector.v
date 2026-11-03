module Sobel_Edge_Detector #(
    parameter [10:0] IMG_HDISP = 11'd1280,
    parameter       SPARSE_INPUT = 1'b0,
    parameter [10:0]  FIXED_THRESHOLD = 11'd80,
    parameter [10:0]  EDGE_LOW = 11'd100,
    parameter [10:0]  EDGE_HIGH = FIXED_THRESHOLD
)(
    input   clk,    //cmos 像素时钟
    input   rst_n,
    //预�?�理数据
    input       per_frame_vsync,
    input       per_frame_href,
    input       per_frame_clken,
    input [7:0] per_img_Y,
    input [10:0] per_x, per_y,
    //处理后的数据
    output      post_frame_vsync,
    output      post_frame_href,
    output      post_frame_clken,
    output      post_img_Bit,
    output      post_img_Weak,
    output [10:0] post_x, post_y,
    output [10:0] post_grad
);
//reg define
reg [9:0]  Gx_temp2; //�?三列�?
reg [9:0]  Gx_temp1; //�?一列�?
reg [9:0]  Gx_data;  //x方向的偏导数
reg [9:0]  Gy_temp1; //�?一行�?
reg [9:0]  Gy_temp2; //�?三�?��?
reg [9:0]  Gy_data;  //y方向的偏导数
reg [10:0] Gxy_sum;
reg [3:0]  per_frame_vsync_r;
reg [3:0]  per_frame_href_r;
reg [3:0]  per_frame_clken_r;
reg        post_img_Bit_r;
reg        post_img_Weak_r;
reg [10:0] post_grad_r;
reg [10:0] x_r[0:3], y_r[0:3];
integer ci;

//wire define
wire        matrix_frame_vsync;
wire        matrix_frame_href;
wire        matrix_frame_clken;
wire [10:0] matrix_x, matrix_y;
//输出3X3 矩阵
wire [7:0]  matrix_p11;
wire [7:0]  matrix_p12;
wire [7:0]  matrix_p13;
wire [7:0]  matrix_p21;
wire [7:0]  matrix_p22;
wire [7:0]  matrix_p23;
wire [7:0]  matrix_p31;
wire [7:0]  matrix_p32;
wire [7:0]  matrix_p33;

assign post_frame_vsync = per_frame_vsync_r[3];
assign post_frame_href  = per_frame_href_r[3] ;
assign post_frame_clken = per_frame_clken_r[3];
assign post_img_Bit =(post_frame_href && post_frame_clken) ? post_img_Bit_r : 1'b0;
assign post_img_Weak = (post_frame_href && post_frame_clken) ? post_img_Weak_r : 1'b0;
assign post_x = x_r[3];
assign post_y = y_r[3];
assign post_grad = post_grad_r;


//3x3矩阵
cartoon_window_3x3_8bit #(.IMG_HDISP(IMG_HDISP))
u_cartoon_window_3x3_8bit(
    .clk  (clk),
    .rst_n  (rst_n),
    //预�?�理数据
    .in_vsync (per_frame_vsync),
    .in_href  (per_frame_href),
    .in_clken (per_frame_clken),
    .in_x(per_x), .in_y(per_y), .in_pixel(per_img_Y),

    //处理后的数据
    .out_vsync (matrix_frame_vsync),
    .out_href  (matrix_frame_href),
    .out_clken (matrix_frame_clken),
    .out_x(matrix_x), .out_y(matrix_y),
    .p11(matrix_p11), .p12(matrix_p12), .p13(matrix_p13),
    .p21(matrix_p21), .p22(matrix_p22), .p23(matrix_p23),
    .p31(matrix_p31), .p32(matrix_p32), .p33(matrix_p33)
);

//Sobel 算子
//         Gx                  Gy                  像素�?
// [   -1  0   +1  ]   [   +1  +2   +1 ]     [   P11  P12   P13 ]
// [   -2  0   +2  ]   [   0   0    0  ]     [   P21  P22   P23 ]
// [   -1  0   +1  ]   [   -1  -2   -1 ]     [   P31  P32   P33 ]

//Step 1 计算y方向的偏导数
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        Gy_temp1 <= 10'd0;
        Gy_temp2 <= 10'd0;
        Gy_data <=  10'd0;
    end
    else begin
        Gy_temp1 <=
      {2'b0, matrix_p13} + ({2'b0, matrix_p23} << 1) + {2'b0, matrix_p33};

        Gy_temp2 <=
      {2'b0, matrix_p11} + ({2'b0, matrix_p21} << 1)+ {2'b0, matrix_p31};

        Gy_data <= (Gy_temp1 >= Gy_temp2) ? Gy_temp1 - Gy_temp2 :
                   (Gy_temp2 - Gy_temp1);
    end
end

//Step 2 计算x方向的偏导数
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        Gx_temp1 <= 10'd0;
        Gx_temp2 <= 10'd0;
        Gx_data <=  10'd0;
    end
    else begin
    Gx_temp1 <=
      {2'b0, matrix_p11}+ ({2'b0, matrix_p12} << 1)+ {2'b0, matrix_p13};

    Gx_temp2 <=
      {2'b0, matrix_p31}+ ({2'b0, matrix_p32} << 1)+ {2'b0, matrix_p33};
        Gx_data <= (Gx_temp1 >= Gx_temp2) ? Gx_temp1 - Gx_temp2 :
                   (Gx_temp2 - Gx_temp1);
    end
end

//Step 3 计算�?
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        Gxy_sum <= 11'd0;
    else
        Gxy_sum <= (Gx_data >= Gy_data) ?
                   ({1'b0,Gx_data} + ({1'b0,Gy_data} >> 1)) :
                   ({1'b0,Gy_data} + ({1'b0,Gx_data} >> 1));
end



//Step 4 将相加后的数�?与�?��?�阈值比�?
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        begin post_img_Bit_r <= 1'b0; post_img_Weak_r <= 1'b0; post_grad_r <= 0; end
    else begin
        post_img_Bit_r <= (Gxy_sum >= EDGE_HIGH);
        post_img_Weak_r <= (Gxy_sum >= EDGE_LOW) && (Gxy_sum < EDGE_HIGH);
        post_grad_r <= Gxy_sum;
    end
end

//延迟4�?周期同�??
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        per_frame_vsync_r <= 0;
        per_frame_href_r <= 0;
        per_frame_clken_r <= 0;
        for (ci=0;ci<4;ci=ci+1) begin x_r[ci]<=0; y_r[ci]<=0; end
    end
    else begin
        per_frame_vsync_r  <=  {per_frame_vsync_r[2:0],matrix_frame_vsync};
        per_frame_href_r  <=  {per_frame_href_r[2:0],matrix_frame_href};
        per_frame_clken_r  <=  {per_frame_clken_r[2:0],matrix_frame_clken};
        x_r[0]<=matrix_x; y_r[0]<=matrix_y;
        for (ci=1;ci<4;ci=ci+1) begin x_r[ci]<=x_r[ci-1]; y_r[ci]<=y_r[ci-1]; end
    end
end

endmodule
