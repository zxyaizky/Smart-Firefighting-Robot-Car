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

/*******************************uiip_arp_txģ��*********************
--��������������Ƶ�uiip_arp_txģ��
-��ģ����Ҫ�� 2 �����ܣ�
1.����ip_txģ�������ip���ݰ���������Ŀ��ip��ַ��mac_cache�ж�����Ӧ��Ŀ��mac��ַ��
�������Чmac��ַ��ip���ݱ������mac_txģ�飬��������Чmac��ַ����ʹarp_txģ
�鷢��Ŀ��ip��ַ��arp��������ȴ���Чmac��ַͨ��arp_rxģ�鱻�� mac_cache�к����¶�����
2.���� arp_tx ģ������� arp ��������� mac_tx ģ�顣
*********************************************************************/
`timescale 1ns/1ps
module	uiip_arp_tx
(
	input	wire				I_ip_arp_clk,		//�ڲ�ϵͳʱ������
	input	wire				I_ip_arp_reset,		//��λ�ź�
	//arp_layer��mac_cache
	output	reg					O_mac_cache_ren,
	output	reg		[31:0]		O_mac_cache_rip_addr,
	input	wire	[47:0]		I_mac_cache_rdest_addr,//����ip_txģ�飬��ѯcache�е�MAC��ַ
	input	wire				I_mac_cache_rdone,
	//arp���źţ����͸�arp�������ѯmac
	output	reg					O_arp_treq_en,			//������͵�IP�����޷���MAC cache�����ҵ���Ӧ��MAC����Ҫ������ARP�����ͨ��IPѰ��Զ��������MAC
	output	reg		[31:0]		O_arp_treq_ip_addr,		//�ڷ���IP����ʱ������޷��ҵ�MAC����ͨ��IP��ַ����ARP��Ѱ��Զ��������MAC
	output	reg					O_arp_tbusy,			//��Ӧarp_txģ�飬���Է���ARP���� 
	input	wire				I_arp_treq,				//����arp_txģ�飬��Ҫ����ARP������
	input	wire				I_arp_tvalid,			//����arp_txģ��
	input	wire	[7:0]		I_arp_tdata,			//����arp_txģ��
	input	wire				I_arp_tdata_type,		//����arp_txģ�飬ARP�����ͣ�ARP Ӧ���(arp reply; 0) ARP�����(arp request ;1)
	input	wire	[47:0]		I_arp_tdest_mac_addr,	//����arp_txģ�飬Ŀ�ĵ�ַ��MAC
	input	wire				I_arp_treply_done,		//����arp_txģ��

	output	reg					O_ip_tbusy,				//ip_txģ��ɹ�ռ��ip_arp_tx����ip���ķ��������ź�
	input	wire				I_ip_treq,				//����ip_txģ�飬������IP��
	input	wire				I_ip_tvalid,			//����ip_txģ�飬IP������Ч�ź�
	input	wire	[7:0]		I_ip_tdata,				//����ip_txģ�飬IP����
	input	wire	[31:0]		I_ip_tdest_addr,		//����ip_txģ�飬Ŀ��IP��ַ

	input	wire				I_mac_tbusy,			//MAC layer ����æ��־
	output	reg					O_mac_tvalid,			//���MAC ������Ч�ź�
	output	reg		[7:0]		O_mac_tdata,			//���MAC ����
	output	reg		[1:0]		O_mac_tdata_type,		//���MAC tdata�������ͣ�IP��(2'b01)��ARPӦ���(2'b10)��ARP�����(2'b11)
	output	reg		[47:0]		O_mac_tdest_addr		//���MAC Ŀ��MAC

);

localparam	ARP_TIMEOUT_VALUE	=	30'd65536;
localparam	IDLE				=	3'd0;
localparam	CHECK_MAC_CACHE		=	3'd1;
localparam	WAIT_ARP_REPLY		=	3'd2;
localparam	WAIT_ARP_PACKET		=	3'd3;
localparam	WAIT_IP_PACKET		=	3'd4; 
localparam	SEND_ARP_PACKET		=	3'd5;
localparam	SEND_IP_PACKET		=	3'd6;     

reg		[47:0]		tmac_addr_temp;		//��ַ�Ĵ�
reg		      		arp_req_pend;
reg		[2:0] 		STATE;
reg					dst_ip_unreachable;
reg		[29:0]		arp_wait_time;		//ARP�ȴ�Ӧ�������

always@(posedge I_ip_arp_clk or posedge I_ip_arp_reset)begin
	if(I_ip_arp_reset) begin
		O_mac_cache_ren 		<=	1'b0; 	//��ѯMAC cache
		O_mac_cache_rip_addr 	<=	32'd0;	//��ѯMAC cache��ַ
		O_arp_tbusy 			<=	1'b0;	//ip_arp_tx arp ����׼����	
		O_arp_treq_en 			<=	1'b0;	//ip_arp_tx arp������ARP����������IP����û���Ҵ�cache�е�MAC��ʱ���ͣ�
		O_arp_treq_ip_addr 		<=	32'd0;	//ARP���Է���ģ��ͨ�����ʹ���Ŀ��IP��ַ��ARP���󣬻�ȡĿ��Զ��������MAC��ַ
		
		O_ip_tbusy				<=	1'b0;	//ip_arp_tx���Է���IP��

		O_mac_tdata_type		<=	2'd0;	//MAC������������
		O_mac_tvalid 			<=	1'b0;	//MAC����������Ч
		O_mac_tdata  			<=	8'd0;	//MAC��������
		O_mac_tdest_addr 		<=	48'd0;	//MAC���͵�ַ

		tmac_addr_temp 			<=	48'd0;
		arp_req_pend 			<=	1'b0;
		dst_ip_unreachable		<=	1'b0;
		arp_wait_time			<=	30'd0;
		STATE 					<=	IDLE;
	end
	else begin
		case(STATE)
			IDLE:begin
				O_arp_treq_en	<=	1'b0;
				if(!I_mac_tbusy) begin//MAC�㲻æ
					if(I_arp_treq) begin//�Ƿ���ARP����
						O_arp_tbusy				<=	1'b1;			//���Է���ARP��
						O_ip_tbusy				<=	1'b0;
						STATE					<=	WAIT_ARP_PACKET;//�ȴ�ARP��Ӧ
					end
					else if(I_ip_treq && ~arp_req_pend) begin	//�����IP���󣬲���֮ǰ��ARP����û��pend
						O_arp_tbusy				<=	1'b0;
						O_ip_tbusy				<=	1'b0;
						O_mac_cache_ren			<=	1'b1;				//�����IP�����ȴ�mac cacheͨ��IP��ַ��ȡMAC��ַ
						O_mac_cache_rip_addr	<=	I_ip_tdest_addr;	//ͨ��IP��ַ��ѯMAC cache
						STATE					<=	CHECK_MAC_CACHE;	
					end
					else begin
						O_arp_tbusy 			<= 1'b0;
						O_ip_tbusy  			<= 1'b0;						
						STATE 					<= IDLE;						
					end
				end
				else begin
					O_arp_tbusy				<= 1'b0;
					O_ip_tbusy  			<= 1'b0;
					O_mac_cache_ren 		<= 1'b0;
					O_mac_cache_rip_addr 	<= 48'd0;
					STATE 					<= IDLE;
				end
			end
			CHECK_MAC_CACHE:begin//��ѯMAC cache,���û�в鵽MAC������ARP�㷢��ARP����
				O_mac_cache_ren			<=	1'b0;
				if(I_mac_cache_rdone) begin						//MAC cache��ѯ���
					if(I_mac_cache_rdest_addr == 48'd0) begin	//���û�в�ѯ����Ӧ��MAC,����ARP�㷢��ARP����
						O_arp_treq_en			<=	1'b1;		//����ARP�㷢��ARP
						O_ip_tbusy				<=	1'b0;
						O_arp_treq_ip_addr		<=	O_mac_cache_rip_addr;	//���û�в�ѯ��MAC��Ҫ�����ṩ��IP��ַ����ARP�㷢��ARP����ȡMAC
						arp_req_pend			<=	1'b1;					//arp����Pend����ǰ������������arp����
						STATE					<=	IDLE;					//�ص�IDLE״̬���ȴ�ARP�㷢��ARP��
					end
					else begin
						tmac_addr_temp			<=	I_mac_cache_rdest_addr;	//��MAC cache��ѯ��MAC��ַ
						O_ip_tbusy				<=	1'b1;					//����IP���ACK
						O_arp_treq_en			<=	1'b0;
						arp_req_pend			<=	1'b0;
						STATE					<=	WAIT_IP_PACKET;
					end
				end
					else
						STATE					<=	CHECK_MAC_CACHE;
			end
			WAIT_ARP_REPLY:begin//�ȴ�Զ��������ARP��Ӧ(ARP���recieveģ�����յ�ARP��Ӧ)
				if(I_arp_treply_done) begin//��Ӧ
					arp_req_pend			<=	1'b0;
					arp_wait_time			<=	30'd0;
					dst_ip_unreachable		<=	1'b0;
					STATE					<=	IDLE;
				end
				else begin
					if(arp_wait_time == ARP_TIMEOUT_VALUE) begin//��ʱ��δ�յ���Ӧ
						arp_req_pend			<=	1'b1;
						O_arp_tbusy				<=	1'b0;
						O_arp_treq_en			<=	1'b1;
						O_arp_treq_ip_addr		<=	I_ip_tdest_addr;
						dst_ip_unreachable		<=	1'b1;
						arp_wait_time			<=	30'd0;
						STATE					<=	IDLE;						
					end
					else begin
						arp_req_pend			<=	1'b1;
						O_arp_tbusy				<=	1'b1;
						dst_ip_unreachable		<=	1'b0;
						arp_wait_time			<=	arp_wait_time + 1'b1;
						STATE					<=	WAIT_ARP_REPLY;
					end
				end
			end
			WAIT_ARP_PACKET:begin//ARP����Ч�����ĺ�ֱ�������MAC��	
				if(I_arp_tvalid) begin
					O_mac_tdata_type		<=	{1'b1,I_arp_tdata_type};//2'b10:arp reply; 2'b11:arp request ;2'b01 ip
					O_mac_tvalid			<=	1'b1;
					O_mac_tdata				<=	I_arp_tdata;
					O_mac_tdest_addr		<=	I_arp_tdest_mac_addr;
					STATE					<=	SEND_ARP_PACKET;
				end
				else begin
					O_mac_tdata_type		<=	2'd0;
					O_mac_tvalid			<=	1'b0;
					O_mac_tdata				<=	8'd0;
					O_mac_tdest_addr		<=	48'd0;
					STATE					<=	WAIT_ARP_PACKET;					
				end
			end
			SEND_ARP_PACKET:begin		//�������ĺ������MAC��
				if(I_arp_tvalid) begin	//���ARP����Ч
					O_mac_tvalid			<=	1'b1;
					O_mac_tdata				<=	I_arp_tdata;
					STATE					<=	SEND_ARP_PACKET;					
				end
				else begin
					O_arp_tbusy				<=	1'b0;
					O_mac_tdata_type		<=	2'd0;
					O_mac_tvalid			<=	1'b0;
					O_mac_tdata				<=	8'd0;
					O_mac_tdest_addr		<=	48'd0;
					if(arp_req_pend)	//������ź���Ч������IP�㷢��IP����ʱ��û�дӱ���cache��ѯ��MAC��ַ�������͵�ARP������������һ���ȴ�Զ����������ARP��Ӧ
						STATE				<=	WAIT_ARP_REPLY;
					else
						STATE				<=	IDLE;	//����ǵ�����ARP�㷢�͵İ������˽���			
				end
			end
			WAIT_IP_PACKET:begin	//IP���Ĵ���	
				if(I_ip_tvalid) begin
					O_mac_tdata_type		<=	2'b01;
					O_mac_tvalid			<=	1'b1;
					O_mac_tdata				<=	I_ip_tdata;
					O_mac_tdest_addr		<=	tmac_addr_temp;
					STATE					<=	SEND_IP_PACKET;
				end
				else begin			
					O_mac_tdata_type		<=	2'd0;
					O_mac_tvalid			<=	1'b0;
					O_mac_tdata				<=	8'd0;
					O_mac_tdest_addr		<=	48'd0;
					STATE					<=	WAIT_IP_PACKET;
				end
			end
			SEND_IP_PACKET:begin	//IP���Ĵ���
				if(I_ip_tvalid) begin
					O_mac_tvalid			<=	1'b1;
					O_mac_tdata				<=	I_ip_tdata;
					STATE					<=	SEND_IP_PACKET;	
				end
				else begin
					O_ip_tbusy 				<= 1'b0;
					O_mac_tdata_type 		<= 2'd0;
					O_mac_tvalid 			<= 1'b0;
					O_mac_tdata 			<= 8'd0;
					O_mac_tdest_addr 		<= 48'd0;
					STATE 					<= IDLE;					
				end
			end
		endcase
	end
end


endmodule
