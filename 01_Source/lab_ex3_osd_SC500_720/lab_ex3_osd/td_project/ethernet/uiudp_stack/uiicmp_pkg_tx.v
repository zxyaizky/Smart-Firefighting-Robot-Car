
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
/*******************************uiicmp_pkg_txģ��*********************
--��������������Ƶ�uiicmp_pkg_tx������ģ��
�����յ�1֡icmp������������ģ�飬����icmp����echo�ش�
*********************************************************************/

`timescale 1ns / 1ps

module uiicmp_pkg_tx(
input 	wire		I_clk,
input	wire		I_reset,
input 	wire		I_icmp_req_en,				//����,ICMP����pingӦ���������ɺ�ʹ�����
input 	wire [15:0] I_icmp_req_id,				//����,ICMP���İ��ı�ʶ��,��ÿһ�����͵����ݽ��б�ʶ
input 	wire [15:0] I_icmp_req_sq_num,			//����,ICMP����pingӦ���������ɺ�ʹ�����	
input   wire [15:0] I_icmp_req_checksum,		//����,ICMP���İ����ײ�У���
input 	wire [31:0] I_icmp_req_ip_addr,			//����,ICMP���İ�ԴIP��ַ(Զ��IP��ַ)

input  	wire [7 :0] I_icmp_ping_echo_data,		//����,ICMP���İ���echo pingӦ�������
input  	wire [9 :0] I_icmp_ping_echo_data_len,  //����,ICMP���İ���echo pingӦ������ݳ���
output 	reg        	O_icmp_ping_echo_ren,		//���,����������FIFO�е�echo pingӦ�������

input				I_icmp_pkg_busy,			//����,ip_sendģ�鷢��ICMP���ĵ�Ӧ�𣬴�����ģ��������Է���ICMP���İ������ݲ���
output 	reg			O_icmp_pkg_req,				//���,��֪ip_sendģ����ICMP���İ���Ҫ����
output 	reg     	O_icmp_pkg_valid,			//���,��֪ip_sendģ����ICMP���İ���Ҫ����
output 	reg  [7 :0] O_icmp_pkg_data,			//���,ICMP���ĵ���Ч����
output 	wire [9 :0] O_icmp_pkg_data_len,		//���,ICMP���ĵ���Ч���ݳ���
output 	wire [31:0]	O_icmp_pkg_ip_addr			//���,ICMP���ĵ�Ŀ��IP��ַ(Զ��������IP��ַ)
);


reg [15:0]    request_id;
reg [15:0]	  request_sq_num;
reg [31:0]	  request_ip_taddress;
reg [15:0]    checksum;
reg [9:0]	  echo_data_length;
//reg [31:0]    checksum_temp;
reg [3:0]     cnt1;
reg [9:0]     cnt2;
reg [1:0]     STATE;

localparam		WAIT_ICMP_PACKET = 2'd0;
localparam		WAIT_PACKET_SEND = 2'd1;
localparam		SEND_PACKET      = 2'd2;

localparam     	PING_REPLY_TYPE  = 8'h00;

//localparam     CHECKSUM_BASE    = 32'h0006aa9d;  //��ȥid��sq_num���ⲿ�ֵ�У���

assign   O_icmp_pkg_ip_addr		= request_ip_taddress;
assign   O_icmp_pkg_data_len 	= echo_data_length + 10'd8;

//����icmp����У���
// always@(request_id or request_sq_num or reset)
   // begin
		// if(reset) begin
			// checksum = 16'd0;
			// checksum_temp = 32'd0;
		// end
		// else begin
			// checksum_temp = request_id + request_sq_num + CHECKSUM_BASE;
			// checksum = ~(checksum_temp[31:16] + checksum_temp[15:0]);
		// end
	// end
		
always@(posedge I_clk or posedge I_reset)begin
	if(I_reset) begin
		cnt1 					<= 4'd0;
		cnt2 					<= 10'd0;
		request_id 				<= 16'd0;
		request_sq_num 			<= 16'd0;
		request_ip_taddress 	<= 32'd0;
		checksum 				<= 16'd0;
		echo_data_length 		<= 10'd0;
		O_icmp_pkg_req 			<= 1'b0;
		O_icmp_pkg_valid 		<= 1'b0;
		O_icmp_pkg_data 		<= 8'd0;
		O_icmp_ping_echo_ren 	<= 1'b0;
		STATE 					<= WAIT_ICMP_PACKET;
	end
	else begin
		case(STATE)
			WAIT_ICMP_PACKET:begin
				if(I_icmp_req_en) begin //�����յ�ICMP echo ping��,�ȱ���ð��Ļ�����Ϣ���Ĵ���
					request_id 				<= I_icmp_req_id;				//ICMP���ı�ʶ��
					request_sq_num 			<= I_icmp_req_sq_num;			//ICMP�������к�
					request_ip_taddress 	<= I_icmp_req_ip_addr;			//ICMP���ĵ�ַ
					checksum 				<= I_icmp_req_checksum;			//ICMP����У���
					echo_data_length 		<= I_icmp_ping_echo_data_len;	//ICMP���ĳ���
					O_icmp_pkg_req 			<= 1'b1;						//����ip_sendģ�鷢�Ͳ��֣�����ICMP����
					STATE 					<= WAIT_PACKET_SEND;			//����ICMP��״̬
				end
				else begin
					request_id 				<= 16'd0;
					request_sq_num 			<= 16'd0;
					request_ip_taddress 	<= 32'd0;
					checksum 				<= 16'd0;
					echo_data_length 		<= 10'd0;
					O_icmp_pkg_req 			<= 1'b0;
					STATE 					<= WAIT_ICMP_PACKET;
				end
			end
			WAIT_PACKET_SEND:begin	
				if(I_icmp_pkg_busy) begin //���ź�����ip_sendģ�飬����Ч����ip_sendģ���Ѿ���ʼ׼������ICMP����������Ҫ��ip_send���벿��ʱ���߼�ȷ��������ȷ����ip_sendģ��
					O_icmp_pkg_req 			<= 1'b0;
					O_icmp_pkg_valid 		<= 1'b1;
					O_icmp_pkg_data 		<= PING_REPLY_TYPE; //����Ӧ��(pingӦ��)������
					STATE 					<= SEND_PACKET;
				end
				else begin
					O_icmp_pkg_req 			<= 1'b1;
					O_icmp_pkg_valid 		<= 1'b0;
					O_icmp_pkg_data 		<= 8'd0;
					STATE 					<= WAIT_PACKET_SEND;
				end
			end
			SEND_PACKET:begin
				case(cnt1)
					0: begin O_icmp_pkg_data <= 8'h00; 					cnt1 <= cnt1 + 1'b1; end//����Ӧ��(pingӦ��)�Ĵ���
					1: begin O_icmp_pkg_data <= checksum[15:8]; 		cnt1 <= cnt1 + 1'b1; end//ICMP���İ�У��ͣ�ֱ�ӻ�ȡԶ���������͵�Ping��У���
					2: begin O_icmp_pkg_data <= checksum[7:0]; 			cnt1 <= cnt1 + 1'b1; end//ICMP���İ�У��ͣ�ֱ�ӻ�ȡԶ���������͵�Ping��У���
					3: begin O_icmp_pkg_data <= request_id[15:8]; 		cnt1 <= cnt1 + 1'b1; end//ICMP���ı�ʶ����ֱ�ӻ�ȡԶ���������͵�Ping����ʶ��
					4: begin O_icmp_pkg_data <= request_id[7:0]; 		cnt1 <= cnt1 + 1'b1; end//ICMP���ı�ʶ����ֱ�ӻ�ȡԶ���������͵�Ping����ʶ��
					5: begin O_icmp_pkg_data <= request_sq_num[15:8];	cnt1 <= cnt1 + 1'b1; end//ICMP���ı��룬ֱ�ӻ�ȡԶ���������͵�Ping���к�
					6: begin O_icmp_pkg_data <= request_sq_num[7:0]; 	cnt1 <= cnt1 + 1'b1; O_icmp_ping_echo_ren <= 1'b1;end//��echo FIFO�ж�ȡICMP echo���ĵ����ݲ���
					7: begin //ICMP���İ���������Ч����
						O_icmp_pkg_valid 		<= 1'b1;
						O_icmp_pkg_data 		<= I_icmp_ping_echo_data;
						if(cnt2 == (echo_data_length - 1)) begin
							cnt2 					<= 10'd0;
							O_icmp_ping_echo_ren 	<= 1'b0;
							cnt1 					<= cnt1 + 1'b1;
						end
						else begin
							O_icmp_ping_echo_ren 	<= 1'b1;
							cnt2 					<= cnt2 + 1'b1;
							cnt1 					<= cnt1;
						end
					end
					8: begin
						cnt1 					<= 4'd0;
						O_icmp_pkg_data 		<= 8'd0;
						O_icmp_pkg_valid 		<= 1'b0;
						STATE 					<= WAIT_ICMP_PACKET;
					end
					default: ;
				endcase
			end
		endcase
	end
end
							
endmodule

