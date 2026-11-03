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

/*******************************uiarp_txģ��*********************
--��������������Ƶ�uiarp_txģ��
--1.����һ��Ŀ��IPͨ�ţ�������Ҫ����Լ���ARP��������Ƿ����Ŀ��IP��Ӧ��Ŀ��MAC��������ڲ��ᴥ��ARP������Ӧ��ֱ�Ӹ���ARP��������װĿ��MAC
--2.������ARP��������򴥷�ARP���󣬶Է��յ�ARP���󣬸���ARP�ı����е�Ŀ��IP�жϣ��Ƿ�Ѱ���������Լ�������ǣ�����ARP��Ӧ��Я���Լ���MAC��ַ
*********************************************************************/
`timescale 1ns/1ps
module	uiarp_tx
(
	input	wire	[47:0]			I_mac_local_addr,
	input	wire	[31:0]			I_ip_local_addr,

	input	wire					I_arp_clk,
	input	wire					I_arp_reset,
//ip_arp_tx���ֵ��ź�
	input	wire					I_arp_treq_en,		//ip_arp_tx�ڷ���IP����ʱ��û�в�ѯ��cache��MAC������ͨ������ARP��������ȡԶ��������ӦMAC
	input	wire	[31:0]			I_arp_tip_addr,		//ip_arp_tx���������IP��û�ҵ�cache��MAC��ͨ������IP��ַ��ȡԶ������MAC
	input	wire					I_arp_tbusy,		//ip_arp_tx��ɷ���ARP������
	output	reg						O_arp_treq,			//֪ͨip_arp_txģ����Ҫ����ARP��
	output	reg						O_arp_tvalid,		//����ip_arp_tx��arp���ݰ���Ч
	output	reg		[7:0]			O_arp_tdata,		//����ip_arp_tx��arp���ݰ�
	output	reg						O_arp_ttype,		//����ip_arp_tx��arp������Ϊarp��
	output	reg		[47:0]			O_arp_tdest_mac_addr,//����ip_arp_tx����Ҫ���͵�ARP��Ŀ������MAC
//��arp_rxģ��Խӵ��źţ�Զ���������͵�ARP������Ҫͨ��arp_tx����Ӧ���Զ������
	input	wire					I_arp_rreply_en,		//Զ���������͵�ARP������Ч������������Ҫ����ARPӦ��
	input	wire	[31:0]			I_arp_rreply_ip_addr,	//Զ���������͵�ARP����Զ������IP��ַ������������Ҫ����ARPӦ��
	input	wire	[47:0]			I_arp_rreply_mac_addr	//Զ���������͵�ARP����Զ������IP��ַ������������Ҫ����ARPӦ��
);

reg		[47:0]		mac_reply_buffer;
reg		[31:0]		ip_reply_buffer;
reg		[31:0]		ip_request_buffer;
reg					reply_buffer_valid;
reg					request_buffer_valid;
reg		[4 :0]		cnt;
reg		[4 :0]		pad_cnt;
reg		[15:0]		OPER;
reg		[31:0]		TPA;
reg		[47:0]		THA;
reg					STATE;

localparam	ARP_REQUEST	=	16'h0001;
localparam	ARP_REPLY	=	16'h0002;
localparam	HTYPE		=	16'h0001;//Ӳ������-��̫������
localparam	PTYPE		=	16'h0800;//�ϲ�Э��ΪIPЭ��
localparam	HLEN		=	8'h06;
localparam	PLEN		=	8'h04;
localparam	WAIT_BUFFER_READY	=	1'b0;
localparam	SEND_ARP_PACKET		=	1'b1;

always@(posedge I_arp_clk or posedge I_arp_reset) begin
	if(I_arp_reset) begin
		O_arp_treq				<=	1'b0;
		O_arp_tvalid			<=	1'b0;
		O_arp_tdata				<=	8'd0;
		O_arp_ttype				<=	1'b0;
		O_arp_tdest_mac_addr	<=	48'd0;
		mac_reply_buffer		<=	48'd0;
		ip_reply_buffer			<=	32'd0;
		ip_request_buffer		<=	32'd0;
		reply_buffer_valid		<=	1'b0;
		request_buffer_valid	<=	1'b0;
		cnt						<=	5'd0;
		pad_cnt					<=	5'd0;
		OPER					<=	16'd0;
		TPA						<=	32'd0;
		THA						<=	48'd0;
		STATE					<=	WAIT_BUFFER_READY;
	end
	else begin//ARP�����Ǵ�ip_txģ�鷢�ͣ�ARPӦ������MAC����ģ���ã��ǲ��еģ�����ARP���ķ���ͨ���ǵ����ģ�������Ҫ�Ŷӷ���
		case({I_arp_treq_en, I_arp_rreply_en})//��״̬��ʵ���˼�����ͬʱ��ARPӦ�����ARP���󣬶���ȷ����ɷ���
			2'b00:begin
				if((!O_arp_treq) && (!O_arp_tvalid)) begin//û��arp_treq���󣬲���arp_tvalidΪ0 ����û��Ҫ���͵�ARP����
					if(request_buffer_valid) begin//�����δ�������ARP�������������
						OPER					<=	ARP_REQUEST;
						TPA						<=	ip_request_buffer;
						THA						<=	48'd0;
						request_buffer_valid	<=	1'b0;//���request_buffer_valid
						O_arp_treq				<=	1'b1;
					end
					else if(reply_buffer_valid) begin//�����δ�������ARPӦ�����������
						OPER					<=	ARP_REPLY;
						TPA						<=	ip_reply_buffer;
						THA						<=	mac_reply_buffer;
						reply_buffer_valid		<=	1'b0;//���request_buffer_valid
						O_arp_treq				<=	1'b1;						
					end
				end
			end
			2'b01:begin//����ARPӦ��
				if((!O_arp_treq) && (!O_arp_tvalid)) begin
					OPER					<=	ARP_REPLY;
					TPA						<=	I_arp_rreply_ip_addr;
					THA						<=	I_arp_rreply_mac_addr;
					O_arp_treq				<=	1'b1;	
				end
				else begin//��ҪarpӦ��
					ip_reply_buffer			<=	I_arp_rreply_ip_addr;//�Ĵ�Ŀ�ĵ�ַIP
					mac_reply_buffer		<=	I_arp_rreply_mac_addr;//�Ĵ�Ŀ�ĵ�ַMAC	
					reply_buffer_valid		<=	1'b1;//��Ҫ����ARPӦ��
				end
			end
			2'b10:begin//����ARP����,��ip_arp_tx����IP����ѯMACû�в�ѯ����ִ��ARP��������Զ�������ṩMAC
				if((!O_arp_treq) && (!O_arp_tvalid)) begin
					OPER					<=	ARP_REQUEST;
					TPA						<=	I_arp_tip_addr;
					THA						<=	48'd0;
					O_arp_treq				<=	1'b1;//ARP ����				
				end
				else begin//arp�����
					ip_request_buffer		<=	I_arp_tip_addr;
					request_buffer_valid	<=	1'b1;//ARP ������Ч��־
				end
			end
			2'b11:begin//����ARP��������ARPӦ��
				if((!O_arp_treq) && (!O_arp_tvalid)) begin
					OPER					<=	ARP_REQUEST;
					TPA						<=	I_arp_tip_addr;
					THA						<=	48'd0;
					O_arp_treq				<=	1'b1;//ARP ����
				end
				else begin
					ip_request_buffer		<=	I_arp_tip_addr;
					request_buffer_valid	<=	1'b1;//ARP������Ч
				end	
				ip_reply_buffer			<=	I_arp_rreply_ip_addr;
				mac_reply_buffer		<=	I_arp_rreply_mac_addr;
				reply_buffer_valid		<=	1'b1;	//ARPӦ����Ч
			end
		endcase

		case(STATE)
			WAIT_BUFFER_READY:begin
				if(O_arp_treq && I_arp_tbusy) begin
					O_arp_tdata		<=	HTYPE[15:8];	//Ӳ������-��̫������
					O_arp_tvalid	<=	1'b1;			//ARP������Ч
					cnt				<=	cnt + 1'b1;		
					if(OPER == ARP_REQUEST) begin		//�����ARP����
						O_arp_tdest_mac_addr	<=	48'hff_ff_ff_ff_ff_ff;	//ARPĿ�ĵ�ַΪ�㲥��ַ
						O_arp_ttype				<=	1'b1;					//֪ͨip_arp_tx ARP����ΪARP����
					end
					else begin
						O_arp_tdest_mac_addr	<=	THA;
						O_arp_ttype				<=	1'b0;		//֪ͨip_arp_tx ARP����ΪARPӦ��	
					end
					O_arp_treq		<=	1'b0;
					STATE			<=	SEND_ARP_PACKET;
				end
				else
					STATE			<=	WAIT_BUFFER_READY;
			end
			SEND_ARP_PACKET:begin
				case(cnt)
					1:	begin	O_arp_tdata	<=	HTYPE[7:0]; 				cnt <= cnt + 1'b1;end
					2:	begin	O_arp_tdata	<=	PTYPE[15:8]; 				cnt <= cnt + 1'b1;end
					3:	begin	O_arp_tdata	<=	PTYPE[7:0]; 				cnt <= cnt + 1'b1;end
					4:	begin	O_arp_tdata	<=	HLEN; 						cnt <= cnt + 1'b1;end
					5:	begin	O_arp_tdata	<=	PLEN; 						cnt <= cnt + 1'b1;end
					6:	begin	O_arp_tdata	<=	OPER[15:8]; 				cnt <= cnt + 1'b1;end
					7:	begin	O_arp_tdata	<=	OPER[7:0]; 					cnt <= cnt + 1'b1;end
					8:	begin	O_arp_tdata	<=	I_mac_local_addr[47:40]; 	cnt <= cnt + 1'b1;end
					9:	begin	O_arp_tdata	<=	I_mac_local_addr[39:32]; 	cnt <= cnt + 1'b1;end
					10:	begin	O_arp_tdata	<=	I_mac_local_addr[31:24]; 	cnt <= cnt + 1'b1;end
					11:	begin	O_arp_tdata	<=	I_mac_local_addr[23:16]; 	cnt <= cnt + 1'b1;end
					12:	begin	O_arp_tdata	<=	I_mac_local_addr[15:8]; 	cnt <= cnt + 1'b1;end
					13:	begin	O_arp_tdata	<=	I_mac_local_addr[7:0]; 		cnt <= cnt + 1'b1;end
					14:	begin	O_arp_tdata	<=	I_ip_local_addr[31:24]; 	cnt <= cnt + 1'b1;end
					15:	begin	O_arp_tdata	<=	I_ip_local_addr[23:16]; 	cnt <= cnt + 1'b1;end
					16:	begin	O_arp_tdata	<=	I_ip_local_addr[15:8]; 		cnt <= cnt + 1'b1;end
					17:	begin	O_arp_tdata	<=	I_ip_local_addr[7:0]; 		cnt <= cnt + 1'b1;end
					18:	begin	O_arp_tdata	<=	THA[47:40]; 				cnt <= cnt + 1'b1;end
					19:	begin	O_arp_tdata	<=	THA[39:32]; 				cnt <= cnt + 1'b1;end
					20:	begin	O_arp_tdata	<=	THA[31:24]; 				cnt <= cnt + 1'b1;end
					21:	begin	O_arp_tdata	<=	THA[23:16]; 				cnt <= cnt + 1'b1;end
					22:	begin	O_arp_tdata	<=	THA[15:8]; 					cnt <= cnt + 1'b1;end
					23:	begin	O_arp_tdata	<=	THA[7:0]; 					cnt <= cnt + 1'b1;end
					24:	begin	O_arp_tdata	<=	TPA[31:24]; 				cnt <= cnt + 1'b1;end
					25:	begin	O_arp_tdata	<=	TPA[23:16]; 				cnt <= cnt + 1'b1;end
					26:	begin	O_arp_tdata	<=	TPA[15:8]; 					cnt <= cnt + 1'b1;end
					27:	begin	O_arp_tdata	<=	TPA[7:0]; 					cnt <= cnt + 1'b1;end					
					28:	begin
						O_arp_tdata	<=	8'd0;
						if(pad_cnt == 5'd17) begin	//ͨ����ĩβ����0��ȷ�����ݳ���Ϊ46
							cnt		<=	cnt + 1'b1;
							pad_cnt	<=	5'd0;
						end
						else begin
							cnt		<=	cnt;
							pad_cnt	<=	pad_cnt + 1'b1;
						end
					end
					29: begin
						O_arp_tdata		<=	8'd0;
						O_arp_tvalid	<=	1'b0;
						O_arp_tdest_mac_addr	<=	48'd0;
						O_arp_ttype		<=	1'b0;
						cnt				<=	5'd0;
						STATE			<=	WAIT_BUFFER_READY;
					end
					default:begin
						O_arp_tdata		<=	8'd0;
						O_arp_tvalid	<=	1'b0;
						cnt				<=	5'd0;
						STATE			<=	WAIT_BUFFER_READY;
					end
				endcase
			end
		endcase
	end
end





endmodule
