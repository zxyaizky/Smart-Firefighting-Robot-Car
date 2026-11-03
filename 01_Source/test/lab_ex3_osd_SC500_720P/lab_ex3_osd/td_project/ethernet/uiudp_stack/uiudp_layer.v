
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

/*******************************uiudp_layer ģ��*********************
--��������������Ƶ�uiudp_layer ������ģ��
--1.udp_layer��Ҫ��ɶ��Ͼ�Ӧ�����ݵ�udpЭ�����,���а�����������ģ��udp_tx ��udp_rx���ֱ���ɶ�Ӧ�����ݵķ��ͺͽ��ա�
*********************************************************************/

`timescale 1ns / 1ps

module uiudp_layer 
(
input   wire [15:0]     I_udp_local_port,  
input   wire [15:0]   	I_udp_dest_port,   //udp�û���ӿڣ�дͨ��Ŀ�Ķ˿�
input   wire       		I_udp_reset,            
//UDP�û��ӿ����ݷ����ź�
input   wire        	I_W_udp_clk,        //дʱ��
input   wire       		I_W_udp_req,        //udp�û���ӿڣ��û���������ǰ�ȷ���д����
input   wire       		I_W_udp_valid,      //udp�û���ӿڣ���udp_sendģ�����O_W_udp_busy��UDP�û�дͨ������W_udp_valid��Ч��������
input   wire [7 :0]		I_W_udp_data,       //udp�û���ӿڣ�дͨ������
input   wire [15:0]   	I_W_udp_len,        //udp�û���ӿڣ�дͨ�����ݳ���
output  wire	   		O_W_udp_busy,       //��W_udp_req��Ч��udp����ģ��ͨ�������O_W_udp_busy֪ͨ�û�����Է�������
//UDP�û��ӿ����ݽ����ź�
input   wire           	I_R_udp_clk,        //�û��ӿڶ�ʱ��
output  wire		   	O_R_udp_valid,      //udp�û���ӿڣ���ͨ����Ч
output  wire [7 :0] 	O_R_udp_data,       //udp�û���ӿڣ���������Ч
output  wire [15:0]	    O_R_udp_len,   //udp�û���ӿڣ������ݳ���
output  wire [15:0]	    O_R_udp_src_port,   //udp�û���ӿڣ����� 
//ip_layer �ӿ��ź�
input   wire        	I_udp_ip_tbusy,       //ip_layer׼�����ź�
output  wire	   		O_udp_ip_treq,       //������UDP����ip_layer
output  wire    		O_udp_ip_tvalid,     //����UDP����Ч�źŵ�ip
output  wire [7 :0] 	O_udp_ip_tdata,      //����UDP��������Ч
output  wire [15:0]	    O_udp_ip_tpkg_len,   //����UDP������

input   wire           	I_udp_ip_rvalid,     //���յ�ip_layer��UDP����Ч�ź�
input   wire [7 :0]     I_udp_ip_rdata       //���ܵ�ip_layer��UDP���ݰ�
);

//UDP����ģ��
uiudp_tx udp_tx_inst 
(
.I_udp_local_port       (I_udp_local_port ),
.I_udp_dest_port		(I_udp_dest_port  ), //udp�û���ӿڣ�дͨ��Ŀ�Ķ˿�
//�û��ӿ�
.I_reset				(I_udp_reset      ), 
.I_W_udp_clk			(I_W_udp_clk      ), //�û��ӿ�дʱ��
.I_W_udp_req		    (I_W_udp_req      ), //udp�û���ӿڣ��û���������ǰ�ȷ���д����
.I_W_udp_valid		    (I_W_udp_valid    ), //udp�û���ӿڣ���udp_sendģ�����O_W_udp_busy��UDP�û�дͨ������W_udp_valid��Ч��������
.I_W_udp_data			(I_W_udp_data     ), //udp�û���ӿڣ�дͨ������
.I_W_udp_len		    (I_W_udp_len      ), //udp�û���ӿڣ�дͨ�����ݳ���
.O_W_udp_busy			(O_W_udp_busy     ), //��W_udp_req��Ч��udp����ģ��ͨ�������O_W_udp_busy֪ͨ�û�����Է�������
//ip layer�ӿ�
.I_udp_ip_tbusy			(I_udp_ip_tbusy   ), //udp����ģ�������ip_layer�������ݣ�ip_layer����׼�����ź�
.O_udp_ip_treq		    (O_udp_ip_treq    ), //udp����ģ�������ip_layer������
.O_udp_ip_tvalid		(O_udp_ip_tvalid  ), //udp����������Ч�ź�
.O_udp_ip_tdata			(O_udp_ip_tdata   ), //udp�������ݵ�ip_layer
.O_udp_ip_tpkg_len		(O_udp_ip_tpkg_len)  //udp����
);
//UDP����ģ��	 
uiudp_rx udp_rx_inst 
(
.I_reset				(I_udp_reset      ), 
//�û��ӿ�
.I_R_udp_clk		    (I_R_udp_clk      ), //�û��ӿڶ�ʱ��
.O_R_udp_valid		    (O_R_udp_valid    ), //udp�û���ӿڣ���ͨ����Ч
.O_R_udp_data			(O_R_udp_data     ), //udp�û���ӿڣ���������Ч
.O_R_udp_len		    (O_R_udp_len      ), //udp�û���ӿڣ������ݳ���
.O_R_udp_src_port       (O_R_udp_src_port ), //udp�û���ӿڣ����� 
//ip_layer�ӿ�
.I_udp_ip_rvalid		(I_udp_ip_rvalid  ), //ip layer ���͹�����������Ч�ź�
.I_udp_ip_rdata			(I_udp_ip_rdata   )  //ip layer ���͹���������
);
	 
endmodule


