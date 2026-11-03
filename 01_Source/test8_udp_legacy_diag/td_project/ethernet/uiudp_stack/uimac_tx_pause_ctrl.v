
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

/*******************************MAC_SEND_FLOW_CONTROL ������ģ��*********************
--��������������Ƶ�MAC_SEND_FLOW_CONTROL MAC���Ͷˣ���������ģ��
--1.
*********************************************************************/

`timescale 1ns / 1ps

module uimac_tx_pause_ctrl(
input            	 I_clk,
input 			 	 I_reset,
input [2:0]          I_mac_state,
input                I_mac_pause_en,		//
input [21:0]    	 I_mac_pause_time,
input [47:0]    	 I_mac_pause_addr,
output reg [47:0]	 O_pause_dst_mac_addr,
output reg           O_pause_flag
);


reg [21:0]     pause_clk_num;
reg [21:0]     pause_clk_cnt;
reg [1:0]      STATE;

localparam WAIT_PAUSE_FRAME        = 2'd0;
localparam WAIT_CURRENT_SEND_DONE  = 2'd1;
localparam MAC_SEND_PAUSE          = 2'd2;

localparam ADD_IFG   = 3'd4;

always@(posedge I_clk or posedge I_reset)begin
	if(I_reset) begin
		pause_clk_num  			<= 22'd0;
		pause_clk_cnt 			<= 22'd0;
		O_pause_flag 			<= 1'b0;
		O_pause_dst_mac_addr	<= 48'd0;
		STATE 					<= WAIT_PAUSE_FRAME;
	end
	else begin
		case(STATE)
			WAIT_PAUSE_FRAME:begin //�ȴ�PAUSE֡					
				O_pause_flag <= 1'b0;
				if(I_mac_pause_en) begin	//MAC����ģ����յ�PAUSE֡		
					O_pause_dst_mac_addr 	<= I_mac_pause_addr;//MAC����ģ����Ҫ����PAUSE��Ŀ��MAC��ַ		   
					pause_clk_num 			<= I_mac_pause_time;//PAUSEʱ�䣬��MAC���ն��Ѿ��������ҪPAUSE��ʱ�����ڸ���
					STATE 					<= WAIT_CURRENT_SEND_DONE;
				end
				else begin
					O_pause_dst_mac_addr 	<= 48'd0;
					pause_clk_num  			<= 22'd0;
					STATE 					<= WAIT_PAUSE_FRAME;
				end
			end
			WAIT_CURRENT_SEND_DONE:begin//�ȴ���MAC����״̬����I_mac_state == ADD_IFG״̬��ʱ������O_pause_flag��־
				if(I_mac_state == ADD_IFG)begin
					O_pause_flag 			<= 1'b1;//����O_pause_flag,֪ͨMAC ֡����ģ�飬��ͣ���ݷ���
					STATE 					<= MAC_SEND_PAUSE;
				end
				else begin
					O_pause_flag 			<= 1'b0;
					STATE 					<= WAIT_CURRENT_SEND_DONE;
				end
			end
			MAC_SEND_PAUSE:begin//��ͣ���ݷ��ͣ��ȴ�(pause_clk_num - 3)��ʱ������
				if(pause_clk_cnt == (pause_clk_num - 3)) begin
					O_pause_flag 			<= 1'b0;
					O_pause_dst_mac_addr 	<= 48'd0;
					pause_clk_cnt 			<= 22'd0;
					pause_clk_num 			<= 22'd0;
					STATE 					<= WAIT_PAUSE_FRAME;
				end
				else begin
					O_pause_flag 			<= 1'b1;//����O_pause_flag,֪ͨMAC ֡����ģ�飬��ͣ���ݷ���
					pause_clk_cnt 			<= pause_clk_cnt + 1'b1;
					STATE 					<= MAC_SEND_PAUSE;
				end
			end
		endcase
	end
end
	
endmodule

