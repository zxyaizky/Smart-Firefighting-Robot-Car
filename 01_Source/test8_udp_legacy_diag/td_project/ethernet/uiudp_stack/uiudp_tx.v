
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

/*******************************uiudp_txģ��**************************
--��������������Ƶ�uiudp_tx������ģ��
--1.uiudp_tx �������˳���Ϊ 8 ����λ�Ĵ�����udp_shift_register�����ڷ���udp�ײ�ʱ�������ݻ��塣
*********************************************************************/

`timescale 1ns / 1ps

module uiudp_tx 
(
input  wire [15:0]  I_udp_local_port,	//UDP���ض˿�
input  wire [15:0]	I_udp_dest_port,	//UDPĿ�Ķ˿�

input  wire         I_reset,	
input  wire         I_W_udp_clk,		//UDPд����ʱ��	
input  wire         I_W_udp_req,		//UDPд����
input  wire         I_W_udp_valid,		//UDPд��Ч
input  wire [7 :0]  I_W_udp_data,		//UDPд����
input  wire [15:0]	I_W_udp_len,		//UDPд����
output wire        	O_W_udp_busy,		//UDPдæ

input  wire         I_udp_ip_tbusy,		//ip�㷢��æ
output wire        	O_udp_ip_treq,		//udp���������ݵ�IP��
output reg         	O_udp_ip_tvalid,	//udp����udp����ip����Ч
output reg [7:0]   	O_udp_ip_tdata,		//udp����udp����ip
output reg [15:0]  	O_udp_ip_tpkg_len	//udp����udp������
);

reg  [3 :0] cnt; 
wire [7 :0] shift_data_out;
reg  [15:0] trans_data_cnt;
reg  [1 :0] STATE;


localparam  IDLE = 2'd0;
localparam  WAIT_ACK = 2'd1;
localparam  SEND_UDP_HEADER = 2'd2;
localparam  SEND_UDP_PACKET = 2'd3;

localparam  CHECKSUM = 16'h0000;        //����UDP����ʹ��У��͹��ܣ�У��Ͳ�����ȫ����0��UDP���Ͳ���У��ͼ���


assign O_W_udp_busy 		= I_udp_ip_tbusy;
assign O_udp_ip_treq 		= I_W_udp_req;

PH1P_LOGIC_SHIFTER#(
.DATA_WIDTH(8),
.DATA_DEPTH(8),
.INIT_FILE("NONE"),
.SHIFT_TYPE("FIXED"))
shift_udp_inst(
.depth({1{1'b0}}),
.dataout(shift_data_out),
.clk(I_W_udp_clk),
.en(I_W_udp_valid | O_udp_ip_tvalid),
.datain(I_W_udp_data));

always @(posedge I_W_udp_clk or posedge I_reset) begin
	if(I_reset) begin
		cnt 				<= 4'h0;
		O_udp_ip_tvalid 	<= 1'b0;
		O_udp_ip_tdata 		<= 8'd0;
		O_udp_ip_tpkg_len	<= 16'd0;
		trans_data_cnt 		<= 16'd0;
		STATE 				<= 2'd0;
	end
	else begin
		case(STATE)
			IDLE:begin
				if(I_W_udp_req & (~I_udp_ip_tbusy)) //����дUDP���󣬲���ip_sendģ�鲻æ(��I_udp_ip_tbusy=1��������ip�����ڴ�������)
					STATE <= WAIT_ACK;		  	  //����WAIT_ACK
				else
					STATE <= IDLE;
			end
			WAIT_ACK:begin
				if(I_udp_ip_tbusy)				  //���ip_sendģ��׼���ã�����UDP layer���Է�������
					STATE <= SEND_UDP_HEADER;
				else
					STATE <= WAIT_ACK;
			end
			SEND_UDP_HEADER:begin
				case (cnt) 
					0: begin
						if(I_W_udp_valid) begin
							O_udp_ip_tvalid 	<= 1'b1;					//udp��������Ч
							O_udp_ip_tdata 		<= I_udp_local_port[15:8];	//UDP����Դ�˿�
							O_udp_ip_tpkg_len 	<= I_W_udp_len + 16'h0008;  //UDP���ĳ��ȣ�����8bytesΪudp�ײ�
							cnt 				<= cnt + 1'b1;
						end
						else
							cnt <= 4'd0;
					end
					1: begin
						O_udp_ip_tdata 	<= I_udp_local_port[7:0];		//UDP����Դ�˿�
						cnt 			<= cnt + 1'b1;
					end
					2: begin
						O_udp_ip_tdata 	<= I_udp_dest_port[15:8];		//UDP����Ŀ�Ķ˿�
						cnt 			<= cnt + 1'b1;
					end
					3: begin
						O_udp_ip_tdata 	<= I_udp_dest_port[7:0];		//UDP����Ŀ�Ķ˿�
						cnt 			<= cnt + 1'b1;
					end
					4: begin
						O_udp_ip_tdata 	<= O_udp_ip_tpkg_len[15:8];		//UDP���ĳ���
						cnt 			<= cnt + 1'b1;
					end
					5: begin
						O_udp_ip_tdata 	<= O_udp_ip_tpkg_len[7:0];		//UDP���ĳ���
						cnt 			<= cnt + 1'b1;
					end
					6: begin	
						O_udp_ip_tdata 	<= CHECKSUM[15:8];				//У���
						cnt 			<= cnt + 1'b1;
					end
					7: begin
						O_udp_ip_tdata 	<= CHECKSUM[7:0];				//У���
						cnt 			<= 4'h0;
						STATE 			<= SEND_UDP_PACKET;
					end
					default: cnt <= 4'h0;
				endcase
			end
			SEND_UDP_PACKET:begin
				if (trans_data_cnt != (O_udp_ip_tpkg_len - 16'd8)) begin
					O_udp_ip_tvalid 	<= 1'b1;
					O_udp_ip_tdata 		<= shift_data_out;
					trans_data_cnt 		<= trans_data_cnt + 1'b1;
					STATE 				<= SEND_UDP_PACKET;
				end
				else begin
					trans_data_cnt 		<= 16'd0;
					O_udp_ip_tvalid 	<= 1'b0;
					O_udp_ip_tdata 		<= 8'd0;
					O_udp_ip_tpkg_len 	<= 16'd0;
					cnt 				<= 4'h0;
					STATE 				<= IDLE;
				end
			end
			default: STATE <= IDLE;
			endcase
	    end	
end

endmodule

