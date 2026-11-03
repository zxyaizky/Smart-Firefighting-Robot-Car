module line_shift_RAM_8bit(
    input clock,
    
    input          clken,
    input          per_frame_href,
    
    input   [7:0]  shiftin,  
    output  [7:0]  taps0x,   
    output  [7:0]  taps1x    
);

//reg define
reg  [2:0]  clken_dly;
reg  [10:0]  ram_rd_addr;
reg  [10:0]  ram_rd_addr_d0;
reg  [10:0]  ram_rd_addr_d1;
reg  [10:0]  ram_rd_addr_d2;
reg  [10:0]  ram_rd_addr_d3;
reg  [7:0]  shiftin_d0;
reg  [7:0]  shiftin_d1;
reg  [7:0]  shiftin_d2;
reg  [7:0]  taps0x_d0;



//*****************************************************
//**                    main code
//*****************************************************

//在数�???来到时，ram地址�???�???
always@(posedge clock)begin
    if(per_frame_href)
        if(clken)
            ram_rd_addr <= ram_rd_addr + 1 ;
        else
            ram_rd_addr <= ram_rd_addr ;
    else
        ram_rd_addr <= 0 ;
end

//时钟使能信号延迟三拍
always@(posedge clock) begin
    clken_dly <= { clken_dly[1:0] , clken };
end


//将ram地址延迟2�???
always@(posedge clock ) begin
    ram_rd_addr_d0 <= ram_rd_addr;
    ram_rd_addr_d1 <= ram_rd_addr_d0;
end

//输入数据延迟三拍
always@(posedge clock)begin
    shiftin_d0 <= shiftin;
    shiftin_d1 <= shiftin_d0;
    shiftin_d2 <= shiftin_d1;
end

//用于存储前一行图像的RAM
blk_mem_gen_0  u_ram_1280x8_1(
    .dia      (shiftin_d2),     //在延迟的�???三个时钟周期，当前�?�的数据写入RAM0
    .clka     (clock),
    .addrb (ram_rd_addr),
    .addra (ram_rd_addr_d1),
    .wea     (clken_dly[2]),
    .dob        (taps0x)  ,        //延迟一�???时钟周期，输出RAM0�???前一行图像的数据
    .rstb       (1'b0)
);  


//寄存一次前一行图像的数据
always@(posedge clock ) begin
    taps0x_d0 <= taps0x;
end

//用于存储前前一行图像的RAM
blk_mem_gen_0  u_ram_1280x8_2(
    .dia      (taps0x_d0),     //在延迟的�???二个时钟周期，将前一行图像的数据写入RAM1
    .clka      (clock     ),
    .addra (ram_rd_addr_d0),
    .wea     (clken_dly[1]),    
    
    .addrb (ram_rd_addr),
    .dob       (taps1x),           //延迟一�???时钟周期，输出RAM1�???前前一行图像的数据
    .rstb       (1'b0)
);

endmodule 