
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
/*******************************uiip_txģ��*********************
--��������������Ƶ�uiip_tx������ģ��
uiip_tx������udp���ݰ���icmp���ݰ���uiip_tx ģ�����������Ҫ���ܣ�
1.ͨ���ڲ���ģ��� ip_rx ģ����� icmp �������Ϣ����������װΪ��Ӧ�� icmp Ӧ�����
2.��uiudp_tx ģ����� udp �������ݣ���װΪ IP �����͡�uiip_tx ģ��Ϊ udp ���ġ�icmp ���ݰ����� IP ���ײ���ͬʱ�����ײ�У��͵ļ��㣬�������������ײ�������ֶΣ�
��󽫷�װ��ɵ� IP ���ݱ������ uiip_arp_tx ģ�顣uiudp_tx �� uiip_tx��uiip_tx �� uiicmp_pkg_tx��uiip_tx �� uiip_arp_tx ֮������ݴ������Ҫ�������ͨ�š�
*********************************************************************/
`timescale 1ns / 1ps

module uiip_tx #
(
parameter VERSION          		= 4'h4,          	//IPv4
parameter IHL              		= 4'h5,         	//IP��ͷ��С��5*4=20Bytes
parameter TOS              		= 8'h00,         	//��ͨ��������
parameter ID_BASE          		= 16'h0000,      	//IP����ʶ��׼0
parameter FLAG            		= 3'b010,        	//������IP��Ƭ���ҷ��͵�IP���ݰ�Ϊ���һ����
parameter FRAGMENT_OFFSET  		= 13'd0         	//IP����Ƭƫ��0
//parameter TTL              	= 8'h80��         	//����ʱ��
//parameter PROTOCOL         	= 8'h11,         	//17��UDPЭ��
//parameter I_udp_local_ip_taddr = 32'hc0a80a01  	//ԴIP��ַ��192.168.10.1
//parameter I_ip_dest_addr      = 32'hc0a80102,  	//Ŀ��IP��ַ��192.168.1.2
//parameter CHKSUM_BASE      	= 16'h8fbb      	//��Ŀ��IP��ַ��IP�����ȣ�IP����ʶ���⣬������֪IP���ײ����ֵ�У���   
)
(
input wire [31:0] 		I_ip_local_addr,			//����IP��ַ
input wire [31:0] 		I_ip_dest_addr,				//����UDP��,UDP�㷢�͵�Ŀ��IP��ַ
input wire        		I_reset,
input wire        		I_ip_clk,

output reg        		O_ip_udp_tbusy,				//���͸�UDP��,֪ͨUDP��ip_sendģ���Ѿ�׼���ã����Է���UDP���ݰ�
input wire        		I_ip_udp_treq,				//����UDP��,UDP���������û�UDP���ݰ�
input wire	      		I_ip_udp_tvalid,				//����UDP��,UDP�㷢�͵���Ч����
input wire [7:0]  		I_ip_udp_tdata,				//����UDP��,UDP�㷢�͵���Ч����
input wire [15:0] 		I_ip_udp_tdata_len,			//����UDP��,UDP�㷢�͵���Ч���ݳ���

input wire        		I_ip_tbusy,					//����ip_arp_layerģ��  ,IP���ݷ����Ƿ�æ
output reg        		O_ip_treq,					//���͸�ip_arp_layerģ��,������IP���ݰ�
output reg	      		O_ip_tvalid,					//���͸�ip_arp_layerģ��,IP���ݰ���Ч�ź�
output reg [7:0]  		O_ip_tdata,					//���͸�ip_arp_layerģ��,IP���ݰ���Ч
output reg [31:0] 		O_ip_taddr,        			//���͸�ip_arp_layerģ��,MACĿ�ĵ�ַ

input wire        		I_icmp_req_en,				//���룬ICMP���İ�pingӦ��ʹ��(��UDPЭ��ջ��ֻ֧��ICMP��ping������)
input wire [15:0] 		I_icmp_req_id,				//���룬ICMP���İ���ʶ
input wire [15:0] 		I_icmp_req_sq_num,			//���룬ICMP���İ����к�
input      [15:0] 		I_icmp_req_checksum,		//���룬ICMP���İ�У���
input wire [31:0] 		I_icmp_req_ip_addr,			//���룬IP����Ŀ��IP��ַ(Զ��������IP��ַ)
input      [7:0]  		I_icmp_ping_echo_data,		//���룬ICMP���ĵ���Ч����
input      [9:0]  		I_icmp_ping_echo_data_len,	//���룬ICMP���ĵ���Ч���ݳ���
output wire       		O_icmp_ping_echo_ren		//�����ʹ�ܣ���ICMP���Ļ����FIFO�ж�ȡICMP��������
);

wire[31:0] 	checksum_base;
wire [15:0] 	checksum;
wire [16:0] checksum1;
reg [31:0] 	checksum_temp;
reg [15:0] 	ip_tdata_length;
reg [15:0] 	datagram_cnt;
reg [15:0] 	packet_id;
reg 		udp_pkg_en;
wire[7 :0] 	shift_data_out;
reg [15:0] 	trans_data_cnt;
reg [7 :0]  TTL;
reg [7 :0]  PROTOCOL;
reg [4 :0]  cnt;
reg [2 :0]  STATE;

localparam  IDLE 				= 3'd0;
localparam  WAIT_ACK 			= 3'd1;
localparam  SEND_IP_HEADER 		= 3'd2;
localparam  SEND_UDP_PACKET 	= 3'd3;
localparam  SEND_ICMP_PACKET 	= 3'd4;
	

assign     checksum_base = {VERSION, IHL, TOS} + ID_BASE + {FLAG, FRAGMENT_OFFSET} + I_ip_local_addr[31:16] +  I_ip_local_addr[15:0];

//20����������λ�Ĵ�����
PH1P_LOGIC_SHIFTER#
(
.DATA_WIDTH(8),
.DATA_DEPTH(20),
.INIT_FILE("NONE"),
.SHIFT_TYPE("FIXED")
)
shift_ip_tx_inst
(
.depth({1{1'b0}}),
.dataout(shift_data_out),
.clk(I_ip_clk),
.en(I_ip_udp_tvalid | O_ip_tvalid),
.datain(I_ip_udp_tdata)
);



reg        	icmp_pkg_busy;	  
wire      	icmp_pkg_req;
wire      	icmp_pkg_valid;
wire [7:0]  icmp_pkg_data;
wire [31:0] icmp_pkg_ip_addr;
wire [9:0]  icmp_pkg_data_len;

uiicmp_pkg_tx icmp_pkg_tx_inst 
(
.I_clk							(I_ip_clk), 
.I_reset						(I_reset), 
.I_icmp_req_en					(I_icmp_req_en), 		//����,ICMP����pingӦ���������ɺ�ʹ�����			
.I_icmp_req_id					(I_icmp_req_id), 		//����,ICMP���İ��ı�ʶ��,��ÿһ�����͵����ݽ��б�ʶ
.I_icmp_req_sq_num				(I_icmp_req_sq_num),	//����,ICMP���İ������к�,��ÿһ�����ݽ��б��ı��	
.I_icmp_req_checksum			(I_icmp_req_checksum),	//����,ICMP���İ����ײ�У���
.I_icmp_req_ip_addr   			(I_icmp_req_ip_addr),	//����,ICMP���İ�ԴIP��ַ(Զ��IP��ַ)

.I_icmp_ping_echo_data   		(I_icmp_ping_echo_data),	//���룬ICMP���ĵ���Ч����
.I_icmp_ping_echo_data_len  	(I_icmp_ping_echo_data_len),//���룬ICMP���ĵ���Ч���ݳ���
.O_icmp_ping_echo_ren 			(O_icmp_ping_echo_ren), 	//�����ʹ�ܣ���ICMP���Ļ����FIFO�ж�ȡICMP��������

.I_icmp_pkg_busy				(icmp_pkg_busy), 		//����,ip_sendģ���еķ���ģ�鲿�֣���ICMP���İ�ʹ��
.O_icmp_pkg_req					(icmp_pkg_req), 		//���,icmp_packet_sendģ����Ҫ����ICMP���İ���Ӧecho ping����
.O_icmp_pkg_valid				(icmp_pkg_valid), 		//���,ICMP����������Ч
.O_icmp_pkg_data				(icmp_pkg_data),		//���,ICMP��������
.O_icmp_pkg_data_len       		(icmp_pkg_data_len),	//���,ICMP�������ݳ���
.O_icmp_pkg_ip_addr 			(icmp_pkg_ip_addr) 		//���,ICMP����Ŀ��IP��ַ(Զ��IP��ַ)
);
	
//IPУ��ͼ���
always@(posedge I_ip_clk or posedge I_reset)begin
	if(I_reset) begin
		checksum_temp <= 32'd0;
		//checksum = 16'd0;
	end
	else begin
		checksum_temp <= checksum_base + {TTL, PROTOCOL} + packet_id + ip_tdata_length + O_ip_taddr[31:16] + O_ip_taddr[15:0];
		//checksum = ~(checksum_temp[31:16] + checksum_temp[15:0]);
	end
end

assign checksum1 = checksum_temp[31:16] + checksum_temp[15:0];
assign checksum = ~(checksum1[16] + checksum1[15:0]);

//��ģ��ΪIP������ģ�飬IP����UDO����ICMP�������ȷ���ICMP��	
always@(posedge I_ip_clk or posedge I_reset)begin
	if(I_reset) begin
		cnt 				<= 5'd0;
		udp_pkg_en 			<= 1'b0;
		datagram_cnt 		<= 16'h0;
		packet_id 			<= 16'd0;
		ip_tdata_length 	<= 16'd0;
		TTL 				<= 8'd0;
		PROTOCOL 			<= 8'd0;
		icmp_pkg_busy 		<= 1'b0;
		trans_data_cnt 		<= 16'd0;
		O_ip_udp_tbusy 		<= 1'b0;
		O_ip_treq 			<= 1'b0;
		O_ip_tdata 			<= 8'd0;
		O_ip_tvalid 		<= 1'b0;
		O_ip_taddr 			<= 32'd0;
		STATE 				<= IDLE;
	end
	else begin
		case(STATE)
			IDLE:begin
				if(icmp_pkg_req & (~I_ip_tbusy)) begin 			//�����ICMP����Ҫ���ͣ�����ip_arp_txģ�鴦�ڿ���(I_ip_tbusy==0����tbuf���У����ڷ�������)
					O_ip_treq 			<= 1'b1;				//֪ͨip_arp_txģ�飬��IP����Ҫ���ͣ�ICMP��Ҳ��IP����
					O_ip_udp_tbusy 		<= 1'b0;				//֪ͨudp_layerģ�飬Ŀǰ���ܷ���UDP���ݰ�
					O_ip_taddr			<= icmp_pkg_ip_addr;	//����ip_rxģ����յ���icmp�����IP��ַ(��Ϊ����icmp����Ҫͨ��IP��ַ��ȡԶ��������MAC��ַ)
					udp_pkg_en 			<= 1'b0;				//����Ƿ���udp������udp_pkg_en=1 ����ip�㷢�͵�����ΪUDP��
					STATE 				<= WAIT_ACK;
				end
				else if(I_ip_udp_treq & (~I_ip_tbusy)) begin 		//�����UDP����Ҫ����
					O_ip_treq 			<= 1'b1;				//���ip���������󣬸�ip_arp_txģ��
					O_ip_udp_tbusy 		<= 1'b0;				//֪ͨudp_layerģ�飬Ŀǰ���ܷ���UDP���ݰ�
					O_ip_taddr 			<= I_ip_dest_addr;		//udp���ṩ��Ҫ���͵�Ŀ��������IP��ַ
					udp_pkg_en 			<= 1'b1;				//����Ƿ���udp������udp_pkg_en=1 ����ip�㷢�͵�����ΪUDP��
					STATE 				<= WAIT_ACK;
				end
				else begin
					O_ip_udp_tbusy 		<= 1'b0;
					O_ip_treq 			<= 1'b0;
					udp_pkg_en 			<= 1'b0;					
					STATE 				<= IDLE;							
				end
			end
			WAIT_ACK:begin
				if(I_ip_tbusy) begin	//������O_ip_treq�����ip_arp_txģ�鷵��I_ip_tbusy=1 ����ip_layer���Է���IP��(UDP����ICMP��)��ip_arp_txģ��
					O_ip_treq 			<= 1'b0;
					O_ip_udp_tbusy 		<= udp_pkg_en ? 1 : 0;	//���udp_pkg_en��Ч����������UDP��	
					STATE 				<= SEND_IP_HEADER;		//����IP֡ͷ
				end
				else begin
					O_ip_udp_tbusy 		<= 1'b0;
					O_ip_treq 			<= 1'b1;
					STATE 				<= WAIT_ACK;
				end
			end
			SEND_IP_HEADER:begin			//����IP��֡ͷ
				case(cnt)
					0: begin
						if(I_ip_udp_tvalid | (~udp_pkg_en)) begin				//�����UDP���İ���Ҫ���ͻ���udp_pkg_en==0 ��ICMP���İ�
							O_ip_tdata 			<= {VERSION, IHL};				//�汾|�ײ�����(IP�ײ�һ���ж��ٸ�32bit����)
							O_ip_tvalid 		<= 1'b1;						//֪ͨtbuf IP������Ч
							packet_id 			<= ID_BASE + datagram_cnt;		//��ʶ��ÿ����1����ֵ��1
							TTL 				<= 8'h80;						//����ʱ��	
							if(!udp_pkg_en) begin								//�����ICMP��
								ip_tdata_length		<= icmp_pkg_data_len + (IHL << 2);  //IP���ܳ��ȣ�IP���ݳ���+IP�ײ����ȣ�	
								PROTOCOL 		 	<= 8'h01;							 //IP������Ϊ ICMP��
							end
							else begin
								ip_tdata_length 	<= I_ip_udp_tdata_len + (IHL << 2);  //IP���ܳ��ȣ�IP���ݳ���+IP�ײ����ȣ�		
								PROTOCOL 			<= 8'h11;							//IP������Ϊ UDP��											
							end
							cnt 					<= cnt + 1'b1;
						end
						else
						cnt 				<= 5'd0;
					end							
					1:  begin O_ip_tdata <= TOS;					 			cnt <= cnt + 1'b1; end//��������
					2:  begin O_ip_tdata <= ip_tdata_length[15:8]; 	 			cnt <= cnt + 1'b1; end//IP���ܳ���
					3:  begin O_ip_tdata <= ip_tdata_length[7:0]; 	 			cnt <= cnt + 1'b1; end//IP���ܳ���
					4:  begin O_ip_tdata <= packet_id[15:8]; 		 			cnt <= cnt + 1'b1; end//IP����ʶ����ÿ����һ�ݱ��ģ���ֵ��1
					5:  begin O_ip_tdata <= packet_id[7:0]; 		 		 	cnt <= cnt + 1'b1; end//IP����ʶ����ÿ����һ�ݱ��ģ���ֵ��1
					6:  begin O_ip_tdata <= {FLAG , FRAGMENT_OFFSET[12:8]}; 	cnt <= cnt + 1'b1; end//��־�ֶ�3bit|Ƭƫ�ƹ�13bit
					7:  begin O_ip_tdata <= FRAGMENT_OFFSET[7:0]; 	 			cnt <= cnt + 1'b1; end//Ƭƫ�ƹ�13bit
					8:  begin O_ip_tdata <= TTL; 					 			cnt <= cnt + 1'b1; end//����ʱ��
					9:  begin O_ip_tdata <= PROTOCOL; 				 			cnt <= cnt + 1'b1; end//Э��
					10: begin O_ip_tdata <= checksum[15:8]; 		 			cnt <= cnt + 1'b1; end//У���
					11: begin O_ip_tdata <= checksum[7:0]; 			 			cnt <= cnt + 1'b1; end//У���
					12: begin O_ip_tdata <= I_ip_local_addr[31:24]; 			cnt <= cnt + 1'b1; end//ԴIP��ַ32bit
					13: begin O_ip_tdata <= I_ip_local_addr[23:16]; 			cnt <= cnt + 1'b1; end//ԴIP��ַ32bit
					14: begin O_ip_tdata <= I_ip_local_addr[15:8];  			cnt <= cnt + 1'b1; end//ԴIP��ַ32bit
					15: begin O_ip_tdata <= I_ip_local_addr[7:0];   			cnt <= cnt + 1'b1; end//ԴIP��ַ32bit
					16: begin //Ŀ��IP��ַ(Զ������IP��ַ)
						if(!udp_pkg_en) 	//ICMP���İ�
							O_ip_tdata 		<= icmp_pkg_ip_addr[31:24];
						else				//UDP���İ�
							O_ip_tdata 		<= O_ip_taddr[31:24]; 
						cnt	 	<= cnt + 1'b1;
					end
					17: begin //Ŀ��IP��ַ(Զ������IP��ַ)
						if(!udp_pkg_en)	//ICMP���İ�
							O_ip_tdata 			<= icmp_pkg_ip_addr[23:16];
						else			//UDP���İ�
							O_ip_tdata 			<= O_ip_taddr[23:16]; 
						cnt 	<= cnt + 1'b1;
					 end
					18: begin //Ŀ��IP��ַ(Զ������IP��ַ)							   
						if(!udp_pkg_en) begin
							O_ip_tdata 				<= icmp_pkg_ip_addr[15:8];
							icmp_pkg_busy 			<= 1'b1; //icmp_packet_send�����ϱ���ʱ���ϣ���SEND_ICMP_PACKET״̬���ICMP���İ�
						end
						else begin
							O_ip_tdata 				<= O_ip_taddr[15:8];
							icmp_pkg_busy 			<= 1'b0;
						end
						cnt 	<= cnt + 1'b1;
					end
					19: begin //Ŀ��IP��ַ(Զ������IP��ַ)
						cnt <= 5'd0;
						if(!udp_pkg_en) begin	//ICMP���İ�
							O_ip_tdata 				<= icmp_pkg_ip_addr[7:0];
							STATE 					<= SEND_ICMP_PACKET;
						end
						else begin				//UDP���İ�
							O_ip_tdata 				<= O_ip_taddr[7:0]; 
							STATE 					<= SEND_UDP_PACKET;
						end
					end
				    default: cnt <= 5'd0;
			    endcase
		    end
			SEND_UDP_PACKET:begin			//����UDP���İ�	
				if(trans_data_cnt == (ip_tdata_length - 16'd20)) begin //20���ֽ�ΪIP�ײ���������ȴ������ݷ��ͽ���		
					O_ip_udp_tbusy				<= 1'b0;
					O_ip_tvalid 				<= 1'b0;
					O_ip_tdata 					<= 8'd0;
					datagram_cnt 				<= datagram_cnt + 16'h0001; //û������1֡���ģ���ֵ��1
					trans_data_cnt 				<= 16'd0;
					STATE <= IDLE;
				end
				else begin					//������Ч��UDP�������ݲ���
					O_ip_tvalid 				<= 1'b1;
					O_ip_tdata 					<= shift_data_out;	//��shift��λ�Ĵ����Ƴ�����
					trans_data_cnt 				<= trans_data_cnt + 1'b1; //UDP���İ���Ч���ݲ��ּ�����
					STATE 						<= SEND_UDP_PACKET;
				end
			end
			SEND_ICMP_PACKET:begin			//����ICMP���İ�
				if(icmp_pkg_valid) begin
					O_ip_tvalid 				<= 1'b1;
					O_ip_tdata 					<= icmp_pkg_data;
					STATE 						<= SEND_ICMP_PACKET;
				end
				else begin
					O_ip_tvalid 				<= 1'b0;
					O_ip_tdata 					<= 8'd0;					
					icmp_pkg_busy 				<= 1'b0;
					datagram_cnt 				<= datagram_cnt + 16'h0001;//ÿ������1֡���ģ���ֵ��1
					STATE						<= IDLE;
				end
			end
		endcase
	end
end

endmodule

