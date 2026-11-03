
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2022/12/23
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.1
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*******************************rgmii_interfaceģ��*********************
--��������������Ƶ�rgmii_interface������ģ��
��ģ��ʵ����RGMIIתGMII�ӿڣ�֧��10M/100M/1000M����ת��
*********************************************************************/


module rgmii_interface (
// ָʾ��ǰ�����ٶ�Ϊ10/100
input            speed_10_100,   //���õ�ǰ����������
//RGMII����ʱ���������PHY ��������FPGA��TX�źţ�û��ʹ���ڲ�2ns�ӳ������Ҫ��fpga������2ns�ӳ�
input			     gmii_tx_clk_d,    
input			     gmii_tx_reset_d,   
// ���¶˿���RGMII�����ӿڣ���Щ�˿ڽ�λ��FPGA��������
output     [3:0] rgmii_txd,
output           rgmii_tx_ctl,
output           rgmii_txc,

input      [3:0] rgmii_rxd,
input            rgmii_rx_ctl,
input            rgmii_rxc,
// ���¶˿����ӵ� TEMAC�� �� �ڲ�GMII�ӿ�ģ��
input            gmii_tx_reset,
input            gmii_tx_clk,      // ggmii_tx_clk: 125mhz
input      [7:0] gmii_txd,
input            gmii_tx_en,
input            gmii_tx_er,

input            gmii_rx_reset,
output               gmii_rx_clk,    //output�� 125mhz��1gbps�� 25mhz(100mbps)    2.5mhz(10mbps)
output reg    [7:0] gmii_rxd,
output reg          gmii_rx_dv,
output reg          gmii_rx_er,

output           gmii_crs,
output           gmii_col,
// �����ź�ΪRGMII״̬�ź�
output reg       link_status,
output reg [1:0] clock_speed,
output reg       duplex_status
);
//----------------------------------------------------------------------------
// ģ�� �ڲ� �ź�
//----------------------------------------------------------------------------
reg    [3:0] gmii_txd_falling;             // gmii_txd�ź���gmii_tx_clk���½������档
wire         rgmii_txc_odelay;             // RGMII������ʱ��ODDR���.
wire         rgmii_tx_ctl_odelay;          // RGMII�����ź�ODDR���.
wire   [3:0] rgmii_txd_odelay;             // RGMII����ODDR���.
wire         rgmii_tx_ctl_int;             // �ڲ�RGMII��������ź�.
wire         rgmii_rx_ctl_delay;
wire   [3:0] rgmii_rxd_delay;
wire         rgmii_rx_ctl_reg;             // �ڲ�RGMII�����������ź�.

reg          tx_en_to_ddr;

wire         gmii_rx_dv_reg;               
wire         gmii_rx_er_reg;               
wire   [7:0] gmii_rxd_reg;                 

wire         inband_ce;                    //RGMII����״̬�Ĵ��� ʹ������ź�
wire         rgmii_rxc_int;


//==============================================================================
// RGMII �����߼�
//==============================================================================

//----------------------------------------------------------------------------
// RGMII ������ʱ�ӹ�����rgmii_txc
//----------------------------------------------------------------------------
// ���� rgmii_txc ʱ��.
//PH1P_LOGIC_HD_ODDR  rgmii_txc_ddr 
//(
//.q             (rgmii_txc_odelay), //output 125mhz��1gbps�� 25mhz(100mbps)    2.5mhz(10mbps)
//.clk           (gmii_tx_clk_d),
//.d0            (1'b1),
//.d1            (1'b0),
//.rst           (gmii_tx_reset_d)
//);

