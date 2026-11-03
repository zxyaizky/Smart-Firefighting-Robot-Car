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

/*******************************uiarp_rxģ��*********************
--��������������Ƶ�uiarp_rx������ģ��
��ģ����Ҫ���������ܣ� 
1.����ip_arp_rx�����arp�������arpӦ�������ȡ���е�Դip��ַ��Դmac��ַ����һһ��Ӧ�Ĺ�ϵ����mac_cacheģ���С� 
2.���ݽ��յ���arp�����������Ŀ��ip��ַ�뱾��ip��ַ��Ƚϡ�������һ�£�����arp_txģ�鷢��arpӦ�������������Ϣ�����򽫸�arp�����ˡ�
*********************************************************************/
`timescale 1ns/1ps
module	uiarp_rx
(
	input	wire	[31:0]			I_ip_local_addr,
	input	wire					I_arp_clk,
	input	wire					I_arp_reset,

	input	wire					I_arp_rvalid,
	input	wire	[7:0]			I_arp_rdata,

	output	reg						O_arp_req_valid,		//���յ������
	output	reg		[31:0]			O_arp_req_ip_addr,
	output	reg		[47:0]			O_arp_req_mac_addr,

	output	reg						O_arp_reply_done,		//���յ�Ӧ���
	output	reg		[31:0]			O_arp_reply_ip_addr,
	output	reg		[47:0]			O_arp_reply_mac_addr

);

reg		[15:0]		HTYPE;
reg		[15:0]		PTYPE;
reg		[7:0]		HLEN;
reg		[7:0]		PLEN;
reg		[15:0]		OPER;
reg		[47:0]		SHA;
reg		[31:0]		SPA;
reg		[47:0]		THA;
reg		[31:0]		TPA;

reg		[4:0]		cnt;
reg		[1:0]		STATE;

localparam    ARP_REQUEST 		= 16'h0001;
localparam    ARP_REPLY   		= 16'h0002;
localparam    READ_ARP_PACKET  	= 2'd0;
localparam    CHECK_ARP_TYPE   	= 2'd1;
localparam    CLEAR_REQUEST    	= 2'd2;

always@(posedge I_arp_clk or posedge I_arp_reset) begin
	if(I_arp_reset) begin
		HTYPE				<=	16'd0;
		PTYPE				<=	16'd0;
		HLEN				<=	8'd0;
		PLEN				<=	8'd0;
		OPER				<=	16'd0;
		SHA					<=	48'd0;
		SPA					<=	32'd0;
		THA					<=	48'd0;
		TPA					<=	32'd0;
		O_arp_req_valid		<=	1'b0;
		O_arp_req_ip_addr	<=	32'd0;	
		O_arp_req_mac_addr	<=	48'd0;	
		O_arp_reply_done	<=	1'b0;	
		O_arp_reply_ip_addr	<=	32'd0;
		O_arp_reply_mac_addr<=	48'd0;
		cnt					<=	5'd0;	
		STATE				<=	READ_ARP_PACKET;
	end
	else begin
		case(STATE)
			READ_ARP_PACKET:begin
				O_arp_req_valid		<=	1'b0;
				O_arp_reply_done	<=	1'b0;
				if(I_arp_rvalid) begin
					case(cnt)
						0 :begin	HTYPE[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//Ӳ������16��h0001
						1 :begin	HTYPE[7:0]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//Ӳ������16��h0001
						2 :begin	PTYPE[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����ǰ��·Ϊ��̫���������Э��ΪIPЭ�� 16'h0800
						3 :begin	PTYPE[7:0]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����ǰ��·Ϊ��̫���������Э��ΪIPЭ�� 16'h0800
						4 :begin	HLEN		<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//MAC��ַ���� 8'h06
						5 :begin	PLEN		<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//IP��ַ����  8'h04
						6 :begin	OPER[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//������ 16��h01 ARP����� �� 16��h02 ARPӦ��
						7 :begin	OPER[7:0]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//������ 16��h01 ARP����� �� 16��h02 ARPӦ��
						8 :begin	SHA[47:40]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���ͷ�MAC(Դ��ַMAC)
						9 :begin	SHA[39:32]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���ͷ�MAC(Դ��ַMAC) 
						10:begin	SHA[31:24]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���ͷ�MAC(Դ��ַMAC) 
						11:begin	SHA[23:16]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���ͷ�MAC(Դ��ַMAC) 	
						12:begin	SHA[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���ͷ�MAC(Դ��ַMAC) 	
						13:begin	SHA[7:0]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���ͷ�MAC(Դ��ַMAC) 
						14 :begin	SPA[31:24]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����IP(ԴIP��ַ)
						15 :begin	SPA[23:16]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����IP(ԴIP��ַ)	
						16:begin	SPA[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����IP(ԴIP��ַ)	
						17:begin	SPA[7:0]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����IP(ԴIP��ַ)

						18:begin	THA[47:40]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����MAC(Ŀ�ĵ�ַMAC)
						19:begin	THA[39:32]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����MAC(Ŀ�ĵ�ַMAC)
						20:begin	THA[31:24]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����MAC(Ŀ�ĵ�ַMAC)
						21:begin	THA[23:16]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����MAC(Ŀ�ĵ�ַMAC)		
						22:begin	THA[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����MAC(Ŀ�ĵ�ַMAC)		
						23:begin	THA[7:0]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//����MAC(Ŀ�ĵ�ַMAC)
						24:begin	TPA[31:24]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���շ�IP(Ŀ��IP��ַ)
						25:begin	TPA[23:16]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���շ�IP(Ŀ��IP��ַ)		
						26:begin	TPA[15:8]	<=	I_arp_rdata;	cnt	<=	cnt + 1'b1;end	//���շ�IP(Ŀ��IP��ַ)		
						27:begin	TPA[7:0]	<=	I_arp_rdata;	cnt	<=	5'd0;	STATE	<=	CHECK_ARP_TYPE;end//���շ�IP(Ŀ��IP)
						default:	cnt			<=	5'd0;
					endcase
				end
				else begin
					HTYPE				<=	16'd0;
					PTYPE				<=	16'd0;
					HLEN				<=	8'd0;
					PLEN				<=	8'd0;
					OPER				<=	16'd0;
					SHA					<=	48'd0;
					SPA					<=	32'd0;
					THA					<=	48'd0;
					TPA					<=	32'd0;
					cnt					<=	5'd0;				
					STATE				<=	READ_ARP_PACKET;
				end
			end
			CHECK_ARP_TYPE:begin
				STATE			<=	READ_ARP_PACKET;//�ص�ARP����ȡ״̬	
				if(OPER == ARP_REQUEST) begin//�����ARP���� ARP_REQUEST = 16'h0001��16��h01 ARP����� �� 16��h02 ARPӦ��
					if(TPA == I_ip_local_addr) begin		//�ȽϽ��յ���ARP�������IP��ַ�Ƿ�ͱ���IP��ַһ��
						O_arp_req_ip_addr		<=	SPA;	//����IP(Զ��ԴIP��ַ)
						O_arp_req_mac_addr		<=	SHA;	//���ͷ�MAC(Զ��Դ��ַMAC)
						O_arp_req_valid			<=	1'b1;	//����ARP������Ч(֪ͨ����ARP����ģ�鷢��һ��ARPӦ���Զ������),����Զ��������IP��ַ��MAC��ַ��cache
						O_arp_reply_done		<=	1'b0;
					end	
					else begin	
						O_arp_req_ip_addr		<=	32'd0;
						O_arp_req_mac_addr		<=	48'd0;
						O_arp_req_valid			<=	1'b0;
						O_arp_reply_done		<=	1'b0;
					end
				end
				else begin
						O_arp_reply_ip_addr		<=	SPA;
						O_arp_reply_mac_addr	<=	SHA;
						O_arp_req_valid			<=	1'b0;
						O_arp_reply_done		<=	1'b1;					
				end
			end
		endcase
	end
end


endmodule

