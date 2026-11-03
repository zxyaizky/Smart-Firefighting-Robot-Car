/************************************************************\
**	Copyright (c) 2012-2025 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Sep 10 2026 20:44:01
**	TD version	:	6.2.168116
************************************************************/
`timescale 1ns/1ps
module sync_fifo_for_linebufferpool
(
  input                         srst,
  input   [63:0]                di,
  input                         clk,
  input                         re,
  input                         we,
  output  [63:0]                dout,
  output                        empty_flag,
  output                        aempty,
  output                        full_flag,
  output                        afull,
  output                        valid,
  output                        overflow,
  output                        underflow,
  output                        wr_success,
  output  [9:0]                 rdusedw,
  output  [9:0]                 wrusedw,
  output                        wr_rst_done,
  output                        rd_rst_done
);

  soft_fifo_dc793d8cf75c
  #(
      .COMMON_CLK_EN(1),
      .MEMORY_TYPE(0),
      .RST_TYPE(2),
      .DATA_WIDTH_W(64),
      .ADDR_WIDTH_W(9),
      .DATA_WIDTH_R(64),
      .ADDR_WIDTH_R(9),
      .DOUT_INITVAL(64'h0),
      .OUTREG_EN("NOREG"),
      .SHOW_AHEAD_EN(1),
      .AL_FULL_NUM(3),
      .AL_EMPTY_NUM(2),
      .RDUSEDW_WIDTH(10),
      .WRUSEDW_WIDTH(10),
      .ASYNC_RST_SYNC_RELS(0),
      .SYNC_STAGE(2)
  )soft_fifo_dc793d8cf75c_Inst
  (
      .srst(srst),
      .di(di),
      .clk(clk),
      .re(re),
      .we(we),
      .dout(dout),
      .empty_flag(empty_flag),
      .aempty(aempty),
      .full_flag(full_flag),
      .afull(afull),
      .valid(valid),
      .overflow(overflow),
      .underflow(underflow),
      .wr_success(wr_success),
      .rdusedw(rdusedw),
      .wrusedw(wrusedw),
      .wr_rst_done(wr_rst_done),
      .rd_rst_done(rd_rst_done)
  );
endmodule