// ��ʱ���2ns,�Ա㽫ʱ�ӱ��ؼ�����rgmii_txd [3��0]��Ч�����ڡ�����0.285ns
// EG_LOGIC_ODELAY 
// #(
// .OUTDEL  (1)
// )
// delay_rgmii_gmii_tx_clk 
// (
// .i       (rgmii_txc_odelay),
// .o       (rgmii_txc)     //output 125mhz��1gbps�� 25mhz(100mbps)    2.5mhz(10mbps)
// );
PH1P_LOGIC_HD_ODDR  rgmii_txc_ddr 
(
.q             (rgmii_txc_odelay), //output 125mhz��1gbps�� 25mhz(100mbps)    2.5mhz(10mbps)
.clk           (gmii_tx_clk_d),
.d0            (1'b1),
.d1            (1'b0),
.rst           (gmii_tx_reset_d)
);

/*
PH1P_LOGIC_HR_OSERDES  rgmii_txc_ddr 
(
.sclk			(gmii_tx_clk_d),
.pclk			(gmii_tx_clk_d),
.rst			(gmii_tx_reset_d),
.idata			({1'b0,1'b1}),
.odata			(rgmii_txc_odelay)
);  
*/
assign rgmii_txc = rgmii_txc_odelay;
   
//---------------------------------------------------------------------------
// RGMII �����߼� : rgmii_txd
//---------------------------------------------------------------------------
// 1Gbps gmii_txd  8λ��Ч; rgmii_txc˫��ʹ�ܷ���8λ
// 10/100Mbps gmii_txd ������λ��Ч��rgmii_txc˫��ʹ���ظ����͵���λ
// 1Gbpsʱ��125mhz��rgmii_txc�������ط��͵���λ���½��ط��͸���λ�� һ��ʱ������8bit, 125*8=1Gbps
// 100Mbpsʱ��25mhz��rgmii_txc�������ط��͵���λ���½��ط��͵���λ�� �൱��һ��ʱ������ֻ��һ��4bit, 25*4=100mbps
// 10Mbpsʱͬ100mbps,������Чλ��ÿbyte�ĵ���λ����Ȼһ��ʱ�������ظ�������λ���൱��һ��ʱ������ֻ��һ����4λ��
    
always @ (speed_10_100, gmii_txd)begin
   if (speed_10_100 == 1'b0) // 1Gbps gmii_txd  8λ��Ч
      gmii_txd_falling     <= gmii_txd[7:4];
   else      // 10/100Mbps gmii_txd����λ��Ч��rgmii_txc˫��ʹ�ܷ��͵���λ
      gmii_txd_falling     <= gmii_txd[3:0];
end

genvar i;
generate for (i=0; i<4; i=i+1)begin : txdata_out_bus

PH1P_LOGIC_HD_ODDR  rgmii_txd_out 
(
.q             (rgmii_txd_odelay[i]),
.clk           (gmii_tx_clk),
.d0            (gmii_txd[i]),
.d1            (gmii_txd_falling[i]),
.rst           (gmii_tx_reset)
);

// �ӳ���� 2 ns�� ���棺0.175ns
// EG_LOGIC_ODELAY 
// #(
// .OUTDEL  (0)
// )
// delay_rgmii_txd (
// .i  (rgmii_txd_odelay[i]),
// .o       (rgmii_txd[i])
// );
/*
	PH1P_LOGIC_HR_OSERDES rgmii_txd_out(
	  	.sclk			(gmii_tx_clk),
	  	.pclk			(gmii_tx_clk),
	  	.rst			(gmii_tx_reset),
	  	.idata			({gmii_txd_falling[i],gmii_txd[i]}),
	  	.odata			(rgmii_txd_odelay[i])
	);
*/
assign rgmii_txd[i] = rgmii_txd_odelay[i];
end
endgenerate


//---------------------------------------------------------------------------
// RGMII �����߼� : rgmii_tx_ctl
//---------------------------------------------------------------------------
// ���� rgmii ctl �ź�
assign rgmii_tx_ctl_int = gmii_tx_en ^ gmii_tx_er;

// ��Ҫ�߼���ȷ�� �����ź� ��������ʱ����λ�ڣ���tx_ctl����Ϊ�͵�ƽ
always @(speed_10_100 or gmii_tx_en or gmii_tx_er)begin
   if (speed_10_100)
      tx_en_to_ddr = gmii_tx_en & (!gmii_tx_er );
   else
      tx_en_to_ddr = gmii_tx_en;
end
    
// oDDR primitive
PH1P_LOGIC_HD_ODDR  ctl_output 
(
.q             (rgmii_tx_ctl_odelay),
.clk           (gmii_tx_clk),
.d0            (tx_en_to_ddr),
.d1            (rgmii_tx_ctl_int),
.rst           (gmii_tx_reset)
);

// �ӳ���� 2 ns�� ���棺0.175ns
// EG_LOGIC_ODELAY 
// #(
// .OUTDEL  (0)
// )
// delay_rgmii_tx_ctl 
// (
// .i       (rgmii_tx_ctl_odelay),
// .o       (rgmii_tx_ctl)
// );
/*
	PH1P_LOGIC_HR_OSERDES  ctl_output
	(
	  	.sclk			(gmii_tx_clk),
	  	.pclk			(gmii_tx_clk),
	  	.rst			(gmii_tx_reset),
	  	.idata			({rgmii_tx_ctl_int,tx_en_to_ddr}),
	  	.odata			(rgmii_tx_ctl_odelay)
	);
*/
assign rgmii_tx_ctl = rgmii_tx_ctl_odelay;

//==============================================================================
// RGMII �����߼�
//==============================================================================

//---------------------------------------------------------------------------
// RGMII �����߼���rgmii_rxc
//---------------------------------------------------------------------------
/*
PH1P_PHY_IOCLK u_rgmii_rxc_int 
(
.clkin (rgmii_rxc),
.clkout (rgmii_rxc_int)
);
*/
PH1P_LOGIC_BUFG u_LOGIC_BUFG
(
.o(rgmii_rxc_int),
.i(rgmii_rxc)
);

/*
PH1P_PHY_SCLK u_rgmii_rxc 
(
.ce(1'b1),
.clkin (rgmii_rxc),
.clkout (gmii_rx_clk)
);
*/
PH1P_PHY_LCLK u_gmii_rx_clk
(
.ce        (1'b1        ),
.clkin     (rgmii_rxc   ),
.rst       (1'b0        ),
.clkout    (gmii_rx_clk ),
.clkdivout (     )
);

/*
ʹ�����´������ʵ��ͨ�ţ����Ǵ��ڶ���
PH1_PHY_SCLK_V2 u_rgmii_rxc 
(
.ce(1'b1),
.clkin (rgmii_rxc),
.clkout (gmii_rx_clk)
);

assign	rgmii_rxc_int = gmii_rx_clk;      ////input 125mhz��1gbps�� 25mhz(100mbps)    2.5mhz(10mbps)
*/
//assign   gmii_rx_clk  = rgmii_rxc_int;  // �ڲ��źŸ�������˿�
   
   
//---------------------------------------------------------------------------
// RGMII �����߼���rgmii_rxd ---->  gmii_rxd_reg
//---------------------------------------------------------------------------
// 1Gbps gmii_rxd  8λ��Ч; rgmii_rxc˫��ʹ�ܽ���8λ
// 10/100Mbps gmii_rxd ������λ��Ч��rgmii_rxc˫��ʹ�ܽ��ոߵ���λ������ͬ
// 1gbpsʱ��125mhz��rgmii_rxc�������ؽ�����λ���ݣ���Ӧ��4bit�����½��ؽ�����λ���ݣ���Ӧ��4bit���� һ��ʱ������8bit, 125mhz*8=1gbps
// 100mbpsʱ��25mhz��rgmii_rxc�������ؽ�����λ���ݣ��½��ؽ�����λ���ݣ�����λ�͵���λ������ͬ���� �൱�ڵ��ز�����һ��ʱ������ֻ��һ��4bit��������Чλ��ÿbyte�ĵ���λ���ߵ���λ�ظ���, 25mhz*4=100mbps
// 10mbpsʱͬ100mbps,��Ȼһ��ʱ�������������ظ�������ͬ��λ���ݣ��൱��һ��ʱ������ֻ��һ��4bit��

genvar j;
generate for (j=0; j<4; j=j+1)begin : rxdata_bus
	
// EG_LOGIC_IDELAY delay_rgmii_rxd 
// (
// .i       (rgmii_rxd[j]),
// .o       (rgmii_rxd_delay[j])
// );

assign rgmii_rxd_delay[j]=rgmii_rxd[j];
end
endgenerate

// Instantiate Double Data Rate Input flip-flops.
// DDR_CLK_EDGE attribute specifies output data alignment from IDDR component
genvar k;
generate for (k=0; k<4; k=k+1)begin : rxdata_in_bus 
PH1P_LOGIC_HD_IDDR rgmii_rx_data_in 
(
.q0            (gmii_rxd_reg[k]),
.q1            (gmii_rxd_reg[k+4]),
.clk           (rgmii_rxc_int),
.d             (rgmii_rxd_delay[k]),
.rst           (1'b0)
);
/*
	PH1P_LOGIC_HR_ISERDES #(
        .IDDRMODE	("DDRX1_PIPE")
    )
    rgmii_rx_data_in 
    (
  		.sclk     (rgmii_rxc_int),
  		.pclk     (rgmii_rxc_int),
  		.rst      (1'b0),
  		.idata    (rgmii_rxd_delay[k]),
  		.odata    ({gmii_rxd_reg[k+4],gmii_rxd_reg[k]})
  	);
*/
     
end
endgenerate
   
//---------------------------------------------------------------------------
// RGMII �����߼���rgmii_rx_ctl ------> gmii_rx_dv��gmii_rx_er
//---------------------------------------------------------------------------
	
// EG_LOGIC_IDELAY delay_rgmii_rx_ctl 
// (
// .i       (rgmii_rx_ctl),
// .o       (rgmii_rx_ctl_delay)
// );
assign rgmii_rx_ctl_delay = rgmii_rx_ctl;
 
PH1P_LOGIC_HD_IDDR rgmii_rx_ctl_in 
(
.q0            (gmii_rx_dv_reg),
.q1            (rgmii_rx_ctl_reg),
.clk           (rgmii_rxc_int),
.d             (rgmii_rx_ctl_delay),
.rst           (1'b0)
);

/*
	PH1P_LOGIC_HR_ISERDES #(
        .IDDRMODE	("DDRX1_PIPE")
    )
    rgmii_rx_ctl_in 
    (
  		.sclk     (rgmii_rxc_int),
  		.pclk     (rgmii_rxc_int),
  		.rst      (1'b0),
  		.idata    (rgmii_rx_ctl_delay),
  		.odata    ({rgmii_rx_ctl_reg,gmii_rx_dv_reg})
  	);
*/

// ���� gmii_rx_er signal
assign gmii_rx_er_reg = gmii_rx_dv_reg ^ rgmii_rx_ctl_reg;


//----------------------------------------------------------------------------
// �����߼����ڲ��źŸ�������˿ڣ�gmii_rxd��gmii_rx_dv��gmii_rx_er��gmii_col��gmii_crs
//----------------------------------------------------------------------------

//assign gmii_rxd      = gmii_rxd_reg;
//assign gmii_rx_dv    = gmii_rx_dv_reg;
//assign gmii_rx_er    = gmii_rx_er_reg;

always @ (posedge gmii_rx_clk  )begin
gmii_rxd      <= gmii_rxd_reg;
gmii_rx_dv    <= gmii_rx_dv_reg;
gmii_rx_er    <= gmii_rx_er_reg;    
end

// ��RGMII����GMII��ʽ�ĳ�ͻ���ز������ź� 
assign gmii_col = (gmii_tx_en | gmii_tx_er) & (gmii_rx_dv_reg | gmii_rx_er_reg);
assign gmii_crs = (gmii_tx_en | gmii_tx_er) | (gmii_rx_dv_reg | gmii_rx_er_reg);
  
  

//==============================================================================
// RGMII ״̬�Ĵ���
//==============================================================================

// ��֡�����ڼ����ô���״̬�Ĵ���
   
assign inband_ce = !(gmii_rx_dv_reg || gmii_rx_er_reg);

always @ (posedge gmii_rx_clk  or posedge gmii_rx_reset)begin
   if (gmii_rx_reset) begin
      link_status          <= 1'b0;
      clock_speed[1:0]     <= 2'b0;
      duplex_status        <= 1'b0;
   end
   else if (inband_ce) begin
      link_status          <= gmii_rxd_reg[0];
      clock_speed[1:0]     <= gmii_rxd_reg[2:1];
      duplex_status        <= gmii_rxd_reg[3];
   end
end


endmodule


