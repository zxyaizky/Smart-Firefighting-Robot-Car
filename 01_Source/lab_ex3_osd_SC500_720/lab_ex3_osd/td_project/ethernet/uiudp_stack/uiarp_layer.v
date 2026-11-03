/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2024-06-24
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

/*******************************uiarp_layerģ��*********************
--��������������Ƶ�uiarp_layer������ģ��
--1.
*********************************************************************/
`timescale 1ns/1ps
module	uiarp_layer
(
	input	wire	[47:0]		I_mac_local_addr,
	input	wire	[31:0]		I_ip_local_addr,

	input	wire				I_arp_clk,
	input	wire				I_arp_reset,
	//ip_arp_tx�ڷ���ip��(udp��icmp)��ʱ��û�в�ѯ��cache�е�mac����ʹ��arp_req_en�źţ�֪ͨarp�㣬����arp�����Զ������
	input	wire				I_arp_treq_en,		//ip_arp_tx�ڷ���arp����ʹ��	
	input	wire	[31:0]		I_arp_tip_addr,		//ip_arp_tx����ip��ַ
	input	wire				I_arp_tbusy,		//ip_arp_tx����arp��æ
	output	wire				O_arp_treq,			//����arp����ip_arp_tx
	output	wire				O_arp_tvalid,		//�����ip_arp_tx��arp�������Ч
	output	wire	[7:0]		O_arp_tdata,		//�����ip_arp_tx��arp��
	output	wire				O_arp_ttype,		//�����ip_arp_tx��arp������
	output	wire	[47:0]		O_arp_tdest_mac_addr,//�����ip_arp_tx����Զ���������յ���ARP������������MAC��ַ
	output	wire				O_arp_reply_done,//������ARP����ip_arp_tx��ȴ�Զ��������ARP��Ӧ
	//ip_arp_tx�ڷ���ip����ʱ���ѯcache���Ƿ���mac��ַ
	input	wire				I_mac_cache_ren,
	input	wire	[31:0]		I_mac_cache_rip_addr,
	output	wire	[47:0]		O_mac_cache_rdest_addr,
	output	wire				O_mac_cache_rdone,
	//���յ�arp���ݰ�
	input	wire				I_arp_rvalid,
	input	wire	[7:0]		I_arp_rdata

);

wire				arp_req_valid;
wire	[31:0]		arp_req_ip_addr;
wire	[47:0]		arp_req_mac_addr;
wire	[31:0]		arp_reply_ip_addr;
wire	[47:0]		arp_reply_mac_addr;
wire				arp_reply_done;

assign	O_arp_reply_done	=	arp_reply_done;

uiarp_tx arp_tx
(
	.I_mac_local_addr      		(I_mac_local_addr),
	.I_ip_local_addr       		(I_ip_local_addr),
			
	.I_arp_clk             		(I_arp_clk),
	.I_arp_reset           		(I_arp_reset),
	//��ip_arp_tx���ֵ��ź�		
	.I_arp_treq_en         		(I_arp_treq_en),	//ip_arp_tx�ڷ���IP����ʱ��û�в�ѯ��cache��MAC������ͨ������ARP��������ȡԶ��������ӦMAC
	.I_arp_tip_addr        		(I_arp_tip_addr),	//ip_arp_tx���������IP��û�ҵ�cache��MAC��ͨ������IP��ַ��ȡԶ������MAC
	.I_arp_tbusy           		(I_arp_tbusy),		//ip_arp_tx��ɷ���ARP������
	.O_arp_treq            		(O_arp_treq),		//֪ͨip_arp_txģ����Ҫ����ARP�����,	
	//����arp���ź�		
	.O_arp_tvalid          		(O_arp_tvalid),		//����ip_arp_tx��arp���ݰ���Ч
	.O_arp_tdata           		(O_arp_tdata),		//����ip_arp_tx��arp���ݰ�
	.O_arp_ttype           		(O_arp_ttype),		//����ip_arp_tx��arp������Ϊarp��
	.O_arp_tdest_mac_addr  		(O_arp_tdest_mac_addr),	//����ip_arp_tx����Ҫ���͵�ARP��Ŀ������MAC
	//��arp_rxģ��Խӵ��źţ�Զ���������͵�arp������Ҫͨ��arp_tx����Ӧ���Զ������
	.I_arp_rreply_en       		(arp_req_valid),	//Զ���������͵�ARP������Ч������������Ҫ����ARPӦ��
	.I_arp_rreply_ip_addr  		(arp_req_ip_addr),	//Զ���������͵�ARP����Զ������IP��ַ������������Ҫ����ARPӦ��
	.I_arp_rreply_mac_addr 		(arp_req_mac_addr)	//Զ���������͵�ARP����Զ������IP��ַ������������Ҫ����ARPӦ��
);


uiarp_rx arp_rx
(
	.I_ip_local_addr     		(I_ip_local_addr),
	.I_arp_clk           		(I_arp_clk),
	.I_arp_reset         		(I_arp_reset),
	//���յ���arp���ݰ�
	.I_arp_rvalid        		(I_arp_rvalid),	//����ip_arp_rxģ���ARP���ݰ�����
	.I_arp_rdata         		(I_arp_rdata),	//����ip_arp_rxģ���ARP���ݰ�����
	//�������ARP���ݰ���ΪԶ��������ARP�����Զ��������arpӦ�������Զ��������arp������ͨ��arp_txģ�鷢��arpӦ�����Զ������
	//���յ�Զ��������arp�����
	.O_arp_req_valid     		(arp_req_valid),		//Զ���������͵�ARP������Ч
	.O_arp_req_ip_addr   		(arp_req_ip_addr),		//Զ���������͵�ARP����Զ������IP��ַ
	.O_arp_req_mac_addr  		(arp_req_mac_addr),		//Զ���������͵�ARP����Զ������MAC��ַ
	//���յ�Զ��������arpӦ���
	.O_arp_reply_done    		(arp_reply_done),		//Զ��������ARPӦ�����
	.O_arp_reply_ip_addr 		(arp_reply_ip_addr),	//Զ��������ARPӦ����ɣ�Զ������IP��ַ
	.O_arp_reply_mac_addr		(arp_reply_mac_addr)	//Զ��������ARPӦ����ɣ�Զ������MAC��ַ
);

reg					mac_cache_wen;
reg		[31:0]		mac_cache_wip_addr;
reg		[47:0]		mac_cache_wmac_addr;

always@(*) begin//дMAC��ַ��mac_cache�л���
	if(I_arp_reset) begin
		mac_cache_wen		<=	1'b0;
		mac_cache_wip_addr	<=	32'd0;
		mac_cache_wmac_addr	<=	48'd0;
	end
	else begin
		if(arp_req_valid) begin//ARP����
			mac_cache_wen		<=	1'b1;
			mac_cache_wip_addr	<=	arp_req_ip_addr;
			mac_cache_wmac_addr	<=	arp_req_mac_addr;
		end
		else if(arp_reply_done) begin//ARPӦ��
			mac_cache_wen		<=	1'b1;
			mac_cache_wip_addr	<=	arp_reply_ip_addr;
			mac_cache_wmac_addr	<=	arp_reply_mac_addr;	
		end
		else begin
			mac_cache_wen		<=	1'b0;
			mac_cache_wip_addr	<=	32'd0;
			mac_cache_wmac_addr	<=	48'd0;			
		end		
	end
end


mac_cache mac_cache
(
	.I_wclk      (I_arp_clk),
	.I_reset     (I_arp_reset),
	.I_wen       (mac_cache_wen),
	.I_wip_addr  (mac_cache_wip_addr),
	.I_wmac_addr (mac_cache_wmac_addr),

	.I_rclk      (I_arp_clk),
	.I_ren       (I_mac_cache_ren),
	.I_rip_addr  (I_mac_cache_rip_addr),
	.O_rmac_addr (O_mac_cache_rdest_addr),
	.O_rmac_done (O_mac_cache_rdone)
);





endmodule
