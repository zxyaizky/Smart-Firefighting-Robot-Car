
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

/*******************************uiicmp_pkg_ctrlģ��*********************
--��������������Ƶ�uiicmp_pkg_ctrl������ģ��
--1.�� uiicmp_pkg_ctrl ���� ip_arp_rx ģ������� icmp ����Ŀǰֻ֧�� icmp �е� ping���������
���� ping ����������ݲ�����Ӧ�� ping �������Ϣ����� ip_arp_txģ�飬���� ping ������ĸ������ݴ��� icmp_echo_data_fifo ��
*********************************************************************/

`timescale 1ns / 1ps

module uiicmp_pkg_ctrl(
input       			I_reset,						//��λ����
input       			I_clk,							//ʱ������ 
input       			I_icmp_pkg_valid,				//���룬��Ч��ICMP���İ��ź�
input 		[7:0]	   	I_icmp_pkg_data,				//���룬��Ч��ICMP���İ�������Ч
output reg      		O_icmp_req_en,					//�����ICMP���İ�����
output reg [15:0]  		O_icmp_req_id,					//�����ICMP���İ��ı�ʶ��
output reg [15:0] 		O_icmp_req_sq_num,				//�����ICMP���İ������к�
output reg [15:0]		O_icmp_req_checksum,			//�����ICMP����У���
output reg        		O_icmp_ping_echo_data_valid,	//��������յ�ICMP���ģ�echo pingӦ����Ч
output reg [7 :0] 		O_icmp_ping_echo_data,			//��������յ�ICMP���ģ�echo pingӦ����Ч���ݲ���
output wire[9 :0] 		O_icmp_ping_echo_data_len		//��������յ�ICMP���ģ�echo pingӦ����Ч���ݲ��ֳ���

); 

reg [7 :0]  ptype;
reg [7 :0]  code;
reg [15:0]  checksum;
wire[15:0]  checksum_temp;
reg [3 :0]  cnt;
reg [9 :0]  echo_data_cnt;
reg         STATE;

reg [1 :0]  checksum_state;
reg         checksum_correct;
wire[31:0]  tmp_accum1;
reg [15:0]  accum1;
reg [31:0]  accum2;

localparam   RECORD_ICMP_HEADER = 0;
localparam   WAIT_PACKET_END = 1;

localparam   PING_REQUEST = 8'h08;

assign  O_icmp_ping_echo_data_len = echo_data_cnt + 1'b1;

assign  tmp_accum1 = accum2 + accum1;
assign  checksum_temp = ~(tmp_accum1[15:0] + tmp_accum1[31:16] - checksum - {ptype, 8'd0});

//ICMP���ĵ�У���
always @(posedge I_clk or posedge I_reset) begin
	if(I_reset) begin
		accum1 				<= 16'd0;
		accum2 				<= 32'd0;
		checksum_state 		<= 2'd0;
        checksum_correct 	<= 1'b1;			
	end
	else begin
		case(checksum_state) 
		0: begin 
			if(I_icmp_pkg_valid) begin
				accum1[15:8] 	<= I_icmp_pkg_data; 
				checksum_state 	<= 2'd1; 
			end
			else begin
				accum1[15:8] 	<= 8'd0;
				checksum_state 	<= 2'd0;
			end
		end
		1: begin accum1[7:0]  	<= I_icmp_pkg_data; checksum_state <= 2'd2; end
		2: begin 		
			if(!I_icmp_pkg_valid) begin
				if((tmp_accum1[15:0] + tmp_accum1[31:16]) != 16'hffff)
					checksum_correct <= 1'b0;
                 else
                    checksum_correct <= 1'b1;
			checksum_state <= 2'd3;
			end
			else begin
				accum2 			<= tmp_accum1;					  
				accum1[15:8] 	<= I_icmp_pkg_data;					   
				checksum_state 	<= 2'd1;
			end
		end
        3: begin
                accum1 			<= 16'd0;
				accum2 			<= 32'd0;
				checksum_state 	<= 2'd0;
		end				
		endcase
	end
end

//����ģ�����ICMP���İ�echo pingӦ������󣬲����Ȼ��浽ip_layer��FIFO��
always @(posedge I_clk or posedge I_reset) begin
	if(I_reset) begin
		cnt 						<= 4'd0;
		ptype 						<= 8'd0;
		code 						<= 8'd0;
		echo_data_cnt 				<= 10'd0;
		checksum 					<= 16'd0;
		O_icmp_req_en 				<= 1'b0;
		O_icmp_req_id 				<= 16'd0;
		O_icmp_req_sq_num 			<= 16'd0;
		O_icmp_ping_echo_data_valid <= 1'b0;
		O_icmp_ping_echo_data 		<= 8'd0;
		O_icmp_req_checksum 			<= 16'd0;
		STATE 						<= RECORD_ICMP_HEADER;
	end
	else begin
		case(STATE)
		RECORD_ICMP_HEADER:begin
			O_icmp_req_en <= 1'b0;
			echo_data_cnt <= 10'd0;
				if(I_icmp_pkg_valid)		//ICMP������Ч
					case(cnt)
					0: begin ptype 						<= I_icmp_pkg_data; cnt <= cnt + 1'b1; end	//ICMP�����ײ�-����:8λ����ʾ�������͵Ĳ�����Ļ��߲�ѯ���͵ı��汨��,һ���ǲ�ѯ���ģ�0��������Ӧ��(pingӦ��)��1������ѯӦ��(��������(ping����))��
					1: begin code 						<= I_icmp_pkg_data; cnt <= cnt + 1'b1; end	//ICMP�����ײ�-����:����ռ��8λ���ݣ�����ICMP������ĵ����ͣ���һ�����������ԭ��
					2: begin checksum[15:8] 			<= I_icmp_pkg_data; cnt <= cnt + 1'b1; end	//ICMP�����ײ�-У���:16λУ��͵ļ��㷽����IP�ײ�У��ͼ��㷽��һ�£���У�����Ҫ��ICMP�ײ���ICMP������У��
					3: begin checksum[7 :0] 			<= I_icmp_pkg_data; cnt <= cnt + 1'b1; end	//ICMP�����ײ�-У���:16λУ��͵ļ��㷽����IP�ײ�У��ͼ��㷽��һ�£���У�����Ҫ��ICMP�ײ���ICMP������У��
					4: begin O_icmp_req_id[15:8]  		<= I_icmp_pkg_data;	cnt <= cnt + 1'b1; end	//ICMP�����ײ�-��ʶ��:16λ��ʶ����ÿһ�����͵����ݱ����б�ʶ
					5: begin O_icmp_req_id[7 :0]  		<= I_icmp_pkg_data; cnt <= cnt + 1'b1; end	//ICMP�����ײ�-��ʶ��:16λ��ʶ����ÿһ�����͵����ݱ����б�ʶ
					6: begin O_icmp_req_sq_num[15:8]	<= I_icmp_pkg_data;	cnt <= cnt + 1'b1; end	//ICMP�����ײ�-���к�:16λ�Է��͵�ÿһ�����ݱ��Ľ��б��
					7: begin O_icmp_req_sq_num[7 :0] 	<= I_icmp_pkg_data; cnt <= cnt + 1'b1; end	//ICMP�����ײ�-���к�:16λ�Է��͵�ÿһ�����ݱ��Ľ��б��
					8: begin											
						if(ptype == PING_REQUEST && code == 8'h00) begin 		//�����Զ����������ping���������ô����������Ҫ����һ��pingӦ���
							O_icmp_ping_echo_data_valid <= 1'b1;				//pingӦ����Ч
							O_icmp_ping_echo_data 		<= I_icmp_pkg_data;										
						end	
						else begin	
							O_icmp_ping_echo_data_valid <= 1'b0;
							O_icmp_ping_echo_data 		<= 8'd0;
						end
						cnt 	<= 4'd0;
						STATE 	<= WAIT_PACKET_END;	
					end
					default: STATE <= RECORD_ICMP_HEADER;
					endcase
				else
					STATE <= RECORD_ICMP_HEADER;
		end
		WAIT_PACKET_END:begin					
			if(I_icmp_pkg_valid) begin //��������ICMP ����
				if(O_icmp_ping_echo_data_valid) //pingӦ����Ч
					echo_data_cnt <= echo_data_cnt + 1'b1; //ICMP��������
				else
					echo_data_cnt <= 10'd0;
				O_icmp_ping_echo_data_valid <= O_icmp_ping_echo_data_valid;
				O_icmp_ping_echo_data 		<= I_icmp_pkg_data;
				STATE 						<= WAIT_PACKET_END;
			end
			else begin
				if(O_icmp_ping_echo_data_valid) begin
					O_icmp_req_en 	<= 1'b1;	      //֪ͨip_send ģ����յ�ICMP���İ� ping���󣬲��ҷ���һ��echo pingӦ��
					O_icmp_req_checksum <= checksum_temp; //���У���
				end
				else begin
					O_icmp_req_checksum <= 16'd0;
					O_icmp_req_en <= 1'b0;
				end	
				echo_data_cnt <= echo_data_cnt;
				O_icmp_ping_echo_data_valid <= 1'b0;
				O_icmp_ping_echo_data 		<= 8'd0;
				STATE 						<= RECORD_ICMP_HEADER;											
			end
		end
		endcase
	end
end
				  								

endmodule


