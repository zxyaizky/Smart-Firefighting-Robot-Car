
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

/*******************************uiip_layerģ��*********************
--��������������Ƶ�uiip_layer������ģ��
1.uiip_tx����IP���ݰ�(UDP���ݰ���ICMP���ݰ�)
2.uiip_rx�����ⲿ��IP���ݰ����ҽ���ΪICMP���İ���UDP���İ�
3.ICMP��ִֻ��echo����Ӧ���ܣ����ip_rxģ����յ�ICMP pingӦ��������ݲ����Ȼ��浽FIFO�У�֮����ip_tx����Ӧ���ʱ���ȡFIFO��ͨ������
*********************************************************************/

`timescale 1ns / 1ps

module uiip_layer 
(
input  wire [31:0]		I_ip_local_addr,    //����IP��ַ
input  wire [31:0]		I_ip_dest_addr,     //Ŀ�ĵ�IP��ַ
input  wire             I_ip_reset,         //ϵͳ��λ
input  wire             I_ip_clk,          //UDP/IP���ݰ�����ͬ��ʱ��
//ip_receiveģ����յ���udp���ݰ������͸�udp_layer
output wire             O_ip_udp_rvalid,    //�����upd_layer,��ip_receiveģ�������Ч��UDP�����ݲ���
output wire [7 :0] 	    O_ip_udp_rdata,     //�����upd_layer,��ip_receiveģ�������Ч��UDP�����ݲ���
//����udp���ݣ�udp_layer����������Ҫ�õ����źţ���Щ�źŻ��ṩ��ip_sendģ��
output wire             O_ip_udp_tbusy,     //ip_sendģ��׼���ã����Խ�������udp_layer������
input  wire             I_ip_udp_treq,      //����UDP��,UDP���������û�UDP���ݰ�       
input  wire             I_ip_udp_tvalid,    //����UDP��,UDP�㷢�͵���Ч����
input  wire [7 :0] 		I_ip_udp_tdata,     //����UDP��,UDP�㷢�͵���Ч����
input  wire [15:0]		I_ip_udp_tdata_len, //����UDP��,UDP�㷢�͵�Ŀ��IP��ַ
//��Ҫ���͵������źţ��źŽӵ�tbufģ��
input  wire             I_ip_tbusy,         //����tbufģ��,ģ��׼����
output wire             O_ip_treq,          //���͸�tbufģ��,������IP���ݰ�
output wire             O_ip_tvalid,        //���͸�tbufģ��,IP���ݰ���Ч�ź�
output wire [7 :0]      O_ip_tdata,         //���͸�tbufģ��,IP���ݰ���Ч
output wire [31:0]	    O_ip_taddr,         //���͸�tbufģ��,MACĿ�ĵ�ַ
//��Ҫ���յ������źţ��źŽӵ�rbufģ��
input  wire             I_ip_rvalid,        //���յ���IP������Ч�źţ����뵽ip_receive
input  wire [7:0]	    I_ip_rdata,         //���յ���IP���ݰ���Ч�����뵽ip_receive
output wire             O_ip_rerror         //���յ���IP���ݰ���������
);
	 
localparam   VERSION          = 4'h4;       //IPv4
localparam 	 IHL              = 4'h5;       //IP��ͷ��С��5*4=20Bytes
localparam	 TOS              = 8'h00;      //��ͨ��������
localparam	 ID_BASE          = 16'h0000;   //IP����ʶ��׼0
localparam 	 FLAG             = 3'b010;     //������IP��Ƭ���ҷ��͵�IP���ݰ�Ϊ���һ����
localparam	 FRAGMENT_OFFSET  = 13'd0;      //IP����Ƭƫ��0

wire      		icmp_req_en;
wire [15:0]   	icmp_req_id;
wire [15:0]   	icmp_req_sq_num;
wire [31:0]   	icmp_req_ip_addr;
wire [15:0]   	icmp_req_checksum;
wire          	icmp_ping_echo_data_valid;
wire [7:0] 	  	icmp_ping_echo_data;
wire [9:0]    	icmp_ping_echo_data_len;	
wire     	  	icmp_ping_echo_ren;
wire [7:0] 	  	icmp_ping_echo_data_out;

//��ICMP���浽FIFO,֮����ip_sendģ���е�icmp_packet_sendģ���У���FIFO��ȡ����
udp_pkg_buf #(
.COMMON_CLOCK(1'b1), // Both ports are I_ip_clk.
.DATA_WIDTH_W(8), 
.DATA_WIDTH_R(8)  , 
.ADDR_WIDTH_W(11) , 
.ADDR_WIDTH_R(11) , 
.SHOW_AHEAD_EN(1'b1), 
.OUTREG_EN("NOREG")
) 
icmp_echo_data_fifo(
.rst	(I_ip_reset),  //asynchronous port,active hight
.clkw	(I_ip_clk),  //write clock
.we		(icmp_ping_echo_data_valid),  //write enable,active hight
.di		(icmp_ping_echo_data),  //write data
.clkr	(I_ip_clk),  //read clock
.re		(icmp_ping_echo_ren),  //read enable,active hight
.dout	(icmp_ping_echo_data_out),  //read data
.wrusedw(),  //stored data number in fifo
.rdusedw() //available data number for read      
) ;





//IP������ģ�飬��������UDP����ICMP��
uiip_tx #
(
.VERSION                        (VERSION),
.IHL                            (IHL),
.TOS					        (TOS),
.ID_BASE						(ID_BASE),
.FLAG							(FLAG),
.FRAGMENT_OFFSET                (FRAGMENT_OFFSET)
)
ip_tx_inst
(
.I_ip_local_addr                (I_ip_local_addr),
.I_ip_dest_addr				    (I_ip_dest_addr), 	   //����UDP��,UDP�㷢�͵�Ŀ��IP��ַ
.I_reset						(I_ip_reset), 
.I_ip_clk					    (I_ip_clk), 

.O_ip_udp_tbusy				    (O_ip_udp_tbusy),      //���͸�UDP��,֪ͨUDP��ip_sendģ���Ѿ�׼���ã����Է���UDP���ݰ�
.I_ip_udp_treq			    	(I_ip_udp_treq), 	   //����UDP��,UDP���������û�UDP���ݰ�
.I_ip_udp_tvalid			    (I_ip_udp_tvalid), 	   //����UDP��,UDP�㷢�͵���Ч����
.I_ip_udp_tdata					(I_ip_udp_tdata), 	   //����UDP��,UDP�㷢�͵���Ч����
.I_ip_udp_tdata_len				(I_ip_udp_tdata_len),  //����UDP��,UDP�㷢�͵���Ч���ݳ���

.I_ip_tbusy			    	    (I_ip_tbusy),          //����tbufģ��,ģ��׼����
.O_ip_treq					    (O_ip_treq),           //���͸�tbufģ��,������IP���ݰ�
.O_ip_taddr				        (O_ip_taddr),          //���͸�tbufģ��,MACĿ�ĵ�ַ
.O_ip_tvalid			        (O_ip_tvalid),         //���͸�tbufģ��,IP���ݰ���Ч�ź�
.O_ip_tdata				        (O_ip_tdata),          //���͸�tbufģ��,IP���ݰ���Ч

.I_icmp_req_en				    (icmp_req_en), 
.I_icmp_req_id				    (icmp_req_id), 
.I_icmp_req_sq_num		        (icmp_req_sq_num), 
.I_icmp_req_checksum			(icmp_req_checksum),
.I_icmp_req_ip_addr	            (icmp_req_ip_addr),
.I_icmp_ping_echo_data   		(icmp_ping_echo_data_out),
.I_icmp_ping_echo_data_len      (icmp_ping_echo_data_len),	
.O_icmp_ping_echo_ren           (icmp_ping_echo_ren)
);
	 
//IP����ģ�飬IP�����պ󣬱�ȷ��ΪUDP��ICMP���İ������
uiip_rx ip_rx_inst 
(
.I_ip_local_addr         	    (I_ip_local_addr),   
.I_reset						(I_ip_reset), 						//����,��λ
.I_ip_clk					    (I_ip_clk), 					//����,ʱ��
.I_ip_rvalid				    (I_ip_rvalid), 			        //����,��Ч��IP���ź�
.I_ip_rdata						(I_ip_rdata), 				    //����,��Ч��IP���ݰ�
.O_icmp_req_ip_addr		        (icmp_req_ip_addr), 			//���,ICMP���İ�ԴIP��ַ(Զ��IP��ַ)
.O_icmp_req_en				    (icmp_req_en), 				    //���,ICMP����pingӦ���������ɺ�ʹ�����			
.O_icmp_req_id				    (icmp_req_id), 				    //���,ICMP���İ��ı�ʶ��,��ÿһ�����͵����ݽ��б�ʶ
.O_icmp_req_sq_num			    (icmp_req_sq_num),			    //���,ICMP���İ������к�,��ÿһ�����ݽ��б��ı��	
.O_icmp_req_checksum			(icmp_req_checksum),			//���,ICMP���İ����ײ�У���
.O_icmp_ping_echo_data_valid    (icmp_ping_echo_data_valid),	//���,ICMP���İ���echo pingӦ����Ч�ź�
.O_icmp_ping_echo_data   		(icmp_ping_echo_data),		    //���,ICMP���İ���echo pingӦ����Ч����
.O_icmp_ping_echo_data_len      (icmp_ping_echo_data_len),	    //���,ICMP���İ���echo pingӦ����Ч����
.O_udp_ip_rvalid		        (O_ip_udp_rvalid), 			    //���,UDP������Ч�ź�
.O_udp_ip_rdata				    (O_ip_udp_rdata), 				//���,UDP������Ч����
.O_checksum_rerror	            (O_ip_rerror)				    //���,IP���ײ�У����Ƿ���ȷ
);


endmodule


