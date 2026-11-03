/************************************************************\
**	Copyright (c) 2012-2025 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Sep 10 2026 21:28:52
**	TD version	:	6.2.168116
************************************************************/
`timescale 1ns/1ps
module blk_mem_gen_0
(
  input   [7:0]                 dia,
  input   [10:0]                addra,
  input                         wea,
  input                         clka,
  output  [7:0]                 dob,
  input   [10:0]                addrb,
  input                         rstb
);

  ram_d5bf2e66b253
  #(
      .DATA_WIDTH_A(8),
      .ADDR_WIDTH_A(11),
      .DATA_DEPTH_A(1280),
      .DATA_WIDTH_B(8),
      .ADDR_WIDTH_B(11),
      .DATA_DEPTH_B(1280),
      .REGMODE_A("NOREG"),
      .WRITEMODE_A("NORMAL"),
      .RESETMODE_A("ASYNC"),
      .INIT_FILE("NONE"),
      .REGMODE_B("OUTREG"),
      .FILL_ALL("NONE"),
      .WRITEMODE_B("NORMAL"),
      .RESETMODE_B("ASYNC")
  )ram_d5bf2e66b253_Inst
  (
      .dia(dia),
      .addra(addra),
      .wea(wea),
      .clka(clka),
      .dob(dob),
      .addrb(addrb),
      .rstb(rstb)
  );
endmodule
