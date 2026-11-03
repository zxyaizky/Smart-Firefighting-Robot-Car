/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2024-06-22
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

/*******************************uiip_arp_rxģ��*********************
--��������������Ƶ�uiip_arp_rxģ��
1.��ģ���������ֽ���������IP������ARP��
*********************************************************************/
`timescale 1ns/1ps
module	uiip_arp_rx
(
	input	wire				I_ip_arp_reset,		//��λ
	input	wire				I_ip_arp_rclk,		//RX ����ʱ��
	output	wire				O_ip_rvalid,		//���յ���ЧIP�ź�
	output	wire	[7:0]		O_ip_rdata,			//���յ�IP����
	output	wire				O_arp_rvalid,		//���յ���ЧARP�ź�
	output	wire	[7:0]		O_arp_rdata,		//���յ���ЧARP����

	input	wire				I_mac_rvalid,		//MAC���յ���������Ч�ź�
	input	wire	[7:0]		I_mac_rdata,		//MAC���յ���Ч����
	input	wire	[15:0]		I_mac_rdata_type	//MAC���յ���֡����

);




reg					ip_rx_data_valid;	//���յ���ЧIP�ź�
reg		[7:0]		ip_rx_data;			//���յ�IP����
reg					arp_rx_data_valid;	//���յ���ЧARP�ź�
reg		[7:0]		arp_rx_data;		//���յ���ЧARP����

assign	O_ip_rvalid		=	ip_rx_data_valid;
assign	O_ip_rdata		=	ip_rx_data;
assign	O_arp_rvalid	=	arp_rx_data_valid;
assign	O_arp_rdata		=	arp_rx_data;

localparam	ARP_TYPE	=	16'h0806;	//ARP������
localparam	IP_TYPE		=	16'h0800;	//IP ������


always@(posedge I_ip_arp_rclk or posedge I_ip_arp_reset) begin
	if(I_ip_arp_reset) begin
		ip_rx_data_valid	<=	1'b0;
		ip_rx_data			<=	8'd0;
		arp_rx_data_valid	<=	1'b0;
		arp_rx_data			<=	8'd0;
	end
	else if(I_mac_rvalid) begin
		if(I_mac_rdata_type == IP_TYPE) begin//IP��
			ip_rx_data_valid	<=	1'b1;
			ip_rx_data			<=	I_mac_rdata;
		end
		else if(I_mac_rdata_type == ARP_TYPE) begin//ARP��
			arp_rx_data_valid	<=	1'b1;
			arp_rx_data			<=	I_mac_rdata;
		end
		else begin
			ip_rx_data_valid	<=	1'b0;
			ip_rx_data			<=	8'd0;
			arp_rx_data_valid	<=	1'b0;
			arp_rx_data			<=	8'd0;
		end
	end
	else begin
		ip_rx_data_valid	<=	1'b0;
		ip_rx_data			<=	8'd0;
		arp_rx_data_valid	<=	1'b0;
		arp_rx_data			<=	8'd0;
	end
end

endmodule

