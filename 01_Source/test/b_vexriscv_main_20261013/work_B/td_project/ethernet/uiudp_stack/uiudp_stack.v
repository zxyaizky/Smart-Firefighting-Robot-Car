
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
/*******************************uiudp_stackģ��*********************
--��������������Ƶ�uiudp_stack������ģ��
*********************************************************************/

`timescale 1ns / 1ps

module uiudp_stack #
(
parameter               TX_COMMON_CLOCK = 1'b0,
parameter               CRC_GEN_EN        = 1'b1,          //CRC32ʹ��
parameter               INTER_FRAME_GAP   = 4'd12          //֡���
)
(   
input  wire             I_uclk,                 //�û�ʱ��
input  wire             I_reset,                //ϵͳ��λ
input  wire[47:0]       I_mac_local_addr,       //����MAC��ַ
input  wire[15:0]       I_udp_local_port,       //����UDP�˿�
input  wire[31:0]       I_ip_local_addr,        //����IP��ַ

input  wire[15:0]		I_udp_dest_port,        //Ŀ��UDP�˿�
input  wire[31:0]		I_ip_dest_addr,         //Ŀ��IP��ַ

output wire             O_W_udp_busy,		    //udp��дæ
input  wire             I_W_udp_req,            //udp��д����
input  wire             I_W_udp_valid,          //udp��д��Ч
input  wire[7:0]        I_W_udp_data,           //udp��д����
input  wire[15:0]		I_W_udp_len,            //udp��д����
			
output wire             O_R_udp_valid,          //udp�����Ч
output wire [7:0]       O_R_udp_data,           //udp�������
output wire [15:0]      O_R_udp_len,             //udp������ݳ���
output wire [15:0]      O_R_udp_src_port,       //udp���������Զ�������˿ں�  

input                   I_gmii_rclk,            //PHY RGMII�ӿڽ���ʱ��				
input                   I_gmii_rvalid,          //PHY RGMII�ӿڽ�����Ч
input [7:0]        		I_gmii_rdata,	        //PHY RGMII�ӿڽ�������

input                   I_gmii_tclk,	        //PHY RGMII�ӿڷ���ʱ��		
output wire             O_gmii_tvalid,          //PHY RGMII�ӿڷ���������Ч
output wire [7:0]       O_gmii_tdata,           //PHY RGMII�ӿڷ�������
		
output wire             O_ip_rerror,            //IP����մ���
output wire 			O_mac_rerror            //MAC����մ���
);

wire         udp_ip_treq;                       //����UDP��,UDP���������û�UDP���ݰ�       
wire         udp_ip_tvalid;                     //����UDP��,UDP�㷢�͵���Ч����
wire [7 :0]  udp_ip_tdata;                      //����UDP��,UDP�㷢�͵���Ч����
wire [15:0]  udp_ip_tpkg_len;                   //����UDP��,UDP�㷢�͵�Ŀ��IP��ַ
wire         udp_ip_tbusy;                      //ip_sendģ��׼���ã����Խ�������udp_layer������
wire         ip_udp_rvalid;                     //���յ�ip_layer��UDP����Ч�ź�
wire [7 :0]  ip_udp_rdata;                      //���ܵ�ip_layer��UDP���ݰ�



//UDPģ��
uiudp_layer udp_layer_inst 
(
.I_udp_local_port                   (I_udp_local_port   ),  //UDP���������˿�
.I_udp_dest_port		            (I_udp_dest_port    ),  //UDPĿ�������˿�
.I_udp_reset					    (I_reset            ), 

.I_W_udp_clk                        (I_uclk             ),  //UDP���û�ʱ��
.I_W_udp_req			            (I_W_udp_req        ),  //�û�UDP�ӿڷ�����������
.I_W_udp_valid		                (I_W_udp_valid      ),  //�û�UDP�ӿڷ���������Ч 
.I_W_udp_data			            (I_W_udp_data       ),  //�û�UDP�ӿڷ�������
.I_W_udp_len		                (I_W_udp_len        ),  //�û�UDP�ӿڷ������ݳ���
.O_W_udp_busy			            (O_W_udp_busy       ),  //�û�UDP�ӿڣ�UDP����׼����

.I_R_udp_clk                        (I_uclk             ),
.O_R_udp_valid		                (O_R_udp_valid      ),  //�û�UDP�ӿڶ�������Ч
.O_R_udp_data			            (O_R_udp_data       ),  //�û�UDP�ӿڶ�����
.O_R_udp_len		                (O_R_udp_len        ),  //�û�UDP�ӿڶ����ݳ���
.O_R_udp_src_port		            (O_R_udp_src_port   ),  //�û�UDP�ӿڶ����ݶ˿�

.I_udp_ip_tbusy                     (udp_ip_tbusy       ),  //ip_layer׼�����ź�
.O_udp_ip_treq                      (udp_ip_treq        ),  //������UDP����ip_layer
.O_udp_ip_tvalid                    (udp_ip_tvalid      ),  //����UDP����Ч�źŵ�ip
.O_udp_ip_tdata                     (udp_ip_tdata       ),  //����UDP��������Ч
.O_udp_ip_tpkg_len                  (udp_ip_tpkg_len    ),  //����UDP������

.I_udp_ip_rvalid                    (ip_udp_rvalid      ),  //���յ�ip_layer��UDP����Ч�ź�
.I_udp_ip_rdata                     (ip_udp_rdata       )   //���ܵ�ip_layer��UDP���ݰ�
);

//IP layer���ź�
wire        ip_tbusy;     		        //ip_sendģ��ɹ�ռ��send_buffer����ip���ķ��������ź�
wire        ip_treq;			        //����ip_sendģ�飬������IP��
wire        ip_tvalid;			        //����ip_sendģ�飬IP������Ч�ź�
wire [7 :0]	ip_tdata;			        //����ip_sendģ�飬IP����
wire [31:0] ip_taddr;			        //����ip_sendģ�飬Ŀ��IP��ַ

wire         ip_rvalid;	                //���յ���ЧIP�ź�
wire [7 :0]	 ip_rdata; 	                //���յ�IP����
                                  
uiip_layer ip_layer_inst                //IPģ�飬�����շ�IP���ݰ�(UDP)	 
(
.I_ip_local_addr                    (I_ip_local_addr    ),    //��������IP��ַ
.I_ip_dest_addr		                (I_ip_dest_addr     ),    //Ŀ������IP��ַ 
.I_ip_reset					        (I_reset            ),    //ϵͳ��λ
.I_ip_clk				            (I_uclk             ),    //ip���û�ʱ��
//ip_receiveģ����յ���udp���ݰ������͸�udp_layer
.O_ip_udp_rvalid		            (ip_udp_rvalid      ),    //�����upd_layer,��ip_receiveģ�������Ч��UDP�����ݲ��� 
.O_ip_udp_rdata			            (ip_udp_rdata	    ),    //�����upd_layer,��ip_receiveģ�������Ч��UDP�����ݲ���
//����udp���ݣ�udp_layer����������Ҫ�õ����źţ���Щ�źŻ��ṩ��ip_sendģ��
.O_ip_udp_tbusy			            (udp_ip_tbusy       ),    //ip_sendģ��׼���ã����Խ�������udp_layer������   
.I_ip_udp_treq			            (udp_ip_treq        ),    //����UDP��,UDP���������û�UDP���ݰ�   
.I_ip_udp_tvalid		            (udp_ip_tvalid      ),    //����UDP��,UDP�㷢�͵���Ч���� 
.I_ip_udp_tdata			            (udp_ip_tdata       ),    //����UDP��,UDP�㷢�͵���Ч���� 
.I_ip_udp_tdata_len		            (udp_ip_tpkg_len    ),    //����UDP��,UDP�㷢�͵�Ŀ��IP��ַ 
//����ip����ip_arp_tx����
.I_ip_tbusy		                    (ip_tbusy           ),    //ip_arp_tx׼���ã����ܷ���UDP����ICMP��
.O_ip_treq			                (ip_treq            ),    //���͸�ip_arp_txģ��,������IP���ݰ�
.O_ip_tvalid		                (ip_tvalid          ),    //���͸�ip_arp_txģ��,IP���ݰ���Ч�ź�
.O_ip_tdata		                    (ip_tdata           ),    //���͸�ip_arp_txģ��,IP���ݰ���Ч
.O_ip_taddr			                (ip_taddr           ),    //���͸�ip_arp_txģ��,MACĿ�ĵ�ַ 
//����ip_arp_rxģ���IP��
.I_ip_rvalid		                (ip_rvalid          ),    //���յ���IP������Ч�źţ�����ip_receive
.I_ip_rdata				            (ip_rdata           ),    //���յ���IP���ݰ���Ч������ip_receive
.O_ip_rerror			            (O_ip_rerror        )     //���յ���IP���ݰ���������
);
	

//ARPģ��


wire        mac_cache_ren;
wire [31:0] mac_cache_rip_addr;
wire [47:0] mac_cache_rdest_addr; 	//����ip_sendģ�飬��ѯcache�е�MAC��ַ
wire        mac_cache_rdone;
//ARP���ź�,���͸�ARP�������ѯMAC

wire        arp_treq_en;		    //������͵�IP�����޷���MAC cache�����ҵ���Ӧ��MAC����Ҫ������ARP�����ͨ��IPѰ��Զ��������MAC 
wire[31:0]	arp_treq_ip_addr;		//�ڷ���IP����ʱ������޷��ҵ�MAC����ͨ��IP��ַ����ARP��Ѱ��Զ��������MAC

wire        arp_tbusy;   		    //��Ӧarp_sendģ�飬���Է���ARP���� 
wire        arp_treq;			    //����arp_sendģ�飬��Ҫ����ARP������
wire        arp_tvalid;		        //����arp_sendģ�飬ARP Ӧ���(arp reply; 2'b11) ARP�����(arp request ;2'b01 ip)
wire [7 :0]	arp_tdata;			    //����arp_sendģ��
wire        arp_ttype;		        //����arp_sendģ�飬ARP IP ������
wire [47:0] arp_tdest_mac_addr;	    //����arp_sendģ�飬Ŀ�ĵ�ַ��MAC
wire        arp_treply_done;	    //����arp_sendģ��


wire        arp_rvalid;	        //���յ���ЧARP�ź�
wire [7 :0] arp_rdata;	        //���յ���ЧARP����

uiarp_layer arp_layer_inst
(
.I_mac_local_addr     		        (I_mac_local_addr   ), //����MAC��ַ
.I_ip_local_addr      		        (I_ip_local_addr    ), //����IP��ַ

.I_arp_clk							(I_uclk             ),  
.I_arp_reset						(I_reset            ),  
//ip_arp_tx�ڷ���IP����ʱ���ѯcache���Ƿ���MAC��ַ
.I_arp_treq_en					    (arp_treq_en        ),  //��ip_arp_tx����IP����cache��û�в�ѯ��MAC������£�ʹ��ARP�㷢��һ��ARP���󣬲�ѯԶ��������MAC
.I_arp_tip_addr	                    (arp_treq_ip_addr   ),  //������Ҫ��ѯ��IP��ַ
.I_arp_tbusy				        (arp_tbusy	        ),  //ip_arp_tx׼������ARP��
.O_arp_treq					        (arp_treq	        ),  //��ARP��������
.O_arp_tvalid				        (arp_tvalid         ),  //ARP����Ч�ź�
.O_arp_tdata					    (arp_tdata          ),  //ARP������
.O_arp_ttype                        (arp_ttype          ),  //ARP������
.O_arp_tdest_mac_addr		        (arp_tdest_mac_addr ),  //ARP��MAC��ַ���(������������ARP����Զ������Ӧ������Զ����������ARP������������Ӧ�𣬶����Ի�ȡ��MAC��ַ)
.O_arp_reply_done				    (arp_treply_done    ),  //������ARP����send_buffer��ȴ�Զ��������ARP��Ӧ

.I_mac_cache_ren				    (mac_cache_ren      ),  //MAC cache��ʹ�� 
.I_mac_cache_rip_addr				(mac_cache_rip_addr ),  //ͨ��IP��ַ��ѯMAC
.O_mac_cache_rdest_addr				(mac_cache_rdest_addr),  //�����ѯ��MAC
.O_mac_cache_rdone			        (mac_cache_rdone    ),  //��ѯMAC���
//���յ�ARP���ݰ�
.I_arp_rvalid				        (arp_rvalid         ),  //rbuf���յ���̫����ΪIP��,��Ч
.I_arp_rdata					    (arp_rdata          )   //rbuf���յ���̫����ΪIP��,����

);

//IP������ARP������ģ��
wire         mac_tvalid;            //MAC������������
wire [7 :0]  mac_tdata;             //MAC������Ч����
wire [1 :0]  mac_tdata_type;        //MAC������������
wire [47:0]  mac_tdest_addr;          //MACĿ�ĵ�ַ
wire         mac_tbusy;             //MAC����ģ���Ƿ��ڷ���æ

uiip_arp_tx ip_arp_tx_inst 
(
.I_ip_arp_clk						(I_uclk              ), 
.I_ip_arp_reset						(I_reset             ), 
//��ѯMAC cache�ź�
.O_mac_cache_ren			        (mac_cache_ren       ),  //MAC cache��ʹ�ܣ���ѯMAC cache
.O_mac_cache_rip_addr		        (mac_cache_rip_addr  ),  //����IP��ַ��ѯMAC
.I_mac_cache_rdest_addr		        (mac_cache_rdest_addr),  //�����ѯ����MAC��ַ
.I_mac_cache_rdone		            (mac_cache_rdone     ),  //MAC cache��ѯ��� 
//ARP���ź�,���͸�ARP�������ѯMAC
.O_arp_treq_en				        (arp_treq_en         ),  //������͵�IP�����޷���MACcache�����ҵ���Ӧ��MAC����Ҫ������ARP�����ͨ��IPѰ��Զ��������MAC 
.O_arp_treq_ip_addr	                (arp_treq_ip_addr    ),  //�ڷ���IP����ʱ������޷��ҵ�MAC����ͨ��IP��ַ����ARP��Ѱ��Զ��������MAC
.O_arp_tbusy				        (arp_tbusy           ),  //��Ӧarp�㣬arp_sendģ�飬���Է���ARP���� 
.I_arp_treq			                (arp_treq            ),  //����arp�㣬arp_sendģ�飬��Ҫ����ARP������
.I_arp_tvalid			            (arp_tvalid          ),  //����arp�㣬arp_sendģ�飬ARP Ӧ���(arp reply; 2'b11) ARP�����(arp request ;2'b01 ip)
.I_arp_tdata				        (arp_tdata           ),  //����arp�㣬arp_sendģ��
.I_arp_tdata_type			        (arp_ttype           ),  //����arp�㣬arp_sendģ�飬ARP IP ������
.I_arp_tdest_mac_addr	            (arp_tdest_mac_addr  ),  //����arp�㣬arp_sendģ�飬Ŀ�ĵ�ַ��MAC 
.I_arp_treply_done				    (arp_treply_done     ),  //����arp�㣬arp_sendģ��
//IP���ź�
.O_ip_tbusy				            (ip_tbusy            ),  //�����ip_sendģ�飬֪ͨip_sendģ�� ip_arp_tx����ģ����Է���ip��
.I_ip_treq			                (ip_treq             ),  //����ip�㣬ip�����������ź�
.I_ip_tvalid			            (ip_tvalid           ),  //����ip�㣬ip����Ч�ź�
.I_ip_tdata					        (ip_tdata            ),  //����ip�㣬ip���ݰ�
.I_ip_tdest_addr			        (ip_taddr            ),  //����ip�㣬Ŀ�ĵ�ַ
//���͸�MAC����ź�
.I_mac_tbusy				        (mac_tbusy           ),  //��������MAC�㣬MAC����æ
.O_mac_tvalid			            (mac_tvalid          ),  //�����mac��,IP��ARP����Ч�ź�
.O_mac_tdata					    (mac_tdata           ),  //�����mac��,IP��ARP��
.O_mac_tdata_type				    (mac_tdata_type      ),  //�����mac��,���ݰ�����ΪIP����ARP��
.O_mac_tdest_addr		            (mac_tdest_addr       )   //�����mac��,MACĿ�ĵ�ַ

);

//IP������ARP������ģ��
wire         mac_rvalid;       //MAC����������Ч�ź�
wire [7 :0]  mac_rdata;        //MAC��������
wire [15:0]  mac_rdata_type;   //MAC���յ������ݰ�����
wire         mac_rdata_error;  //MAC����֡����

uiip_arp_rx ip_arp_rx_inst 
(
.I_ip_arp_reset						(I_reset            ), //��λ
.I_ip_arp_rclk					    (I_uclk             ), //RX ����ʱ��
.O_ip_rvalid		                (ip_rvalid          ), //���յ���ЧIP�ź�
.O_ip_rdata				            (ip_rdata           ), //���յ�IP����
.O_arp_rvalid		                (arp_rvalid         ), //���յ���ЧARP�ź� 
.O_arp_rdata				        (arp_rdata          ), //���յ���ЧARP����
.I_mac_rvalid		                (mac_rvalid         ), //MAC���յ���������Ч�ź�
.I_mac_rdata				        (mac_rdata          ), //MAC���յ���Ч����
.I_mac_rdata_type			        (mac_rdata_type     )  //MAC���յ���֡����
);	

//MA��
uimac_layer #
(
.TX_COMMON_CLOCK (TX_COMMON_CLOCK),
.CRC_GEN_EN        		            (CRC_GEN_EN         ),  //CRCʹ��
.INTER_FRAME_GAP  		            (INTER_FRAME_GAP    )   //֡���
)
mac_layer_inst 
(		
.I_mac_local_addr    	            (I_mac_local_addr   ),  //����MAC��ַ
.I_mac_reset                        (I_reset            ),	
//���յ�MAC�����ݸ��ϲ�Э���
.I_mac_rclk                         (I_uclk),               //MAC������Ч����ʱ��
.O_mac_rvalid                       (mac_rvalid         ),  //�����ip_arp_layer,MAC����������Ч�ź�
.O_mac_rdata                        (mac_rdata          ),  //�����ip_arp_layer,MAC��������
.O_mac_rdata_type                   (mac_rdata_type     ),  //�����ip_arp_layer,MAC���յ������ݰ�����
.O_mac_rdata_error                  (O_mac_rerror        ),  //�����ip_arp_layer,MAC����֡����
//�����ϲ�Э������ݸ�MAC��
.I_mac_tclk                         (I_uclk              ), //MAC��������ʱ��
.I_mac_tvalid                       (mac_tvalid         ),  //MAC������������
.I_mac_tdata                        (mac_tdata          ),  //MAC������Ч����
.I_mac_tdata_type                   (mac_tdata_type     ),  //MAC������������
.I_mac_tdest_addr                   (mac_tdest_addr      ),  //MACĿ�ĵ�ַ
.O_mac_tbusy                        (mac_tbusy          ),  //MAC����ģ���Ƿ��ڷ���æ
//RGMIIתGMIIģ�������
.I_gmii_rclk                        (I_gmii_rclk        ),  //RGMII ����ʱ�� 
.I_gmii_rvalid                      (I_gmii_rvalid      ),  //RGMII����������Ч�ź� 
.I_gmii_rdata                       (I_gmii_rdata       ),	//RGMII������Ч����
//RGMIIתGMIIģ�����
.I_gmii_tclk                        (I_gmii_tclk        ),  //GMII ���ʱ��
.O_gmii_tvalid                      (O_gmii_tvalid      ),  //����� RGMII ģ��
.O_gmii_tdata                       (O_gmii_tdata       )   //����� RGMII ģ��
		
);
	 

endmodule


