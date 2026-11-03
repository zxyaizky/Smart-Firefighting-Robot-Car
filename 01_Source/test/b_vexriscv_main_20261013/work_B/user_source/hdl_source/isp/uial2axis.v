/*****************************************************************
Company : Nanjing Weiku Robot Technology Co., Ltd.
Brand   : VLKUS
Technical forum:www.uisrc.com
@Author      :   
@Time        :   2024/11/11
@Description :   native data convert to axi stream 
*****************************************************************/

module uial2axis #(
    parameter IMG_WIDTH        = 1280,
    parameter IMG_HEIGHT       = 720,
    parameter INPUT_DATA_WIDTH = 128
) (
    // native interface
    input I_native_clk,
    input I_rst_n,

    input [INPUT_DATA_WIDTH-1:0] I_data      ,
    input                        I_data_valid,
    input                        I_data_start,
    input                        I_data_end  ,

    output                          axis_tvalid,
    output [INPUT_DATA_WIDTH-1 : 0] axis_tdata,
    output                          axis_tuser,
    output                          axis_tlast,
    output wire                     frame_complete_o
);
/*********************************************************
******************1.function declaration******************
*********************************************************/
  function integer clogb2(input integer bit_depth);
    begin
      for (clogb2 = 0; bit_depth > 0; clogb2 = clogb2 + 1) bit_depth = bit_depth >> 1;
    end
  endfunction
/*********************************************************
******************2.constant declaration******************
*********************************************************/
  localparam IMG_WIDTH_4X = (IMG_WIDTH >> 2);
/*********************************************************
******************3.wire signals declaration**************
*********************************************************/
  // AXI Stream internal signals
/*********************************************************
******************4.reg signals declaration***************
*********************************************************/
  reg [13:0] hcnt;  //synthesis keep  
  reg [13:0] vcnt;  //synthesis keep  
/*********************************************************
******************5.combination declaration***************
*********************************************************/
  // Passive diagnostic output; no feedback into the video stream.
  assign frame_complete_o = (vcnt == IMG_HEIGHT);
  // 0730: IMG_HEIGHT is the completed-frame sentinel. Only native SOF
  // re-arms acquisition; trailing RAW groups must not become another SOF.
  // Native SOF may coincide with the first group: use coordinate (0,0)
  // immediately and advance the counters once for that accepted group.
  assign axis_tdata  = axis_tvalid ? I_data : 'b0;
  assign axis_tvalid = I_data_valid && (I_data_start || vcnt < IMG_HEIGHT);
  assign axis_tlast  = axis_tvalid && ((I_data_start ? 14'd0 : hcnt) == IMG_WIDTH_4X - 1);
  assign axis_tuser  = axis_tvalid && (I_data_start || (vcnt == 14'd0 && hcnt == 14'd0));
/*********************************************************
******************6.sequential declaration****************
*********************************************************/

  always @(posedge I_native_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      hcnt <= 'b0;
    end else if (I_data_start) begin
      hcnt <= (I_data_valid && IMG_WIDTH_4X > 1) ? 14'd1 : 14'd0;
    end else if (axis_tvalid && hcnt < IMG_WIDTH_4X - 1) begin
      hcnt <= hcnt + 1'b1;
    end else if (axis_tvalid && hcnt == IMG_WIDTH_4X - 1) begin
      hcnt <= 'b0;
    end else hcnt <= hcnt;
  end

  always @(posedge I_native_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      vcnt <= 'b0;
    end else if (I_data_start) begin
      vcnt <= (I_data_valid && IMG_WIDTH_4X == 1) ? 14'd1 : 14'd0;
    end else if (axis_tlast && vcnt < IMG_HEIGHT) begin
      vcnt <= vcnt + 14'd1;
    end else vcnt <= vcnt;
  end

endmodule



